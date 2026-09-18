import Foundation

struct TrackQuery: Equatable {
    let id: String
    let artist: String
    let name: String
    let seconds: Int
}

struct Candidate: Equatable, Decodable {
    let id: String
    let title: String
    let channel: String?
    let duration: Double?
    let isVerified: Bool

    init(id: String, title: String, channel: String?, duration: Double?, isVerified: Bool) {
        self.id = id
        self.title = title
        self.channel = channel
        self.duration = duration
        self.isVerified = isVerified
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, channel, duration
        case isVerified = "channel_is_verified"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        channel = try values.decodeIfPresent(String.self, forKey: .channel)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        isVerified = try values.decodeIfPresent(Bool.self, forKey: .isVerified) ?? false
    }
}

enum ClipMatching {
    static let threshold = 3

    private static let videoMarkers = [
        "music video", "официальный клип", "video oficial", "clip officiel", "videoclip", "official mv",
    ].map(normalize)

    private static let officialVideo = try! NSRegularExpression(pattern: #" official( \w+){0,3} video "#)

    private static let rejectedWords = [
        "audio", "lyric", "lyrics", "текст", "karaoke", "караоке", "live", "concert", "концерт",
        "festival", "cover", "кавер", "reaction", "реакция", "slowed", "reverb", "sped up",
        "nightcore", "8d", "instrumental", "минус", "acoustic", "remix", "full album", "teaser",
        "trailer", "behind the scenes", "making of", "hour", "hours", "tutorial", "lesson",
    ].map(normalize)

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let spaced = String(folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    static func cleanTrackName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "",
                                                options: .regularExpression)
        if let dash = cleaned.range(of: " - ") { cleaned = String(cleaned[..<dash.lowerBound]) }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? name : cleaned
    }

    static func searchQuery(for track: TrackQuery) -> String {
        "\(track.artist) \(cleanTrackName(track.name)) official video"
    }

    static func score(_ candidate: Candidate, for track: TrackQuery) -> Int? {
        guard let duration = candidate.duration else { return nil }
        if track.seconds > 0 {
            guard (0.5...2.0).contains(duration / Double(track.seconds)) else { return nil }
        }

        let title = " \(normalize(candidate.title)) "
        let channel = normalize(candidate.channel ?? "")
        let name = normalize(cleanTrackName(track.name))
        let artist = normalize(track.artist)
        let channelIsArtist = isArtistChannel(channel, artist: artist)

        guard !channel.hasSuffix(" topic") else { return nil }
        guard title.contains(" \(name) ") else { return nil }
        guard title.contains(" \(artist) ") || channelIsArtist else { return nil }

        var rest = title
        for own in [name, artist] {
            if let range = rest.range(of: " \(own) ") { rest.replaceSubrange(range, with: " ") }
        }
        guard !rejectedWords.contains(where: { rest.contains(" \($0) ") }) else { return nil }

        var score = 0
        let whole = NSRange(title.startIndex..., in: title)
        if officialVideo.firstMatch(in: title, range: whole) != nil
            || videoMarkers.contains(where: { title.contains(" \($0) ") }) { score += 3 }
        if channelIsArtist { score += 3 }
        if candidate.isVerified { score += 1 }
        if track.seconds > 0, abs(duration - Double(track.seconds)) <= 10 { score += 1 }
        return score >= threshold ? score : nil
    }

    static func pick(for track: TrackQuery, from candidates: [Candidate]) -> Candidate? {
        var best: (candidate: Candidate, score: Int)?
        for candidate in candidates {
            guard let score = score(candidate, for: track) else { continue }
            if best == nil || score > best!.score { best = (candidate, score) }
        }
        return best?.candidate
    }

    private static func isArtistChannel(_ channel: String, artist: String) -> Bool {
        let compactChannel = channel.replacingOccurrences(of: " ", with: "")
        let compactArtist = artist.replacingOccurrences(of: " ", with: "")
        guard !compactArtist.isEmpty else { return false }
        return ["", "vevo", "official"].contains { compactChannel == compactArtist + $0 }
    }
}
