# Clip Resolver (Spotify clips, Part 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a Spotify track (id, artist, name, length) into a playable YouTube HLS URL or a remembered "no clip", verified by unit tests and a command-line harness — without touching the app.

**Architecture:** Four small sources under `Clips/`: pure candidate scoring, a JSON mapping store, a `yt-dlp` wrapper behind a `ClipSource` protocol, and a blocking `ClipResolver` that ties them together with an in-memory URL cache. Tests are a plain `swiftc` executable driven by `./build.sh --test`; ranking is tested against search results captured from YouTube on 2026-09-18.

**Tech Stack:** Swift 5 mode, Foundation only, `swiftc` (no SwiftPM, no Xcode project, no XCTest), `yt-dlp` from Homebrew as an external tool.

**Spec:** `docs/superpowers/specs/2026-09-18-spotify-clips-design.md` — this plan implements its "ClipResolver" section and "Part 2 — ClipResolver" checks.

## Global Constraints

- Compiler flags everywhere: `-swift-version 5 -target arm64-apple-macosx13.0`. No package manager, no third-party Swift code.
- The app is not touched in this part: `Loopscape.swift`, `LoopscapeSaver.swift`, `make-dmg.sh` and `VERSION="1.6"` stay as they are. Nothing under `Clips/` is compiled into the app yet.
- Format selector, verbatim: `bv[vcodec^=avc1][height>=480][height<=1080][protocol^=m3u8]`.
- A remembered miss lapses after 30 days; a remembered video never does.
- A stream URL with less than 600 s left before its `expire` deadline is not reused.
- Live pass criteria: ≤ 8 s for an unknown track, ≤ 5 s with a mapping hit, instant within one process.
- Comments: none by default. Only a comment that answers a "why" the code cannot show is allowed; the ones in this plan are of that kind — copy them as written, add no others.
- Commits: one short imperative English subject line, no body unless it explains a "why", and no LLM attribution of any kind (no `Co-Authored-By`, no "Generated with").
- Stage files by explicit path. `.omc/` is untracked and stays that way.

**Open question for Aktan (does not block):** `YtDlp.minimumHeight` is 480. МакSим — «Лучшая ночь» exists only at 240p, so with this value it resolves to "no clip". Lower the constant if any clip beats none.

## File Structure

| File | Responsibility |
|---|---|
| `Clips/ClipMatching.swift` | `TrackQuery`, `Candidate`, and the pure functions that normalise text, build the search query, score a candidate and pick one |
| `Clips/ClipStore.swift` | `clips.json`: track id → video id or dated miss |
| `Clips/YtDlp.swift` | `ClipError`, `ClipStream`, the `ClipSource` protocol and its `yt-dlp` implementation |
| `Clips/ClipResolver.swift` | `ClipResolution` and the store → search → pick → stream flow with the URL cache |
| `Tests/Harness.swift` | `test`, `expect`, `expectEqual`, `runAll`, fixture and temp-dir helpers |
| `Tests/main.swift` | Registers every test group and runs them |
| `Tests/*Tests.swift` | One file per source under test |
| `Tests/Fixtures/*.json` | Ten captured searches — already in the working tree, committed in Task 1 |
| `Tools/resolve/main.swift` | Command-line harness for live checks |
| `build.sh` | Gains `--test` |

Each fixture is `{"artist", "name", "seconds", "candidates": [{"id", "title", "channel", "duration", "channel_is_verified"}]}`, trimmed from:

```sh
yt-dlp --no-warnings --flat-playlist -J "ytsearch5:<artist> <cleaned name> official video"
```

A wrong pick found later becomes a new fixture captured the same way, plus one line in `expectedPicks`.

---

### Task 1: Test runner and candidate scoring

**Files:**
- Modify: `build.sh:1-10` (usage comment, `--test` branch)
- Create: `Tests/Harness.swift`, `Tests/main.swift`, `Tests/ClipMatchingTests.swift`
- Create: `Clips/ClipMatching.swift`
- Commit as they are: `Tests/Fixtures/*.json`, `docs/superpowers/`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct TrackQuery { id: String, artist: String, name: String, seconds: Int }`
  - `struct Candidate: Decodable { id: String, title: String, channel: String?, duration: Double?, isVerified: Bool }` with a memberwise `init(id:title:channel:duration:isVerified:)`; decodes `channel_is_verified`, `null` → `false`
  - `ClipMatching.normalize(_:) -> String`, `.cleanTrackName(_:) -> String`, `.searchQuery(for:) -> String`, `.score(_:for:) -> Int?`, `.pick(for:from:) -> Candidate?`
  - Test helpers: `test(_:_:)`, `expect(_:_:)`, `expectEqual(_:_:)`, `runAll() -> Never`, `loadFixture(_:) throws -> Fixture`, `temporaryDirectory() throws -> URL`, `var fixturesDirectory: URL`

- [ ] **Step 1: Branch and commit what already exists**

```bash
git checkout -b clip-resolver
git add docs/superpowers Tests/Fixtures
git commit -m "add spotify clips design, resolver plan and search fixtures"
```

- [ ] **Step 2: Teach `build.sh` to run tests**

Replace the usage comment at the top of `build.sh`:

```bash
# Usage:
#   ./build.sh              build, install to /Applications and launch
#   ./build.sh --dest DIR   build the bundle into DIR and stop (used by make-dmg.sh)
#   ./build.sh --test       build and run the unit tests, touch nothing else
```

Insert directly after the `HERE="$(cd ...` line:

```bash
if [[ "${1:-}" == "--test" ]]; then
    mkdir -p "$HERE/.build"
    echo "==> compiling tests"
    swiftc -swift-version 5 -target arm64-apple-macosx13.0 \
        -o "$HERE/.build/tests" "$HERE"/Clips/*.swift "$HERE"/Tests/*.swift
    "$HERE/.build/tests" "$HERE/Tests/Fixtures"
    exit 0
fi
```

