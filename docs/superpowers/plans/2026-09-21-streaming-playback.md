# Streaming Playback (Spotify clips, Part 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the app to play a remote HLS URL on every display — start at a position, loop, report failure — and drive it from debug launch arguments so Part 3 is verified without Spotify.

**Architecture:** `Loopscape.swift` is split into `App/main.swift` (entry point), `App/AppDelegate.swift` and `App/ScreenWallpaper.swift`, and `build.sh` compiles `App/*.swift`. Streaming is a second playback mode of `ScreenWallpaper`: a `StreamSession` keeps two `AVPlayerItem`s of the same URL queued on the existing `AVQueuePlayer` so the loop seam is pre-buffered, watches item status and stalls, and reports a `StreamFailure`; `StreamStill` grabs one frame through `AVPlayerItemVideoOutput` for the menu-bar strip. `AppDelegate` gains a `Stream` state next to `currentSlug`, starts a stream from `LaunchOptions` (`--play-url`, `--play-at`), re-establishes it on display changes, and falls back to the regular pack on failure. No mode machine yet — that is Part 4.

**Tech Stack:** Swift 5 via plain `swiftc` (no package manager, no Xcode), AppKit, AVFoundation, CryptoKit; the existing hand-rolled test harness in `Tests/`.

**Spec:** `docs/superpowers/specs/2026-09-18-spotify-clips-design.md` — sections "Architecture", "Streaming in ScreenWallpaper", "Glue" (only what Part 3 needs), "Part 3 — streaming playback", "Versioning".

## Global Constraints

- Compiler flags everywhere: `-swift-version 5 -target arm64-apple-macosx13.0`. No package manager, no third-party Swift code.
- `VERSION="2.0"` in `build.sh` and `make-dmg.sh` from the first commit that changes the app binary (Task 1). No tag, no DMG: those come after Part 4.
- `LoopscapeSaver.swift`, everything under `Clips/`, `Tools/` and `Tests/Fixtures/` stay untouched. `current.txt` keeps naming only regular packs — a stream is never written there.
- Stills for streams live at `~/Library/Caches/<bundle id>/stills/<id>.jpg`, one file per id; an existing still is reused, never rewritten (the wallpaper agent caches by URL).
- A stall longer than `ScreenWallpaper.stallTimeout` (20 s) or a failed item ends on the regular pack — never on black or a frozen frame. Pass criterion: first frame ≤ 2 s.
- Every existing behaviour of packs, rotation, pause, spaces, sleep/wake and the screen saver stays as it is; Task 1 is a pure move of code.
- Comments: none by default. Only a comment that answers a "why" the code cannot show is allowed; the ones in this plan are of that kind — copy them as written, add no others. Existing comments move with their code.
- Commits: one short imperative English subject line, no body unless it explains a "why", and no LLM attribution of any kind (no `Co-Authored-By`, no "Generated with").
- Stage files by explicit path. `.omc/`, `.build/`, `.superpowers/` are untracked and stay that way.
- Branch: `clip-playback`, forked from `clip-resolver` (both edit `build.sh`; Part 4 needs both). Work in place on this checkout, as Part 2 did.
- Test totals: `./build.sh --test` prints `44 tests, 0 failures` at the start and `49 tests, 0 failures` from Task 2 on, then `==> compiling resolve`.

---

### Task 1: Split the app into three sources and open the 2.0 line

