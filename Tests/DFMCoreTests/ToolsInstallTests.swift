import Foundation
import Testing
@testable import DFMCore

// Install (protocol §10.6): the command for a server's package manager, the action Kermo makes of it, its prechecks
// run for real on this Mac's /bin/dash and /bin/bash, what the trust sheet lists; Clean Up Kermo Files on a HOME of
// the test's own.

private let shells = ["/bin/dash", "/bin/bash"]

private func tool(_ json: String) throws -> ToolPreset {
    let text = #"{ "schema": 1, "id": "t", "title": "T", "tool": "thing", "# + json + " }"
    return try #require(ToolSchema.validate(Data(text.utf8), file: "t.json").preset)
}

/// `p` run as ssh runs a payload — in a session of its own, as sshd's, stdin held open (its end stops the run) — HOME `home`:
/// its output after the start marker, its exit.
private func run(_ p: ToolPayload, home: String) throws -> (out: String, status: Int32) {
    var reader = ToolRunOutput(nonce: p.nonce), out = Data()
    let setsid = "/usr/bin/perl -e 'use POSIX; setsid(); exec @ARGV' -- "
    let (status, _) = try SSHCommand.run(.local(), "HOME=\(home) " + setsid + p.command, stdin: p.stdin(), holdStdin: CancelFlag()) { out += reader.feed($0) }
    return (String(decoding: out, as: UTF8.self), status)
}

/// A server's `pkg` fact picks the command — apt-get's is `apt`, yum's `dnf` — as root but brew's; where there's none,
/// the script; neither: nothing to install. Install… is `long` and always asked, `after` its line at the end.
@Test func installPicksTheServersPackageManager() throws {
    let p = try tool(#""install": { "apt": "apt-get install -y thing", "dnf": "dnf install -y thing", "brew": "brew install thing", "after": "thing starts off" }"#)
    let i = try #require(p.install)
    #expect(i.command(pkg: "apt-get") == "apt-get install -y thing" && i.command(pkg: "yum") == "dnf install -y thing")
    #expect(i.command(pkg: "apk") == nil && i.run(pkg: "apk") == nil && i.action(pkg: "none", title: "thing") == nil)
    #expect(i.run(pkg: "apt-get")?.sudo == true && i.run(pkg: "brew")?.sudo == false, "brew won't run as root")
    let a = try #require(i.action(pkg: "dnf", title: "thing"))
    #expect(a.spec.id == ToolInstall.actionID && a.spec.title == "Install thing…" && a.spec.long == true && a.spec.confirm == true)
    #expect(a.spec.done == "thing starts off" && a.run.command?.all == ["dnf install -y thing"])

    let s = try #require(try tool(#""install": { "apk": "apk add thing", "script": { "url": "https://example.com/i.sh", "env": { "V": "1.2" }, "sha256": "ab" } }"#).install)
    #expect(s.run(pkg: "apk")?.command?.all == ["apk add thing"])
    let script = try #require(s.run(pkg: "apt-get"))
    #expect(script.script == "https://example.com/i.sh" && script.env == ["V": "1.2"] && script.sudo == true, "its text goes in under its address")
}

/// Each precheck runs as the login user, its values as variables; one that fails stops Install with its title and what
/// was found: an exit that isn't 0, a pattern not found, a version under `min`. All passed: nothing to say.
@Test(arguments: shells) func prechecksSayWhyInstallStops(_ shell: String) throws {
    func refusal(_ checks: String, base: String = "/opt/x") throws -> String? {
        let json = #""vars": { "base": { "default": "/opt" } }, "install": { "apt": "x", "precheck": [ "# + checks + " ] }"
        let i = try #require(try tool(json).install)
        let p = try #require(i.prechecks(.init(vars: ["base": .string(base)]), shell: shell))
        let r = try run(p, home: NSTemporaryDirectory())
        #expect(r.status == 0, "\(r)")
        return i.refusal(prechecks: r.out, nonce: p.nonce)
    }
    let podman = #"{ "title": "Podman 4.8 or newer", "command": "printf 'podman version %s\\n' 4.3.1", "pattern": "(?<v>\\d+\\.\\d+)", "min": "4.8" }"#
    #expect(try refusal(podman) == "Podman 4.8 or newer is needed (found 4.3)")
    #expect(try refusal(podman.replacingOccurrences(of: "4.3.1", with: "5.0.2")) == nil)
    #expect(try refusal(#"{ "title": "systemd", "command": "echo 'no such thing' >&2; exit 1" }"#) == "systemd is needed (no such thing)")
    #expect(try refusal(#"{ "title": "A base", "command": "echo {base}", "pattern": "^/srv" }"#) == "A base is needed (not found)")
    #expect(try refusal(#"{ "title": "A base", "command": "echo {base}", "pattern": "^/srv" }"#, base: "/srv/a") == nil)
    #expect(try refusal(#"{ "title": "A base", "command": "echo {base}", "pattern": "^/srv" }"#, base: "$(echo /srv)") == "A base is needed (not found)",
            "a value is a variable, never shell text")
    #expect(try refusal(#"{ "title": "One", "command": "true" }, { "title": "Two", "command": "exit 3" }"#) == "Two is needed")
}

