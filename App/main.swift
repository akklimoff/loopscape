import AppKit

// launchd's RunAtLoad and a manual launch can race; a second instance would stack
// another set of desktop windows and double the decode cost.
let mine = ProcessInfo.processInfo.processIdentifier
let bundleID = Bundle.main.bundleIdentifier ?? "com.aklimoff.loopscape"
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .contains(where: { $0.processIdentifier != mine }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
