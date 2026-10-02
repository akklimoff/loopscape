import AppKit
import AVFoundation
import Network
import ServiceManagement
import UniformTypeIdentifiers
import os

extension AppDelegate {
    // MARK: - streaming

    var cachesDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.aklimoff.loopscape")
    }

    var stillsDirectory: URL {
        cachesDirectory.appendingPathComponent("stills")
    }

    func stopStreamPlayback() {
        guard let playback = streamPlayback else { return }
        streamPlayback = nil
        awaitingFirstFrame = false
        syncToken += 1
        clipSync = ClipSync()
        playback.session.stop()
        playback.player.pause()
        playback.player.removeAllItems()
    }

    /// An animated start keeps the pack on screen until the curtain has covered it; the clip
    /// buffers on the shared player meanwhile, so the cover costs no time.
    func startStream(_ target: StreamTarget, animated: Bool = false) {
        if stream?.url != target.url { streamGeneration += 1 }
        stopStreamPlayback()
        stream = target
        timer?.invalidate()
        timer = nil
        if wallpapers.isEmpty { rebuildScreens() }
        let started = Date()
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .advance
        let session = StreamSession(url: target.url, player: player) { [weak self] failure in
            self?.streamFailed(failure)
        }
        streamPlayback = (session, player)
        session.onHeld = { [weak self, weak session] position in
            guard let self, let session else { return }
            self.held(session, at: position)
        }
        let show = { [weak self, weak session] in
            guard let self, let session, self.streamPlayback?.session === session else { return }
            self.wallpapers.forEach { $0.show(stream: session, on: player) }
        }
        if animated {
            awaitingFirstFrame = true
            curtain.whenCovered(show)
        } else {
            show()
        }
        session.start(at: target.position)
        if !shouldPlay { session.pause() }

        let still = stillsDirectory.appendingPathComponent("\(target.stillID).jpg")
        let cached = FileManager.default.fileExists(atPath: still.path)
        if cached { syncDesktopPicture(still: still) }
        StreamStill.firstFrame(of: player,
                               isPositioned: { [weak session] in session?.isPositioned ?? false }) { [weak self, weak session] frame in
            guard let self, let session, self.streamPlayback?.session === session else { return }
            let written = !cached && frame.map { StreamStill.write($0, to: still) } == true
            os_log("stream: first frame after %{public}.2f s, still %{public}@",
                   Date().timeIntervalSince(started),
                   frame == nil ? "none, timed out" : cached ? "cached" : written ? "written" : "not written")
            if written { self.syncDesktopPicture(still: still) }
            self.awaitingFirstFrame = false
            self.settleCurtain()
            if frame != nil {
                self.scheduleSync(after: 0.5)
                self.startAligning(videoID: target.stillID)
            }
        }
    }
}
