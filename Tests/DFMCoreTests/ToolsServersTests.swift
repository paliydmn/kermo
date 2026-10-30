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
