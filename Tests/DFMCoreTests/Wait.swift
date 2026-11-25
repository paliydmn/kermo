import Foundation

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

/// The same for a test that isn't async: it blocks the thread — one of Swift's pool, as many as cores. With them all
/// blocked (a 3-core CI runner) DispatchQueue.global() got no thread for good: what such a test waits for goes on
/// `Timeouts.queue` (a quick cancel) or a `Thread` of its own.
func waitUntil(_ seconds: Double = 60, _ done: () -> Bool) -> Bool {
    let end = ContinuousClock.now + .seconds(seconds * testSlowness)
    while !done() {
        guard ContinuousClock.now < end, !Task.isCancelled else { return false }
        usleep(10_000)
    }
    return true
}
