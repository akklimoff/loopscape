import AppKit
import AVFoundation
import Network
import ServiceManagement
import UniformTypeIdentifiers
import os

extension AppDelegate {
    // MARK: - Spotify clips

    /// Stream URLs are signed for the client's IP, so a new path invalidates all of them;
    /// a clip or a search that failed while offline gets its retry once a path is back.
    func networkChanged(online: Bool, interfaces: [String]) {
        let previous = network
        network = (online, interfaces)
        guard let previous, online, !previous.online || previous.interfaces != interfaces else { return }
        os_log("network: back on %{public}@", interfaces.joined(separator: ", "))
        if let resolver { clipQueue.async { resolver.forgetAllStreams() } }
        apply(clipMode.retryFailed())
    }

    func apply(_ effects: [ClipEffect]) {
        for effect in effects {
            switch effect {
            case .resolve(let query, let generation):
                resolveClip(query, generation: generation)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.curtainDelay) { [weak self] in
                    guard let self, self.clipMode.isCurrent(generation) else { return }
                    self.curtain.cover()
                }
            case .play(let videoID, let url, let position):
                os_log("clip: %{public}@ from %{public}.1f s", videoID, position)
                listenToSpotify()
                startStream(StreamTarget(url: url, position: position, stillID: videoID), animated: true)
            case .pause:
                if stream != nil { wallpapers.forEach { $0.pause() } }
            case .resume:
                if stream != nil, shouldPlay {
                    wallpapers.forEach { $0.resume() }
                    clipSync = ClipSync()
                    streamPlayback?.session.setRate(1)
                    scheduleSync(after: 0.5)
                }
            case .retryLater(let trackID, let delay):
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    self.apply(self.clipMode.retryFailed(trackID: trackID))
                }
            case .pauseTimeout(let delay):
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    let effects = self.clipMode.pauseTimedOut()
                    if !effects.isEmpty { os_log("clip: paused for %{public}.0f s — the pack plays meanwhile", ClipMode.pauseLimit) }
                    self.apply(effects)
                }
            case .seek(let position):
                os_log("clip: resync to %{public}.1f s", position)
                clipSync = ClipSync()
                streamPlayback?.session.setRate(1)
                streamPlayback?.session.jump(to: position)
                if streamPlayback != nil { scheduleSync(after: 3) }
            case .leave:
                os_log("clip: back to the pack")
                let generation = streamGeneration
                curtain.whenCovered { [weak self] in
                    guard let self, self.streamGeneration == generation else { return }
                    self.leaveStream()
                }
            }
        }
        settleCurtain()
    }

    func settleCurtain() {
        guard !clipMode.isResolving, !awaitingFirstFrame else { return }
        curtain.reveal()
    }

    /// A resolve blocks for seconds, so resolves queue up behind each other during fast
    /// skipping; each one re-checks on main that it is still wanted before it starts, so the
    /// queue never works through a backlog of tracks that are already gone.
    func resolveClip(_ query: TrackQuery, generation: Int) {
        guard let resolver else { return }
        clipQueue.async { [weak self] in
            let wanted = DispatchQueue.main.sync { self?.clipMode.isCurrent(generation) ?? false }
            guard wanted else { return }
            os_log("clip: resolving %{public}@ — %{public}@", query.artist, query.name)
            let outcome: ResolveOutcome
            do {
                switch try resolver.resolve(query) {
                case .stream(let videoID, let url, let offsets):
                    outcome = .found(videoID: videoID, url: url, offsets: offsets)
                case .none: outcome = .notFound
                }
            } catch ClipError.toolMissing {
                os_log("clip: yt-dlp is not installed")
                outcome = .toolMissing
            } catch {
                os_log("clip: resolve failed: %{public}@", String(describing: error))
                outcome = .failed
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if outcome == .notFound {
                    os_log("clip: no video for %{public}@ — %{public}@", query.artist, query.name)
                }
                self.apply(self.clipMode.resolved(outcome, generation: generation))
            }
        }
    }
}
