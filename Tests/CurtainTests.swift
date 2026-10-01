import Foundation

func curtainTests() {
    let start = Date(timeIntervalSince1970: 1_900_000_000)
    let silk = CurtainStyle.silk

    test("a clear curtain has nothing to draw") {
        expect(Curtain().frame(at: start) == nil)
    }

    test("a cover runs for the style's duration before the curtain counts as covered") {
        var curtain = Curtain()
        expect(curtain.cover(style: silk, at: start))
        expect(!curtain.isCovered(at: start.addingTimeInterval(silk.coverDuration - 0.01)))
        expect(curtain.isCovered(at: start.addingTimeInterval(silk.coverDuration)))
        expectEqual(curtain.coveredAt, start.addingTimeInterval(silk.coverDuration))
    }

    test("a second cover while covering keeps the first one's clock") {
        var curtain = Curtain()
        _ = curtain.cover(style: silk, at: start)
        expect(!curtain.cover(style: .wind, at: start.addingTimeInterval(0.5)))
        expectEqual(curtain.frame(at: start.addingTimeInterval(1))?.elapsed, 1)
        expectEqual(curtain.style, silk)
    }

    test("a reveal waits for the cover to finish") {
        var curtain = Curtain()
        _ = curtain.cover(style: silk, at: start)
        expect(!curtain.reveal(at: start.addingTimeInterval(0.2)))
        expect(curtain.reveal(at: start.addingTimeInterval(silk.coverDuration)))
    }

    test("the waiting animation keeps its clock through the reveal") {
        var curtain = Curtain()
        _ = curtain.cover(style: silk, at: start)
        _ = curtain.reveal(at: start.addingTimeInterval(5))
        let frame = curtain.frame(at: start.addingTimeInterval(5.5))
        expectEqual(frame, CurtainFrame(elapsed: 5.5, revealElapsed: 0.5))
    }

    test("a finished reveal clears the curtain, an unfinished one does not") {
        var curtain = Curtain()
        _ = curtain.cover(style: silk, at: start)
        _ = curtain.reveal(at: start.addingTimeInterval(5))
        expect(!curtain.settle(at: start.addingTimeInterval(5 + silk.revealDuration - 0.01)))
        expect(curtain.settle(at: start.addingTimeInterval(5 + silk.revealDuration)))
        expect(curtain.frame(at: start.addingTimeInterval(9)) == nil)
    }

    test("a cover during a reveal starts over with the new style") {
        var curtain = Curtain()
        _ = curtain.cover(style: silk, at: start)
        _ = curtain.reveal(at: start.addingTimeInterval(5))
        expect(curtain.cover(style: .loom, at: start.addingTimeInterval(5.5)))
        expectEqual(curtain.style, .loom)
        expectEqual(curtain.frame(at: start.addingTimeInterval(6)), CurtainFrame(elapsed: 0.5, revealElapsed: nil))
    }

    test("no style draws no curtain") {
        var curtain = Curtain()
        expect(!curtain.cover(style: .none, at: start))
        expect(curtain.frame(at: start) == nil)
    }

    test("every drawn style finishes its moves in under two seconds") {
        for style in CurtainStyle.allCases where style != .none {
            expect(style.coverDuration > 0 && style.coverDuration < 2, "\(style) cover")
            expect(style.revealDuration > 0 && style.revealDuration < 2, "\(style) reveal")
        }
    }
}
