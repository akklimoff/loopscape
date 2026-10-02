import AppKit
import AVFoundation
import Network
import ServiceManagement
import UniformTypeIdentifiers
import os

extension AppDelegate {
    // MARK: - screens

    func rebuildScreens() {
        wallpapers.forEach { $0.tearDown() }
        wallpapers = NSScreen.screens.map { ScreenWallpaper(screen: $0) }
        lastFrames = NSScreen.screens.map { $0.frame }
    }

    /// setDesktopImageURL itself posts didChangeScreenParameters, so rebuilding on every
    /// notification would tear the windows down and repaint the picture in a loop. Only a
    /// real geometry change warrants new windows.
    @objc func screensChanged() {
        // A display waking up or being unplugged can briefly report no screens; tearing
        // down then would leave nothing to restore once it comes back.
        guard !NSScreen.screens.isEmpty else { return }
        guard NSScreen.screens.map({ $0.frame }) != lastFrames else {
            realign()
            return
        }
        let clipAt = streamPosition
        rebuildScreens()
        // A display attached after the last pack switch still shows the default system
        // wallpaper, which the menu bar and "click to reveal desktop" blur instead of
        // the video — repaint the still on every geometry change, not just on switch.
        restorePlayback(clipAt: clipAt)
    }

    @objc func screensDidSleep() {
        displaysAsleep = true
        wallpapers.forEach { $0.pause() }
    }

    @objc func screensDidWake() {
        displaysAsleep = false
        if NSScreen.screens.map({ $0.frame }) != lastFrames, !NSScreen.screens.isEmpty {
            let clipAt = streamPosition
            rebuildScreens()
            restorePlayback(clipAt: clipAt)
        } else if stream != nil {
            // The song kept playing while the displays slept; resuming the frozen frame would
            // leave the video behind it by the whole sleep.
            realign()
            restorePlayback()
        } else {
            realign()
            if shouldPlay { wallpapers.forEach { $0.resume() } }
            // Waking repaints every screen from the wallpaper store; if a record went
            // stale while the displays slept, this is where the default would show.
            repaintDesktopPicture()
        }
    }

    /// Every path that (re)creates windows starts them playing, so a paused session must
    /// be re-frozen here or a display replug and launch would quietly resume it.
    func startPlayback(_ slug: String) {
        let target = url(for: slug)
        for wallpaper in wallpapers { wallpaper.play(target) }
        if isPaused || displaysAsleep { wallpapers.forEach { $0.pause() } }
        if curtain.isDown { awaitPackFrame() }
    }

    /// While the next track resolves, the clip on screen belongs to the previous one and the
    /// mode machine has no position for it, so the player's own is the one to keep.
    func restorePlayback(clipAt playerPosition: TimeInterval? = nil) {
        if let stream {
            let position = clipMode.clipPosition ?? playerPosition ?? stream.position
            startStream(StreamTarget(url: stream.url, position: position, stillID: stream.stillID),
                        animated: awaitingFirstFrame)
        } else if let slug = currentSlug {
            startPlayback(slug)
            syncDesktopPicture(slug)
        }
    }

    func awaitPackFrame() {
        awaitingFirstFrame = true
        packWait += 1
        checkPackFrame(packWait, until: Date().addingTimeInterval(2))
    }

    func checkPackFrame(_ wait: Int, until deadline: Date) {
        guard wait == packWait, stream == nil else { return }
        guard wallpapers.allSatisfy(\.isShowingPack) || Date() >= deadline else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.checkPackFrame(wait, until: deadline)
            }
            return
        }
        awaitingFirstFrame = false
        settleCurtain()
    }

    func switchPack(to slug: String) {
        let generation = streamGeneration
        curtain.whenCovered { [weak self] in
            guard let self, self.streamGeneration == generation else { return }
            self.applySelection(slug)
        }
    }

    func applySelection(_ slug: String) {
        let wasStreaming = stream != nil
        stream = nil
        currentSlug = slug
        rememberPin(slug)
        startPlayback(slug)
        syncDesktopPicture(slug)
        markCurrentForSaver(slug)
        refreshMenu()
        if wasStreaming { restartTimer() }
        settleCurtain()
    }
}