- [ ] **Step 3: Write the harness**

`Tests/Harness.swift`:

```swift
import Foundation

var fixturesDirectory = URL(fileURLWithPath: "Tests/Fixtures")

private var registered: [(name: String, body: () throws -> Void)] = []
private var failures: [String] = []
private var running = ""

func test(_ name: String, _ body: @escaping () throws -> Void) {
    registered.append((name, body))
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expectation failed",
            line: UInt = #line) {
    if !condition { failures.append("\(running): \(message()) (line \(line))") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, line: UInt = #line) {
    expect(actual == expected, "got \(actual), expected \(expected)", line: line)
}

func runAll() -> Never {
    for (name, body) in registered {
        running = name
        do { try body() } catch { failures.append("\(name): threw \(error)") }
    }
    failures.forEach { print("FAIL \($0)") }
    print("\(registered.count) tests, \(failures.count) failures")
    exit(failures.isEmpty ? 0 : 1)
}

struct Fixture: Decodable {
    let artist: String
    let name: String
    let seconds: Int
    let candidates: [Candidate]

    var track: TrackQuery { TrackQuery(id: "spotify:track:\(name)", artist: artist, name: name, seconds: seconds) }
}

func loadFixture(_ slug: String) throws -> Fixture {
    let data = try Data(contentsOf: fixturesDirectory.appendingPathComponent("\(slug).json"))
    return try JSONDecoder().decode(Fixture.self, from: data)
}

func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("loopscape-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
```

`Tests/main.swift`:

```swift
import Foundation

if let path = CommandLine.arguments.dropFirst().first {
    fixturesDirectory = URL(fileURLWithPath: path)
}
matchingTests()
runAll()
```

- [ ] **Step 4: Write the failing tests**

`Tests/ClipMatchingTests.swift`:

```swift
import Foundation

func matchingTests() {
    let expectedPicks: [(slug: String, videoID: String?)] = [
        ("get-lucky", "of1XzU7-PHk"),
        ("luchshaya-noch", "AtKMvNUEPMM"),
        ("505", "iIfl5k2nQBQ"),
        ("blinding-lights", "4NRXx6U8ABQ"),
        ("treefingers", nil),
        ("bad-guy", "DyDfgMOUjCI"),
        ("gruppa-krovi", "MAn_WoXZ-hk"),
        ("never-gonna", "dQw4w9WgXcQ"),
        ("audio", "tjA7nAHOAww"),
        ("live-forever", "TDe1DqxwJoc"),
    ]
    for (slug, videoID) in expectedPicks {
        test("pick: \(slug)") {
            let fixture = try loadFixture(slug)
            expectEqual(ClipMatching.pick(for: fixture.track, from: fixture.candidates)?.id, videoID)
        }
    }

    test("normalize folds case, diacritics and punctuation") {
        expectEqual(ClipMatching.normalize("  Beyoncé — P!nk / AC/DC  "), "beyonce p nk ac dc")
        expectEqual(ClipMatching.normalize("МакSим - Лучшая НОЧЬ"), "макsим лучшая ночь")
    }

    test("cleanTrackName drops Spotify decorations") {
        expectEqual(ClipMatching.cleanTrackName("Get Lucky (feat. Pharrell Williams & Nile Rodgers)"), "Get Lucky")
        expectEqual(ClipMatching.cleanTrackName("Live Forever - Remastered"), "Live Forever")
        expectEqual(ClipMatching.cleanTrackName("Song [Bonus Track] - 2011 Remaster"), "Song")
        expectEqual(ClipMatching.cleanTrackName("(Untitled)"), "(Untitled)")
    }

    test("searchQuery uses the cleaned name") {
        let track = TrackQuery(id: "t", artist: "Oasis", name: "Live Forever - Remastered", seconds: 276)
        expectEqual(ClipMatching.searchQuery(for: track), "Oasis Live Forever official video")
    }

    let audio = TrackQuery(id: "t", artist: "LSD", name: "Audio", seconds: 191)

    test("a rejected word in the track's own name is forgiven once") {
        let video = Candidate(id: "v", title: "LSD - Audio (Official Video)", channel: "Sia",
                              duration: 226, isVerified: true)
        let cover = Candidate(id: "a", title: "LSD - Audio (Official Audio)", channel: "Sia",
                              duration: 191, isVerified: true)
        expectEqual(ClipMatching.score(video, for: audio), 4)
        expectEqual(ClipMatching.score(cover, for: audio), nil)
    }

    test("art tracks on Topic channels are rejected") {
        let artTrack = Candidate(id: "v", title: "LSD - Audio (Official Video)", channel: "LSD - Topic",
                                 duration: 191, isVerified: true)
        expectEqual(ClipMatching.score(artTrack, for: audio), nil)
    }

    test("the same title by another artist is rejected") {
        let other = Candidate(id: "v", title: "Audio (Official Music Video)", channel: "Somebody Else",
                              duration: 191, isVerified: true)
        expectEqual(ClipMatching.score(other, for: audio), nil)
    }

    test("durations far from the track are rejected, unknown track length is not") {
        let loop = Candidate(id: "v", title: "LSD - Audio (Official Video) 1 Hour", channel: "LSD",
                             duration: 3600, isVerified: false)
        let video = Candidate(id: "v", title: "LSD - Audio (Official Video)", channel: "LSD",
                              duration: 3600, isVerified: false)
        let unknownLength = TrackQuery(id: "t", artist: "LSD", name: "Audio", seconds: 0)
        expectEqual(ClipMatching.score(loop, for: audio), nil)
        expectEqual(ClipMatching.score(video, for: audio), nil)
        expectEqual(ClipMatching.score(video, for: unknownLength), 6)
    }

    test("an official channel upload without a marker clears the threshold") {
        let track = TrackQuery(id: "t", artist: "Billie Eilish", name: "bad guy", seconds: 194)
        let upload = Candidate(id: "v", title: "Billie Eilish - bad guy", channel: "Billie Eilish",
                               duration: 206, isVerified: false)
        let stranger = Candidate(id: "s", title: "Billie Eilish - bad guy", channel: "Some Fan",
                                 duration: 194, isVerified: true)
        expectEqual(ClipMatching.score(upload, for: track), 3)
        expectEqual(ClipMatching.score(stranger, for: track), nil)
    }
}
```

