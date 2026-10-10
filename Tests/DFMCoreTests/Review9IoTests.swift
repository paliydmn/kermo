import Foundation
import Testing
@testable import DFMCore

/// P9: twice as many calls as cores stuck in the kernel (a dead mount, a hung server): another `Blocking.run` still
/// gets a thread, and errors come back to the caller. At most 48: GCD stops at 64 threads.
@MainActor @Test func blockingRunsBesideHungCalls() async throws {
    let n = min(2 * ProcessInfo.processInfo.activeProcessorCount, 48)
    let stuck = DispatchSemaphore(value: 0)
    defer { for _ in 0..<n { stuck.signal() } }   // also when an expectation below fails
    let hung = (0..<n).map { _ in Task { await Blocking.run { stuck.wait(timeout: .now() + 10) == .success } } }

    let got = Box()
    Task { got.set(await Blocking.run(.userInitiated) { 42 }) }
    let start = Date()
    while got.value == nil, Date().timeIntervalSince(start) < 3 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(got.value == 42)

    struct Boom: Error {}
    await #expect(throws: Boom.self) { try await Blocking.run { () throws -> Int in throw Boom() } }
    for _ in 0..<n { stuck.signal() }
    for h in hung { #expect(await h.value) }
}

/// P9: a listing on a dead mount hangs for good. Asked again and again (reloads, tab switches, both panels) it holds
/// one thread, not one per call: they wait for one more run after it, which all of them share. Another key runs at once.
@MainActor @Test func coalescedRunsOnePerKey() async throws {
    let runs = Coalesced<Int>(), entered = Box(), stuck = DispatchSemaphore(value: 0)
    defer { stuck.signal() }
    let count = { @Sendable () -> Int in entered.add(); return entered.value! }
    let first = Task { await runs.run("/dead") { _ = count(); return stuck.wait(timeout: .now() + 10) == .success ? 1 : -1 } }
    for _ in 0..<300 where entered.value == nil { try await Task.sleep(for: .milliseconds(10)) }
    let later = (0..<100).map { _ in Task { await runs.run("/dead") { count() } } }
    #expect(await runs.run("/other") { 7 } == 7, "another folder doesn't wait")
    try await Task.sleep(for: .milliseconds(100))
    #expect(entered.value == 1, "100 more calls while one hangs: still one thread")

    stuck.signal()
    #expect(await first.value == 1)
    for t in later { #expect(await t.value == 2, "one more run, shared by all who asked meanwhile") }
    #expect(entered.value == 2)
    #expect(await runs.run("/dead") { count() } == 3, "after that, a call runs again")
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int?
    var value: Int? { lock.withLock { v } }
    func set(_ x: Int) { lock.withLock { v = x } }
    func add() { lock.withLock { v = (v ?? 0) + 1 } }
}
