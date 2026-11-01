import Foundation
import Testing
@testable import DFMCore

// Tools presets, schema 1: the built-ins load clean, every check of protocol §14 fires, and the field table and the
// typed model describe the same fields.

private let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/tools")

/// A preset file `t.json` from the fields given, as one JSON object.
private func check(_ json: String, file: String = "t.json", hasScript: @escaping (String) -> Bool = { _ in true },
                   hasSymbol: @escaping (String) -> Bool = { _ in true }) -> (preset: ToolPreset?, problems: [ToolProblem]) {
    ToolSchema.validate(Data(json.utf8), file: file, hasScript: hasScript, hasSymbol: hasSymbol)
}

private let head = #""schema": 1, "id": "t", "title": "T""#

@Test func theBuiltInPresetsLoadWithoutAProblem() throws {
    let dir = ToolPreset.builtInFolder
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
    #expect(files == ["dpl.json", "fail2ban.json", "sites.json", "sysinfo.json", "system.json", "ufw.json"])
    for f in files {
        let (preset, problems) = ToolSchema.validate(try Data(contentsOf: dir.appendingPathComponent(f)), file: f) {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        #expect(preset?.id == (f as NSString).deletingPathExtension, "\(f)")
        #expect(problems.isEmpty, "\(f): \(problems)")
    }
}

/// restic: a tool someone made with New Tool…, with vars, a poll and an age metric.
@Test func anOwnPresetLoads() throws {
    let (preset, problems) = ToolSchema.validate(try Data(contentsOf: fixtures.appendingPathComponent("restic.json")), file: "restic.json")
    #expect(problems.isEmpty)
    #expect(preset?.vars?["repo"]?.info.ask == true)
    #expect(preset?.metrics?["age"]?.calc == "age")
    #expect(preset?.actions?[1].run.command == .many(["restic restore {short_id} --target {target}", "--include {path}"]))
}

struct Case: CustomTestStringConvertible, Sendable {
    let name: String, json: String, says: String
    var level = ToolProblem.Level.error
    var testDescription: String { name }
}

/// Each error of §14 stops the tool; each warning lets it load.
@Test(arguments: [
    Case(name: "invalid JSON", json: "{\n \"schema\": 1,\n \"id\": \"t\"\n \"title\": \"T\" }", says: "invalid JSON"),
    Case(name: "a missing field", json: #"{ "schema": 1, "id": "t" }"#, says: "“title” is missing"),
    Case(name: "an unknown field", json: "{ \(head), \"colour\": \"red\" }", says: "colour: unknown field"),
    Case(name: "a wrong type", json: "{ \(head), \"list\": { \"command\": \"x\", \"every\": \"5\" } }", says: "list.every: should be a number"),
    Case(name: "a value not allowed", json: "{ \(head), \"where\": \"cloud\" }", says: "where: should be one of “server”, “mac”"),
    Case(name: "a schema too new", json: #"{ "schema": 2, "id": "t", "title": "T", "anything": 1 }"#, says: "schema 2 needs a newer Kermo"),
    Case(name: "id isn't the file's name", json: #"{ "schema": 1, "id": "other", "title": "T" }"#, says: "isn't the file's name"),
    Case(name: "id with capitals", json: #"{ "schema": 1, "id": "T", "title": "T" }"#, says: "only a–z, 0–9 and “-”"),
    Case(name: "an action id twice", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"command\": \"x\" }, { \"id\": \"a\", \"command\": \"y\" } ] }",
         says: "“a” is another action's id too"),
    Case(name: "a key twice in a list", json: "{ \(head), \"list\": { \"command\": \"x\" }, \"actions\": [ { \"id\": \"a\", \"key\": \"f8\", \"command\": \"x\" } ], "
         + "\"toolActions\": [ { \"id\": \"b\", \"key\": \"f8\", \"command\": \"y\" } ] }", says: "“f8” is another action's key"),
    Case(name: "a Run without a source", json: "{ \(head), \"requires\": { \"sudo\": true } }", says: "requires: needs a command, script"),
    Case(name: "a Run with two sources", json: "{ \(head), \"list\": { \"command\": \"x\", \"script\": \"x.sh\" } }", says: "one source, not command and script"),
    Case(name: "an action that does nothing", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\" } ] }", says: "needs a command or script, or edit"),
    Case(name: "a script with a slash", json: "{ \(head), \"list\": { \"script\": \"../x.sh\" } }", says: "no “/”"),
    Case(name: "a script that isn't there", json: "{ \(head), \"list\": { \"script\": \"gone.sh\" } }", says: "gone.sh isn't next to the preset"),
    Case(name: "a broken regex", json: "{ \(head), \"list\": { \"command\": \"x\", \"format\": \"regex\", \"pattern\": \"(?<a>\" } }", says: "a broken regular expression"),
    Case(name: "a group the template wants", json: "{ \(head), \"list\": { \"command\": \"x\", \"format\": \"regex\", \"pattern\": \"(?<a>.+)\", \"title\": \"{b}\" } }",
         says: "{b}: the list's pattern has no group “b”"),
    Case(name: "↩ on a dangerous action", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"key\": \"return\", \"dangerous\": true, \"command\": \"x\" } ] }",
         says: "↩ never runs an action that asks first"),
    Case(name: "↩ on a confirmed action", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"key\": \"return\", \"confirm\": true, \"command\": \"x\" } ] }",
         says: "↩ never runs an action that asks first"),
    Case(name: "a display format in a command", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"command\": \"echo {server:bytes}\" } ] }",
         says: "a display format can't be in a command"),
    Case(name: "an unknown display format", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"command\": \"x\", \"done\": \"{server:huge}\" } ] }",
         says: "“huge” isn't a display format"),
    Case(name: "a secret to a terminal", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"command\": \"x {p}\", \"output\": \"terminal\", "
         + "\"inputs\": [ { \"name\": \"p\", \"type\": \"secret\" } ] } ] }", says: "a secret can't go to a terminal"),
    Case(name: "a long job on this Mac", json: "{ \(head), \"where\": \"mac\", \"toolActions\": [ { \"id\": \"a\", \"command\": \"x\", \"long\": true } ] }",
         says: "a long job runs on the server"),
    Case(name: "verify without a list", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"command\": \"x\", \"verify\": true } ] }",
         says: "verify reads a list again"),
    Case(name: "verify on a dashboard's rows", json: "{ \(head), \"actions\": [ { \"id\": \"a\", \"rows\": \"procs\", \"command\": \"x\", \"verify\": true } ] }",
         says: "verify reads a list again"),
    Case(name: "rate on a count", json: "{ \(head), \"metrics\": { \"m\": { \"rows\": \"list\", \"count\": \"state\", \"calc\": \"rate\" } } }",
         says: "rate works on a number at path"),
    Case(name: "on_alert in a preset", json: "{ \(head), \"on_alert\": \"curl …\" }", says: "on_alert is a user setting"),
    Case(name: "a list without its output", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"command\": \"x\", \"list\": { \"format\": \"lines\" } } ] }",
         says: "has output “list”"),
    Case(name: "a tool's level with nothing to repeat", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"command\": \"x\", \"output\": \"list\" } ] }",
         says: "no list it's on to repeat"),
    Case(name: "a dashboard row's level with nothing to repeat", json: "{ \(head), \"list\": { \"command\": \"x\" }, \"actions\": [ { \"id\": \"a\", \"rows\": \"disks\", \"command\": \"x\", \"output\": \"list\" } ] }",
         says: "no list it's on to repeat"),
    Case(name: "a repeated level with actions", json: "{ \(head), \"list\": { \"command\": \"x\" }, \"actions\": [ { \"id\": \"a\", \"command\": \"x\", \"output\": \"list\", "
         + "\"actions\": [ { \"id\": \"b\", \"command\": \"x\" } ] } ] }", says: "has that level's actions"),
    Case(name: "a level on marked rows", json: "{ \(head), \"list\": { \"command\": \"x\" }, \"actions\": [ { \"id\": \"a\", \"command\": \"x\", \"output\": \"list\", \"multi\": true } ] }",
         says: "a level is one row's"),
    Case(name: "a secret into a level", json: "{ \(head), \"list\": { \"command\": \"x\" }, \"actions\": [ { \"id\": \"a\", \"command\": \"x {p}\", \"output\": \"list\", "
         + "\"inputs\": [ { \"name\": \"p\", \"type\": \"secret\" } ] } ] }", says: "a secret doesn't go into a level's run"),
    Case(name: "a folder on a short action", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"command\": \"x {f}\", "
         + "\"inputs\": [ { \"name\": \"f\", \"type\": \"folder\" } ] } ] }", says: "only a long action takes one"),
    Case(name: "remember on a text", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"command\": \"x {f}\", "
         + "\"inputs\": [ { \"name\": \"f\", \"type\": \"text\", \"remember\": true } ] } ] }", says: "only a folder or a file is remembered"),
    Case(name: "a metric that isn't there", json: "{ \(head), \"alerts\": [ { \"metric\": \"cpu\", \"warn\": 1 } ] }", says: "“cpu” isn't one of the metrics"),
    Case(name: "a bad env name", json: "{ \(head), \"env\": { \"KERMO_X\": \"1\" } }", says: "an env name is A–Z"),
    Case(name: "a bad key", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"key\": \"hyper+x\", \"command\": \"x\" } ] }", says: "isn't a key"),
    Case(name: "{x} in single quotes", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"command\": \"echo '{server}'\" } ] }",
         says: "arrives as the literal text", level: .warning),
    Case(name: "{x} in double quotes", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"command\": \"echo \\\"{server}\\\"\" } ] }",
         says: "leave the quoting to Kermo", level: .warning),
    Case(name: "a placeholder nothing fills", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"command\": \"echo {nope}\" } ] }",
         says: "{nope}: nothing gives it a value", level: .warning),
    Case(name: "a name hiding Kermo's", json: "{ \(head), \"vars\": { \"host\": { \"default\": \"x\" } } }", says: "hides Kermo's own {host}", level: .warning),
    Case(name: "rm in a readonly action", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"readonly\": true, \"command\": \"rm -f /tmp/x\" } ] }",
         says: "a readonly action that runs “rm”", level: .warning),
    Case(name: "> in a readonly action", json: "{ \(head), \"toolActions\": [ { \"id\": \"a\", \"readonly\": true, \"command\": \"ls 2>/dev/null > /tmp/x\" } ] }",
         says: "writes to a file", level: .warning),
    Case(name: "sudo without about", json: "{ \(head), \"sudo\": true, \"command\": \"id\" }", says: "runs as root but has no “about”", level: .warning),
])
func everyCheckOfTheProtocol(_ c: Case) {
    let (preset, problems) = check(c.json, hasScript: { $0 != "gone.sh" })
    #expect(problems.contains { $0.level == c.level && $0.text.contains(c.says) }, "\(problems)")
    #expect((preset != nil) == (c.level == .warning), "\(problems)")
}

@Test func anUnknownSymbolIsAWarning() {
    let (preset, problems) = check("{ \(head), \"icon\": \"no.such.symbol\" }", hasSymbol: { _ in false })
    #expect(preset != nil)
    #expect(problems.map(\.text) == ["icon: this macOS has no SF Symbol “no.such.symbol”: Kermo shows a wrench"])
}

/// Same-key variants (§10.3): each with its own `requires`, the first that passes shows.
@Test func sameKeyVariantsWithTheirOwnRequires() {
    let (preset, problems) = check("""
        { \(head), "toolActions": [
          { "id": "up-apt", "title": "Upgrade", "key": "cmd+u", "requires": "command -v apt-get", "command": "apt-get -y upgrade" },
          { "id": "up-dnf", "title": "Upgrade", "key": "cmd+u", "requires": "command -v dnf", "command": "dnf -y upgrade" } ] }
        """)
    #expect(problems.isEmpty)
    #expect(preset?.toolActions?.count == 2)
}

/// A problem names its line; one inside an action names the action's line.
@Test func problemsSayTheirLine() {
    let json = """
        {
          "schema": 1, "id": "t", "title": "T",
          "toolActions": [
            { "id": "a", "command": "x" },
            {
              "id": "b",
              "command": "y",
              "colour": "red"
            }
          ]
        }
        """
    let (_, problems) = check(json)
    #expect(problems == [ToolProblem(line: 8, text: "toolActions[1].colour: unknown field", level: .error)])
    #expect(ToolSchema.lineMap(Data(json.utf8))["toolActions[1]"] == 5)
    #expect(check("{\n\"schema\": 1,\n\"id\": \"t\",\n\"title\": 5\n}").problems.first?.line == 4)
    #expect(check("{\n\"schema\": 1,\n\"id\": \"t\"\n\"title\": \"T\" }").problems.first?.line == 4)   // the missing comma
}

/// `notes` and `$schema` are read and ignored: the author's remarks and an editor's completion.
@Test func notesAndSchemaURLAreIgnored() {
    let (preset, problems) = check("{ \(head), \"$schema\": \"https://example.com/tools.json\", \"notes\": [\"one\", \"two\"], \"command\": \"df -h\" }")
    #expect(problems.isEmpty)
    #expect(preset?.notes == .many(["one", "two"]))
    #expect(preset?.schemaURL == "https://example.com/tools.json")
}

/// A sample with every field of the table, decoded into `ToolPreset` and encoded back: a field the table has and the
/// model doesn't is lost on the way, and this fails.
@Test func theModelHasEveryFieldOfTheTable() throws {
    // An object inside itself (an action's actions, a block's row) is left out there.
    func sample(_ f: ToolSchema.Field, _ inside: Set<String>) -> Any? {
        switch f {
        case .text, .strings: "x"
        case .number, .duration: 2
        case .integer: 1
        case .bool, .scalar: true
        case .oneOf(let all): all.first { !$0.isEmpty }!
        case .list(let item): sample(item, inside).map { [$0] }
        case .map(let item): sample(item, inside).map { ["k": $0] }
        case .runOrText: sample(.object("run"), inside)
        case .column: ["field": "x", "title": "x", "width": 1]
        case .object(let name):
            inside.contains(name) ? nil : ToolSchema.objects[name]!.fields.compactMapValues { sample($0, inside.union([name])) }
        }
    }
    var top = sample(.object("preset"), []) as! [String: Any]
    top["schema"] = 1
    let data = try JSONSerialization.data(withJSONObject: top)
    let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONDecoder().decode(ToolPreset.self, from: data)))
    func paths(_ v: Any, _ at: String) -> Set<String> {
        if let o = v as? [String: Any] { return o.reduce(into: Set([at])) { $0.formUnion(paths($1.value, at + "." + $1.key)) } }
        if let a = v as? [Any] { return a.reduce(into: Set([at])) { $0.formUnion(paths($1, at + "[]")) } }
        return [at]
    }
    let lost = paths(top, "").subtracting(paths(back, ""))
    #expect(lost.isEmpty, "\(lost.sorted())")
}

@Test func theJSONSchemaHasEveryObject() throws {
    let schema = try #require(JSONSerialization.jsonObject(with: ToolSchema.jsonSchema()) as? [String: Any])
    let defs = try #require(schema["$defs"] as? [String: [String: Any]])
    #expect(Set(defs.keys) == Set(ToolSchema.objects.keys))
    let top = try #require(defs["preset"]?["properties"] as? [String: Any])
    #expect(top.keys.contains("toolActions") && top.keys.contains("$schema"))
    #expect(defs["preset"]?["additionalProperties"] as? Bool == false)
}

/// `watch.every` is a second or more: `sleep 0` would spin on the server, and a tick divides by it.
@Test func watchEveryIsASecondOrMore() {
    let json = #"{ "schema": 1, "id": "x", "title": "X", "watch": { "every": 0.5 }, "stream": { "command": "cat", "format": "jsonl" } }"#
    let found = ToolSchema.validate(Data(json.utf8), file: "x.json")
    #expect(found.preset == nil && found.problems.contains { $0.text == "watch.every: a second or more" }, "\(found.problems)")
    #expect(ToolSchema.validate(Data(json.replacingOccurrences(of: "0.5", with: "1").utf8), file: "x.json").preset != nil)
}

/// D-155: a row's action with `output: "list"` and no list of its own repeats the level it's on — the tool's list, or
/// one level down the action's above it (System's Biggest Folders Inside).
@Test func aLevelWithNoListOfItsOwnRepeatsTheOneItsOn() {
    let row = check("{ \(head), \"list\": { \"command\": \"x\", \"format\": \"lines\", \"key\": \"{line}\" }, \"actions\": [ { \"id\": \"a\", \"command\": \"ls {line}\", \"output\": \"list\" } ] }")
    #expect(row.problems.isEmpty && row.preset != nil, "\(row.problems)")
    let underTool = check("{ \(head), \"toolActions\": [ { \"id\": \"t\", \"command\": \"x\", \"output\": \"list\", \"list\": { \"format\": \"lines\", \"key\": \"{line}\" }, "
                          + "\"actions\": [ { \"id\": \"a\", \"command\": \"ls {line}\", \"output\": \"list\" }, { \"id\": \"v\", \"command\": \"rm {line}\", \"verify\": true } ] } ] }")
    #expect(underTool.problems.isEmpty, "a tool action's level is a list: its rows repeat it and verify — \(underTool.problems)")
    let system = ToolSchema.validate(try! Data(contentsOf: ToolPreset.builtInFolder.appendingPathComponent("system.json")), file: "system.json") { _ in true }
    let inside = system.preset?.actions?.first { $0.spec.id == "biggest" }?.spec.actions?.first { $0.spec.id == "inside" }
    #expect(system.problems.isEmpty && inside?.spec.output == .list && inside?.spec.list == nil && inside?.spec.actions == nil)
}
