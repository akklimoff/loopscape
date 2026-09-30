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

    /// A cover band's own videos are all covers, so the word only counts against strangers.
    private static let forgivenOnArtistChannel = ["cover", "кавер"].map(normalize)

    private static let qualityMarkers = ["remaster", "remastered", "4k", "hd", "hq", "1080p"].map(normalize)

    /// Lowercased, diacritics folded, punctuation turned into single spaces — so "МакSим",
    /// "P!nk" and "Beyoncé" compare equal however a title decorates them.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let spaced = String(folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// Spotify decorates names with "(feat. …)", "[…]" and " - Remastered 2011"; YouTube
    /// titles do not repeat them.
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

    /// Spotify joins a track's artists with ", "; video titles and channels name the first.
    static func primaryArtist(_ artist: String) -> String {
        artist.components(separatedBy: ", ").first ?? artist
    }

    /// nil means the candidate is ruled out, not merely weak.
    static func score(_ candidate: Candidate, for track: TrackQuery) -> Int? {
        guard let assessment = assess(candidate, for: track) else { return nil }
        return assessment.points >= threshold ? assessment.points : nil
    }

    private static func assess(_ candidate: Candidate, for track: TrackQuery) -> (points: Int, bareTitle: Bool)? {
        guard let duration = candidate.duration else { return nil }
        if track.seconds > 0 {
            guard (0.5...2.0).contains(duration / Double(track.seconds)) else { return nil }
        }

        let title = " \(normalize(candidate.title)) "
        let channel = normalize(candidate.channel ?? "")
        let name = normalize(cleanTrackName(track.name))
        let artist = normalize(primaryArtist(track.artist))
        let channelIsArtist = isArtistChannel(channel, artist: artist)

        guard !channel.hasSuffix(" topic") else { return nil }
        guard title.contains(" \(name) ") else { return nil }
        guard title.contains(" \(artist) ") || channelIsArtist else { return nil }

        // A track called "Audio" or "Live Forever" must not trip the word list on its own
        // name, while "Audio (Official Audio)" still has to.
        var rest = title
        for own in [name, artist] {
            if let range = rest.range(of: " \(own) ") { rest.replaceSubrange(range, with: " ") }
        }
        let rejected = channelIsArtist
            ? rejectedWords.filter { !forgivenOnArtistChannel.contains($0) }
            : rejectedWords
        guard !rejected.contains(where: { rest.contains(" \($0) ") }) else { return nil }

        var score = 0
        let whole = NSRange(title.startIndex..., in: title)
        if officialVideo.firstMatch(in: title, range: whole) != nil
            || videoMarkers.contains(where: { title.contains(" \($0) ") }) { score += 3 }
        if channelIsArtist { score += 3 }
        if candidate.isVerified { score += 1 }
        if track.seconds > 0, abs(duration - Double(track.seconds)) <= 10 { score += 1 }
        if qualityMarkers.contains(where: { rest.contains(" \($0) ") }) { score += 1 }
        return (score, rest.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Ties go to YouTube's own ranking, which is why the first best score wins. With no
    /// winner, YouTube's top hit is still taken when a verified channel titled it with nothing
    /// but artist and name — the shape of a label's upload, which carries no other marker.
    static func pick(for track: TrackQuery, from candidates: [Candidate]) -> Candidate? {
        var best: (candidate: Candidate, score: Int)?
        for candidate in candidates {
            guard let score = score(candidate, for: track) else { continue }
            if best == nil || score > best!.score { best = (candidate, score) }
        }
        if let best { return best.candidate }
        guard let top = candidates.first, top.isVerified,
              assess(top, for: track)?.bareTitle == true else { return nil }
        return top
    }

    private static func isArtistChannel(_ channel: String, artist: String) -> Bool {
        let compactChannel = channel.replacingOccurrences(of: " ", with: "")
        let compactArtist = artist.replacingOccurrences(of: " ", with: "")
        guard !compactArtist.isEmpty else { return false }
        return ["", "vevo", "official", "music"].contains { compactChannel == compactArtist + $0 }
    }
}
