import Darwin
import Foundation
import Testing
@testable import DFMCore

// Review 1, phase 5: ssh's questions asked by the app over a unix socket (`Askpass`).

/// A socket path short enough for sun_path, in a folder only we can enter (as `SFTP.controlDir`).
private func socketPath() -> String {
    var dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-ap-" + String(UUID().uuidString.prefix(8))
    if dir.utf8.count > 80 { dir = "/tmp/dfm-ap-" + String(UUID().uuidString.prefix(8)) }
    mkdir(dir, 0o700)
    return dir + "/s.sock"
}
private func cleanUp(_ path: String) { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Askpass.Request] = []
    func add(_ r: Askpass.Request) { lock.withLock { all.append(r) } }
    var requests: [Askpass.Request] { lock.withLock { all } }
}

/// The client in a thread of its own, as the script runs it: its exit code and what it printed for ssh.
private func ask(_ path: String, _ prompt: String, env: [String: String] = [:]) async -> (Int32, String) {
    await withCheckedContinuation { cont in
        Thread {
            nonisolated(unsafe) var printed = ""
            let code = Askpass.client(prompt: prompt, env: env.merging(["DFM_ASKPASS_SOCKET": path]) { $1 }) { printed = $0 }
            cont.resume(returning: (code, printed))
        }.start()
    }
}

/// The app takes the question, its answer goes to ssh (0); Cancel is 1; the why and whose login come with the prompt.
@Test func theAppAnswersSshsQuestion() async throws {
    let path = socketPath()
    defer { cleanUp(path) }
    let asked = Asked()
    let server = try #require(Askpass.Server(path: path) { r, taken, _ in
        asked.add(r)
        taken()
        return r.prompt.contains("cancel") ? nil : "pw for " + r.prompt
    })
    defer { server.stop() }
    var s = stat()
    #expect(stat(path, &s) == 0 && s.st_mode & 0o777 == 0o600)
    let (code, out) = await ask(path, "me@web's password: ", env: ["DFM_ASKPASS_WHY": "For “Run on Servers”", "DFM_ASKPASS_TARGET": "me@web\t2222"])
    #expect(code == 0 && out == "pw for me@web's password: ")
    #expect(asked.requests == [Askpass.Request(prompt: "me@web's password: ", why: "For “Run on Servers”", target: "me@web\t2222")])
    #expect(await ask(path, "cancel this") == (1, ""))
}

/// Two logins at once (tunnels, Run on Servers) each get their own answer.
@Test func twoQuestionsAtOnceEachGetTheirAnswer() async throws {
    let path = socketPath()
    defer { cleanUp(path) }
    let server = try #require(Askpass.Server(path: path) { r, taken, _ in
        taken()
        usleep(100_000)
        return r.prompt.uppercased()
    })
    defer { server.stop() }
    async let a = ask(path, "first")
    async let b = ask(path, "second")
    let (x, y) = await (a, b)
    #expect(x == (0, "FIRST") && y == (0, "SECOND"))
}

/// The app doesn't take it in time (busy), or isn't there: 2 — the script asks with its own dialog, so a login never
/// hangs. Not let in (another user's process, or one this app didn't start) is the same.
extension AskpassSerial {
@Test func noAnswerFallsBackToTheDialog() async throws {
    let wait = Askpass.ackWait
    Askpass.ackWait = 0.3
    defer { Askpass.ackWait = wait }
    let path = socketPath()
    defer { cleanUp(path) }
    #expect(await ask(path, "nobody listens") == (2, ""))
    #expect(Askpass.client(prompt: "x", env: [:]) { _ in } == 2, "not the app (the tests): no socket")
    let slow = try #require(Askpass.Server(path: path) { _, taken, _ in
        usleep(800_000)
        taken()
        return "late"
    })
    #expect(await ask(path, "busy") == (2, ""))
    slow.stop()
    let shut = try #require(Askpass.Server(path: path) { _, taken, _ in taken(); return "x" })
    shut.admits = { _ in false }   // as another uid is turned away: closed before it's taken
    #expect(await ask(path, "stranger") == (2, ""))
    shut.stop()
}
}

/// The client hanging up — ssh gone — takes the question away (`gone`), and nothing is answered after it.
@Test func aClientThatHangsUpTakesTheQuestionAway() async throws {
    let path = socketPath()
    defer { cleanUp(path) }
    let wentAway = Asked()
    let server = try #require(Askpass.Server(path: path) { r, taken, gone in
        taken()
        for _ in 0..<50 where !gone.isCancelled { usleep(50_000) }
        if gone.isCancelled { wentAway.add(r) }
        return "too late"
    })
    defer { server.stop() }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(Askpass.withAddress(path, { connect(fd, $0, $1) }) == 0)
    #expect(Askpass.write(fd, "me@web's password: \0\0\0"))
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    #expect(poll(&p, 1, 2000) > 0 && Askpass.read(fd, 1) == Data("S".utf8))
    close(fd)
    for _ in 0..<60 where wentAway.requests.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(wentAway.requests.map(\.prompt) == ["me@web's password: "])
}

/// Only what this app started may ask: its own process, or one a few parents down; not its parent, nor launchd.
@Test func onlyThisAppsChildrenMayAsk() throws {
    #expect(Askpass.descends(getpid(), from: getpid()))
    #expect(!Askpass.descends(getppid(), from: getpid()) && !Askpass.descends(1, from: getpid()))
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["5"]
    try child.run()
    defer { child.terminate() }
    #expect(Askpass.descends(child.processIdentifier, from: getpid()))
}

/// `Askpass.ackWait` is global: these one at a time.
@Suite(.serialized) struct AskpassSerial {}
