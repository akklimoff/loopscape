import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers

private let defaultRoot: URL = {
    let base = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("Loopscape")
}()

private enum Key {
    static let root = "videosRoot"
    static let pinned = "pinnedSlug"
    static let minutes = "rotateMinutes"
    static let loginAsked = "loginItemDecided"
    static let paused = "paused"
    static let posterSlot = "posterSlot"
    static let posterSlug = "posterSlug"
}

/// The system language decides the whole UI; anything other than Russian gets English.
private enum Lang {
    static let isRussian = (Locale.preferredLanguages.first ?? "en").hasPrefix("ru")

    static func t(_ en: String, _ ru: String) -> String { isRussian ? ru : en }
}

struct Pack: Decodable {
    let slug: String
    let ru: String
    let en: String

    var title: String { Lang.t(en, ru) }
}

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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var wallpapers: [ScreenWallpaper] = []
    private var packs: [Pack] = []
    private var videoFiles: [String: URL] = [:]
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var libraryWatch: DispatchSourceFileSystemObject?
    private var libraryReload: DispatchWorkItem?
    private var currentSlug: String?
    private var lastFrames: [NSRect] = []
    private var root = defaultRoot
    private var posterSlot = false
    private var posterSlug: String?
    private var unposterable: Set<String> = []
    private var activity: NSObjectProtocol?

    private let defaults = UserDefaults.standard

    private var isPaused: Bool { defaults.bool(forKey: Key.paused) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let stored = defaults.string(forKey: Key.root), !stored.isEmpty {
            root = URL(fileURLWithPath: stored)
        }
        // Every wallpaper-store record from the previous session points at the slot file
        // that was active when it ended. Starting the alternation from scratch would make
        // the first switch overwrite exactly that file with a different image; restoring
        // the parity keeps the first write in the other slot.
        posterSlot = defaults.bool(forKey: Key.posterSlot)
        if FileManager.default.fileExists(atPath: posterURL(slot: posterSlot).path) {
            posterSlug = defaults.string(forKey: Key.posterSlug)
        }
        if defaults.object(forKey: Key.minutes) == nil { defaults.set(15, forKey: Key.minutes) }
        // A wallpaper that vanishes after a reboot is useless, so opt in once and let the
        // menu switch it off afterwards.
        if defaults.object(forKey: Key.loginAsked) == nil {
            defaults.set(true, forKey: Key.loginAsked)
            try? SMAppService.mainApp.register()
        }

        // A drag-and-drop install has no setup step, so the folder has to appear on its own
        // or the first launch is a dead end.
        migrateLegacyVideosFolder()
        try? FileManager.default.createDirectory(at: wallpapersDirectory,
                                                 withIntermediateDirectories: true)

        buildStatusItem()
        reloadLibrary()
        watchLibrary()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensDidSleep),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(spaceChanged),
                              name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    /// Wallpaper is per space and setDesktopImageURL reaches only the active one, so a
    /// space painted before the last pack switch — or never visited — still shows the
    /// system default during the switch animation, where only real wallpapers are drawn.
    /// Repainting on every space change covers each space as soon as it is entered.
    @objc private func spaceChanged() {
        realign()
        if let slug = currentSlug { syncDesktopPicture(slug) }
    }

    private func realign() {
        let screens = NSScreen.screens
        if screens.count == wallpapers.count {
            zip(wallpapers, screens).forEach { $0.align(to: $1) }
        } else {
            wallpapers.forEach { $0.raise() }
        }
    }

    // MARK: - packs

    /// Asking AVFoundation instead of hardcoding extensions means any container the OS can
    /// decode (mp4, mov, m4v, ts, ...) works, and new ones appear with OS updates for free.
    private static let playableExtensions: Set<String> = {
        var extensions: Set<String> = []
        for type in AVURLAsset.audiovisualTypes() {
            guard let ut = UTType(type.rawValue), ut.conforms(to: .movie) else { continue }
            for ext in ut.tags[.filenameExtension] ?? [] { extensions.insert(ext.lowercased()) }
        }
        return extensions.isEmpty ? ["mp4", "mov", "m4v"] : extensions
    }()

    private func loadPacks() -> [Pack] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: wallpapersDirectory.path)) ?? []
        videoFiles = [:]
        for file in files.sorted() {
            let url = wallpapersDirectory.appendingPathComponent(file)
            guard Self.playableExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let slug = url.deletingPathExtension().lastPathComponent
            if videoFiles[slug] == nil { videoFiles[slug] = url }
        }

        var known: [String: Pack] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("packs.json")),
           let decoded = try? JSONDecoder().decode([Pack].self, from: data) {
            for pack in decoded { known[pack.slug] = pack }
        }
        syncSaverMirror()
        return videoFiles.keys.sorted().map { known[$0] ?? Pack(slug: $0, ru: $0, en: $0) }
    }

    private var wallpapersDirectory: URL { root.appendingPathComponent("Wallpapers") }

    /// Releases up to 1.2 kept the library in "videos"; the mirror inside the saver
    /// container followed the same name and would otherwise linger as a dead copy.
    private func migrateLegacyVideosFolder() {
        let fm = FileManager.default
        let legacy = root.appendingPathComponent("videos")
        if fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: wallpapersDirectory.path) {
            try? fm.moveItem(at: legacy, to: wallpapersDirectory)
        }
        try? fm.removeItem(at: Self.saverMirror.deletingLastPathComponent()
                                .appendingPathComponent("videos"))
    }

    // MARK: - screen saver mirror

    private static let saverMirror = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver")
        .appendingPathComponent("Data/Library/Application Support/Loopscape/Wallpapers")

    /// The companion .saver runs inside the sandboxed legacyScreenSaver appex, which cannot
    /// see the real wallpapers folder — its home is its own container. Mirror the clips there as
    /// hardlinks: same bytes on disk, and library edits reach the saver on the next pack load.
    private func syncSaverMirror() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.saverMirror, withIntermediateDirectories: true)

        let wanted = Set(videoFiles.values.map { $0.lastPathComponent })
        let existing = (try? fm.contentsOfDirectory(atPath: Self.saverMirror.path)) ?? []
        for name in existing where !wanted.contains(name) && name != "current.txt" {
            try? fm.removeItem(at: Self.saverMirror.appendingPathComponent(name))
        }
        for source in videoFiles.values {
            let mirror = Self.saverMirror.appendingPathComponent(source.lastPathComponent)
            let sourceInode = (try? fm.attributesOfItem(atPath: source.path))?[.systemFileNumber] as? Int
            let mirrorInode = (try? fm.attributesOfItem(atPath: mirror.path))?[.systemFileNumber] as? Int
            if sourceInode != nil, sourceInode == mirrorInode { continue }
            try? fm.removeItem(at: mirror)
            try? fm.linkItem(at: source, to: mirror)
        }
    }

    private func markCurrentForSaver(_ slug: String) {
        try? slug.write(to: Self.saverMirror.appendingPathComponent("current.txt"),
                        atomically: true, encoding: .utf8)
    }

    /// Re-scans the folder and reconciles the screen with it: clips dropped in start
    /// playing without a restart, and a clip deleted from under the current pack gives
    /// way to another one instead of a frozen last frame.
    private func reloadLibrary() {
        packs = loadPacks()
        if packs.isEmpty {
            wallpapers.forEach { $0.tearDown() }
            wallpapers = []
            currentSlug = nil
        } else if wallpapers.isEmpty {
            rebuildScreens()
            applySelection(pick())
        } else if !packs.contains(where: { $0.slug == currentSlug }) {
            applySelection(pick())
        }
        // Opening the menu must not reset the countdown, so only a stopped timer is touched.
        if timer == nil || packs.count < 2 { restartTimer() }
        refreshMenu()
    }

    /// Finder copies a large clip in many writes; waiting for the burst to settle keeps
    /// AVPlayer from opening a half-written file.
    private func watchLibrary() {
        let descriptor = open(wallpapersDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.libraryReload?.cancel()
            let reload = DispatchWorkItem { [weak self] in self?.reloadLibrary() }
            self.libraryReload = reload
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reload)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        libraryWatch = source
    }

    private func url(for slug: String) -> URL {
        videoFiles[slug] ?? wallpapersDirectory.appendingPathComponent("\(slug).mp4")
    }

    private func poster(for slug: String) -> URL? {
        for ext in ["jpg", "jpeg", "png", "heic"] {
            let still = wallpapersDirectory.appendingPathComponent("\(slug).\(ext)")
            if FileManager.default.fileExists(atPath: still.path) { return still }
        }
        return generatePoster(for: slug)
    }

    /// A clip dropped in without a still would leave the menu bar strip blurring the old
    /// wallpaper, so the first frame is extracted once and kept beside the clip. A clip
    /// that yields no frame is remembered: the sync runs on every space change, and a
    /// failed 4K decode on the main thread each time would make switching desktops lag.
    private func generatePoster(for slug: String) -> URL? {
        guard let clip = videoFiles[slug], !unposterable.contains(slug) else { return nil }
        defer { if !FileManager.default.fileExists(atPath: posterPath(slug)) { unposterable.insert(slug) } }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip))
        generator.appliesPreferredTrackTransform = true
        guard let frame = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        // HEVC main10 clips come out as 16-bit frames, which the JPEG encoder rejects.
        guard let context = CGContext(data: nil, width: frame.width, height: frame.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        guard let eightBit = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: eightBit)
                  .representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return nil }
        let still = URL(fileURLWithPath: posterPath(slug))
        guard (try? jpeg.write(to: still, options: .atomic)) != nil else { return nil }
        return still
    }

    private func posterPath(_ slug: String) -> String {
        wallpapersDirectory.appendingPathComponent("\(slug).jpg").path
    }

    /// The menu bar blurs the *desktop picture*, not the window stack, so a video at
    /// desktop level leaves the old wallpaper showing through the top strip. Painting the
    /// system wallpaper with a still from the same clip makes that strip blend in.
    ///
    /// The wallpaper store keeps one record per space and display, and setDesktopImageURL
    /// reaches only the active space of each screen — a record written when the poster
    /// lived at another path survives until that space is repainted, and once the old file
    /// is gone macOS silently falls back to the built-in default wherever the real picture
    /// is drawn (Exposé, Mission Control, the menu bar strip). Two fixed slot files that
    /// are overwritten but never deleted keep every stale record pointing at an image that
    /// exists; alternating slots on each pack switch sidesteps the same-URL set being
    /// treated as a no-op.
    private func syncDesktopPicture(_ slug: String) {
        guard let still = poster(for: slug) else { return }
        let fm = FileManager.default
        if posterSlug != slug || !fm.fileExists(atPath: posterURL(slot: posterSlot).path) {
            let next = posterURL(slot: !posterSlot)
            // The wallpaper agent can revalidate its records at any moment (login, wake,
            // Mission Control) and a record whose file is missing is silently rewritten to
            // the built-in default — so the slot file must never be absent, even between
            // two of our own filesystem calls. Stage the copy and swap it in atomically.
            let staged = root.appendingPathComponent("poster-staged.jpg")
            try? fm.removeItem(at: staged)
            guard (try? fm.copyItem(at: still, to: staged)) != nil else { return }
            if fm.fileExists(atPath: next.path) {
                // Without this option the swapped-in file inherits the old modification
                // date; the wallpaper agent caches decoded images by URL and date, so a
                // display that had this slot cached keeps showing the previous still.
                guard (try? fm.replaceItemAt(next, withItemAt: staged,
                                             options: .usingNewMetadataOnly)) != nil else { return }
            } else {
                guard (try? fm.moveItem(at: staged, to: next)) != nil else { return }
            }
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: next.path)
            posterSlot.toggle()
            posterSlug = slug
            defaults.set(posterSlot, forKey: Key.posterSlot)
            defaults.set(slug, forKey: Key.posterSlug)
        }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true,
        ]
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(posterURL(slot: posterSlot),
                                                       for: screen, options: options)
        }
    }

    private func posterURL(slot: Bool) -> URL {
        root.appendingPathComponent(slot ? "poster-a.jpg" : "poster-b.jpg")
    }

    private func pick() -> String {
        if let pinned = defaults.string(forKey: Key.pinned),
           packs.contains(where: { $0.slug == pinned }) {
            return pinned
        }
        if packs.count == 1 { return packs[0].slug }
        var slug = packs[Int.random(in: 0..<packs.count)].slug
        if slug == currentSlug {
            slug = packs[(packs.firstIndex { $0.slug == slug }! + 1) % packs.count].slug
        }
        return slug
    }

    // MARK: - screens

    private func rebuildScreens() {
        wallpapers.forEach { $0.tearDown() }
        wallpapers = NSScreen.screens.map { ScreenWallpaper(screen: $0) }
        lastFrames = NSScreen.screens.map { $0.frame }
    }

    /// setDesktopImageURL itself posts didChangeScreenParameters, so rebuilding on every
    /// notification would tear the windows down and repaint the picture in a loop. Only a
    /// real geometry change warrants new windows.
    @objc private func screensChanged() {
        // A display waking up or being unplugged can briefly report no screens; tearing
        // down then would leave nothing to restore once it comes back.
        guard !NSScreen.screens.isEmpty else { return }
        guard NSScreen.screens.map({ $0.frame }) != lastFrames else {
            realign()
            return
        }
        rebuildScreens()
        if let slug = currentSlug {
            startPlayback(slug)
            // A display attached after the last pack switch still shows the default system
            // wallpaper, which the menu bar and "click to reveal desktop" blur instead of
            // the video — repaint the still on every geometry change, not just on switch.
            syncDesktopPicture(slug)
        }
    }

    @objc private func screensDidSleep() {
        wallpapers.forEach { $0.pause() }
    }

    @objc private func screensDidWake() {
        if NSScreen.screens.map({ $0.frame }) != lastFrames, !NSScreen.screens.isEmpty {
            rebuildScreens()
            if let slug = currentSlug {
                startPlayback(slug)
                syncDesktopPicture(slug)
            }
        } else {
            realign()
            if !isPaused { wallpapers.forEach { $0.resume() } }
            // Waking repaints every screen from the wallpaper store; if a record went
            // stale while the displays slept, this is where the default would show.
            if let slug = currentSlug { syncDesktopPicture(slug) }
        }
    }

    /// Every path that (re)creates windows starts them playing, so a paused session must
    /// be re-frozen here or a display replug and launch would quietly resume it.
    private func startPlayback(_ slug: String) {
        let target = url(for: slug)
        for wallpaper in wallpapers { wallpaper.play(target) }
        if isPaused { wallpapers.forEach { $0.pause() } }
    }

    private func applySelection(_ slug: String) {
        currentSlug = slug
        rememberPin(slug)
        startPlayback(slug)
        syncDesktopPicture(slug)
        markCurrentForSaver(slug)
        refreshMenu()
    }

    // MARK: - timer

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        let minutes = defaults.integer(forKey: Key.minutes)
        guard minutes > 0, packs.count > 1, !isPaused else {
            if let token = activity { ProcessInfo.processInfo.endActivity(token) }
            activity = nil
            return
        }
        let rotation = Timer(timeInterval: Double(minutes) * 60,
                             repeats: true) { [weak self] _ in
            guard let self else { return }
            self.applySelection(self.pick())
        }
        rotation.tolerance = 30
        // .common keeps the timer ticking while the status menu is open; App Nap would
        // otherwise defer a background accessory's timers indefinitely, so hold an
        // activity for as long as rotation is on.
        RunLoop.main.add(rotation, forMode: .common)
        timer = rotation
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Wallpaper rotation")
        }
    }

    // MARK: - menu

    /// The logo's stacked cards, redrawn at menu bar scale: the artwork itself is colored and
    /// its card offsets disappear below ~20pt, while the status bar needs a monochrome template
    /// so macOS can tint it for the light, dark and highlighted states.
    private func statusIcon() -> NSImage {
        let side: CGFloat = 18
        let box: CGFloat = 12
        let radius: CGFloat = 3
        let offset: CGFloat = 4.6
        let gap: CGFloat = 1.4
        let line: CGFloat = 1.4

        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()

        let margin = (side - box - offset) / 2
        let front = NSRect(x: margin + offset, y: margin, width: box, height: box)
        let back = front.offsetBy(dx: -offset, dy: offset)

        NSColor.black.setStroke()
        let outline = NSBezierPath(roundedRect: back.insetBy(dx: line / 2, dy: line / 2),
                                   xRadius: radius, yRadius: radius)
        outline.lineWidth = line
        outline.stroke()

        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(roundedRect: front.insetBy(dx: -gap, dy: -gap),
                     xRadius: radius + gap, yRadius: radius + gap).fill()

        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.black.setFill()
        NSBezierPath(roundedRect: front, xRadius: radius, yRadius: radius).fill()

        image.unlockFocus()
        image.isTemplate = true
        image.accessibilityDescription = "Loopscape"
        return image
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusIcon()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        guard !packs.isEmpty else {
            appendEmptyState(to: menu)
            return
        }

        let minutes = defaults.integer(forKey: Key.minutes)
        for pack in packs {
            let item = NSMenuItem(title: pack.title,
                                  action: #selector(choosePack(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = pack.slug
            if pack.slug == currentSlug { item.state = minutes > 0 ? .mixed : .on }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let intervals = NSMenuItem(title: Lang.t("Interval", "Интервал"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for value in [0, 5, 15, 30, 60] {
            let entry = NSMenuItem(title: value == 0 ? Lang.t("Off", "Выключен")
                                                 : Lang.t("\(value) min", "\(value) мин"),
                                   action: #selector(setInterval(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.representedObject = value
            entry.state = value == minutes ? .on : .off
            submenu.addItem(entry)
            if value == 0 { submenu.addItem(.separator()) }
        }
        intervals.submenu = submenu
        menu.addItem(intervals)

        menu.addItem(.separator())

        let next = NSMenuItem(title: Lang.t("Next wallpaper", "Следующий фон"),
                                action: #selector(nextPack), keyEquivalent: "")
        next.target = self
        menu.addItem(next)

        let pause = NSMenuItem(title: isPaused ? Lang.t("Resume", "Продолжить")
                                               : Lang.t("Pause", "Пауза"),
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = isPaused ? .on : .off
        menu.addItem(pause)

        menu.addItem(revealItem())
        menu.addItem(loginItem())
        menu.addItem(.separator())
        menu.addItem(versionItem())
        menu.addItem(quitItem())
    }

    private func appendEmptyState(to menu: NSMenu) {
        let hint = NSMenuItem(title: Lang.t("No wallpapers yet — drop clips in the folder below",
                                            "Обоев пока нет — положи ролики в папку ниже"),
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(revealItem())
        menu.addItem(.separator())
        menu.addItem(loginItem())
        menu.addItem(.separator())
        menu.addItem(versionItem())
        menu.addItem(quitItem())
    }

    private func versionItem() -> NSMenuItem {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let item = NSMenuItem(title: "Loopscape \(version ?? "dev")", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func revealItem() -> NSMenuItem {
        let item = NSMenuItem(title: Lang.t("Open wallpapers folder", "Открыть папку с обоями"),
                              action: #selector(revealFolder), keyEquivalent: "")
        item.target = self
        return item
    }

    private func loginItem() -> NSMenuItem {
        let item = NSMenuItem(title: Lang.t("Launch at login", "Запускать при входе"),
                              action: #selector(toggleLoginItem), keyEquivalent: "")
        item.target = self
        switch SMAppService.mainApp.status {
        case .enabled: item.state = .on
        case .requiresApproval: item.state = .mixed
        default: item.state = .off
        }
        return item
    }

    private func quitItem() -> NSMenuItem {
        let item = NSMenuItem(title: Lang.t("Quit", "Выйти"),
                              action: #selector(quit), keyEquivalent: "q")
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        reloadLibrary()
    }

    /// With rotation on, picking a pack means "show this one now" and the countdown starts
    /// over; with the interval off it is the pack that survives the next launch.
    @objc private func choosePack(_ sender: NSMenuItem) {
        guard let slug = sender.representedObject as? String else { return }
        defaults.set(false, forKey: Key.paused)
        restartTimer()
        applySelection(slug)
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        defaults.set(value, forKey: Key.minutes)
        restartTimer()
        if let slug = currentSlug { rememberPin(slug) }
        refreshMenu()
    }

    /// Without an interval there is nothing to rotate to, so the pack on screen is held
    /// across launches instead of letting the next one pick at random.
    private func rememberPin(_ slug: String) {
        if defaults.integer(forKey: Key.minutes) > 0 {
            defaults.removeObject(forKey: Key.pinned)
        } else {
            defaults.set(slug, forKey: Key.pinned)
        }
    }

    @objc private func togglePause() {
        defaults.set(!isPaused, forKey: Key.paused)
        if isPaused {
            wallpapers.forEach { $0.pause() }
        } else {
            wallpapers.forEach { $0.resume() }
            if let slug = currentSlug { syncDesktopPicture(slug) }
        }
        restartTimer()
        refreshMenu()
    }

    @objc private func nextPack() {
        guard packs.count > 1 else { return }
        defaults.set(false, forKey: Key.paused)
        restartTimer()
        let index = packs.firstIndex { $0.slug == currentSlug } ?? -1
        applySelection(packs[(index + 1) % packs.count].slug)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSSound.beep()
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refreshMenu()
    }

    @objc private func revealFolder() {
        NSWorkspace.shared.open(wallpapersDirectory)
    }

    @objc private func quit() {
        wallpapers.forEach { $0.tearDown() }
        NSApp.terminate(nil)
    }

}

// launchd's RunAtLoad and a manual launch can race; a second instance would stack
// another set of desktop windows and double the decode cost.
let mine = ProcessInfo.processInfo.processIdentifier
let bundleID = Bundle.main.bundleIdentifier ?? "com.aklimoff.loopscape"
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .contains(where: { $0.processIdentifier != mine }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
