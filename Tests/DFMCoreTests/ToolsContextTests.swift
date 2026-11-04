import Foundation
import Testing
@testable import DFMCore

// A tool in Kermo's own places (protocol §11): which server files its `context` and `validators` take, the names they
// give, and a validator as the check a save runs — its values as variables, never text in the command.

private func tool(_ json: String) throws -> ToolPreset {
    let id = try #require(json.firstMatch(of: /"id": "([a-z0-9-]+)"/)?.1)
    return try #require(ToolSchema.validate(Data(("{ \"schema\": 1, \"title\": \"T\", " + json + " }").utf8), file: "\(id).json").preset)
}

private let dpl = try! #require(ToolSchema.validate(try Data(contentsOf: ToolPreset.builtInFolder.appendingPathComponent("dpl.json")), file: "dpl.json").preset)
private func base(_ b: String) -> ToolTemplate.Scope { ToolTemplate.Scope(vars: ["base": .string(b)]) }

@Test func aFileGlobTakesFilesInOneFolder() throws {
    let names = try #require(ToolPreset.fileNames("/srv/dpl/conf/web.v2.yaml", glob: "{base}/conf/*.yaml", base("/srv/dpl")))
    #expect(names == ["file": "/srv/dpl/conf/web.v2.yaml", "dir": "/srv/dpl/conf", "stem": "web.v2"])
    #expect(ToolPreset.fileNames("/srv/dpl/conf/old/web.yaml", glob: "{base}/conf/*.yaml", base("/srv/dpl")) == nil, "* stays in its folder")
    #expect(ToolPreset.fileNames("/opt/dpl/conf/web.yaml", glob: "{base}/conf/*.yaml", base("/srv/dpl")) == nil)
    #expect(ToolPreset.mayTake("/srv/dpl/conf/web.yaml", glob: "{base}/conf/*.yaml"), "a var could be any folder")
    #expect(!ToolPreset.mayTake("/etc/nginx/nginx.conf", glob: "{base}/conf/*.yaml"))
    #expect(dpl.fileGlobs == ["{base}/conf/*.yaml", "{base}/conf/*.yaml"])
}

/// dpl's validator: `dpl check` on the file's stem, once the file is in place, as root (the tool's `sudo`).
@Test func dplsValidatorIsASaveCheck() throws {
    let c = try #require(dpl.check(for: "/srv/dpl/conf/web.yaml", base("/srv/dpl")))
    #expect(c.match == "/srv/dpl/conf/web.yaml" && c.after && c.needsRoot && c.reload == nil)
    #expect(c.check == #"dpl check "$K_stem""# && c.setup == "K_stem=web")
    #expect(ConfigCheck.program(c.check!) == "dpl")
    #expect(dpl.check(for: "/srv/dpl/conf/web.yaml", base("/opt/dpl")) == nil && dpl.check(for: "/srv/dpl/conf/x/web.yaml", base("/srv/dpl")) == nil)
    #expect(dpl.check(for: "/srv/dpl/conf/-web.yaml", base("/srv/dpl")) == nil, "a value that begins with - gives no check (§3.2 rule 5)")
    let json = try JSONEncoder().encode(c)
    #expect(!String(decoding: json, as: UTF8.self).contains("setup"), "not a validators.json field")
}

/// A `before` validator runs on the new text next to the file: `{file}` is that one, `{stem}` and `{dir}` the file's;
/// a name with a space, a quote, `$(…)`, `;` and `%f` arrives as one word, the tool's `env` with it.
@Test func aToolsCheckGetsItsValuesAsVariables() throws {
    let p = try tool(#""id": "names", "env": { "WHERE": "{dir}" }, "validators": [ { "path": "{root}/*.conf", "check": "printf '%s|%s|%s|%s\\n' {stem} {file} {dir} \"$WHERE\"" } ]"#)
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-ctx-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    let file = d + "/a b;$(touch x)'%f.conf"
    try Data("old\n".utf8).write(to: URL(fileURLWithPath: file))
    try Data("new\n".utf8).write(to: URL(fileURLWithPath: d + "/l"))
    let rule = try #require(p.check(for: file, ToolTemplate.Scope(vars: ["root": .string(d)])))
    #expect(!rule.after && !rule.needsRoot)
    let c = try SFTPClient(.local())
    defer { c.close() }
    let (_, outcome) = try c.save(d + "/l", to: file, baseline: nil, rule: rule)
    guard case .passed(let said)? = outcome else { Issue.record("\(String(describing: outcome))"); return }
    let parts = said.trimmingCharacters(in: .newlines).components(separatedBy: "|")
    #expect(parts.count == 4 && parts[0] == "a b;$(touch x)'%f" && parts[1].hasPrefix(d + "/.dfm-partial-") && parts[2] == d && parts[3] == d, "\(said)")
    #expect(!FileManager.default.fileExists(atPath: d + "/x") && FileManager.default.contents(atPath: file) == Data("new\n".utf8))
}

@Test func contextAndAcceptsAreChecked() throws {
    func errors(_ json: String) -> [String] {
        let id = json.firstMatch(of: /"id": "([a-z0-9-]+)"/)!.1
        return ToolSchema.validate(Data(("{ \"schema\": 1, \"title\": \"T\", " + json + " }").utf8), file: "\(id).json").problems.filter { $0.level == .error }.map(\.text)
    }
    #expect(errors(#""id": "c", "list": { "command": "ls", "key": "{line}" }, "actions": [ { "id": "a", "command": "x {line}" } ], "context": [ { "path": "/x/*", "actions": ["a"] } ]"#)
        .contains { $0.contains("row") }, "a context names its row")
    #expect(errors(#""id": "s", "toolActions": [ { "id": "grep", "accepts": "text", "command": "grep -i error" } ]"#).isEmpty)
    #expect(errors(#""id": "s", "list": { "command": "ls", "key": "{line}" }, "actions": [ { "id": "a", "accepts": "text", "command": "cat" } ]"#)
        .contains { $0.contains("no row") })
    #expect(errors(#""id": "s", "toolActions": [ { "id": "a", "accepts": "text", "edit": "/x" } ]"#).contains { $0.contains("stdin") })
    for bad in [#""output": "follow""#, #""output": "terminal""#, #""long": true"#] {
        #expect(errors(#""id": "s", "toolActions": [ { "id": "a", "accepts": "text", "command": "cat", "#  + bad + " } ]").contains { $0.contains("line or in a window") }, "\(bad)")
    }
}