Why these expectations — so a failure can be judged rather than "fixed" by editing the table:

| Fixture | Expected | Reason |
|---|---|---|
| `get-lucky` | `of1XzU7-PHk` | "Official Audio" on the verified artist channel is rejected; of three "Official Video" re-uploads the one whose length matches the 369 s album track scores one point more |
| `luchshaya-noch` | `AtKMvNUEPMM` | «официальный клип»; the concert recording on the same official channel is rejected |
| `505` | `iIfl5k2nQBQ` | the only "Music Video"; lyrics and the festival set are rejected, a bare upload by a stranger stays under the threshold |
| `blinding-lights` | `4NRXx6U8ABQ` | official video on the artist channel; audio, lyrics, live and the 10-minute version are rejected |
| `treefingers` | none | no candidate has a video marker or an artist channel |
| `bad-guy` | `DyDfgMOUjCI` | no marker in the title, but it is the verified artist channel — beats a stranger's "[Official Music Video]" |
| `gruppa-krovi` | `MAn_WoXZ-hk` | "[Official Video]"; uploads titled «Виктор Цой» do not name the artist «Кино» |
| `never-gonna` | `dQw4w9WgXcQ` | ties with the animated video at the same score; YouTube's order breaks the tie |
| `audio` | `tjA7nAHOAww` | the track is called "Audio" — the word must not reject its own video |
| `live-forever` | `TDe1DqxwJoc` | same for "Live"; " - Remastered" is stripped from the Spotify name |

- [ ] **Step 5: Add the data types only, run, watch it fail**

`Clips/ClipMatching.swift`:

```swift
import Foundation

struct TrackQuery: Equatable {
    let id: String
    let artist: String
    let name: String
    let seconds: Int
}

struct Candidate: Equatable, Decodable {
    let id: String
    let title: String
    let channel: String?
    let duration: Double?
    let isVerified: Bool

    init(id: String, title: String, channel: String?, duration: Double?, isVerified: Bool) {
        self.id = id
        self.title = title
        self.channel = channel
        self.duration = duration
        self.isVerified = isVerified
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, channel, duration
        case isVerified = "channel_is_verified"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        channel = try values.decodeIfPresent(String.self, forKey: .channel)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        isVerified = try values.decodeIfPresent(Bool.self, forKey: .isVerified) ?? false
    }
}
```

Run: `./build.sh --test`
Expected: compilation fails with `cannot find 'ClipMatching' in scope`.

- [ ] **Step 6: Implement the scoring**

Append to `Clips/ClipMatching.swift`:

```swift
enum ClipMatching {
    static let threshold = 3

    private static let videoMarkers = [
        "music video", "официальный клип", "video oficial", "clip officiel", "videoclip", "official mv",
    ].map(normalize)

    private static let officialVideo = try! NSRegularExpression(pattern: #" official( \w+){0,3} video "#)

    private static let rejectedWords = [
        "audio", "lyric", "lyrics", "текст", "karaoke", "караоке", "live", "concert", "концерт",
        "festival", "cover", "кавер", "reaction", "реакция", "slowed", "reverb", "sped up",
        "nightcore", "8d", "instrumental", "минус", "acoustic", "remix", "full album", "teaser",
        "trailer", "behind the scenes", "making of", "hour", "hours", "tutorial", "lesson",
    ].map(normalize)

    /// Lowercased, diacritics folded, punctuation turned into single spaces — so "МакSим",
    /// "P!nk" and "Beyoncé" compare equal however a title decorates them.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let spaced = String(folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// Spotify decorates names with "(feat. …)", "[…]" and " - Remastered 2011"; YouTube
    /// titles do not repeat them.
    static func cleanTrackName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "",
                                                options: .regularExpression)
        if let dash = cleaned.range(of: " - ") { cleaned = String(cleaned[..<dash.lowerBound]) }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? name : cleaned
    }

    static func searchQuery(for track: TrackQuery) -> String {
        "\(track.artist) \(cleanTrackName(track.name)) official video"
    }

    /// nil means the candidate is ruled out, not merely weak.
    static func score(_ candidate: Candidate, for track: TrackQuery) -> Int? {
        guard let duration = candidate.duration else { return nil }
        if track.seconds > 0 {
            guard (0.5...2.0).contains(duration / Double(track.seconds)) else { return nil }
        }

        let title = " \(normalize(candidate.title)) "
        let channel = normalize(candidate.channel ?? "")
        let name = normalize(cleanTrackName(track.name))
        let artist = normalize(track.artist)
        let channelIsArtist = isArtistChannel(channel, artist: artist)

        guard !channel.hasSuffix(" topic") else { return nil }
        guard title.contains(" \(name) ") else { return nil }
        guard title.contains(" \(artist) ") || channelIsArtist else { return nil }

        // A track called "Audio" or "Live Forever" must not trip the word list on its own
        // name, while "Audio (Official Audio)" still has to.
        var rest = title
        for own in [name, artist] {
            if let range = rest.range(of: " \(own) ") { rest.replaceSubrange(range, with: " ") }
        }
        guard !rejectedWords.contains(where: { rest.contains(" \($0) ") }) else { return nil }

        var score = 0
        let whole = NSRange(title.startIndex..., in: title)
        if officialVideo.firstMatch(in: title, range: whole) != nil
            || videoMarkers.contains(where: { title.contains(" \($0) ") }) { score += 3 }
        if channelIsArtist { score += 3 }
        if candidate.isVerified { score += 1 }
        if track.seconds > 0, abs(duration - Double(track.seconds)) <= 10 { score += 1 }
        return score >= threshold ? score : nil
    }

    /// Ties go to YouTube's own ranking, which is why the first best score wins.
    static func pick(for track: TrackQuery, from candidates: [Candidate]) -> Candidate? {
        var best: (candidate: Candidate, score: Int)?
        for candidate in candidates {
            guard let score = score(candidate, for: track) else { continue }
            if best == nil || score > best!.score { best = (candidate, score) }
        }
        return best?.candidate
    }

    private static func isArtistChannel(_ channel: String, artist: String) -> Bool {
        let compactChannel = channel.replacingOccurrences(of: " ", with: "")
        let compactArtist = artist.replacingOccurrences(of: " ", with: "")
        guard !compactArtist.isEmpty else { return false }
        return ["", "vevo", "official"].contains { compactChannel == compactArtist + $0 }
    }
}
```

