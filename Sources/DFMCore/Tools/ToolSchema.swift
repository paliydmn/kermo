import Foundation

/// A problem in a preset file: its line (nil: the file as a whole), what's wrong, and whether it stops the tool from
/// loading (an error) or only shows (a warning).
public struct ToolProblem: Sendable, Hashable, CustomStringConvertible {
    public enum Level: String, Sendable { case error, warning }
    public var line: Int?
    public var text: String
    public var level: Level
    public init(line: Int?, text: String, level: Level) { (self.line, self.text, self.level) = (line, text, level) }
    public var description: String { (line.map { "line \($0): " } ?? "") + text }
}

/// Schema 1 of Tools presets (protocol §13) and the checks of §14. The field table here is the one description of the
/// schema: it checks files and becomes the JSON Schema `tools-lint --schema` prints. `ToolPreset` is the typed view,
/// decoded once a file passes; a test keeps the two the same.
public enum ToolSchema {
    public static let version = 1

    /// What a field holds.
    indirect enum Field: Sendable {
        case text(Text)                 // a string of this kind
        case strings(Text)              // a string or an array of them
        case number, integer, bool
        case oneOf([String])
        case list(Field)
        case map(Field)                 // names → values
        case object(String)             // one of `objects`
        case runOrText                  // a Run, or a string that is its command
        case duration                   // "5m" or seconds
        case scalar                     // a string, number or bool
        case column                     // "field:format" or { field, title, width }
    }

    /// The kinds of strings, by what's checked in them.
    enum Text: Sendable {
        case plain
        case command   // shell, with placeholders as variables
        case value     // an `env` value
        case path      // a path or glob template (SFTP, the editor, the panel)
        case display   // shown text, with display formats
        case regex, split, script, key, id, symbol
    }

    struct Object: Sendable {
        var fields: [String: Field]
        var required: [String] = []
    }

    static let run: [String: Field] = [
        "command": .strings(.command), "script": .text(.script), "files": .text(.path), "http": .object("http"), "sudo": .bool,
        "where": .oneOf(["server", "mac"]), "env": .map(.text(.value)), "timeout": .number, "exitOk": .list(.integer),
    ]
    static let parse: [String: Field] = [
        "format": .oneOf(ToolFormat.allCases.map(\.rawValue)), "rows": .text(.plain), "pattern": .text(.regex),
        "names": .list(.text(.plain)), "split": .text(.split), "sort": .text(.plain), "limit": .integer,
    ]
    static let view: [String: Field] = [
        "key": .text(.display), "title": .text(.display), "subtitle": .strings(.display), "detail": .text(.display),
        "state": .object("state"), "columns": .list(.column), "empty": .text(.display), "every": .number, "header": .runOrText,
        "name": .text(.plain), "also": .object("also"),
    ]
    static let install: [String: Field] = [
        "apt": .text(.command), "dnf": .text(.command), "apk": .text(.command), "pacman": .text(.command), "zypper": .text(.command),
        "brew": .text(.command), "script": .object("installScript"), "precheck": .list(.object("precheck")), "leaves": .object("leaves"),
        "docs": .text(.plain), "after": .text(.display),
    ]
    static let action: [String: Field] = [
        "id": .text(.id), "title": .text(.display), "key": .text(.key), "readonly": .bool, "confirm": .bool, "dangerous": .bool,
        "message": .text(.display), "verify": .bool, "only": .map(.list(.text(.plain))), "multi": .bool, "rows": .text(.plain),
        "refresh": .bool, "note": .text(.display), "strip": .oneOf(["cri"]), "output": .oneOf(ToolOutput.allCases.map(\.rawValue)),
        "done": .text(.display), "save": .text(.display), "requires": .runOrText, "edit": .text(.path), "open": .text(.path),
        "goto": .text(.display), "check": .bool, "accepts": .oneOf(["text"]), "long": .bool, "progress": .object("progress"),
        "format": .oneOf(ToolFormat.allCases.map(\.rawValue)), "inputs": .list(.object("input")), "list": .object("actionList"),
        "actions": .list(.object("action")),
    ]

