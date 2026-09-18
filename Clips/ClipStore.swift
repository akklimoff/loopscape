import Foundation

/// Track → video mapping kept beside packs.json. Misses are remembered too, so a track with
/// no video costs one search instead of one per play; they lapse so a later release is found.
final class ClipStore {
    enum Entry: Equatable {
        case video(String)
        case none
    }

    static let missLifetime: TimeInterval = 30 * 24 * 3600

    private let file: URL
    private let now: () -> Date

    init(file: URL, now: @escaping () -> Date = Date.init) {
        self.file = file
        self.now = now
    }

    func lookup(_ trackID: String) -> Entry? {
        guard let record = load()[trackID] as? [String: Any] else { return nil }
        if let video = record["video"] as? String, !video.isEmpty { return .video(video) }
        guard let stamp = record["checked"] as? String,
              let checked = ISO8601DateFormatter().date(from: stamp) else { return nil }
        return now().timeIntervalSince(checked) < Self.missLifetime ? Entry.none : nil
    }

    func record(_ entry: Entry, for trackID: String) {
        var records = load()
        var record: [String: Any] = ["checked": ISO8601DateFormatter().string(from: now())]
        if case .video(let id) = entry { record["video"] = id }
        records[trackID] = record
        // A lost write costs one repeated search, so failures are not surfaced.
        guard let data = try? JSONSerialization.data(withJSONObject: records,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Read afresh on every access: the file doubles as the manual override and the app runs
    /// for days, so an edit made meanwhile must take effect and must not be overwritten.
    /// Kept as raw JSON so an entry this version cannot read is written back untouched.
    private func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root
    }
}
