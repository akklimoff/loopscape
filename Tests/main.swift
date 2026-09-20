import Foundation

if let path = CommandLine.arguments.dropFirst().first {
    fixturesDirectory = URL(fileURLWithPath: path)
}
matchingTests()
storeTests()
ytDlpTests()
runAll()
