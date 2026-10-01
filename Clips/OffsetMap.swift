import Foundation

/// How much later each part of the song comes in its music video than in Spotify's
/// recording. A video can cut or insert scenes mid-song, so the offset is kept per stretch:
/// each one holds from where it was measured until the next.
struct OffsetMap: Equatable {
    struct Point: Equatable {
        let at: TimeInterval
        let offset: TimeInterval
    }

    /// Measurements closer than this describe the same stretch of the song.
    static let mergeRadius: TimeInterval = 5
    /// Below this a new measurement only restates the offset in force.
    static let agreement: TimeInterval = 0.05

    private(set) var points: [Point] = []

    init() {}

    func offset(at position: TimeInterval) -> TimeInterval {
        points.last { $0.at <= position }?.offset ?? points.first?.offset ?? 0
    }

    mutating func set(_ offset: TimeInterval, at position: TimeInterval) {
        points.removeAll { abs($0.at - position) < Self.mergeRadius }
        guard points.isEmpty || abs(self.offset(at: position) - offset) >= Self.agreement else { return }
        points.append(Point(at: position, offset: offset))
        points.sort { $0.at < $1.at }
    }

    var stored: [[Double]] {
        points.map { [($0.at * 10).rounded() / 10, ($0.offset * 100).rounded() / 100] }
    }

    init(stored: [[Double]]) {
        points = stored.compactMap { $0.count == 2 ? Point(at: $0[0], offset: $0[1]) : nil }
            .sorted { $0.at < $1.at }
    }

    init(stored single: Double) {
        points = [Point(at: 0, offset: single)]
    }
}