/// A precheck that didn't say how it went (the run stopped early) stops Install too; a value it needs that's empty
/// stops it before anything runs.
@Test func aPrecheckThatDidntRunStopsInstall() throws {
    let i = try #require(try tool(#""install": { "apt": "x", "precheck": [ { "title": "Base", "command": "test -d {base}" } ] }"#).install)
    #expect(i.refusal(prechecks: "", nonce: "n") == "Base: its check didn't run")
    #expect(i.prechecks(.init()) == nil, "{base} has no value")
}

/// The trust sheet and the tool's page list what Install runs on each system, as root but brew, the script with its
/// values and its sha256's start, and what stays on the server; an agentless tool has no such group.
@Test func whatInstallRunsIsListed() throws {
    let p = try tool(#"""
        "install": { "apt": "apt-get install -y thing", "brew": "brew install thing",
                     "script": { "url": "https://example.com/i.sh", "env": { "V": "1.2" }, "sha256": "0123456789abcdef0123" },
                     "leaves": { "services": ["thing"], "paths": ["/usr/local/bin/thing", "{base}"], "ports": [80, 443], "note": "a timer too" } },
        "vars": { "base": { "default": "/opt/thing" } }, "command": "thing status"
        """#)
    let t = LoadedTool(preset: p, path: "/t.json", builtIn: false, scripts: [:], hash: "h", warnings: [])
    let g = try #require(t.runs.groups.last)
    #expect(g.title == "Installs software, only when you press Install…")
    #expect(g.lines.map(\.text) == ["  apt: apt-get install -y thing   — as root", "  brew: brew install thing",
                                    "  script: https://example.com/i.sh V=1.2 (sha256 0123456789ab…)   — as root",
                                    "  stays on the server: services thing; /usr/local/bin/thing, {base}; ports 80, 443; a timer too"])
    let bare = LoadedTool(preset: try tool(#""command": "thing status""#), path: "/t.json", builtIn: false, scripts: [:], hash: "h", warnings: [])
    #expect(!bare.runs.groups.contains { $0.title.hasPrefix("Installs") })
    let noSum = try #require(try tool(#""install": { "script": { "url": "https://example.com/i.sh" } }"#).install)
    #expect(noSum.lines.first?.how == "https://example.com/i.sh (no sha256: not run)")
}

/// Clean Up Kermo Files: nothing there — no size; a folder — its size; a job still running from it — kept (exit 3),
/// and counted; once it's over — the folder gone.
@Test(arguments: shells) func cleanUpTakesKermosFolderUnlessAJobRuns(_ shell: String) throws {
    let home = NSTemporaryDirectory() + "kermo-clean-" + UUID().uuidString, runs = home + "/.cache/kermo/runs"
    defer { try? FileManager.default.removeItem(atPath: home) }
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    #expect(ToolLong.cleanUp(try run(ToolLong.cleanUp(remove: false, shell: shell), home: home).out).bytes == nil)

    try FileManager.default.createDirectory(atPath: runs, withIntermediateDirectories: true)
    try Data(repeating: 65, count: 20_000).write(to: URL(fileURLWithPath: runs + "/1-a.log"))
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try sleeper.run()
    defer { sleeper.terminate() }
    try Data("\(sleeper.processIdentifier)\n".utf8).write(to: URL(fileURLWithPath: runs + "/1-a.pid"))
    let looked = ToolLong.cleanUp(try run(ToolLong.cleanUp(remove: false, shell: shell), home: home).out)
    #expect(looked.running == 1 && (looked.bytes ?? 0) >= 20_000, "\(looked)")
    #expect(try run(ToolLong.cleanUp(remove: true, shell: shell), home: home).status == 3)
    #expect(FileManager.default.fileExists(atPath: runs + "/1-a.log"), "a running job's log stays")

    try Data("0\n".utf8).write(to: URL(fileURLWithPath: runs + "/1-a.exit"))   // it's over
    let r = try run(ToolLong.cleanUp(remove: true, shell: shell), home: home)
    #expect(r.status == 0 && ToolLong.cleanUp(r.out).running == 0, "\(r)")
    #expect(!FileManager.default.fileExists(atPath: home + "/.cache/kermo") && FileManager.default.fileExists(atPath: home))
}
