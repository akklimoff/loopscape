import Foundation
import os.log

/// Runs one curtain across every display and sequences the work that has to happen behind
/// it: a wallpaper swap queued with `whenCovered` runs once the pack has fully left, and a
/// reveal asked for earlier waits for those swaps.
final class CurtainDirector {
    var style: CurtainStyle

    private var curtain = Curtain()
    private var afterCover: [() -> Void] = []
    private var revealWanted = false
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
        revealWanted = false
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
        guard curtain.coveredAt != nil else { return }
        guard curtain.isCovered(at: Date()), afterCover.isEmpty else {
            revealWanted = true
            return
        }
        startReveal()
    }

    private func startReveal() {
        revealWanted = false
        guard curtain.reveal(at: Date()) else { return }
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
            actions.forEach { $0() }
            if revealWanted, curtain.coveredAt != nil { startReveal() }
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
