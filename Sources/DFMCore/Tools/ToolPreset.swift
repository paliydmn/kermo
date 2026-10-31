import Foundation

// A Tools preset (schema 1) as read from its JSON file: every field of the protocol, including the ones later Tools
// PRs bring to life. `ToolSchema` checks a file before it's decoded into these; here they're only typed.
// Parts shared by several places (a Run, a Parse) are decoded from the same JSON object as the rest of it.

/// A JSON value from a preset or a record: what a template shows and a Parse yields.
public enum ToolValue: Sendable, Hashable, Codable {
    case string(String), number(Double), bool(Bool), array([ToolValue]), object([String: ToolValue]), null

    public init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([ToolValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: ToolValue].self)) }
    }

    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    /// From JSONSerialization's objects (NSNumber's bools stay bools).
    public init(any v: Any) {
        switch v {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(ToolValue.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(ToolValue.init(any:)))
        default: self = .null
        }
    }

    /// As a template shows it: a whole number without ".0", an array as "a, b, c", nothing for null.
    public var text: String {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): b ? "true" : "false"
        case .array(let a): a.map(\.text).joined(separator: ", ")
        case .object(let o): (try? String(decoding: JSONEncoder.sorted.encode(o), as: UTF8.self)) ?? ""
        case .null: ""
        }
    }

    /// A number, or a string that is one (values from text formats are strings).
    public var number: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// `failure.stage`: a field of a field.
    public subscript(path: String) -> ToolValue? {
        var v: ToolValue? = self
        for part in path.split(separator: ".", omittingEmptySubsequences: false) {
            guard case .object(let o)? = v else { return nil }
            v = o[String(part)]
        }
        return v
    }
}

extension JSONEncoder {
    static let sorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

/// A string, or an array of them: a command's parts, `subtitle`'s, `notes`, a dashboard `stat` of two metrics.
public enum ToolStrings: Sendable, Hashable, Codable {
    case one(String), many([String])

    public init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .one(s) } else { self = .many(try c.decode([String].self)) }
    }

    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .one(let s): try c.encode(s)
        case .many(let a): try c.encode(a)
        }
    }

    public var all: [String] { switch self { case .one(let s): [s]; case .many(let a): a } }
}

public enum ToolWhere: String, Sendable, Codable { case server, mac }

public enum ToolFormat: String, Sendable, Codable, CaseIterable {
    case text, lines, json, jsonl, tsv, csv, table, regex, prometheus, nagios
}

public enum ToolOutput: String, Sendable, Codable, CaseIterable { case line, window, follow, terminal, silent, list }

/// Run (protocol §3.1): where output comes from and how it runs. A plain string in `requires` and `header` is its command.
public struct ToolRun: Sendable, Hashable, Codable {
    public var command: ToolStrings?
    public var script: String?
    public var files: String?
    public var http: ToolHTTP?
    public var sudo: Bool?
    public var `where`: ToolWhere?
    public var env: [String: String]?
    public var timeout: Double?
    public var exitOk: [Int]?

    public init(command: ToolStrings? = nil, script: String? = nil, files: String? = nil, http: ToolHTTP? = nil, sudo: Bool? = nil,
                where: ToolWhere? = nil, env: [String: String]? = nil, timeout: Double? = nil, exitOk: [Int]? = nil) {
        (self.command, self.script, self.files, self.http, self.sudo) = (command, script, files, http, sudo)
        (self.where, self.env, self.timeout, self.exitOk) = (`where`, env, timeout, exitOk)
    }

    private enum CodingKeys: String, CodingKey { case command, script, files, http, sudo, `where`, env, timeout, exitOk }

    public init(from d: Decoder) throws {
        if let s = try? d.singleValueContainer().decode(String.self) { self.init(command: .one(s)); return }
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(command: try c.decodeIfPresent(ToolStrings.self, forKey: .command), script: try c.decodeIfPresent(String.self, forKey: .script),
                  files: try c.decodeIfPresent(String.self, forKey: .files), http: try c.decodeIfPresent(ToolHTTP.self, forKey: .http),
                  sudo: try c.decodeIfPresent(Bool.self, forKey: .sudo), where: try c.decodeIfPresent(ToolWhere.self, forKey: .where),
                  env: try c.decodeIfPresent([String: String].self, forKey: .env), timeout: try c.decodeIfPresent(Double.self, forKey: .timeout),
                  exitOk: try c.decodeIfPresent([Int].self, forKey: .exitOk))
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(script, forKey: .script)
        try c.encodeIfPresent(files, forKey: .files)
        try c.encodeIfPresent(http, forKey: .http)
        try c.encodeIfPresent(sudo, forKey: .sudo)
        try c.encodeIfPresent(self.where, forKey: .where)
        try c.encodeIfPresent(env, forKey: .env)
        try c.encodeIfPresent(timeout, forKey: .timeout)
        try c.encodeIfPresent(exitOk, forKey: .exitOk)
    }

