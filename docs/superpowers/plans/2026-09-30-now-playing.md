# NowPlaying (Spotify clips, Part 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app learns what the Spotify desktop client is playing from `com.spotify.client.PlaybackStateChanged` and shows a disabled "♪ Artist — Title" line at the top of its menu while a track is known.

**Architecture:** `App/Track.swift` is pure Foundation: a `Track` value and its parser from Spotify's `userInfo`, plus the menu title — compiled into the test binary. `App/NowPlaying.swift` observes the distributed notification and Spotify's termination, keeps the latest `Track?` and calls `onChange`. `AppDelegate` owns one `NowPlaying`, logs every change with `os_log` and rebuilds the menu, which puts the line above everything else. No clip logic — that is Part 4.

**Tech Stack:** Swift 5 via plain `swiftc` (no package manager, no Xcode), Foundation, AppKit, `os`; the hand-rolled test harness in `Tests/`.

**Spec:** `docs/superpowers/specs/2026-09-18-spotify-clips-design.md` — sections "Spike measurements" (Part 0 result), "Architecture" → "NowPlaying", "Glue" (menu line only), "Part 1 — NowPlaying", "Owner UX pass".

## Global Constraints

- Compiler flags everywhere: `-swift-version 5 -target arm64-apple-macosx13.0`. No package manager, no third-party Swift code.
- `VERSION="2.0"` in `build.sh` and `make-dmg.sh` already; no tag, no DMG (those come after Part 4).
- `LoopscapeSaver.swift`, everything under `Clips/`, `Tools/` and `Tests/Fixtures/` stay untouched. Streaming code (`App/ScreenWallpaper.swift`, `App/StreamSession.swift`, `App/StreamStill.swift`) stays untouched.
- No permissions, no polling, no OAuth, no AppleScript in the app: only `DistributedNotificationCenter` and `NSWorkspace` notifications.
- Spotify's `userInfo`: `Duration` is milliseconds, `Playback Position` is seconds, numbers arrive as `NSNumber`. A seek posts nothing. The first `play` after Spotify launches posts a stale event for the previous session's track, then the real one ~3 ms later.
- Accepted limitation: Loopscape launched mid-track shows no line until the next play/pause/skip.
- Every existing behaviour of packs, rotation, pause, spaces, sleep/wake, streaming and the screen saver stays as it is.
- Comments: none by default. Only a comment that answers a "why" the code cannot show is allowed; the ones in this plan are of that kind — copy them as written, add no others.
- Commits: one short imperative English subject line, no body unless it explains a "why", and no LLM attribution of any kind (no `Co-Authored-By`, no "Generated with").
- Stage files by explicit path. `.omc/`, `.build/`, `.superpowers/` are untracked and stay that way.
- Branch: `now-playing`, forked from `clip-playback` at the commit `record streaming playback measurements`. Work in place on this checkout.
- Test totals: `./build.sh --test` prints `49 tests, 0 failures` at the start and `55 tests, 0 failures` from Task 1 on, then `==> compiling resolve`.
- In zsh a bare `log` is a builtin: always call `/usr/bin/log`.

## Review Focus

- A `Stopped` event, or one without a track id or name, hides the line instead of showing "♪  — ".
- A local file or a podcast has an empty artist → the line shows the name alone, no dangling dash.
- A 150-character classical title → the line is cut to 60 characters with "…", the menu stays narrow.
- Spotify quits while a track is shown → the line disappears without waiting for another event.
- `Duration` as an integer `NSNumber` and `Playback Position` as a floating one (the real payload) both parse; a Swift `Double` boxed in `Any` parses too.

---

### Task 1: Parse Spotify's state into a Track

**Files:**
- Create: `App/Track.swift`, `Tests/TrackTests.swift`
- Modify: `Tests/main.swift` (register `trackTests()`), `build.sh` (test compile line)

**Interfaces:**
- Consumes: nothing new.
- Produces: `struct Track: Equatable { let id: String; let name: String; let artist: String; let duration: TimeInterval; let position: TimeInterval; let isPlaying: Bool }` with the memberwise init, `init?(spotifyInfo: [AnyHashable: Any])`, and `var menuTitle: String`.

- [ ] **Step 1: Branch**

```bash
git switch -c now-playing clip-playback
git log --oneline -1
```
Expected: the head is `record streaming playback measurements`. If it is not, stop and report.

```bash
git add docs/superpowers/plans/2026-09-30-now-playing.md
git commit -m "add now playing plan"
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/TrackTests.swift`:

```swift
import Foundation

func trackTests() {
    let playing: [AnyHashable: Any] = [
        "Album": "Hybrid Theory (Bonus Edition)",
        "Artist": "Linkin Park",
        "Duration": NSNumber(value: 216880),
        "Name": "In the End",
        "Playback Position": NSNumber(value: 0.013),
        "Player State": "Playing",
        "Track ID": "spotify:track:60a0Rd6pjrkxjPbaKzXjfq",
    ]

    test("a playing Spotify event becomes a track") {
        expectEqual(Track(spotifyInfo: playing),
                    Track(id: "spotify:track:60a0Rd6pjrkxjPbaKzXjfq", name: "In the End",
                          artist: "Linkin Park", duration: 216.88, position: 0.013, isPlaying: true))
    }

    test("a paused event keeps the track and says it is paused") {
        var paused = playing
        paused["Player State"] = "Paused"
        paused["Playback Position"] = NSNumber(value: 2.3)
        let track = Track(spotifyInfo: paused)
        expectEqual(track?.isPlaying, false)
        expectEqual(track?.position, 2.3)
    }

    test("a stopped player, an unknown state or a missing id or name is no track") {
        var stopped = playing
        stopped["Player State"] = "Stopped"
        expectEqual(Track(spotifyInfo: stopped), nil)
        var unknown = playing
        unknown["Player State"] = "Buffering"
        expectEqual(Track(spotifyInfo: unknown), nil)
        var nameless = playing
        nameless["Name"] = ""
        expectEqual(Track(spotifyInfo: nameless), nil)
        var idless = playing
        idless.removeValue(forKey: "Track ID")
        expectEqual(Track(spotifyInfo: idless), nil)
        expectEqual(Track(spotifyInfo: [:]), nil)
    }

    test("numbers are read whether they arrive as integers or doubles") {
        var info = playing
        info["Duration"] = 157000.0
        info["Playback Position"] = 63
        let track = Track(spotifyInfo: info)
        expectEqual(track?.duration, 157)
        expectEqual(track?.position, 63)
    }

    test("the menu title names the artist and the track") {
        let track = Track(id: "spotify:track:74rl89i6GlqWwOFVlBtEh9", name: "Младшая сестра",
                          artist: "Дора", duration: 222.223, position: 0, isPlaying: true)
        expectEqual(track.menuTitle, "♪ Дора — Младшая сестра")
        let local = Track(id: "spotify:local:::Demo:180", name: "Demo", artist: "",
                          duration: 180, position: 0, isPlaying: false)
        expectEqual(local.menuTitle, "♪ Demo")
    }

    test("a long title is cut to fit the menu") {
        let track = Track(id: "spotify:track:long", name: String(repeating: "Allegro ", count: 20),
                          artist: "Wiener Philharmoniker", duration: 600, position: 0, isPlaying: true)
        expectEqual(track.menuTitle.count, 62)
        expect(track.menuTitle.hasSuffix("…"), "got \(track.menuTitle)")
        expect(track.menuTitle.hasPrefix("♪ Wiener Philharmoniker — Allegro"), "got \(track.menuTitle)")
    }
}
```

In `Tests/main.swift`, add `trackTests()` after `launchOptionsTests()`:

```swift
launchOptionsTests()
trackTests()
runAll()
```

In `build.sh`, the test compile line gains `App/Track.swift`. Replace:

```bash
        -o "$HERE/.build/tests" "$HERE"/Clips/*.swift "$HERE/App/LaunchOptions.swift" "$HERE"/Tests/*.swift
```
with:
```bash
        -o "$HERE/.build/tests" "$HERE"/Clips/*.swift "$HERE/App/LaunchOptions.swift" "$HERE/App/Track.swift" "$HERE"/Tests/*.swift
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `./build.sh --test`
Expected: the compile fails with `error: no such file or directory: '…/App/Track.swift'` (the file does not exist yet).

- [ ] **Step 4: Write the implementation**

Create `App/Track.swift`:

```swift
import Foundation

struct Track: Equatable {
    let id: String
    let name: String
    let artist: String
    let duration: TimeInterval
    let position: TimeInterval
    let isPlaying: Bool

    private static let menuTitleLimit = 60

    var menuTitle: String {
        let label = artist.isEmpty ? name : "\(artist) — \(name)"
        guard label.count > Self.menuTitleLimit else { return "♪ " + label }
        return "♪ " + label.prefix(Self.menuTitleLimit - 1) + "…"
    }
}

