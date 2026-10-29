import Foundation

/// A record: one row of a list, one sample of a stream.
public typealias ToolRecord = [String: ToolValue]

/// What a Parse made of a run's output (protocol §4).
public struct ToolRecords: Sendable, Hashable {
    /// The rows, sorted, at most `limit` of them.
    public var rows: [ToolRecord] = []
    /// How many there were before `limit`.
    public var total = 0
    /// Lines (or blocks) that gave no record: a header, a banner, a line the pattern doesn't fit.
    public var unmatched: [String] = []
    /// `format: text`: the output to show as it is.
    public var text: String?

    /// False: there was output, but it gave no record — "the output didn't match" (never silent, §4.2).
    public var matched: Bool { text != nil || !rows.isEmpty || unmatched.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// "20 rows", "500 of 812 rows", "the output didn't match (3 lines)".
    public var summary: String {
        if text != nil { return "text" }
        if !matched { return "the output didn't match (\(unmatched.count) \(unmatched.count == 1 ? "line" : "lines"))" }
        let n = total == rows.count ? "\(total)" : "\(rows.count) of \(total)"
        return "\(n) \(total == 1 ? "row" : "rows")" + (unmatched.isEmpty ? "" : ", \(unmatched.count) unmatched")
    }
}

/// A file a `files` list reads (over SFTP, Tools PR 7): its path, its content, and the content of its `also` file.
public struct ToolFile: Sendable {
    public var path: String
    public var data: Data
    public var also: Data?
    public init(path: String, data: Data, also: Data? = nil) { (self.path, self.data, self.also) = (path, data, also) }
}

extension ToolParse {
    /// Lines of output: a newline or a carriage return ends one (a progress bar redraws its line with `\r`), ANSI colors
    /// stripped.
    public static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }
            .map { ANSI.strip($0) }
    }

    /// The output cut into records' text (`split`): lines, blocks between blank lines, or blocks that each start with
    /// a line `split`'s regex finds. A stream's frames are these.
    public func units(_ text: String) -> [String] {
        let all = Self.lines(text)
        switch split ?? "line" {
        case "line": return all.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        case "blank":
            return all.split { $0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.joined(separator: "\n") }
        case let pattern:
            guard let first = try? Regex(pattern) else { return [] }
            var blocks: [[String]] = []
            for l in all where !l.trimmingCharacters(in: .whitespaces).isEmpty {
                if blocks.isEmpty || l.firstMatch(of: first) != nil { blocks.append([l]) } else { blocks[blocks.count - 1].append(l) }
            }
            return blocks.map { $0.joined(separator: "\n") }
        }
    }

    /// The records in a run's output. Values from text formats are strings; `prometheus` and `nagios` are read from
    /// Tools PR 5 on, so here their output stays unmatched.
    public func records(_ out: Data) -> ToolRecords {
        let text = String(decoding: out, as: UTF8.self)
        var r = ToolRecords()
        switch format ?? .lines {
        case .text: r.text = text; return r
        case .lines: r.rows = units(text).map { ["line": .string($0)] }
        case .json:
            guard let doc = try? JSONSerialization.jsonObject(with: out, options: .fragmentsAllowed) else {
                r.unmatched = units(text)
                break
            }
            r.rows = jsonRows(ToolValue(any: doc))
        case .jsonl:
            for u in units(text) {
                if case .object(let o)? = (try? JSONSerialization.jsonObject(with: Data(u.utf8))).map(ToolValue.init(any:)) { r.rows.append(o) }
                else { r.unmatched.append(u) }
            }
        case .tsv: r = delimited(units(text).map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) })
        case .csv: r = delimited(Self.csv(text))
        case .table: for u in split == nil ? [text] : units(text) { r.add(table(u)) }   // split: each block under its own header
        case .regex:
            guard let re = try? Regex(pattern ?? "") else { r.unmatched = units(text); break }
            for u in units(text) {
                guard let m = u.firstMatch(of: re) else { r.unmatched.append(u); continue }
                var rec = ToolRecord()
                for g in m.output.dropFirst() { if let name = g.name, let s = g.substring { rec[name] = .string(String(s)) } }
                r.rows.append(rec)
            }
        case .prometheus, .nagios: r.unmatched = units(text)
        }
        return finish(r)
    }

    /// A `files` list: each file one record, read by this Parse (its first record); `name` gets the file's parent
    /// folder's name, and `also`'s pattern adds its groups from the file's `also`.
    public func records(files: [ToolFile], name: String?, also: String?) -> ToolRecords {
        var r = ToolRecords()
        let alsoRe = also.flatMap { try? Regex($0).anchorsMatchLineEndings() }   // ^ and $ at each line of the file
        for f in files {
            let one = Self(format: format, rows: rows, pattern: pattern, names: names, split: split).records(f.data)
            guard var rec = one.rows.first else { r.unmatched.append(f.path); continue }
            if let name { rec[name] = .string(((f.path as NSString).deletingLastPathComponent as NSString).lastPathComponent) }
            if let alsoRe, let a = f.also.map({ String(decoding: $0, as: UTF8.self) }), let m = a.firstMatch(of: alsoRe) {
                for g in m.output.dropFirst() { if let n = g.name, let s = g.substring { rec[n] = .string(String(s)) } }
            }
            r.rows.append(rec)
        }
        return finish(r)
    }

    /// `json`: the array at `rows` (or the document), each element a record; an object there is a map — each value a
    /// record, its key in `_key` (tailscale's `Peer`).
    private func jsonRows(_ doc: ToolValue) -> [ToolRecord] {
        let at = rows.map { doc[$0] ?? .null } ?? doc
        switch at {
        case .array(let a): return a.map { if case .object(let o) = $0 { o } else { ["value": $0] } }
        case .object(let o) where rows != nil:
            return o.keys.sorted().map { k in
                var rec: ToolRecord = if case .object(let v)? = o[k] { v } else { ["value": o[k]!] }
                rec["_key"] = .string(k)
                return rec
            }
        case .object(let o): return [o]
        default: return []
        }
    }

    /// `tsv` / `csv` rows: the first is the header unless `names` gives the names.
    private func delimited(_ lines: [[String]]) -> ToolRecords {
        var r = ToolRecords(), lines = lines.filter { $0 != [""] }
        guard let header = names ?? (lines.isEmpty ? nil : lines.removeFirst()) else { return r }
        for l in lines {
            guard l.count <= header.count else { r.unmatched.append(l.joined(separator: format == .csv ? "," : "\t")); continue }
            r.rows.append(Dictionary(zip(header, l.map(ToolValue.string)), uniquingKeysWith: { a, _ in a }))
        }
        return r
    }

    /// RFC 4180: fields in double quotes may hold commas, line breaks and `""` for a quote.
    static func csv(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = text.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()
        var pending: Character?
        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    let n = chars.next()
                    if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" || c == "\r" { row.append(field); rows.append(row); (row, field) = ([], "") }
            else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    /// Aligned output under a header line (`ps`, `iostat`). A column runs from its header word to the next one; each
    /// word of a line goes to the column its last character falls in, so right-aligned numbers that start left of
    /// their header stay whole, and the last column takes the rest of the line.
    /// ponytail: a header word with a space in it (df's "Mounted on") reads as two columns; such output wants a script
    /// that prints TSV.
    private func table(_ block: String) -> ToolRecords {
        func words(_ l: [Character]) -> [Range<Int>] {
            var all: [Range<Int>] = [], i = 0
            while i < l.count {
                if l[i].isWhitespace { i += 1; continue }
                let from = i
                while i < l.count, !l[i].isWhitespace { i += 1 }
                all.append(from..<i)
            }
            return all
        }
        var r = ToolRecords()
        var lines = block.split(separator: "\n").map { Array($0) }
        guard !lines.isEmpty else { return r }
        let header = lines.removeFirst(), columns = words(header)
        let names = columns.map { String(header[$0]) }
        for l in lines {
            var cells = [Range<Int>?](repeating: nil, count: columns.count)
            for w in words(l) {
                let k = columns.lastIndex { $0.lowerBound <= w.upperBound - 1 } ?? 0
                cells[k] = cells[k].map { $0.lowerBound..<w.upperBound } ?? w
            }
            r.rows.append(Dictionary(zip(names, cells.map { .string($0.map { String(l[$0]) } ?? "") }), uniquingKeysWith: { a, _ in a }))
        }
        return r
    }

    /// Sorted (`sort`, `-field` descending; numbers as numbers), then cut to `limit` (500).
    private func finish(_ r: ToolRecords) -> ToolRecords {
        var r = r
        if let sort {
            let desc = sort.hasPrefix("-"), field = desc ? String(sort.dropFirst()) : sort
            r.rows = r.rows.enumerated().sorted { a, b in
                let x = ToolValue.object(a.element)[field], y = ToolValue.object(b.element)[field]
                let order: ComparisonResult = if let p = x?.number, let q = y?.number { p < q ? .orderedAscending : p > q ? .orderedDescending : .orderedSame }
                    else { (x?.text ?? "").localizedStandardCompare(y?.text ?? "") }
                return order == .orderedSame ? a.offset < b.offset : (order == .orderedAscending) != desc
            }.map(\.element)
        }
        r.total = r.rows.count
        r.rows = Array(r.rows.prefix(limit ?? 500))
        return r
    }
}