    static let objects: [String: Object] = [
        "preset": Object(fields: [
            "schema": .integer, "id": .text(.id), "title": .text(.plain), "tool": .text(.plain), "about": .text(.plain),
            "icon": .text(.symbol), "group": .text(.plain), "author": .text(.plain), "catalogVersion": .integer, "minKermo": .text(.plain),
            "notes": .strings(.plain), "$schema": .text(.plain), "where": .oneOf(["server", "mac"]), "sudo": .bool,
            "env": .map(.text(.value)), "vars": .map(.object("var")), "requires": .runOrText, "version": .object("version"),
            "install": .object("install"), "uninstall": .object("uninstall"), "header": .runOrText, "command": .strings(.command),
            "script": .text(.script), "output": .oneOf(ToolOutput.allCases.map(\.rawValue)), "save": .text(.display),
            "done": .text(.display), "list": .object("list"), "actions": .list(.object("action")), "toolActions": .list(.object("action")),
            "primary": .text(.plain), "stream": .object("source"), "poll": .object("source"), "http": .object("http"),
            "watch": .object("watch"), "metrics": .map(.object("metric")), "alerts": .list(.object("alert")),
            "events": .list(.object("event")), "summary": .list(.object("summary")), "dashboard": .list(.object("block")),
            "context": .list(.object("context")), "validators": .list(.object("validator")),
        ], required: ["schema", "id", "title"]),
        "run": Object(fields: run),
        "source": Object(fields: run.merging(parse) { a, _ in a }),
        "list": Object(fields: run.merging(parse) { a, _ in a }.merging(view) { a, _ in a }),
        "actionList": Object(fields: parse.merging(view) { a, _ in a }),
        "var": Object(fields: run.merging(["title": .text(.plain), "default": .text(.display), "placeholder": .text(.plain),
                                           "pattern": .text(.regex), "ask": .bool]) { a, _ in a }),
        "version": Object(fields: ["command": .text(.command), "pattern": .text(.regex), "tested": .text(.plain),
                                   "unknown": .list(.text(.plain))], required: ["command", "pattern"]),
        "install": Object(fields: install),
        "uninstall": Object(fields: install.merging(["keeps": .text(.plain)]) { a, _ in a }),
        "installScript": Object(fields: ["url": .text(.plain), "env": .map(.text(.plain)), "sha256": .text(.plain)], required: ["url"]),
        "precheck": Object(fields: ["title": .text(.plain), "command": .text(.command), "pattern": .text(.regex), "min": .text(.plain)],
                           required: ["title", "command"]),
        "leaves": Object(fields: ["services": .list(.text(.plain)), "paths": .list(.text(.path)), "ports": .list(.integer),
                                  "note": .text(.plain)]),
        "http": Object(fields: ["urls": .oneOf(["server"]), "method": .oneOf(["GET", "HEAD"]), "timeout": .number], required: ["urls"]),
        "watch": Object(fields: ["every": .number, "down": .integer], required: ["every"]),
        "metric": Object(fields: ["title": .text(.plain), "path": .text(.plain), "unit": .oneOf(["", "%", "B", "B/s", "ms", "s", "h", "days", "/min"]),
                                  "max": .number, "detail": .text(.display), "rows": .text(.plain), "key": .text(.plain),
                                  "count": .oneOf(["state"]), "calc": .oneOf(["rate", "age"])]),
        "alert": Object(fields: ["id": .text(.plain), "metric": .text(.plain), "warn": .number, "crit": .number, "below": .bool,
                                 "for": .object("levels"), "checks": .integer, "message": .text(.display)], required: ["metric"]),
        "levels": Object(fields: ["warn": .duration, "crit": .duration]),
        "event": Object(fields: ["id": .text(.plain), "path": .text(.plain), "rows": .text(.plain), "key": .text(.plain),
                                 "field": .text(.plain), "when": .oneOf(["changed", "increased", "added", "left", "is"]),
                                 "value": .scalar, "from": .scalar, "if": .text(.plain), "unless": .text(.plain),
                                 "level": .oneOf(["info", "warning", "critical"]), "message": .text(.display), "goto": .text(.display)],
                        required: ["when"]),
        "summary": Object(fields: ["metric": .text(.plain), "as": .oneOf(["bar", "count", "text"]), "of": .oneOf(["max", "sum", "min", "avg"]),
                                   "label": .text(.display)], required: ["metric"]),
        "block": Object(fields: ["row": .list(.object("block")), "stat": .strings(.plain), "of": .oneOf(["max", "sum", "min", "avg"]),
                                 "also": .text(.plain), "charts": .list(.list(.text(.plain))), "range": .list(.duration),
                                 "per": .text(.plain), "log": .text(.plain), "table": .text(.plain), "title": .text(.plain), "key": .text(.display),
                                 "columns": .list(.column), "actions": .list(.text(.plain)), "events": .bool, "counts": .list(.object("count"))]),
        "count": Object(fields: ["rows": .text(.plain), "title": .text(.plain), "goto": .text(.display)], required: ["rows", "title"]),
        "context": Object(fields: ["path": .text(.path), "row": .text(.display), "actions": .list(.text(.plain))], required: ["path", "actions"]),
        "validator": Object(fields: ["path": .text(.path), "check": .text(.command), "when": .oneOf(["before", "after"])],
                            required: ["path", "check"]),
        "state": Object(fields: ["field": .text(.plain), "ok": .list(.text(.plain)), "warn": .list(.text(.plain)), "bad": .list(.text(.plain)),
                                 "off": .list(.text(.plain)), "busy": .list(.text(.plain))], required: ["field"]),
        "also": Object(fields: ["files": .text(.path), "pattern": .text(.regex)], required: ["files", "pattern"]),
        "progress": Object(fields: ["percent": .text(.plain), "fraction": .text(.plain), "pattern": .text(.regex), "text": .text(.display)]),
        "input": Object(fields: run.merging(parse) { a, _ in a }.merging([
            "name": .text(.plain), "type": .oneOf(ToolInput.Kind.allCases.map(\.rawValue)), "title": .text(.plain),
            "placeholder": .text(.plain), "default": .text(.display), "pattern": .text(.regex), "optional": .bool,
            "options": .list(.text(.plain)), "remember": .bool, "key": .text(.display),
        ]) { _, b in b }, required: ["name", "type"]),
        "action": Object(fields: run.merging(action) { a, _ in a }, required: ["id"]),
    ]

