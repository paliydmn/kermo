import Foundation
import Testing
@testable import DFMCore

// What the charts hand on (review 4 PR 4): a CSV field quoted and kept from reading as a formula, numbers exact, times
// ISO 8601 with the offset, a row a sample, a slot or a gap; a series' average, lowest and highest without the gaps.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 900))   // a slot's start
private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
/// A time as the CSV writes it in `zone`.
private func isoTime(_ d: Date, _ zone: TimeZone) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = zone
    return f.string(from: d)
}

@Test func aCSVFieldIsQuotedAndNeverAFormula() {
    #expect(ToolExport.field("plain") == "plain" && ToolExport.field("") == "")
    #expect(ToolExport.field("a,b") == "\"a,b\"" && ToolExport.field("say \"hi\"") == "\"say \"\"hi\"\"\"" && ToolExport.field("two\nlines") == "\"two\nlines\""
            && ToolExport.field("cr\rhere") == "\"cr\rhere\"" && ToolExport.field("crlf\r\nhere") == "\"crlf\r\nhere\"")
    #expect(ToolExport.field("=1+1") == "'=1+1" && ToolExport.field("+x") == "'+x" && ToolExport.field("-dev") == "'-dev" && ToolExport.field("@a") == "'@a")
    #expect(ToolExport.field("\tx") == "'\tx" && ToolExport.field("\rx") == "\"'\rx\"", "a tab or CR first: guarded, and CR quoted")
    #expect(ToolExport.field("=HYPERLINK(\"http://x\",\"y\")") == "\"'=HYPERLINK(\"\"http://x\"\",\"\"y\"\")\"", "guarded, then quoted")
    #expect(ToolExport.field("/var/log") == "/var/log" && ToolExport.field("https://a.example/x?y=1") == "https://a.example/x?y=1")
}

@Test func aCSVNumberIsExact() {
    #expect(["0.1", "1234567.891", "1e-07", "-5", "0", "42", "2.5"] == [0.1, 1234567.891, 1e-07, -5, 0, 42, 2.5].map { ToolExport.number($0) })
    #expect(ToolExport.number(nil) == "" && ToolExport.number(1e20) == "1e+20" && Double(ToolExport.number(1.0 / 3)) == 1.0 / 3, "reads back as it was")
}

@Test func aCSVTimeHasItsOffset() throws {
    let d = try #require(ISO8601DateFormatter().date(from: "2026-11-10T12:19:30Z"))
    func row(_ zone: TimeZone?) throws -> String {
        try ToolExport.csv([.init(chart: "c", metric: "m", key: "", unit: "", points: [.init(at: d, value: 1)])], slot: nil, zone: #require(zone)).components(separatedBy: "\r\n")[1]
    }
    #expect(try row(TimeZone(secondsFromGMT: 7200)) == "2026-11-10T14:19:30+02:00,,c,m,,,1,,,,sample")
    #expect(try row(TimeZone(secondsFromGMT: -(3 * 3600 + 1800))).hasPrefix("2026-11-10T08:49:30-03:30,"))
    #expect(try row(TimeZone(identifier: "UTC")).hasPrefix("2026-11-10T12:19:30Z,"))
}

/// A row a point: a sample's value, a slot's lowest, average and highest with its 15 minutes, a gap's reason with
/// nothing for its numbers — never a 0; names guarded, the unit with each row.
@Test func aCSVHasARowAPoint() throws {
    let zone = try #require(TimeZone(secondsFromGMT: 7200)), iso = { isoTime($0, zone) }
    let samples = ToolExport.Series(chart: "Disks", metric: "disk", key: "=cmd|' /C calc'!A0", unit: "%",
                                    points: [.init(at: at(0), value: 40.5), .init(at: at(5), gap: .asleep), .init(at: at(60), value: 0), .init(at: at(65), gap: .noAnswer)])
    let csv = ToolExport.csv([samples], slot: nil, zone: zone)
    #expect(csv == [ToolExport.header,
                    "\(iso(at(0))),,Disks,disk,'=cmd|' /C calc'!A0,%,40.5,,,,sample",
                    "\(iso(at(5))),,Disks,disk,'=cmd|' /C calc'!A0,%,,,,,asleep",
                    "\(iso(at(60))),,Disks,disk,'=cmd|' /C calc'!A0,%,0,,,,sample",
                    "\(iso(at(65))),,Disks,disk,'=cmd|' /C calc'!A0,%,,,,,no answer", ""].joined(separator: "\r\n"), "\(csv)")
    let slots = ToolExport.Series(chart: "CPU · I/O wait", metric: "cpu", key: "", unit: "%",
                                  points: [.init(at: at(0), value: 12.25, low: 3, high: 97.5), .init(at: at(900), gap: .notWatched)])
    let lines = ToolExport.csv([slots], slot: 900, zone: zone).components(separatedBy: "\r\n")
    #expect(lines.dropFirst().first == "\(iso(at(0))),\(iso(at(900))),CPU · I/O wait,cpu,,%,,3,12.25,97.5,slot" && lines[2] == "\(iso(at(900))),,CPU · I/O wait,cpu,,%,,,,,not watched"
            && lines.count == 4 && lines.last == "", "\(lines)")
    #expect(ToolExport.csv([], slot: nil, zone: zone) == ToolExport.header + "\r\n", "nothing drawn: the header")
    let early = ToolExport.Series(chart: "CPU", metric: "cpu", key: "", unit: "%", points: [.init(at: at(0), value: 5, low: 1, high: 9), .init(at: at(420), gap: .asleep)])
    #expect(ToolExport.csv([early], slot: 900, zone: zone).components(separatedBy: "\r\n")[1].hasPrefix("\(iso(at(0))),\(iso(at(420))),"), "a slot written early at a sleep ends where the gap begins")
}

/// A series' numbers without its gaps; on the history a slot's highest at the slot's start, its lowest the lowest low.
@Test func aSeriesStatsLeaveTheGapsOut() throws {
    #expect(ToolExport.stats([]) == nil && ToolExport.stats([.init(at: at(0), gap: .asleep)]) == nil, "nothing recorded: no numbers, not zeros")
    let s = try #require(ToolExport.stats([.init(at: at(0), value: 10), .init(at: at(5), gap: .asleep), .init(at: at(30), value: 30), .init(at: at(35), value: 30), .init(at: at(40), value: 2)]))
    #expect(s == .init(average: 18, highest: 30, highestAt: at(30)), "the first time it was highest")
    let h = try #require(ToolExport.stats([.init(at: at(0), value: 20, low: 5, high: 90), .init(at: at(900), value: 40, low: 30, high: 50)]))
    #expect(h == .init(average: 30, highest: 90, highestAt: at(0)), "the history: the slot whose highest was highest")
}
