import Foundation

if let path = CommandLine.arguments.dropFirst().first {
    fixturesDirectory = URL(fileURLWithPath: path)
}
matchingTests()
storeTests()
ytDlpTests()
resolverTests()
launchOptionsTests()
trackTests()
onDemandYtDlpTests()
clipModeTests()
streamCacheTests()
runAll()
