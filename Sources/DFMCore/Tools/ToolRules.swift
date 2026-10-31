import Foundation

// Watching (protocol §8), the pure part: a stream's lines into frames and samples, a sample's metrics, their series in
// memory, the alerts' standing and the events — nothing of the connection. The engine (`ToolMonitor`) feeds samples
// and gaps in and shows what comes out. Every time here is the server's clock (the start marker's epoch, §3.2),
// unless said otherwise.

/// One sample of a stream or a poll (§8.1): a record, or `{ "rows": [...] }` where a frame gave several.
public struct ToolSample: Sendable, Equatable {
    public var at: Date
    public var record: ToolRecord
    public init(at: Date, record: ToolRecord) { (self.at, self.record) = (at, record) }

    /// `rows` of the sample: an array at that path, or the list's rows (`rows: "list"`, which a poll of the list gives
    /// as `rows`).
    public func rows(_ path: String) -> [ToolRecord] {
        guard case .array(let a)? = ToolValue.object(record)[path == "list" ? "rows" : path] else { return [] }
        return a.compactMap { if case .object(let o) = $0 { o } else { nil } }
    }
}

/// Why a stretch of a series has no values (§2): a band on the chart, never zeros; nothing recovers through one.
/// `maintenance` is a band over values: the server's own time (`ToolMonitor`), never a point of a series.
public enum ToolGap: String, Sendable, Codable { case asleep, noAnswer, reconnecting, notWatched, maintenance }

/// A point of a series: a value, or the start of a gap (till the next value).
public struct ToolPoint: Sendable, Equatable {
    public var at: Date
    public var value: Double?
    public var gap: ToolGap?
    public init(at: Date, value: Double? = nil, gap: ToolGap? = nil) { (self.at, self.value, self.gap) = (at, value, gap) }
}

/// One metric's values in one sample, by series key: "" for a scalar; a row's `key` for `rows`; a count's `all`
/// and each state's name.
public typealias ToolValues = [String: Double]

// MARK: Frames and samples

/// A stream's lines into frames (§8.1): each line (the default — `jsonl`), the blocks between blank lines
/// (`split: "blank"`), or blocks that each start with a line `split`'s regex finds — such a frame is done only when
/// the next one begins. A poll's frame is its whole run, with the line that ends it (`ToolPayload.ranMark`, its exit
/// code). Not Sendable: it holds its regex, and one channel's parser lives with the engine on the main actor.
public struct ToolFrames {
    private let split: String?
    private let poll: Bool
    private let first: Regex<AnyRegexOutput>?
    private var held: [String] = []

    public init(split: String?, poll: Bool = false) {
        (self.split, self.poll) = (split, poll)
        first = split.flatMap { $0 == "line" || $0 == "blank" ? nil : try? Regex($0) }
    }

    /// The frames `line` completes.
    public mutating func feed(_ line: String) -> [String] {
        if poll {   // output with no newline at its end has the mark at the end of its last line
            guard let mark = line.range(of: ToolPayload.ranMark) else {
                held.append(line)
                if held.count > 20_000 { held.removeFirst(10_000) }   // ponytail: a run that never ends keeps its last lines, once in a while
                return []
            }
            defer { held = [] }
            if mark.lowerBound > line.startIndex { held.append(String(line[..<mark.lowerBound])) }
            return [(held + [String(line[mark.lowerBound...])]).joined(separator: "\n")]
        }
        let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
        switch split ?? "line" {
        case "line": return blank ? [] : [line]
        case "blank":
            guard blank else { held.append(line); return [] }
            defer { held = [] }
            return held.isEmpty ? [] : [held.joined(separator: "\n")]
        default:
            guard !blank else { return [] }
            if let first, line.firstMatch(of: first) != nil, !held.isEmpty {
                defer { held = [line] }
                return [held.joined(separator: "\n")]
            }
            held.append(line)
            return []
        }
    }
}

