import Foundation

func offsetMapTests() {
    test("an empty map has no offset anywhere") {
        expectEqual(OffsetMap().offset(at: 100), 0)
    }

    test("each offset holds from where it was measured until the next one") {
        var map = OffsetMap()
        map.set(1.7, at: 20)
        map.set(4.2, at: 95)
        expectEqual(map.offset(at: 0), 1.7)
        expectEqual(map.offset(at: 94), 1.7)
        expectEqual(map.offset(at: 95), 4.2)
        expectEqual(map.offset(at: 200), 4.2)
    }

    test("a nearby measurement replaces the old one instead of piling up") {
        var map = OffsetMap()
        map.set(1.7, at: 20)
        map.set(1.75, at: 23)
        expectEqual(map.points.count, 1)
        expectEqual(map.offset(at: 0), 1.75)
    }

    test("a measurement that agrees with the offset already in force adds nothing") {
        var map = OffsetMap()
        map.set(1.7, at: 20)
        map.set(1.72, at: 60)
        expectEqual(map.points.count, 1)
    }

    test("a map round-trips through its stored form") {
        var map = OffsetMap()
        map.set(1.7, at: 20)
        map.set(4.2, at: 95)
        expectEqual(OffsetMap(stored: map.stored), map)
        expectEqual(OffsetMap(stored: 2.5).offset(at: 50), 2.5)
    }
}
