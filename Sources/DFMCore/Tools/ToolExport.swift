import Foundation

/// What the charts hand on (review 4 §6.6, plan PR 4): a CSV of the series drawn, a row a point — long, so its columns
/// stay the same whatever the series —, and the numbers a summary says. Numbers unrounded; times ISO 8601 with the
/// offset; a gap a row with its reason, never a zero; text from a server (a mount, an address) is only ever text:
/// quoted, and kept from reading as a formula in a spreadsheet.
public enum ToolExport {
    /// One series as drawn: its chart's title, its metric's id, its key ("" for a metric of one value), its unit.
    public struct Series: Sendable {
        public let chart, metric, key, unit: String
        public let points: [ToolPoint]
        public init(chart: String, metric: String, key: String, unit: String, points: [ToolPoint]) {
            (self.chart, self.metric, self.key, self.unit, self.points) = (chart, metric, key, unit, points)
        }
    }

    /// The columns, a contract: a script that reads them keeps working.
    public static let header = "interval_start,interval_end,chart,metric,series,unit,value,min,avg,max,quality"

    /// `series` as CSV — UTF-8, CRLF, the header first. A sample: its time and `value`, `sample`; a slot of the history
    /// (`slot`: its length): its start and end — where a gap begins, if one does before (a slot written early, at a
    /// sleep) —, `min`, `avg`, `max`, `slot`; a gap: its start and why.
    public static func csv(_ series: [Series], slot: TimeInterval?, zone: TimeZone) -> String {
        let iso = ISO8601DateFormatter()   // once: a week of six charts is ~24,000 rows
        iso.timeZone = zone
        var lines = [header]
        for s in series {
            let named = [s.chart, s.metric, s.key, s.unit].map(field).joined(separator: ",")
            for (i, p) in s.points.enumerated() {
                let start = iso.string(from: p.at)
                if let gap = p.gap { lines.append("\(start),,\(named),,,,,\(field(quality(gap)))") }
                else if let v = p.value, let slot {
                    let next = s.points.indices.contains(i + 1) ? s.points[i + 1] : nil, cut = next.flatMap { $0.gap != nil && $0.at > p.at ? $0.at : nil }
                    lines.append("\(start),\(iso.string(from: min(p.at.addingTimeInterval(slot), cut ?? .distantFuture))),\(named),,\(number(p.low)),\(number(v)),\(number(p.high)),slot")
                } else if let v = p.value { lines.append("\(start),,\(named),\(number(v)),,,,sample") }
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// A text field (RFC 4180): in quotes, its quotes doubled, where it has a comma, a quote or a line break; one that
    /// starts as a formula would (`=`, `+`, `-`, `@`, a tab, CR) behind a `'` first (OWASP CSV injection). Numbers
    /// don't come here: -5 is a number.
    public static func field(_ s: String) -> String {
        // by scalars: "\r\n" is one Character, and neither "\r" nor "\n" alone would match it
        let s = s.unicodeScalars.first.map { "=+-@\t\r".unicodeScalars.contains($0) } == true ? "'" + s : s
        return s.unicodeScalars.contains(where: { ",\"\r\n".unicodeScalars.contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// `v` exactly — the shortest text that reads back as it, a point for the decimals, no grouping; a whole number
    /// without ".0". nil: nothing.
    public static func number(_ v: Double?) -> String {
        guard let v else { return "" }
        return v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : "\(v)"
    }

    /// A gap's reason in a CSV's `quality`.
    public static func quality(_ g: ToolGap) -> String {
        switch g { case .asleep: "asleep"; case .noAnswer: "no answer"; case .reconnecting: "reconnecting"; case .notWatched: "not watched"; case .maintenance: "maintenance" }
    }

    /// What a series did over its points: gaps don't count. On the history each point is a slot — the average is the
    /// slots' averages' (a slot doesn't keep how many samples it had), the highest a slot's highest at its start.
    public struct Stats: Sendable, Equatable {
        public let average, highest: Double
        public let highestAt: Date
    }

    public static func stats(_ points: [ToolPoint]) -> Stats? {
        let values = points.filter { $0.gap == nil && $0.value != nil }
        guard let top = values.max(by: { ($0.high ?? $0.value!) < ($1.high ?? $1.value!) }) else { return nil }
        return Stats(average: values.reduce(0) { $0 + $1.value! } / Double(values.count), highest: top.high ?? top.value!, highestAt: top.at)
    }
}
