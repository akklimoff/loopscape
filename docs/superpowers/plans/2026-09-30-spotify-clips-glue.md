# Spotify Clips Glue (Part 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While the Spotify desktop client plays a track, the wallpaper on every display becomes that track's music video from the track's position; everything else falls back to the regular packs. A "Spotify clips" checkbox (off by default) switches it.

**Architecture:** `ClipResolver` (Part 2), streaming (Part 3) and `NowPlaying` (Part 1) are joined by a pure state machine, `App/ClipMode.swift`: it takes track changes, resolve results, stream failures and the checkbox, and returns effects (`resolve`, `play`, `pause`, `resume`, `leave`) — so every transition is unit-tested without AppKit or yt-dlp. `AppDelegate` carries the effects out: it runs `ClipResolver` on one serial queue, starts streams through the existing `startStream`, and falls back through a `leaveStream()` split out of `streamFailed`. The app now compiles `Clips/*.swift`, so the app-side `ClipStream` becomes `StreamTarget`.

**Tech Stack:** Swift 5 via plain `swiftc` (no package manager, no Xcode), Foundation, AppKit, `os`; the hand-rolled test harness in `Tests/`; `yt-dlp` (Homebrew) at run time.

**Spec:** `docs/superpowers/specs/2026-09-18-spotify-clips-design.md` — "Decisions", "Architecture" (all units), "Glue", "Part 4 — glue and menu", "Owner UX pass", and the Part 0 / Part 3 measurements under "Spike measurements".

## Global Constraints

