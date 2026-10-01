import AppKit

/// Spotify's notifications carry a position only when playback changes, so lining a clip up
/// mid-song asks Spotify directly. Raw Apple Events rather than NSAppleScript: they can be
/// sent off the main thread with a timeout, and addressed to a running process they can
/// never launch Spotify. Addressed by bundle ID instead, Spotify never replied (-1712).
enum SpotifyPosition {
    struct Reading {
        let trackID: String
        let position: TimeInterval
        let at: Date
    }

    enum Failure: Error {
        case notRunning
        case denied
        case failed(Int)
    }

    private static let bundleID = "com.spotify.client"

    static func read() -> Result<Reading, Failure> {
        guard let spotify = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return .failure(.notRunning)
        }
        let target = NSAppleEventDescriptor(processIdentifier: spotify.processIdentifier)
        do {
            let app = NSAppleEventDescriptor.null()
            let trackID = try get(property("ID  ", of: property("pTrk", of: app)), from: target)?.stringValue
            let before = Date()
            let position = try get(property("pPos", of: app), from: target)?.doubleValue
            let after = Date()
            guard let trackID, let position else { return .failure(.failed(0)) }
            return .success(Reading(trackID: trackID, position: position,
                                    at: before.addingTimeInterval(after.timeIntervalSince(before) / 2)))
        } catch let error as NSError {
            switch error.code {
            case -1743: return .failure(.denied)
            case -600: return .failure(.notRunning)
            default: return .failure(.failed(error.code))
            }
        }
    }

    private static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    private static func property(_ name: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record()
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code(name)), forKeyword: code("seld"))
        specifier.setDescriptor(container, forKeyword: code("from"))
        return specifier.coerce(toDescriptorType: code("obj ")) ?? specifier
    }

    private static func get(_ specifier: NSAppleEventDescriptor,
                            from target: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code("core"), eventID: code("getd"),
            targetDescriptor: target,
            returnID: -1, transactionID: 0)
        event.setParam(specifier, forKeyword: code("----"))
        let reply = try event.sendEvent(options: [.waitForReply], timeout: 1)
        return reply.paramDescriptor(forKeyword: code("----"))
    }
}