extension ToolRecords {
    mutating func add(_ other: ToolRecords) {
        rows += other.rows
        unmatched += other.unmatched
    }
}

extension ToolRun {
    /// Whether an exit code counts as success (`exitOk`, default `[0]`).
    public func succeeded(_ exit: Int32) -> Bool { (exitOk ?? [0]).contains(Int(exit)) }
}

// MARK: How a row looks

/// A row's state mark (§6.2): ● ok, ○ warn, ◆ bad, a grey dot off; busy is a spinner.
public enum ToolRowState: String, Sendable, CaseIterable { case ok, warn, bad, off, busy }

/// A record as a Picker or a panel shows it.
public struct ToolRow: Sendable, Hashable {
    public var key: String
    public var title: String
    public var subtitle: String
    public var detail: String
    public var state: ToolRowState?
    /// `columns`, each value in its format; `state`, `bar` and `spark` columns hold the raw value for the view to draw.
    public var cells: [Cell]
    public var record: ToolRecord

    public struct Cell: Sendable, Hashable {
        public var field: String
        public var format: String?
        public var text: String
        public var value: ToolValue?
    }
}

extension ToolListView {
    /// `record` as a row. `scope`: the names around it (vars, Kermo's, parent rows); the record goes first among the
    /// rows. `now`: the server's clock, for `ago`.
    public func row(_ record: ToolRecord, _ scope: ToolTemplate.Scope = .init(), now: Date = Date()) -> ToolRow {
        var s = scope
        s.levels.insert(record, at: 1)   // after the inputs, before parent rows
        let keyText = key.map { ToolTemplate.text($0, s, now: now) }
            ?? String(decoding: (try? JSONEncoder.sorted.encode(record)) ?? Data(), as: UTF8.self)
        let mark = state.flatMap { st -> ToolRowState? in
            let v = s.value(st.field)?.text ?? ""
            return [(ToolRowState.ok, st.ok), (.warn, st.warn), (.bad, st.bad), (.off, st.off), (.busy, st.busy)].first { $0.1?.contains(v) == true }?.0
        }
        let cells = (columns ?? []).map { c -> ToolRow.Cell in
            let (field, format) = c.field
            let v = s.value(field)
            let raw = ["state", "bar", "spark"].contains(format ?? "")
            return ToolRow.Cell(field: field, format: format, text: v.map { raw ? $0.text : ToolTemplate.show($0, format, now: now) } ?? "", value: v)
        }
        return ToolRow(key: keyText, title: title.map { ToolTemplate.text($0, s, now: now) } ?? keyText,
                       subtitle: ToolTemplate.parts(subtitle?.all ?? [], s, now: now), detail: detail.map { ToolTemplate.text($0, s, now: now) } ?? "",
                       state: mark, cells: cells, record: record)
    }
}