extension Track {
    /// Spotify's PlaybackStateChanged payload: `Duration` is in milliseconds while
    /// `Playback Position` is in seconds.
    init?(spotifyInfo info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String
        guard state == "Playing" || state == "Paused",
              let id = info["Track ID"] as? String, !id.isEmpty,
              let name = info["Name"] as? String, !name.isEmpty else { return nil }
        self.init(id: id,
                  name: name,
                  artist: info["Artist"] as? String ?? "",
                  duration: ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                  position: (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0,
                  isPlaying: state == "Playing")
    }
}
```

The init lives in an extension so the struct keeps its memberwise init, which the tests and Part 4 use.

- [ ] **Step 5: Run the tests to see them pass**

Run: `./build.sh --test`
Expected: `55 tests, 0 failures`, then `==> compiling resolve`.

Then check the app still builds (it compiles `App/*.swift`, so `Track.swift` is in it):

Run: `./build.sh --dest .build/check`
Expected: ends with `==> built …/.build/check/Loopscape.app`, no warnings.

- [ ] **Step 6: Commit**

```bash
git add App/Track.swift Tests/TrackTests.swift Tests/main.swift build.sh
git commit -m "parse Spotify's playback state into a track"
```

---

### Task 2: Follow Spotify and show the track in the menu

**Files:**
- Create: `App/NowPlaying.swift`
- Modify: `App/AppDelegate.swift` (a `nowPlaying` property, wiring in `applicationDidFinishLaunching`, `refreshMenu`, a new `appendNowPlaying(to:)`), `docs/superpowers/specs/2026-09-18-spotify-clips-design.md` (Part 1 result, one Owner UX pass line)

**Interfaces:**
- Consumes: `Track`, `Track(spotifyInfo:)`, `Track.menuTitle` from Task 1.
- Produces: `final class NowPlaying { private(set) var track: Track?; var onChange: ((Track?) -> Void)?; func start() }` — Part 4's glue subscribes through `onChange` and reads `track`.

- [ ] **Step 1: Write NowPlaying**

Create `App/NowPlaying.swift`:

```swift
import AppKit

final class NowPlaying {
    private static let spotifyBundleID = "com.spotify.client"
    private static let stateChanged = Notification.Name("com.spotify.client.PlaybackStateChanged")

    private(set) var track: Track?
    var onChange: ((Track?) -> Void)?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(
            forName: Self.stateChanged, object: nil, queue: .main
        ) { [weak self] note in
            self?.update(Track(spotifyInfo: note.userInfo ?? [:]))
        }))

        // A crash or a force quit posts no Stopped event, so Spotify's termination clears the line.
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.spotifyBundleID else { return }
            self?.update(nil)
        }))
    }

    deinit {
        observers.forEach { $0.center.removeObserver($0.token) }
    }

    private func update(_ new: Track?) {
        guard new != track else { return }
        track = new
        onChange?(new)
    }
}
```

- [ ] **Step 2: Wire it into AppDelegate**

In `App/AppDelegate.swift`, add the property after `private let options: LaunchOptions`:

```swift
    private let options: LaunchOptions
    private let nowPlaying = NowPlaying()
```

In `applicationDidFinishLaunching`, replace:

```swift
        buildStatusItem()
        reloadLibrary()
        watchLibrary()
```
with:
```swift
        buildStatusItem()
        reloadLibrary()
        watchLibrary()

        nowPlaying.onChange = { [weak self] track in
            os_log("now playing: %{public}@", track.map {
                "\($0.menuTitle), \($0.isPlaying ? "playing" : "paused") at \(Int($0.position)) s"
            } ?? "nothing")
            self?.refreshMenu()
        }
        nowPlaying.start()
```

In `refreshMenu()`, replace:

```swift
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        guard !packs.isEmpty else {
```
with:
```swift
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        appendNowPlaying(to: menu)

        guard !packs.isEmpty else {
```

Add the helper directly above `private func appendEmptyState(to menu: NSMenu) {`:

```swift
    private func appendNowPlaying(to menu: NSMenu) {
        guard let track = nowPlaying.track else { return }
        let item = NSMenuItem(title: track.menuTitle, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        menu.addItem(.separator())
    }

```

- [ ] **Step 3: Build and test**

Run: `./build.sh --test`
Expected: `55 tests, 0 failures`, then `==> compiling resolve`.

Run: `./build.sh --dest .build/check`
Expected: ends with `==> built …/.build/check/Loopscape.app`, no warnings.

Run: `git diff clip-playback -- LoopscapeSaver.swift Clips Tools Tests/Fixtures App/ScreenWallpaper.swift App/StreamSession.swift App/StreamStill.swift`
Expected: empty.

- [ ] **Step 4: Commit the code**

```bash
git add App/NowPlaying.swift App/AppDelegate.swift
git commit -m "show the Spotify track in the menu"
```

- [ ] **Step 5: Live check against the real Spotify client**

This drives the owner's Spotify with AppleScript — a few seconds of music, the owner agreed to it for Part 0. Record whether Spotify was running first and restore that at the end. Swap the installed app for the dev build, and swap it back at the end.

```bash
SPOTIFY_WAS_RUNNING=$(pgrep -x Spotify >/dev/null && echo 1 || echo 0)
osascript -e 'quit app "Loopscape"'; while pgrep -x Loopscape >/dev/null; do sleep 0.2; done; sleep 2
open -a "$PWD/.build/check/Loopscape.app"
open -g -a Spotify; until osascript -e 'tell application "Spotify" to get player state' >/dev/null 2>&1; do sleep 1; done; sleep 4
S='tell application "Spotify" to'
for action in play pause play "next track" pause; do osascript -e "$S $action" >/dev/null; sleep 4; done
osascript -e 'quit app "Spotify"'; while pgrep -x Spotify >/dev/null; do sleep 0.5; done; sleep 2
/usr/bin/log show --predicate 'process == "Loopscape" AND eventMessage BEGINSWITH "now playing:"' --last 2m --style compact
```

Expected, in order: one line per action — `playing`, `paused`, `playing`, a different track `playing`, `paused` — each within a second of its action (the timestamps), and a final `now playing: nothing` after Spotify quits. The stale event right after Spotify's launch may add one extra `playing` line for the previous session's track; note it, it is not a failure. Report the literal lines.

Then launch-mid-track (the accepted limitation, confirmed rather than assumed):

```bash
open -g -a Spotify; until osascript -e 'tell application "Spotify" to get player state' >/dev/null 2>&1; do sleep 1; done; sleep 4
osascript -e "$S play"; sleep 3
osascript -e 'quit app "Loopscape"'; while pgrep -x Loopscape >/dev/null; do sleep 0.2; done; sleep 2
open -a "$PWD/.build/check/Loopscape.app"; sleep 5
/usr/bin/log show --predicate 'process == "Loopscape" AND eventMessage BEGINSWITH "now playing:"' --last 5s --style compact
osascript -e "$S pause"; sleep 2
/usr/bin/log show --predicate 'process == "Loopscape" AND eventMessage BEGINSWITH "now playing:"' --last 3s --style compact
```

Expected: no `now playing:` line in the first 5 s after the relaunch; one `paused` line after the pause.

Restore:

```bash
[ "$SPOTIFY_WAS_RUNNING" = 0 ] && { osascript -e 'quit app "Spotify"'; while pgrep -x Spotify >/dev/null; do sleep 0.5; done; }
osascript -e 'quit app "Loopscape"'; while pgrep -x Loopscape >/dev/null; do sleep 0.2; done; sleep 2
open -a /Applications/Loopscape.app
```

- [ ] **Step 6: Record the result in the spec**

In `docs/superpowers/specs/2026-09-18-spotify-clips-design.md`:

- Under "### Part 1 — NowPlaying", append a paragraph `Result (<date>, Spotify <version from Part 0 or `defaults read /Applications/Spotify.app/Contents/Info.plist CFBundleShortVersionString`>):` with the measured delay from action to log line, whether quit clears the line, and the launch-mid-track observation — one sentence each, facts only.
- In "### Owner UX pass (before `v2.0`)", directly after the "Deferred from Part 3:" list, add a line `Deferred from Part 1:`, a blank line, and one bullet: `- The "♪ Artist — Title" line by eye: at the top of the menu, disabled, follows skip, pause and quit when the menu is reopened; long titles end in "…".`

```bash
git add docs/superpowers/specs/2026-09-18-spotify-clips-design.md
git commit -m "record now playing results"
```

---

## Done when

- `./build.sh --test` prints `55 tests, 0 failures`; `./build.sh --dest .build/check` builds with no warnings; the untouched-files diff is empty.
- With the dev build running, every Spotify play, pause and skip logs a `now playing:` line within a second, and quitting Spotify logs `now playing: nothing`.
- The spec records the Part 1 result and the menu line's owner check.
