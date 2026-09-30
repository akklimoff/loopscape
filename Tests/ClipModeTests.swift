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

    test("a pack picked from the menu mid-clip holds until the next track") {
        var mode = showing()
        mode.packChosen()
        expectEqual(mode.trackChanged(track(at: 40, playing: false)), [])
        expect(mode.clipPlayback == nil, "the pack is on screen, not a clip")
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
}
