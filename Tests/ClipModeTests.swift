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

    func showing(at clock: Clock) -> ClipMode {
        var mode = ClipMode(isEnabled: true, now: { clock.now })
        _ = mode.trackChanged(track(at: 30))
        _ = mode.resolved(.found(videoID: "5NV6Rdv1a3I", url: url), generation: 1)
        return mode
    }

    test("the mode is resolving from a track change until the outcome") {
        var mode = ClipMode(isEnabled: true)
        expect(!mode.isResolving)
        _ = mode.trackChanged(track())
        expect(mode.isResolving)
        _ = mode.resolved(.notFound, generation: 1)
        expect(!mode.isResolving)
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
                    [.play(videoID: "5NV6Rdv1a3I", url: url, position: 34 + ClipMode.startLead)])
        expect(!mode.isClipPaused, "a playing track plays its clip")
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
        expect(mode.isClipPaused, "a paused track holds its clip")
        expectEqual(mode.clipPosition, 32)
    }

    test("only the last of several quick skips gets a clip") {
        let clock = Clock()
        var mode = ClipMode(isEnabled: true, now: { clock.now })
        for id in ["A", "B", "C", "D", "E"] { _ = mode.trackChanged(track("spotify:track:\(id)")) }
        expect(!mode.isCurrent(1), "the first skip's resolve must be voided")
        expect(mode.isCurrent(5), "the last skip's resolve must run")
        expectEqual(mode.resolved(.found(videoID: "first", url: url), generation: 1), [])
        expectEqual(mode.resolved(.found(videoID: "last", url: url), generation: 5),
                    [.play(videoID: "last", url: url, position: 30 + ClipMode.startLead)])
    }

    test("a track without a video leaves the pack alone, paused or not") {
        var mode = ClipMode(isEnabled: true)
        _ = mode.trackChanged(track())
        expectEqual(mode.resolved(.notFound, generation: 1), [])
        expectEqual(mode.trackChanged(track(playing: false)), [])
        expectEqual(mode.trackChanged(track(playing: true)), [])
        expect(mode.clipPosition == nil, "no clip is on screen")
    }

    test("the old clip stays until the next track resolves, then gives way if it has none") {
        var mode = showing()
        expectEqual(mode.trackChanged(track("spotify:track:B")),
                    [.resolve(query("spotify:track:B"), generation: 2)])
        expectEqual(mode.trackChanged(track("spotify:track:B", playing: false)), [.pause])
        expectEqual(mode.resolved(.failed, generation: 2), [.leave])
    }

    test("Spotify's pause and resume pause and resume the clip") {
        let clock = Clock()
        var mode = showing(at: clock)
        clock.now += 10
        expectEqual(mode.trackChanged(track(at: 40, playing: false)), [.pause])
        clock.now += 60
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
        expect(mode.clipPosition == nil, "no clip is on screen after the second failure")
    }

    test("switching clips off takes the clip down and voids the resolve in flight") {
        var mode = showing()
        _ = mode.trackChanged(track("spotify:track:B"))
        expectEqual(mode.setEnabled(false), [.leave])
        expectEqual(mode.resolved(.found(videoID: "b", url: url), generation: 2), [])
    }

    test("a pack picked from the menu mid-clip holds until the next track") {
        var mode = showing()
        mode.packChosen()
        expectEqual(mode.trackChanged(track(at: 40, playing: false)), [])
        expect(mode.clipPosition == nil, "the pack is on screen, not a clip")
        expectEqual(mode.trackChanged(track(at: 40, playing: true)), [])
        expectEqual(mode.trackChanged(track("spotify:track:B")),
                    [.resolve(query("spotify:track:B"), generation: 3)])

        var resolving = ClipMode(isEnabled: true)
        _ = resolving.trackChanged(track())
        resolving.packChosen()
        expectEqual(resolving.resolved(.found(videoID: "5NV6Rdv1a3I", url: url), generation: 1), [])
    }

    test("switching clips on mid-track, or playing a restored track, starts a resolve") {
        var mode = ClipMode(isEnabled: false)
        _ = mode.trackChanged(track())
        expectEqual(mode.setEnabled(true), [.resolve(query(), generation: 1)])

        var restored = ClipMode(isEnabled: true)
        expectEqual(restored.trackChanged(track(playing: false)), [])
        expectEqual(restored.trackChanged(track(playing: true)), [.resolve(query(), generation: 2)])
    }

    test("a failed resolve is retried when the same track resumes") {
        var mode = ClipMode(isEnabled: true)
        _ = mode.trackChanged(track())
        expectEqual(mode.resolved(.failed, generation: 1), [.retryLater(trackID: "spotify:track:A", after: ClipMode.retryDelay)])
        expectEqual(mode.trackChanged(track(at: 40, playing: false)), [])
        expectEqual(mode.trackChanged(track(at: 40)), [.resolve(query(), generation: 2)])
    }

    test("a track with no video is not searched again on resume") {
        var mode = ClipMode(isEnabled: true)
        _ = mode.trackChanged(track())
        _ = mode.resolved(.notFound, generation: 1)
        _ = mode.trackChanged(track(at: 40, playing: false))
        expectEqual(mode.trackChanged(track(at: 40)), [])
    }

    test("a stream lost while offline waits for the network instead of searching") {
        var mode = showing()
        expectEqual(mode.streamFailed(offline: true), [])
        expectEqual(mode.retryFailed(), [.resolve(query(), generation: 2)])
    }

    test("a resolve that failed is retried when the network returns") {
        var mode = ClipMode(isEnabled: true)
        _ = mode.trackChanged(track())
        _ = mode.resolved(.failed, generation: 1)
        expectEqual(mode.retryFailed(), [.resolve(query(), generation: 2)])
    }

    test("the network returning leaves a clip on screen and a track without a video alone") {
        var shown = showing()
        expectEqual(shown.retryFailed(), [])
        var missing = ClipMode(isEnabled: true)
        _ = missing.trackChanged(track())
        _ = missing.resolved(.notFound, generation: 1)
        expectEqual(missing.retryFailed(), [])
    }

    test("a paused track waits for its resume, not the network") {
        var mode = ClipMode(isEnabled: true)
        _ = mode.trackChanged(track())
        _ = mode.resolved(.failed, generation: 1)
        _ = mode.trackChanged(track(at: 40, playing: false))
        expectEqual(mode.retryFailed(), [])
    }

    test("a repeat of the same track sends the clip back to the start") {
        let clock = Clock()
        var mode = showing(at: clock)
        clock.now += 200
        expectEqual(mode.trackChanged(track(at: 0)), [.seek(position: ClipMode.startLead), .resume])
    }

    test("a scrub shows up at the next event and moves the clip") {
        let clock = Clock()
        var mode = showing(at: clock)
        clock.now += 10
        expectEqual(mode.trackChanged(track(at: 100, playing: false)), [.seek(position: 100), .pause])
    }

    test("a position within the drift allowance does not seek") {
        let clock = Clock()
        var mode = showing(at: clock)
        clock.now += 10
        expectEqual(mode.trackChanged(track(at: 41, playing: false)), [.pause])
    }

    test("a failed resolve of a playing track asks for one retry later, not a loop") {
        var mode = ClipMode(isEnabled: true)
        _ = mode.trackChanged(track())
        expectEqual(mode.resolved(.failed, generation: 1), [.retryLater(trackID: "spotify:track:A", after: ClipMode.retryDelay)])
        expectEqual(mode.retryFailed(), [.resolve(query(), generation: 2)])
        expectEqual(mode.resolved(.failed, generation: 2), [])
    }

    test("a delayed retry belongs to its track, and a track played again gets a new one") {
        var mode = ClipMode(isEnabled: true)
        _ = mode.trackChanged(track("spotify:track:A"))
        _ = mode.resolved(.failed, generation: 1)
        _ = mode.trackChanged(track("spotify:track:B"))
        expectEqual(mode.resolved(.failed, generation: 2), [.retryLater(trackID: "spotify:track:B", after: ClipMode.retryDelay)])
        expectEqual(mode.retryFailed(trackID: "spotify:track:A"), [])
        expectEqual(mode.retryFailed(trackID: "spotify:track:B"), [.resolve(query("spotify:track:B"), generation: 3)])
        _ = mode.resolved(.found(videoID: "b", url: url), generation: 3)
        _ = mode.trackChanged(track("spotify:track:A"))
        expectEqual(mode.resolved(.failed, generation: 4), [.leave, .retryLater(trackID: "spotify:track:A", after: ClipMode.retryDelay)])
    }

    test("the previous clip stays paused with Spotify while the next track resolves") {
        var mode = showing()
        _ = mode.trackChanged(track("spotify:track:B"))
        expectEqual(mode.trackChanged(track("spotify:track:B", playing: false)), [.pause])
        expect(mode.isClipPaused, "a paused Spotify must hold the clip still on screen")
        _ = mode.trackChanged(track("spotify:track:B"))
        expect(!mode.isClipPaused, "playing again releases it")
    }

    func resolvedQuery(_ effects: [ClipEffect]) -> TrackQuery? {
        guard effects.count == 1, case .resolve(let query, _) = effects[0] else { return nil }
        return query
    }

    func failThree(_ mode: inout ClipMode) {
        for (index, id) in ["X", "Y", "Z"].enumerated() {
            _ = mode.trackChanged(track("spotify:track:\(id)"))
            _ = mode.resolved(.failed, generation: index + 1)
        }
    }

    test("three failed resolves in a row back off for a quarter of an hour") {
        let clock = Clock()
        var mode = ClipMode(isEnabled: true, now: { clock.now })
        failThree(&mode)
        expectEqual(mode.trackChanged(track("spotify:track:A")),
                    [.retryLater(trackID: "spotify:track:A", after: ClipMode.backoff)])
        expectEqual(mode.retryFailed(trackID: "spotify:track:A"),
                    [.retryLater(trackID: "spotify:track:A", after: ClipMode.backoff)])
        clock.now += ClipMode.backoff + 1
        expectEqual(resolvedQuery(mode.trackChanged(track("spotify:track:B"))), query("spotify:track:B"))
    }

    test("the third failure asks for no delayed retry") {
        var mode = ClipMode(isEnabled: true)
        _ = mode.trackChanged(track("spotify:track:X"))
        _ = mode.resolved(.failed, generation: 1)
        _ = mode.trackChanged(track("spotify:track:Y"))
        _ = mode.resolved(.failed, generation: 2)
        _ = mode.trackChanged(track("spotify:track:Z"))
        expectEqual(mode.resolved(.failed, generation: 3), [])
    }

    test("the network returning lifts the back-off") {
        var mode = ClipMode(isEnabled: true)
        failThree(&mode)
        _ = mode.trackChanged(track("spotify:track:A"))
        expectEqual(resolvedQuery(mode.retryFailed()), query("spotify:track:A"))
    }

    test("an answer from YouTube resets the failure count") {
        var mode = ClipMode(isEnabled: true)
        _ = mode.trackChanged(track("spotify:track:X"))
        _ = mode.resolved(.failed, generation: 1)
        _ = mode.trackChanged(track("spotify:track:Y"))
        _ = mode.resolved(.notFound, generation: 2)
        _ = mode.trackChanged(track("spotify:track:Z"))
        _ = mode.resolved(.failed, generation: 3)
        expectEqual(mode.trackChanged(track("spotify:track:A")), [.resolve(query("spotify:track:A"), generation: 4)])
    }

    test("the network returning lifts the back-off even with nothing to retry right now") {
        var mode = ClipMode(isEnabled: true)
        failThree(&mode)
        _ = mode.trackChanged(track("spotify:track:A", playing: false))
        expectEqual(mode.retryFailed(), [])
        expectEqual(resolvedQuery(mode.trackChanged(track("spotify:track:B"))), query("spotify:track:B"))
    }

    test("a missing yt-dlp neither counts toward the back-off nor asks for a delayed retry") {
        var mode = ClipMode(isEnabled: true)
        for (index, id) in ["X", "Y", "Z"].enumerated() {
            _ = mode.trackChanged(track("spotify:track:\(id)"))
            expectEqual(mode.resolved(.toolMissing, generation: index + 1), [])
        }
        expectEqual(resolvedQuery(mode.trackChanged(track("spotify:track:A"))), query("spotify:track:A"))
    }

    test("a track started during the back-off is retried when it ends") {
        let clock = Clock()
        var mode = ClipMode(isEnabled: true, now: { clock.now })
        failThree(&mode)
        clock.now += 600
        expectEqual(mode.trackChanged(track("spotify:track:A")),
                    [.retryLater(trackID: "spotify:track:A", after: ClipMode.backoff - 600)])
        clock.now += ClipMode.backoff - 600
        expectEqual(resolvedQuery(mode.retryFailed(trackID: "spotify:track:A")), query("spotify:track:A"))
    }
}
