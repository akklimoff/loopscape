import Foundation

func onDemandYtDlpTests() {
    test("a yt-dlp installed after launch is found by the next call") {
        let holder = try temporaryDirectory()
        let source = OnDemandYtDlp(directories: { [holder.path] })
        do {
            _ = try source.search("anything")
            expect(false, "expected a throw before yt-dlp exists")
        } catch ClipError.toolMissing {
        }

        let tool = holder.appendingPathComponent("yt-dlp")
        try Data("#!/bin/sh\necho '{\"entries\": []}'\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        expectEqual(try source.search("anything"), [])
    }

    test("a missing yt-dlp fails a stream request as toolMissing") {
        let source = OnDemandYtDlp(directories: { [] })
        do {
            _ = try source.stream(videoID: "dQw4w9WgXcQ")
            expect(false, "expected a throw")
        } catch ClipError.toolMissing {
        }
    }
}
