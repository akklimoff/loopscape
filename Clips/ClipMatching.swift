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

    private struct Assessment {
        let points: Int
        let hasQualityMarker: Bool
        let bareTitle: Bool
    }

    private enum ChannelMatch {
        case none
        case own
        /// "<artist> Music" is as often a label as the artist's own channel.
        case musicSuffix
    }

    /// nil means the candidate is ruled out, not merely weak. A quality marker only ranks
    /// candidates that already qualify: on a stranger's upload "HD" says nothing about whose it is.
    static func score(_ candidate: Candidate, for track: TrackQuery) -> Int? {
        guard let assessment = assess(candidate, for: track), assessment.points >= threshold else {
            return nil
        }
        return assessment.points + (assessment.hasQualityMarker ? 1 : 0)
    }

    /// Spotify joins several artists with ", ", but a name can contain one too ("Tyler, The
    /// Creator"). So a title shows the artist either as the whole string or by naming every
    /// listed artist, however it joins them ("ft.", "x", "&"); and a channel named after one
    /// listed artist counts only when verified or when the title credits another of them,
    /// since a fragment like "Tyler" is anybody's channel name.
    private static func assess(_ candidate: Candidate, for track: TrackQuery) -> Assessment? {
        guard let duration = candidate.duration else { return nil }
        if track.seconds > 0 {
            guard (0.5...2.0).contains(duration / Double(track.seconds)) else { return nil }
        }

        let title = " \(normalize(candidate.title)) "
        let channel = normalize(candidate.channel ?? "")
        let name = normalize(cleanTrackName(track.name))
        let artist = normalize(track.artist)
        let listed = track.artist.components(separatedBy: ", ").map(normalize).filter { !$0.isEmpty }
        let credited = listed.filter { title.contains(" \($0) ") }
        let titleHasArtist = title.contains(" \(artist) ")
            || (listed.count > 1 && credited.count == listed.count)

        guard !channel.hasSuffix(" topic") else { return nil }
        guard title.contains(" \(name) ") else { return nil }

        let whole = NSRange(title.startIndex..., in: title)
        let saysVideo = officialVideo.firstMatch(in: title, range: whole) != nil
            || videoMarkers.contains(where: { title.contains(" \($0) ") })

        var channelIsArtist = false
        var channelIsPerformer = false
        switch channelMatch(channel, artist: artist) {
        case .own:
            channelIsArtist = true
            channelIsPerformer = true
        case .musicSuffix:
            channelIsArtist = titleHasArtist || !credited.isEmpty
            channelIsPerformer = channelIsArtist
        case .none:
            if listed.count > 1, let own = listed.first(where: { channelMatch(channel, artist: $0) != .none }) {
                let vouched = candidate.isVerified || saysVideo || credited.contains { $0 != own }
                let needsCredit = channelMatch(channel, artist: own) == .musicSuffix
                channelIsArtist = vouched && (!needsCredit || !credited.isEmpty)
                // The first listed artist is the performer, so their verified channel may
                // carry the track as a cover; a featured artist's channel may not.
                channelIsPerformer = channelIsArtist && candidate.isVerified && own == listed.first
            }
        }
        guard titleHasArtist || channelIsArtist else { return nil }

        // A track called "Audio" or "Live Forever" must not trip the word list on its own
        // name, while "Audio (Official Audio)" still has to.
        var rest = title
        for own in [name, artist] {
            if let range = rest.range(of: " \(own) ") { rest.replaceSubrange(range, with: " ") }
        }
        let rejected = channelIsPerformer
            ? rejectedWords.filter { !forgivenOnArtistChannel.contains($0) }
            : rejectedWords
        guard !rejected.contains(where: { rest.contains(" \($0) ") }) else { return nil }

        var points = 0
        if saysVideo { points += 3 }
        if channelIsArtist { points += 3 }
        if candidate.isVerified { points += 1 }
        if track.seconds > 0, abs(duration - Double(track.seconds)) <= 10 { points += 1 }
        return Assessment(points: points,
                          hasQualityMarker: qualityMarkers.contains { rest.contains(" \($0) ") },
                          bareTitle: rest.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private static func channelMatch(_ channel: String, artist: String) -> ChannelMatch {
        let compactChannel = channel.replacingOccurrences(of: " ", with: "")
        let compactArtist = artist.replacingOccurrences(of: " ", with: "")
        guard !compactArtist.isEmpty else { return .none }
        if ["", "vevo", "official"].contains(where: { compactChannel == compactArtist + $0 }) { return .own }
        return compactChannel == compactArtist + "music" ? .musicSuffix : .none
    }
}
