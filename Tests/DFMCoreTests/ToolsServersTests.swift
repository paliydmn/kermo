import Foundation
import Testing
@testable import DFMCore

// Per-server settings of tools (`tools/servers.json`, protocol §9, Q6): where a tool is used — wherever it's found, or
// only on the servers checked — hidden on one, the vars' values set there.

/// Wherever it's found unless hidden there; only-there tools on their list alone. A server not saved (no id) has no
/// settings: it shows what's used wherever found, nothing that's only on some.
@Test func whereAToolShows() {
    var s = ToolServers()
    #expect(s.uses("ufw", on: "A") && s.uses("ufw", on: nil))
    s.use("ufw", on: "A", false)
    #expect(!s.uses("ufw", on: "A") && s.uses("ufw", on: "B") && s.uses("ufw", on: nil))
    s.use("ufw", on: "A", true)
    #expect(s.uses("ufw", on: "A") && s == ToolServers(), "showing again writes nothing")

    s.assign("restic", onlyChecked: true, checked: ["B"], of: ["A", "B", "C"])
    #expect(!s.uses("restic", on: "A") && s.uses("restic", on: "B") && !s.uses("restic", on: nil))
    s.use("restic", on: "C", true)   // + on C
    s.use("restic", on: "B", false)  // Hide on B
    #expect(s.only["restic"] == ["C"] && s.servers.isEmpty, "an only-there tool's Hide is its list, not a flag")

    s.use("ufw", on: "A", false)
    s.assign("ufw", onlyChecked: false, checked: ["A", "C"], of: ["A", "B", "C"])
    #expect(s.uses("ufw", on: "A") && !s.uses("ufw", on: "B") && s.uses("ufw", on: "C") && s.uses("ufw", on: "D"), "a server saved later: found there, shown")
    s.assign("restic", onlyChecked: false, checked: ["A", "B", "C"], of: ["A", "B", "C"])
    #expect(s.only.isEmpty && s.uses("restic", on: nil))
}

