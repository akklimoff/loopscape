import AppKit
import AVFoundation
import Network
import ServiceManagement
import UniformTypeIdentifiers
import os

let defaultRoot: URL = {
    let base = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("Loopscape")
}()

extension CurtainStyle {
    var menuTitle: String {
        switch self {
        case .silk: return Lang.t("Silk", "Шёлк")
        case .loom: return Lang.t("Loom", "Ткацкий станок")
        case .wind: return Lang.t("Fabric in the wind", "Ткань на ветру")
        case .satin: return Lang.t("Satin", "Атлас")
        case .none: return Lang.t("No animation", "Без анимации")
        }
    }
}

enum Key {
    static let root = "videosRoot"
    static let pinned = "pinnedSlug"
    static let minutes = "rotateMinutes"
    static let loginAsked = "loginItemDecided"
    static let paused = "paused"
    static let clips = "spotifyClips"
    static let curtain = "clipCurtain"
}

/// The system language decides the whole UI; anything other than Russian gets English.
enum Lang {
    static let isRussian = (Locale.preferredLanguages.first ?? "en").hasPrefix("ru")

    static func t(_ en: String, _ ru: String) -> String { isRussian ? ru : en }
}

struct Pack: Decodable {
    let slug: String
    let ru: String
    let en: String

    var title: String { Lang.t(en, ru) }
}

struct StreamTarget {
    let url: URL
    let position: TimeInterval
    let stillID: String
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var wallpapers: [ScreenWallpaper] = [] {
        didSet { curtain.attach(wallpapers.map(\.curtain)) }
    }
    var packs: [Pack] = []
    var videoFiles: [String: URL] = [:]
    var statusItem: NSStatusItem?
    var timer: Timer?
    var libraryWatch: DispatchSourceFileSystemObject?
    var libraryReload: DispatchWorkItem?
    var currentSlug: String?
    var lastFrames: [NSRect] = []
    var root = defaultRoot
    var unposterable: Set<String> = []
    var activity: NSObjectProtocol?
    var stream: StreamTarget? {
        didSet { if stream == nil { stopStreamPlayback() } }
    }
    var streamPlayback: (session: StreamSession, player: AVQueuePlayer)?
    var streamPosition: TimeInterval? {
        guard let seconds = streamPlayback?.player.currentTime().seconds, seconds.isFinite else { return nil }
        return seconds
    }
    var desktopStill: URL?
    let options: LaunchOptions
    let nowPlaying = NowPlaying()
    var clipMode = ClipMode(isEnabled: false)
    var resolver: ClipResolver?
    let clipQueue = DispatchQueue(label: "com.aklimoff.loopscape.clips")
    lazy var curtain: CurtainDirector = {
        let director = CurtainDirector(
            style: CurtainStyle(rawValue: defaults.string(forKey: Key.curtain) ?? "") ?? .silk)
        director.onCovered = { [weak self] in self?.settleCurtain() }
        return director
    }()
    /// A curtain hiding a wallpaper that has no picture yet must stay down until it has one.
    var awaitingFirstFrame = false
    var packWait = 0
    var clipSync = ClipSync()
    var syncToken = 0
    var spotifyReadable = true
    let syncQueue = DispatchQueue(label: "com.aklimoff.loopscape.sync")
    var clipStore: ClipStore?
    let alignQueue = DispatchQueue(label: "com.aklimoff.loopscape.align")
    var alignToken = 0
    var listener: AnyObject?
    var soundtrack: (videoID: String, bands: [[Float]])?
    /// A cold start can land past the song; the second jump is buffered and lands in time.
    var jumpedAgain = false
    var unconfirmedOffset: (trackID: String, offset: TimeInterval)?
    /// Often enough that a pause the video inserts is caught a few seconds in, not ten.
    static let alignEvery: TimeInterval = 3
    static let alignHearing: TimeInterval = 6
    /// A shift this large is a cut in the video or a chorus mistaken for another, and only a
    /// second check that agrees tells the two apart.
    static let alignConfirmBeyond: TimeInterval = 0.5
    static let cutSearch: TimeInterval = 18
    /// Wide enough for any edit a video makes between two checks, narrow enough that a chorus
    /// heard again elsewhere in the song is out of reach.
    static let alignRadius: TimeInterval = 6
    static let alignSampleRate: Double = 12_000
    /// Between AVPlayer's play() and the picture moving.
    static let playLatency: TimeInterval = 0.05
    static let longestHold: TimeInterval = 4
    /// Bumped when a different clip starts, not when the same one restarts, so a pack swap
    /// queued behind the curtain can tell that a newer clip has taken the screen.
    var streamGeneration = 0
    /// Tracks without a clip are usually known misses that resolve in milliseconds; waiting
    /// this long before covering spares them a curtain that would only open on the same pack.
    static let curtainDelay: TimeInterval = 0.3

