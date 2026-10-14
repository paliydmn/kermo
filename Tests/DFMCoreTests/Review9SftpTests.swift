import Foundation
import Testing
@testable import DFMCore

// Task 9 QA follow-up, servers (R13, R15, R19): fake "sftp servers" — small shell scripts on pipes, no ssh — that
// misbehave, and a client that must neither hang nor leave the server process behind.

private nonisolated(unsafe) let fm = FileManager.default

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9sftp-" + UUID().uuidString
    try! fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// A server script in `dir`; its path (unique) is how `pgrep` finds it. `while read` keeps it a shell waiting on
/// stdin (builtins only), as a server waits for the next request.
private func fakeServer(_ dir: String, _ body: String) -> String {
    let path = dir + "/fake-sftp-server"
    try! ("#!/bin/sh\n" + body + "\nwhile read x; do :; done\n").write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    return path
}

private let version = #"printf '\000\000\000\005\002\000\000\000\003'"#   // VERSION 3, no extensions
private let readInit = "head -c 9 >/dev/null"                           // the client's INIT, before answering it

/// Whether a process started from `path` is still there, after giving a SIGTERM a moment to land.
private func running(_ path: String) -> Bool {
    for _ in 0..<40 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", path]
        p.standardOutput = FileHandle.nullDevice
        try! p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { return false }
        usleep(50_000)
    }
    return true
}

private func kill(_ path: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = ["-f", path]
    try? p.run()
    p.waitUntilExit()
}

private final class Box<T>: @unchecked Sendable { var value: T?; init() {} }

/// `body` on its own thread; nil if it hasn't returned after `seconds` (a hang fails the test, not the suite).
private func within<T>(_ seconds: Double, _ body: @escaping @Sendable () -> T) -> T? {
    let box = Box<T>(), done = DispatchSemaphore(value: 0)
    Thread { box.value = body(); done.signal() }.start()
    return done.wait(timeout: .now() + seconds) == .success ? box.value : nil
}

private func connect(_ server: String, cancel: CancelFlag? = nil) -> Result<SFTPClient, Error>? {
    within(5) { Result { try SFTPClient(.local(server: server), cancel: cancel) } }
}

/// R15: a login script's banner where the server's greeting should be fails the connection with a protocol error,
/// and the server goes (it would wait for us forever).
@Test func bannerInsteadOfSFTPFailsAndEndsTheServer() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let server = fakeServer(d, "echo 'Welcome to prod-1! Last login: yesterday'")
    defer { kill(server) }
    let r = try #require(connect(server), "the handshake hung")
    guard case .failure(let e) = r else { Issue.record("connected to a banner"); return }
    #expect(e.localizedDescription.contains("protocol error"), "\(e)")
    #expect(!running(server))
}

/// R15: a reply over 1 MiB fails the call waiting for it (and any other) at once and ends the server; the
/// client says it's not connected.
@Test func oversizedReplyFailsTheWaitingCallAndEndsTheServer() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let server = fakeServer(d, "\(readInit); \(version); head -c 4 >/dev/null; printf '\\000\\020\\000\\001'")
    defer { kill(server) }
    let c = try #require(connect(server), "the handshake hung").get()
    defer { c.close() }
    let r = try #require(within(5) { Result { try c.lstat("/") } }, "the call hung")
    #expect(throws: SFTPError.self) { try r.get() }
    #expect(!c.isConnected)
    #expect(!running(server))
}

/// R19: a handshake that fails (an answer that isn't VERSION) doesn't leave the server running.
@Test func failedHandshakeEndsTheServer() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let server = fakeServer(d, #"\#(readInit); printf '\000\000\000\005\145\000\000\000\000'"#)   // a STATUS
    defer { kill(server) }
    let r = try #require(connect(server), "the handshake hung")
    #expect(throws: SFTPError.self) { try r.get() }
    #expect(!running(server))
}

