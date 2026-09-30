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