    /// Its sources; a Run needs exactly one (`ToolSchema` says so).
    public var sources: [String] {
        [command.map { _ in "command" }, script.map { _ in "script" }, files.map { _ in "files" }, http.map { _ in "http" }].compactMap { $0 }
    }
}

/// Parse (protocol §4.1): how output becomes records.
public struct ToolParse: Sendable, Hashable, Codable {
    public var format: ToolFormat?
    public var rows: String?
    public var pattern: String?
    public var names: [String]?
    public var split: String?
    public var sort: String?
    public var limit: Int?

    public init(format: ToolFormat? = nil, rows: String? = nil, pattern: String? = nil, names: [String]? = nil, split: String? = nil,
                sort: String? = nil, limit: Int? = nil) {
        (self.format, self.rows, self.pattern, self.names, self.split, self.sort, self.limit) = (format, rows, pattern, names, split, sort, limit)
    }
}

/// A Run with a Parse: `stream`, `poll`.
public struct ToolSource: Sendable, Hashable, Codable {
    public var run: ToolRun
    public var parse: ToolParse
    public init(from d: Decoder) throws { (run, parse) = (try ToolRun(from: d), try ToolParse(from: d)) }
    public func encode(to e: Encoder) throws { try run.encode(to: e); try parse.encode(to: e) }
}

/// A list's state mark (§6.2): which values of `field` are which state.
public struct ToolStateMap: Sendable, Hashable, Codable {
    public var field: String
    public var ok, warn, bad, off, busy: [String]?
}

/// A panel column: "field:format", or an object.
public enum ToolColumn: Sendable, Hashable, Codable {
    case spec(String)
    case object(field: String, title: String?, width: Double?)

    private enum CodingKeys: String, CodingKey { case field, title, width }

    public init(from d: Decoder) throws {
        if let s = try? d.singleValueContainer().decode(String.self) { self = .spec(s); return }
        let c = try d.container(keyedBy: CodingKeys.self)
        self = .object(field: try c.decode(String.self, forKey: .field), title: try c.decodeIfPresent(String.self, forKey: .title),
                       width: try c.decodeIfPresent(Double.self, forKey: .width))
    }

    public func encode(to e: Encoder) throws {
        switch self {
        case .spec(let s):
            var c = e.singleValueContainer()
            try c.encode(s)
        case .object(let field, let title, let width):
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(field, forKey: .field)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(width, forKey: .width)
        }
    }

