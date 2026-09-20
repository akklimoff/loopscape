import AppKit
import AVFoundation

/// AVPlayerLayer as the view's backing layer, so it always matches the window exactly.
final class PlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer = playerLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

final class ScreenWallpaper {
    private let window: NSWindow
    private let view: PlayerView
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(screen: NSScreen) {
        let frame = screen.frame
        view = PlayerView(frame: NSRect(origin: .zero, size: frame.size))
        window = NSWindow(contentRect: frame,
                          styleMask: .borderless,
                          backing: .buffered,
                          defer: false)
        window.contentView = view
        // Below the desktop-icon layer, so icons and Stage Manager stay usable.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        // .canJoinAllSpaces covers only desktop spaces; without .fullScreenAuxiliary the
        // window is absent from fullscreen spaces, and every backdrop glimpse there
        // (transitions, Split View gaps, menu bar reveal) shows the static poster instead.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                     .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.setFrame(frame, display: true)

        player.isMuted = true
        player.actionAtItemEnd = .none
        view.playerLayer.player = player
        window.orderFront(nil)
    }

    func play(_ url: URL) {
        looper = nil
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    func pause() { player.pause() }

    /// A desktop-level window is not always carried into a fullscreen space created after
    /// it was ordered in; re-ordering on every space change makes it show up there too.
    func raise() { window.orderFrontRegardless() }

    /// While displays detach and reattach around sleep the window server is free to move
    /// windows between screens, and the layout can come back identical to the one that
    /// bypasses a rebuild — so the frame is re-asserted rather than trusted.
    func align(to screen: NSScreen) {
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        window.orderFrontRegardless()
    }

    func resume() { player.play() }

    func tearDown() {
        player.pause()
        looper = nil
        window.orderOut(nil)
        window.close()
    }
}