extension ToolParse {
    /// A frame as a sample (§8.1): a `json` / `jsonl` object or a `nagios` run is the sample itself; anything else — a
    /// table under its header, a regex's groups, lines, Prometheus' samples — is rows, one record or many, so a
    /// metric's `rows` names them the same way whatever the frame held. A poll's run ends with its exit code (a Nagios
    /// run's status; whether it failed is the engine's to judge, `ToolPayload.ran`). nil: the frame gave no record.
    public func sample(_ frame: String, at: Date) -> ToolSample? {
        let (text, exit) = ToolPayload.ran(frame)
        let r = Self(format: format, rows: rows, pattern: pattern, names: names, split: nil, sort: sort, limit: limit).records(Data(text.utf8), exit: exit)
        guard !r.rows.isEmpty else { return nil }
        if r.rows.count == 1, [.json, .jsonl, .nagios].contains(format ?? .lines) { return ToolSample(at: at, record: r.rows[0]) }
        return ToolSample(at: at, record: ["rows": .array(r.rows.map(ToolValue.object))])
    }
}

// MARK: Metrics

extension ToolMetric {
    /// The metric's values in `sample` (§8.2): the number at `path`, or in each of `rows` by `key`; `count`: the rows
    /// — `all`, and by each state of `states` (the list's) — ; `rate`: the change per second since `previous`;
    /// `age`: `now` (the server's clock) minus the time at `path`, in `unit`. Empty where the sample hasn't it (a
    /// stream's first line has no rates).
    public func values(in sample: ToolSample, previous: ToolSample?, now: Date, states: ToolStateMap? = nil) -> ToolValues {
        if count != nil, let rows {
            let all = sample.rows(rows)
            var out: ToolValues = ["all": Double(all.count)]
            if let states {
                for s in ToolRowState.allCases {
                    let names = [ToolRowState.ok: states.ok, .warn: states.warn, .bad: states.bad, .off: states.off, .busy: states.busy][s] ?? nil
                    out[s.rawValue] = Double(all.filter { names?.contains($0[states.field]?.text ?? "") == true }.count)
                }
            }
            return out
        }
        guard let path else { return [:] }
        func number(_ r: ToolRecord, _ before: ToolRecord?) -> Double? { raw(r, before).flatMap { $0.isFinite ? $0 : nil } }   // NaN, ±Inf: no value
        func raw(_ r: ToolRecord, _ before: ToolRecord?) -> Double? {
            let v = ToolValue.object(r)[path]
            switch calc {
            case "rate":
                guard let a = v?.number, let before, let b = ToolValue.object(before)[path]?.number, let p = previous else { return nil }
                let dt = sample.at.timeIntervalSince(p.at)
                return dt > 0 ? (a - b) / dt : nil
            case "age":
                guard let v, let d = ToolTemplate.date(v) else { return nil }
                return now.timeIntervalSince(d) / (["h": 3600, "days": 86400, "ms": 0.001][unit ?? ""] ?? 1)
            default: return v?.number
            }
        }
        guard let rows, let key else { return number(sample.record, previous?.record).map { ["": $0] } ?? [:] }
        let was = Dictionary((previous?.rows(rows) ?? []).compactMap { r in r[key].map { ($0.text, r) } }) { a, _ in a }
        return Dictionary(sample.rows(rows).compactMap { r -> (String, Double)? in
            guard let k = r[key]?.text, let n = number(r, was[k]) else { return nil }
            return (k, n)
        }) { a, _ in a }
    }

    /// One number of a metric's values (§6.3): a scalar as it is; over rows, `of` — `max` (the default), `sum`,
    /// `min` or `avg`.
    public static func one(_ values: ToolValues, of: String?) -> Double? {
        if let x = values[""] { return x }
        let all = Array(values.values)
        guard !all.isEmpty else { return nil }
        switch of ?? "max" {
        case "sum": return all.reduce(0, +)
        case "min": return all.min()
        case "avg": return all.reduce(0, +) / Double(all.count)
        default: return all.max()
        }
    }

