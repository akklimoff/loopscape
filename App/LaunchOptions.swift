import CryptoKit
import Foundation

struct LaunchOptions: Equatable {
    var playURL: URL?
    var playAt: TimeInterval = 0

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        for (index, argument) in arguments.enumerated() {
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch argument {
            case "--play-url":
                options.playURL = value.flatMap { URL(string: $0) }
                    .flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
            case "--play-at":
                options.playAt = max(0, value.flatMap { Double($0) } ?? 0)
            default:
                continue
            }
        }
        return options
    }

    /// A debug still is keyed by its URL the way a clip's still is keyed by video id: the
    /// wallpaper agent caches by URL, so a still file is never rewritten with other pixels.
    static func stillID(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return "debug-" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
