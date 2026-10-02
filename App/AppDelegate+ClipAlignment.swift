import AppKit
import AVFoundation
import Network
import ServiceManagement
import UniformTypeIdentifiers
import os

extension AppDelegate {
    // MARK: - clip alignment

    /// A music video often runs ahead of or behind the album recording (an intro, a cut), and
    /// no clock can see that; listening to Spotify and finding what it played in the video's
    /// soundtrack can. Checked every few seconds near where the clip is expected, so a cut
    /// mid-song is caught where it happens; what is measured is kept in clips.json.
    func startAligning(videoID: String) {
        guard #available(macOS 14.2, *) else { return }
        alignToken += 1
        let token = alignToken
        unconfirmedOffset = nil
        guard listenToSpotify() else { return }
        if soundtrack?.videoID == videoID { return scheduleAlignCheck(videoID: videoID, token: token) }
        soundtrack = nil
        let cache = SoundtrackCache(directory: cachesDirectory.appendingPathComponent("soundtracks"))
        alignQueue.async { [weak self] in
            let bands: [[Float]]
            if let cached = cache.bands(of: videoID) {
                bands = cached
            } else {
                do {
                    let url = try OnDemandYtDlp().audio(videoID: videoID)
                    let samples = try ClipAudio.load(url, sampleRate: Self.alignSampleRate)
                    bands = AudioAlign.onsets(samples, sampleRate: Self.alignSampleRate)
                    cache.save(bands, of: videoID)
                } catch {
                    return os_log("align: no soundtrack for %{public}@: %{public}@", videoID, String(describing: error))
                }
            }
            DispatchQueue.main.async {
                guard let self, self.alignToken == token else { return }
                self.soundtrack = (videoID, bands)
                self.scheduleAlignCheck(videoID: videoID, token: token)
            }
        }
    }

