import Foundation
import Testing
@testable import DFMCore

// Server facts and the batched `requires` (protocol §10.2–10.5), and per-server vars (§9).

private let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/tools")

/// The facts script's output, recorded on five systems (four of them in containers, so no init).
@Test func factsFromFiveSystems() throws {
    func facts(_ os: String) throws -> ToolFacts { ToolFacts.read(try String(contentsOf: fixtures.appendingPathComponent("facts.\(os).txt"), encoding: .utf8)) }
    let all = try ["debian", "ubuntu", "fedora", "alpine", "mint"].map(facts)
    #expect(all.map(\.os) == ["debian", "ubuntu", "fedora", "alpine", "linuxmint"])
    #expect(all.map(\.osVersion) == ["12", "26.04", "44", "3.20.10", "22.3"])
    #expect(all.map(\.pkg) == ["apt-get", "apt-get", "dnf", "apk", "apt-get"])
    #expect(all.map(\.userland) == ["gnu", "gnu", "gnu", "busybox", "gnu"])   // Ubuntu 26.04's uutils ls counts as GNU
    #expect(all.map(\.initSystem) == ["none", "none", "none", "none", "systemd"])
    #expect(all.allSatisfy { $0.arch == "x86_64" })
    let mint = all[4]
    #expect(mint.isOS("linuxmint") && mint.isOS("ubuntu") && mint.isOS("debian") && !mint.isOS("fedora"))   // a preset for debian shows on Mint
    #expect(!all[2].isOS("debian"))
    #expect(mint.names["os_version"] == "22.3" && mint.names["init"] == "systemd")
}

@Test func aFactIsOneShortPrintableLine() {
    let f = ToolFacts.read("banner\nkermo-fact ID=evil\u{1b}[2Jos\nkermo-fact pkg=\(String(repeating: "x", count: 200))\nkermo-fact other=1\n")
    #expect(f.os == "evil[2Jos")
    #expect(f.pkg.count == 64)
}

@Test func factsOfThisMac() throws {
    let p = ToolPayload(body: ToolFacts.script, values: [], where: .mac)
    var out = Data(), reader = ToolRunOutput(nonce: p.nonce)
    _ = try SSHCommand.run(.local(), p.command, stdin: p.stdin()) { out += reader.feed($0) }
    let f = ToolFacts.read(String(decoding: out, as: UTF8.self))
    #expect(f.os == "darwin" && !f.osVersion.isEmpty && !f.arch.isEmpty)
}

private func tool(_ json: String) throws -> ToolPreset {
    let id = try #require(json.firstMatch(of: /"id": "([a-z0-9-]+)"/)?.1)
    return try #require(ToolSchema.validate(Data(("{ \"schema\": 1, \"title\": \"T\", " + json + " }").utf8), file: "\(id).json").preset)
}

private let setsid = "/usr/bin/perl -e 'use POSIX; setsid(); exec @ARGV' -- "