- [ ] **Step 7: Run the tests**

Run: `./build.sh --test`
Expected: `18 tests, 0 failures`.

If a fixture pick fails, print `ClipMatching.score` for each of its candidates and compare with the table in Step 4 before changing any weight; a change must keep all ten fixtures passing.

- [ ] **Step 8: Check the normal build is unaffected**

Run: `./build.sh --dest .build/check`
Expected: ends with `==> built .build/check/Loopscape.app`.

- [ ] **Step 9: Commit**

```bash
git add build.sh Clips/ClipMatching.swift Tests/Harness.swift Tests/main.swift Tests/ClipMatchingTests.swift
git commit -m "add clip candidate scoring with a swiftc test runner"
```

---

### Task 2: Mapping store

**Files:**
- Create: `Clips/ClipStore.swift`, `Tests/ClipStoreTests.swift`
- Modify: `Tests/main.swift`

**Interfaces:**
- Consumes: test helpers from Task 1.
- Produces:
  - `final class ClipStore` with `init(file: URL, now: @escaping () -> Date = Date.init)`
  - `enum ClipStore.Entry: Equatable { case video(String), none }`
  - `func lookup(_ trackID: String) -> Entry?` — `nil` means unknown or a lapsed miss
  - `func record(_ entry: Entry, for trackID: String)`
  - `static let missLifetime: TimeInterval` (30 days)
  - On disk: `{ "<track id>": { "checked": "<ISO 8601>", "video": "<id>" } }`; a miss has no `video` key.

- [ ] **Step 1: Write the failing tests**

`Tests/ClipStoreTests.swift`:

```swift
import Foundation

func storeTests() {
    test("store round-trips videos and misses through the file") {
        let file = try temporaryDirectory().appendingPathComponent("clips.json")
        let store = ClipStore(file: file)
        expectEqual(store.lookup("a"), nil)
        store.record(.video("AtKMvNUEPMM"), for: "a")
        store.record(.none, for: "b")

        let reopened = ClipStore(file: file)
        expectEqual(reopened.lookup("a"), .video("AtKMvNUEPMM"))
        expectEqual(reopened.lookup("b"), ClipStore.Entry.none)
        expectEqual(reopened.lookup("c"), nil)
    }

    test("a miss lapses after 30 days, a video never does") {
        let file = try temporaryDirectory().appendingPathComponent("clips.json")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ClipStore(file: file, now: { clock })
        store.record(.video("v"), for: "a")
        store.record(.none, for: "b")

        clock += 29 * 24 * 3600
        expectEqual(store.lookup("b"), ClipStore.Entry.none)
        clock += 2 * 24 * 3600
        expectEqual(store.lookup("b"), nil)
        expectEqual(store.lookup("a"), .video("v"))
    }

    test("a hand-edited file without dates' precision still loads") {
        let file = try temporaryDirectory().appendingPathComponent("clips.json")
        let edited = #"{ "spotify:track:1": { "video": "dQw4w9WgXcQ", "checked": "2026-09-18T00:00:00Z" } }"#
        try Data(edited.utf8).write(to: file)
        expectEqual(ClipStore(file: file).lookup("spotify:track:1"), .video("dQw4w9WgXcQ"))
    }

    test("a corrupt file starts empty instead of crashing") {
        let file = try temporaryDirectory().appendingPathComponent("clips.json")
        try Data("not json".utf8).write(to: file)
        let store = ClipStore(file: file)
        expectEqual(store.lookup("a"), nil)
        store.record(.video("v"), for: "a")
        expectEqual(ClipStore(file: file).lookup("a"), .video("v"))
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
runAll()
```

- [ ] **Step 2: Run, watch it fail**

Run: `./build.sh --test`
Expected: compilation fails with `cannot find 'ClipStore' in scope`.

- [ ] **Step 3: Implement**

`Clips/ClipStore.swift`:

```swift
import Foundation

/// Track → video mapping kept beside packs.json. Misses are remembered too, so a track with
/// no video costs one search instead of one per play; they lapse so a later release is found.
final class ClipStore {
    enum Entry: Equatable {
        case video(String)
        case none
    }

    static let missLifetime: TimeInterval = 30 * 24 * 3600

    private struct Record: Codable {
        var video: String?
        var checked: Date
    }

    private let file: URL
    private let now: () -> Date
    private var records: [String: Record] = [:]

    init(file: URL, now: @escaping () -> Date = Date.init) {
        self.file = file
        self.now = now
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file),
           let decoded = try? decoder.decode([String: Record].self, from: data) {
            records = decoded
        }
    }

    func lookup(_ trackID: String) -> Entry? {
        guard let record = records[trackID] else { return nil }
        if let video = record.video { return .video(video) }
        return now().timeIntervalSince(record.checked) < Self.missLifetime ? Entry.none : nil
    }

    func record(_ entry: Entry, for trackID: String) {
        switch entry {
        case .video(let id): records[trackID] = Record(video: id, checked: now())
        case .none: records[trackID] = Record(video: nil, checked: now())
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./build.sh --test`
Expected: `22 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Clips/ClipStore.swift Tests/ClipStoreTests.swift Tests/main.swift
git commit -m "add track to video mapping store"
```

