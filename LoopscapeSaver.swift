import AVFoundation
import ScreenSaver
import UniformTypeIdentifiers

@objc(LoopscapeSaverView)
public final class LoopscapeSaverView: ScreenSaverView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?

    private static let playableExtensions: Set<String> = {
        var extensions: Set<String> = []
        for type in AVURLAsset.audiovisualTypes() {
            guard let ut = UTType(type.rawValue), ut.conforms(to: .movie) else { continue }
            for ext in ut.tags[.filenameExtension] ?? [] { extensions.insert(ext.lowercased()) }
        }
        return extensions.isEmpty ? ["mp4", "mov", "m4v"] : extensions
    }()

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
        player.isMuted = true
        playerLayer.player = player
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    /// The saver runs inside the sandboxed legacyScreenSaver appex, whose home is its own
    /// container — the app mirrors the clips there as hardlinks. NSHomeDirectory() resolves
    /// to the container in the appex and to the real home in an unsandboxed test host, so
    /// the same path works in both.
    private var videosDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Loopscape/videos")
    }

    private func pickClip() -> URL? {
        let dir = videosDirectory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let clips = files.filter {
            Self.playableExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }.sorted()
        guard !clips.isEmpty else { return nil }
        let current = (try? String(contentsOf: dir.appendingPathComponent("current.txt"),
                                   encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let current,
           let match = clips.first(where: { ($0 as NSString).deletingPathExtension == current }) {
            return dir.appendingPathComponent(match)
        }
        return dir.appendingPathComponent(clips.randomElement()!)
    }

    public override func startAnimation() {
        super.startAnimation()
        if looper == nil, let url = pickClip() {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }
        player.play()
    }

    public override func stopAnimation() {
        super.stopAnimation()
        player.pause()
    }
}
