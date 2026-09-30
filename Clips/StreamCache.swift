import Foundation

/// Stream URLs last hours, so keeping them across relaunches spares a repeated track its
/// yt-dlp run. Tagged with the format that picked them: a URL chosen under another format
/// would play the old quality until it expires.
final class StreamCache {
    private let file: URL?
    private let variant: String
    private let now: () -> Date
    private var streams: [String: ClipStream]

    init(file: URL?, variant: String, now: @escaping () -> Date = Date.init) {
        self.file = file
        self.variant = variant
        self.now = now
        streams = file.map { StreamCache.load($0, variant: variant) } ?? [:]
    }

    func lookup(_ videoID: String) -> ClipStream? {
        streams[videoID]
    }

    func record(_ stream: ClipStream, for videoID: String) {
        streams[videoID] = stream
        save()
    }

    func forget(_ videoID: String) {
        guard streams.removeValue(forKey: videoID) != nil else { return }
        save()
    }

    private struct Contents: Codable {
        struct Entry: Codable {
            let url: URL
            let expires: Date
        }
        let variant: String
        let streams: [String: Entry]
    }

    private static func load(_ file: URL, variant: String) -> [String: ClipStream] {
        guard let data = try? Data(contentsOf: file),
              let contents = try? JSONDecoder().decode(Contents.self, from: data),
              contents.variant == variant else { return [:] }
        return contents.streams.mapValues { ClipStream(url: $0.url, expires: $0.expires) }
    }

    private func save() {
        guard let file else { return }
        let current = now()
        streams = streams.filter { $0.value.expires > current }
        let contents = Contents(variant: variant,
                                streams: streams.mapValues { .init(url: $0.url, expires: $0.expires) })
        // A lost write costs one yt-dlp run, so failures are not surfaced.
        guard let data = try? JSONEncoder().encode(contents) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
