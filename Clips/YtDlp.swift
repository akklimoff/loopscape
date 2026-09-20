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
