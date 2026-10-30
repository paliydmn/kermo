import Foundation
import Testing
@testable import DFMCore

// Long jobs (protocol §7.6) run for real on this Mac's /bin/dash and /bin/bash, HOME a folder of the test's own. This
// Mac has no setsid: the start takes perl's — the fallback a macOS server or a small busybox gets; a stand-in `setsid`
// on PATH takes the first way. The payload runs in a session of its own, as sshd's session is on a server.

private let shells = ["/bin/dash", "/bin/bash"]
private let setsid = "/usr/bin/perl -e 'use POSIX; setsid(); exec @ARGV' -- "

/// A HOME, a bin for stand-ins (sudo wanting a made-up password), and runs of payloads in it as ssh would run them.
private struct Box {
    let home = NSTemporaryDirectory() + "kermo-long-" + UUID().uuidString
    var bin: String { home + "/bin" }
    var runs: String { home + "/.cache/kermo/runs" }

    init() throws {
        try FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        // -n: wants a password; -S: reads one line, wants "right-pw-7731"; then runs the rest.
        try script("sudo", """
            while [ $# -gt 0 ]; do case $1 in -n) echo 'sudo: a password is required' >&2; exit 1 ;; -S|-k) shift ;; -p) shift 2 ;; *) break ;; esac; done
            IFS= read -r pw || exit 1; [ "$pw" = right-pw-7731 ] || { echo 'Sorry, try again.' >&2; exit 1; }
            exec "$@"
            """)
    }

    func script(_ name: String, _ body: String) throws {
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: bin + "/" + name))
        chmod(bin + "/" + name, 0o755)
    }

    func run(_ p: ToolPayload, path: String? = nil, password: String? = nil) throws -> (status: Int32, out: String, errors: String) {
        var reader = ToolRunOutput(nonce: p.nonce), out = Data()
        let command = "HOME=\(home) PATH=\(path ?? bin + ":/usr/bin:/bin:/usr/sbin:/sbin") " + setsid + p.command
        let (status, errors) = try SSHCommand.run(.local(), command, stdin: p.stdin(password: password), holdStdin: CancelFlag()) { out += reader.feed($0) }
        return (status, String(decoding: out, as: UTF8.self), errors)
    }

    func start(_ body: String, shell: String, id: String, root: ToolLong.Root = .none, values: [ToolTemplate.Variable] = [], secret: Set<String> = [],
               path: String? = nil) throws -> (status: Int32, out: String, errors: String) {
        let job = ToolPayload(body: body, values: values, secret: secret, detached: true)
        return try run(ToolLong.start(job, id: id, root: root, sudoProgram: bin + "/sudo", shell: shell), path: path)
    }

    func read(_ id: String, _ ext: String) -> String? { try? String(contentsOfFile: "\(runs)/\(id).\(ext)", encoding: .utf8) }

    func waitFor(_ id: String, _ ext: String, seconds: Double = 10) -> String? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if let s = read(id, ext) { return s }; usleep(100_000) }
        return nil
    }

    func done() { try? FileManager.default.removeItem(atPath: home) }
}

private func running(_ text: String) -> Bool {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axwwE", "-o", "args"]   // E: the environment too
    p.standardOutput = out
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").contains { $0.contains(text) && !$0.contains("/bin/ps") }
}

