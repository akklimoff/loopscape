import AppKit

final class NowPlaying {
    private static let spotifyBundleID = "com.spotify.client"
    private static let stateChanged = Notification.Name("com.spotify.client.PlaybackStateChanged")

    private(set) var track: Track?
    var onChange: ((Track?) -> Void)?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(
            forName: Self.stateChanged, object: nil, queue: .main
        ) { [weak self] note in
            self?.update(Track(spotifyInfo: note.userInfo ?? [:]))
        }))

        // A crash or a force quit posts no Stopped event, so Spotify's termination clears the line.
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.spotifyBundleID else { return }
            self?.update(nil)
        }))
    }

    deinit {
        observers.forEach { $0.center.removeObserver($0.token) }
    }

    private func update(_ new: Track?) {
        guard new != track else { return }
        track = new
        onChange?(new)
    }
}
