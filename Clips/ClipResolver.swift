import Foundation

enum ClipResolution: Equatable {
    case stream(videoID: String, url: URL)
    case none
}

/// Blocking by design: a resolve is two yt-dlp runs of a few seconds each, so the caller
/// owns the queue it runs on — a single serial queue, since the cached streams are
/// unsynchronised — and decides what to do with a result that arrives too late.
final class ClipResolver {
    /// A stream that dies mid-clip is worse than a fresh resolve, so a URL close to its
    /// deadline is not handed out.
    static let expiryMargin: TimeInterval = 600

    /// A missing format is as likely a yt-dlp or YouTube change that hits every video at once
    /// as a property of this one, so it is held in memory for hours rather than written down
    /// as a miss for a month.
    static let formatMissLifetime: TimeInterval = 6 * 3600

    private let store: ClipStore
    private let source: ClipSource
    private let now: () -> Date
    /// Kept in memory only: a googlevideo URL is signed for the client's IP, so one saved
    /// before a network change would fail to play after it.
    private var streams: [String: ClipStream] = [:]
    private var formatMisses: [String: Date] = [:]

    init(store: ClipStore, source: ClipSource, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.source = source
        self.now = now
    }

    /// A URL that failed to play would fail again, so the next resolve fetches a new one.
    func forgetStream(of videoID: String) {
        streams[videoID] = nil
    }

    func forgetAllStreams() {
        streams = [:]
    }

    func resolve(_ track: TrackQuery) throws -> ClipResolution {
        let videoID: String
        let foundBySearch: Bool
        switch store.lookup(track.id) {
        case .some(.none):
            return .none
        case .some(.video(let known)):
            videoID = known
            foundBySearch = false
        case nil:
            let candidates = try source.search(ClipMatching.searchQuery(for: track))
            guard !candidates.isEmpty else { throw ClipError.toolFailed("empty search result") }
            guard let picked = ClipMatching.pick(for: track, from: candidates) else {
                store.record(.none, for: track.id)
                return .none
            }
            videoID = picked.id
            foundBySearch = true
        }

        do {
            let stream = try liveStream(for: videoID)
            if foundBySearch { store.record(.video(videoID), for: track.id) }
            return .stream(videoID: videoID, url: stream.url)
        } catch ClipError.unplayable {
            if foundBySearch { store.record(.none, for: track.id) }
            return .none
        } catch ClipError.noFormat {
            if foundBySearch { store.record(.video(videoID), for: track.id) }
            formatMisses[videoID] = now()
            return .none
        }
    }

    private func liveStream(for videoID: String) throws -> ClipStream {
        if let missed = formatMisses[videoID], now().timeIntervalSince(missed) < Self.formatMissLifetime {
            throw ClipError.noFormat
        }
        if let cached = streams[videoID],
           cached.expires.timeIntervalSince(now()) > Self.expiryMargin {
            return cached
        }
        let fresh = try source.stream(videoID: videoID)
        streams[videoID] = fresh
        return fresh
    }
}