@Test func requiresOfToolsAndActionsInOneRun() throws {
    let here = try tool(#""id": "here", "requires": "command -v sh", "toolActions": [ { "id": "a", "command": "x" } ]"#)
    let gone = try tool(#""id": "gone", "requires": "command -v kermo-no-such-program""#)
    let everywhere = try tool(#""id": "everywhere", "command": "df -h""#)
    let base = try tool(#""id": "base", "vars": { "base": { "default": "/" } }, "requires": "test -d {base}""#)
    let upgrade = try tool(#"""
        "id": "upgrade", "toolActions": [
          { "id": "up-apt", "title": "Upgrade", "key": "cmd+u", "requires": "command -v kermo-no-apt", "command": "apt-get upgrade" },
          { "id": "up-sh", "title": "Upgrade", "key": "cmd+u", "requires": "command -v sh", "command": "sh -c :" },
          { "id": "up-later", "title": "Upgrade", "key": "cmd+u", "requires": "command -v sh", "command": "true" },
          { "id": "status", "title": "Status", "command": "uptime" } ]
        """#)
    let tools = [here, gone, everywhere, base, upgrade]
    let items = ToolBatch.items(tools)
    #expect(items.map(\.name) == ["here", "gone", "base", "upgrade/up-apt", "upgrade/up-sh", "upgrade/up-later"])
    let scope = { (id: String) in ToolTemplate.Scope(vars: tools.first { $0.id == id }!.varValues(saved: [:])) }
    let p = ToolBatch.payload(items, scope: scope, scripts: { _ in [:] })
    #expect(p.script.contains("(\nK_base=/\ntest -d \"$K_base\"\n) >/dev/null 2>&1 </dev/null && echo 'kermo-ok 2'"))
    #expect(ToolBatch.ask(.local(), items, scope: scope, scripts: { _ in [:] }, hasMaster: { _ in false }) == nil)   // no live connection: no answer
    let answer = try #require(ToolBatch.ask(.local(), items, scope: scope, scripts: { _ in [:] }, hasMaster: { _ in true },
                                            command: { _ in setsid + "/bin/dash -s" }))
    #expect(answer.passed == ["here", "base", "upgrade/up-sh", "upgrade/up-later"])
    #expect(answer.facts.os == "darwin")
    #expect(tools.map { answer.has($0) } == [true, false, true, true, true])
    #expect(answer.visible(upgrade.toolActions!, of: upgrade).map(\.spec.id) == ["up-sh", "status"])   // the first variant that passed
}

@Test func anAnswerNamesOnlyItsOwnItems() {
    let items = [ToolBatch.Item(tool: "a", action: nil, run: ToolRun(command: .one("true")))]
    #expect(ToolBatch.read("kermo-ok 0\nkermo-ok 7\nkermo-ok x\n  kermo-ok 0\n", items).passed == ["a"])
}

/// A requires as root goes through `sudo -n`: a password it would want counts as "not here".
@Test func aRequiresAsRootAsksNobody() throws {
    let t = try tool(#""id": "r", "sudo": true, "about": "x", "requires": { "command": "test -r /etc/shadow", "sudo": true }, "toolActions": [ { "id": "a", "requires": "command -v x", "command": "x" } ]"#)
    let p = ToolBatch.payload(ToolBatch.items([t]), scope: { _ in .init() }, scripts: { _ in [:] })
    #expect(p.script.contains("sudo -n sh -c 'test -r /etc/shadow' >/dev/null 2>&1 </dev/null && echo 'kermo-ok 0'"))
    #expect(p.script.contains("(\ncommand -v x\n) >/dev/null"))   // the tool's sudo doesn't reach the requires
    #expect(p.command == "sh -s")
}

@Test func varsPerServer() throws {
    let restic = try #require(ToolSchema.validate(try Data(contentsOf: fixtures.appendingPathComponent("restic.json")), file: "restic.json").preset)
    #expect(restic.varsToAsk(saved: [:]) == ["passfile", "repo"])
    #expect(restic.varsToAsk(saved: ["repo": "/srv/restic"]) == ["passfile"])
    #expect(restic.varValues(saved: ["repo": "/srv/restic"]) == ["repo": "/srv/restic", "passfile": "/root/.restic-password"])
    let dpl = try #require(ToolSchema.validate(try Data(contentsOf: ToolPreset.builtInFolder.appendingPathComponent("dpl.json")), file: "dpl.json").preset)
    #expect(dpl.varCommands.map(\.name) == ["base"])
    #expect(dpl.varValues(saved: [:]) == ["base": "/opt/dpl"])
    #expect(dpl.varValues(saved: [:], found: ["base": "/srv/dpl"]) == ["base": "/srv/dpl"])
    #expect(dpl.varValues(saved: ["base": "/data/dpl"], found: ["base": "/srv/dpl"]) == ["base": "/data/dpl"])
}