/// The start comes back at once with the job's pid; the job runs on after the connection is gone, its output in its
/// log, its exit in its exit file; the folder is the login user's, 0700. A follow reads the log and ends with the exit.
@Test(arguments: shells) func aLongJobOutlivesItsConnection(_ shell: String) throws {
    let box = try Box()
    defer { box.done() }
    let started = Date()
    let r = try box.start("echo one; sleep 2; echo two; exit 3", shell: shell, id: "j1")
    #expect(r.status == 0 && Int32(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) != nil, "\(r)")
    #expect(Date().timeIntervalSince(started) < 2, "at once, not the job's 2 s")
    #expect(box.read("j1", "exit") == nil, "still running once the connection is gone")
    let attrs = try FileManager.default.attributesOfItem(atPath: box.runs)
    #expect((attrs[.posixPermissions] as? Int) == 0o700)

    let follow = ToolLong.follow(id: "j1", from: 0, shell: shell)
    let f = try box.run(follow)
    #expect(f.out == "one\ntwo\n", "\(f)")
    #expect(ToolLong.end(f.errors, nonce: follow.nonce) == .exit(3))
    #expect(box.read("j1", "exit") == "3\n" && box.read("j1", "log") == "one\ntwo\n")

    let tail = ToolLong.follow(id: "j1", from: -4, shell: shell)
    let t = try box.run(tail)
    #expect(t.out == "two\n" && ToolLong.end(t.errors, nonce: tail.nonce) == .exit(3), "a reattach reads the end")
    let gone = ToolLong.follow(id: "nope", from: 0, shell: shell)
    #expect(ToolLong.end(try box.run(gone).errors, nonce: gone.nonce) == .gone)
}

/// Where there's a `setsid`, the start takes it; on this Mac (none) perl's — both leave the job in a session of its own.
@Test func setsidFirstThenPerl() throws {
    let box = try Box()
    defer { box.done() }
    try box.script("setsid", "touch \(box.home)/setsid-used; exec /usr/bin/perl -e 'use POSIX; setsid(); exec @ARGV' -- \"$@\"")
    #expect(try box.start("exit 0", shell: "/bin/dash", id: "s1").status == 0)
    #expect(box.waitFor("s1", "exit") == "0\n" && FileManager.default.fileExists(atPath: box.home + "/setsid-used"))
    try FileManager.default.removeItem(atPath: box.bin + "/setsid")
    try FileManager.default.removeItem(atPath: box.home + "/setsid-used")
    #expect(try box.start("exit 0", shell: "/bin/dash", id: "s2").status == 0)
    #expect(box.waitFor("s2", "exit") == "0\n" && !FileManager.default.fileExists(atPath: box.home + "/setsid-used"))
}

/// Root's job: the password checked before anything starts — a wrong one is 97 and nothing runs — then piped to sudo:
/// never in a process's arguments or environment, nor a secret value; both shown as •••.
@Test(arguments: shells) func thePasswordAndSecretsNeverShowInPs(_ shell: String) throws {
    let box = try Box()
    defer { box.done() }
    let wrong = try box.start("echo ran", shell: shell, id: "w1", root: .password("wrong-pw-0451"))
    #expect(wrong.status == ToolPayload.sudoRefused && !FileManager.default.fileExists(atPath: box.runs + "/w1.log"), "\(wrong)")
    let wants = try box.start("echo ran", shell: shell, id: "w2", root: .noPassword)
    #expect(wants.status == ToolLong.wantsPassword && wants.errors.contains("a password is required"))

    let secret = ToolTemplate.Variable(name: "K_key", value: "hunter2-xyz")
    let job = ToolPayload(body: "sleep 2; echo \"key=$K_key\"", values: [secret], secret: ["K_key"], detached: true)
    let start = ToolLong.start(job, id: "r1", root: .password("right-pw-7731"), sudoProgram: box.bin + "/sudo", shell: shell)
    #expect(!start.shown.contains("right-pw-7731") && !start.shown.contains("hunter2") && start.shown.contains("•••"))
    #expect(try box.run(start).status == 0)
    usleep(500_000)
    #expect(!running("hunter2") && !running("right-pw-7731") && running("sleep 2"))
    #expect(box.waitFor("r1", "exit") == "0\n" && box.read("r1", "log") == "key=hunter2-xyz\n")
}

