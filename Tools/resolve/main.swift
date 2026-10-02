import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, let seconds = Int(arguments[2]) else {
    print("usage: resolve <artist> <title> <seconds>")
    exit(64)
}

let track = TrackQuery(id: "cli:\(arguments[0]):\(arguments[1])", artist: arguments[0],
                       name: arguments[1], seconds: seconds)
let storeFile = FileManager.default.temporaryDirectory.appendingPathComponent("loopscape-resolve-clips.json")

do {
    let resolver = ClipResolver(store: ClipStore(file: storeFile), source: try YtDlp())
    var lastURL: URL?
    for attempt in ["cold", "repeat"] {
        let started = Date()
        let resolution = try resolver.resolve(track)
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(started))
        switch resolution {
        case .stream(let videoID, let url, _):
            print("\(attempt): \(elapsed) https://youtu.be/\(videoID)")
            lastURL = url
        case .none:
            print("\(attempt): \(elapsed) no clip")
        }
    }
    if let lastURL { print("stream: \(lastURL.absoluteString)") }
    print("mapping kept in \(storeFile.path)")
} catch ClipError.toolMissing {
    print("yt-dlp not found — brew install yt-dlp")
    exit(69)
} catch {
    print("failed: \(error)")
    exit(1)
}
