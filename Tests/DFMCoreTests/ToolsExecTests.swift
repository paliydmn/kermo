import Foundation
import Testing
@testable import DFMCore

// One Tools run (protocol §2 once, §3.2): its limits, sudo with a password, and exit 127 / 126 in words. Payloads run
// on this Mac's /bin/sh in a session of their own (perl's setsid), as sshd starts one on a server.

private let setsid = "/usr/bin/perl -e 'use POSIX; setsid(); exec @ARGV' -- "

private func payload(_ body: String, sudo: ToolPayload.Sudo = .none, sudoProgram: String = "sudo") -> ToolPayload {
    ToolPayload(body: body, values: [], sudo: sudo, sudoProgram: sudoProgram)
}

private func run(_ body: String, timeout: Double = 30, cancel: CancelFlag = CancelFlag()) throws -> ToolExec.Ran {
    try ToolExec.run({ _ in payload(body) }, on: .local(), timeout: timeout, cancel: cancel) { setsid + $0.command }
}

/// What comes before the marker isn't the run's; a failure keeps its exit and stderr.
@Test func aRunIsItsOwnOutputAndExit() throws {
    let r = try run("echo one; echo two; echo oops >&2; exit 3")
    #expect(r.started && r.status == 3 && r.text == "one\ntwo\n" && r.errors == "oops" && r.stopped == nil)
}

/// Past its timeout a run is stopped and says so; ⎋ stops it as a cancel.
@Test func aRunStopsAtItsTimeoutAndOnCancel() throws {
    let start = Date()
    let r = try run("echo started; sleep 20", timeout: 1)
    #expect(r.stopped == "it took over 1 s" && r.text == "started\n" && Date().timeIntervalSince(start) < 5)
    let flag = CancelFlag()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { flag.cancel() }
    #expect(throws: CancellationError.self) { try run("sleep 20", cancel: flag) }
}

/// Over 16 MB the run is stopped; a line keeps its first 1 MB.
@Test func outputHasItsLimits() throws {
    let r = try run("yes 0123456789abcdef")
    #expect(r.stopped == "over 16 MB of output" && r.out.count > ToolExec.maxOutput && r.out.count < ToolExec.maxOutput + 2 << 20)
    let long = Data(repeating: 0x61, count: ToolExec.maxLine + 10) + Data("\nnext\n".utf8)
    #expect(ToolExec.lines(long) == Data(repeating: 0x61, count: ToolExec.maxLine) + Data("\nnext\n".utf8))
}

/// Exit 127 and 126 say which program, where, and what the server is — from each shell's own words.
@Test func notFoundAndNotPermittedInWords() {
    var f = ToolFacts()
    (f.os, f.osVersion, f.pkg) = ("fedora", "44", "dnf")
    func ran(_ status: Int32, _ errors: String) -> ToolExec.Ran { var r = ToolExec.Ran(); (r.status, r.errors) = (status, errors); return r }
    #expect(ToolExec.notHere(ran(127, "sh: 1: apt-get: not found"), server: "web-01", facts: f) == "apt-get isn't on web-01 (Fedora 44 · dnf)")
    #expect(ToolExec.notHere(ran(127, "sh: line 1: apt-get: command not found"), server: "web-01", facts: nil) == "apt-get isn't on web-01")
    #expect(ToolExec.notHere(ran(127, "sh: whois: not found"), server: "this Mac", facts: nil) == "whois isn't on this Mac")
    #expect(ToolExec.notHere(ran(126, "sh: 1: ./deploy: Permission denied"), server: "web-01", facts: f) == "./deploy can't be run on web-01: permission")
    #expect(ToolExec.notHere(ran(1, "sh: 1: x: not found"), server: "web-01", facts: f) == nil)
}

/// `version.tested`: each part an operator and a version, number by number; `unknown` builds say nothing.
@Test func versionsWithinTested() throws {
    let v = try JSONDecoder().decode(ToolVersion.self, from: Data(#"{"command": "dpl -V", "pattern": "dpl (?<v>[\\d.]+)", "tested": ">=0.6 <0.7", "unknown": ["0.0.1"]}"#.utf8))
    #expect(v.found(in: "dpl 0.6.1 (abc)") == "0.6.1" && v.found(in: "nothing") == nil)
    #expect(v.tested("0.6.1") == true && v.tested("0.6") == true && v.tested("0.7.0") == false && v.tested("0.5.9") == false && v.tested("0.0.1") == nil)
}

/// `sudo -n` first; only where it wants a password, the wrapper — asked, a wrong one asked again, then it runs. The
/// password never shows in what's said.
extension SudoPasswordTests {
    static let toolSudo = #"""
        #!/bin/sh
        n=; while [ $# -gt 0 ]; do case $1 in -n) n=1; shift ;; -S|-k) shift ;; -p) shift 2 ;; *) break ;; esac; done
        [ -n "$n" ] && { echo 'sudo: a password is required' >&2; exit 1; }
        IFS= read -r pw || exit 1
        [ "$pw" = kermo-test-pw ] || { echo "Sorry, try again ($pw)." >&2; exit 1; }
        exec "$@"
        """#

    @Test func aToolRunAsksForSudosPasswordOnlyWhenItWantsOne() throws {
        let sudo = NSTemporaryDirectory() + "kermo-tool-sudo-" + UUID().uuidString
        try Data(Self.toolSudo.utf8).write(to: URL(fileURLWithPath: sudo))
        chmod(sudo, 0o755)
        defer { try? FileManager.default.removeItem(atPath: sudo) }
        let make = { (pw: Bool) in payload("echo as-root", sudo: pw ? .password : .noPassword, sudoProgram: sudo) }
        let a = Answers(["wrong-one", "kermo-test-pw"])
        try Self.answering(a) {
            let r = try ToolExec.run(make, on: .local(), timeout: 30, cancel: CancelFlag()) { setsid + $0.command }
            #expect(r.started && r.status == 0 && r.text == "as-root\n" && r.password == "kermo-test-pw")
            #expect(a.wrong == [false, true] && a.taken == ["kermo-test-pw"])
        }
        let none = Answers([nil])
        try Self.answering(none) {
            #expect(throws: ToolExec.NoPassword.self) { try ToolExec.run(make, on: .local(), timeout: 30, cancel: CancelFlag()) { setsid + $0.command } }
        }
        let thrice = Answers(["a", "b", "c"])
        try Self.answering(thrice) {
            do {
                _ = try ToolExec.run(make, on: .local(), timeout: 30, cancel: CancelFlag()) { setsid + $0.command }
                Issue.record("ran with a wrong password")
            } catch let e as SFTPError {
                #expect(e.message.hasPrefix("sudo on localhost refused the password 3 times: ") && e.message.hasSuffix("try again (•••)."), "\(e.message)")
            }
        }
    }
}
