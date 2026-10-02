import Foundation

/// A clip's soundtrack reduced to onset bands, kept on disk so that realigning a clip heard
/// before costs neither a yt-dlp call nor a download.
struct SoundtrackCache {
    let directory: URL

    func bands(of videoID: String) -> [[Float]]? {
        guard let data = try? Data(contentsOf: file(of: videoID)), data.count > 4 else { return nil }
        let bandCount = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let values = (data.count - 4) / MemoryLayout<Float>.size
        guard bandCount > 0, (data.count - 4) % MemoryLayout<Float>.size == 0, values % bandCount == 0 else { return nil }
        let floats = data.dropFirst(4).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let length = values / bandCount
        return (0..<bandCount).map { Array(floats[($0 * length)..<(($0 + 1) * length)]) }
    }

    func save(_ bands: [[Float]], of videoID: String) {
        guard let length = bands.first?.count, bands.allSatisfy({ $0.count == length }) else { return }
        var data = withUnsafeBytes(of: UInt32(bands.count)) { Data($0) }
        for band in bands { band.withUnsafeBytes { data.append(contentsOf: $0) } }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(of: videoID), options: .atomic)
    }

    private func file(of videoID: String) -> URL {
        directory.appendingPathComponent(videoID)
    }
}
