import AppKit
import AVFoundation
import ServiceManagement

private let defaultRoot: URL = {
    let base = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("Loopscape")
}()

private enum Key {
    static let root = "videosRoot"
    static let pinned = "pinnedSlug"
    static let shuffle = "shuffle"
    static let minutes = "rotateMinutes"
    static let loginAsked = "loginItemDecided"
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
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
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
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var currentSlug: String?
    private var lastFrames: [NSRect] = []
    private var root = defaultRoot

    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let stored = defaults.string(forKey: Key.root), !stored.isEmpty {
            root = URL(fileURLWithPath: stored)
        }
        if defaults.object(forKey: Key.minutes) == nil { defaults.set(15, forKey: Key.minutes) }
        if defaults.object(forKey: Key.shuffle) == nil { defaults.set(true, forKey: Key.shuffle) }
        // A wallpaper that vanishes after a reboot is useless, so opt in once and let the
        // menu switch it off afterwards.
        if defaults.object(forKey: Key.loginAsked) == nil {
            defaults.set(true, forKey: Key.loginAsked)
            try? SMAppService.mainApp.register()
        }

        // A drag-and-drop install has no setup step, so the folder has to appear on its own
        // or the first launch is a dead end.
        try? FileManager.default.createDirectory(at: videosDirectory,
                                                 withIntermediateDirectories: true)

