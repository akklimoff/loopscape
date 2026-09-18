import Foundation

/// Track → video mapping kept beside packs.json. Misses are remembered too, so a track with
/// no video costs one search instead of one per play; they lapse so a later release is found.
final class ClipStore {
    enum Entry: Equatable {
        case video(String)
        case none
    }

    static let missLifetime: TimeInterval = 30 * 24 * 3600

    private struct Record: Codable {
        var video: String?
        var checked: Date
    }

    private let file: URL
    private let now: () -> Date
    private var records: [String: Record] = [:]

    init(file: URL, now: @escaping () -> Date = Date.init) {
        self.file = file
        self.now = now
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file),
           let decoded = try? decoder.decode([String: Record].self, from: data) {
            records = decoded
        }
    }

    func lookup(_ trackID: String) -> Entry? {
        guard let record = records[trackID] else { return nil }
        if let video = record.video { return .video(video) }
        return now().timeIntervalSince(record.checked) < Self.missLifetime ? Entry.none : nil
    }

    func record(_ entry: Entry, for trackID: String) {
        switch entry {
        case .video(let id): records[trackID] = Record(video: id, checked: now())
        case .none: records[trackID] = Record(video: nil, checked: now())
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