    /// `v` as the metric shows it: "96%", "1.2 MB/s", "1500 ms", "4.0".
    public func text(_ v: Double) -> String {
        switch unit ?? "" {
        case "%": return ToolTemplate.show(.number(v.rounded()), "%").replacingOccurrences(of: " %", with: "%")
        case "B": return ToolTemplate.show(.number(v), "bytes")
        case "B/s": return ToolTemplate.show(.number(v), "bytes") + "/s"
        case "ms": return ToolTemplate.show(.number(v), "ms")
        case "days": return ToolTemplate.show(.number(v.rounded()), "days")
        case "": return ToolValue.number((v * 100).rounded() / 100).text
        case let u: return ToolValue.number((v * 10).rounded() / 10).text + " " + u
        }
    }
}

// MARK: Series

/// A tool's series on one server: an hour of each metric's values, with the gaps (§8, decision 6).
public struct ToolHistory: Sendable {
    /// Metric → series key → its points, oldest first.
    public private(set) var series: [String: [String: [ToolPoint]]] = [:]
    public private(set) var last: ToolSample?
    /// The sample before `last`: rates and events go by the two.
    public private(set) var previous: ToolSample?
    /// Each row set (a top-level array in a record) → the latest sample that carried it: a stream prints its heavier
    /// reads every few lines (System's processes every 3rd, its disks every 6th), so a table, a count and an
    /// `added` event go by the last sample that had the rows, not by the last line.
    public private(set) var carrying: [String: ToolSample] = [:]
    /// `carrying` as it stood before `last` came: what `last`'s rows are compared with.
    public private(set) var carriedBefore: [String: ToolSample] = [:]
    public var keep: TimeInterval = 3600

    public init(keep: TimeInterval = 3600) { self.keep = keep }

    /// `sample` taken: each metric's values added to its series; the values, for the alerts.
    public mutating func add(_ sample: ToolSample, metrics: [String: ToolMetric], now: Date, states: ToolStateMap? = nil) -> [String: ToolValues] {
        var all: [String: ToolValues] = [:]
        for (id, m) in metrics {
            let v = m.values(in: sample, previous: last, now: now, states: states)
            all[id] = v
            for (key, n) in v { series[id, default: [:]][key, default: []].append(ToolPoint(at: sample.at, value: n)) }
        }
        (previous, last) = (last, sample)
        carriedBefore = carrying
        for (k, v) in sample.record { if case .array = v { carrying[k] = sample } }
        trim(before: sample.at.addingTimeInterval(-keep))
        return all
    }

    /// The latest sample that carried the row set `path` (`list`: the list's, under `rows`), if any.
    public func carried(_ path: String) -> ToolSample? { carrying[path == "list" ? "rows" : path] }
    /// The rows of `path` as the latest sample that carried them had them.
    public func rows(_ path: String) -> [ToolRecord] { carried(path)?.rows(path) ?? [] }

    /// No data from `at` on: a gap point on every series (one per stretch), till the next value.
    public mutating func mark(_ gap: ToolGap, at: Date) {
        for (id, keys) in series {
            for (key, points) in keys where points.last?.gap != gap { series[id]![key]!.append(ToolPoint(at: at, gap: gap)) }
        }
        trim(before: at.addingTimeInterval(-keep))
    }

    public func points(_ metric: String, _ key: String = "") -> [ToolPoint] { series[metric]?[key] ?? [] }

    /// The last values of `metric`, by key: those in the latest sample (nothing through a gap).
    public func latest(_ metric: String) -> ToolValues {
        guard let keys = series[metric] else { return [:] }
        return Dictionary(keys.compactMap { key, points in points.last.flatMap(\.value).map { (key, $0) } }) { a, _ in a }
    }

    private mutating func trim(before: Date) {
        carrying = carrying.filter { $0.value.at >= before }   // a row set that stopped coming isn't shown for ever
        for (id, keys) in series {
            for (key, points) in keys where points.first.map({ $0.at < before }) == true {
                series[id]![key] = Array(points.drop { $0.at < before })
            }
        }
    }
}

// MARK: A chart

/// What a chart draws of one series (§6.3): the runs of values between gaps — a line each, never one across a gap
/// — and each gap as a band from its point to the next point or `now`.
public struct ToolChart: Sendable, Equatable {
    public struct Band: Sendable, Equatable {
        public var from: Date, to: Date
        public var gap: ToolGap
        public init(from: Date, to: Date, gap: ToolGap) { (self.from, self.to, self.gap) = (from, to, gap) }
    }
    public var runs: [[ToolPoint]] = []
    public var bands: [Band] = []