    let defaults = UserDefaults.standard

    var isPaused: Bool { defaults.bool(forKey: Key.paused) }

    /// Spotify's pause holds a clip still the way the menu's Pause holds everything.
    var displaysAsleep = false
    let pathMonitor = NWPathMonitor()
    var terminationSignal: DispatchSourceSignal?
    var network: (online: Bool, interfaces: [String])?
    var shouldPlay: Bool {
        !isPaused && !displaysAsleep && !clipMode.isClipPaused
    }

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let stored = defaults.string(forKey: Key.root), !stored.isEmpty {
            root = URL(fileURLWithPath: stored)
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

        let vp9 = YtDlp.decodesVP9()
        let clipFormat = YtDlp.format(allowingVP9: vp9)
        os_log("clip: %{public}@", vp9 ? "VP9 up to 1440p, H.264 fallback" : "H.264 only, no VP9 decoder")
        let store = ClipStore(file: root.appendingPathComponent("clips.json"))
        clipStore = store
        resolver = ClipResolver(store: store, source: OnDemandYtDlp(format: clipFormat))
        apply(clipMode.setEnabled(defaults.bool(forKey: Key.clips)))

        nowPlaying.onChange = { [weak self] track in
            guard let self else { return }
            os_log("now playing: %{public}@", track.map {
                "\($0.menuTitle), \($0.isPlaying ? "playing" : "paused") at \(Int($0.position)) s"
            } ?? "nothing")
            self.apply(self.clipMode.trackChanged(track))
            self.refreshMenu()
        }
        nowPlaying.start()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let interfaces = path.availableInterfaces.map(\.name)
            DispatchQueue.main.async { self?.networkChanged(online: online, interfaces: interfaces) }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        // `pkill` (build.sh, logout scripts) sends SIGTERM, which skips
        // applicationWillTerminate and would leave a clip's still as the desktop picture.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        terminationSignal = termination

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

        if let url = options.playURL {
            startStream(StreamTarget(url: url, position: options.playAt, stillID: LaunchOptions.stillID(for: url)))
        }
    }

    /// The desktop picture outlives the app: a clip's still would stay behind as the
    /// wallpaper of a song long over, while the pack's poster is what the screen saver and the
    /// next launch continue from.
    func applicationWillTerminate(_ notification: Notification) {
        YtDlp.terminateRunning()
        if stream != nil, let slug = currentSlug { syncDesktopPicture(slug) }
    }

    /// Wallpaper is per space and setDesktopImageURL reaches only the active one, so a
    /// space painted before the last pack switch — or never visited — still shows the
    /// system default during the switch animation, where only real wallpapers are drawn.
    /// Repainting on every space change covers each space as soon as it is entered.
    @objc func spaceChanged() {
        realign()
        repaintDesktopPicture()
    }

    func realign() {
        let screens = NSScreen.screens
        if screens.count == wallpapers.count {
            zip(wallpapers, screens).forEach { $0.align(to: $1) }
        } else {
            wallpapers.forEach { $0.raise() }
        }
    }
}