    // MARK: Checking a file

    /// Checks a preset file (§14). `file`: its name, which the `id` must match. `hasScript`: whether a script of that
    /// name is next to it; `hasSymbol`: whether this macOS has an SF Symbol (the core has no AppKit). The preset comes
    /// back only when nothing is an error.
    public static func validate(_ data: Data, file: String, hasScript: @escaping (String) -> Bool = { _ in true },
                                hasSymbol: @escaping (String) -> Bool = { _ in true }) -> (preset: ToolPreset?, problems: [ToolProblem]) {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) } catch {
            let why = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            let line = why.firstMatch(of: /line (\d+)/).flatMap { Int($0.1) }
            return (nil, [ToolProblem(line: line, text: "invalid JSON: " + why, level: .error)])
        }
        let lines = lineMap(data)
        var c = Check(lines: lines, hasScript: hasScript, hasSymbol: hasSymbol)
        guard let top = json as? [String: Any] else { return (nil, [ToolProblem(line: 1, text: "a preset is a JSON object", level: .error)]) }
        if let n = top["schema"] as? Int, n > version {
            return (nil, [c.problem([.key("schema")], "schema \(n) needs a newer Kermo (this one reads schema \(version))")])
        }
        c.walk(top, .object("preset"), [])
        if let id = top["id"] as? String, id != (file as NSString).deletingPathExtension {
            c.error([.key("id")], "“\(id)” isn't the file's name: \(id).json")
        }
        c.texts.forEach { c.checkText($0.path, $0.kind, $0.text) }
        if c.problems.allSatisfy({ $0.level != .error }) {
            do {
                let p = try JSONDecoder().decode(ToolPreset.self, from: data)
                c.checkTyped(p)
                if c.problems.allSatisfy({ $0.level != .error }) { return (p, c.sorted) }
            } catch {
                c.error((error as? DecodingError).map(Check.path(of:)) ?? [], "can't be read: \(error.localizedDescription)")
            }
        }
        return (nil, c.sorted)
    }

    /// `actions[2].key` for a path.
    static func describe(_ path: [ToolPath]) -> String {
        path.enumerated().map { i, p in if case .key(let k) = p { i == 0 ? k : "." + k } else { p.description } }.joined()
    }

    /// The line each value starts on (an object's member: its key's line), by `describe`d path.
    static func lineMap(_ data: Data) -> [String: Int] {
        enum C { case object(key: String?), array(index: Int) }
        var map: [String: Int] = ["": 1], stack: [(c: C, path: [ToolPath])] = []
        var line = 1, pending = false   // pending: an array element starts at the next token
        let b = [UInt8](data)
        var i = 0
        func elementStarts() {
            guard pending, case .array(let n)? = stack.last?.c else { return }
            map[describe(stack.last!.path + [.index(n)])] = line
            pending = false
        }
        func valuePath() -> [ToolPath] {
            guard let top = stack.last else { return [] }
            switch top.c {
            case .object(let k): return top.path + (k.map { [.key($0)] } ?? [])
            case .array(let n): return top.path + [.index(n)]
            }
        }
        while i < b.count {
            switch b[i] {
            case 0x0A: line += 1
            case 0x20, 0x09, 0x0D, 0x3A: break   // space, tab, CR, colon
            case 0x22:   // a string: a key, or a value
                var j = i + 1
                while j < b.count, b[j] != 0x22 { j += b[j] == 0x5C ? 2 : 1 }
                if case .object(nil)? = stack.last?.c {
                    let key = (try? JSONSerialization.jsonObject(with: Data(b[i...min(j, b.count - 1)]), options: .fragmentsAllowed)) as? String ?? ""
                    stack[stack.count - 1].c = .object(key: key)
                    map[describe(stack.last!.path + [.key(key)])] = line
                } else { elementStarts() }
                i = j
            case 0x7B, 0x5B:   // { [
                elementStarts()
                stack.append((b[i] == 0x7B ? .object(key: nil) : .array(index: 0), valuePath()))
                pending = b[i] == 0x5B
            case 0x7D, 0x5D: stack.removeLast(); pending = false   // } ]
            case 0x2C:   // ,
                switch stack.last?.c {
                case .object?: stack[stack.count - 1].c = .object(key: nil)
                case .array(let n)?: stack[stack.count - 1].c = .array(index: n + 1); pending = true
                case nil: break
                }
            default: elementStarts()
            }
            i += 1
        }
        return map
    }

    /// One check of one file.
    struct Check {
        let lines: [String: Int]
        let hasScript: (String) -> Bool
        let hasSymbol: (String) -> Bool
        var problems: [ToolProblem] = []
        var texts: [(path: [ToolPath], kind: Text, text: String)] = []

        var sorted: [ToolProblem] {
            var seen = Set<ToolProblem>()
            return problems.filter { seen.insert($0).inserted }.sorted { ($0.line ?? 0, $0.level == .error ? 0 : 1) < ($1.line ?? 0, $1.level == .error ? 0 : 1) }
        }

        func line(_ path: [ToolPath]) -> Int? {
            var p = path
            while true {
                if let l = lines[ToolSchema.describe(p)] { return l }
                if p.isEmpty { return nil }
                p.removeLast()
            }
        }

        func problem(_ path: [ToolPath], _ text: String, _ level: ToolProblem.Level = .error) -> ToolProblem {
            ToolProblem(line: line(path), text: path.isEmpty ? text : "\(ToolSchema.describe(path)): \(text)", level: level)
        }
        mutating func error(_ path: [ToolPath], _ text: String) { problems.append(problem(path, text)) }
        mutating func warn(_ path: [ToolPath], _ text: String) { problems.append(problem(path, text, .warning)) }

        static func path(of e: DecodingError) -> [ToolPath] {
            let ctx: DecodingError.Context? = switch e {
            case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c): c
            @unknown default: nil
            }
            return (ctx?.codingPath ?? []).map { $0.intValue.map(ToolPath.index) ?? .key($0.stringValue) }
        }

        // MARK: Structure: fields, types, values

        mutating func walk(_ v: Any, _ f: Field, _ path: [ToolPath]) {
            func wrong(_ what: String) { error(path, "should be \(what)") }
            switch f {
            case .text(let kind):
                guard let s = v as? String else { return wrong("a string") }
                texts.append((path, kind, s))
            case .strings(let kind):
                if let s = v as? String { texts.append((path, kind, s)) }
                else if let a = v as? [Any], a.allSatisfy({ $0 is String }), !a.isEmpty {
                    for (i, s) in a.enumerated() { texts.append((path + [.index(i)], kind, s as! String)) }
                } else { wrong("a string or an array of strings") }
            case .number: if !isNumber(v) { wrong("a number") }
            case .integer: if !isNumber(v) || (v as! NSNumber).doubleValue.rounded() != (v as! NSNumber).doubleValue { wrong("a whole number") }
            case .bool: if !isBool(v) { wrong("true or false") }
            case .duration:
                if isNumber(v) { break }
                guard let s = v as? String, ToolDuration.text(s).seconds != nil else { return wrong("a duration: \"90s\", \"5m\", \"2h\", \"7d\" or seconds") }
            case .scalar: if !(v is String || v is NSNumber) { wrong("a string, a number or true/false") }
            case .oneOf(let all):
                guard let s = v as? String, all.contains(s) else { return wrong("one of " + all.map { "“\($0)”" }.joined(separator: ", ")) }
            case .list(let item):
                guard let a = v as? [Any] else { return wrong("an array") }
                for (i, x) in a.enumerated() { walk(x, item, path + [.index(i)]) }
            case .map(let item):
                guard let o = v as? [String: Any] else { return wrong("an object") }
                for (k, x) in o { walk(x, item, path + [.key(k)]) }
            case .runOrText:
                if let s = v as? String { texts.append((path, .command, s)) } else { walk(v, .object("run"), path) }
            case .column:
                let field = (v as? String) ?? (v as? [String: Any])?["field"] as? String
                if let fmt = field.flatMap({ ToolColumn.spec($0).field.format }), !ToolTemplate.columnFormats.contains(fmt) { error(path, "“\(fmt)” isn't a column format") }
                if !(v is String) { walk(v, .object("column"), path) }
            case .object(let name):
                guard let o = v as? [String: Any] else { return wrong("an object") }
                let spec = name == "column" ? Object(fields: ["field": .text(.plain), "title": .text(.plain), "width": .number], required: ["field"])
                    : objects[name]!
                for (k, x) in o {
                    if let field = spec.fields[k] { walk(x, field, path + [.key(k)]) }
                    else if k == "on_alert" { error(path + [.key(k)], "on_alert is a user setting (Settings), never a preset's") }
                    else { error(path + [.key(k)], "unknown field") }
                }
                for k in spec.required where o[k] == nil { error(path, "“\(k)” is missing") }
            }
        }

        private func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
        private func isNumber(_ v: Any) -> Bool { v is NSNumber && !isBool(v) }

        // MARK: Strings by kind

        mutating func checkText(_ path: [ToolPath], _ kind: Text, _ s: String) {
            let holders = ToolTemplate.placeholders(in: s)
            switch kind {
            case .command, .value, .path:
                if kind == .value, case .key(let name)? = path.last, !ToolSchema.isEnvName(name) {
                    error(path, "an env name is A–Z, 0–9 and “_”, not from a digit, and not KERMO_…")
                }
                for p in holders where p.format != nil {
                    error(path, "{\(p.name):\(p.format!)}: a display format can't be in a command; it gets the value as it is")
                }
                if kind == .command {
                    let quoting = ToolTemplate.quotes(in: s)
                    for p in holders where quoting(p.range.lowerBound) != .bare {
                        warn(path, "{\(p.name)} is inside quotes: " + (quoting(p.range.lowerBound) == .single
                            ? "it arrives as the literal text \"$…\", not its value" : "leave the quoting to Kermo"))
                    }
                }
            case .display:
                for p in holders where p.format.map({ !ToolTemplate.displayFormats.contains($0) }) ?? false {
                    error(path, "{\(p.name):\(p.format!)}: “\(p.format!)” isn't a display format")
                }
            case .regex: if (try? Regex(s)) == nil { error(path, "a broken regular expression") }
            case .split: if !["line", "blank"].contains(s), (try? Regex(s)) == nil { error(path, "“line”, “blank” or a regular expression") }
            case .script:
                if s.contains("/") { error(path, "a script is a file next to the preset: no “/”") }
                else if !hasScript(s) { error(path, "\(s) isn't next to the preset") }
            case .key: if !ToolSchema.isKey(s) { error(path, "“\(s)” isn't a key (cmd+e, shift+f6, return…)") }
            case .id: if s.isEmpty || !s.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) { error(path, "only a–z, 0–9 and “-”") }
            case .symbol: if !hasSymbol(s) { warn(path, "this macOS has no SF Symbol “\(s)”: Kermo shows a wrench") }
            case .plain: break
            }
        }
    }

    static func isEnvName(_ s: String) -> Bool {
        guard let f = s.first, !f.isNumber, !s.hasPrefix("KERMO_") else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
    }

    /// keymap.json's key names (`Shortcut`), with modifiers: `cmd+shift+l`, `f8`, `return`.
    static func isKey(_ s: String) -> Bool {
        let parts = s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, parts.dropLast().allSatisfy(["cmd", "opt", "alt", "ctrl", "shift"].contains) else { return false }
        let named: Set = ["return", "kpenter", "tab", "space", "backspace", "delete", "esc", "home", "end", "pgup", "pgdn", "left", "right",
                          "down", "up", "kpstar", "kpplus", "kpminus", "menu"]
        return named.contains(key) || (1...12).map { "f\($0)" }.contains(key)
            || (key.count == 1 && (key.first!.isLowercase || key.first!.isNumber || "=-][';\\,/.`".contains(key)))
    }
}