    /// Started with the clip rather than at its first check, so the first check already has
    /// enough heard to place the clip.
    @discardableResult
    func listenToSpotify() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        guard listener == nil else { return true }
        do {
            listener = try SpotifyAudio.listen()
            return true
        } catch {
            os_log("align: cannot listen to Spotify: %{public}@", String(describing: error))
            return false
        }
    }

    func stopAligning() {
        alignToken += 1
        guard #available(macOS 14.2, *) else { return }
        (listener as? SpotifyAudio)?.stop()
        listener = nil
    }

    func scheduleAlignCheck(videoID: String, token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.alignEvery) { [weak self] in
            guard let self, self.alignToken == token else { return }
            self.checkAlignment(videoID: videoID, token: token)
        }
    }

    /// Spotify is read first: a seek during the stretch heard would otherwise go unseen until
    /// the next sync, and the stretch would be placed against the wrong song position.
    func checkAlignment(videoID: String, token: Int) {
        guard #available(macOS 14.2, *), let listener = listener as? SpotifyAudio,
              let bands = soundtrack?.bands, soundtrack?.videoID == videoID,
              let trackID = clipMode.trackID, clipMode.trackPosition != nil, shouldPlay, spotifyReadable,
              let heard = listener.recent(seconds: Self.alignHearing) else {
            return scheduleAlignCheck(videoID: videoID, token: token)
        }
        syncQueue.async { [weak self] in
            let reading = try? SpotifyPosition.read().get()
            DispatchQueue.main.async {
                guard let self, self.alignToken == token else { return }
                guard let reading, reading.trackID == trackID else {
                    return self.scheduleAlignCheck(videoID: videoID, token: token)
                }
                self.clipMode.positionRead(reading.position, trackID: reading.trackID, at: reading.at)
                guard let heardFrom = self.clipMode.songPosition(at: heard.startedAt), heardFrom >= 0 else {
                    return self.scheduleAlignCheck(videoID: videoID, token: token)
                }
                let offsets = self.clipMode.offsets
                self.alignQueue.async {
                    let match = Self.place(heard, from: heardFrom, in: bands, offsets: offsets)
                    DispatchQueue.main.async {
                        guard self.alignToken == token else { return }
                        self.alignmentChecked(match, heardFrom: heardFrom, trackID: trackID, videoID: videoID,
                                              bands: bands, token: token)
                        self.scheduleAlignCheck(videoID: videoID, token: token)
                    }
                }
            }
        }
    }

    /// Near the offset in force first; only a stretch that is not there is looked for across
    /// the whole soundtrack.
    @available(macOS 14.2, *)
    static func place(_ heard: SpotifyAudio.Recording, from heardFrom: TimeInterval,
                              in soundtrack: [[Float]], offsets: OffsetMap) -> AudioAlign.Match? {
        let segment = AudioAlign.onsets(heard.samples, sampleRate: heard.sampleRate)
        if !offsets.points.isEmpty,
           let near = AudioAlign.locate(segment, in: soundtrack, near: heardFrom + offsets.offset(at: heardFrom),
                                        within: alignRadius), near.isConfident {
            return near
        }
        return AudioAlign.locate(segment, in: soundtrack)
    }

    func alignmentChecked(_ match: AudioAlign.Match?, heardFrom: TimeInterval, trackID: String,
                                  videoID: String, bands: [[Float]], token: Int) {
        guard let match, match.isConfident else {
            return os_log("align: %{public}@ at %{public}.1f s unsure (peak %{public}.2f, margin %{public}.2f)",
                          videoID, heardFrom, match?.peak ?? 0, match?.margin ?? 0)
        }
        let measured = match.time - heardFrom
        let current = clipMode.offsets.offset(at: heardFrom)
        guard !clipMode.offsets.points.isEmpty, abs(measured - current) >= Self.alignConfirmBeyond else {
            unconfirmedOffset = nil
            return recordOffset(measured, at: heardFrom, trackID: trackID, videoID: videoID, peak: match.peak)
        }
        guard let unconfirmed = unconfirmedOffset, unconfirmed.trackID == trackID,
              abs(unconfirmed.offset - measured) < Self.alignConfirmBeyond / 2 else {
            unconfirmedOffset = (trackID, measured)
            return os_log("align: %{public}@ at %{public}.1f s seems %{public}+.2f s off, checking again",
                          videoID, heardFrom, measured - current)
        }
        unconfirmedOffset = nil
        locateCut(to: measured, from: current, near: heardFrom, in: bands, token: token) { [weak self] cut in
            self?.recordOffset(measured, at: cut ?? heardFrom, trackID: trackID, videoID: videoID, peak: match.peak)
        }
    }

    /// The change was measured seconds after the video made it; placing it at the cut itself
    /// is what lets the next play of the song jump at the right moment.
    func locateCut(to offset: TimeInterval, from previous: TimeInterval, near heardFrom: TimeInterval,
                           in bands: [[Float]], token: Int, completion: @escaping (TimeInterval?) -> Void) {
        guard #available(macOS 14.2, *), let listener = listener as? SpotifyAudio,
              let heard = listener.recent(seconds: Self.cutSearch) ?? listener.recent(seconds: Self.alignHearing),
              let from = clipMode.songPosition(at: heard.startedAt) else { return completion(nil) }
        alignQueue.async { [weak self] in
            let segment = AudioAlign.onsets(heard.samples, sampleRate: heard.sampleRate)
            let cut = AudioAlign.cut(segment, from: from, in: bands, before: previous, after: offset)
            DispatchQueue.main.async {
                guard let self, self.alignToken == token else { return }
                completion(cut.map { min($0, heardFrom + Self.alignHearing) })
            }
        }
    }

    func recordOffset(_ offset: TimeInterval, at position: TimeInterval, trackID: String,
                              videoID: String, peak: Float) {
        let before = clipMode.offsets
        guard clipMode.offsetMeasured(offset, at: position, trackID: trackID) else { return }
        os_log("align: %{public}@ from %{public}.1f s runs %{public}.2f s behind Spotify (%{public}+.2f, peak %{public}.2f)",
               videoID, position, offset, offset - before.offset(at: position), peak)
        guard clipMode.offsets != before, let store = clipStore else { return }
        let offsets = clipMode.offsets
        clipQueue.async { store.recordOffsets(offsets, for: trackID) }
        if clipMode.offsets.offset(at: clipMode.songPosition(at: Date()) ?? position) != before.offset(at: position) {
            scheduleSync(after: 0)
        }
    }

    /// The clip waits on its frame until the song gets there, so it starts in step instead of
    /// wherever a seek of unknowable length happened to land.
    func held(_ session: StreamSession, at position: TimeInterval) {
        guard spotifyReadable, let trackID = clipMode.trackID, clipMode.trackPosition != nil else {
            return release(session, at: position)
        }
        syncQueue.async { [weak self] in
            let reading = try? SpotifyPosition.read().get()
            DispatchQueue.main.async {
                guard let self, self.streamPlayback?.session === session else { return }
                if let reading, reading.trackID == trackID {
                    self.clipMode.positionRead(reading.position, trackID: reading.trackID, at: reading.at)
                }
                self.release(session, at: position)
            }
        }
    }

    func release(_ session: StreamSession, at position: TimeInterval) {
        guard let trackTime = clipMode.trackPosition else { return session.release(after: 0) }
        let wait = position - trackTime - Self.playLatency
        os_log("sync: held at %{public}.2f s, the song gets there in %{public}.2f s", position, wait)
        if wait < -Self.alignConfirmBeyond, !jumpedAgain {
            jumpedAgain = true
            return session.jump(to: trackTime + ClipMode.seekLead)
        }
        jumpedAgain = false
        session.release(after: min(max(wait, 0), Self.longestHold))
    }
}
