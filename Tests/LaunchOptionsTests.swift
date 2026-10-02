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
