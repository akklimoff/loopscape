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

    test("a measured offset is kept with the track's video until a new video is recorded") {
        let file = try temporaryDirectory().appendingPathComponent("clips.json")
        let store = ClipStore(file: file)
        store.record(.video("v"), for: "a")
        expectEqual(store.offset(for: "a"), nil)
        store.recordOffset(2.05, for: "a")
        expectEqual(ClipStore(file: file).offset(for: "a"), 2.05)
        expectEqual(store.lookup("a"), .video("v"))
        store.record(.video("w"), for: "a")
        expectEqual(store.offset(for: "a"), nil)
    }

    test("an offset is not recorded for a track without a video") {
        let file = try temporaryDirectory().appendingPathComponent("clips.json")
        let store = ClipStore(file: file)
        store.recordOffset(1, for: "a")
        expectEqual(store.lookup("a"), nil)
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

    test("a video id that is not a usable string makes the entry unreadable") {
        let file = try temporaryDirectory().appendingPathComponent("clips.json")
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = ISO8601DateFormatter().string(from: clock)
        let edited = """
        {
          "empty": { "video": "", "checked": "\(fresh)" },
          "numeric": { "video": 5, "checked": "\(fresh)" }
        }
        """
        try Data(edited.utf8).write(to: file)
        let store = ClipStore(file: file, now: { clock })
        expectEqual(store.lookup("empty"), nil)
        expectEqual(store.lookup("numeric"), nil)
    }

    test("a corrupt file starts empty instead of crashing") {
        let file = try temporaryDirectory().appendingPathComponent("clips.json")
        try Data("not json".utf8).write(to: file)
        let store = ClipStore(file: file)
        expectEqual(store.lookup("a"), nil)
        store.record(.video("v"), for: "a")
        expectEqual(ClipStore(file: file).lookup("a"), .video("v"))
    }

    test("one malformed entry does not take the others down, and survives a write") {
        let file = try temporaryDirectory().appendingPathComponent("clips.json")
        let edited = #"""
        {
          "pinned": { "video": "dQw4w9WgXcQ" },
          "broken": { "video": 5, "checked": "yesterday" },
          "miss-without-date": {}
        }
        """#
        try Data(edited.utf8).write(to: file)
        let store = ClipStore(file: file)
        expectEqual(store.lookup("pinned"), .video("dQw4w9WgXcQ"))
        expectEqual(store.lookup("broken"), nil)
        expectEqual(store.lookup("miss-without-date"), nil)

        store.record(.video("v"), for: "new")
        let reopened = ClipStore(file: file)
        expectEqual(reopened.lookup("pinned"), .video("dQw4w9WgXcQ"))
        expectEqual(reopened.lookup("new"), .video("v"))
        let raw = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        expect(raw.contains("\"broken\""), "the entry that could not be read was dropped from the file")
    }

    test("an edit made while the store is open is honoured and survives the next write") {
        let file = try temporaryDirectory().appendingPathComponent("clips.json")
        let store = ClipStore(file: file)
        store.record(.video("found"), for: "a")

        let pinned = #"{ "a": { "video": "pinned" } }"#
        try Data(pinned.utf8).write(to: file)
        expectEqual(store.lookup("a"), .video("pinned"))

        store.record(.none, for: "b")
        expectEqual(ClipStore(file: file).lookup("a"), .video("pinned"))
        expectEqual(ClipStore(file: file).lookup("b"), ClipStore.Entry.none)
    }
}
