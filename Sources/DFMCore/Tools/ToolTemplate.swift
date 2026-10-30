import Foundation

/// Templates (protocol §5): `{name}` in a preset's text. In a command a value never becomes shell text: each one is a
/// variable set in the payload's preamble, and `{x}` stands for `"$K_x"`. Display text gets the value as text.
public enum ToolTemplate {
    /// `{name}` or `{name:format}`.
    public struct Placeholder: Sendable, Hashable {
        public var range: Range<String.Index>
        public var name: String
        public var format: String?
    }

    /// The placeholders in `s`: `{`, a name that starts with an ASCII letter (then letters, digits, `_`, `.`), an
    /// optional `:format`, `}` — and not right after `$`. Anything else in braces is shell's or another tool's
    /// (`${HOME}`, `{}`, `{a,b}`, awk's `{ print $1 }`, Go's `{{.Name}}`) and stays as it is.
    public static func placeholders(in s: String) -> [Placeholder] {
        var found: [Placeholder] = []
        var i = s.startIndex
        while let open = s[i...].firstIndex(of: "{") {
            i = s.index(after: open)
            guard open == s.startIndex || s[s.index(before: open)] != "$" else { continue }
            var j = i
            while j < s.endIndex, s[j].isASCII, s[j].isLetter || s[j].isNumber || s[j] == "_" || s[j] == "." { j = s.index(after: j) }
            guard j > i, s[i].isASCII, s[i].isLetter, j < s.endIndex else { continue }
            let name = String(s[i..<j])
            var format: String?
            if s[j] == ":" {
                var k = s.index(after: j)
                while k < s.endIndex, s[k].isASCII, s[k].isLetter || s[k] == "%" { k = s.index(after: k) }
                guard k > s.index(after: j) else { continue }
                format = String(s[s.index(after: j)..<k])
                j = k
            }
            guard j < s.endIndex, s[j] == "}" else { continue }
            found.append(Placeholder(range: open..<s.index(after: j), name: name, format: format))
            i = s.index(after: j)
        }
        return found
    }

    /// Formats a template may show a value in (§5.2); `columns` also take `state`, `bar`, `spark`.
    public static let displayFormats: Set<String> = ["bytes", "kbytes", "%", "ms", "ago", "datetime", "days", "v"]
    public static let columnFormats = displayFormats.union(["state", "bar", "spark"])

    /// Kermo's own names (§5.3), last in the order of names.
    public static let kermoNames: Set<String> = ["server", "host", "user", "every", "stdout", "from", "to", "value", "exit",
                                                 "os", "os_version", "pkg", "init", "arch"]

    /// The names a template can use, in their order (§5.3): the action's inputs, the row's fields (its own, then its
    /// parents', nearest first), the tool's vars, Kermo's own. The first level that has a name wins.
    public struct Scope: Sendable {
        public var levels: [[String: ToolValue]]
        public init(inputs: [String: ToolValue] = [:], rows: [[String: ToolValue]] = [], vars: [String: ToolValue] = [:],
                    kermo: [String: ToolValue] = [:]) {
            levels = [inputs] + rows + [vars, kermo]
        }

        /// `failure.stage`: a field named so, else `stage` inside `failure`.
        public func value(_ name: String) -> ToolValue? {
            for level in levels {
                if let v = level[name] { return v }
                guard let dot = name.firstIndex(of: "."), let top = level[String(name[..<dot])] else { continue }
                return top[String(name[name.index(after: dot)...])]
            }
            return nil
        }

        /// Empty: missing, null or "".
        func isEmpty(_ name: String) -> Bool { (value(name)?.text ?? "").isEmpty }
    }

    // MARK: Display text

    /// Display text with its values: `title`, `detail`, `message`, `done`… A missing value shows as nothing.
    /// `now`: the server's clock (`ago`).
    public static func text(_ t: String, _ scope: Scope, now: Date = Date()) -> String {
        var out = "", from = t.startIndex
        for p in placeholders(in: t) {
            out += t[from..<p.range.lowerBound]
            out += scope.value(p.name).map { show($0, p.format, now: now) } ?? ""
            from = p.range.upperBound
        }
        return out + t[from...]
    }