    public init(_ points: [ToolPoint], now: Date) {
        var run: [ToolPoint] = []
        for (i, p) in points.enumerated() {
            guard let gap = p.gap else { run.append(p); continue }
            if !run.isEmpty { runs.append(run); run = [] }
            bands.append(Band(from: p.at, to: points.indices.contains(i + 1) ? points[i + 1].at : now, gap: gap))
        }
        if !run.isEmpty { runs.append(run) }
    }

    /// The top of a chart's scale: `max` (a percentage's 100), else a round number — 1, 2, 2.5, 5 or 10 times a
    /// power of ten — a little over the highest value.
    public static func top(_ values: [Double], max: Double?) -> Double {
        if let max { return max }
        let v = Swift.max(1, values.max() ?? 1) * 1.15
        let p = pow(10, floor(log10(v)))
        return [1, 2, 2.5, 5, 10].first { $0 * p >= v }! * p   // v < 10·p by construction
    }

    /// The point nearest `at` among `points` with a value; nil past `within` seconds of any.
    public static func nearest(_ points: [ToolPoint], to at: Date, within: TimeInterval) -> ToolPoint? {
        let p = points.filter { $0.value != nil }.min { abs($0.at.timeIntervalSince(at)) < abs($1.at.timeIntervalSince(at)) }
        return p.flatMap { abs($0.at.timeIntervalSince(at)) <= within ? $0 : nil }
    }
}

// MARK: Alerts

public enum ToolLevel: Int, Sendable, Comparable, Codable {
    case warning = 1, critical = 2
    public static func < (a: ToolLevel, b: ToolLevel) -> Bool { a.rawValue < b.rawValue }
    public var name: String { self == .critical ? "critical" : "warning" }
}

/// An alert's standing on one series (§8.3).
public struct ToolAlertState: Sendable, Equatable {
    public var level: ToolLevel?
    /// When it was raised, for "after 12 min" when it's back; the message then.
    public var since: Date?
    public var message: String?
    /// Past each level's threshold since (real samples in a row; a gap starts it over).
    var over: [ToolLevel: Date] = [:]
    var streak: [ToolLevel: Int] = [:]
}

/// What a sample changed: for the worse — with its message — or back to normal (only a real sample says so, §2).
public enum ToolAlertChange: Sendable, Equatable {
    case worse(alert: String, key: String, level: ToolLevel, message: String)
    case ok(alert: String, key: String, was: ToolLevel, since: Date)
}

/// A tool's alerts on one server, each per series.
public struct ToolAlerts: Sendable {
    /// Alert id → series key → its standing.
    public private(set) var states: [String: [String: ToolAlertState]] = [:]

    public init() {}

    /// A real sample's `values` (by metric) judged against `alerts` (§8.3): past `warn` / `crit` (`below`: under it),
    /// held for `for` or `checks` samples in a row; one message per change for the worse. `message` is the alert's
    /// template with `{value}` and the row's fields (`sample`), else "CPU 96% for 5 min" / "/var 86%".
    public mutating func judge(_ values: [String: ToolValues], alerts: [ToolAlert], metrics: [String: ToolMetric], sample: ToolSample, now: Date) -> [ToolAlertChange] {
        var changes: [ToolAlertChange] = []
        for a in alerts {
            guard let metricID = a.metric, let m = metrics[metricID], let found = values[metricID] else { continue }
            let id = a.id ?? metricID
            for (key, v) in found {
                var s = states[id]?[key] ?? ToolAlertState()
                let was = s.level
                var held: ToolLevel?
                for (level, threshold) in [(ToolLevel.critical, a.crit), (.warning, a.warn)] {
                    guard let threshold else { continue }
                    let past = a.below == true ? v <= threshold : v >= threshold
                    guard past else { (s.over[level], s.streak[level]) = (nil, 0); continue }
                    s.over[level] = s.over[level] ?? sample.at
                    s.streak[level, default: 0] += 1
                    let long = (level == .critical ? a.for?.crit : a.for?.warn)?.seconds
                    // Held long enough — or standing already: past its threshold, an alert stays (a gap started the count over).
                    let ok = was.map { $0 >= level } == true || (long.map { sample.at.timeIntervalSince(s.over[level]!) >= $0 } ?? a.checks.map { s.streak[level]! >= $0 } ?? true)
                    if ok, held == nil { held = level }
                }
                s.level = held
                if let held, held > (was ?? .warning) || was == nil {
                    s.since = s.since ?? sample.at
                    s.message = message(a, m, key: key, value: v, level: held, sample: sample)
                    changes.append(.worse(alert: id, key: key, level: held, message: s.message!))
                } else if let held, let was, held < was {
                    s.message = message(a, m, key: key, value: v, level: held, sample: sample)   // down to a warning: its words, no message
                } else if held == nil, let was, let since = s.since {
                    (s.since, s.message) = (nil, nil)
                    changes.append(.ok(alert: id, key: key, was: was, since: since))
                }
                states[id, default: [:]][key] = s
            }
        }
        return changes
    }

