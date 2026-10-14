import Foundation
import Testing
@testable import DFMCore

/// The window's lines and last line: names padded so the lines of every server line up; the summary counts what went
/// well and names what didn't.
@Test func multiRunLabelsAndSummary() {
    #expect(MultiRun.label("web1", width: 6) == "web1   │ " && MultiRun.label("db-main", width: 6) == "db-main │ ")
    #expect(MultiRun.summary([("a", .exit(0)), ("b", .exit(0)), ("db2", .exit(1)), ("c", .exit(0)), ("vault", .skipped), ("d", .notRun("refused"))])
            == "✓ 3  ✗ 2 (db2: exit 1, d: not run)  🔒 1 skipped (vault)")
    #expect(MultiRun.summary([("a", .stopped), ("b", .exit(0)), ("c", .stopped)]) == "✓ 1  ⎋ 2 stopped")
    #expect(MultiRun.summary([("a", .exit(255))]) == "✗ 1 (a: exit 255)")
    #expect(MultiRun.summary([]) == "")
}

/// What `MultiRun` said, line by line.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [(Int, String, Bool)] = []
    func add(_ i: Int, _ text: String, _ error: Bool) { lock.withLock { all.append((i, text, error)) } }
    func of(_ i: Int) -> [String] { lock.withLock { all.filter { $0.0 == i }.map { ($0.2 ? "! " : "") + $0.1 } } }
}

/// The most at once, from a file of "+" and "-" lines each run appends.
private func most(_ path: String) -> Int {
    var n = 0, top = 0
    for c in (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" where c == "+" || c == "-" {
        n += c == "+" ? 1 : -1
        top = max(top, n)
    }
    return top
}

extension SudoPasswordTests {

/// Each server's output (`.local()`: this Mac's sh) comes as whole lines with its index — a line written in two goes
/// is one line, stderr's marked — and each one's exit status, in order. A login that fails leaves that one not run,
/// with ssh's words as its last line; the others run.
@Test func aCommandRunsOnEachServer() {
    let heard = Heard()
    let servers = ["web1", "web2", "db"].enumerated().map { MultiRun.Server(name: $1, target: .local(persist: $0)) }   // three targets
    let ended = Heard()
    let outcomes = MultiRun.run(servers, "printf 'a'; sleep 0.2; printf 'b\\r\\n'; echo two; echo oops >&2; printf 'no end'; exit 3",
                                cancel: CancelFlag(), ended: { i, o in ended.add(i, "\(o)", false) }, line: heard.add)
    #expect(outcomes == [.exit(3), .exit(3), .exit(3)])
    #expect((0..<3).allSatisfy { ended.of($0) == ["exit(3)"] }, "each told once, as it ended")
    for i in 0..<3 { #expect(heard.of(i).sorted() == ["! oops", "ab", "no end", "two"], "\(heard.of(i))") }

    let refused = Heard()
    let some = MultiRun.run(servers, "echo hi", cancel: CancelFlag(), login: { t, _ in
        if t == servers[1].target { throw SFTPError(message: "me@web2: Permission denied (publickey).", connection: true) }
    }, line: refused.add)
    #expect(some == [.exit(0), .notRun("me@web2: Permission denied (publickey)."), .exit(0)])
    #expect(refused.of(1) == ["! me@web2: Permission denied (publickey)."] && refused.of(0) == ["hi"] && refused.of(2) == ["hi"])
}

/// Up to `limit` run at once, the rest waiting their turn; logins go one at a time, whatever the limit.
@Test func runsAreLimitedAndLoginsTakeTurns() throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-multi-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    let runs = d + "/runs", logins = d + "/logins"
    let servers = (1...6).map { MultiRun.Server(name: "s\($0)", target: .local()) }
    let outcomes = MultiRun.run(servers, "echo + >> \(runs); sleep 0.3; echo - >> \(runs)", limit: 3, cancel: CancelFlag(), login: { _, _ in
        let f = fopen(logins, "a"); fputs("+\n", f); fclose(f)
        usleep(50_000)
        let g = fopen(logins, "a"); fputs("-\n", g); fclose(g)
    }, line: { _, _, _ in })
    #expect(outcomes == Array(repeating: .exit(0), count: 6))
    #expect(most(runs) == 3, "three at a time")
    #expect(most(logins) == 1, "one login at a time")
}

/// Over a real ssh master (this Mac's sshd): ⎋ ends the run at once. In mux mode the master keeps the server's end of
/// the command's stderr until the command there ends, so it used to wait for the whole `sleep 5`.
@Test(.timeLimit(.minutes(1))) func cancellingDoesntWaitForTheServer() throws {
    try withTestSSHD { t, _, _ in
        let cancel = CancelFlag(), heard = Heard()
        Timeouts.queue.asyncAfter(deadline: .now() + 0.5) { cancel.cancel() }
        let started = Date()
        let outcomes = MultiRun.run([MultiRun.Server(name: "here", target: t)], "echo start; sleep 5; echo done", cancel: cancel, line: heard.add)
        #expect(Date().timeIntervalSince(started) < 2.5, "\(Date().timeIntervalSince(started)) s")
        #expect(outcomes == [.stopped] && heard.of(0) == ["start"])
        // A command that never stops writing to stderr doesn't hold the reader either.
        let busy = CancelFlag()
        Timeouts.queue.asyncAfter(deadline: .now() + 0.5) { busy.cancel() }
        let begun = Date()
        let noisy = MultiRun.run([MultiRun.Server(name: "here", target: t)], "while :; do echo x >&2; sleep 0.01; done", cancel: busy, line: { _, _, _ in })
        #expect(Date().timeIntervalSince(begun) < 2.5 && noisy == [.stopped], "\(Date().timeIntervalSince(begun)) s")
    }
}

/// ⎋ stops them all at once: none runs on to its end, and each says it was stopped.
@Test func cancellingStopsEveryServer() {
    let heard = Heard(), cancel = CancelFlag()
    Timeouts.queue.asyncAfter(deadline: .now() + 0.4) { cancel.cancel() }
    let started = Date()
    let ended = Heard()
    let outcomes = MultiRun.run((1...3).map { MultiRun.Server(name: "s\($0)", target: .local()) }, "echo start; sleep 5; echo done",
                                cancel: cancel, ended: { i, o in ended.add(i, "\(o)", false) }, line: heard.add)
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(outcomes == [.stopped, .stopped, .stopped] && (0..<3).allSatisfy { ended.of($0) == ["stopped"] })
    #expect((0..<3).allSatisfy { heard.of($0) == ["start"] })
}

}
