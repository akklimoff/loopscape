import Foundation

enum ResolveOutcome: Equatable {
    case found(videoID: String, url: URL)
    case notFound
    case failed
}

enum ClipEffect: Equatable {
    case resolve(TrackQuery, generation: Int)
    case play(videoID: String, url: URL, position: TimeInterval)
    case pause
    case resume
    case leave
}

struct ClipMode {
    private enum Phase: Equatable {
        case idle
        case resolving(trackID: String, generation: Int)
        case showing(trackID: String)
        case missing(trackID: String)
        /// A network or tool failure says nothing about the track, so the next play event of
        /// the same track tries again.
        case failed(trackID: String)
    }

    private(set) var isEnabled: Bool
    private var phase = Phase.idle
    private var generation = 0
    private var track: Track?
    private var trackSeen = Date.distantPast
    private var clipOnScreen = false
    private var retriedTrackID: String?
    private let now: () -> Date

    init(isEnabled: Bool, now: @escaping () -> Date = Date.init) {
        self.isEnabled = isEnabled
        self.now = now
    }

    var clipPlayback: (position: TimeInterval, paused: Bool)? {
        guard case .showing = phase, clipOnScreen, let track else { return nil }
        return (position(of: track), !track.isPlaying)
    }

    func isCurrent(_ generation: Int) -> Bool {
        if case .resolving(_, let current) = phase { return current == generation }
        return false
    }

    mutating func setEnabled(_ enabled: Bool) -> [ClipEffect] {
        guard enabled != isEnabled else { return [] }
        isEnabled = enabled
        guard enabled else { return leave() }
        guard let track, track.isPlaying else { return [] }
        return start(track)
    }

    mutating func trackChanged(_ new: Track?) -> [ClipEffect] {
        let sameTrack = new != nil && new?.id == track?.id
        track = new
        trackSeen = now()
        guard isEnabled else { return [] }
        guard let new else { return leave() }
        if sameTrack {
            switch phase {
            case .showing:
                return [new.isPlaying ? .resume : .pause]
            case .resolving:
                return clipOnScreen ? [new.isPlaying ? .resume : .pause] : []
            case .idle:
                return new.isPlaying ? start(new) : []
            case .missing:
                return []
            case .failed:
                return new.isPlaying ? start(new) : []
            }
        }
        guard new.isPlaying else { return leave() }
        return start(new)
    }

    mutating func resolved(_ outcome: ResolveOutcome, generation: Int) -> [ClipEffect] {
        guard isCurrent(generation), case .resolving(let trackID, _) = phase,
              let track, track.id == trackID else { return [] }
        switch outcome {
        case .found(let videoID, let url):
            phase = .showing(trackID: trackID)
            clipOnScreen = true
            return [.play(videoID: videoID, url: url, position: position(of: track))]
        case .notFound:
            phase = .missing(trackID: trackID)
            return takeClipOff()
        case .failed:
            phase = .failed(trackID: trackID)
            return takeClipOff()
        }
    }

    /// A pack picked from the menu replaces the clip, and the track playing now does not bring
    /// it back; the next track does.
    mutating func packChosen() {
        generation += 1
        clipOnScreen = false
        phase = track.map { .missing(trackID: $0.id) } ?? .idle
    }

    /// Called after the wallpaper has already fallen back to the pack. Offline, the URL is
    /// most likely still good and a search would fail too, so the clip waits for the network
    /// and the one retry is kept for a stream that is actually broken.
    mutating func streamFailed(offline: Bool = false) -> [ClipEffect] {
        guard case .showing(let trackID) = phase, let track else { return [] }
        clipOnScreen = false
        if offline {
            phase = .failed(trackID: trackID)
            return []
        }
        guard retriedTrackID != trackID, let query = Self.query(for: track) else {
            phase = .missing(trackID: trackID)
            return []
        }
        retriedTrackID = trackID
        generation += 1
        phase = .resolving(trackID: trackID, generation: generation)
        return [.resolve(query, generation: generation)]
    }

    mutating func networkReturned() -> [ClipEffect] {
        guard isEnabled, case .failed(let trackID) = phase, let track, track.id == trackID,
              track.isPlaying else { return [] }
        return start(track)
    }

    /// Ads, podcast episodes and local files have no music video to find, and the matcher
    /// rejects every candidate for an empty artist, so none of them is worth a yt-dlp run.
    private static func query(for track: Track) -> TrackQuery? {
        guard track.id.hasPrefix("spotify:track:"), !track.artist.isEmpty, track.duration > 0 else {
            return nil
        }
        return TrackQuery(id: track.id, artist: track.artist, name: track.name,
                          seconds: Int(track.duration.rounded()))
    }

    private mutating func start(_ track: Track) -> [ClipEffect] {
        generation += 1
        retriedTrackID = nil
        guard let query = Self.query(for: track) else {
            phase = .missing(trackID: track.id)
            return takeClipOff()
        }
        phase = .resolving(trackID: track.id, generation: generation)
        return [.resolve(query, generation: generation)]
    }

    private mutating func leave() -> [ClipEffect] {
        generation += 1
        phase = .idle
        return takeClipOff()
    }

    private mutating func takeClipOff() -> [ClipEffect] {
        guard clipOnScreen else { return [] }
        clipOnScreen = false
        return [.leave]
    }

    /// Spotify reports the position only when something changes, so a playing track's
    /// position is extrapolated from the last event.
    private func position(of track: Track) -> TimeInterval {
        track.isPlaying ? track.position + now().timeIntervalSince(trackSeen) : track.position
    }
}
