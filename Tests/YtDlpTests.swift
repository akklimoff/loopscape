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

    test("parseStream takes the deadline the URL carries") {
        let line = "https://rr2---sn.googlevideo.com/videoplayback?expire=1790000123&ei=abc\n"
        let stream = try YtDlp.parseStream(Data(line.utf8), now: Date(timeIntervalSince1970: 1_780_000_000))
        expectEqual(stream.url, URL(string: "https://rr2---sn.googlevideo.com/videoplayback?expire=1790000123&ei=abc")!)
        expectEqual(stream.expires, Date(timeIntervalSince1970: 1_790_000_123))
    }

    test("parseStream falls back to an hour from now when the URL carries none") {
        let clock = Date(timeIntervalSince1970: 1_780_000_000)
        let stream = try YtDlp.parseStream(Data("  https://example.com/video.m3u8  ".utf8), now: clock)
        expectEqual(stream.url, URL(string: "https://example.com/video.m3u8")!)
        expectEqual(stream.expires, clock + 3600)
    }

    test("parseStream reports a non-https line and empty output as tool failures") {
        for output in ["ERROR: Requested format is not available", ""] {
            do {
                _ = try YtDlp.parseStream(Data(output.utf8), now: Date(timeIntervalSince1970: 0))
                expect(false, "expected a throw for \(output)")
            } catch ClipError.toolFailed {
            }
        }
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

    test("the format prefers VP9 up to 1440p and falls back to H.264 up to 1080p, HLS only") {
        expectEqual(YtDlp.format,
                    "bv[vcodec^=vp09][height>=480][height<=1440][protocol^=m3u8]"
                    + "/bv[vcodec^=avc1][height>=480][height<=1080][protocol^=m3u8]")
    }

    test("terminateRunning stops a yt-dlp run in flight") {
        let holder = try temporaryDirectory()
        let tool = holder.appendingPathComponent("yt-dlp")
        try Data("#!/bin/sh\nexec sleep 10\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let ytDlp = try YtDlp(directories: [holder.path])

        let started = Date()
        var thrown: Error?
        let done = DispatchGroup()
        DispatchQueue.global().async(group: done) {
            do { _ = try ytDlp.search("anything") } catch { thrown = error }
        }
        Thread.sleep(forTimeInterval: 0.5)
        YtDlp.terminateRunning()
        expect(done.wait(timeout: .now() + 3) == .success, "run still going after terminateRunning")
        expect(thrown != nil, "a terminated run must throw")
        expect(Date().timeIntervalSince(started) < 4, "run was not cut short")
    }
}