    /// `subtitle`'s parts: a part after the first with an empty field is left out; the rest joined with " · ".
    public static func parts(_ parts: [String], _ scope: Scope, now: Date = Date()) -> String {
        kept(parts, scope).map { text($0, scope, now: now) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The parts that stay: the first, and each later one whose fields all have values.
    static func kept(_ parts: [String], _ scope: Scope) -> [String] {
        parts.enumerated().filter { i, p in i == 0 || !placeholders(in: p).contains { scope.isEmpty($0.name) } }.map(\.element)
    }

    /// A value in a display format (§5.2). Unknown or no format: the value as text.
    public static func show(_ v: ToolValue, _ format: String?, now: Date = Date()) -> String {
        guard let format, v != .null, !(v.text.isEmpty) else { return v.text }
        let n = v.number
        switch format {
        case "bytes", "kbytes":
            guard let n else { return v.text }
            let b = Int64(format == "kbytes" ? n * 1024 : n)
            return b < 1000 ? "\(b) B" : ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
        case "%": return n.map { ToolValue.number(($0 * 10).rounded() / 10).text + " %" } ?? v.text
        case "ms":
            guard let n else { return v.text }
            return n < 1000 ? "\(Int(n.rounded())) ms" : String(format: "%.1f s", n / 1000)
        case "days":
            guard let n else { return v.text }
            return n == 1 ? "1 day" : "\(ToolValue.number(n).text) days"
        case "v": return "v" + v.text
        case "ago":
            guard let d = date(v) else { return v.text }
            let s = max(0, now.timeIntervalSince(d))
            return s < 60 ? "just now" : s < 3600 ? "\(Int(s / 60)) min ago" : s < 86400 ? "\(Int(s / 3600)) h ago"
                : Int(s / 86400) == 1 ? "1 day ago" : "\(Int(s / 86400)) days ago"
        case "datetime": return date(v).map { dateTime.string(from: $0) } ?? v.text
        default: return v.text
        }
    }

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE dd.MM HH:mm"
        return f
    }()

    /// A time: Unix seconds, or ISO 8601 with any number of fraction digits (restic writes nanoseconds).
    public static func date(_ v: ToolValue) -> Date? {
        if let n = v.number { return Date(timeIntervalSince1970: n) }
        guard case .string(var s) = v else { return nil }
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) ?? Optional(s.endIndex) {
            s.removeSubrange(dot..<end)
        }
        return (try? Date(s, strategy: .iso8601)) ?? (try? Date(s + "Z", strategy: .iso8601))
    }

    // MARK: Commands

    /// A command with its values outside its text: `text` holds `"$K_x"` where the preset has `{x}`, `values` the
    /// variables to set before it, `shown` the same command with the values filled in (for reading only).
    public struct Command: Sendable, Hashable {
        public var text: String
        public var values: [Variable]
        public var shown: String
    }

    public struct Variable: Sendable, Hashable {
        public var name: String   // K_…
        public var value: String
    }

    /// Why a command can't be made.
    public struct Empty: Error, Hashable, CustomStringConvertible {
        public var field: String
        public var description: String { "{\(field)} is empty" }
    }

    /// The command for `c`: an array's later parts with an empty field drop out; a single string with one is refused.
    /// `taken`: variables named already in this payload (another template's), so the same field gets the same one.
    public static func command(_ c: ToolStrings, _ scope: Scope, vars taken: inout [String: String]) throws(Empty) -> Command {
        let parts: [String]
        switch c {
        case .one(let s):
            if let p = placeholders(in: s).first(where: { scope.isEmpty($0.name) }) { throw Empty(field: p.name) }
            parts = [s]
        case .many(let all):
            if let first = all.first, let p = placeholders(in: first).first(where: { scope.isEmpty($0.name) }) { throw Empty(field: p.name) }
            parts = kept(all, scope)
        }
        var cmd = Command(text: "", values: [], shown: "")
        for part in parts {
            let one = shell(part, scope, vars: &taken)
            cmd.text += (cmd.text.isEmpty ? "" : " ") + one.text
            cmd.shown += (cmd.shown.isEmpty ? "" : " ") + one.shown
            cmd.values += one.values.filter { v in !cmd.values.contains(v) }
        }
        return cmd
    }

    /// An `env` value: what it says, with literal text quoted too (it's a value, not shell code).
    public static func value(_ t: String, _ scope: Scope, vars taken: inout [String: String]) -> Command {
        var cmd = Command(text: "", values: [], shown: "")
        var from = t.startIndex
        func literal(_ s: Substring) {
            guard !s.isEmpty else { return }
            cmd.text += ShellContext.quote(String(s))
            cmd.shown += s
        }
        for p in placeholders(in: t) {
            literal(t[from..<p.range.lowerBound])
            let v = variable(p.name, scope, &taken)
            cmd.text += "\"$\(v.name)\""
            cmd.shown += v.value
            if !cmd.values.contains(v) { cmd.values.append(v) }
            from = p.range.upperBound
        }
        literal(t[from...])
        if cmd.text.isEmpty { cmd.text = "''" }
        return cmd
    }