/// Stop…: TERM to the job's group — a root job's through sudo, the shell's own kill — the exit file says 143; a job
/// that's over is left alone.
@Test(arguments: shells, [ToolLong.Root.none, .password("right-pw-7731")]) func stopKillsTheJobsGroup(_ shell: String, _ root: ToolLong.Root) throws {
    let box = try Box()
    defer { box.done() }
    let token = "3\(Int.random(in: 100_000...999_999))"
    #expect(try box.start("sleep \(token) & wait; echo late", shell: shell, id: "k1", root: root).status == 0)
    usleep(300_000)
    #expect(running("sleep \(token)"))
    let stop = ToolLong.stop(id: "k1", root: root, sudoProgram: box.bin + "/sudo", shell: shell)
    #expect(!stop.shown.contains("right-pw-7731") && !stop.script.contains("/kill"))
    #expect(try box.run(stop).status == 0)
    #expect(box.waitFor("k1", "exit") == "143\n")
    usleep(300_000)
    #expect(!running("sleep \(token)") && box.read("k1", "log")?.contains("late") != true)
    #expect(try box.run(ToolLong.stop(id: "k1", root: root, sudoProgram: box.bin + "/sudo", shell: shell)).status == 0, "over already: nothing to do")
}

/// The next start removes a job's files a week after it ended — or, with no exit, after it started and its process
/// is gone — never a running one's, nor a recent one's.
@Test func weekOldJobsGoAtTheNextStart() throws {
    let box = try Box()
    defer { box.done() }
    try FileManager.default.createDirectory(atPath: box.runs, withIntermediateDirectories: true)
    let old = Date().addingTimeInterval(-8 * 86_400)
    func job(_ id: String, pid: Int32, exit: Bool, at date: Date) throws {
        for ext in ["log", "pid"] + (exit ? ["exit"] : []) {
            let path = "\(box.runs)/\(id).\(ext)"
            try Data((ext == "pid" ? "\(pid)\n" : "0\n").utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
    }
    try job("ended-old", pid: 999_999, exit: true, at: old)
    try job("ended-new", pid: 999_999, exit: true, at: Date())
    try job("dead-old", pid: 999_999, exit: false, at: old)
    try job("alive-old", pid: getpid(), exit: false, at: old)   // the test runner: alive
    #expect(try box.start("exit 0", shell: "/bin/dash", id: "n1").status == 0)
    _ = box.waitFor("n1", "exit")
    let left = Set(try FileManager.default.contentsOfDirectory(atPath: box.runs).map { ($0 as NSString).deletingPathExtension })
    #expect(left == ["ended-new", "alive-old", "n1"], "\(left)")
}

/// `progress` (§7.6): a pattern's `percent`, a JSON line's `percent` or `fraction`, its text from the line's fields;
/// the last record of the log for `done`.
@Test func progressAndTheLastRecord() {
    let rsync = ToolProgress(percent: nil, fraction: nil, pattern: #"(?<percent>\d+)%"#, text: nil)
    #expect(ToolLong.progress(rsync, line: "  1,234,567  42%  10.00MB/s    0:00:12")?.fraction == 0.42)
    #expect(ToolLong.progress(rsync, line: "sending incremental file list") == nil)
    let restic = ToolProgress(percent: nil, fraction: "percent_done", pattern: nil, text: "{files_done} files")
    let p = ToolLong.progress(restic, line: #"{"message_type":"status","percent_done":0.25,"files_done":12}"#)
    #expect(p?.fraction == 0.25 && p?.text == "12 files")
    #expect(ToolLong.progress(ToolProgress(percent: "pct", fraction: nil, pattern: nil, text: nil), line: #"{"pct": 150}"#)?.fraction == 1)
    let log = Data("""
        {"message_type":"status","percent_done":1}
        {"message_type":"summary","snapshot_id":"4f2a","files_new":3}
        restic: done

        """.utf8)
    #expect(ToolLong.last(log, format: .jsonl)?["snapshot_id"] == .string("4f2a"))
    #expect(ToolLong.end("x\nKERMO-n1-END lost\n", nonce: "n1") == .lost && ToolLong.end("ssh: closed", nonce: "n1") == nil)
}
