import AppKit
import AVFoundation
import Network
import ServiceManagement
import UniformTypeIdentifiers
import os

extension AppDelegate {
    // MARK: - clip sync

    func scheduleSync(after delay: TimeInterval) {
        syncToken += 1
        let token = syncToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.syncToken == token else { return }
            self.syncClip()
        }
    }

    /// Spotify's own position is exact; the extrapolated one is the fallback when Spotify
    /// does not answer or the user declined the Automation prompt.
    func syncClip() {
        guard let playback = streamPlayback, let trackID = clipMode.trackID,
              clipMode.trackPosition != nil, shouldPlay else { return scheduleSync(after: 3) }
        guard spotifyReadable else { return lineUp(playback.session, trackTime: clipMode.trackPosition, source: "estimate") }
        syncQueue.async { [weak self] in
            let reading = SpotifyPosition.read()
            DispatchQueue.main.async {
                guard let self, self.streamPlayback?.session === playback.session else { return }
                switch reading {
                case .success(let reading) where reading.trackID == trackID:
                    self.clipMode.positionRead(reading.position, trackID: reading.trackID, at: reading.at)
                    self.lineUp(playback.session, trackTime: self.clipMode.trackPosition, source: "Spotify")
                case .failure(.denied):
                    os_log("sync: Spotify declined Automation access — using the estimated position")
                    self.spotifyReadable = false
                    self.lineUp(playback.session, trackTime: self.clipMode.trackPosition, source: "estimate")
                case .failure(.failed(let code)):
                    os_log("sync: Spotify did not answer (%d)", code)
                    self.lineUp(playback.session, trackTime: self.clipMode.trackPosition, source: "estimate")
                default:
                    self.lineUp(playback.session, trackTime: self.clipMode.trackPosition, source: "estimate")
                }
            }
        }
    }

    func lineUp(_ session: StreamSession, trackTime: TimeInterval?, source: String) {
        guard let playback = streamPlayback, playback.session === session, let trackTime,
              playback.player.timeControlStatus == .playing else { return scheduleSync(after: 3) }
        let clipTime = playback.player.currentTime().seconds
        let duration = playback.player.currentItem?.duration.seconds
        let action = clipSync.decide(clipTime: clipTime, trackTime: trackTime,
                                     clipDuration: duration.flatMap { $0.isFinite ? $0 : nil })
        let offset = clipTime - trackTime
        let gap = String(format: "%.2f s %@ (%@)", abs(offset), offset < 0 ? "behind" : "ahead", source)
        switch action {
        case .keep:
            break
        case .rate(let rate):
            os_log("sync: clip %{public}@, rate %{public}.3f", gap, rate)
            session.setRate(rate)
        case .seek(let position):
            os_log("sync: clip %{public}@, seek to %{public}.1f s", gap, position)
            session.setRate(1)
            session.jump(to: position)
        }
        var next: TimeInterval = clipSync.isNudging ? 1 : 3
        if let song = clipMode.songPosition(at: Date()), let change = clipMode.offsets.nextChange(after: song) {
            next = min(next, max(0, change - song))
        }
        scheduleSync(after: next)
    }

    func streamFailed(_ failure: StreamFailure) {
        guard let failed = stream else { return }
        let offline = network?.online == false
        os_log("stream: %{public}@%{public}@ — back to the pack", failure.description,
               offline ? " while offline" : "")
        if !offline, let resolver {
            clipQueue.async { resolver.forgetStream(of: failed.stillID) }
        }
        leaveStream()
        apply(clipMode.streamFailed(offline: offline))
    }

    func leaveStream() {
        guard stream != nil else { return }
        stream = nil
        stopAligning()
        restartTimer()
        if let slug = currentSlug {
            startPlayback(slug)
            syncDesktopPicture(slug)
        } else if !packs.isEmpty {
            applySelection(pick())
        } else {
            wallpapers.forEach { $0.tearDown() }
            wallpapers = []
        }
    }
}
