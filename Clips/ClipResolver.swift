import Foundation

enum ClipResolution: Equatable {
    case stream(videoID: String, url: URL)
    case none
}

/// Blocking by design: a resolve is two yt-dlp runs of a few seconds each, so the caller
/// owns the queue it runs on and decides what to do with a result that arrives too late.
final class ClipResolver {
    /// A stream that dies mid-clip is worse than a fresh resolve, so a URL close to its
    /// deadline is not handed out.
    static let expiryMargin: TimeInterval = 600

    private let store: ClipStore
    private let source: ClipSource
    private let now: () -> Date
    private var streams: [String: ClipStream] = [:]

    init(store: ClipStore, source: ClipSource, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.source = source
        self.now = now
    }

    func resolve(_ track: TrackQuery) throws -> ClipResolution {
        let videoID: String
        switch store.lookup(track.id) {
        case .some(.none):
            return .none
        case .some(.video(let known)):
            videoID = known
        case nil:
            let candidates = try source.search(ClipMatching.searchQuery(for: track))
            guard let picked = ClipMatching.pick(for: track, from: candidates) else {
                store.record(.none, for: track.id)
                return .none
            }
            videoID = picked.id
        }

        do {
            let stream = try liveStream(for: videoID)
            store.record(.video(videoID), for: track.id)
            return .stream(videoID: videoID, url: stream.url)
        } catch ClipError.unplayable {
            store.record(.none, for: track.id)
            return .none
        }
    }

    private func liveStream(for videoID: String) throws -> ClipStream {
        if let cached = streams[videoID],
           cached.expires.timeIntervalSince(now()) > Self.expiryMargin {
            return cached
        }
        let fresh = try source.stream(videoID: videoID)
        streams[videoID] = fresh
        return fresh
    }
}
