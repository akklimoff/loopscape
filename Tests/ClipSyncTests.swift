import Foundation

func clipSyncTests() {
    test("a clip within the tolerance is left alone") {
        var sync = ClipSync()
        expectEqual(sync.decide(clipTime: 60.1, trackTime: 60), .keep)
    }

    test("a clip behind the track speeds up, harder the further behind it is") {
        var near = ClipSync()
        var far = ClipSync()
        guard case .rate(let nearRate) = near.decide(clipTime: 59.7, trackTime: 60),
              case .rate(let farRate) = far.decide(clipTime: 59, trackTime: 60) else {
            return expect(false, "expected rate nudges")
        }
        expect(nearRate > 1 && farRate > nearRate, "\(nearRate), \(farRate)")
        expect(farRate <= 1 + ClipSync.maxNudge)
    }

    test("a clip ahead of the track slows down") {
        var sync = ClipSync()
        guard case .rate(let rate) = sync.decide(clipTime: 60.5, trackTime: 60) else {
            return expect(false, "expected a rate nudge")
        }
        expect(rate < 1 && rate >= 1 - ClipSync.maxNudge, "\(rate)")
    }

    test("a nudge holds until the clip is close, then returns to normal speed once") {
        var sync = ClipSync()
        _ = sync.decide(clipTime: 59.5, trackTime: 60)
        if case .keep = sync.decide(clipTime: 59.9, trackTime: 60) { expect(false, "still nudging at 0.1 s") }
        expectEqual(sync.decide(clipTime: 59.98, trackTime: 60), .rate(1))
        expectEqual(sync.decide(clipTime: 59.98, trackTime: 60), .keep)
    }

    test("a gap too wide to catch up on is sought, ahead by the start lead") {
        var sync = ClipSync()
        expectEqual(sync.decide(clipTime: 50, trackTime: 60), .seek(60 + ClipMode.seekLead))
    }

    test("a gap over a second is jumped rather than nudged for long") {
        var sync = ClipSync()
        expectEqual(sync.decide(clipTime: 58.7, trackTime: 60), .seek(60 + ClipMode.seekLead))
    }

    test("past the end of a shorter clip there is nothing to line up") {
        var sync = ClipSync()
        expectEqual(sync.decide(clipTime: 10, trackTime: 200, clipDuration: 180), .keep)
    }
}