/// Recorded output for checking a preset without a server (`tools-lint --fixtures`, the catalog's CI):
/// `<tool>.<source>[.<note>].<ext>` — `ufw.list.txt` is ufw's list output, `system.stream.jsonl` its stream's,
/// `system.biggest.txt` the output of its action `biggest`, read by that action's own list. For a `files` list the
/// note is the file's folder (`dpl.list.api.json`: `…/api/deploy.json`).
public enum ToolFixture {
    public struct Source: Sendable {
        public var name: String
        public var run: ToolRun
        public var parse: ToolParse
        public var view: ToolListView?
    }

    public static func match(_ file: String, _ presets: [ToolPreset]) -> (preset: ToolPreset, source: Source)? {
        let parts = file.split(separator: ".").map(String.init)
        guard parts.count >= 3, let p = presets.first(where: { $0.id == parts[0] }) else { return nil }
        switch parts[1] {
        case "list": return p.list.map { (p, Source(name: "list", run: $0.run, parse: $0.parse, view: $0.view)) }
        case "stream": return p.stream.map { (p, Source(name: "stream", run: $0.run, parse: $0.parse)) }
        case "poll": return p.poll.map { (p, Source(name: "poll", run: $0.run, parse: $0.parse)) }
        case let id:
            guard let a = p.allActions.first(where: { $0.action.spec.id == id })?.action, let l = a.spec.list else { return nil }
            return (p, Source(name: id, run: a.run, parse: l.parse, view: l.view))
        }
    }

    /// The fixture read by its source: a `files` list's as one file in the folder its name gives.
    public static func records(_ file: String, _ data: Data, _ source: Source) -> ToolRecords {
        guard source.run.files != nil else { return source.parse.records(data) }
        let parts = file.split(separator: ".").map(String.init)
        let folder = parts.count > 3 ? parts[2] : "fixture"
        return source.parse.records(files: [ToolFile(path: "\(folder)/\(file)", data: data)], name: source.view?.name, also: nil)
    }
}
