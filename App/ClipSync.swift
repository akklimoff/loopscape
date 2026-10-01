import Foundation

enum SyncAction: Equatable {
    case keep
    case rate(Double)
    case seek(TimeInterval)
}

/// Keeps a playing clip level with the song. Small gaps are closed by playing the muted
/// clip slightly faster or slower, which nobody sees; a seek freezes the picture for a
/// second, so it is kept for gaps a nudge would take too long to close.
struct ClipSync {
    static let startNudgingBeyond: TimeInterval = 0.15
    static let stopNudgingWithin: TimeInterval = 0.04
    /// A seek holds the picture still for well under a second and lands within a frame or
    /// two; nudging a full second away at the largest rate takes five.
    static let seekBeyond: TimeInterval = 1
    static let maxNudge = 0.2
    /// How long a nudge should take to close the gap, before the cap applies.
    static let catchUpWindow: TimeInterval = 4

    private(set) var isNudging = false

    mutating func decide(clipTime: TimeInterval, trackTime: TimeInterval,
                         clipDuration: TimeInterval? = nil) -> SyncAction {
        if let clipDuration, trackTime >= clipDuration { return settle() }
        let offset = clipTime - trackTime
        if abs(offset) > Self.seekBeyond {
            isNudging = false
            return .seek(trackTime + ClipMode.seekLead)
        }
        let threshold = isNudging ? Self.stopNudgingWithin : Self.startNudgingBeyond
        guard abs(offset) > threshold else { return settle() }
        isNudging = true
        let nudge = min(Self.maxNudge, max(-Self.maxNudge, offset / Self.catchUpWindow))
        return .rate(1 - nudge)
    }

    private mutating func settle() -> SyncAction {
        guard isNudging else { return .keep }
        isNudging = false
        return .rate(1)
    }
}
