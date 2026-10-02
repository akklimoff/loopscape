import Foundation

struct Track: Equatable {
    let id: String
    let name: String
    let artist: String
    let duration: TimeInterval
    let position: TimeInterval
    let isPlaying: Bool

    private static let menuTitleLimit = 60

    var menuTitle: String {
        let label = artist.isEmpty ? name : "\(artist) — \(name)"
        guard label.count > Self.menuTitleLimit else { return "♪ " + label }
        return "♪ " + label.prefix(Self.menuTitleLimit - 1) + "…"
    }
}

extension Track {
    /// Spotify's PlaybackStateChanged payload: `Duration` is in milliseconds while
    /// `Playback Position` is in seconds.
    init?(spotifyInfo info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String
        guard state == "Playing" || state == "Paused",
              let id = info["Track ID"] as? String, !id.isEmpty,
              let name = info["Name"] as? String, !name.isEmpty else { return nil }
        self.init(id: id,
                  name: name,
                  artist: info["Artist"] as? String ?? "",
                  duration: ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                  position: (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0,
                  isPlaying: state == "Playing")
    }
}
