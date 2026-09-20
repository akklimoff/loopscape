import Foundation

var fixturesDirectory = URL(fileURLWithPath: "Tests/Fixtures")

private var registered: [(name: String, body: () throws -> Void)] = []
private var failures: [String] = []
private var running = ""
private var temporaries: [URL] = []

func test(_ name: String, _ body: @escaping () throws -> Void) {
    registered.append((name, body))
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expectation failed",
            line: UInt = #line) {
    if !condition { failures.append("\(running): \(message()) (line \(line))") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, line: UInt = #line) {
    expect(actual == expected, "got \(actual), expected \(expected)", line: line)
}

func runAll() -> Never {
    for (name, body) in registered {
        running = name
        do { try body() } catch { failures.append("\(name): threw \(error)") }
    }
    temporaries.forEach { try? FileManager.default.removeItem(at: $0) }
    failures.forEach { print("FAIL \($0)") }
    print("\(registered.count) tests, \(failures.count) failures")
    exit(failures.isEmpty ? 0 : 1)
}

struct Fixture: Decodable {
    let artist: String
    let name: String
    let seconds: Int
    let candidates: [Candidate]

    var track: TrackQuery { TrackQuery(id: "spotify:track:\(name)", artist: artist, name: name, seconds: seconds) }
}

func loadFixture(_ slug: String) throws -> Fixture {
    let data = try Data(contentsOf: fixturesDirectory.appendingPathComponent("\(slug).json"))
    return try JSONDecoder().decode(Fixture.self, from: data)
}

func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("loopscape-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    temporaries.append(directory)
    return directory
}
