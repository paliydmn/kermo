import Foundation
import Testing
@testable import DFMCore

// The history on disk: 15-minute slots of each series (min, average, max) and the gaps, a line each, a file a day;
// 7 days kept; the points 24h and 7d draw, with "not watched" where slots are missing.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 900))   // a slot's start
private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

@Test func aSlotIsWrittenOnceItsOver() {
    var s = ToolSlots(tool: "system")
    #expect(s.add(["cpu": ["": 10]], at: at(0)).isEmpty && s.add(["cpu": ["": 30]], at: at(300)).isEmpty)
    #expect(s.add(["cpu": ["": 20], "disk": ["/": 50, "/var": 60]], at: at(600)).isEmpty)
    let done = s.add(["cpu": ["": 99]], at: at(900))
    #expect(done == [.init(t: t0.timeIntervalSince1970, tool: "system", v: ["cpu": ["": [10, 20, 30]], "disk": ["/": [50, 50, 50], "/var": [60, 60, 60]]])])
    let slept = s.mark(.asleep, at: at(1000))
    #expect(slept.map(\.gap) == [nil, .asleep] && slept[0].v?["cpu"]?[""] == [99, 99, 99] && slept[1].t == at(1000).timeIntervalSince1970)
    #expect(s.mark(.asleep, at: at(1100)).isEmpty && s.mark(.reconnecting, at: at(1200)).map(\.gap) == [.reconnecting], "once a stretch")
    #expect(s.mark(.maintenance, at: at(1300)).isEmpty, "maintenance is a band over values, not a gap")
    _ = s.add(["cpu": ["": 5]], at: at(5000))
    #expect(s.mark(.reconnecting, at: at(5001)).count == 2, "values came: a new stretch")
    #expect(s.flush().isEmpty)
}

@Test func slotsGoToADayFileAndAWeekIsKept() throws {
    let dir = NSTemporaryDirectory() + "kermo-slots-\(UUID().uuidString)/server"
    defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }
    let now = Date(), day = floor(now.timeIntervalSince1970 / 86400) * 86400 + 43200   // today's noon, UTC: one file
    ToolSlots.append([.init(t: day - 900, tool: "system", v: ["cpu": ["": [1, 2, 3]]]), .init(t: day - 900, tool: "sites", v: ["up": ["https://a": [1, 1, 1]]]),
                      .init(t: day - 300, tool: "system", gap: .asleep)], to: dir)
    let old = ToolSlots.name(now.addingTimeInterval(-9 * 86400)), kept = ToolSlots.name(now.addingTimeInterval(-6 * 86400))
    for f in [old, kept] { FileManager.default.createFile(atPath: dir + "/" + f, contents: Data()) }
    ToolSlots.append([.init(t: day, tool: "system", v: ["cpu": ["": [4, 5, 6]]])], to: dir)
    let today = dir + "/" + ToolSlots.name(Date(timeIntervalSince1970: day))
    #expect(!FileManager.default.fileExists(atPath: dir + "/" + old) && FileManager.default.fileExists(atPath: dir + "/" + kept), "past 7 days: gone")
    #expect((try FileManager.default.attributesOfItem(atPath: today)[.posixPermissions] as? Int) == 0o600)
    #expect((try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? Int) == 0o700)
    let lines = ToolSlots.read(dir, tool: "system", from: Date(timeIntervalSince1970: day - 900))
    #expect(lines.map(\.t) == [day - 900, day - 300, day] && lines[1].gap == .asleep && lines[2].v?["cpu"]?[""] == [4, 5, 6], "\(lines)")
    #expect(ToolSlots.read(dir, tool: "system", from: Date(timeIntervalSince1970: day + 900)).map(\.t) == [day], "from: the slot that holds it on")
}

@Test func aWeeksPointsWithTheirGaps() {
    let lines: [ToolSlots.Line] = [
        .init(t: at(900).timeIntervalSince1970, tool: "s", v: ["cpu": ["": [1, 10, 20]]]),
        .init(t: at(1800).timeIntervalSince1970, tool: "s", v: ["cpu": ["": [1, 12, 20]]]),
        .init(t: at(2000).timeIntervalSince1970, tool: "s", gap: .asleep),
        .init(t: at(9000).timeIntervalSince1970, tool: "s", v: ["cpu": ["": [1, 30, 40]]]),
        .init(t: at(18000).timeIntervalSince1970, tool: "s", v: ["cpu": ["": [1, 40, 50]], "disk": ["/": [5, 5, 5]]]),
    ]
    let p = ToolSlots.points(lines, metric: "cpu", key: "", from: t0)
    let want: [ToolPoint] = [.init(at: t0, gap: .notWatched), .init(at: at(900), value: 10), .init(at: at(1800), value: 12),
                             .init(at: at(2000), gap: .asleep), .init(at: at(9000), value: 30), .init(at: at(9900), gap: .notWatched), .init(at: at(18000), value: 40)]
    #expect(p == want, "\(p)")
    let twice = [lines[1], .init(t: at(2000).timeIntervalSince1970, tool: "s", gap: .asleep), .init(t: at(2100).timeIntervalSince1970, tool: "s", gap: .reconnecting)]
    #expect(ToolSlots.points(twice, metric: "cpu", key: "", from: at(1800)).compactMap(\.gap) == [.asleep, .reconnecting], "a gap of another kind is a band of its own")
    #expect(ToolSlots.keys(lines, metric: "disk") == ["/"] && ToolSlots.points(Array(lines.suffix(1)), metric: "disk", key: "/", from: at(18000)) == [.init(at: at(18000), value: 5)])
}