        buildStatusItem()
        startIfReady()
        refreshMenu()

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
    }

    // MARK: - packs

    private func loadPacks() -> [Pack] {
        let videos = root.appendingPathComponent("videos")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: videos.path)) ?? []
        let slugs = Set(files.filter { $0.hasSuffix(".mp4") }.map { String($0.dropLast(4)) })

        var known: [String: Pack] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("packs.json")),
           let decoded = try? JSONDecoder().decode([Pack].self, from: data) {
            for pack in decoded { known[pack.slug] = pack }
        }
        return slugs.sorted().map { known[$0] ?? Pack(slug: $0, ru: $0, en: $0) }
    }

    private var videosDirectory: URL { root.appendingPathComponent("videos") }

    /// Runs again whenever the menu opens while empty, so dropping clips in needs no restart.
    private func startIfReady() {
        guard wallpapers.isEmpty else { return }
        packs = loadPacks()
        guard !packs.isEmpty else { return }
        rebuildScreens()
        applySelection(pick())
        restartTimer()
    }

    private func url(for slug: String) -> URL {
        root.appendingPathComponent("videos").appendingPathComponent("\(slug).mp4")
    }

    private func poster(for slug: String) -> URL {
        root.appendingPathComponent("videos").appendingPathComponent("\(slug).jpg")
    }

    /// The menu bar blurs the *desktop picture*, not the window stack, so a video at
    /// desktop level leaves the old wallpaper showing through the top strip. Painting the
    /// system wallpaper with a still from the same clip makes that strip blend in.
    private func syncDesktopPicture(_ slug: String) {
        let still = poster(for: slug)
        guard FileManager.default.fileExists(atPath: still.path) else { return }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true,
        ]
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(still, for: screen, options: options)
        }
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
        guard NSScreen.screens.map({ $0.frame }) != lastFrames else { return }
        rebuildScreens()
        if let slug = currentSlug { startPlayback(slug) }
    }

    @objc private func screensDidSleep() {
        wallpapers.forEach { $0.pause() }
    }

    @objc private func screensDidWake() {
        if NSScreen.screens.map({ $0.frame }) != lastFrames, !NSScreen.screens.isEmpty {
            rebuildScreens()
            if let slug = currentSlug { startPlayback(slug) }
        } else {
            wallpapers.forEach { $0.resume() }
        }
    }

    private func startPlayback(_ slug: String) {
        let target = url(for: slug)
        for wallpaper in wallpapers { wallpaper.play(target) }
    }

    private func applySelection(_ slug: String) {
        currentSlug = slug
        startPlayback(slug)
        syncDesktopPicture(slug)
        refreshMenu()
    }

    // MARK: - timer

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        let minutes = defaults.integer(forKey: Key.minutes)
        let shuffling = defaults.bool(forKey: Key.shuffle)
        guard shuffling, minutes > 0, packs.count > 1,
              defaults.string(forKey: Key.pinned) == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60,
                                     repeats: true) { [weak self] _ in
            guard let self else { return }
            self.applySelection(self.pick())
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
        // Enabling is driven by refreshMenu, not by AppKit's responder lookup, so the
        // shuffle row can be greyed out while its action target is still wired up.
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

        let pinned = defaults.string(forKey: Key.pinned)
        for pack in packs {
            let item = NSMenuItem(title: pack.title,
                                  action: #selector(choosePack(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = pack.slug
            if pinned == pack.slug {
                item.state = .on
            } else if pinned == nil, pack.slug == currentSlug {
                item.state = .mixed
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let minutes = defaults.integer(forKey: Key.minutes)
        let shuffle = NSMenuItem(title: minutes > 0
                                    ? Lang.t("Shuffle every \(minutes) min", "Листать все, каждые \(minutes) мин")
                                    : Lang.t("Shuffle — interval off", "Листать все — интервал выключен"),
                                 action: #selector(toggleShuffle),
                                 keyEquivalent: "")
        shuffle.target = self
        shuffle.state = (pinned == nil && defaults.bool(forKey: Key.shuffle)) ? .on : .off
        shuffle.isEnabled = minutes > 0
        menu.addItem(shuffle)

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

        menu.addItem(revealItem())
        menu.addItem(loginItem())
        menu.addItem(.separator())
        menu.addItem(quitItem())
    }

    private func appendEmptyState(to menu: NSMenu) {
        let hint = NSMenuItem(title: Lang.t("No videos yet — drop clips in the folder below",
                                            "Видео пока нет — положи ролики в папку ниже"),
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(revealItem())
        menu.addItem(.separator())
        menu.addItem(loginItem())
        menu.addItem(.separator())
        menu.addItem(quitItem())
    }

    private func revealItem() -> NSMenuItem {
        let item = NSMenuItem(title: Lang.t("Open videos folder", "Открыть папку с видео"),
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
        if packs.isEmpty { startIfReady() }
        refreshMenu()
    }

    @objc private func choosePack(_ sender: NSMenuItem) {
        guard let slug = sender.representedObject as? String else { return }
        defaults.set(slug, forKey: Key.pinned)
        defaults.set(false, forKey: Key.shuffle)
        restartTimer()
        applySelection(slug)
    }

    @objc private func toggleShuffle() {
        let enabling = !(defaults.string(forKey: Key.pinned) == nil && defaults.bool(forKey: Key.shuffle))
        if enabling {
            defaults.removeObject(forKey: Key.pinned)
            defaults.set(true, forKey: Key.shuffle)
        } else {
            defaults.set(false, forKey: Key.shuffle)
            if let slug = currentSlug { defaults.set(slug, forKey: Key.pinned) }
        }
        restartTimer()
        refreshMenu()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        defaults.set(value, forKey: Key.minutes)
        // Without an interval there is nothing to rotate to, so hold the current pack
        // instead of letting the next launch pick at random.
        if value == 0, defaults.string(forKey: Key.pinned) == nil, let slug = currentSlug {
            defaults.set(slug, forKey: Key.pinned)
            defaults.set(false, forKey: Key.shuffle)
        }
        restartTimer()
        refreshMenu()
    }

    @objc private func nextPack() {
        guard packs.count > 1 else { return }
        let index = packs.firstIndex { $0.slug == currentSlug } ?? -1
        let slug = packs[(index + 1) % packs.count].slug
        if defaults.string(forKey: Key.pinned) != nil {
            defaults.set(slug, forKey: Key.pinned)
        }
        applySelection(slug)
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
        NSWorkspace.shared.open(videosDirectory)
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