// MARK: Checks on the decoded preset

extension ToolSchema.Check {
    mutating func checkTyped(_ p: ToolPreset) {
        func source(_ r: ToolRun?, _ path: [ToolPath], needed: Bool = true) {
            guard let r else { return }
            if r.sources.count > 1 { error(path, "a Run has one source, not " + r.sources.joined(separator: " and ")) }
            else if needed, r.sources.isEmpty { error(path, "needs a command, script, files or http") }
        }
        source(p.requires, [.key("requires")])
        source(p.header, [.key("header")])
        source(p.list?.run, [.key("list")])
        source(p.list?.view.header, [.key("list"), .key("header")])
        source(p.stream?.run, [.key("stream")])
        source(p.poll?.run, [.key("poll")])
        if p.command != nil, p.script != nil { error([.key("script")], "a one-command tool has a command or a script, not both") }
        for (name, v) in p.vars ?? [:] {
            source(v.run, [.key("vars"), .key(name)], needed: false)
            if !v.run.sources.isEmpty, v.info.ask == true { error([.key("vars"), .key(name)], "a value comes from its command or is asked, not both") }
        }
        if let v = p.version, !groups(v.pattern).contains("v") { error([.key("version"), .key("pattern")], "needs a group (?<v>…) for the version") }
        if let pr = p.primary, !(p.toolActions ?? []).contains(where: { $0.spec.id == pr }) { error([.key("primary")], "“\(pr)” isn't a tool action") }

        var ids: [String: Bool] = [:]
        for (path, a) in p.allActions {
            let s = a.spec, onTool = path.count == 2 && path.first == .key("toolActions")   // a tool's own: one down there is a list's row's
            if ids.updateValue(true, forKey: s.id) != nil { error(path + [.key("id")], "“\(s.id)” is another action's id too") }
            source(a.run, path, needed: false)
            source(s.requires, path + [.key("requires")])
            if a.run.sources.isEmpty, s.edit == nil, s.open == nil, s.goto == nil, s.check != true {
                error(path, "needs a command or script, or edit, open, goto or check")
            }
            if s.key == "return", s.dangerous == true || s.confirm == true {
                error(path + [.key("key")], "↩ never runs an action that asks first: it's what Cancel answers to")
            }
            if s.long == true, (a.run.where ?? p.where) == .mac { error(path + [.key("long")], "a long job runs on the server, not on this Mac") }
            if s.verify == true, onTool || s.rows != nil { error(path + [.key("verify")], "verify reads a list again: only for a list's rows") }
            // No list of its own repeats the level it's on (§7.5): a row's of a list, or one level down — not a tool's, nor a dashboard table's.
            if s.output == .list, s.list == nil, onTool || s.rows != nil || path.count == 2 && p.list == nil {
                error(path + [.key("output")], "“list” needs the action's own list here: there's no list it's on to repeat")
            }
            if s.output == .list, s.list == nil, s.actions != nil { error(path + [.key("actions")], "an action that repeats its level has that level's actions") }
            if s.output == .list, s.multi == true { error(path + [.key("multi")], "a level is one row's: not on marked rows") }
            if s.output == .list, (s.inputs ?? []).contains(where: { $0.info.type == .secret }) {
                error(path + [.key("inputs")], "a secret doesn't go into a level's run: its read isn't masked")
            }
            if s.output != .list, s.list != nil || s.actions != nil { error(path + [.key("output")], "an action with its own list and actions has output “list”") }
            if let pat = s.progress?.pattern, !groups(pat).contains("percent") {
                error(path + [.key("progress"), .key("pattern")], "needs a group (?<percent>…)")
            }
            for (j, input) in (s.inputs ?? []).enumerated() {
                let ip = path + [.key("inputs"), .index(j)]
                if input.info.type == .choiceFrom {
                    source(input.run, ip)
                    if input.parse.format == .regex { error(ip + [.key("format")], "an input's pattern checks its value, so its choices can't be read by regex") }
                } else if !input.run.sources.isEmpty { error(ip, "only a choice-from input runs a command for its choices") }
                if input.info.type == .choice, (input.info.options ?? []).isEmpty { error(ip, "a choice needs options") }
                if input.info.type == .secret, s.output == .terminal { error(ip, "a secret can't go to a terminal: it has no stdin of Kermo's") }
                if ToolTemplate.kermoNames.contains(input.info.name) { warn(ip + [.key("name")], "“\(input.info.name)” hides Kermo's own {\(input.info.name)}") }
            }
            if s.readonly == true, let words = ToolSchema.destructive(a.run.command?.all ?? []) {
                warn(path + [.key("command")], "a readonly action that \(words)")
            }
        }
        sameKeys((p.actions ?? []).enumerated().map { ([.key("actions"), .index($0)], $1) }
                 + (p.toolActions ?? []).enumerated().map { ([.key("toolActions"), .index($0)], $1) })
        for (path, a) in p.allActions where a.spec.actions != nil {
            sameKeys(a.spec.actions!.enumerated().map { (path + [.key("actions"), .index($0)], $1) })
        }

        // What other parts name.
        let rowActions = Set((p.actions ?? []).map(\.spec.id)), metrics = Set((p.metrics ?? [:]).keys)
        for (i, c) in (p.context ?? []).enumerated() {
            for x in c.actions where !rowActions.contains(x) { error([.key("context"), .index(i), .key("actions")], "“\(x)” isn't one of the actions") }
        }
        let actionRows = Dictionary((p.actions ?? []).map { ($0.spec.id, $0.spec.rows) }) { a, _ in a }
        func blocks(_ list: [ToolBlock], _ at: [ToolPath]) {
            for (i, b) in list.enumerated() {
                let bp = at + [.index(i)]
                if [b.row != nil, b.stat != nil, b.charts != nil, b.table != nil, b.events != nil, b.counts != nil].filter({ $0 }).count != 1 {
                    error(bp, "a block is one of row, stat, charts, table, events, counts")
                }
                if b.table != nil, b.columns?.isEmpty ?? true { error(bp + [.key("columns")], "a table needs its columns") }
                for x in b.actions ?? [] where !rowActions.contains(x) { error(bp + [.key("actions")], "“\(x)” isn't one of the actions") }
                for x in b.actions ?? [] { if let rows = actionRows[x] ?? nil, let table = b.table, rows != table { error(bp + [.key("actions")], "“\(x)” acts on rows of \(rows), not \(table)") } }
                if let log = b.log, !rowActions.contains(log) { error(bp + [.key("log")], "“\(log)” isn't one of the actions") }
                for m in (b.stat?.all ?? []) + (b.charts ?? []).flatMap({ $0 }) where !metrics.contains(m) { error(bp, "“\(m)” isn't one of the metrics") }
                blocks(b.row ?? [], bp + [.key("row")])
            }
        }
        blocks(p.dashboard ?? [], [.key("dashboard")])
        for (i, a) in (p.alerts ?? []).enumerated() where !metrics.contains(a.metric ?? "") {
            error([.key("alerts"), .index(i), .key("metric")], "“\(a.metric ?? "")” isn't one of the metrics")
        }
        for (i, s) in (p.summary ?? []).enumerated() where !metrics.contains(s.metric) {
            error([.key("summary"), .index(i), .key("metric")], "“\(s.metric)” isn't one of the metrics")
        }
        for (id, m) in p.metrics ?? [:] where m.calc != nil && (m.path == nil || m.count != nil) {
            error([.key("metrics"), .key(id), .key("calc")], "\(m.calc!) works on a number at path, not on a count")
        }
        if let w = p.watch, w.every < 1 { error([.key("watch"), .key("every")], "a second or more") }   // `sleep 0` would spin, and a tick divides by it

        // Names: Kermo's own hidden, placeholders nothing fills.
        for name in (p.vars ?? [:]).keys where ToolTemplate.kermoNames.contains(name) {
            warn([.key("vars"), .key(name)], "“\(name)” hides Kermo's own {\(name)}")
        }
        for (path, l) in [([ToolPath.key("list")], p.list)] + p.allActions.map({ ($0.path + [.key("list")], $0.action.spec.list) }) {
            guard let l else { continue }
            for name in rows(l).names where ToolTemplate.kermoNames.contains(name) { warn(path, "the field “\(name)” hides Kermo's own {\(name)}") }
        }
        for t in texts where [.command, .value, .path, .display].contains(t.kind) {
            guard let names = names(for: t.path, in: p), names.complete else { continue }
            for h in ToolTemplate.placeholders(in: t.text) {
                let root = String(h.name.prefix { $0 != "." })
                guard !names.names.contains(root) else { continue }
                if names.regex { error(t.path, "{\(root)}: the list's pattern has no group “\(root)”") }
                else { warn(t.path, "{\(root)}: nothing gives it a value — no input, row field, var or Kermo name") }
            }
        }
        if p.about == nil, p.sudo == true || p.allActions.contains(where: { $0.action.run.sudo == true }) {
            warn([], "runs as root but has no “about” to say what for")
        }
    }

