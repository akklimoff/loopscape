import Foundation

func soundtrackCacheTests() {
    test("a soundtrack's bands come back from the cache as they were saved") {
        let cache = SoundtrackCache(directory: try temporaryDirectory().appendingPathComponent("soundtracks"))
        expectEqual(cache.bands(of: "v"), nil)
        let bands: [[Float]] = [[0, 1, 2.5], [3, 4, 5], [6, 7, 8]]
        cache.save(bands, of: "v")
        expectEqual(cache.bands(of: "v"), bands)
        expectEqual(cache.bands(of: "w"), nil)
    }

    test("a cache file cut short is ignored") {
        let directory = try temporaryDirectory()
        let cache = SoundtrackCache(directory: directory)
        cache.save([[1, 2], [3, 4]], of: "v")
        let file = directory.appendingPathComponent("v")
        let data = try Data(contentsOf: file)
        try data.dropLast(3).write(to: file)
        expectEqual(cache.bands(of: "v"), nil)
    }
}
