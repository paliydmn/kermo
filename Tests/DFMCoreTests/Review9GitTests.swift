import Foundation
import Testing
@testable import DFMCore

// Task 9 QA follow-up, git group (tasks/task9_qa_followup/README.md §6.4).

/// L13: git counts as installed only if the folder `xcode-select -p` names has it; otherwise /usr/bin/git is the
/// shim that asks to install developer tools.
@Test func gitNeedsDeveloperToolsWithGitInside() throws {
    let dir = NSTemporaryDirectory() + "dfm-clt-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir + "/usr/bin", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    #expect(!GitStatus.gitInstalled(developerDir: nil))   // xcode-select -p failed: no tools at all
    #expect(!GitStatus.gitInstalled(developerDir: dir))   // a stale path left behind
    FileManager.default.createFile(atPath: dir + "/usr/bin/git", contents: Data("#!/bin/sh\n".utf8),
                                   attributes: [.posixPermissions: 0o755])
    #expect(GitStatus.gitInstalled(developerDir: dir))
}

@MainActor private func waitUntil(_ done: () -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(5)
    while !done() {
        try #require(ContinuousClock.now < end)
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// L14: reloads while `git status` runs don't start more of them: one runs, then exactly one more, at least
/// `interval` after the first ended.
@MainActor @Test func gitStatusRunsOneAtATime() async throws {
    var inFlight = 0, maxInFlight = 0
    var starts: [ContinuousClock.Instant] = []
    var gate: CheckedContinuation<Void, Never>?
    let flight = SingleFlight(interval: .milliseconds(100)) {
        starts.append(.now)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        await withCheckedContinuation { gate = $0 }
        inFlight -= 1
    }
    for _ in 0..<10 { flight.request(key: "/repo") }
    try await waitUntil { gate != nil }
    for _ in 0..<10 { flight.request(key: "/repo") }
    let firstEnded = ContinuousClock.now
    gate?.resume()
    gate = nil
    try await waitUntil { gate != nil }
    #expect(starts.count == 2)
    #expect(starts[1] - firstEnded >= .milliseconds(100))
    gate?.resume()
    try await Task.sleep(for: .milliseconds(300))
    #expect(starts.count == 2)
    #expect(maxInFlight == 1)
}

/// L14: going into another folder doesn't wait out the interval of the previous one.
@MainActor @Test func gitStatusForANewFolderStartsRightAway() async throws {
    var runs = 0
    let flight = SingleFlight(interval: .seconds(60)) { runs += 1 }
    flight.request(key: "/repo")
    try await waitUntil { runs == 1 }
    flight.request(key: "/repo/sub")
    try await waitUntil { runs == 2 }
}

/// L14: a run that never ends (git stuck on a stale mount) doesn't hold up the next folder's status.
@MainActor @Test func gitStatusForANewFolderDoesNotWaitForAStuckRun() async throws {
    var started: [Int] = []
    var stuck: CheckedContinuation<Void, Never>?
    var n = 0
    let flight = SingleFlight(interval: .milliseconds(10)) {
        n += 1
        started.append(n)
        if n == 1 { await withCheckedContinuation { stuck = $0 } }
    }
    flight.request(key: "/stale")
    try await waitUntil { stuck != nil }
    flight.request(key: "/repo")
    try await waitUntil { started.count == 2 }
    stuck?.resume()
    try await Task.sleep(for: .milliseconds(100))
    #expect(started == [1, 2])   // the stuck run ending late doesn't start the new folder's run again
}

/// A repo whose .gitignore is a FIFO: `git status` opens it and blocks until someone writes.
func fifoRepo() throws -> String {
    let dir = NSTemporaryDirectory() + "dfm-fifo-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let p = try Process.run(URL(fileURLWithPath: "/usr/bin/git"), arguments: ["init", "-q", dir])
    p.waitUntilExit()
    #expect(mkfifo(dir + "/.gitignore", 0o644) == 0)
    return dir
}

/// Lets a git still blocked on the FIFO go on (it sees an empty .gitignore), then removes the repo.
func removeFifoRepo(_ dir: String) {
    let fd = open(dir + "/.gitignore", O_WRONLY | O_NONBLOCK)   // fails with ENXIO if no git has it open
    if fd >= 0 { close(fd) }
    try? FileManager.default.removeItem(atPath: dir)
}

/// L14: a git that hangs is killed after the timeout instead of blocking the panel's status for good.
@Test(.enabled(if: GitStatus.available)) func stuckGitIsKilled() throws {
    let dir = try fifoRepo()
    defer { removeFifoRepo(dir) }
    let start = ContinuousClock.now
    #expect(GitStatus.git(["status", "--porcelain"], in: dir, timeout: 0.5) == nil)
    #expect(ContinuousClock.now - start < .seconds(5))
}
