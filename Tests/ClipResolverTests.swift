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