---

### Task 3: yt-dlp wrapper

**Files:**
- Create: `Clips/YtDlp.swift`, `Tests/YtDlpTests.swift`
- Modify: `Tests/main.swift`

**Interfaces:**
- Consumes: `Candidate` from Task 1.
- Produces:
  - `enum ClipError: Error, Equatable { case toolMissing, unplayable, toolFailed(String) }`
  - `struct ClipStream: Equatable { url: URL, expires: Date }`
  - `protocol ClipSource { func search(_ query: String) throws -> [Candidate]; func stream(videoID: String) throws -> ClipStream }`
  - `struct YtDlp: ClipSource` with `init(directories: [String] = YtDlp.defaultDirectories()) throws` (throws `.toolMissing`)
  - Pure statics the tests use: `parseSearch(_: Data) throws -> [Candidate]`, `expiry(of: URL) -> Date?`, `locate(in: [String]) -> URL?`, `environment(for: URL, inherited: [String: String]) -> [String: String]`
  - `static let minimumHeight = 480`, `static let format` (the selector from Global Constraints)

The process-running path (`search`, `stream`) has no unit test — it needs the network. Task 5 covers it live.

- [ ] **Step 1: Write the failing tests**

`Tests/YtDlpTests.swift`:

```swift
import Foundation

func ytDlpTests() {
    test("parseSearch reads yt-dlp's flat playlist JSON") {
        let json = #"""
        {"_type": "playlist", "entries": [
          {"id": "AtKMvNUEPMM", "title": "МакSим - Лучшая ночь (официальный клип)", "channel": "Maksim",
           "duration": 236, "channel_is_verified": true, "view_count": 17913073},
          {"id": "q4E2GwlhV3g", "title": "Макsим - Лучшая ночь", "channel": null,
           "duration": null, "channel_is_verified": null}
        ]}
        """#
        let candidates = try YtDlp.parseSearch(Data(json.utf8))
        expectEqual(candidates, [
            Candidate(id: "AtKMvNUEPMM", title: "МакSим - Лучшая ночь (официальный клип)",
                      channel: "Maksim", duration: 236, isVerified: true),
            Candidate(id: "q4E2GwlhV3g", title: "Макsим - Лучшая ночь",
                      channel: nil, duration: nil, isVerified: false),
        ])
    }

    test("parseSearch reports garbage as a tool failure") {
        do {
            _ = try YtDlp.parseSearch(Data("ERROR: nope".utf8))
            expect(false, "expected a throw")
        } catch ClipError.toolFailed {
        }
    }

    test("expiry is read from HLS manifest paths and from query strings") {
        let manifest = URL(string: "https://manifest.googlevideo.com/api/manifest/hls_playlist/expire/1790000000/ei/abc/playlist/index.m3u8")!
        let direct = URL(string: "https://rr2---sn.googlevideo.com/videoplayback?expire=1790000123&ei=abc")!
        let plain = URL(string: "https://example.com/video.m3u8")!
        expectEqual(YtDlp.expiry(of: manifest), Date(timeIntervalSince1970: 1_790_000_000))
        expectEqual(YtDlp.expiry(of: direct), Date(timeIntervalSince1970: 1_790_000_123))
        expectEqual(YtDlp.expiry(of: plain), nil)
    }

    test("locate returns the first directory holding an executable yt-dlp") {
        let empty = try temporaryDirectory()
        let holder = try temporaryDirectory()
        let tool = holder.appendingPathComponent("yt-dlp")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        expectEqual(YtDlp.locate(in: [empty.path, holder.path]), nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        expectEqual(YtDlp.locate(in: [empty.path, holder.path])?.path, tool.path)
    }

    test("the child PATH leads with yt-dlp's own directory and the Homebrew prefixes") {
        let tool = URL(fileURLWithPath: "/somewhere/bin/yt-dlp")
        let finder = YtDlp.environment(for: tool, inherited: ["PATH": "/usr/bin:/bin", "HOME": "/Users/x"])
        expectEqual(finder["PATH"], "/somewhere/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        expectEqual(finder["HOME"], "/Users/x")

        let bare = YtDlp.environment(for: tool, inherited: [:])
        expectEqual(bare["PATH"], "/somewhere/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    test("init throws toolMissing when yt-dlp is nowhere") {
        do {
            _ = try YtDlp(directories: [try temporaryDirectory().path])
            expect(false, "expected a throw")
        } catch ClipError.toolMissing {
        }
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
runAll()
```

- [ ] **Step 2: Run, watch it fail**

Run: `./build.sh --test`
Expected: compilation fails with `cannot find 'YtDlp' in scope`.

- [ ] **Step 3: Implement**

`Clips/YtDlp.swift`:

```swift
import Foundation

enum ClipError: Error, Equatable {
    case toolMissing
    case unplayable
    case toolFailed(String)
}

struct ClipStream: Equatable {
    let url: URL
    let expires: Date
}

protocol ClipSource {
    func search(_ query: String) throws -> [Candidate]
    func stream(videoID: String) throws -> ClipStream
}

struct YtDlp: ClipSource {
    static let minimumHeight = 480

    /// H.264 only: AVFoundation does not play VP9, and AV1 has no hardware decoder before M3.
    /// HLS only: the https DASH variants take ~14 s to start and report a doubled duration.
    static let format = "bv[vcodec^=avc1][height>=\(minimumHeight)][height<=1080][protocol^=m3u8]"

    /// An app started from Finder or at login gets a bare PATH without the Homebrew prefix.
    static let homebrewDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    let executable: URL

    init(directories: [String] = YtDlp.defaultDirectories()) throws {
        guard let found = YtDlp.locate(in: directories) else { throw ClipError.toolMissing }
        executable = found
    }

    static func defaultDirectories() -> [String] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return homebrewDirectories + path.split(separator: ":").map(String.init)
    }

    static func locate(in directories: [String]) -> URL? {
        directories
            .map { URL(fileURLWithPath: $0).appendingPathComponent("yt-dlp") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func search(_ query: String) throws -> [Candidate] {
        try YtDlp.parseSearch(run(["--flat-playlist", "-J", "ytsearch5:\(query)"]))
    }

    func stream(videoID: String) throws -> ClipStream {
        let output = try run(["-f", YtDlp.format, "--print", "url",
                              "https://www.youtube.com/watch?v=\(videoID)"])
        let line = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: line), url.scheme == "https" else {
            throw ClipError.toolFailed("unexpected output: \(line.prefix(200))")
        }
        return ClipStream(url: url, expires: YtDlp.expiry(of: url) ?? Date().addingTimeInterval(3600))
    }

    static func parseSearch(_ data: Data) throws -> [Candidate] {
        struct Listing: Decodable { let entries: [Candidate] }
        do {
            return try JSONDecoder().decode(Listing.self, from: data).entries
        } catch {
            throw ClipError.toolFailed("unreadable search result: \(error)")
        }
    }

    /// googlevideo URLs carry their own deadline, as "/expire/<unix>/" in HLS manifests and
    /// "expire=<unix>" in direct links.
    static func expiry(of url: URL) -> Date? {
        let text = url.absoluteString
        guard let match = text.range(of: #"[/?&]expire[/=]\d+"#, options: .regularExpression),
              let seconds = TimeInterval(text[match].drop { !$0.isNumber }) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// yt-dlp needs a JavaScript runtime for YouTube; Homebrew installs deno beside it, and
    /// yt-dlp finds it through PATH — which a Finder-launched app does not have.
    static func environment(for executable: URL, inherited: [String: String]) -> [String: String] {
        var environment = inherited
        let path = inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = ([executable.deletingLastPathComponent().path]
                               + homebrewDirectories + [path]).joined(separator: ":")
        return environment
    }

    private func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--no-warnings", "--socket-timeout", "10"] + arguments
        process.environment = YtDlp.environment(for: executable,
                                                inherited: ProcessInfo.processInfo.environment)

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { throw ClipError.toolMissing }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let complaint = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let gone = ["Requested format is not available", "Video unavailable", "Private video"]
            if gone.contains(where: complaint.contains) { throw ClipError.unplayable }
            throw ClipError.toolFailed(String(complaint.suffix(300)))
        }
        return data
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./build.sh --test`
Expected: `28 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Clips/YtDlp.swift Tests/YtDlpTests.swift Tests/main.swift
git commit -m "add yt-dlp search and stream lookup"
```

---

### Task 4: Resolver

**Files:**
- Create: `Clips/ClipResolver.swift`, `Tests/ClipResolverTests.swift`
- Modify: `Tests/main.swift`

**Interfaces:**
- Consumes: `TrackQuery`, `Candidate`, `ClipMatching.searchQuery(for:)`, `ClipMatching.pick(for:from:)` (Task 1); `ClipStore` (Task 2); `ClipSource`, `ClipStream`, `ClipError` (Task 3).
- Produces:
  - `enum ClipResolution: Equatable { case stream(videoID: String, url: URL), none }`
  - `final class ClipResolver` with `init(store: ClipStore, source: ClipSource, now: @escaping () -> Date = Date.init)`
  - `func resolve(_ track: TrackQuery) throws -> ClipResolution` — blocking; throws `ClipError.toolMissing` / `.toolFailed`, never `.unplayable`
  - `static let expiryMargin: TimeInterval` (600)

- [ ] **Step 1: Write the failing tests**

`Tests/ClipResolverTests.swift`:

```swift
import Foundation

private final class FakeSource: ClipSource {
    var candidates: [Candidate] = []
    var streamResult: Result<ClipStream, ClipError> = .failure(.unplayable)
    var searchError: ClipError?
    private(set) var searches: [String] = []
    private(set) var streamRequests: [String] = []

    func search(_ query: String) throws -> [Candidate] {
        searches.append(query)
        if let searchError { throw searchError }
        return candidates
    }

    func stream(videoID: String) throws -> ClipStream {
        streamRequests.append(videoID)
        return try streamResult.get()
    }
}

func resolverTests() {
    let track = TrackQuery(id: "spotify:track:1", artist: "Rick Astley",
                           name: "Never Gonna Give You Up", seconds: 213)
    let official = Candidate(id: "dQw4w9WgXcQ",
                             title: "Rick Astley - Never Gonna Give You Up (Official Video)",
                             channel: "Rick Astley", duration: 214, isVerified: true)
    let url = URL(string: "https://manifest.googlevideo.com/expire/1800003600/index.m3u8")!
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func makeStore() throws -> (ClipStore, URL) {
        let file = try temporaryDirectory().appendingPathComponent("clips.json")
        return (ClipStore(file: file), file)
    }

    test("an unknown track is searched, streamed and remembered") {
        let (store, _) = try makeStore()
        let source = FakeSource()
        source.candidates = [official]
        source.streamResult = .success(ClipStream(url: url, expires: start + 3600))
        let resolver = ClipResolver(store: store, source: source, now: { start })

        expectEqual(try resolver.resolve(track), .stream(videoID: "dQw4w9WgXcQ", url: url))
        expectEqual(source.searches, ["Rick Astley Never Gonna Give You Up official video"])
        expectEqual(store.lookup(track.id), .video("dQw4w9WgXcQ"))
    }

    test("a repeat within the URL's lifetime touches nothing") {
        let (store, _) = try makeStore()
        let source = FakeSource()
        source.candidates = [official]
        source.streamResult = .success(ClipStream(url: url, expires: start + 3600))
        let resolver = ClipResolver(store: store, source: source, now: { start })

        _ = try resolver.resolve(track)
        _ = try resolver.resolve(track)
        expectEqual(source.searches.count, 1)
        expectEqual(source.streamRequests, ["dQw4w9WgXcQ"])
    }

    test("a URL inside the expiry margin is resolved again") {
        let (store, _) = try makeStore()
        let source = FakeSource()
        source.candidates = [official]
        source.streamResult = .success(ClipStream(url: url, expires: start + 3600))
        var clock = start
        let resolver = ClipResolver(store: store, source: source, now: { clock })

        _ = try resolver.resolve(track)
        clock = start + 3600 - 599
        _ = try resolver.resolve(track)
        expectEqual(source.searches.count, 1)
        expectEqual(source.streamRequests.count, 2)
    }

    test("a mapped track skips the search after a relaunch") {
        let (store, file) = try makeStore()
        store.record(.video("dQw4w9WgXcQ"), for: track.id)
        let source = FakeSource()
        source.streamResult = .success(ClipStream(url: url, expires: start + 3600))
        let resolver = ClipResolver(store: ClipStore(file: file), source: source, now: { start })

        expectEqual(try resolver.resolve(track), .stream(videoID: "dQw4w9WgXcQ", url: url))
        expectEqual(source.searches, [])
    }

    test("no acceptable candidate is remembered as a miss") {
        let (store, _) = try makeStore()
        let source = FakeSource()
        source.candidates = [Candidate(id: "x", title: "Rick Astley - Never Gonna Give You Up (Lyrics)",
                                       channel: "7clouds", duration: 213, isVerified: true)]
        let resolver = ClipResolver(store: store, source: source, now: { start })

        expectEqual(try resolver.resolve(track), ClipResolution.none)
        expectEqual(try resolver.resolve(track), ClipResolution.none)
        expectEqual(source.searches.count, 1)
        expectEqual(source.streamRequests, [])
    }

    test("a video without a playable format is remembered as a miss") {
        let (store, _) = try makeStore()
        let source = FakeSource()
        source.candidates = [official]
        source.streamResult = .failure(.unplayable)
        let resolver = ClipResolver(store: store, source: source, now: { start })

        expectEqual(try resolver.resolve(track), ClipResolution.none)
        expectEqual(store.lookup(track.id), ClipStore.Entry.none)
    }

    test("tool failures propagate and are not remembered") {
        let (store, _) = try makeStore()
        let source = FakeSource()
        source.searchError = .toolFailed("network down")
        let resolver = ClipResolver(store: store, source: source, now: { start })

        do {
            _ = try resolver.resolve(track)
            expect(false, "expected a throw")
        } catch ClipError.toolFailed {
        }
        expectEqual(store.lookup(track.id), nil)
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
runAll()
```

- [ ] **Step 2: Run, watch it fail**

Run: `./build.sh --test`
Expected: compilation fails with `cannot find 'ClipResolver' in scope`.

- [ ] **Step 3: Implement**

`Clips/ClipResolver.swift`:

```swift
import Foundation

enum ClipResolution: Equatable {
    case stream(videoID: String, url: URL)
    case none
}

/// Blocking by design: a resolve is two yt-dlp runs of a few seconds each, so the caller
/// owns the queue it runs on and decides what to do with a result that arrives too late.
final class ClipResolver {
    /// A stream that dies mid-clip is worse than a fresh resolve, so a URL close to its
    /// deadline is not handed out.
    static let expiryMargin: TimeInterval = 600

    private let store: ClipStore
    private let source: ClipSource
    private let now: () -> Date
    private var streams: [String: ClipStream] = [:]

    init(store: ClipStore, source: ClipSource, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.source = source
        self.now = now
    }

    func resolve(_ track: TrackQuery) throws -> ClipResolution {
        let videoID: String
        switch store.lookup(track.id) {
        case .some(.none):
            return .none
        case .some(.video(let known)):
            videoID = known
        case nil:
            let candidates = try source.search(ClipMatching.searchQuery(for: track))
            guard let picked = ClipMatching.pick(for: track, from: candidates) else {
                store.record(.none, for: track.id)
                return .none
            }
            videoID = picked.id
        }

        do {
            let stream = try liveStream(for: videoID)
            store.record(.video(videoID), for: track.id)
            return .stream(videoID: videoID, url: stream.url)
        } catch ClipError.unplayable {
            store.record(.none, for: track.id)
            return .none
        }
    }

    private func liveStream(for videoID: String) throws -> ClipStream {
        if let cached = streams[videoID],
           cached.expires.timeIntervalSince(now()) > Self.expiryMargin {
            return cached
        }
        let fresh = try source.stream(videoID: videoID)
        streams[videoID] = fresh
        return fresh
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./build.sh --test`
Expected: `35 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Clips/ClipResolver.swift Tests/ClipResolverTests.swift Tests/main.swift
git commit -m "add clip resolver"
```

---

### Task 5: Live harness and the spec's Part 2 checks

**Files:**
- Create: `Tools/resolve/main.swift`
- Modify: `build.sh` (the `--test` branch)
- Modify: `docs/superpowers/specs/2026-09-18-spotify-clips-design.md` (measurement table, only if the numbers differ)