    /// A gap (§2): nothing recovers; durations and streaks start over after it.
    public mutating func gap() {
        for (id, keys) in states {
            for key in keys.keys { (states[id]![key]!.over, states[id]![key]!.streak) = ([:], [:]) }
        }
    }

    /// Watching ended: its standings go without a word (a stop is no recovery).
    public mutating func clear() { states = [:] }

    /// The worst level standing on any series.
    public var worst: ToolLevel? { states.values.flatMap { $0.values.compactMap(\.level) }.max() }

    /// The worst level standing on `metric`'s series, by the alert that watches it.
    public func worst(metric: String, alerts: [ToolAlert]) -> ToolLevel? {
        alerts.first { $0.metric == metric }.flatMap { states[$0.id ?? metric]?.values.compactMap(\.level).max() }
    }

    /// Every series past a threshold: alert id, key, standing.
    public var standing: [(alert: String, key: String, state: ToolAlertState)] {
        states.flatMap { id, keys in keys.compactMap { $0.value.level == nil ? nil : (id, $0.key, $0.value) } }.sorted { ($0.alert, $0.key) < ($1.alert, $1.key) }
    }

    private func message(_ a: ToolAlert, _ m: ToolMetric, key: String, value: Double, level: ToolLevel, sample: ToolSample) -> String {
        let row = m.rows.flatMap { rows in sample.rows(rows).first { $0[m.key ?? ""]?.text == key } }
        if let t = a.message {
            return ToolTemplate.text(t, .init(inputs: ["value": .number(value)], rows: [row ?? sample.record]))
        }
        let shown = m.text(value), long = (level == .critical ? a.for?.crit : a.for?.warn)?.seconds
        return (row == nil ? "\(m.title ?? a.metric ?? "") \(shown)" : "\(key) \(shown)") + (long.map { " for " + Self.minutes($0) } ?? "")
    }

    /// "45 s", "12 min", "3 h".
    public static func minutes(_ s: Double) -> String { s < 60 ? "\(Int(s)) s" : s < 3600 ? "\(Int(s / 60)) min" : "\(Int(s / 3600)) h" }
}

// MARK: Events

/// An event that happened (§8.4, §8.7): the tool's, or the script's `_event`.
public struct ToolEventRecord: Sendable, Equatable {
    public var at: Date
    public var id: String
    /// `info`, `warning`, `critical`; `ok` closes a script's event.
    public var level: String
    public var message: String
    public var goto: String?
    public init(at: Date, id: String, level: String, message: String, goto: String? = nil) {
        (self.at, self.id, self.level, self.message, self.goto) = (at, id, level, message, goto)
    }
}