/// R13: cancel stops a call the server never answers — while connecting and after — and ends the server.
@Test(arguments: [false, true]) func cancelStopsAServerThatNeverAnswers(_ connected: Bool) throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let server = fakeServer(d, connected ? "\(readInit); \(version)" : "")
    defer { kill(server) }
    let flag = CancelFlag()
    Timeouts.queue.asyncAfter(deadline: .now() + 0.3) { flag.cancel() }
    let r = try #require(within(5) { Result { try SFTPClient.session(.local(server: server), cancel: flag) { try $0.lstat("/") } } },
                         "cancel didn't stop it")
    #expect(throws: (any Error).self) { try r.get() }
    #expect(!running(server))
}

/// R13: F5 to a server that never answers: Cancel stops the job while it is still connecting, or once connected
/// (a server gone silent is cut off, not waited for).
@Test(arguments: [false, true]) func cancelStopsAJobConnectingToADeadServer(_ connected: Bool) throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let server = fakeServer(d, connected ? "\(readInit); \(version)" : "")
    defer { kill(server) }
    try Data("x".utf8).write(to: URL(fileURLWithPath: d + "/file"))
    let job = FileJob(.copy, sources: [d + "/file"], from: .local, to: .sftp(.local(server: server)), destDir: d + "/up")
    Timeouts.queue.asyncAfter(deadline: .now() + 0.3) { job.cancel() }
    #expect(within(10) { job.run() } != nil, "cancel didn't stop the job")   // cut after 5 s of silence
    #expect(!running(server))
}

/// R13: a cancelled upload removes its partial file over the connection it has, instead of logging in again.
@Test func cancelledUploadCleansUpWithoutReconnecting() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let log = d + "/connections"
    let server = d + "/counting-sftp-server"
    try "#!/bin/sh\necho x >> '\(log)'\nexec /usr/libexec/sftp-server \"$@\"\n".write(toFile: server, atomically: true, encoding: .utf8)
    chmod(server, 0o755)
    try fm.createDirectory(atPath: d + "/up", withIntermediateDirectories: false)
    let big = FileHandle(forWritingAtPath: { fm.createFile(atPath: d + "/big", contents: nil); return d + "/big" }())!
    try big.truncate(atOffset: 1 << 30)   // sparse: quick to make, long enough to copy
    try big.close()
    let job = FileJob(.copy, sources: [d + "/big"], from: .local, to: .sftp(.local(server: server)), destDir: d + "/up")
    Thread {
        while ![.done, .cancelled, .failed].contains(job.progress.state) {
            if ((try? fm.contentsOfDirectory(atPath: d + "/up")) ?? []).contains(where: { $0.hasPrefix(".dfm-partial-") }) { return job.cancel() }
            usleep(2_000)
        }
    }.start()
    #expect(within(20) { job.run() } != nil)
    #expect(job.isCancelled, "finished before it could be cancelled")
    #expect(try fm.contentsOfDirectory(atPath: d + "/up") == [])
    #expect(try String(contentsOfFile: log, encoding: .utf8) == "x\n", "connected again after cancel")
}

/// R13: a cancelled upload over a slow link still removes its partial file: the server takes a few seconds to work
/// through the writes already sent, and is waited for while it answers (it isn't cut off a second after cancel).
@Test func cancelledUploadOverASlowLinkCleansUp() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d); kill(d) }
    let log = d + "/connections"
    let server = slowServer(d, log: log)
    try fm.createDirectory(atPath: d + "/up", withIntermediateDirectories: false)
    let big = sparse(d + "/big", 1 << 30)
    let job = FileJob(.copy, sources: [big], from: .local, to: .sftp(.local(server: server)), destDir: d + "/up")
    cancelOnPartial(in: d + "/up", while: { ![.done, .cancelled, .failed].contains(job.progress.state) }) { job.cancel() }
    #expect(within(40) { job.run() } != nil)
    #expect(job.isCancelled, "finished before it could be cancelled")
    #expect(try fm.contentsOfDirectory(atPath: d + "/up") == [], "the partial file stayed")
    #expect(try String(contentsOfFile: log, encoding: .utf8) == "x\n", "connected again after cancel")
}