    /// One command string: each `{x}` becomes its variable, quoted for where it stands — `"$K_x"` in the open,
    /// `${K_x}` inside the author's double quotes (still one word). Inside single quotes it stays literal text, as
    /// the shell would have it; the validator warns about both.
    static func shell(_ t: String, _ scope: Scope, vars taken: inout [String: String]) -> Command {
        var cmd = Command(text: "", values: [], shown: "")
        var from = t.startIndex
        let quoting = quotes(in: t)
        for p in placeholders(in: t) {
            cmd.text += t[from..<p.range.lowerBound]
            cmd.shown += t[from..<p.range.lowerBound]
            let v = variable(p.name, scope, &taken)
            switch quoting(p.range.lowerBound) {
            case .bare, .single: cmd.text += "\"$\(v.name)\""
            case .double: cmd.text += "${\(v.name)}"
            }
            cmd.shown += quoting(p.range.lowerBound) == .bare ? ShellContext.quote(v.value) : v.value
            if !cmd.values.contains(v) { cmd.values.append(v) }
            from = p.range.upperBound
        }
        cmd.text += t[from...]
        cmd.shown += t[from...]
        return cmd
    }

    /// `K_` and the field's name cleaned to `[A-Za-z0-9_]` (`failure.stage` → `K_failure_stage`, `%util` →
    /// `K_util`); two names that clean to the same one get a number.
    static func variable(_ name: String, _ scope: Scope, _ taken: inout [String: String]) -> Variable {
        let value = scope.value(name)?.text ?? ""
        if let known = taken[name] { return Variable(name: known, value: value) }
        let base = "K_" + String(name.unicodeScalars.compactMap { c -> Character? in
            c == "." ? "_" : c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "_") ? Character(c) : nil
        })
        var v = base, n = 2
        while taken.values.contains(v) { v = base + "\(n)"; n += 1 }
        taken[name] = v
        return Variable(name: v, value: value)
    }

    public enum Quote: Sendable { case bare, single, double }

    /// How the shell reads each position of `t`: outside quotes, inside '…', inside "…". `$(…)` and backquotes
    /// inside double quotes start over outside quotes.
    /// ponytail: counts parentheses and knows no comments, so a `case … in x)` inside `$(…)` or a `'` after `#` confuses
    /// it; logic like that belongs in a script, which has no templates.
    public static func quotes(in t: String) -> (String.Index) -> Quote {
        enum Ctx: Equatable { case open(Int), single, double, back }   // open: depth of `$(…)` parentheses (0: top level)
        var stack: [Ctx] = [.open(0)]
        var map: [String.Index: Quote] = [:]
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i], next = t.index(after: i), ctx = stack.last!
            let dollarParen = c == "$" && next < t.endIndex && t[next] == "("
            map[i] = ctx == .single ? .single : ctx == .double ? .double : .bare
            var pair = false   // the next character goes with this one
            switch ctx {
            case .single:
                if c == "'" { stack.removeLast() }
            case .double:
                if c == "\\" { pair = true }
                else if c == "\"" { stack.removeLast() }
                else if dollarParen { stack.append(.open(1)); pair = true }
                else if c == "`" { stack.append(.back) }
            case .open, .back:
                if c == "\\" { pair = true }
                else if c == "'" { stack.append(.single) }
                else if c == "\"" { stack.append(.double) }
                else if c == "`" { if ctx == .back { stack.removeLast() } else { stack.append(.back) } }
                else if dollarParen { stack.append(.open(1)); pair = true }
                else if case .open(let d) = ctx, d > 0, c == "(" { stack[stack.count - 1] = .open(d + 1) }
                else if case .open(let d) = ctx, d > 0, c == ")" { if d == 1 { stack.removeLast() } else { stack[stack.count - 1] = .open(d - 1) } }
            }
            if pair, next < t.endIndex { map[next] = map[i]; i = t.index(after: next) } else { i = next }
        }
        return { map[$0] ?? .bare }
    }

    // MARK: Values

    /// Why a value can't go into a command (§3.2, rule 5), or nil: one that begins with `-` (it would be an option —
    /// `whois -h …`), or holds a control character or a line break. An input's `pattern` that matches it whole
    /// allows it anyway.
    public static func refusal(_ value: String, pattern: String? = nil) -> String? {
        if let pattern, let r = try? Regex(pattern), (try? r.wholeMatch(in: value)) != nil { return nil }
        if value.hasPrefix("-") { return "it begins with “-”, so a command would take it for an option" }
        if value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}" }) {
            return "it holds a line break or a control character"
        }
        return nil
    }
}