    /// The field it shows and its display format ("updated_at:ago" → updated_at, ago), in either form.
    public var field: (name: String, format: String?) {
        let s = switch self { case .spec(let s): s; case .object(let f, _, _): f }
        guard let i = s.firstIndex(of: ":") else { return (s, nil) }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    /// Its heading: the object's `title`, else the field's words ("inodes_pct" → "Inodes pct").
    public var title: String {
        if case .object(_, let t?, _) = self { return t }
        let words = field.name.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
    /// The object's `width`, if given.
    public var width: Double? { if case .object(_, _, let w) = self { w } else { nil } }
}

/// `list.also`: fields read from another file by regex.
public struct ToolAlso: Sendable, Hashable, Codable {
    public var files: String
    public var pattern: String
}

/// How a list's rows look (§6.2), apart from its Run and Parse.
public struct ToolListView: Sendable, Hashable, Codable {
    public var key, title, detail, empty: String?
    public var subtitle: ToolStrings?
    public var state: ToolStateMap?
    public var columns: [ToolColumn]?
    public var every: Double?
    public var header: ToolRun?
    public var name: String?
    public var also: ToolAlso?

    /// A dashboard table's view (§6.3): its columns and what names a row (`key`); none: the record itself.
    public init(columns: [ToolColumn]?, key: String? = nil) { (self.columns, self.key) = (columns, key) }
}

/// `list`, and an action's own list one level down (whose Run is the action's).
public struct ToolList: Sendable, Hashable, Codable {
    public var run: ToolRun
    public var parse: ToolParse
    public var view: ToolListView
    public init(from d: Decoder) throws { (run, parse, view) = (try ToolRun(from: d), try ToolParse(from: d), try ToolListView(from: d)) }
    public func encode(to e: Encoder) throws { try run.encode(to: e); try parse.encode(to: e); try view.encode(to: e) }
}

/// `vars.<name>` (§9): a per-server value, its default, or a Run whose first line is the value.
public struct ToolVar: Sendable, Hashable, Codable {
    public var run: ToolRun
    public var info: Info
    public struct Info: Sendable, Hashable, Codable {
        public var title, `default`, placeholder, pattern: String?
        public var ask: Bool?
    }
    public init(from d: Decoder) throws { (run, info) = (try ToolRun(from: d), try Info(from: d)) }
    public func encode(to e: Encoder) throws { try run.encode(to: e); try info.encode(to: e) }
}

public struct ToolVersion: Sendable, Hashable, Codable {
    public var command: String
    public var pattern: String
    public var tested: String?
    public var unknown: [String]?
}

/// `install` and `uninstall` (§10.6): commands by package manager, or a script, with prechecks.
public struct ToolInstall: Sendable, Hashable, Codable {
    public var apt, dnf, apk, pacman, zypper, brew: String?
    public var script: Script?
    public var precheck: [Precheck]?
    public var leaves: Leaves?
    public var docs, after: String?
    public var keeps: String?   // uninstall only
    public struct Script: Sendable, Hashable, Codable {
        public var url: String
        public var env: [String: String]?
        public var sha256: String?
    }
    public struct Precheck: Sendable, Hashable, Codable {
        public var title, command: String
        public var pattern, min: String?
    }
    public struct Leaves: Sendable, Hashable, Codable {
        public var services, paths: [String]?
        public var ports: [Int]?
        public var note: String?
    }
}

public struct ToolHTTP: Sendable, Hashable, Codable {
    public var urls: String
    public var method: String?
    public var timeout: Double?
}

public struct ToolWatch: Sendable, Hashable, Codable {
    public var every: Double
    public var down: Int?
}

/// A duration: "90s", "5m", "2h", "7d", or seconds.
public enum ToolDuration: Sendable, Hashable, Codable {
    case text(String), seconds(Double)

    public init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let n = try? c.decode(Double.self) { self = .seconds(n) } else { self = .text(try c.decode(String.self)) }
    }

    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .text(let s): try c.encode(s)
        case .seconds(let n): try c.encode(n)
        }
    }

    /// nil: not a duration.
    public var seconds: Double? {
        switch self {
        case .seconds(let n): return n
        case .text(let s):
            guard let unit = s.last, let n = Double(s.dropLast()) else { return Double(s) }
            return ["s": 1, "m": 60, "h": 3600, "d": 86400][unit].map { n * $0 }
        }
    }
}

public struct ToolMetric: Sendable, Hashable, Codable {
    public var title, path, unit, detail, rows, key, count, calc: String?
    public var max: Double?
}

public struct ToolAlert: Sendable, Hashable, Codable {
    public var id, metric: String?
    public var warn, crit: Double?
    public var below: Bool?
    public var `for`: Levels?
    public var checks: Int?
    public var message: String?
    public struct Levels: Sendable, Hashable, Codable { public var warn, crit: ToolDuration? }
}

public struct ToolEvent: Sendable, Hashable, Codable {
    public var id, path, rows, key, field, when, level, message, goto: String?
    public var value, from: ToolValue?
    public var `if`, unless: String?
}

public struct ToolSummary: Sendable, Hashable, Codable {
    public var metric: String
    public var `as`, of, label: String?
}

/// A dashboard block (§6.3): exactly one of `row`, `stat`, `charts`, `table`, `events`, `counts`, with its options.
public struct ToolBlock: Sendable, Hashable, Codable {
    public var row: [ToolBlock]?
    public var stat: ToolStrings?
    public var of, also: String?
    public var charts: [[String]]?
    public var range: [ToolDuration]?
    public var per, log: String?
    public var table, title, key: String?
    public var columns: [ToolColumn]?
    public var actions: [String]?
    public var events: Bool?
    public var counts: [Count]?
    public struct Count: Sendable, Hashable, Codable { public var rows, title: String; public var goto: String? }
}

public struct ToolContext: Sendable, Hashable, Codable {
    public var path: String
    public var row: String?
    public var actions: [String]
}

public struct ToolValidator: Sendable, Hashable, Codable {
    public var path, check: String
    public var when: String?
}

public struct ToolProgress: Sendable, Hashable, Codable {
    public var percent, fraction, pattern, text: String?
}

/// An input of an action's form (§7.4). A `choice-from` input's choices come from its own Run and Parse; there
/// `pattern` still checks the value, so the choices aren't read with `format: regex`.
public struct ToolInput: Sendable, Hashable, Codable {
    public var info: Info
    public var run: ToolRun
    public var parse: ToolParse
    public struct Info: Sendable, Hashable, Codable {
        public var name: String
        public var type: Kind
        public var title, placeholder, `default`, pattern, key: String?
        public var optional, remember: Bool?
        public var options: [String]?
    }
    public enum Kind: String, Sendable, Codable, CaseIterable { case text, secret, choice, choiceFrom = "choice-from", folder, file }
    public init(from d: Decoder) throws { (info, run, parse) = (try Info(from: d), try ToolRun(from: d), try ToolParse(from: d)) }
    public func encode(to e: Encoder) throws { try info.encode(to: e); try run.encode(to: e); try parse.encode(to: e) }
}