- Compiler flags everywhere: `-swift-version 5 -target arm64-apple-macosx13.0`. No package manager, no third-party Swift code.
- `VERSION="2.0"` stays in `build.sh` and `make-dmg.sh`. No tag, no DMG in this plan: "Only after all ten steps and the owner UX pass below: tag `v2.0` and build the DMG."
- The feature ships switched off: the `spotifyClips` default is absent → off.
- No video found, a failed resolve, a stream failure, Spotify stopped or quit, or the checkbox off → the regular pack. Never a black or frozen screen.
- `current.txt` keeps naming the last regular pack — a clip is never written there, so the screen saver plays a pack.
- The rotation timer is suspended while a clip plays and restarted on the way out (already true for any stream: `restartTimer()` returns while `stream != nil`).
- `ClipResolver.resolve` blocks and its cache is unsynchronised: call it from exactly one serial queue; drop late results by generation.
- `yt-dlp` can be installed while the app runs: look it up per call, never cache a `YtDlp` from launch.
- Stills are keyed by video id: `~/Library/Caches/<bundle id>/stills/<video id>.jpg`, reused, never rewritten.
- Spotify facts (Part 0): `Duration` ms, `Playback Position` s; a seek posts nothing (a scrubbed track's clip drifts — accepted for 2.0); Spotify's launch posts a `paused` event for the restored track.
- `LoopscapeSaver.swift`, `Tests/Fixtures/`, `App/ScreenWallpaper.swift`, `App/StreamSession.swift`, `App/StreamStill.swift`, `App/NowPlaying.swift`, `App/Track.swift` stay untouched.
- Comments: none by default. Only a comment that answers a "why" the code cannot show is allowed; the ones in this plan are of that kind — copy them as written, add no others.
- Commits: one short imperative English subject line, no body unless it explains a "why", and no LLM attribution of any kind.
- Stage files by explicit path. `.omc/`, `.build/`, `.superpowers/` are untracked and stay that way.
- Branch: `spotify-clips`, forked from `now-playing` at `c220f73 record now playing results`. Work in place on this checkout.
- Test totals: `55 tests, 0 failures` at the start; `57` after Task 1; `70` from Task 2 on; each followed by `==> compiling resolve`.
- In zsh a bare `log` is a builtin: always call `/usr/bin/log`. The owner's wallpaper is usually paused (`defaults read com.aklimoff.loopscape paused` = 1): live checks set it to false and restore it.

## Review Focus

- Five skips in two seconds while a resolve takes ~5 s: only the last track's resolve runs; the others are voided before they start, not worked through as a backlog.
- Spotify paused before the clip arrives: the clip starts paused at the paused position, not playing.
- Ads, podcast episodes, local files and tracks with no artist: never searched, the pack stays.
- `yt-dlp` installed while Loopscape runs: the next resolve finds it and the menu hint disappears without a relaunch.
- A display replug or wake during a clip: the stream restarts at Spotify's current position and stays paused if Spotify is paused (no unit test — AppKit; the final review traces `restorePlayback`, `screensDidWake` and `shouldPlay`).

---

### Task 1: Compile the resolver into the app

**Files:**
- Modify: `build.sh` (app compile line), `App/AppDelegate.swift` (rename `ClipStream` → `StreamTarget`, 4 spots), `Clips/YtDlp.swift` (append `OnDemandYtDlp`), `Tests/main.swift`
- Create: `Tests/OnDemandYtDlpTests.swift`

**Interfaces:**
- Consumes: `YtDlp(directories:)`, `YtDlp.defaultDirectories()`, `ClipSource`, `ClipError.toolMissing` (Part 2).
- Produces: `struct StreamTarget { let url: URL; let position: TimeInterval; let stillID: String }` in `App/AppDelegate.swift`; `struct OnDemandYtDlp: ClipSource` with `var directories: () -> [String] = YtDlp.defaultDirectories`.

- [ ] **Step 1: Branch and commit this plan**

```bash
git switch -c spotify-clips now-playing
git log --oneline -1
git add docs/superpowers/plans/2026-09-30-spotify-clips-glue.md
git commit -m "add spotify clips glue plan"
```
Expected before the commit: the head is `c220f73 record now playing results`. If it is not, stop and report.

- [ ] **Step 2: Write the failing tests**

Create `Tests/OnDemandYtDlpTests.swift`:

```swift
import Foundation

func onDemandYtDlpTests() {
    test("a yt-dlp installed after launch is found by the next call") {
        let holder = try temporaryDirectory()
        let source = OnDemandYtDlp(directories: { [holder.path] })
        do {
            _ = try source.search("anything")
            expect(false, "expected a throw before yt-dlp exists")
        } catch ClipError.toolMissing {
        }

        let tool = holder.appendingPathComponent("yt-dlp")
        try Data("#!/bin/sh\necho '{\"entries\": []}'\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        expectEqual(try source.search("anything"), [])
    }

    test("a missing yt-dlp fails a stream request as toolMissing") {
        let source = OnDemandYtDlp(directories: { [] })
        do {
            _ = try source.stream(videoID: "dQw4w9WgXcQ")
            expect(false, "expected a throw")
        } catch ClipError.toolMissing {
        }
    }
}
```

In `Tests/main.swift`, register it after `trackTests()`:

```swift
trackTests()
onDemandYtDlpTests()
runAll()
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `./build.sh --test`
Expected: compile error `cannot find 'OnDemandYtDlp' in scope`.

- [ ] **Step 4: Add OnDemandYtDlp**

Append to `Clips/YtDlp.swift`:

```swift

/// yt-dlp may be installed while the app runs, so it is looked up on every call rather than
/// once at launch.
struct OnDemandYtDlp: ClipSource {
    var directories: () -> [String] = YtDlp.defaultDirectories

    func search(_ query: String) throws -> [Candidate] {
        try YtDlp(directories: directories()).search(query)
    }

    func stream(videoID: String) throws -> ClipStream {
        try YtDlp(directories: directories()).stream(videoID: videoID)
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `./build.sh --test`
Expected: `57 tests, 0 failures`, then `==> compiling resolve`.

- [ ] **Step 6: Rename the app's ClipStream and compile Clips into the app**

`Clips/YtDlp.swift` already declares `struct ClipStream { url, expires }`; the app's own `ClipStream` would clash once both are compiled together. In `App/AppDelegate.swift` replace every `ClipStream` with `StreamTarget` — exactly four places:

```swift
struct StreamTarget {
    let url: URL
    let position: TimeInterval
    let stillID: String
}
```
```swift
    private var stream: StreamTarget?
```
```swift
            startStream(StreamTarget(url: url, position: options.playAt, stillID: LaunchOptions.stillID(for: url)))
```
```swift
    private func startStream(_ target: StreamTarget) {
```

Check: `grep -n 'ClipStream' App/*.swift` prints nothing.

In `build.sh`, replace the app compile line:

```bash
    -o "$HERE/.build/${APP_NAME}" "$HERE"/App/*.swift
```
with:
```bash
    -o "$HERE/.build/${APP_NAME}" "$HERE"/App/*.swift "$HERE"/Clips/*.swift
```

Run: `./build.sh --dest .build/check`
Expected: ends with `==> built …/.build/check/Loopscape.app`; `./build.sh --dest .build/check 2>&1 | grep -c warning` prints `0`.

- [ ] **Step 7: Commit**

```bash
git add Clips/YtDlp.swift Tests/OnDemandYtDlpTests.swift Tests/main.swift App/AppDelegate.swift build.sh
git commit -m "compile the clip resolver into the app"
```

---

### Task 2: The clip mode state machine

**Files:**
- Create: `App/ClipMode.swift`, `Tests/ClipModeTests.swift`
- Modify: `Tests/main.swift`, `build.sh` (test compile line)

**Interfaces:**
- Consumes: `Track` (Part 1: `id`, `name`, `artist`, `duration`, `position`, `isPlaying`, memberwise init), `TrackQuery(id:artist:name:seconds:)` (Part 2).
- Produces, all used by Task 3:
  - `enum ResolveOutcome: Equatable { case found(videoID: String, url: URL); case notFound; case failed }`
  - `enum ClipEffect: Equatable { case resolve(TrackQuery, generation: Int); case play(videoID: String, url: URL, position: TimeInterval); case pause; case resume; case leave }`
  - `struct ClipMode` with `init(isEnabled: Bool, now: @escaping () -> Date = Date.init)`, `private(set) var isEnabled: Bool`, `var clipPlayback: (position: TimeInterval, paused: Bool)?`, `func isCurrent(_ generation: Int) -> Bool`, and the mutating event methods `setEnabled(_:)`, `trackChanged(_:)`, `resolved(_:generation:)`, `streamFailed()`, each returning `[ClipEffect]`.

Behaviour the tests pin, argued from the spec:
- A clip starts only for a **playing** track: Spotify's launch posts a `paused` event for its restored track, and "when nothing plays, Loopscape behaves exactly as it does today".
- A new track **playing** while a clip shows keeps the old clip until the new one resolves, then switches once (to the new clip, or to the pack) — one transition instead of clip → pack → clip.
- A new track that arrives **paused** (skip while paused) takes the clip off: nothing plays.
- `.missing` (no video / failed resolve) stays on the pack until the track changes: pause and resume of that track do nothing ("wallpaper does not flicker").
- A stream failure mid-clip gets one re-resolve (the spec's "then one re-resolve"; the resolver's URL cache already drops URLs within 10 min of expiry), then the pack.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClipModeTests.swift`:

```swift
import Foundation

private final class Clock {
    var now = Date(timeIntervalSince1970: 1_900_000_000)
}

func clipModeTests() {
    let url = URL(string: "https://manifest.googlevideo.com/api/manifest/hls_playlist/expire/1900003600/index.m3u8")!

    func track(_ id: String = "spotify:track:A", artist: String = "Daft Punk",
               at position: TimeInterval = 30, playing: Bool = true) -> Track {
        Track(id: id, name: "Get Lucky", artist: artist, duration: 248.4, position: position,
              isPlaying: playing)
    }

    func query(_ id: String = "spotify:track:A") -> TrackQuery {
        TrackQuery(id: id, artist: "Daft Punk", name: "Get Lucky", seconds: 248)
    }

    func showing() -> ClipMode {
        var mode = ClipMode(isEnabled: true)
        _ = mode.trackChanged(track())
        _ = mode.resolved(.found(videoID: "5NV6Rdv1a3I", url: url), generation: 1)
        return mode
    }

    test("with clips off a playing track is not searched") {
        var mode = ClipMode(isEnabled: false)
        expectEqual(mode.trackChanged(track()), [])
    }

    test("a playing track starts a resolve") {
        var mode = ClipMode(isEnabled: true)
        expectEqual(mode.trackChanged(track()), [.resolve(query(), generation: 1)])
    }

    test("a found clip plays from where the track is by now") {
        let clock = Clock()
        var mode = ClipMode(isEnabled: true, now: { clock.now })
        _ = mode.trackChanged(track(at: 30))
        clock.now += 4
        expectEqual(mode.resolved(.found(videoID: "5NV6Rdv1a3I", url: url), generation: 1),
                    [.play(videoID: "5NV6Rdv1a3I", url: url, position: 34)])
        expectEqual(mode.clipPlayback?.paused, false)
    }

    test("a track paused while resolving starts its clip paused where it stopped") {
        let clock = Clock()
        var mode = ClipMode(isEnabled: true, now: { clock.now })
        _ = mode.trackChanged(track(at: 30))
        clock.now += 2
        expectEqual(mode.trackChanged(track(at: 32, playing: false)), [])
        clock.now += 5
        expectEqual(mode.resolved(.found(videoID: "5NV6Rdv1a3I", url: url), generation: 1),
                    [.play(videoID: "5NV6Rdv1a3I", url: url, position: 32)])
        expectEqual(mode.clipPlayback?.paused, true)
        expectEqual(mode.clipPlayback?.position, 32)
    }

    test("only the last of several quick skips gets a clip") {
        let clock = Clock()
        var mode = ClipMode(isEnabled: true, now: { clock.now })
        for id in ["A", "B", "C", "D", "E"] { _ = mode.trackChanged(track("spotify:track:\(id)")) }
        expect(!mode.isCurrent(1), "the first skip's resolve must be voided")
        expect(mode.isCurrent(5), "the last skip's resolve must run")
        expectEqual(mode.resolved(.found(videoID: "first", url: url), generation: 1), [])
        expectEqual(mode.resolved(.found(videoID: "last", url: url), generation: 5),
                    [.play(videoID: "last", url: url, position: 30)])
    }

    test("a track without a video leaves the pack alone, paused or not") {
        var mode = ClipMode(isEnabled: true)
        _ = mode.trackChanged(track())
        expectEqual(mode.resolved(.notFound, generation: 1), [])
        expectEqual(mode.trackChanged(track(playing: false)), [])
        expectEqual(mode.trackChanged(track(playing: true)), [])
        expect(mode.clipPlayback == nil, "no clip is on screen")
    }

    test("the old clip stays until the next track resolves, then gives way if it has none") {
        var mode = showing()
        expectEqual(mode.trackChanged(track("spotify:track:B")),
                    [.resolve(query("spotify:track:B"), generation: 2)])
        expectEqual(mode.trackChanged(track("spotify:track:B", playing: false)), [.pause])
        expectEqual(mode.resolved(.failed, generation: 2), [.leave])
    }

    test("Spotify's pause and resume pause and resume the clip") {
        var mode = showing()
        expectEqual(mode.trackChanged(track(at: 40, playing: false)), [.pause])
        expectEqual(mode.trackChanged(track(at: 40, playing: true)), [.resume])
    }

    test("a stopped or quit Spotify, or a new track arriving paused, takes the clip off") {
        var stopped = showing()
        expectEqual(stopped.trackChanged(nil), [.leave])
        expectEqual(stopped.trackChanged(nil), [])

        var skippedWhilePaused = showing()
        expectEqual(skippedWhilePaused.trackChanged(track("spotify:track:B", playing: false)), [.leave])
    }

    test("ads, episodes, local files and tracks without an artist are never searched") {
        var mode = ClipMode(isEnabled: true)
        expectEqual(mode.trackChanged(track("spotify:ad:1")), [])
        expectEqual(mode.trackChanged(track("spotify:episode:1")), [])
        expectEqual(mode.trackChanged(track("spotify:local:::Demo:180")), [])
        expectEqual(mode.trackChanged(track("spotify:track:B", artist: "")), [])
    }

    test("a failed stream is re-resolved once, then left on the pack") {
        var mode = showing()
        expectEqual(mode.streamFailed(), [.resolve(query(), generation: 2)])
        expectEqual(mode.resolved(.found(videoID: "5NV6Rdv1a3I", url: url), generation: 2).count, 1)
        expectEqual(mode.streamFailed(), [])
        expect(mode.clipPlayback == nil, "no clip is on screen after the second failure")
    }

    test("switching clips off takes the clip down and voids the resolve in flight") {
        var mode = showing()
        _ = mode.trackChanged(track("spotify:track:B"))
        expectEqual(mode.setEnabled(false), [.leave])
        expectEqual(mode.resolved(.found(videoID: "b", url: url), generation: 2), [])
    }

    test("switching clips on mid-track, or playing a restored track, starts a resolve") {
        var mode = ClipMode(isEnabled: false)
        _ = mode.trackChanged(track())
        expectEqual(mode.setEnabled(true), [.resolve(query(), generation: 1)])

        var restored = ClipMode(isEnabled: true)
        expectEqual(restored.trackChanged(track(playing: false)), [])
        expectEqual(restored.trackChanged(track(playing: true)), [.resolve(query(), generation: 2)])
    }
}
```

In `Tests/main.swift`, register it after `onDemandYtDlpTests()`:

```swift
onDemandYtDlpTests()
clipModeTests()
runAll()
```

In `build.sh`, the test compile line gains `App/ClipMode.swift`. Replace:

```bash
        -o "$HERE/.build/tests" "$HERE"/Clips/*.swift "$HERE/App/LaunchOptions.swift" "$HERE/App/Track.swift" "$HERE"/Tests/*.swift
```
with:
```bash
        -o "$HERE/.build/tests" "$HERE"/Clips/*.swift "$HERE/App/LaunchOptions.swift" "$HERE/App/Track.swift" "$HERE/App/ClipMode.swift" "$HERE"/Tests/*.swift
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./build.sh --test`
Expected: compile error `error opening input file '…/App/ClipMode.swift'`.

- [ ] **Step 3: Write the state machine**

Create `App/ClipMode.swift`:

```swift
import Foundation

enum ResolveOutcome: Equatable {
    case found(videoID: String, url: URL)
    case notFound
    case failed
}

enum ClipEffect: Equatable {
    case resolve(TrackQuery, generation: Int)
    case play(videoID: String, url: URL, position: TimeInterval)
    case pause
    case resume
    case leave
}

struct ClipMode {
    private enum Phase: Equatable {
        case idle
        case resolving(trackID: String, generation: Int)
        case showing(trackID: String)
        case missing(trackID: String)
    }

    private(set) var isEnabled: Bool
    private var phase = Phase.idle
    private var generation = 0
    private var track: Track?
    private var trackSeen = Date.distantPast
    private var clipOnScreen = false
    private var retriedTrackID: String?
    private let now: () -> Date

    init(isEnabled: Bool, now: @escaping () -> Date = Date.init) {
        self.isEnabled = isEnabled
        self.now = now
    }

    var clipPlayback: (position: TimeInterval, paused: Bool)? {
        guard case .showing = phase, clipOnScreen, let track else { return nil }
        return (position(of: track), !track.isPlaying)
    }

    func isCurrent(_ generation: Int) -> Bool {
        if case .resolving(_, let current) = phase { return current == generation }
        return false
    }

    mutating func setEnabled(_ enabled: Bool) -> [ClipEffect] {
        guard enabled != isEnabled else { return [] }
        isEnabled = enabled
        guard enabled else { return leave() }
        guard let track, track.isPlaying else { return [] }
        return start(track)
    }

    mutating func trackChanged(_ new: Track?) -> [ClipEffect] {
        let sameTrack = new != nil && new?.id == track?.id
        track = new
        trackSeen = now()
        guard isEnabled else { return [] }
        guard let new else { return leave() }
        if sameTrack {
            switch phase {
            case .showing:
                return [new.isPlaying ? .resume : .pause]
            case .resolving:
                return clipOnScreen ? [new.isPlaying ? .resume : .pause] : []
            case .idle:
                return new.isPlaying ? start(new) : []
            case .missing:
                return []
            }
        }
        guard new.isPlaying else { return leave() }
        return start(new)
    }

    mutating func resolved(_ outcome: ResolveOutcome, generation: Int) -> [ClipEffect] {
        guard isCurrent(generation), case .resolving(let trackID, _) = phase,
              let track, track.id == trackID else { return [] }
        switch outcome {
        case .found(let videoID, let url):
            phase = .showing(trackID: trackID)
            clipOnScreen = true
            return [.play(videoID: videoID, url: url, position: position(of: track))]
        case .notFound, .failed:
            phase = .missing(trackID: trackID)
            return takeClipOff()
        }
    }

    /// Called after the wallpaper has already fallen back to the pack.
    mutating func streamFailed() -> [ClipEffect] {
        guard case .showing(let trackID) = phase, let track else { return [] }
        clipOnScreen = false
        guard retriedTrackID != trackID, let query = Self.query(for: track) else {
            phase = .missing(trackID: trackID)
            return []
        }
        retriedTrackID = trackID
        generation += 1
        phase = .resolving(trackID: trackID, generation: generation)
        return [.resolve(query, generation: generation)]
    }

    /// Ads, podcast episodes and local files have no music video to find, and the matcher
    /// rejects every candidate for an empty artist, so none of them is worth a yt-dlp run.
    private static func query(for track: Track) -> TrackQuery? {
        guard track.id.hasPrefix("spotify:track:"), !track.artist.isEmpty, track.duration > 0 else {
            return nil
        }
        return TrackQuery(id: track.id, artist: track.artist, name: track.name,
                          seconds: Int(track.duration.rounded()))
    }

    private mutating func start(_ track: Track) -> [ClipEffect] {
        generation += 1
        retriedTrackID = nil
        guard let query = Self.query(for: track) else {
            phase = .missing(trackID: track.id)
            return takeClipOff()
        }
        phase = .resolving(trackID: track.id, generation: generation)
        return [.resolve(query, generation: generation)]
    }

    private mutating func leave() -> [ClipEffect] {
        generation += 1
        phase = .idle
        return takeClipOff()
    }

    private mutating func takeClipOff() -> [ClipEffect] {
        guard clipOnScreen else { return [] }
        clipOnScreen = false
        return [.leave]
    }

    /// Spotify reports the position only when something changes, so a playing track's
    /// position is extrapolated from the last event.
    private func position(of track: Track) -> TimeInterval {
        track.isPlaying ? track.position + now().timeIntervalSince(trackSeen) : track.position
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `./build.sh --test`
Expected: `70 tests, 0 failures`, then `==> compiling resolve`.

Run: `./build.sh --dest .build/check 2>&1 | grep -E 'warning|built'`
Expected: only `==> built …/.build/check/Loopscape.app`.

- [ ] **Step 5: Commit**

```bash
git add App/ClipMode.swift Tests/ClipModeTests.swift Tests/main.swift build.sh
git commit -m "decide when the wallpaper follows Spotify"
```

---

### Task 3: Wire clip mode into the app and the menu

**Files:**
- Modify: `App/AppDelegate.swift`

**Interfaces:**
- Consumes: `ClipMode`, `ClipEffect`, `ResolveOutcome` (Task 2); `OnDemandYtDlp`, `StreamTarget` (Task 1); `ClipResolver(store:source:)`, `ClipStore(file:)`, `ClipResolution`, `YtDlp.locate(in:)`, `YtDlp.defaultDirectories()` (Part 2); `NowPlaying.onChange` (Part 1); `startStream(_:)`, `restartTimer()`, `startPlayback(_:)`, `syncDesktopPicture(_:)` (Part 3).
- Produces: the `spotifyClips` user default; log lines `clip: resolving <artist> — <name>`, `clip: <videoID> from <s> s`, `clip: no video for <artist> — <name>`, `clip: resolve failed: <error>`, `clip: back to the pack` (Task 4's live check greps these).

- [ ] **Step 1: State**

In `private enum Key`, add after `static let paused = "paused"`:

```swift
    static let paused = "paused"
    static let clips = "spotifyClips"
```

After `private let nowPlaying = NowPlaying()` add:

```swift
    private let nowPlaying = NowPlaying()
    private var clipMode = ClipMode(isEnabled: false)
    private var resolver: ClipResolver?
    private let clipQueue = DispatchQueue(label: "com.aklimoff.loopscape.clips")
```

Replace:

```swift
    private var isPaused: Bool { defaults.bool(forKey: Key.paused) }
```
with:
```swift
    private var isPaused: Bool { defaults.bool(forKey: Key.paused) }

    /// Spotify's pause holds a clip still the way the menu's Pause holds everything.
    private var shouldPlay: Bool { !isPaused && clipMode.clipPlayback?.paused != true }
```

- [ ] **Step 2: Launch wiring**

In `applicationDidFinishLaunching`, replace:

```swift
        nowPlaying.onChange = { [weak self] track in
            os_log("now playing: %{public}@", track.map {
                "\($0.menuTitle), \($0.isPlaying ? "playing" : "paused") at \(Int($0.position)) s"
            } ?? "nothing")
            self?.refreshMenu()
        }
        nowPlaying.start()
```
with:
```swift
        resolver = ClipResolver(store: ClipStore(file: root.appendingPathComponent("clips.json")),
                                source: OnDemandYtDlp())
        apply(clipMode.setEnabled(defaults.bool(forKey: Key.clips)))

        nowPlaying.onChange = { [weak self] track in
            guard let self else { return }
            os_log("now playing: %{public}@", track.map {
                "\($0.menuTitle), \($0.isPlaying ? "playing" : "paused") at \(Int($0.position)) s"
            } ?? "nothing")
            self.apply(self.clipMode.trackChanged(track))
            self.refreshMenu()
        }
        nowPlaying.start()
```

`root` is final by this point (read from defaults at the top of the method), and the folder exists (`createDirectory(at: wallpapersDirectory, withIntermediateDirectories: true)` above), which `ClipStore` needs because it never creates its parent.

- [ ] **Step 3: Respect Spotify's pause wherever playback restarts**

In `screensDidWake`, replace:

```swift
            if !isPaused { wallpapers.forEach { $0.resume() } }
```
with:
```swift
            if shouldPlay { wallpapers.forEach { $0.resume() } }
```

In `restorePlayback`, replace:

```swift
        if let stream {
            startStream(stream)
        } else if let slug = currentSlug {
```
with:
```swift
        if let stream {
            let position = clipMode.clipPlayback?.position ?? stream.position
            startStream(StreamTarget(url: stream.url, position: position, stillID: stream.stillID))
        } else if let slug = currentSlug {
```

In `startStream`, replace:

```swift
            wallpaper.play(stream: target.url, at: target.position)
        }
        if isPaused { wallpapers.forEach { $0.pause() } }
```
with:
```swift
            wallpaper.play(stream: target.url, at: target.position)
        }
        if !shouldPlay { wallpapers.forEach { $0.pause() } }
```

In `togglePause`, replace:

```swift
        } else {
            wallpapers.forEach { $0.resume() }
            repaintDesktopPicture()
        }
```
with:
```swift
        } else {
            if shouldPlay { wallpapers.forEach { $0.resume() } }
            repaintDesktopPicture()
        }
```

- [ ] **Step 4: Split leaving a stream out of the failure path**

Replace the whole `streamFailed` function:

```swift
    private func streamFailed(_ failure: StreamFailure) {
        guard stream != nil else { return }
        os_log("stream: %{public}@ — back to the pack", failure.description)
        stream = nil
        restartTimer()
        if let slug = currentSlug {
            startPlayback(slug)
            syncDesktopPicture(slug)
        } else if !packs.isEmpty {
            applySelection(pick())
        } else {
            wallpapers.forEach { $0.tearDown() }
            wallpapers = []
        }
    }
```
with:
```swift
    private func streamFailed(_ failure: StreamFailure) {
        guard stream != nil else { return }
        os_log("stream: %{public}@ — back to the pack", failure.description)
        leaveStream()
        apply(clipMode.streamFailed())
    }

    private func leaveStream() {
        guard stream != nil else { return }
        stream = nil
        restartTimer()
        if let slug = currentSlug {
            startPlayback(slug)
            syncDesktopPicture(slug)
        } else if !packs.isEmpty {
            applySelection(pick())
        } else {
            wallpapers.forEach { $0.tearDown() }
            wallpapers = []
        }
    }

    // MARK: - Spotify clips

    private func apply(_ effects: [ClipEffect]) {
        for effect in effects {
            switch effect {
            case .resolve(let query, let generation):
                resolveClip(query, generation: generation)
            case .play(let videoID, let url, let position):
                os_log("clip: %{public}@ from %{public}.1f s", videoID, position)
                startStream(StreamTarget(url: url, position: position, stillID: videoID))
            case .pause:
                if stream != nil { wallpapers.forEach { $0.pause() } }
            case .resume:
                if stream != nil, shouldPlay { wallpapers.forEach { $0.resume() } }
            case .leave:
                os_log("clip: back to the pack")
                leaveStream()
            }
        }
    }

    /// A resolve blocks for seconds, so resolves queue up behind each other during fast
    /// skipping; each one re-checks on main that it is still wanted before it starts, so the
    /// queue never works through a backlog of tracks that are already gone.
    private func resolveClip(_ query: TrackQuery, generation: Int) {
        guard let resolver else { return }
        clipQueue.async { [weak self] in
            let wanted = DispatchQueue.main.sync { self?.clipMode.isCurrent(generation) ?? false }
            guard wanted else { return }
            os_log("clip: resolving %{public}@ — %{public}@", query.artist, query.name)
            let outcome: ResolveOutcome
            do {
                switch try resolver.resolve(query) {
                case .stream(let videoID, let url): outcome = .found(videoID: videoID, url: url)
                case .none: outcome = .notFound
                }
            } catch {
                os_log("clip: resolve failed: %{public}@", String(describing: error))
                outcome = .failed
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if outcome == .notFound {
                    os_log("clip: no video for %{public}@ — %{public}@", query.artist, query.name)
                }
                self.apply(self.clipMode.resolved(outcome, generation: generation))
            }
        }
    }
```

- [ ] **Step 5: The menu checkbox and the install hint**

In `refreshMenu`, replace:

```swift
        menu.addItem(pause)
```
with:
```swift
        menu.addItem(pause)
        appendClipItems(to: menu)
```

In `appendEmptyState`, replace:

```swift
        menu.addItem(hint)
        menu.addItem(revealItem())
```
with:
```swift
        menu.addItem(hint)
        menu.addItem(revealItem())
        appendClipItems(to: menu)
```

Add directly above `private func appendEmptyState(to menu: NSMenu) {`:

```swift
    private func appendClipItems(to menu: NSMenu) {
        let clips = NSMenuItem(title: Lang.t("Spotify clips", "Клипы из Spotify"),
                               action: #selector(toggleClips), keyEquivalent: "")
        clips.target = self
        clips.state = clipMode.isEnabled ? .on : .off
        menu.addItem(clips)
        guard clipMode.isEnabled, YtDlp.locate(in: YtDlp.defaultDirectories()) == nil else { return }
        let hint = NSMenuItem(title: Lang.t("Needs yt-dlp: brew install yt-dlp",
                                            "Нужен yt-dlp: brew install yt-dlp"),
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

```

Add directly above `@objc private func nextPack() {`:

```swift
    @objc private func toggleClips() {
        let enabled = !clipMode.isEnabled
        defaults.set(enabled, forKey: Key.clips)
        apply(clipMode.setEnabled(enabled))
        refreshMenu()
    }

```

- [ ] **Step 6: Build and test**

Run: `./build.sh --test`
Expected: `70 tests, 0 failures`, then `==> compiling resolve`.

Run: `./build.sh --dest .build/check 2>&1 | grep -E 'warning|error|built'`
Expected: only `==> built …/.build/check/Loopscape.app`.

Run: `git diff now-playing -- LoopscapeSaver.swift Tests/Fixtures App/ScreenWallpaper.swift App/StreamSession.swift App/StreamStill.swift App/NowPlaying.swift App/Track.swift`
Expected: empty.

- [ ] **Step 7: Commit**

```bash
git add App/AppDelegate.swift
git commit -m "play the Spotify track's clip as the wallpaper"
```

---

### Task 4: Scenario run, README and spec

**Files:**
- Modify: `README.md`, `docs/superpowers/specs/2026-09-18-spotify-clips-design.md`

This drives the owner's Spotify and swaps the owner's installed app for the dev build, as Parts 0 and 1 did; everything is restored at the end. Every step's evidence is the `/usr/bin/log` output — report the literal lines. The spec's steps 6 (untick mid-clip), 8 (lock → saver) and 10 (`yt-dlp` out of reach) need a person at the screen or changes to the owner's Homebrew install; they go to the owner UX pass in Step 7, not here.

- [ ] **Step 1: Save the owner's state and start the dev build**

Run each line and write the three printed values into the report — shell state does not survive between commands:

```bash
defaults read com.aklimoff.loopscape paused
defaults read com.aklimoff.loopscape spotifyClips 2>/dev/null || echo absent
defaults read com.aklimoff.loopscape rotateMinutes
pgrep -x Spotify >/dev/null && echo spotify-running || echo spotify-not-running
```

```bash
defaults write com.aklimoff.loopscape paused -bool false
defaults write com.aklimoff.loopscape spotifyClips -bool true
defaults write com.aklimoff.loopscape rotateMinutes -int 5
osascript -e 'quit app "Loopscape"'; while pgrep -x Loopscape >/dev/null; do sleep 0.2; done; sleep 2
open -a "$PWD/.build/check/Loopscape.app"; sleep 3
stat -f '%Sm' ~/Library/Application\ Support/Loopscape/current.txt
```
Record the `current.txt` time: it must not change while a clip plays.

A `grep` helper for the steps below:

```bash
/usr/bin/log show --predicate 'process == "Loopscape" AND (eventMessage BEGINSWITH "clip:" OR eventMessage BEGINSWITH "now playing:" OR eventMessage BEGINSWITH "stream:")' --last 2m --style compact
```

- [ ] **Step 2: Scenario 1 — a track with a video**

```bash
open -g -a Spotify; until osascript -e 'tell application "Spotify" to get player state' >/dev/null 2>&1; do sleep 1; done; sleep 4
osascript -e 'tell application "Spotify" to play'; sleep 15
```
Expected in the log: `now playing: … playing at N s`, `clip: resolving …`, `clip: <videoID> from <≈N+elapsed> s`, `stream: first frame after … s, still written`. Pass: the `clip: <videoID>` line comes ≤ ~8 s after the `now playing` line (resolve ≤ 8 s per Part 2), the first frame ≤ 2 s after that. If the track logs `clip: no video for …`, press `next track` until one has a video, and report which.

- [ ] **Step 3: Scenario 4 — pause and resume**

```bash
osascript -e 'tell application "Spotify" to pause'; sleep 3
/usr/bin/log show --predicate 'process == "Loopscape"' --last 3s --style compact | grep -o 'timebase time: [0-9.]* s rate: [0-9.]*' | tail -1
osascript -e 'tell application "Spotify" to play'; sleep 5
/usr/bin/log show --predicate 'process == "Loopscape"' --last 3s --style compact | grep -o 'timebase time: [0-9.]* s rate: [0-9.]*' | tail -1
```
Expected: `rate: 0.00` after the pause, `rate: 1.00` after the resume (if a sample is missing, widen `--last` to 6s). No `clip: resolving` line for the resume.

- [ ] **Step 4: Scenario 2 — five quick skips**

```bash
for i in 1 2 3 4 5; do osascript -e 'tell application "Spotify" to next track'; sleep 0.5; done; sleep 20
```
Expected: five `now playing:` lines; `clip: resolving` for at most the first and the last of them (`resolving` is logged only once a queued resolve has passed its still-wanted check, so the voided ones leave no line); exactly one `clip: <videoID> from` line after the skips, and it belongs to the last track (or `clip: no video for` the last track and then `clip: back to the pack`). No clip line for an intermediate track.

- [ ] **Step 5: Scenario 3 — a track without a video, and scenario 7 — rotation**

Mark the currently loaded track as having no video through the mapping file (the file is the manual override and is read on every resolve), then skip back to it:

```bash
TRACK=$(osascript -e 'tell application "Spotify" to get id of current track'); echo $TRACK
osascript -e 'tell application "Spotify" to next track'; sleep 12
python3 - "$TRACK" <<'EOF'
import json, os, sys, datetime
p = os.path.expanduser("~/Library/Application Support/Loopscape/clips.json")
d = json.load(open(p)) if os.path.exists(p) else {}
d[sys.argv[1]] = {"checked": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
EOF
osascript -e 'tell application "Spotify" to previous track'; sleep 1; osascript -e 'tell application "Spotify" to previous track'; sleep 10
osascript -e 'tell application "System Events" to tell current desktop to get picture'
```
Expected: the last `now playing:` names `$TRACK`'s title; for it `clip: resolving …` and, within a second (the mapping answers without running yt-dlp), `clip: no video for …`, then `clip: back to the pack` (the previous track's clip gives way), no `clip: … from` line for it, and the desktop picture is a pack poster from `Wallpapers/`, not a still from `stills/`. (Spotify's first `previous track` restarts the current track; the second goes back one.) Then remove the seeded entry:

```bash
python3 - "$TRACK" <<'EOF'
import json, os, sys
p = os.path.expanduser("~/Library/Application Support/Loopscape/clips.json")
d = json.load(open(p)); d.pop(sys.argv[1], None); json.dump(d, open(p, "w"), indent=2, sort_keys=True)
EOF
```

Rotation: skip to a track with a clip (`next track` until a `clip: … from` line appears), leave it playing for 6 minutes, and check `stat -f '%Sm' ~/Library/Application\ Support/Loopscape/current.txt` is unchanged since Step 1 — the 5-minute rotation did not fire during the clip. Spotify loops nothing, so if the track ends and the next one plays, that is fine; a `clip: back to the pack` between tracks without a video is fine too — report it.

- [ ] **Step 6: Scenario 5 — quit Spotify; restore**

```bash
osascript -e 'quit app "Spotify"'; while pgrep -x Spotify >/dev/null; do sleep 0.5; done; sleep 3
```
Expected: `now playing: nothing`, then `clip: back to the pack`. Then wait 6 minutes and check `current.txt`'s time **has** changed — rotation resumed after the clip.

Restore the owner's state with the values recorded in Step 1 (if `spotifyClips` was `absent`, delete it; the installed app is still 2.0 without clips, and the key is harmless, but restore anyway):

```bash
defaults write com.aklimoff.loopscape paused -bool <recorded>
defaults delete com.aklimoff.loopscape spotifyClips   # or write the recorded value
defaults write com.aklimoff.loopscape rotateMinutes -int <recorded>
osascript -e 'quit app "Loopscape"'; while pgrep -x Loopscape >/dev/null; do sleep 0.2; done; sleep 2
open -a /Applications/Loopscape.app
```
If Spotify was running in Step 1, leave it quit and say so in the report — relaunching it would start playback state the owner did not choose.

Scenario 9 (launched with `open`, not a terminal) holds for every launch above: the dev build was always started with `open -a`, so a resolve that worked proves `yt-dlp` and `deno` were found without the shell's `PATH`.

- [ ] **Step 7: README and spec**

In `README.md`, insert a section directly above `## Lock screen`:

```markdown
## Spotify clips

With **Spotify clips** ticked in the menu, the track playing in the Spotify desktop app
brings its music video onto every display, from where the track is. Pause in Spotify
pauses the video; skip, stop or quit, or a track without a video, and the regular packs
come back. It is off by default.

It needs `yt-dlp` from Homebrew (`brew install yt-dlp`, which also installs the `deno`
runtime it uses); the menu says so when it cannot find it. Videos are found on YouTube and
streamed, never downloaded; the only thing kept on disk is which video belongs to which
track, in `clips.json` beside the wallpapers folder — edit an entry there to correct a
wrong match, or delete it to search again.

**Terms of service:** fetching video from YouTube through `yt-dlp` is against YouTube's
terms of service. The feature ships switched off; turning it on is your call.

Limitations: Loopscape learns about a track from Spotify's play/pause/skip events, so one
started before Loopscape shows up at the next such event; scrubbing within a track is not
followed.
```

In `README.md`'s `## Menu` section, replace:

```markdown
30 / 60 minutes, or off), jump to the next one, open the wallpapers folder, toggle **Launch at
login**, quit.
```
with:
```markdown
30 / 60 minutes, or off), jump to the next one, open the wallpapers folder, toggle **Spotify
clips** and **Launch at login**, quit.
```

In the spec:
- Under "### Part 4 — glue and menu", append a paragraph `Result (<date>, Spotify <version>, yt-dlp <version>):` with one sentence per scenario run in Steps 2–6: the timings from the log (track event → `clip:` line → first frame), what the skips produced, the no-video track, the `current.txt` times for rotation, and quit.
- Under "### Glue", append a bullet: `- The mode machine is `App/ClipMode.swift`, pure and unit-tested: a clip starts only for a playing track; a new track keeps the old clip until it resolves, then switches once; a new track arriving paused, stop, quit or the checkbox off take the clip down; a failed stream is re-resolved once.`
- In "### Owner UX pass (before `v2.0`)", after the "Deferred from Part 1:" list, add:

```markdown
Deferred from Part 4:

- Untick "Spotify clips" mid-clip: the pack returns at once.
- Lock the Mac during a clip: the screen saver plays a regular pack.
- With `yt-dlp` out of reach (e.g. `brew unlink yt-dlp`), the menu shows the install hint and
  nothing crashes; after `brew link yt-dlp` the hint is gone at the next menu open.
- The "Spotify clips" checkbox and hint by eye, in English and Russian.
- The switch between tracks: the old clip keeps playing for the few seconds the next one
  resolves — acceptable, or show the pack meanwhile.
- A scrub in Spotify: the clip keeps its own time — acceptable for 2.0, or poll the position.
```

Commit:

```bash
git add README.md docs/superpowers/specs/2026-09-18-spotify-clips-design.md
git commit -m "document spotify clips and record the scenario run"
```

---

## Done when

- `./build.sh --test` prints `70 tests, 0 failures`; `./build.sh --dest .build/check` builds with no warnings; the untouched-files diff is empty.
- With clips on and the dev build running, a playing Spotify track brings its clip within ~8 s, Spotify's pause pauses it, skips settle on the last track, a no-video track leaves the pack alone, quitting Spotify brings the pack back, and rotation neither interrupts a clip nor stays off after it.
- README documents the feature, the `yt-dlp` dependency and the terms-of-service note; the spec records the run and the owner UX items.
