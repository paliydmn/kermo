import Foundation
import Testing
@testable import DFMCore

// The payload (protocol §3, review 2026-10-29 §2.4) run for real on this Mac's /bin/dash and /bin/bash — Debian's
// and Fedora's /bin/sh. The local target runs it in a session of its own (perl's setsid: Process can't), so the
// watcher's `kill -TERM 0` reaches only the payload, as sshd's session does on a server.

private let shells = ["/bin/dash", "/bin/bash"]
private let setsid = "/usr/bin/perl -e 'use POSIX; setsid(); exec @ARGV' -- "

private func payload(_ body: String, shell: String, values: [ToolTemplate.Variable] = [], secret: Set<String> = [], text: String? = nil,
                     env: [(name: String, text: String)] = [], sudo: ToolPayload.Sudo = .none, sudoProgram: String = "sudo",
                     where: ToolWhere = .server) -> ToolPayload {
    ToolPayload(body: body, values: values, env: env, secret: secret, text: text, sudo: sudo, where: `where`, sudoProgram: sudoProgram, shell: shell)
}

/// Runs `p` as Kermo would over ssh, stdin held open until it ends (or `hold` is cancelled). Output after the marker.
private func run(_ p: ToolPayload, password: String? = nil, hold: CancelFlag = CancelFlag()) throws -> (status: Int32, out: String, errors: String, skew: TimeInterval?) {
    var reader = ToolRunOutput(nonce: p.nonce), out = Data()
    let (status, errors) = try SSHCommand.run(.local(), setsid + p.command, stdin: p.stdin(password: password), holdStdin: hold) { out += reader.feed($0) }
    return (status, String(decoding: out, as: UTF8.self), errors, reader.skew)
}

/// A stand-in sudo: `-S` reads one password line and wants "right" (`nopasswd`: reads nothing; `greedy`: reads two).
private func standInSudo(_ kind: String) throws -> String {
    let path = NSTemporaryDirectory() + "kermo-sudo-\(kind)-\(UUID().uuidString)"
    let read = ["password": "IFS= read -r pw || exit 1; [ \"$pw\" = right ] || { echo 'Sorry, try again.' >&2; exit 1; }",
                "nopasswd": ":", "greedy": "IFS= read -r pw; IFS= read -r more"][kind]!
    try Data("#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in -S|-k|-n) shift ;; -p) shift 2 ;; *) break ;; esac; done\n\(read)\nexec \"$@\"\n".utf8)
        .write(to: URL(fileURLWithPath: path))
    chmod(path, 0o755)
    return path
}

