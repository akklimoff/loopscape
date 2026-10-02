import AppKit
import AVFoundation
import Network
import ServiceManagement
import UniformTypeIdentifiers
import os

extension AppDelegate {
    // MARK: - menu

    /// The logo's stacked cards, redrawn at menu bar scale: the artwork itself is colored and
    /// its card offsets disappear below ~20pt, while the status bar needs a monochrome template
    /// so macOS can tint it for the light, dark and highlighted states.
    func statusIcon() -> NSImage {
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

    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusIcon()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        appendNowPlaying(to: menu)

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
        menu.addItem(curtainItem())

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
        appendClipItems(to: menu)

        menu.addItem(revealItem())
        menu.addItem(loginItem())
        menu.addItem(.separator())
        menu.addItem(versionItem())
        menu.addItem(quitItem())
    }

    func appendNowPlaying(to menu: NSMenu) {
        guard let track = nowPlaying.track else { return }
        let item = NSMenuItem(title: track.menuTitle, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        menu.addItem(.separator())
    }

    func appendClipItems(to menu: NSMenu) {
        let clips = NSMenuItem(title: Lang.t("Spotify clips", "Клипы из Spotify"),
                               action: #selector(toggleClips), keyEquivalent: "")
        clips.target = self
        clips.state = clipMode.isEnabled ? .on : .off
        menu.addItem(clips)
        guard clipMode.isEnabled, YtDlp.locate(in: YtDlp.defaultDirectories()) == nil else { return }
        let hint = NSMenuItem(title: Lang.t("Needs yt-dlp: brew install yt-dlp",
                                            "Нужен yt-dlp: brew install yt-dlp"),
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    func curtainItem() -> NSMenuItem {
        let item = NSMenuItem(title: Lang.t("Transition", "Переход"),
                              action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for style in CurtainStyle.allCases {
            if style == .none { submenu.addItem(.separator()) }
            let entry = NSMenuItem(title: style.menuTitle, action: #selector(chooseCurtain(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.representedObject = style.rawValue
            entry.state = curtain.style == style ? .on : .off
            entry.isEnabled = style == .none || CurtainView.isAvailable
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    func appendEmptyState(to menu: NSMenu) {
        let hint = NSMenuItem(title: Lang.t("No wallpapers yet — drop clips in the folder below",
                                            "Обоев пока нет — положи ролики в папку ниже"),
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(revealItem())
        appendClipItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(loginItem())
        menu.addItem(.separator())
        menu.addItem(versionItem())
        menu.addItem(quitItem())
    }

    func versionItem() -> NSMenuItem {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let item = NSMenuItem(title: "Loopscape \(version ?? "dev")", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func revealItem() -> NSMenuItem {
        let item = NSMenuItem(title: Lang.t("Open wallpapers folder", "Открыть папку с обоями"),
                              action: #selector(revealFolder), keyEquivalent: "")
        item.target = self
        return item
    }

    func loginItem() -> NSMenuItem {
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

    func quitItem() -> NSMenuItem {
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
    @objc func choosePack(_ sender: NSMenuItem) {
        guard let slug = sender.representedObject as? String else { return }
        clipMode.packChosen()
        defaults.set(false, forKey: Key.paused)
        restartTimer()
        switchPack(to: slug)
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        defaults.set(value, forKey: Key.minutes)
        restartTimer()
        if let slug = currentSlug { rememberPin(slug) }
        refreshMenu()
    }

    /// Without an interval there is nothing to rotate to, so the pack on screen is held
    /// across launches instead of letting the next one pick at random.
    func rememberPin(_ slug: String) {
        if defaults.integer(forKey: Key.minutes) > 0 {
            defaults.removeObject(forKey: Key.pinned)
        } else {
            defaults.set(slug, forKey: Key.pinned)
        }
    }

    @objc func togglePause() {
        defaults.set(!isPaused, forKey: Key.paused)
        if isPaused {
            wallpapers.forEach { $0.pause() }
        } else if stream != nil {
            // The song played on while the wallpaper was paused; resuming the frozen frame
            // would leave the clip behind it by the whole pause.
            restorePlayback(clipAt: streamPosition)
        } else {
            if shouldPlay { wallpapers.forEach { $0.resume() } }
            repaintDesktopPicture()
        }
        restartTimer()
        refreshMenu()
    }

    @objc func chooseCurtain(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = CurtainStyle(rawValue: raw) else { return }
        defaults.set(raw, forKey: Key.curtain)
        curtain.style = style
        refreshMenu()
    }

    @objc func toggleClips() {
        let enabled = !clipMode.isEnabled
        defaults.set(enabled, forKey: Key.clips)
        apply(clipMode.setEnabled(enabled))
        refreshMenu()
    }

    @objc func nextPack() {
        guard packs.count > 1 else { return }
        clipMode.packChosen()
        defaults.set(false, forKey: Key.paused)
        restartTimer()
        let index = packs.firstIndex { $0.slug == currentSlug } ?? -1
        switchPack(to: packs[(index + 1) % packs.count].slug)
    }

    @objc func toggleLoginItem() {
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

    @objc func revealFolder() {
        NSWorkspace.shared.open(wallpapersDirectory)
    }

    @objc func quit() {
        wallpapers.forEach { $0.tearDown() }
        NSApp.terminate(nil)
    }
}
