import Foundation
import os.log

/// Runs one curtain across every display and sequences the work that has to happen behind
/// it: a wallpaper swap queued with `whenCovered` runs once the old wallpaper has fully
/// left, and then `onCovered` asks the owner afresh whether anything still holds it down —
/// a reveal asked for before that moment may be stale by then.
final class CurtainDirector {
    var style: CurtainStyle
    var onCovered: (() -> Void)?

    var isDown: Bool { !curtain.isClear }

    private var curtain = Curtain()
    private var afterCover: [() -> Void] = []
    private var runningActions = false
    private var wakeToken = 0
    private var views: [CurtainView] = []

    init(style: CurtainStyle) {
        self.style = style
    }

    func attach(_ views: [CurtainView]) {
        self.views = views
        for view in views {
            view.source = { [weak self] in
                guard let self, let frame = self.curtain.frame(at: Date()) else { return nil }
                return (frame, self.curtain.style)
            }
        }
        refreshViews()
    }

    func cover() {
        guard CurtainView.isAvailable, curtain.cover(style: style, at: Date()) else { return }
        os_log("curtain: cover (%{public}@)", style.rawValue)
        refreshViews()
        if let coveredAt = curtain.coveredAt { wake(at: coveredAt) }
    }

    func whenCovered(_ action: @escaping () -> Void) {
        if curtain.isClear || curtain.isRevealing { cover() }
        guard curtain.coveredAt != nil, !curtain.isCovered(at: Date()) else { return action() }
        afterCover.append(action)
    }

    func reveal() {
        guard afterCover.isEmpty, !runningActions, curtain.reveal(at: Date()) else { return }
        os_log("curtain: reveal")
        if let end = curtain.revealEndsAt { wake(at: end) }
    }

    /// One pending wake at a time; a newer phase supersedes the older wake through the token.
    private func wake(at date: Date) {
        wakeToken += 1
        let token = wakeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow) + 0.01) { [weak self] in
            guard let self, self.wakeToken == token else { return }
            self.woke()
        }
    }

    private func woke() {
        let now = Date()
        if let coveredAt = curtain.coveredAt {
            guard now >= coveredAt else { return wake(at: coveredAt) }
            let actions = afterCover
            afterCover = []
            runningActions = true
            actions.forEach { $0() }
            runningActions = false
            onCovered?()
        } else if curtain.settle(at: now) {
            os_log("curtain: clear")
            refreshViews()
        } else if let end = curtain.revealEndsAt {
            wake(at: end)
        }
    }

    private func refreshViews() {
        let active = !curtain.isClear
        views.forEach { $0.isActive = active }
    }
}
