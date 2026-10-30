import Foundation
import Testing
@testable import DFMCore

// Loading presets (protocol §12): built-ins from the app, yours from your folder only if they're yours and nobody
// else can change them, yours overriding a built-in's id; trust by the hash of the file and its scripts.

private func folder(_ files: [String: String]) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kermo-tools-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, text) in files {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
        chmod(dir.appendingPathComponent(name).path, 0o644)
    }
    return dir
}

private let mine = #"{ "schema": 1, "id": "mine", "title": "Mine", "list": { "script": "mine.sh" } }"#

@Test func builtInsAndYours() throws {
    let dir = try folder(["mine.json": mine, "mine.sh": "echo a\n", "notes.txt": "not a preset"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let lib = ToolLibrary.load(own: dir)
    #expect(lib.problems.isEmpty, "\(lib.problems)")
    #expect(lib.tools.map(\.preset.id).sorted() == ["dpl", "fail2ban", "mine", "sites", "sysinfo", "system", "ufw"])
    let t = try #require(lib.tools.first { $0.preset.id == "mine" })
    #expect(!t.builtIn && t.scripts == ["mine.sh": "echo a\n"])
    #expect(try #require(lib.tools.first { $0.preset.id == "system" }).scripts.keys.sorted() == ["system.stream.sh"])
    #expect(try #require(lib.tools.first { $0.preset.id == "sysinfo" }).scripts.keys.sorted() == ["sysinfo.report.sh", "sysinfo.traffic.sh"])
}

/// As mc does: a file someone else could change isn't read — nor one whose script could be.
@Test func onlyYourOwnFilesThatNobodyElseCanChange() throws {
    let dir = try folder(["mine.json": mine, "mine.sh": "echo a\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    chmod(dir.appendingPathComponent("mine.json").path, 0o664)
    #expect(ToolLibrary.load(own: dir).problems == ["tools/mine.json: not loaded: its group or others can change it (chmod go-w)"])
    chmod(dir.appendingPathComponent("mine.json").path, 0o644)
    chmod(dir.appendingPathComponent("mine.sh").path, 0o646)
    #expect(ToolLibrary.load(own: dir).problems == ["tools/mine.json: not loaded: mine.sh: its group or others can change it (chmod go-w)"])
    chmod(dir.appendingPathComponent("mine.sh").path, 0o644)
    let other = ToolLibrary.load(own: dir, uid: getuid() + 1)   // as if another user owned them
    #expect(other.problems == ["tools/mine.json: not loaded: it belongs to another user"])
    #expect(!other.tools.contains { $0.preset.id == "mine" })
    try FileManager.default.removeItem(at: dir.appendingPathComponent("mine.sh"))
    #expect(ToolLibrary.load(own: dir).problems == ["tools/mine.json: line 1: list.script: mine.sh isn't next to the preset"])
}

@Test func yoursOverridesABuiltInUnlessItHasAnError() throws {
    let good = #"{ "schema": 1, "id": "ufw", "title": "My Firewall", "command": "ufw status" }"#
    let dir = try folder(["ufw.json": good])
    defer { try? FileManager.default.removeItem(at: dir) }
    let lib = ToolLibrary.load(own: dir)
    #expect(lib.tools.filter { $0.preset.id == "ufw" }.map(\.preset.title) == ["My Firewall"])
    try Data(#"{ "schema": 1, "id": "ufw", "title": "Broken", "colour": "red" }"#.utf8).write(to: dir.appendingPathComponent("ufw.json"))
    let broken = ToolLibrary.load(own: dir)
    #expect(broken.tools.filter { $0.preset.id == "ufw" }.map(\.builtIn) == [true])   // the built-in stays
    #expect(broken.problems == ["tools/ufw.json: line 1: colour: unknown field"])
}

/// Trust goes by the file and its scripts: a change to either asks again; built-ins are trusted.
@Test func trustByTheHashOfTheFileAndItsScripts() throws {
    let dir = try folder(["mine.json": mine, "mine.sh": "echo a\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    var trust = ToolTrust()
    let first = ToolLibrary.load(own: dir)
    #expect(first.trusted(trust).map(\.preset.id).sorted() == ["dpl", "fail2ban", "sites", "sysinfo", "system", "ufw"])   // yours: not yet
    trust.trust(first.tools.first { $0.preset.id == "mine" }!)
    #expect(ToolLibrary.load(own: dir).trusted(trust).contains { $0.preset.id == "mine" })
    try Data("echo b\n".utf8).write(to: dir.appendingPathComponent("mine.sh"))
    let changed = ToolLibrary.load(own: dir)
    #expect(!changed.trusted(trust).contains { $0.preset.id == "mine" })
    #expect(changed.tools.first { $0.preset.id == "mine" }!.hash != first.tools.first { $0.preset.id == "mine" }!.hash)
    let back = try JSONDecoder().decode(ToolTrust.self, from: JSONEncoder().encode(trust))   // tools/trust.json
    #expect(back == trust)
    // An untrusted tool runs nothing, not even its requires: only trusted tools reach the batch.
    let req = #"{ "schema": 1, "id": "mine", "title": "Mine", "requires": "command -v x", "list": { "script": "mine.sh" } }"#
    try Data(req.utf8).write(to: dir.appendingPathComponent("mine.json"))
    #expect(!ToolBatch.items(ToolLibrary.load(own: dir).trusted(trust).map(\.preset)).contains { $0.tool == "mine" })
}

@Test func everyScriptAPresetNames() throws {
    let json = #"""
        { "schema": 1, "id": "s", "title": "S", "requires": { "script": "r.sh" }, "header": { "script": "h.sh" },
          "vars": { "v": { "script": "v.sh" } }, "list": { "script": "l.sh", "header": { "script": "lh.sh" } },
          "stream": { "script": "st.sh", "format": "jsonl" }, "poll": { "script": "p.sh", "format": "json" },
          "actions": [ { "id": "a", "script": "a.sh", "requires": { "script": "ar.sh" },
                         "inputs": [ { "name": "x", "type": "choice-from", "script": "i.sh" } ] } ] }
        """#
    let p = try #require(ToolSchema.validate(Data(json.utf8), file: "s.json").preset)
    #expect(p.scriptNames == ["r.sh", "h.sh", "v.sh", "l.sh", "lh.sh", "st.sh", "p.sh", "a.sh", "ar.sh", "i.sh"])
}