/// R13: the editor's save to a server can be cancelled, and a cancelled save over a slow link leaves no partial.
@Test func cancelledSaveToAServerCleansUp() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d); kill(d) }
    let server = slowServer(d, log: d + "/connections")
    try fm.createDirectory(atPath: d + "/up", withIntermediateDirectories: false)
    let big = sparse(d + "/big", 64 << 20)
    let flag = CancelFlag()
    let done = Box<Bool>()
    cancelOnPartial(in: d + "/up", while: { done.value == nil }) { flag.cancel() }
    let r = try #require(within(40) { () -> Result<SFTPClient.Attrs, Error> in
        defer { done.value = true }
        return Result {
            let c = try SFTPClient(.local(server: server), cancel: flag)
            defer { c.close() }
            return try c.upload(big, to: d + "/up/file", baseline: nil, cancel: flag)
        }
    }, "cancel didn't stop the save")
    #expect(throws: CancellationError.self) { try r.get() }
    #expect(try fm.contentsOfDirectory(atPath: d + "/up") == [], "the partial file stayed")
}

/// R13: a save cancelled while the link stalls for a couple of seconds still removes its partial file: a server
/// quiet that long is waited for, not cut off (then the partial would stay).
@Test func cancelledSaveOverAStallingLinkCleansUp() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d); kill(d) }
    let server = slowServer(d, log: d + "/connections")
    try fm.createDirectory(atPath: d + "/up", withIntermediateDirectories: false)
    let big = sparse(d + "/big", 64 << 20)
    let flag = CancelFlag()
    let done = Box<Bool>()
    cancelOnPartial(in: d + "/up", while: { done.value == nil }) {
        fm.createFile(atPath: d + "/stall", contents: nil)
        flag.cancel()
    }
    let r = try #require(within(40) { () -> Result<SFTPClient.Attrs, Error> in
        defer { done.value = true }
        return Result {
            let c = try SFTPClient(.local(server: server), cancel: flag)
            defer { c.close() }
            return try c.upload(big, to: d + "/up/file", baseline: nil, cancel: flag)
        }
    }, "cancel didn't stop the save")
    #expect(throws: CancellationError.self) { try r.get() }
    #expect(try fm.contentsOfDirectory(atPath: d + "/up") == [], "the partial file stayed")
}

/// `/usr/libexec/sftp-server` behind a link of ~320 KiB/s towards it; each connection adds a line to `log`. The
/// link stalls once for 2.5 s when `dir/stall` shows up. The throttle carries `dir` so `kill(dir)` finds it.
private func slowServer(_ dir: String, log: String) -> String {
    let server = dir + "/slow-sftp-server"
    try! """
    #!/bin/sh
    echo x >> '\(log)'
    perl -e 'while (sysread STDIN, $b, 16384) { syswrite STDOUT, $b; select undef, undef, undef, 0.05; if (!$s && -e "$ARGV[0]/stall") { $s = 1; select undef, undef, undef, 2.5 } }' '\(dir)' | /usr/libexec/sftp-server
    """.write(toFile: server, atomically: true, encoding: .utf8)
    chmod(server, 0o755)
    return server
}

/// A sparse file: quick to make, long enough to copy.
private func sparse(_ path: String, _ size: UInt64) -> String {
    fm.createFile(atPath: path, contents: nil)
    let h = FileHandle(forWritingAtPath: path)!
    try! h.truncate(atOffset: size)
    try! h.close()
    return path
}

/// Runs `cancel` half a second after a partial file shows up in `dir` (the pipeline full, writes waiting on the link).
private func cancelOnPartial(in dir: String, while running: @escaping @Sendable () -> Bool, _ cancel: @escaping @Sendable () -> Void) {
    Thread {
        while running() {
            if ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).contains(where: { $0.hasPrefix(".dfm-partial-") }) {
                usleep(500_000)
                return cancel()
            }
            usleep(2_000)
        }
    }.start()
}