@Test(arguments: shells) func theBodyDoesntSeeStdin(_ shell: String) throws {
    let r = try run(payload(#"IFS= read -r x; echo "got:[$x]"; echo after"#, shell: shell))
    #expect(r.status == 0)
    #expect(r.out == "got:[]\nafter\n")
}

@Test(arguments: shells) func itEndsAtOnceWhileStdinIsHeldOpen(_ shell: String) throws {
    let start = Date()
    let r = try run(payload("echo done", shell: shell))   // the hold is never cancelled: only the run's end releases it
    #expect(r.out == "done\n")
    #expect(Date().timeIntervalSince(start) < 3)
}

@Test(arguments: shells) func theExitCodeArrives(_ shell: String) throws {
    #expect(try run(payload("echo partial; exit 3", shell: shell)).status == 3)
    #expect(try run(payload("false", shell: shell)).status == 1)
}

/// stdin's end is the connection's: the watcher stops the whole session, and nothing is left running.
@Test(arguments: shells) func closingStdinKillsTheRunAndLeavesNothing(_ shell: String) throws {
    let token = "3\(Int.random(in: 100_000...999_999))"   // a sleep no one else runs
    let hold = CancelFlag()
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { hold.cancel() }
    let start = Date()
    let r = try run(payload("sleep \(token); echo late", shell: shell), hold: hold)
    #expect(Date().timeIntervalSince(start) < 10, "at once, not the sleep's — a loaded full run once took 6.7 s")
    #expect(!r.out.contains("late"))
    usleep(300_000)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", "sleep \(token)"]
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 1, "a sleep \(token) is still running")
}

@Test(arguments: shells) func theMarkerCarriesTheServersClock(_ shell: String) throws {
    let p = payload("echo one", shell: shell)
    #expect(p.script.contains("printf 'KERMO-%s %s\\n' \(p.nonce) \"$(date +%s)\""))
    let r = try run(p)
    #expect(r.out == "one\n")
    #expect(abs(try #require(r.skew)) < 5)
}

/// Before the marker: a `.bashrc` banner, a motd — never the run's. The empty line sudo-rs prints after the marker too.
@Test func outputBeforeTheMarkerIsDropped() {
    var r = ToolRunOutput(nonce: "abc")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(r.feed(Data("Welcome!\nKERMO-abc".utf8), now: now).isEmpty)
    #expect(r.feed(Data(" 1800000090\n".utf8), now: now).isEmpty)   // the empty line may come in the next chunk
    #expect(r.feed(Data("\nrow 1\n".utf8), now: now) == Data("row 1\n".utf8))
    #expect(r.feed(Data("\nrow 2\n".utf8), now: now) == Data("\nrow 2\n".utf8))   // only the first empty line goes
    #expect(r.skew == 90)
    var other = ToolRunOutput(nonce: "abc")
    #expect(other.feed(Data("say KERMO-abc 1\nKERMO-abcd 2\nKERMO-abc 1800000000\nx".utf8), now: now) == Data("x".utf8))   // at a line's start, this nonce
}

@Test(arguments: shells) func valuesArriveAsTheyAre(_ shell: String) throws {
    let tricky = "a';rm -rf /;' $(id) `id`"
    let p = payload(#"printf '<%s>' "$K_x" "$RESTIC_REPOSITORY""#, shell: shell, values: [.init(name: "K_x", value: tricky), .init(name: "K_repo", value: "/srv/a b")],
                    env: [(name: "RESTIC_REPOSITORY", text: #"sftp:"$K_repo""#)])
    #expect(try run(p).out == "<\(tricky)><sftp:/srv/a b>")
}

/// A secret is read by a builtin from a heredoc inside the script: never in argv, never shown.
@Test(arguments: shells) func aSecretStaysInsideTheScript(_ shell: String) throws {
    let secret = "pa$$ 'w0rd' $(id)"
    let p = payload(#"printf '%s' "$K_pw""#, shell: shell, values: [.init(name: "K_pw", value: secret)], secret: ["K_pw"])
    #expect(p.script.contains("IFS= read -r K_pw <<'KERMO_\(p.nonce)'\n\(secret)\nKERMO_\(p.nonce)"))
    #expect(!p.shown.contains(secret) && p.shown.contains("•••"))
    #expect(p.mask("echo \(secret) and right", password: "right") == "echo ••• and •••")
    #expect(try run(p).out == secret)
}

/// Send to ▸: the text is the body's stdin, inside the script as a heredoc — bash reads a script byte by byte, and
/// text after it would be read as commands.
@Test(arguments: shells) func sentTextIsTheBodysStdin(_ shell: String) throws {
    let text = "first line\n$(id) stays text\nlast"
    let r = try run(payload("cat; echo ':end'", shell: shell, text: text))
    #expect(r.out == text + "\n:end\n")
}

@Test(arguments: shells) func sudoWithoutAPassword(_ shell: String) throws {
    let sudo = try standInSudo("nopasswd")
    defer { try? FileManager.default.removeItem(atPath: sudo) }
    let p = payload("echo ran as root", shell: shell, sudo: .noPassword, sudoProgram: sudo)
    #expect(p.command == "\(sudo) -n \(shell) -s")
    #expect(try run(p).out == "ran as root\n")
}

/// The wrapper: the password, then the marker. sudo that takes the password leaves the marker first; NOPASSWD
/// leaves the password first, which the wrapper reads past — it never runs as a command.
@Test(arguments: shells) func sudoWithAPasswordThroughTheWrapper(_ shell: String) throws {
    for kind in ["password", "nopasswd"] {
        let sudo = try standInSudo(kind)
        defer { try? FileManager.default.removeItem(atPath: sudo) }
        let p = payload("echo ran", shell: shell, sudo: .password, sudoProgram: sudo)
        let r = try run(p, password: "right")
        #expect((r.status, r.out) == (0, "ran\n"), "\(kind): \(r.errors)")
        #expect(!r.errors.contains("not found") && !r.errors.contains("right"), "\(kind): \(r.errors)")
    }
    let wrong = try standInSudo("password")
    defer { try? FileManager.default.removeItem(atPath: wrong) }
    let r = try run(payload("echo ran", shell: shell, sudo: .password, sudoProgram: wrong), password: "wrong")
    #expect(r.status == 1 && r.out.isEmpty && r.errors.contains("Sorry"))
    let greedy = try standInSudo("greedy")   // one that ate the marker too: nothing runs
    defer { try? FileManager.default.removeItem(atPath: greedy) }
    let g = try run(payload("echo ran", shell: shell, sudo: .password, sudoProgram: greedy), password: "right")
    #expect(g.status == ToolPayload.sudoRefused && g.out.isEmpty)
}

/// On this Mac: no watcher (`kill 0` would reach Kermo's own group), never as root.
@Test func onThisMacThereIsNoWatcher() throws {
    let p = payload("echo here; exit 4", shell: "/bin/sh", sudo: .password, where: .mac)
    #expect(!p.script.contains("kill -TERM 0") && p.sudo == .none && p.command == "/bin/sh -s")
    var out = Data(), reader = ToolRunOutput(nonce: p.nonce)
    let (status, _) = try SSHCommand.run(.local(), p.command, stdin: p.stdin()) { out += reader.feed($0) }
    #expect(status == 4 && out == Data("here\n".utf8))
}

/// A preset's Run as PR 2 will run it: fail2ban's Unban on a row.
@Test func aPresetsRunBecomesItsPayload() throws {
    let data = try Data(contentsOf: ToolPreset.builtInFolder.appendingPathComponent("fail2ban.json"))
    let tool = try #require(ToolSchema.validate(data, file: "fail2ban.json").preset)
    let unban = try #require(tool.actions?.first { $0.spec.id == "unban" })
    let (p, willRun) = try ToolPayload.of(unban.run, in: tool, scope: .init(rows: [["jail": "sshd", "ip": "203.0.113.7"]]), nonce: "n")
    #expect(willRun == "fail2ban-client set sshd unbanip 203.0.113.7")
    #expect(p.command == "sudo -n sh -s")   // the tool's sudo
    #expect(p.script.contains("K_jail=sshd\nK_ip=203.0.113.7\n"))
    #expect(p.script.contains(#"{ fail2ban-client set "$K_jail" unbanip "$K_ip""#))
    let secret = ToolRun(command: .one("mysql -p{pw} -e 'select 1'"))
    let (s, shown) = try ToolPayload.of(secret, in: tool, scope: .init(inputs: ["pw": "hunter2"]), secret: ["pw"], password: true)
    #expect(!s.shown.contains("hunter2") && !shown.contains("hunter2") && s.sudo == .password)
}

@Test func aNonceInTheTextIsReplaced() {
    let p = ToolPayload(body: "echo KERMO_abc", values: [], nonce: "abc")
    #expect(p.nonce != "abc" && p.nonce.count == 16)
}

/// A `terminal` run's line (§2): `sh -c` with each value a variable before the command — one argument, whatever it
/// holds — the tool's env, and `sudo` in front as root. It runs as the login shell would have it.
@Test func aTerminalLineKeepsEachValueOneArgument() throws {
    let tool = try JSONDecoder().decode(ToolPreset.self, from: Data(#"{ "schema": 1, "id": "t", "title": "T", "env": { "MODE": "{mode}" } }"#.utf8))
    let run = ToolRun(command: .one(#"printf '[%s]' {name} "$MODE""#))
    let scope = ToolTemplate.Scope(rows: [["name": "a b'; echo pwned", "mode": "x y"]])
    let (line, willRun) = try ToolPayload.terminal(run, in: tool, scope: scope)
    #expect(willRun == #"printf '[%s]' 'a b'\''; echo pwned' "$MODE""#)
    #expect(try SSHCommand.capture(.local(), line) == "[a b'; echo pwned][x y]")
    #expect(!line.contains("\n"), "one line: a csh login shell takes no line break inside quotes")
    var root = run
    root.sudo = true
    #expect(try ToolPayload.terminal(root, in: tool, scope: scope).line.hasPrefix("sudo sh -c "))
}

/// A list, its header and its version in one round trip (§3.2 rule 9): each part's output and exit apart, output
/// without a last line break too, none at all; the list's stderr kept, the others' dropped; the same variables for all.
@Test(arguments: shells) func severalRunsShareOneRoundTrip(_ shell: String) throws {
    let tool = try JSONDecoder().decode(ToolPreset.self, from: Data(#"{ "schema": 1, "id": "t", "title": "T" }"#.utf8))
    let runs = [ToolRun(command: .one("printf 'a\\nb %s\\n' {x}; echo oops >&2")), ToolRun(command: .one("printf 'no-newline %s' {x}; exit 3")),
                ToolRun(command: .one("echo hidden >&2; echo v1.2"))]
    let p = try #require(try ToolPayload.parts(runs, in: tool, scope: ToolTemplate.Scope(rows: [["x": "1 2"]])))
    let shelled = ToolPayload(body: "", values: [], shell: shell)   // the shell's own command
    var reader = ToolRunOutput(nonce: p.nonce), out = Data()
    let (status, errors) = try SSHCommand.run(.local(), setsid + shelled.command, stdin: p.stdin(), holdStdin: CancelFlag()) { out += reader.feed($0) }
    let parts = ToolPayload.parts(out, nonce: p.nonce)
    #expect(status == 0 && parts.count == 3 && errors == "oops")
    #expect(parts.map { String(decoding: $0.out, as: UTF8.self) } == ["a\nb 1 2\n", "no-newline 1 2", "v1.2\n"] && parts.map(\.status) == [0, 3, 0])
    let quiet = try #require(try ToolPayload.parts([ToolRun(command: .one("true")), runs[2]], in: tool, scope: .init()))
    var quietReader = ToolRunOutput(nonce: quiet.nonce), quietOut = Data()
    _ = try SSHCommand.run(.local(), setsid + shelled.command, stdin: quiet.stdin(), holdStdin: CancelFlag()) { quietOut += quietReader.feed($0) }
    #expect(ToolPayload.parts(quietOut, nonce: quiet.nonce).map { String(decoding: $0.out, as: UTF8.self) } == ["", "v1.2\n"], "a first part that said nothing")
    var root = runs[1]
    root.sudo = true
    #expect(try ToolPayload.parts([runs[0], root], in: tool, scope: .init()) == nil, "sudo differs: separate runs")
}