**Interfaces:**
- Consumes: `TrackQuery`, `ClipStore`, `YtDlp`, `ClipResolver`, `ClipResolution`, `ClipError`.
- Produces: `.build/resolve "<artist>" "<title>" <seconds>` — resolves twice in one process and prints both timings; exit 69 when `yt-dlp` is missing, 64 on bad arguments, 1 on any other failure. Its mapping lives in `$TMPDIR/loopscape-resolve-clips.json`, never in the app's folder.

- [ ] **Step 1: Write the harness**

`Tools/resolve/main.swift`:

```swift
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, let seconds = Int(arguments[2]) else {
    print("usage: resolve <artist> <title> <seconds>")
    exit(64)
}

let track = TrackQuery(id: "cli:\(arguments[0]):\(arguments[1])", artist: arguments[0],
                       name: arguments[1], seconds: seconds)
let storeFile = FileManager.default.temporaryDirectory.appendingPathComponent("loopscape-resolve-clips.json")

do {
    let resolver = ClipResolver(store: ClipStore(file: storeFile), source: try YtDlp())
    var lastURL: URL?
    for attempt in ["cold", "repeat"] {
        let started = Date()
        let resolution = try resolver.resolve(track)
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(started))
        switch resolution {
        case .stream(let videoID, let url):
            print("\(attempt): \(elapsed) https://youtu.be/\(videoID)")
            lastURL = url
        case .none:
            print("\(attempt): \(elapsed) no clip")
        }
    }
    if let lastURL { print("stream: \(lastURL.absoluteString)") }
    print("mapping kept in \(storeFile.path)")
} catch ClipError.toolMissing {
    print("yt-dlp not found — brew install yt-dlp")
    exit(69)
} catch {
    print("failed: \(error)")
    exit(1)
}
```

- [ ] **Step 2: Build it with the tests**

In `build.sh`, inside the `--test` branch, between the line that runs `.build/tests` and `exit 0`:

```bash
    echo "==> compiling resolve"
    swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
        -o "$HERE/.build/resolve" "$HERE"/Clips/*.swift "$HERE/Tools/resolve/main.swift"
```

Run: `./build.sh --test`
Expected: `35 tests, 0 failures`, then `==> compiling resolve` with no errors.

- [ ] **Step 3: The missing-tool path, while the tool is still missing**

Run: `command -v yt-dlp || .build/resolve "a" "b" 1; echo "exit=$?"`

Expected when `yt-dlp` is not installed (the state of this Mac on 2026-09-18): `yt-dlp not found — brew install yt-dlp` and `exit=69`. If `yt-dlp` is already installed the command prints its path and this step is covered by the unit test `init throws toolMissing when yt-dlp is nowhere` alone.

- [ ] **Step 4: Install `yt-dlp`**

Run: `command -v yt-dlp deno`
Expected: two paths under `/opt/homebrew/bin`. If either is missing, stop and ask Aktan to run `brew install yt-dlp` (the formula brings `deno`, the JavaScript runtime `yt-dlp` needs for YouTube) — do not install system software unasked.

- [ ] **Step 5: Unknown track, then the same track from a second process**

```bash
rm -f "$TMPDIR/loopscape-resolve-clips.json"
.build/resolve "Rick Astley" "Never Gonna Give You Up" 213
.build/resolve "Rick Astley" "Never Gonna Give You Up" 213
```

Expected, first run: `cold:` ≤ 8 s with `https://youtu.be/dQw4w9WgXcQ`, `repeat: 0.0s`, and a `stream:` line starting `https://manifest.googlevideo.com/`.
Expected, second run: `cold:` ≤ 5 s (mapping hit, no search), same video.

- [ ] **Step 6: A track with no clip, and one below the minimum height**

```bash
.build/resolve "Radiohead" "Treefingers" 222
.build/resolve "МакSим" "Лучшая ночь" 234
grep -c '"checked"' "$TMPDIR/loopscape-resolve-clips.json"
grep -c '"video"' "$TMPDIR/loopscape-resolve-clips.json"
```

Expected: both print `no clip` for `cold` and `repeat: 0.0s no clip`; the counts are `3` and `1` — three records, only Rick Astley's has a video.

- [ ] **Step 7: The PATH a Finder-launched app gets**

```bash
env -i HOME="$HOME" TMPDIR="$TMPDIR" PATH=/usr/bin:/bin:/usr/sbin:/sbin .build/resolve "The Weeknd" "Blinding Lights" 200
```

Expected: `https://youtu.be/4NRXx6U8ABQ` — `yt-dlp` was found in `/opt/homebrew/bin` and found `deno` without the shell's `PATH`. The same check against the real app launched with `open` belongs to Part 4, where the resolver is first wired in.

- [ ] **Step 8: The stream really plays**

Copy the `stream:` URL from Step 7 and open it:

```bash
open -a "QuickTime Player" "<the stream URL>"
```

Expected: the video starts within a couple of seconds at 480p or better, silent (the selector takes the video-only variant).

- [ ] **Step 9: Record what was measured**

If the timings from Step 4 differ from the spec's "Prototype resolver end to end" row by more than a second, update that row and the pass criteria in the spec's Part 2 section to match reality, saying which `yt-dlp` and JS runtime produced them.

- [ ] **Step 10: Commit**

```bash
git add build.sh Tools/resolve/main.swift docs/superpowers/specs/2026-09-18-spotify-clips-design.md
git commit -m "add resolve harness for live clip lookups"
```

---

## Done when

- `./build.sh --test` prints `35 tests, 0 failures` and builds `.build/resolve`.
- Steps 3–8 of Task 5 gave the expected results, with the measured timings reported to Aktan.
- `./build.sh --dest .build/check` still builds the app, and `git diff main -- Loopscape.swift LoopscapeSaver.swift make-dmg.sh` is empty.
