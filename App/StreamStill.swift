import AppKit
import AVFoundation
import CoreImage

/// AVAssetImageGenerator cannot read an HLS asset, so the still is one of the frames the
/// player is already decoding; waiting for the first one doubles as the first-frame timer.
enum StreamStill {
    static let timeout: TimeInterval = 10
    private static let interval: TimeInterval = 0.1

    static func grab(from player: AVPlayer, to file: URL, completion: @escaping (Bool) -> Void) {
        guard let item = player.currentItem else { return completion(false) }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        poll(item: item, output: output, until: Date().addingTimeInterval(timeout),
             file: file, completion: completion)
    }

    private static func poll(item: AVPlayerItem, output: AVPlayerItemVideoOutput, until deadline: Date,
                             file: URL, completion: @escaping (Bool) -> Void) {
        let time = item.currentTime()
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            item.remove(output)
            completion(write(buffer, to: file))
            return
        }
        guard Date() < deadline else {
            item.remove(output)
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            poll(item: item, output: output, until: deadline, file: file, completion: completion)
        }
    }

    private static func write(_ buffer: CVPixelBuffer, to file: URL) -> Bool {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let frame = CIContext().createCGImage(image, from: image.extent, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let jpeg = NSBitmapImageRep(cgImage: frame)
                  .representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? jpeg.write(to: file, options: .atomic)) != nil
    }
}
