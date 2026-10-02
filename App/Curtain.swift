import Foundation

/// The animation that stands between a pack and a clip while the clip is searched for and
/// buffered: the pack leaves into a "fabric" of white diagonal lines, and the fabric later
/// leaves the same way to show the clip. Designs: claude.ai/artifact/GDPttmsXC2URK9xNfTR4ed.
enum CurtainStyle: String, CaseIterable {
    case silk, loom, wind, satin, none

    var coverDuration: TimeInterval {
        switch self {
        case .silk: return 1.4
        case .loom: return 1.1
        case .wind: return 1.6
        case .satin: return 1.3
        case .none: return 0
        }
    }

    var revealDuration: TimeInterval { coverDuration }

    /// Width of the soft edge of the diagonal wipe, as a share of the screen's diagonal.
    var softness: Float {
        switch self {
        case .silk: return 0.04
        case .wind: return 0.35
        case .satin: return 0.2
        case .loom, .none: return 0
        }
    }

    var glowStrength: Float {
        switch self {
        case .silk: return 1
        case .wind: return 0.35
        case .satin: return 0.5
        case .loom, .none: return 0
        }
    }

    var glowWidth: Float {
        switch self {
        case .silk: return 0.06
        case .wind: return 0.3
        case .satin: return 0.18
        case .loom, .none: return 0
        }
    }

    var shaderIndex: Int32 {
        switch self {
        case .silk: return 0
        case .loom: return 1
        case .wind: return 2
        case .satin: return 3
        case .none: return -1
        }
    }
}

struct CurtainFrame: Equatable {
    /// Since the cover began; the waiting animation runs on this clock throughout.
    let elapsed: TimeInterval
    let revealElapsed: TimeInterval?
}

struct Curtain {
    private enum Phase: Equatable {
        case clear
        case covering(since: Date)
        case revealing(coverSince: Date, since: Date)
    }

    private var phase = Phase.clear
    private(set) var style = CurtainStyle.none

    var isClear: Bool { phase == .clear }

    var isRevealing: Bool {
        if case .revealing = phase { return true }
        return false
    }

    var coveredAt: Date? {
        guard case .covering(let since) = phase else { return nil }
        return since.addingTimeInterval(style.coverDuration)
    }

    var revealEndsAt: Date? {
        guard case .revealing(_, let since) = phase else { return nil }
        return since.addingTimeInterval(style.revealDuration)
    }

    func isCovered(at now: Date) -> Bool {
        guard let coveredAt else { return false }
        return now >= coveredAt
    }

    /// A cover during a reveal starts from scratch: blending a half-gone fabric back in
    /// would need the reveal's mask in reverse, and a skip during a reveal is rare.
    mutating func cover(style: CurtainStyle, at now: Date) -> Bool {
        guard style != .none else { return false }
        if case .covering = phase { return false }
        self.style = style
        phase = .covering(since: now)
        return true
    }

    mutating func reveal(at now: Date) -> Bool {
        guard case .covering(let since) = phase, isCovered(at: now) else { return false }
        phase = .revealing(coverSince: since, since: now)
        return true
    }

    mutating func settle(at now: Date) -> Bool {
        guard let revealEndsAt, now >= revealEndsAt else { return false }
        phase = .clear
        return true
    }

    func frame(at now: Date) -> CurtainFrame? {
        switch phase {
        case .clear:
            return nil
        case .covering(let since):
            return CurtainFrame(elapsed: now.timeIntervalSince(since), revealElapsed: nil)
        case .revealing(let coverSince, let since):
            return CurtainFrame(elapsed: now.timeIntervalSince(coverSince),
                                revealElapsed: now.timeIntervalSince(since))
        }
    }
}
