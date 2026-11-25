import Foundation
import Testing

/// DFM_TEST_SLOW (3 on CI): the waits below last that many times longer — a loaded machine, not a slower Kermo.
let testSlowness = Double(ProcessInfo.processInfo.environment["DFM_TEST_SLOW"] ?? "") ?? 1

/// Checks `done` every 10 ms, on the caller's actor, until it holds or `seconds` (× DFM_TEST_SLOW) pass: whether it held.
@discardableResult
func until(_ seconds: Double = 60, isolation: isolated (any Actor)? = #isolation, _ done: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + .seconds(seconds * testSlowness)
    while !done() {
        guard ContinuousClock.now < end, !Task.isCancelled else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// The same; a test issue "timed out: `what`" if it never held.
func until(_ what: String, seconds: Double = 60, isolation: isolated (any Actor)? = #isolation, _ done: () -> Bool,
           sourceLocation: SourceLocation = #_sourceLocation) async {
    if await !until(seconds, done) { Issue.record("timed out: \(what)", sourceLocation: sourceLocation) }
}