    /// Actions in one list (one level) sharing a key: an error, unless each has its own `requires` (same-key variants).
    mutating func sameKeys(_ all: [([ToolPath], ToolAction)]) {
        for (key, group) in Dictionary(grouping: all.filter { $0.1.spec.key != nil }, by: { $0.1.spec.key! }) where group.count > 1 {
            guard !group.allSatisfy({ $0.1.spec.requires != nil }) else { continue }
            for (path, _) in group.dropFirst() { error(path + [.key("key")], "“\(key)” is another action's key in this list too") }
        }
    }

    /// The names of a regex's groups.
    func groups(_ pattern: String) -> Set<String> {
        Set(pattern.matches(of: /\(\?P?<([A-Za-z_][A-Za-z0-9_]*)>/).map { String($0.1) })
    }


    /// The field names a level's rows have, as far as the file tells: all of them (a regex's groups, `names`, `lines`),
    /// or only some (JSON's fields are known when it runs).
    struct Names {
        var names: Set<String>
        var complete = true
        var regex = false
        static func + (a: Names, b: Names) -> Names { Names(names: a.names.union(b.names), complete: a.complete && b.complete, regex: b.regex) }
    }

    func rows(_ l: ToolList?) -> Names {
        guard let l else { return Names(names: []) }
        var n = Set([l.view.name].compactMap { $0 })
        if let also = l.view.also { n.formUnion(groups(also.pattern)) }
        switch l.parse.format ?? .lines {
        case .regex: return Names(names: n.union(groups(l.parse.pattern ?? "")), regex: true)
        case .lines: return Names(names: n.union(["line"]), complete: l.run.files == nil)
        case .tsv, .csv: return Names(names: n.union(l.parse.names ?? []), complete: l.parse.names != nil)
        case .text: return Names(names: n)
        default: return Names(names: n, complete: false)
        }
    }

    /// The names a template at `path` can use (§5.3); nil where the file can't tell (streams, metrics, dashboards).
    func names(for path: [ToolPath], in p: ToolPreset) -> Names? {
        let base = Names(names: Set((p.vars ?? [:]).keys).union(ToolTemplate.kermoNames))
        func action(_ list: [ToolAction]?, _ rest: ArraySlice<ToolPath>, _ above: Names) -> Names? {
            guard case .index(let i)? = rest.first, let list, i < list.count else { return nil }
            let a = list[i].spec, after = rest.dropFirst()
            var own = above + Names(names: Set((a.inputs ?? []).map(\.info.name)))
            if a.rows != nil { own.complete = false }   // a dashboard table's rows: a stream's
            switch after.first {
            case .key("list")?: return own + rows(a.list)
            case .key("actions")?: return action(a.actions, after.dropFirst(), above + rows(a.list))
            default: return own
            }
        }
        switch path.first {
        case .key("list")?:
            guard case .key(let k)? = path.dropFirst().first else { return nil }
            return ["header", "command", "script", "files", "env"].contains(k) ? base : base + rows(p.list)
        case .key("actions")?: return action(p.actions, path.dropFirst(), base + rows(p.list))
        case .key("toolActions")?: return action(p.toolActions, path.dropFirst(), base)
        case .key("context")?, .key("validators")?: return base + Names(names: ["stem", "file", "dir"])
        case .key("summary")?: return base + Names(names: ["ok", "warn", "bad", "off", "busy", "all"])
        case .key(let k)? where ["vars", "requires", "header", "version", "install", "uninstall", "command", "save", "done", "env"].contains(k):
            return base
        default: return nil
        }
    }
}

// MARK: JSON Schema

extension ToolSchema {
    /// The schema as JSON Schema (draft 2020-12), for editors' completion and a preset's `$schema`.
    public static func jsonSchema() -> Data {
        func field(_ f: Field) -> [String: Any] {
            switch f {
            case .text(.id): return ["type": "string", "pattern": "^[a-z0-9-]+$"]
            case .text: return ["type": "string"]
            case .strings: return ["anyOf": [["type": "string"], ["type": "array", "items": ["type": "string"]]]]
            case .number: return ["type": "number"]
            case .integer: return ["type": "integer"]
            case .bool: return ["type": "boolean"]
            case .oneOf(let all): return ["enum": all]
            case .list(let item): return ["type": "array", "items": field(item)]
            case .map(let item): return ["type": "object", "additionalProperties": field(item)]
            case .object(let name): return ["$ref": "#/$defs/\(name)"]
            case .runOrText: return ["anyOf": [["type": "string"], ["$ref": "#/$defs/run"]]]
            case .duration: return ["anyOf": [["type": "string", "pattern": "^[0-9.]+[smhd]?$"], ["type": "number"]]]
            case .scalar: return ["type": ["string", "number", "boolean"]]
            case .column: return ["anyOf": [["type": "string"], ["type": "object", "properties": ["field": ["type": "string"], "title": ["type": "string"],
                                                                                                 "width": ["type": "number"]],
                                                                  "required": ["field"], "additionalProperties": false]]]
            }
        }
        let defs = objects.mapValues { o -> [String: Any] in
            ["type": "object", "properties": o.fields.mapValues(field), "required": o.required, "additionalProperties": false]
        }
        let schema: [String: Any] = ["$schema": "https://json-schema.org/draft/2020-12/schema", "title": "Kermo Tools preset, schema \(version)",
                                     "$ref": "#/$defs/preset", "$defs": defs]
        return try! JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

extension ToolSchema {
    /// What a destructive command does, said for a warning (here, and in the trust sheet); nil for none.
    public static func destructive(_ commands: [String]) -> String? {
        for c in commands {
            if let w = c.firstMatch(of: /(?:^|[^\w-])(rm|kill|delete|dd|mkfs(?:\.\w+)?)(?:$|[^\w-])/) { return "runs “\(w.1)”" }
            if c.contains("--force") { return "has --force" }
            var rest = Substring(c)
            while let i = rest.firstIndex(of: ">") {
                let after = rest[rest.index(after: i)...].drop { $0 == " " }
                if !(after.hasPrefix("&") || after.hasPrefix("/dev/null")) { return "writes to a file (>)" }
                rest = rest[rest.index(after: i)...]
            }
        }
        return nil
    }
}