/// An action (§7), on a row or (in `toolActions`) on the tool.
public struct ToolAction: Sendable, Hashable, Codable {
    public var run: ToolRun
    public var spec: Spec
    public struct Spec: Sendable, Hashable, Codable {
        public var id: String
        public var title, key, message, rows, note, strip, done, save, edit, open, goto, accepts: String?
        public var readonly, confirm, dangerous, verify, multi, refresh, check, long: Bool?
        public var only: [String: [String]]?
        public var output: ToolOutput?
        public var requires: ToolRun?
        public var progress: ToolProgress?
        public var format: ToolFormat?
        public var inputs: [ToolInput]?
        public var list: ToolList?
        public var actions: [ToolAction]?
    }
    public init(from d: Decoder) throws { (run, spec) = (try ToolRun(from: d), try Spec(from: d)) }
    public func encode(to e: Encoder) throws { try run.encode(to: e); try spec.encode(to: e) }
    init(run: ToolRun, spec: Spec) { (self.run, self.spec) = (run, spec) }
}

public struct ToolPreset: Sendable, Hashable, Codable {
    public var schema: Int
    public var id: String
    public var title: String
    public var tool, about, icon, group, author, minKermo, primary: String?
    public var catalogVersion: Int?
    public var notes: ToolStrings?
    public var schemaURL: String?
    public var `where`: ToolWhere?
    public var sudo: Bool?
    public var env: [String: String]?
    public var vars: [String: ToolVar]?
    public var requires: ToolRun?
    public var version: ToolVersion?
    public var install, uninstall: ToolInstall?
    public var header: ToolRun?
    // A one-command tool (§1): its Run at the top.
    public var command: ToolStrings?
    public var script: String?
    public var output: ToolOutput?
    public var save, done: String?
    public var list: ToolList?
    public var actions, toolActions: [ToolAction]?
    public var stream, poll: ToolSource?
    public var http: ToolHTTP?
    public var watch: ToolWatch?
    public var metrics: [String: ToolMetric]?
    public var alerts: [ToolAlert]?
    public var events: [ToolEvent]?
    public var summary: [ToolSummary]?
    public var dashboard: [ToolBlock]?
    public var context: [ToolContext]?
    public var validators: [ToolValidator]?

    private enum CodingKeys: String, CodingKey {
        case schema, id, title, tool, about, icon, group, author, minKermo, primary, catalogVersion, notes, schemaURL = "$schema"
        case `where`, sudo, env, vars, requires, version, install, uninstall, header, command, script, output, save, done
        case list, actions, toolActions, stream, poll, http, watch, metrics, alerts, events, summary, dashboard, context, validators
    }

    /// Every action of the tool, at every level, with its path in the file ("actions", 4, "actions", 1).
    public var allActions: [(path: [ToolPath], action: ToolAction)] {
        func walk(_ list: [ToolAction]?, _ at: [ToolPath]) -> [([ToolPath], ToolAction)] {
            (list ?? []).enumerated().flatMap { i, a in [(at + [.index(i)], a)] + walk(a.spec.actions, at + [.index(i), .key("actions")]) }
        }
        return walk(actions, [.key("actions")]) + walk(toolActions, [.key("toolActions")])
    }

    /// Its stream or poll (§8.1): what watching runs.
    public var source: ToolSource? { stream ?? poll }
    /// Whether it can be watched, or live on a tab: a stream or a poll, and `watch` saying how often.
    public var watchable: Bool { watch != nil && source != nil }

    /// A one-command tool's (§1) command as an action — what its Tools ▸ item and its place row run; nil for others.
    public var commandAction: ToolAction? {
        guard command != nil || script != nil else { return nil }
        return ToolAction(run: ToolRun(command: command, script: script), spec: .init(id: "command", title: title, done: done, save: save, output: output ?? .window))
    }
}

/// A step of a path into a preset's JSON: a key or an array index.
public enum ToolPath: Sendable, Hashable, CustomStringConvertible {
    case key(String), index(Int)
    public var description: String { switch self { case .key(let k): k; case .index(let i): "[\(i)]" } }
}

extension ToolPreset {
    /// The built-in presets and their scripts, inside the app (`Resources/tools`).
    public static var builtInFolder: URL { Bundle.module.url(forResource: "tools", withExtension: nil)! }
}

extension ToolValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(floatLiteral v: Double) { self = .number(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
}
