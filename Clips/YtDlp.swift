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
    static let timeout: TimeInterval = 20

    /// VP9 first: YouTube serves it over HLS up to 4K, AVFoundation decodes it there in
    /// hardware on Apple silicon, while H.264 stops at 1080p. No AV1: no hardware decoder
    /// before M3. HLS only: the https DASH variants take ~14 s to start and report a doubled
    /// duration.
    static let format = "bv[vcodec^=vp09][height>=\(minimumHeight)][height<=2160][protocol^=m3u8]"
        + "/bv[vcodec^=avc1][height>=\(minimumHeight)][height<=1080][protocol^=m3u8]"

    /// An app started from Finder or at login gets a bare PATH without the Homebrew prefix.
    static let homebrewDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    let executable: URL
    private let now: () -> Date

    init(directories: [String] = YtDlp.defaultDirectories(),
         now: @escaping () -> Date = Date.init) throws {
        guard let found = YtDlp.locate(in: directories) else { throw ClipError.toolMissing }
        executable = found
        self.now = now
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
        return try YtDlp.parseStream(output, now: now())
    }

    static func parseSearch(_ data: Data) throws -> [Candidate] {
        struct Listing: Decodable { let entries: [Candidate] }
        do {
            return try JSONDecoder().decode(Listing.self, from: data).entries
        } catch {
            throw ClipError.toolFailed("unreadable search result: \(error)")
        }
    }

    static func parseStream(_ data: Data, now: Date) throws -> ClipStream {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: line), url.scheme == "https" else {
            throw ClipError.toolFailed("unexpected output: \(line.prefix(200))")
        }
        return ClipStream(url: url, expires: expiry(of: url) ?? now.addingTimeInterval(3600))
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
        process.arguments = ["--no-warnings", "--ignore-config", "--socket-timeout", "10",
                             "--retries", "1", "--extractor-retries", "1"] + arguments
        process.environment = YtDlp.environment(for: executable,
                                                inherited: ProcessInfo.processInfo.environment)

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { throw ClipError.toolMissing }

        // yt-dlp retries on its own and runs YouTube's player JS in a separate runtime, and
        // --socket-timeout bounds neither, so the run needs a deadline of its own.
        let lock = NSLock()
        var expired = false
        let watchdog = DispatchWorkItem {
            lock.lock()
            defer { lock.unlock() }
            guard process.isRunning else { return }
            expired = true
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + YtDlp.timeout, execute: watchdog)

        var complaint = ""
        let reading = DispatchGroup()
        DispatchQueue.global().async(group: reading) {
            complaint = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        reading.wait()
        process.waitUntilExit()
        watchdog.cancel()

        lock.lock()
        let timedOut = expired
        lock.unlock()
        if timedOut { throw ClipError.toolFailed("yt-dlp timed out after 20 s") }

        guard process.terminationStatus == 0 else {
            let gone = ["Requested format is not available", "Video unavailable", "Private video"]
            if gone.contains(where: complaint.contains) { throw ClipError.unplayable }
            throw ClipError.toolFailed(String(complaint.suffix(300)))
        }
        return data
    }
}

/// yt-dlp may be installed while the app runs, so it is looked up on every call rather than
/// once at launch.
struct OnDemandYtDlp: ClipSource {
    var directories: () -> [String] = YtDlp.defaultDirectories

    func search(_ query: String) throws -> [Candidate] {
        try YtDlp(directories: directories()).search(query)
    }

    func stream(videoID: String) throws -> ClipStream {
        try YtDlp(directories: directories()).stream(videoID: videoID)
    }
}