public enum ToolEvents {
    /// The events `sample` raises against `previous` (§8.4): `changed` and `increased` of `path`, `added` and `left`
    /// of `rows` by `key`, `is` of `path` or a row's `field` — the first sample raises `is` alone (the state is so;
    /// nothing was added to nothing). `if` / `unless`: a field that must be non-empty / empty. `scope`: the names
    /// around the sample (vars, Kermo's). `carrying`: for each row set, the last sample before this one that had it
    /// (`ToolHistory.carriedBefore`) — rows that come every few lines are compared with the last that came, else a
    /// failed unit would be "added" again each time the set came round; nil: `previous` is it.
    public static func raised(_ events: [ToolEvent], in sample: ToolSample, previous: ToolSample?, carrying: [String: ToolSample]? = nil,
                              scope: ToolTemplate.Scope = .init()) -> [ToolEventRecord] {
        var out: [ToolEventRecord] = []
        func fits(_ e: ToolEvent, _ r: ToolRecord) -> Bool {
            var s = scope
            s.levels.insert(r, at: 1)
            return (e.if.map { !s.isEmpty($0) } ?? true) && (e.unless.map { s.isEmpty($0) } ?? true)
        }
        func raise(_ e: ToolEvent, _ r: ToolRecord) {
            var s = scope
            s.levels.insert(r, at: 1)
            if r != sample.record { s.levels.insert(sample.record, at: 2) }
            out.append(ToolEventRecord(at: sample.at, id: e.id ?? e.when ?? "", level: e.level ?? "info",
                                       message: e.message.map { ToolTemplate.text($0, s) } ?? (e.id ?? ""), goto: e.goto.map { ToolTemplate.text($0, s) }))
        }
        for e in events {
            if let rows = e.rows, let key = e.key {
                let earlier: ToolSample? = if let carrying { carrying[rows == "list" ? "rows" : rows] } else { previous }
                let now = sample.rows(rows), was = earlier?.rows(rows)
                let before = Dictionary((was ?? []).compactMap { r in r[key].map { ($0.text, r) } }) { a, _ in a }
                for r in now where fits(e, r) {
                    guard let k = r[key]?.text else { continue }
                    let old = before[k]
                    let value = e.field.flatMap { r[$0] }
                    switch e.when {
                    case "added": if was != nil, old == nil { raise(e, r) }
                    case "left": if let old, let f = e.field, old[f] == e.from, value != e.from { raise(e, r) }
                    case "is": if value == e.value, old.map({ $0[e.field ?? ""] != e.value }) ?? true { raise(e, r) }
                    case "changed": if let old, let p = e.path, old[p] != r[p] { raise(e, r) }
                    case "increased": if let old, let p = e.path, let a = r[p]?.number, let b = old[p]?.number, a > b { raise(e, r) }
                    default: break
                    }
                }
                continue
            }
            guard let path = e.path, fits(e, sample.record) else { continue }
            let value = ToolValue.object(sample.record)[path], old = previous.map { ToolValue.object($0.record)[path] }
            switch e.when {
            case "changed": if let old, old != nil, old != value { raise(e, sample.record) }
            case "increased": if let a = value?.number, let b = old??.number, a > b { raise(e, sample.record) }
            case "is": if value == e.value, (old ?? nil) != e.value || previous == nil { raise(e, sample.record) }
            default: break
            }
        }
        return out
    }

    /// The script's own event in `sample` (§8.7): `"_event": { "id", "level", "message" }`.
    public static func scripted(_ sample: ToolSample) -> ToolEventRecord? {
        guard case .object(let e)? = sample.record["_event"], let id = e["id"]?.text, let level = e["level"]?.text else { return nil }
        return ToolEventRecord(at: sample.at, id: id, level: level, message: e["message"]?.text ?? id)
    }
}

/// How many `_event`s a tool may deliver (§8.7, Q22): 10 an hour; past that, "N more" once the hour turns.
public struct ToolEventBudget: Sendable {
    public static let perHour = 10
    private var times: [Date] = []
    public private(set) var held = 0

    public init() {}

    /// Whether this one goes through now; a refused one is counted for "N more".
    public mutating func allows(_ now: Date) -> Bool {
        times.removeAll { now.timeIntervalSince($0) >= 3600 }
        guard times.count < Self.perHour else { held += 1; return false }
        times.append(now)
        return true
    }

    /// The ones held back, and the count starts over.
    public mutating func takeHeld() -> Int { defer { held = 0 }; return held }
}
