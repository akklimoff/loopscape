import AppKit
import AVFoundation
import Network
import ServiceManagement
import UniformTypeIdentifiers
import os

extension AppDelegate {
    // MARK: - packs

    /// Asking AVFoundation instead of hardcoding extensions means any container the OS can
    /// decode (mp4, mov, m4v, ts, ...) works, and new ones appear with OS updates for free.
    static let playableExtensions: Set<String> = {
        var extensions: Set<String> = []
        for type in AVURLAsset.audiovisualTypes() {
            guard let ut = UTType(type.rawValue), ut.conforms(to: .movie) else { continue }
            for ext in ut.tags[.filenameExtension] ?? [] { extensions.insert(ext.lowercased()) }
        }
        return extensions.isEmpty ? ["mp4", "mov", "m4v"] : extensions
    }()

    func loadPacks() -> [Pack] {
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
        return videoFiles.keys.sorted().map { known[$0] ?? Pack(slug: $0, ru: $0, en: $0) }
    }

    var wallpapersDirectory: URL { root.appendingPathComponent("Wallpapers") }

    /// Releases up to 1.2 kept the library in "videos".
    func migrateLegacyVideosFolder() {
        let fm = FileManager.default
        let legacy = root.appendingPathComponent("videos")
        if fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: wallpapersDirectory.path) {
            try? fm.moveItem(at: legacy, to: wallpapersDirectory)
        }
    }

    // MARK: - screen saver

    /// The companion .saver reads the library straight from this folder — its sandbox
    /// grants read access to the whole disk — and needs only to be told which pack is on.
    func markCurrentForSaver(_ slug: String) {
        try? slug.write(to: root.appendingPathComponent("current.txt"),
                        atomically: true, encoding: .utf8)
    }

    /// Re-scans the folder and reconciles the screen with it: clips dropped in start
    /// playing without a restart, and a clip deleted from under the current pack gives
    /// way to another one instead of a frozen last frame.
    func reloadLibrary() {
        packs = loadPacks()
        unposterable = []
        if stream != nil {
            if !packs.contains(where: { $0.slug == currentSlug }) {
                if packs.isEmpty {
                    currentSlug = nil
                } else {
                    let slug = pick()
                    currentSlug = slug
                    markCurrentForSaver(slug)
                }
            }
        } else if packs.isEmpty {
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
    func watchLibrary() {
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

    func url(for slug: String) -> URL {
        videoFiles[slug] ?? wallpapersDirectory.appendingPathComponent("\(slug).mp4")
    }

    func poster(for slug: String) -> URL? {
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
    func generatePoster(for slug: String) -> URL? {
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

    func posterPath(_ slug: String) -> String {
        wallpapersDirectory.appendingPathComponent("\(slug).jpg").path
    }

    /// The menu bar blurs the *desktop picture*, not the window stack, so a video at
    /// desktop level leaves the old wallpaper showing through the top strip. Painting the
    /// system wallpaper with a still from the same clip makes that strip blend in.
    ///
    /// The wallpaper agent caches decoded pictures per display by URL and ignores the
    /// file changing underneath — a fixed slot file rewritten on every switch left one
    /// display showing the previous still. Every clip's still is therefore set under its
    /// own, never-rewritten URL. setDesktopImageURL reaches only the active space of each
    /// screen; spaceChanged repaints the others as they are entered.
    func syncDesktopPicture(_ slug: String) {
        guard let still = poster(for: slug) else { return }
        syncDesktopPicture(still: still)
    }

    func syncDesktopPicture(still: URL) {
        desktopStill = still
        let imageOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true,
        ]
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(still, for: screen, options: imageOptions)
        }
    }

    func repaintDesktopPicture() {
        if let desktopStill { syncDesktopPicture(still: desktopStill) }
    }

    func pick() -> String {
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

    // MARK: - timer

    func restartTimer() {
        guard stream == nil else { return }
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
            self.switchPack(to: self.pick())
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
}
