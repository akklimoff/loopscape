import AVFoundation

enum StreamFailure: CustomStringConvertible {
    case itemFailed(String)
    case stalled(TimeInterval)

    var description: String {
        switch self {
        case .itemFailed(let reason): return "item failed: \(reason)"
        case .stalled(let seconds): return "stalled for \(Int(seconds)) s"
        }
    }
}

/// Two items of the same URL stay queued, so the next loop is buffered before the current
/// one ends and the seam is as short as the player can make it. That is what AVPlayerLooper
/// does for files, but its replicas drop attached outputs (so no still could be grabbed) and
/// its HLS behaviour is undocumented; keeping the queue by hand costs a dozen lines.
final class StreamSession {
    private let url: URL
    private let player: AVQueuePlayer
    private let onFailure: (StreamFailure) -> Void
    private var owned: [AVPlayerItem] = []
    private var itemObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var playerObservation: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []
    private var pendingSeek: (item: AVPlayerItem, position: TimeInterval)?
    private var stallToken: Int?
    private var stallCounter = 0
    private var finished = false
    private var wantsPlay = true
    private(set) var isPositioned = false

    init(url: URL, player: AVQueuePlayer, onFailure: @escaping (StreamFailure) -> Void) {
        self.url = url
        self.player = player
        self.onFailure = onFailure
    }

    deinit { stop() }

    func start(at position: TimeInterval) {
        let first = makeItem()
        player.insert(first, after: nil)
        player.insert(makeItem(), after: first)

        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil,
                                         queue: .main) { [weak self] note in
            self?.itemEnded(note.object as? AVPlayerItem)
        })
        tokens.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil,
                                         queue: .main) { [weak self] note in
            guard let self, self.owns(note.object) else { return }
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self.fail(.itemFailed(error?.localizedDescription ?? "did not reach the end"))
        })
        tokens.append(center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: nil,
                                         queue: .main) { [weak self] note in
            guard let self, self.owns(note.object) else { return }
            self.stalled()
        })
        playerObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.clearStall()
                case .paused:
                    // An unasked-for pause (an empty queue, a system interruption) is a stall;
                    // pause() clears the stall itself before calling player.pause().
                    if self.wantsPlay { self.stalled() } else { self.clearStall() }
                case .waitingToPlayAtSpecifiedRate:
                    self.stalled()
                default:
                    break
                }
            }
        }

        // Until the first frame plays the stream is "stalled" from the user's point of view,
        // so the same timeout covers a URL that never starts and one that dies mid-way.
        stalled()
        if position > 0 {
            pendingSeek = (first, position)
        } else {
            isPositioned = true
            player.play()
        }
    }

    func stop() {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens = []
        playerObservation = nil
        itemObservations = [:]
        owned = []
        pendingSeek = nil
        finished = true
    }

    func pause() {
        wantsPlay = false
        clearStall()
        player.pause()
    }

    func resume() {
        guard !finished, !wantsPlay else { return }
        wantsPlay = true
        stalled()
        // While the first item is still loading, the pending seek will call play() itself;
        // playing here first would start the stream at 0 before the seek lands.
        if pendingSeek == nil { player.play() }
    }

    /// An item that is not ready yet must not be sought (AVPlayerItem raises), so the
    /// position waits for itemReady like the start position does.
    func seek(to position: TimeInterval) {
        guard !finished, let item = player.currentItem else { return }
        guard item.status == .readyToPlay, pendingSeek == nil else {
            pendingSeek = (item, position)
            return
        }
        item.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                  toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
    }

    private func makeItem() -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        owned.append(item)
        itemObservations[ObjectIdentifier(item)] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .failed:
                    self.fail(.itemFailed(item.error?.localizedDescription ?? "unknown error"))
                case .readyToPlay:
                    self.itemReady(item)
                default:
                    break
                }
            }
        }
        return item
    }

    private func itemReady(_ item: AVPlayerItem) {
        guard let pending = pendingSeek, pending.item === item else { return }
        pendingSeek = nil
        item.seek(to: CMTime(seconds: pending.position, preferredTimescale: 600),
                  toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPositioned = true
                guard self.wantsPlay else { return }
                self.player.play()
            }
        }
    }

    private func owns(_ object: Any?) -> Bool {
        guard let item = object as? AVPlayerItem else { return false }
        return owned.contains { $0 === item }
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard !finished, let item, owns(item) else { return }
        owned.removeAll { $0 === item }
        itemObservations[ObjectIdentifier(item)] = nil
        while owned.count < 2 {
            player.insert(makeItem(), after: player.items().last)
        }
    }

    private func stalled() {
        guard !finished, stallToken == nil else { return }
        stallCounter += 1
        let token = stallCounter
        stallToken = token
        let started = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + ScreenWallpaper.stallTimeout) { [weak self] in
            guard let self, !self.finished, self.stallToken == token else { return }
            self.fail(.stalled(Date().timeIntervalSince(started)))
        }
    }

    private func clearStall() {
        stallToken = nil
    }

    private func fail(_ failure: StreamFailure) {
        guard !finished else { return }
        stop()
        onFailure(failure)
    }
}