/// What's set on one server goes into the tool's runs there (`varValues(saved:)`) and isn't asked again; another
/// server's are its own. The file keeps what Kermo doesn't know: a tool that's gone, a server deleted.
@Test func varsPerServerAndARoundTrip() throws {
    let json = #"""
        { "schema": 1, "id": "restic", "title": "Backups", "command": "restic -r {repo} snapshots",
          "vars": { "repo": { "title": "Repository", "ask": true, "pattern": "/[^ ]+", "placeholder": "/backup/restic" },
                    "keep": { "default": "7" } } }
        """#
    let (p, problems) = ToolSchema.validate(Data(json.utf8), file: "restic.json")
    let preset = try #require(p, "\(problems)")
    var s = ToolServers()
    #expect(preset.varsToAsk(saved: s.vars("restic", on: "A")) == ["repo"])
    s.setVars("restic", on: "A", ["repo": "/backup/a"])
    #expect(preset.varsToAsk(saved: s.vars("restic", on: "A")).isEmpty && preset.varsToAsk(saved: s.vars("restic", on: "B")) == ["repo"])
    #expect(preset.varValues(saved: s.vars("restic", on: "A")) == ["repo": .string("/backup/a"), "keep": .string("7")])

    let repo = try #require(preset.vars?["repo"])
    #expect(repo.problem("") == "Repository is empty")
    #expect(repo.problem("backup") == "doesn't look right: like /backup/restic")
    #expect(repo.problem("/backup/a") == nil)

    s.use("gone", on: "A", false)
    s.setVars("restic", on: "deleted-server", ["repo": "/x"])
    s.assign("restic", onlyChecked: true, checked: ["A"], of: ["A"])
    let back = try JSONDecoder().decode(ToolServers.self, from: JSONEncoder().encode(s))
    #expect(back == s && back.servers["A"]?["gone"]?.hidden == true && back.vars("restic", on: "deleted-server") == ["repo": "/x"])
    let hand = #"{ "servers": { "A": { "ufw": { "hidden": true } } } }"#   // `only` left out by hand: nothing only-there
    #expect(try JSONDecoder().decode(ToolServers.self, from: Data(hand.utf8)).uses("ufw", on: "A") == false)
}

/// Watched per server and tool (§8.5): `watch: true` in the server's setting, off again leaves nothing behind;
/// the file keeps it.
@Test func watchedPerServerAndTool() throws {
    var s = ToolServers()
    #expect(!s.watches("system", on: "A") && s.watched.isEmpty)
    s.watch("system", on: "A", true)
    s.watch("dpl", on: "B", true)
    #expect(s.watches("system", on: "A") && !s.watches("system", on: nil) && !s.watches("system", on: "B"))
    #expect(s.watched.map { $0.server + " " + $0.tool } == ["A system", "B dpl"])
    let back = try JSONDecoder().decode(ToolServers.self, from: try JSONEncoder().encode(s))
    #expect(back.watched.map(\.tool) == ["system", "dpl"] && back.uses("system", on: "A"), "watched, and shown as ever")
    s.watch("system", on: "A", false)
    #expect(!s.watches("system", on: "A") && s.servers["A"] == nil, "an empty setting isn't kept")
}

/// A notification's Mute This Alert on This Server: by the alert's id, for one tool on one server, kept in the file;
/// undone, nothing is left.
@Test func mutedPerServerToolAndAlert() throws {
    var s = ToolServers()
    s.mute("cpu", of: "system", on: "A", true)
    s.mute("cpu", of: "system", on: "A", true)
    s.mute("disk", of: "system", on: "A", true)
    #expect(s.mutes("cpu", of: "system", on: "A") && !s.mutes("cpu", of: "system", on: "B") && !s.mutes("cpu", of: "dpl", on: "A") && !s.mutes("cpu", of: "system", on: nil))
    #expect(s.servers["A"]?["system"]?.muted == ["cpu", "disk"], "once each")
    let back = try JSONDecoder().decode(ToolServers.self, from: try JSONEncoder().encode(s))
    #expect(back.mutes("disk", of: "system", on: "A"))
    s.mute("cpu", of: "system", on: "A", false)
    s.mute("disk", of: "system", on: "A", false)
    #expect(s.servers["A"] == nil, "an empty setting isn't kept")
}

/// Your thresholds (Thresholds…): one server's over all servers' over the tool's, by the alert's id (its metric when it
/// has none), each of warn and crit on its own; an empty one isn't kept.
@Test func thresholdsOverTheToolsByAlertID() throws {
    let p = try JSONDecoder().decode(ToolPreset.self, from: Data(#"""
        { "schema": 1, "id": "system", "title": "System",
          "alerts": [ { "id": "cpu", "metric": "cpu", "warn": 85, "crit": 95 }, { "metric": "disk", "warn": 85 } ] }
        """#.utf8))
    var s = ToolServers()
    #expect(s.alerts(p, on: "A") == p.alerts, "none of yours: the tool's")
    s.setThreshold(.init(warn: 70), alert: "cpu", of: "system", on: nil)
    s.setThreshold(.init(crit: 99), alert: "cpu", of: "system", on: "A")
    s.setThreshold(.init(warn: 90), alert: "disk", of: "system", on: "A")
    let a = s.alerts(p, on: "A"), b = s.alerts(p, on: "B")
    #expect(a[0].warn == 70 && a[0].crit == 99 && a[1].warn == 90, "A: all servers' warn, its own crit; disk by its metric")
    #expect(b[0].warn == 70 && b[0].crit == 95 && b[1].warn == 85 && s.alerts(p, on: nil)[0].warn == 70)
    #expect(s.threshold("cpu", of: "system", on: "A") == .init(crit: 99) && s.threshold("cpu", of: "system", on: nil) == .init(warn: 70))
    let back = try JSONDecoder().decode(ToolServers.self, from: try JSONEncoder().encode(s))
    #expect(back.alerts(p, on: "A") == a)
    s.setThreshold(.init(), alert: "cpu", of: "system", on: nil)
    s.setThreshold(.init(), alert: "cpu", of: "system", on: "A")
    s.setThreshold(.init(), alert: "disk", of: "system", on: "A")
    #expect(s == ToolServers(), "emptied: nothing kept")
}