**Files:**
- Create: `App/main.swift`, `App/ScreenWallpaper.swift`
- Move: `Loopscape.swift` → `App/AppDelegate.swift`
- Modify: `build.sh:10` (`VERSION`), `build.sh:47-48` (app compile line), `make-dmg.sh:5` (`VERSION`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `App/ScreenWallpaper.swift` holding `PlayerView` and `ScreenWallpaper` unchanged (`init(screen:)`, `play(_:)`, `pause()`, `resume()`, `raise()`, `align(to:)`, `tearDown()`); `App/AppDelegate.swift` holding `defaultRoot`, `Key`, `Lang`, `Pack`, `AppDelegate` unchanged; `App/main.swift` holding the single-instance guard and `NSApplication` start. `build.sh` compiles `App/*.swift`.

- [ ] **Step 1: Branch**

The branch `clip-playback` was forked from `clip-resolver` when this plan was committed; work happens on it in place.

```bash
git switch clip-playback
git log --oneline -2
```
Expected: the head is `add streaming playback plan`, directly above `06e8c93 record measured clip resolve timings`.

- [ ] **Step 2: Move the code without editing it**

The line numbers below are those of `Loopscape.swift` at the branch point: `PlayerView` and `ScreenWallpaper` occupy lines 36–114 (the `///` comment above `PlayerView` through the closing brace of `ScreenWallpaper`), line 115 is blank, `AppDelegate` runs 116–687, line 688 is blank, and the top-level entry code is 689–701. Check them before cutting:

```bash
sed -n '36p;37p;114p;116p;687p;689p;701p' Loopscape.swift
```
Expected, one per line: the `/// AVPlayerLayer as the view's backing layer…` comment, `final class PlayerView: NSView {`, `}`, `final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {`, `}`, `// launchd's RunAtLoad and a manual launch can race; a second instance would stack`, `app.run()`. If any line differs, stop and report — do not guess new numbers.

```bash
mkdir -p App
git mv Loopscape.swift App/AppDelegate.swift
{ printf 'import AppKit\nimport AVFoundation\n\n'; git show HEAD:Loopscape.swift | sed -n '36,114p'; } > App/ScreenWallpaper.swift
{ printf 'import AppKit\n\n'; git show HEAD:Loopscape.swift | sed -n '689,701p'; } > App/main.swift
sed -i '' '688,701d;36,115d' App/AppDelegate.swift
```

- [ ] **Step 3: Prove it is a pure move**

Reassemble the original from the three pieces and compare it byte for byte:

```bash
{ sed -n '1,35p' App/AppDelegate.swift; tail -n +4 App/ScreenWallpaper.swift; echo; sed -n '36,$p' App/AppDelegate.swift; echo; tail -n +3 App/main.swift; } | diff - <(git show HEAD:Loopscape.swift) && echo "pure move"
```
Expected: `pure move` and no diff lines.

- [ ] **Step 4: Build all app sources and open 2.0**

In `build.sh` change `VERSION="1.6"` to `VERSION="2.0"` and replace the app compile line

```bash
    -o "$HERE/.build/${APP_NAME}" "$HERE/${APP_NAME}.swift"
```
with
```bash
    -o "$HERE/.build/${APP_NAME}" "$HERE"/App/*.swift
```
In `make-dmg.sh` change `VERSION="1.6"` to `VERSION="2.0"`.

- [ ] **Step 5: Verify**

```bash
./build.sh --dest .build/check
./build.sh --test
grep -n 'VERSION=' build.sh make-dmg.sh
git status --short
```
Expected: `==> built .build/check/Loopscape.app` with no compiler diagnostics; `44 tests, 0 failures` then `==> compiling resolve`; both `VERSION="2.0"`; status shows `R  Loopscape.swift -> App/AppDelegate.swift`, `A  App/ScreenWallpaper.swift`, `A  App/main.swift` (after `git add App`), ` M build.sh`, ` M make-dmg.sh` and the untracked `.omc/`.

- [ ] **Step 6: Commit**

```bash
git add App build.sh make-dmg.sh
git commit -m "split app sources and open the 2.0 line"
```

---

### Task 2: Launch options

**Files:**
- Create: `App/LaunchOptions.swift`, `Tests/LaunchOptionsTests.swift`
- Modify: `Tests/main.swift`, `build.sh:14-16` (test compile line)

**Interfaces:**
- Consumes: test harness `test`, `expect`, `expectEqual` (`Tests/Harness.swift`).
- Produces: `struct LaunchOptions: Equatable { var playURL: URL?; var playAt: TimeInterval }`, `static func parse(_ arguments: [String]) -> LaunchOptions`, `static func stillID(for url: URL) -> String` (`"debug-"` + 12 hex characters).

- [ ] **Step 1: Write the failing tests**

`Tests/LaunchOptionsTests.swift`:

```swift
import Foundation

func launchOptionsTests() {
    let url = URL(string: "https://manifest.googlevideo.com/api/manifest/hls_playlist/expire/1800003600/index.m3u8")!

    test("no arguments means no stream") {
        expectEqual(LaunchOptions.parse([]), LaunchOptions())
    }

    test("play-url and play-at are read wherever they appear") {
        let options = LaunchOptions.parse(["-psn_0_1", "--play-at", "30", "--play-url", url.absoluteString])
        expectEqual(options.playURL, url)
        expectEqual(options.playAt, 30)
    }

    test("a missing or unparsable value falls back to the default") {
        expectEqual(LaunchOptions.parse(["--play-url"]).playURL, nil)
        expectEqual(LaunchOptions.parse(["--play-url", "--play-at", "5"]).playURL, nil)
        expectEqual(LaunchOptions.parse(["--play-at", "soon"]).playAt, 0)
        expectEqual(LaunchOptions.parse(["--play-at", "-5"]).playAt, 0)
    }

    test("only http and https streams are accepted") {
        expectEqual(LaunchOptions.parse(["--play-url", "file:///tmp/clip.m3u8"]).playURL, nil)
        expectEqual(LaunchOptions.parse(["--play-url", "http://host/clip.m3u8"]).playURL,
                    URL(string: "http://host/clip.m3u8"))
    }

    test("a still id is stable for a URL and distinct between URLs") {
        let id = LaunchOptions.stillID(for: url)
        expectEqual(id, LaunchOptions.stillID(for: url))
        expectEqual(id.count, 18)
        expect(id.hasPrefix("debug-"), "unexpected id \(id)")
        expect(id != LaunchOptions.stillID(for: URL(string: "https://example.com/other.m3u8")!),
               "different URLs must not share a still")
    }
}
```

`Tests/main.swift` becomes:

```swift
import Foundation

if let path = CommandLine.arguments.dropFirst().first {
    fixturesDirectory = URL(fileURLWithPath: path)
}
matchingTests()
storeTests()
ytDlpTests()
resolverTests()
launchOptionsTests()
runAll()
```

In `build.sh`, the test compile line

```bash
        -o "$HERE/.build/tests" "$HERE"/Clips/*.swift "$HERE"/Tests/*.swift
```
becomes
```bash
        -o "$HERE/.build/tests" "$HERE"/Clips/*.swift "$HERE/App/LaunchOptions.swift" "$HERE"/Tests/*.swift
```

- [ ] **Step 2: Run, watch it fail**

Run: `./build.sh --test`
Expected: the compiler stops with `error: cannot find 'LaunchOptions' in scope` (and the swiftc invocation itself fails because `App/LaunchOptions.swift` does not exist yet — either failure is the expected RED).

- [ ] **Step 3: Implement**

`App/LaunchOptions.swift`:

```swift
import CryptoKit
import Foundation

struct LaunchOptions: Equatable {
    var playURL: URL?
    var playAt: TimeInterval = 0

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        for (index, argument) in arguments.enumerated() {
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch argument {
            case "--play-url":
                options.playURL = value.flatMap { URL(string: $0) }
                    .flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
            case "--play-at":
                options.playAt = max(0, value.flatMap { Double($0) } ?? 0)
            default:
                continue
            }
        }
        return options
    }

    /// A debug still is keyed by its URL the way a clip's still is keyed by video id: the
    /// wallpaper agent caches by URL, so a still file is never rewritten with other pixels.
    static func stillID(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return "debug-" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./build.sh --test`
Expected: `49 tests, 0 failures`, then `==> compiling resolve`. Also `./build.sh --dest .build/check` still builds (the app now compiles `App/LaunchOptions.swift` too, nothing uses it yet).

- [ ] **Step 5: Commit**

```bash
git add App/LaunchOptions.swift Tests/LaunchOptionsTests.swift Tests/main.swift build.sh
git commit -m "add debug launch options for streaming playback"
```

---

### Task 3: Stream playback in ScreenWallpaper

**Files:**
- Create: `App/StreamSession.swift`, `App/StreamStill.swift`
- Modify: `App/ScreenWallpaper.swift` (the `ScreenWallpaper` class: stored properties, `play(_:)`, `tearDown()`, plus new members)

**Interfaces:**
- Consumes: the existing `AVQueuePlayer` in `ScreenWallpaper` (`player`), `AVPlayerLooper` for packs.
- Produces:
  - `enum StreamFailure: CustomStringConvertible { case itemFailed(String), stalled(TimeInterval) }`
  - `final class StreamSession` — `init(url: URL, player: AVQueuePlayer, onFailure: @escaping (StreamFailure) -> Void)`, `func start(at position: TimeInterval)`, `func stop()`
  - `enum StreamStill` — `static func grab(from player: AVPlayer, to file: URL, completion: @escaping (Bool) -> Void)`; `static let timeout: TimeInterval` (10)
  - `ScreenWallpaper`: `static let stallTimeout: TimeInterval` (20), `var onStreamFailure: ((StreamFailure) -> Void)?`, `var isStreaming: Bool`, `func play(stream url: URL, at position: TimeInterval)`, `func grabStill(to file: URL, completion: @escaping (Bool) -> Void)`; `play(_:)` and `tearDown()` also end any stream.

There are no unit tests for this task: every line talks to AVFoundation. The gate is the build plus the task review; the behaviour is exercised in Task 5.

- [ ] **Step 1: The session**

`App/StreamSession.swift`:

```swift
import AVFoundation

enum StreamFailure: CustomStringConvertible {
    case itemFailed(String)
    case stalled(TimeInterval)

    var description: String {
        switch self {
        case .itemFailed(let reason): return "item failed: \(reason)"
        case .stalled(let seconds): return "stalled for \(Int(seconds)) s"
        }
    }
}

/// Two items of the same URL stay queued, so the next loop is buffered before the current
/// one ends and the seam is as short as the player can make it. That is what AVPlayerLooper
/// does for files, but its replicas drop attached outputs (so no still could be grabbed) and
/// its HLS behaviour is undocumented; keeping the queue by hand costs a dozen lines.
final class StreamSession {
    private let url: URL
    private let player: AVQueuePlayer
    private let onFailure: (StreamFailure) -> Void
    private var owned: [AVPlayerItem] = []
    private var itemObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var playerObservation: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []
    private var pendingSeek: (item: AVPlayerItem, position: TimeInterval)?
    private var stallToken: Int?
    private var stallCounter = 0
    private var finished = false
    private var wantsPlay = true

    init(url: URL, player: AVQueuePlayer, onFailure: @escaping (StreamFailure) -> Void) {
        self.url = url
        self.player = player
        self.onFailure = onFailure
    }

    deinit { stop() }

    func start(at position: TimeInterval) {
        let first = makeItem()
        player.insert(first, after: nil)
        player.insert(makeItem(), after: first)

        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil,
                                         queue: .main) { [weak self] note in
            self?.itemEnded(note.object as? AVPlayerItem)
        })
        tokens.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil,
                                         queue: .main) { [weak self] note in
            guard let self, self.owns(note.object) else { return }
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self.fail(.itemFailed(error?.localizedDescription ?? "did not reach the end"))
        })
        tokens.append(center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: nil,
                                         queue: .main) { [weak self] note in
            guard let self, self.owns(note.object) else { return }
            self.stalled()
        })
        playerObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.clearStall()
                case .paused:
                    // An unasked-for pause (an empty queue, a system interruption) is a stall;
                    // pause() clears the stall itself before calling player.pause().
                    if self.wantsPlay { self.stalled() } else { self.clearStall() }
                case .waitingToPlayAtSpecifiedRate:
                    self.stalled()
                default:
                    break
                }
            }
        }

        // Until the first frame plays the stream is "stalled" from the user's point of view,
        // so the same timeout covers a URL that never starts and one that dies mid-way.
        stalled()
        if position > 0 {
            pendingSeek = (first, position)
        } else {
            player.play()
        }
    }

    func stop() {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens = []
        playerObservation = nil
        itemObservations = [:]
        owned = []
        pendingSeek = nil
        finished = true
    }

    func pause() {
        wantsPlay = false
        clearStall()
        player.pause()
    }

    func resume() {
        guard !finished, !wantsPlay else { return }
        wantsPlay = true
        stalled()
        // While the first item is still loading, the pending seek will call play() itself;
        // playing here first would start the stream at 0 before the seek lands.
        if pendingSeek == nil { player.play() }
    }

    private func makeItem() -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        owned.append(item)
        itemObservations[ObjectIdentifier(item)] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .failed:
                    self.fail(.itemFailed(item.error?.localizedDescription ?? "unknown error"))
                case .readyToPlay:
                    self.itemReady(item)
                default:
                    break
                }
            }
        }
        return item
    }

    private func itemReady(_ item: AVPlayerItem) {
        guard let pending = pendingSeek, pending.item === item else { return }
        pendingSeek = nil
        item.seek(to: CMTime(seconds: pending.position, preferredTimescale: 600)) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.wantsPlay else { return }
                self.player.play()
            }
        }
    }

    private func owns(_ object: Any?) -> Bool {
        guard let item = object as? AVPlayerItem else { return false }
        return owned.contains { $0 === item }
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard !finished, let item, owns(item) else { return }
        owned.removeAll { $0 === item }
        itemObservations[ObjectIdentifier(item)] = nil
        while owned.count < 2 {
            player.insert(makeItem(), after: player.items().last)
        }
    }

    private func stalled() {
        guard !finished, stallToken == nil else { return }
        stallCounter += 1
        let token = stallCounter
        stallToken = token
        let started = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + ScreenWallpaper.stallTimeout) { [weak self] in
            guard let self, !self.finished, self.stallToken == token else { return }
            self.fail(.stalled(Date().timeIntervalSince(started)))
        }
    }

    private func clearStall() {
        stallToken = nil
    }

    private func fail(_ failure: StreamFailure) {
        guard !finished else { return }
        stop()
        onFailure(failure)
    }
}
```

- [ ] **Step 2: The still**

`App/StreamStill.swift`:

```swift
import AppKit
import AVFoundation
import CoreImage

/// AVAssetImageGenerator cannot read an HLS asset, so the still is one of the frames the
/// player is already decoding; waiting for the first one doubles as the first-frame timer.
enum StreamStill {
    static let timeout: TimeInterval = 10
    private static let interval: TimeInterval = 0.1

    static func grab(from player: AVPlayer, to file: URL, completion: @escaping (Bool) -> Void) {
        guard let item = player.currentItem else { return completion(false) }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        poll(player: player, item: item, output: output, until: Date().addingTimeInterval(timeout),
             file: file, completion: completion)
    }

    /// The grab starts right after play(stream:at:), while a seek may still be pending and
    /// currentTime() reads 0; waiting for .playing skips that frame instead of writing a
    /// still from position zero.
    private static func poll(player: AVPlayer, item: AVPlayerItem, output: AVPlayerItemVideoOutput,
                             until deadline: Date, file: URL, completion: @escaping (Bool) -> Void) {
        let time = item.currentTime()
        if player.timeControlStatus == .playing,
           output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            item.remove(output)
            completion(write(buffer, to: file))
            return
        }
        guard Date() < deadline else {
            item.remove(output)
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            poll(player: player, item: item, output: output, until: deadline, file: file, completion: completion)
        }
    }

    private static func write(_ buffer: CVPixelBuffer, to file: URL) -> Bool {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let frame = CIContext().createCGImage(image, from: image.extent, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let jpeg = NSBitmapImageRep(cgImage: frame)
                  .representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? jpeg.write(to: file, options: .atomic)) != nil
    }
}
```

- [ ] **Step 3: The wallpaper's second mode**

In `App/ScreenWallpaper.swift`, inside `final class ScreenWallpaper`:

Replace the stored properties

```swift
    private let window: NSWindow
    private let view: PlayerView
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
```
with
```swift
    /// A stall shorter than this is buffering; past it the network or the URL is gone, and
    /// the regular pack is better than a frozen frame.
    static let stallTimeout: TimeInterval = 20

    private let window: NSWindow
    private let view: PlayerView
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var stream: StreamSession?

    var onStreamFailure: ((StreamFailure) -> Void)?
    var isStreaming: Bool { stream != nil }
```

Replace `play(_:)`

```swift
    func play(_ url: URL) {
        looper = nil
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }
```
with
```swift
    func play(_ url: URL) {
        stream?.stop()
        stream = nil
        looper = nil
        player.removeAllItems()
        player.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
        onStreamFailure = nil
    }

    func play(stream url: URL, at position: TimeInterval) {
        stream?.stop()
        stream = nil
        looper = nil
        player.removeAllItems()
        player.actionAtItemEnd = .advance
        let session = StreamSession(url: url, player: player) { [weak self] failure in
            self?.stream = nil
            self?.onStreamFailure?(failure)
        }
        stream = session
        session.start(at: position)
    }

    func grabStill(to file: URL, completion: @escaping (Bool) -> Void) {
        StreamStill.grab(from: player, to: file, completion: completion)
    }
```

Replace `tearDown()`

```swift
    func tearDown() {
        player.pause()
        looper = nil
        window.orderOut(nil)
        window.close()
    }
```
with
```swift
    func tearDown() {
        stream?.stop()
        stream = nil
        player.pause()
        looper = nil
        window.orderOut(nil)
        window.close()
    }
```

`pause()`, `resume()`, `raise()`, `align(to:)` and `init(screen:)` stay as they are (`init` already sets `actionAtItemEnd = .none` and `isMuted = true`).

- [ ] **Step 4: Build**

Run: `./build.sh --dest .build/check && ./build.sh --test`
Expected: `==> built .build/check/Loopscape.app` with no diagnostics (an unused-result or unused-variable warning is a defect — fix it); `49 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add App/StreamSession.swift App/StreamStill.swift App/ScreenWallpaper.swift
git commit -m "play a looping HLS stream on the wallpaper windows"
```

---

### Task 4: Debug stream in the app

**Files:**
- Modify: `App/AppDelegate.swift` (stored properties, `init`, `applicationDidFinishLaunching`, `spaceChanged`, `syncDesktopPicture`, `screensChanged`, `screensDidWake`, `startPlayback`, `applySelection`, `togglePause`, new `// MARK: - streaming` section), `App/main.swift` (delegate construction)

**Interfaces:**
- Consumes: `LaunchOptions` (Task 2); `ScreenWallpaper.play(stream:at:)`, `onStreamFailure`, `grabStill(to:completion:)`, `StreamFailure` (Task 3).
- Produces: `struct ClipStream { let url: URL; let position: TimeInterval; let stillID: String }`; `AppDelegate.init(options: LaunchOptions)`; private `startStream(_:)`, `streamFailed(_:)`, `restorePlayback()`, `syncDesktopPicture(still:)`, `repaintDesktopPicture()`, `stillsDirectory` — the hooks Part 4 will call from its mode machine.

- [ ] **Step 1: State and construction**

In `App/AppDelegate.swift`, above `final class AppDelegate` add:

```swift
struct ClipStream {
    let url: URL
    let position: TimeInterval
    let stillID: String
}
```

Inside `AppDelegate`, after `private var activity: NSObjectProtocol?` add:

```swift
    private var stream: ClipStream?
    private var desktopStill: URL?
    private let options: LaunchOptions
```

and after `private var isPaused: Bool { defaults.bool(forKey: Key.paused) }` add:

```swift
    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }
```

In `App/main.swift` replace `let delegate = AppDelegate()` with

```swift
let delegate = AppDelegate(options: LaunchOptions.parse(CommandLine.arguments))
```

- [ ] **Step 2: Start the debug stream after launch**

At the end of `applicationDidFinishLaunching`, after the last `workspace.addObserver(...)` call, add:

```swift
        if let url = options.playURL {
            startStream(ClipStream(url: url, position: options.playAt, stillID: LaunchOptions.stillID(for: url)))
        }
```

- [ ] **Step 3: One still per screen state**

Replace `spaceChanged`

```swift
    @objc private func spaceChanged() {
        realign()
        if let slug = currentSlug { syncDesktopPicture(slug) }
    }
```
with
```swift
    @objc private func spaceChanged() {
        realign()
        repaintDesktopPicture()
    }
```
(the `///` comment above it stays).

Replace `syncDesktopPicture`

```swift
    private func syncDesktopPicture(_ slug: String) {
        guard let still = poster(for: slug) else { return }
        let imageOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true,
        ]
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(still, for: screen, options: imageOptions)
        }
    }
```
with
```swift
    private func syncDesktopPicture(_ slug: String) {
        guard let still = poster(for: slug) else { return }
        syncDesktopPicture(still: still)
    }

    private func syncDesktopPicture(still: URL) {
        desktopStill = still
        let imageOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true,
        ]
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(still, for: screen, options: imageOptions)
        }
    }

    private func repaintDesktopPicture() {
        if let desktopStill { syncDesktopPicture(still: desktopStill) }
    }
```
(the two `///` comment blocks above `syncDesktopPicture` stay above the first function).

- [ ] **Step 4: Display changes restore whatever was playing**

Replace, in `screensChanged`,

```swift
        rebuildScreens()
        if let slug = currentSlug {
            startPlayback(slug)
            // A display attached after the last pack switch still shows the default system
            // wallpaper, which the menu bar and "click to reveal desktop" blur instead of
            // the video — repaint the still on every geometry change, not just on switch.
            syncDesktopPicture(slug)
        }
```
with
```swift
        rebuildScreens()
        // A display attached after the last pack switch still shows the default system
        // wallpaper, which the menu bar and "click to reveal desktop" blur instead of
        // the video — repaint the still on every geometry change, not just on switch.
        restorePlayback()
```

Replace `screensDidWake`

```swift
    @objc private func screensDidWake() {
        if NSScreen.screens.map({ $0.frame }) != lastFrames, !NSScreen.screens.isEmpty {
            rebuildScreens()
            if let slug = currentSlug {
                startPlayback(slug)
                syncDesktopPicture(slug)
            }
        } else {
            realign()
            if !isPaused { wallpapers.forEach { $0.resume() } }
            // Waking repaints every screen from the wallpaper store; if a record went
            // stale while the displays slept, this is where the default would show.
            if let slug = currentSlug { syncDesktopPicture(slug) }
        }
    }
```
with
```swift
    @objc private func screensDidWake() {
        if NSScreen.screens.map({ $0.frame }) != lastFrames, !NSScreen.screens.isEmpty {
            rebuildScreens()
            restorePlayback()
        } else {
            realign()
            if !isPaused { wallpapers.forEach { $0.resume() } }
            // Waking repaints every screen from the wallpaper store; if a record went
            // stale while the displays slept, this is where the default would show.
            repaintDesktopPicture()
        }
    }
```

After `startPlayback(_:)` add:

```swift
    private func restorePlayback() {
        if let stream {
            startStream(stream)
        } else if let slug = currentSlug {
            startPlayback(slug)
            syncDesktopPicture(slug)
        }
    }
```

In `applySelection(_:)` add `stream = nil` as the first line and restart the rotation timer once a stream ends:

```swift
    private func applySelection(_ slug: String) {
        let wasStreaming = stream != nil
        stream = nil
        currentSlug = slug
        rememberPin(slug)
        startPlayback(slug)
        syncDesktopPicture(slug)
        markCurrentForSaver(slug)
        refreshMenu()
        if wasStreaming { restartTimer() }
    }
```

In `togglePause()` replace `if let slug = currentSlug { syncDesktopPicture(slug) }` with `repaintDesktopPicture()`.

- [ ] **Step 5: The streaming section**

Before `// MARK: - timer` add:

```swift
    // MARK: - streaming

    private var stillsDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.aklimoff.loopscape"
        return caches.appendingPathComponent(bundleID).appendingPathComponent("stills")
    }

    private func startStream(_ target: ClipStream) {
        stream = target
        timer?.invalidate()
        timer = nil
        if wallpapers.isEmpty { rebuildScreens() }
        let started = Date()
        for wallpaper in wallpapers {
            wallpaper.onStreamFailure = { [weak self] failure in self?.streamFailed(failure) }
            wallpaper.play(stream: target.url, at: target.position)
        }
        if isPaused { wallpapers.forEach { $0.pause() } }

        let still = stillsDirectory.appendingPathComponent("\(target.stillID).jpg")
        if FileManager.default.fileExists(atPath: still.path) {
            syncDesktopPicture(still: still)
            return
        }
        wallpapers.first?.grabStill(to: still) { [weak self] written in
            guard let self, self.stream?.url == target.url else { return }
            os_log("stream: first frame after %{public}.2f s, still %{public}@",
                  Date().timeIntervalSince(started), written ? "written" : "not written")
            if written { self.syncDesktopPicture(still: still) }
        }
    }

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

- [ ] **Step 6: Build**

Run: `./build.sh --dest .build/check && ./build.sh --test`
Expected: `==> built .build/check/Loopscape.app` with no diagnostics; `49 tests, 0 failures`.

Then confirm the pack path is untouched in behaviour: `git diff HEAD -- App/AppDelegate.swift | grep '^-' | grep -v '^---'` lists only the lines this task replaces: the `syncDesktopPicture(slug)` call sites in `spaceChanged`, `screensChanged`, `screensDidWake` (two) and `togglePause`, the `startPlayback` calls in the two screen handlers, the old `syncDesktopPicture` body, and `let delegate = AppDelegate()` in `main.swift`.

- [ ] **Step 7: Commit**

```bash
git add App/AppDelegate.swift App/main.swift
git commit -m "stream a clip from debug launch arguments and fall back to the pack"
```

---

### Task 5: Live verification and the spec's Part 3 checks

**Files:**
- Modify: `docs/superpowers/specs/2026-09-18-spotify-clips-design.md` ("Streaming in ScreenWallpaper" bullet on looping, "Spike measurements" or a new Part 3 measurements table, the "Open risk" paragraph's outcome)

**Interfaces:**
- Consumes: the built app, `.build/resolve` (Part 2 harness, built by `./build.sh --test`), `yt-dlp` and `deno` from Homebrew.

Two kinds of steps. **Implementer steps** are run by whoever executes this task from a shell. **Owner steps** need eyes on the screen, the menu, a second display or the network switch — the implementer prints the exact commands and expected results in the report, and Aktan runs them; the implementer never toggles Wi-Fi, never puts displays to sleep and never installs anything.

Precondition: the wallpaper library is not empty (the fallback target is "the pack that was showing"), and the installed Loopscape from `/Applications` is running (it will be quit for the duration and relaunched at the end).

- [ ] **Step 1 (implementer): Build and fetch a stream URL**

```bash
./build.sh --dest .build/check && ./build.sh --test
.build/resolve "Rick Astley" "Never Gonna Give You Up" 213
```
Expected: the app builds, `49 tests, 0 failures`, and the harness prints a `stream: https://manifest.googlevideo.com/...m3u8` line. Keep that URL as `$URL`; it stays valid for about six hours.

- [ ] **Step 2 (implementer): Swap in the dev build**

```bash
osascript -e 'quit app "Loopscape"'; while pgrep -x Loopscape >/dev/null; do sleep 0.2; done
rm -f ~/Library/Caches/com.aklimoff.loopscape/stills/debug-*.jpg
log stream --process Loopscape --style compact > .build/stream.log 2>&1 &
LOGPID=$!
open -a "$PWD/.build/check/Loopscape.app" --args --play-url "$URL" --play-at 30
sleep 8; screencapture -x .build/frame-a.png; sleep 3; screencapture -x .build/frame-b.png
grep 'stream:' .build/stream.log
```
Expected: a log line `stream: first frame after N s, still written` with N ≤ 2.0; `frame-a.png` and `frame-b.png` differ (`cmp` reports a difference) and both show the music video, not a pack; `~/Library/Caches/com.aklimoff.loopscape/stills/debug-<12 hex>.jpg` exists and is a frame of the video (open it with `qlmanage -p` or view the file).

- [ ] **Step 3 (implementer): The loop seam**

```bash
osascript -e 'quit app "Loopscape"'; while pgrep -x Loopscape >/dev/null; do sleep 0.2; done
open -a "$PWD/.build/check/Loopscape.app" --args --play-url "$URL" --play-at 205
for i in 1 2 3 4 5 6; do sleep 2; screencapture -x ".build/seam-$i.png"; done
```
The video is 213 s long, so the seam falls around the third or fourth capture. Expected: no capture is black or shows a pack; captures before and after the seam show the video's end and its beginning. Whether the seam is smooth by eye is an owner step (below).

- [ ] **Step 4 (implementer): Failure paths that need no network switch**

An unreachable URL:

```bash
osascript -e 'quit app "Loopscape"'; while pgrep -x Loopscape >/dev/null; do sleep 0.2; done
open -a "$PWD/.build/check/Loopscape.app" --args --play-url "https://127.0.0.1:9/never.m3u8"
sleep 25; grep 'stream:' .build/stream.log | tail -2; screencapture -x .build/after-fail.png
```
Expected: a `stream: item failed: … — back to the pack` line (or `stalled for 20 s`) within 25 s, and `after-fail.png` shows a regular pack, not black.

An expired URL — take `$URL` and set its `expire` path or query component to `1600000000`:

```bash
EXPIRED="$(printf '%s' "$URL" | sed -E 's#(/expire/|expire=)[0-9]+#\11600000000#')"
osascript -e 'quit app "Loopscape"'; while pgrep -x Loopscape >/dev/null; do sleep 0.2; done
open -a "$PWD/.build/check/Loopscape.app" --args --play-url "$EXPIRED"
sleep 25; grep 'stream:' .build/stream.log | tail -2
```
Expected: `stream: item failed: …` (the CDN answers 403) and the pack is back.

- [ ] **Step 5 (implementer): Resource use**

```bash
osascript -e 'quit app "Loopscape"'; while pgrep -x Loopscape >/dev/null; do sleep 0.2; done
open -a "$PWD/.build/check/Loopscape.app" --args --play-url "$URL"
sleep 10
top -l 3 -s 5 -pid "$(pgrep -x Loopscape)" -stats pid,cpu,mem | tail -3
nettop -P -L 6 -p "$(pgrep -x Loopscape)" -J bytes_in | tail -6
```
Expected: CPU a few percent once the first seconds of buffering are over; bytes in for one display in the region of 4.7 Mbit/s ≈ 0.6 MB/s. Record the numbers.

- [ ] **Step 6 (implementer): Restore the installed app and hand over**

```bash
osascript -e 'quit app "Loopscape"'; while pgrep -x Loopscape >/dev/null; do sleep 0.2; done
kill "$LOGPID"
open -a /Applications/Loopscape.app
```

Then write the owner checklist into the report, each item with its command and the expected result:

1. Loop seam by eye: `open -a "$PWD/.build/check/Loopscape.app" --args --play-url "$URL" --play-at 205`, watch the seam three times (each loop is 213 s, so `--play-at 205` again for each look). Acceptable or not.
2. Start position: `--play-at 30` lands near 0:30 of the video (compare with the YouTube page).
3. Pause / Resume from the menu, a space switch, a fullscreen app: the stream behaves like a local pack.
4. Display sleep and wake (`pmset displaysleepnow`, then a key press): the stream resumes; after a sleep longer than the URL's lifetime (see the `expire` timestamp in `$URL`) the pack comes back and nothing is black.
5. Wi-Fi off for 30 s mid-stream, then on: the stream stalls, the pack returns at about 20 s, the log shows `stalled for 20 s`.
6. Two displays, if available: bandwidth ≈ 2× the Step 5 figure; note the drift between the two pictures after a few minutes.
7. Menu bar strip: screenshots at three or four moments of a video with hard scene changes (`screencapture -x` while the menu bar is visible); decide whether the still's disagreement with the moving picture is acceptable or whether a remedy (average-colour still, periodic repaint) goes into Part 4.

Quit the dev build and relaunch `/Applications/Loopscape.app` after each item.

- [ ] **Step 7 (owner): Run the checklist and report the decisions**

Aktan runs items 1–7 and reports which passed, the seam verdict, and the strip decision.

- [ ] **Step 8 (implementer, after Step 7): Record the outcome in the spec**

In `docs/superpowers/specs/2026-09-18-spotify-clips-design.md`:
- In "Streaming in ScreenWallpaper", replace the bullet `play(stream:at:) beside the existing play(_:); looping via AVPlayerLooper if it holds up with HLS, otherwise seek to zero on didPlayToEndTime.` with a bullet stating what was built: `play(stream:at:)` beside `play(_:)`; looping by keeping two items of the same URL queued on the `AVQueuePlayer` (`StreamSession`), because `AVPlayerLooper` drops outputs from its replicas and its HLS behaviour is undocumented; a stall past 20 s or a failed item reports `StreamFailure`.
- Add a "Part 3 measurements" table under "Spike measurements" with: first frame (s), CPU (%), bytes in for one display (MB/s), two-display figure and drift if measured, the seam verdict, and the failure timings from Step 4 — each with the yt-dlp and macOS versions.
- Replace the "**Open risk:**" paragraph's last sentence with the decision from item 7.

```bash
git add docs/superpowers/specs/2026-09-18-spotify-clips-design.md
git commit -m "record streaming playback measurements"
```

---

## Done when

- `./build.sh --test` prints `49 tests, 0 failures` and `./build.sh --dest .build/check` builds the app from `App/*.swift`; `git diff clip-resolver -- LoopscapeSaver.swift Clips Tools Tests/Fixtures` is empty.
- With the library non-empty, `open -a <app> --args --play-url <m3u8> --play-at <s>` shows the video on every display within 2 s, loops it, and an unreachable, expired or stalled stream ends on the regular pack.
- The owner checklist has a verdict per item and the spec records the measurements, the loop mechanism and the strip decision.
