import Foundation

enum ResolveOutcome: Equatable {
    case found(videoID: String, url: URL)
    case notFound
    case failed
    /// Not a failure of YouTube or the network: the menu hint covers it, and the next play
    /// after `brew install yt-dlp` finds the tool.
    case toolMissing
}

enum ClipEffect: Equatable {
    case resolve(TrackQuery, generation: Int)
    case play(videoID: String, url: URL, position: TimeInterval)
    case seek(position: TimeInterval)
    case retryLater(trackID: String, after: TimeInterval)
    case pauseTimeout(after: TimeInterval)
    case pause
    case resume
    case leave
}

struct ClipMode {
    /// An exact seek plus the first frame took 1.4–2.0 s in the live runs, so a playing clip
    /// is started that far ahead of the song to land level with it.
    static let startLead: TimeInterval = 1.5
    /// Extrapolation drifts by a few hundred milliseconds; beyond this the song was scrubbed
    /// or restarted, and a seek is worth its frozen second.
    static let driftAllowance: TimeInterval = 2
    /// Failures in a row usually mean YouTube is refusing yt-dlp ("confirm you're not a
    /// bot") or yt-dlp is broken; asking again on every track only prolongs a rate limit.
    static let failuresBeforeBackoff = 3
    static let backoff: TimeInterval = 15 * 60
    static let retryDelay: TimeInterval = 15
    /// A frozen frame reads as "the clip is paused" for a moment; past this it reads as a
    /// broken wallpaper, and the pack is better until Spotify plays again.
    static let pauseLimit: TimeInterval = 10
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
    private var laterRetriedTrackID: String?
    private var failuresInRow = 0
    private var backoffUntil: Date?
    private let now: () -> Date

    init(isEnabled: Bool, now: @escaping () -> Date = Date.init) {
        self.isEnabled = isEnabled
        self.now = now
    }

    /// Where a restarted clip should begin; nil when the clip on screen is not this track's.
    var clipPosition: TimeInterval? {
        guard case .showing = phase, clipOnScreen, let track else { return nil }
        return startPosition(of: track)
    }

    /// Covers the clip still on screen while the next track resolves too, which has no
    /// playback position of its own but must still follow Spotify's pause.
    var isClipPaused: Bool {
        clipOnScreen && track?.isPlaying == false
    }

    var isResolving: Bool {
        if case .resolving = phase { return true }
        return false
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
        let expected = track.map(position(of:))
        track = new
        trackSeen = now()
        guard isEnabled else { return [] }
        guard let new else { return leave() }
        if sameTrack {
            switch phase {
            case .showing:
                let toggle = new.isPlaying ? [ClipEffect.resume] : [.pause, .pauseTimeout(after: Self.pauseLimit)]
                guard let expected, abs(new.position - expected) > Self.driftAllowance else { return toggle }
                return [.seek(position: startPosition(of: new))] + toggle
            case .resolving:
                guard clipOnScreen else { return [] }
                return new.isPlaying ? [.resume] : [.pause, .pauseTimeout(after: Self.pauseLimit)]
            case .idle:
                return new.isPlaying ? start(new) : []
            case .missing:
                return []
            case .failed:
                return new.isPlaying ? start(new) : []
            }
        }
        laterRetriedTrackID = nil
        guard new.isPlaying else { return leave() }
        return start(new)
    }

    mutating func resolved(_ outcome: ResolveOutcome, generation: Int) -> [ClipEffect] {
        guard isCurrent(generation), case .resolving(let trackID, _) = phase,
              let track, track.id == trackID else { return [] }
        if outcome != .failed && outcome != .toolMissing {
            failuresInRow = 0
            backoffUntil = nil
        }
        switch outcome {
        case .found(let videoID, let url):
            phase = .showing(trackID: trackID)
            clipOnScreen = true
            let play = ClipEffect.play(videoID: videoID, url: url, position: startPosition(of: track))
            guard !track.isPlaying else { return [play] }
            return [play, .pauseTimeout(after: Self.pauseLimit - now().timeIntervalSince(trackSeen))]
        case .notFound:
            phase = .missing(trackID: trackID)
            return takeClipOff()
        case .toolMissing:
            phase = .failed(trackID: trackID)
            return takeClipOff()
        case .failed:
            phase = .failed(trackID: trackID)
            var effects = takeClipOff()
            failuresInRow += 1
            if failuresInRow >= Self.failuresBeforeBackoff {
                backoffUntil = now().addingTimeInterval(Self.backoff)
                return effects
            }
            // The network can report a path before DNS or routing works (a wake), and no
            // path change follows to retry on; one delayed attempt per track covers that
            // without looping on an outage or a rate limit.
            if track.isPlaying, laterRetriedTrackID != trackID {
                laterRetriedTrackID = trackID
                effects.append(.retryLater(trackID: trackID, after: Self.retryDelay))
            }
            return effects
        }
    }

    /// Spotify sends nothing while it stays paused, so the timer armed by the pause asks
    /// back; a newer event since then has armed its own.
    mutating func pauseTimedOut() -> [ClipEffect] {
        guard clipOnScreen, let track, !track.isPlaying,
              now().timeIntervalSince(trackSeen) >= Self.pauseLimit - 0.05 else { return [] }
        generation += 1
        phase = .idle
        return takeClipOff()
    }

    /// A pack picked from the menu replaces the clip, and the track playing now does not bring
    /// it back; the next track does.
    mutating func packChosen() {
        generation += 1
        clipOnScreen = false
        phase = track.map { .missing(trackID: $0.id) } ?? .idle
    }

    /// Called after the wallpaper has already fallen back to the pack. Offline a search would
    /// fail too, so the clip waits for the network, and the one retry is kept for a stream
    /// that is actually broken.
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

    /// nil retries whatever track failed; a delayed retry names the track it was armed for.
    mutating func retryFailed(trackID wanted: String? = nil) -> [ClipEffect] {
        if wanted == nil {
            failuresInRow = 0
            backoffUntil = nil
        }
        guard isEnabled, case .failed(let trackID) = phase, let track, track.id == trackID,
              wanted == nil || wanted == trackID, track.isPlaying else { return [] }
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
        if let backoffUntil, now() < backoffUntil {
            phase = .failed(trackID: track.id)
            return takeClipOff() + [.retryLater(trackID: track.id, after: backoffUntil.timeIntervalSince(now()))]
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

    private func startPosition(of track: Track) -> TimeInterval {
        position(of: track) + (track.isPlaying ? Self.startLead : 0)
    }

    /// Spotify reports the position only when something changes, so a playing track's
    /// position is extrapolated from the last event.
    private func position(of track: Track) -> TimeInterval {
        track.isPlaying ? track.position + now().timeIntervalSince(trackSeen) : track.position
    }
}
