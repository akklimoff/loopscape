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

    test("checks that confirm a cut leave it where it was placed") {
        var map = OffsetMap()
        map.set(1.7, at: 6)
        map.set(9.7, at: 70)
        for position in stride(from: 73.0, through: 100, by: 3) { map.set(9.7, at: position) }
        for position in stride(from: 9.0, through: 60, by: 3) { map.set(1.7, at: position) }
        expectEqual(map.points, [OffsetMap.Point(at: 6, offset: 1.7), OffsetMap.Point(at: 70, offset: 9.7)])
    }

    test("a map round-trips through its stored form") {
        var map = OffsetMap()
        map.set(1.7, at: 20)
        map.set(4.2, at: 95)
        expectEqual(OffsetMap(stored: map.stored), map)
        expectEqual(OffsetMap(stored: 2.5).offset(at: 50), 2.5)
    }

    test("the next change is the first point past the position") {
        var map = OffsetMap()
        expectEqual(map.nextChange(after: 0), nil)
        map.set(1, at: 10)
        map.set(4, at: 60)
        expectEqual(map.nextChange(after: 5), 10)
        expectEqual(map.nextChange(after: 10), 60)
        expectEqual(map.nextChange(after: 61), nil)
    }
}
