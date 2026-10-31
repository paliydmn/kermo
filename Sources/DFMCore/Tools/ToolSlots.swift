import Foundation

/// The history on disk (decision 6): a watched tool's series as 15-minute slots — each series' min, average and max —
/// and the gaps, a JSON line each, in a file a day per server (`<day>.jsonl`, UTC), 7 days kept. The hour in memory
/// is `ToolHistory`; this is what 24h and 7d draw. A slot is written once it's over, so the disk sees a line per tool
/// every 15 minutes (≈100 KB a server a week). Times are the server's clock, as the series'.
public struct ToolSlots: Sendable {
    public static let length: TimeInterval = 900
    public static let days = 7

    /// One line: a tool's slot from `t` (`v`: metric → series key → [min, avg, max]), or a gap from `t` till the
    /// next slot.
    public struct Line: Sendable, Codable, Equatable {
        public var t: Double
        public var tool: String
        public var v: [String: [String: [Double]]]?
        public var gap: ToolGap?
        public init(t: Double, tool: String, v: [String: [String: [Double]]]? = nil, gap: ToolGap? = nil) { (self.t, self.tool, self.v, self.gap) = (t, tool, v, gap) }
    }

    public let tool: String
    /// The slot being filled: its start, and each series' min, sum, count and max.
    private var start: Double?
    private var sums: [String: [String: (min: Double, sum: Double, n: Double, max: Double)]] = [:]
    /// The gap written last, till values come again: a reconnect that repeats is one line.
    private var gapped: ToolGap?

    public init(tool: String) { self.tool = tool }

    public static func slot(_ at: Date) -> Double { floor(at.timeIntervalSince1970 / length) * length }

    /// A sample's `values` (by metric) at `at` into the slot; the slot before it, if `at` is past it.
    public mutating func add(_ values: [String: ToolValues], at: Date) -> [Line] {
        let slot = Self.slot(at), done = start.map { $0 != slot } == true ? flush() : []
        start = slot
        gapped = nil
        for (metric, keys) in values {
            for (key, v) in keys {
                let a = sums[metric]?[key] ?? (v, 0, 0, v)
                sums[metric, default: [:]][key] = (Swift.min(a.min, v), a.sum + v, a.n + 1, Swift.max(a.max, v))
            }
        }
        return done
    }

    /// No data from `at` on (asleep, not watched, no answer): the slot so far, and the gap — once a stretch.
    public mutating func mark(_ gap: ToolGap, at: Date) -> [Line] {
        guard gap != gapped, gap != .maintenance else { return [] }
        gapped = gap
        return flush() + [Line(t: at.timeIntervalSince1970.rounded(), tool: tool, gap: gap)]
    }

    /// The slot so far as a line, and a new one begins.
    public mutating func flush() -> [Line] {
        defer { (start, sums) = (nil, [:]) }
        guard let start, !sums.isEmpty else { return [] }
        return [Line(t: start, tool: tool, v: sums.mapValues { $0.mapValues { a in [a.min, (a.sum / a.n * 100).rounded() / 100, a.max] } })]
    }

    // MARK: The files

    /// `lines` at the end of their days' files in `dir` (0700; each file 0600), and the files past 7 days deleted.
    /// ponytail: a file opened and closed each slot — 96 appends a day a server.
    public static func append(_ lines: [Line], to dir: String) {
        guard !lines.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let oldest = name(Date().addingTimeInterval(-Double(days + 1) * 86400))
        for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".jsonl") && f < oldest { try? fm.removeItem(atPath: dir + "/" + f) }
        for (day, some) in Dictionary(grouping: lines, by: { name(Date(timeIntervalSince1970: $0.t)) }) {
            let path = dir + "/" + day
            if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            guard let h = FileHandle(forWritingAtPath: path) else { continue }
            h.seekToEndOfFile()
            h.write(Data(some.compactMap { try? String(decoding: JSONEncoder.sorted.encode($0), as: UTF8.self) }.joined(separator: "\n").utf8 + [0x0A]))
            try? h.close()
        }
    }

    /// `tool`'s lines in `dir` from `from` on, oldest first; a line that doesn't read is left out.
    public static func read(_ dir: String, tool: String, from: Date) -> [Line] {
        let first = name(from)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jsonl") && $0 >= first }.sorted()
        return files.flatMap { f in
            (try? String(contentsOfFile: dir + "/" + f, encoding: .utf8))?.split(separator: "\n").compactMap { try? JSONDecoder().decode(Line.self, from: Data($0.utf8)) } ?? []
        }.filter { $0.tool == tool && $0.t >= from.timeIntervalSince1970 - length }.sorted { $0.t < $1.t }
    }

    static func name(_ d: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: d)
        return String(format: "%04d-%02d-%02d.jsonl", c.year!, c.month!, c.day!)
    }

    // MARK: A chart

    /// `metric`'s series `key` in `lines` (oldest first) as a chart's points from `from`: each slot's average at its
    /// start (a slot written early — at a sleep, a stop — never lands past now), and the gaps: the ones written, and
    /// "not watched" where slots are missing (Kermo not running, the server not watched) and before the first.
    public static func points(_ lines: [Line], metric: String, key: String, from: Date) -> [ToolPoint] {
        var out: [ToolPoint] = []
        var end = from.timeIntervalSince1970   // where the last slot ended
        for l in lines {
            if let gap = l.gap {
                if out.last?.gap == nil { out.append(ToolPoint(at: Date(timeIntervalSince1970: l.t), gap: gap)) }
                continue
            }
            guard let v = l.v?[metric]?[key], v.count == 3 else { continue }
            if l.t > end + 1, out.last?.gap == nil { out.append(ToolPoint(at: Date(timeIntervalSince1970: end), gap: .notWatched)) }
            out.append(ToolPoint(at: Date(timeIntervalSince1970: l.t), value: v[1]))
            end = l.t + length
        }
        return out
    }

    /// The series keys of `metric` in `lines`, sorted.
    public static func keys(_ lines: [Line], metric: String) -> [String] { Set(lines.flatMap { $0.v?[metric]?.keys.map { $0 } ?? [] }).sorted() }
}
