import AVFoundation

/// The video's own soundtrack, decoded to the same mono rate as the Spotify recording.
/// Blocking: it runs on the alignment queue next to the yt-dlp call that found the URL.
enum ClipAudio {
    enum Failure: Error {
        case download(String)
        case decode(String)
    }

    static func load(_ url: URL, sampleRate: Double) throws -> [Float] {
        let file = try download(url)
        defer { try? FileManager.default.removeItem(at: file) }
        return try decode(file, sampleRate: sampleRate)
    }

    /// googlevideo throttles a plain GET to a trickle (230 KB in 20 s) but serves a ranged
    /// one at full speed (1.3 MB in 0.13 s), the way yt-dlp's own downloader asks.
    private static func download(_ url: URL) throws -> URL {
        let done = DispatchSemaphore(value: 0)
        var result: Result<URL, Failure> = .failure(.download("timed out"))
        let length = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "clen" }?.value.flatMap(Int.init) ?? 10_000_000
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
        let task = URLSession.shared.downloadTask(with: request) { location, response, error in
            defer { done.signal() }
            if let error { return result = .failure(.download(error.localizedDescription)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let location, status == 200 || status == 206 else {
                return result = .failure(.download("status \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
            }
            let kept = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                result = .success(kept)
            } catch {
                result = .failure(.download(error.localizedDescription))
            }
        }
        task.resume()
        if done.wait(timeout: .now() + 30) == .timedOut { task.cancel() }
        return try result.get()
    }

    private static func decode(_ file: URL, sampleRate: Double) throws -> [Float] {
        let asset = AVURLAsset(url: file)
        let loaded = DispatchSemaphore(value: 0)
        var audioTrack: AVAssetTrack?
        asset.loadTracks(withMediaType: .audio) { tracks, _ in
            audioTrack = tracks?.first
            loaded.signal()
        }
        loaded.wait()
        guard let track = audioTrack else { throw Failure.decode("no audio track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw Failure.decode(reader.error?.localizedDescription ?? "cannot read") }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        guard reader.status == .completed, !samples.isEmpty else {
            throw Failure.decode(reader.error?.localizedDescription ?? "nothing decoded")
        }
        return samples
    }
}
