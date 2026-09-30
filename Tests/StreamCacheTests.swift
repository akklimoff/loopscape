import Foundation

func streamCacheTests() {
    let url = URL(string: "https://manifest.googlevideo.com/expire/1800003600/index.m3u8")!
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    test("streams round-trip through the file") {
        let file = try temporaryDirectory().appendingPathComponent("streams.json")
        StreamCache(file: file, variant: "f", now: { start }).record(ClipStream(url: url, expires: start + 3600), for: "v")
        expectEqual(StreamCache(file: file, variant: "f", now: { start }).lookup("v"),
                    ClipStream(url: url, expires: start + 3600))
        expectEqual(StreamCache(file: file, variant: "f", now: { start }).lookup("other"), nil)
    }

    test("streams picked for another format are ignored") {
        let file = try temporaryDirectory().appendingPathComponent("streams.json")
        StreamCache(file: file, variant: "old", now: { start }).record(ClipStream(url: url, expires: start + 3600), for: "v")
        expectEqual(StreamCache(file: file, variant: "new", now: { start }).lookup("v"), nil)
    }

    test("expired streams are dropped from the file on the next write") {
        let file = try temporaryDirectory().appendingPathComponent("streams.json")
        var clock = start
        let cache = StreamCache(file: file, variant: "f", now: { clock })
        cache.record(ClipStream(url: url, expires: start + 60), for: "old")
        clock = start + 120
        cache.record(ClipStream(url: url, expires: start + 3600), for: "new")
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        expect(!text.contains("\"old\""), "expired entry still written")
        expect(text.contains("\"new\""), "fresh entry missing")
    }

    test("a forgotten stream is gone after a relaunch too") {
        let file = try temporaryDirectory().appendingPathComponent("streams.json")
        let cache = StreamCache(file: file, variant: "f", now: { start })
        cache.record(ClipStream(url: url, expires: start + 3600), for: "v")
        cache.forget("v")
        expectEqual(StreamCache(file: file, variant: "f", now: { start }).lookup("v"), nil)
    }

    test("a missing or unreadable file is an empty cache") {
        let directory = try temporaryDirectory()
        let garbage = directory.appendingPathComponent("garbage.json")
        try Data("not json".utf8).write(to: garbage)
        expectEqual(StreamCache(file: garbage, variant: "f").lookup("v"), nil)
        expectEqual(StreamCache(file: directory.appendingPathComponent("absent.json"), variant: "f").lookup("v"), nil)
    }
}
