import Foundation
import Testing
@testable import DFMCore

// Watching's pure part (protocol §8): frames and samples, metrics with rate and age, series with gaps, alerts held
// for a time or a count — a gap keeps them, one message per change for the worse — and events, each `when`.

private let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/tools")
private func fixture(_ name: String) throws -> String { try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8) }
private let system = try! #require(ToolSchema.validate(try Data(contentsOf: ToolPreset.builtInFolder.appendingPathComponent("system.json")), file: "system.json").preset)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
private func sample(_ s: Double, _ record: ToolRecord) -> ToolSample { ToolSample(at: at(s), record: record) }
private func cpu(_ pct: Double) -> ToolRecord { ["cpu": .object(["pct": .number(pct)])] }

/// System's recorded stream, each line a sample.
private func systemSamples() throws -> [ToolSample] {
    let parse = try #require(system.stream).parse
    return try fixture("system.stream.jsonl").split(separator: "\n").enumerated().compactMap { i, l in parse.sample(String(l), at: at(Double(i) * 5)) }
}

@Test func metricsFromASystemSample() throws {
    let samples = try systemSamples(), m = try #require(system.metrics)
    #expect(samples.count == 5)
    #expect(m["cpu"]!.values(in: samples[0], previous: nil, now: at(0)) == [:], "the first line has no rates")
    #expect(m["cpu"]!.values(in: samples[1], previous: samples[0], now: at(5)) == ["": 8])
    #expect(m["mem"]!.values(in: samples[0], previous: nil, now: at(0)) == ["": 39.4])
    #expect(m["load"]!.values(in: samples[0], previous: nil, now: at(0)) == ["": 0.2])
    #expect(m["disk"]!.values(in: samples[0], previous: nil, now: at(0)) == ["/": 26, "/boot/efi": 2])
    #expect(m["inodes"]!.values(in: samples[0], previous: nil, now: at(0)) == ["/": 4, "/boot/efi": 0])
    #expect(m["disk"]!.values(in: samples[1], previous: samples[0], now: at(5)) == [:], "disks come every 6th line")
    #expect(m["rx"]!.text(1968170) == "2 MB/s" && m["cpu"]!.text(8.26) == "8%" && m["load"]!.text(0.2) == "0.2")
}

@Test func rateAndAgeAreComputed() {
    let rate = ToolMetric(path: "bytes", unit: "B/s", calc: "rate"), age = ToolMetric(path: "time", unit: "h", calc: "age")
    let a = sample(0, ["bytes": 100, "time": .number(at(-7200).timeIntervalSince1970)]), b = sample(10, ["bytes": 160])
    #expect(rate.values(in: a, previous: nil, now: at(0)) == [:] && rate.values(in: b, previous: a, now: at(10)) == ["": 6])
    #expect(age.values(in: a, previous: nil, now: at(0)) == ["": 2])
    let iso = sample(0, ["time": "2027-01-15T10:00:00Z"])
    #expect(age.values(in: iso, previous: nil, now: ToolTemplate.date("2027-01-15T12:00:00Z")!) == ["": 2])
    let per = ToolMetric(path: "n", rows: "hosts", key: "host", calc: "rate")
    let h1 = sample(0, ["hosts": .array([.object(["host": "a", "n": 10]), .object(["host": "b", "n": 5])])])
    let h2 = sample(5, ["hosts": .array([.object(["host": "a", "n": 20]), .object(["host": "c", "n": 1])])])
    #expect(per.values(in: h2, previous: h1, now: at(5)) == ["a": 2], "a row that's new has no rate yet")
}

@Test func aCountByState() {
    let m = ToolMetric(rows: "list", count: "state"), states = ToolStateMap(field: "last_status", ok: ["ready"], bad: ["failed"])
    let s = sample(0, ["rows": .array([.object(["last_status": "ready"]), .object(["last_status": "ready"]), .object(["last_status": "failed"])])])
    let v = m.values(in: s, previous: nil, now: at(0), states: states)
    #expect(v["all"] == 3 && v["ok"] == 2 && v["bad"] == 1 && v["warn"] == 0)
    #expect(m.values(in: s, previous: nil, now: at(0)) == ["all": 3])
    #expect(m.values(in: sample(5, ["hosts": .array([])]), previous: nil, now: at(5), states: states) == [:], "a line without the list counts none, not zero")
    #expect(m.values(in: sample(5, ["rows": .array([])]), previous: nil, now: at(5))["all"] == 0, "an empty list is zero")
}

/// dpl's list read beside its stream (§8.7): the list's sample feeds its count and leaves the stream's `last` — the
/// stream's rates and events go on from their own line; the stream's lines leave the count as the list had it; a
/// gap of one source marks its metrics only.
@Test func aListsSampleSitsBesideTheStreams() throws {
    let dpl = try #require(ToolSchema.validate(try Data(contentsOf: ToolPreset.builtInFolder.appendingPathComponent("dpl.json")), file: "dpl.json").preset)
    #expect(dpl.watchesList && dpl.watchable && !system.watchesList)
    let metrics = (dpl.metrics ?? [:]).merging(["req": ToolMetric(path: "req", calc: "rate")]) { a, _ in a }, states = dpl.list?.view.state
    func list(_ statuses: [String]) -> ToolSample { sample(7, ["rows": .array(statuses.map { .object(["unit": .string($0), "last_status": .string($0)]) })]) }
    var h = ToolHistory()
    _ = h.add(sample(0, ["req": 100, "hosts": .array([.object(["host": "a", "rpm": 6])])]), metrics: metrics, now: at(0), states: states)
    _ = h.add(list(["ready", "ready", "ready", "failed"]), metrics: metrics, now: at(7), states: states, list: true)
    let v = h.add(sample(10, ["req": 160, "hosts": .array([.object(["host": "a", "rpm": 12])])]), metrics: metrics, now: at(10), states: states)
    #expect(v["req"] == ["": 6], "the rate from the stream's line before, not the list's: \(v)")
    #expect(h.latest("apps") == ["all": 4, "ok": 3, "bad": 1, "warn": 0, "off": 0, "busy": 0] && h.points("apps", "all").count == 1, "\(h.latest("apps"))")
    #expect(h.latest("rpm") == ["a": 12] && h.last?.at == at(10) && h.previous?.at == at(0) && h.rows("list").count == 4)
    h.mark(.noAnswer, at: at(12), metrics: ["apps"])
    #expect(h.latest("apps").isEmpty && h.latest("rpm") == ["a": 12], "the list's gap, not the stream's")
}

@Test func framesByBlankLinesAndByAFirstLine() throws {
    var blank = ToolFrames(split: "blank"), frames: [String] = []
    for l in try fixture("iostat.dx.txt").split(separator: "\n", omittingEmptySubsequences: false) { frames += blank.feed(String(l)) }
    #expect(frames.count >= 2 && frames.allSatisfy { $0.hasPrefix("Device") || $0.hasPrefix("Linux") })
    let parse = ToolParse(format: .table, split: "blank")
    let s = try #require(parse.sample(frames.first { $0.hasPrefix("Device") }!, at: at(0)))
    #expect(ToolMetric(path: "%util", rows: "rows", key: "Device").values(in: s, previous: nil, now: at(0)) == ["sda": 2.92])

    var top = ToolFrames(split: "^top -")
    #expect(top.feed("top - 10:00") == [] && top.feed("Tasks: 100") == [] && top.feed("") == [])
    #expect(top.feed("top - 10:05") == ["top - 10:00\nTasks: 100"], "a frame ends when the next begins")
    var lines = ToolFrames(split: nil)
    #expect(lines.feed("{\"a\":1}") == ["{\"a\":1}"] && lines.feed("  ") == [])
    #expect(ToolParse(format: .jsonl).sample("{\"a\":1}", at: at(0))?.record == ["a": 1])
    #expect(ToolParse(format: .jsonl).sample("not json", at: at(0)) == nil)
}

@Test func seriesKeepAnHourWithGapsAsMarks() throws {
    var h = ToolHistory(keep: 60)
    let m = ["cpu": ToolMetric(path: "cpu.pct", unit: "%")]
    for s in stride(from: 0.0, through: 70, by: 10) { _ = h.add(sample(s, cpu(s)), metrics: m, now: at(s)) }
    #expect(h.points("cpu").map(\.at) == [at(10), at(20), at(30), at(40), at(50), at(60), at(70)], "older than an hour gone")
    h.mark(.noAnswer, at: at(80))
    h.mark(.noAnswer, at: at(90))
    #expect(h.points("cpu").filter { $0.gap != nil }.count == 1, "one mark a stretch")
    #expect(h.points("cpu").last == ToolPoint(at: at(80), gap: .noAnswer) && h.latest("cpu") == [:], "no value through a gap")
    _ = h.add(sample(100, cpu(5)), metrics: m, now: at(100))
    #expect(h.latest("cpu") == ["": 5] && h.previous?.at == at(70) && h.last?.at == at(100))
}

@Test func alertsHoldForATimeOrACount() {
    var a = ToolAlerts()
    let m = ["cpu": ToolMetric(title: "CPU", path: "cpu.pct", unit: "%")]
    let rule = ToolAlert(id: "cpu", metric: "cpu", warn: 85, crit: 95, for: .init(crit: .text("10s")))
    func judge(_ s: Double, _ v: Double) -> [ToolAlertChange] { a.judge(["cpu": ["": v]], alerts: [rule], metrics: m, sample: sample(s, cpu(v)), now: at(s)) }
    #expect(judge(0, 96) == [.worse(alert: "cpu", key: "", level: .warning, message: "CPU 96%")], "warn has no `for`: at once")
    #expect(judge(5, 96) == [] && a.worst == .warning)
    #expect(judge(10, 97) == [.worse(alert: "cpu", key: "", level: .critical, message: "CPU 97% for 10 s")])
    #expect(judge(15, 97) == [], "one message per change for the worse")
    #expect(judge(20, 90) == [] && a.worst == .warning, "down from critical: no message, warning stands")
    #expect(judge(25, 97) == [] && judge(35, 97) == [.worse(alert: "cpu", key: "", level: .critical, message: "CPU 97% for 10 s")], "up again: held again")
    #expect(judge(40, 50) == [.ok(alert: "cpu", key: "", was: .critical, since: at(0))] && a.worst == nil)

    var c = ToolAlerts()
    let twice = ToolAlert(metric: "cpu", crit: 95, checks: 2)
    #expect(c.judge(["cpu": ["": 99]], alerts: [twice], metrics: m, sample: sample(0, cpu(99)), now: at(0)) == [])
    #expect(c.judge(["cpu": ["": 99]], alerts: [twice], metrics: m, sample: sample(5, cpu(99)), now: at(5)).count == 1 && c.standing.first?.alert == "cpu")
}

@Test func aGapNeverRecoversAnAlert() {
    var a = ToolAlerts()
    let m = ["cpu": ToolMetric(title: "CPU", path: "cpu.pct", unit: "%")]
    let rule = ToolAlert(metric: "cpu", crit: 95, for: .init(crit: .seconds(10)))
    _ = a.judge(["cpu": ["": 99]], alerts: [rule], metrics: m, sample: sample(0, cpu(99)), now: at(0))
    #expect(a.judge(["cpu": ["": 99]], alerts: [rule], metrics: m, sample: sample(10, cpu(99)), now: at(10)).count == 1 && a.worst == .critical)
    a.gap()
    #expect(a.worst == .critical, "the Mac slept: it stands as it was")
    #expect(a.judge(["cpu": ["": 99]], alerts: [rule], metrics: m, sample: sample(600, cpu(99)), now: at(600)) == [] && a.worst == .critical, "still past: no new message, no recovery")
    #expect(a.judge(["cpu": ["": 10]], alerts: [rule], metrics: m, sample: sample(605, cpu(10)), now: at(605)) == [.ok(alert: "cpu", key: "", was: .critical, since: at(10))], "since it was raised")
    #expect(a.judge([:], alerts: [rule], metrics: m, sample: sample(610, [:]), now: at(610)) == [], "a sample without the metric says nothing")
}

@Test func alertsPerRowBelowAndWithAMessage() {
    var a = ToolAlerts()
    let m = ["disk": ToolMetric(title: "Disk", path: "pct", unit: "%", rows: "disks", key: "mount"),
             "tls": ToolMetric(title: "Certificate", path: "days", unit: "days", rows: "urls", key: "url")]
    let disks: ToolRecord = ["disks": .array([.object(["mount": "/", "pct": 50]), .object(["mount": "/var", "pct": 90])])]
    let rules = [ToolAlert(id: "disk", metric: "disk", warn: 85, crit: 95),
                 ToolAlert(id: "tls", metric: "tls", warn: 14, crit: 3, below: true, message: "{url}: certificate ends in {value} days")]
    let s = sample(0, disks.merging(["urls": .array([.object(["url": "https://a.example", "days": 10])])]) { a, _ in a })
    let changes = a.judge(["disk": ["/": 50, "/var": 90], "tls": ["https://a.example": 10]], alerts: rules, metrics: m, sample: s, now: at(0))
    #expect(changes == [.worse(alert: "disk", key: "/var", level: .warning, message: "/var 90%"),
                        .worse(alert: "tls", key: "https://a.example", level: .warning, message: "https://a.example: certificate ends in 10 days")])
    #expect(a.judge(["tls": ["https://a.example": 2]], alerts: rules, metrics: m, sample: s, now: at(5)).first == .worse(alert: "tls", key: "https://a.example", level: .critical, message: "https://a.example: certificate ends in 2 days"))
    #expect(a.standing.map(\.key) == ["/var", "https://a.example"])
    a.clear()
    #expect(a.worst == nil)
}

@Test func eventsOfEachKind() throws {
    let events = try #require(system.events)
    let base: ToolRecord = ["boot_id": "b1", "oom_kill": 0, "reboot_required": false,
                            "failed_units": .array([.object(["unit": "a.service"])]),
                            "containers": .array([.object(["name": "api", "state": "running", "status": "Up"])])]
    let first = sample(0, base)
    #expect(ToolEvents.raised(events, in: first, previous: nil).isEmpty, "the first sample: nothing was added to nothing")
    var next = base
    next["boot_id"] = "b2"
    next["oom_kill"] = 1
    next["reboot_required"] = true
    next["failed_units"] = .array([.object(["unit": "a.service"]), .object(["unit": "db.service"])])
    next["containers"] = .array([.object(["name": "api", "state": "exited", "status": "Exited (1)"]), .object(["name": "web", "state": "restarting", "status": "Restarting"])])
    let raised = ToolEvents.raised(events, in: sample(5, next), previous: first)
    #expect(raised.map { "\($0.id) \($0.level): \($0.message)" + ($0.goto.map { " → " + $0 } ?? "") } == [
        "reboot info: Rebooted", "oom warning: Out of memory: the kernel killed a process",
        "unit critical: db.service failed → services:db.service", "container critical: api Exited (1) → containers:api",
        "restarting warning: web keeps restarting", "reboot_required info: Needs a restart to finish updates"])
    #expect(ToolEvents.raised(events, in: sample(10, next), previous: sample(5, next)).isEmpty, "the same again: nothing new")
    #expect(ToolEvents.raised(events, in: sample(0, next), previous: nil).map(\.id) == ["restarting", "reboot_required"], "`is` on the first sample: the state is so")
}

/// System prints its units and containers every 12th line: a failed unit is "added" once — against the last sample
/// that had the rows, not the line before — and a container that left `running` is seen; the history hands tables
/// and counts the rows of the last sample that carried them.
@Test func rowsThatComeEveryFewLinesCompareWithTheLastThatCame() throws {
    let events = try #require(system.events), m = try #require(system.metrics)
    var h = ToolHistory()
    func feed(_ s: Double, _ r: ToolRecord) -> [ToolEventRecord] {
        let x = sample(s, r)
        _ = h.add(x, metrics: m, now: at(s))
        return ToolEvents.raised(events, in: x, previous: h.previous, carrying: h.carriedBefore)
    }
    let units: ToolValue = .array([.object(["unit": "a.service"])]), running: ToolValue = .array([.object(["name": "api", "state": "running", "status": "Up"])])
    #expect(feed(0, ["boot_id": "b1", "failed_units": units, "containers": running]).isEmpty)
    #expect(feed(5, ["boot_id": "b1"]).isEmpty && feed(10, ["boot_id": "b1"]).isEmpty, "lines without the rows")
    #expect(h.rows("failed_units").map { $0["unit"] } == ["a.service"] && h.last?.rows("failed_units").isEmpty == true, "the table reads the last sample that had them")
    #expect(feed(15, ["boot_id": "b1", "failed_units": units, "containers": running]).isEmpty, "the same rows again: nothing added")
    let later = feed(20, ["boot_id": "b1", "failed_units": .array([.object(["unit": "a.service"]), .object(["unit": "b.service"])]),
                          "containers": .array([.object(["name": "api", "state": "exited", "status": "Exited (1)"])])])
    #expect(later.map(\.message) == ["b.service failed", "api Exited (1)"], "\(later)")
    #expect(ToolEvents.raised(events, in: sample(25, ["boot_id": "b1", "failed_units": units]), previous: sample(20, ["boot_id": "b1"])).map(\.message) == ["a.service failed"],
            "without the carrying map, the line before is all there is")

    // A poll's rows come as `rows`, and an event names them `list`: the same sample is found under either.
    let gone = ToolEvent(id: "gone", rows: "list", key: "unit", when: "added", level: "info", message: "{unit} new")
    var poll = ToolHistory()
    let one: ToolRecord = ["rows": .array([.object(["unit": "a"])])], two: ToolRecord = ["rows": .array([.object(["unit": "a"]), .object(["unit": "b"])])]
    _ = poll.add(sample(0, one), metrics: [:], now: at(0))
    _ = poll.add(sample(5, two), metrics: [:], now: at(5))
    #expect(ToolEvents.raised([gone], in: sample(5, two), previous: poll.previous, carrying: poll.carriedBefore).map(\.message) == ["b new"])
    #expect(poll.rows("list").count == 2 && poll.carried("list")?.at == at(5))
}

@Test func aChartHasRunsBandsAndATop() {
    let pts = [ToolPoint(at: at(0), value: 1), ToolPoint(at: at(5), value: 2), ToolPoint(at: at(10), gap: .asleep), ToolPoint(at: at(60), gap: .reconnecting),
               ToolPoint(at: at(65), value: 3), ToolPoint(at: at(70), gap: .noAnswer)]
    let c = ToolChart(pts, now: at(80))
    #expect(c.runs.map { $0.map(\.value) } == [[1, 2], [3]], "a line never crosses a gap")
    #expect(c.bands == [.init(from: at(10), to: at(60), gap: .asleep), .init(from: at(60), to: at(65), gap: .reconnecting), .init(from: at(70), to: at(80), gap: .noAnswer)])
    #expect(ToolChart.top([3, 40], max: 100) == 100 && ToolChart.top([3, 40], max: nil) == 50 && ToolChart.top([], max: nil) == 2 && ToolChart.top([1_900_000], max: nil) == 2_500_000)
    #expect(ToolChart.nearest(pts, to: at(12), within: 10)?.at == at(5) && ToolChart.nearest(pts, to: at(30), within: 10) == nil)
}

@Test func eventsIfUnlessAndScripted() {
    let down = ToolEvent(id: "down", rows: "list", key: "unit", field: "last_status", when: "is", level: "critical", message: "{unit} is down", value: "failed", unless: "active_version")
    let failed = ToolEvent(id: "failed", rows: "list", key: "unit", field: "last_status", when: "is", level: "warning", message: "{unit}: v{active_version} still serves", value: "failed", if: "active_version")
    let rows: ToolRecord = ["rows": .array([.object(["unit": "api", "last_status": "failed", "active_version": 12]), .object(["unit": "web", "last_status": "failed"])])]
    let raised = ToolEvents.raised([down, failed], in: sample(0, rows), previous: nil)
    #expect(raised.map { "\($0.id) \($0.message)" } == ["down web is down", "failed api: v12 still serves"])
    let changed = ToolEvent(id: "v", path: "active_version", rows: "list", key: "unit", when: "increased", message: "{unit} v{active_version}")
    let later: ToolRecord = ["rows": .array([.object(["unit": "api", "last_status": "ready", "active_version": 13])])]
    #expect(ToolEvents.raised([changed], in: sample(5, later), previous: sample(0, rows)).map(\.message) == ["api v13"])

    let e = ToolEvents.scripted(sample(0, ["_event": .object(["id": "deploy", "level": "info", "message": "api v13 serving"])]))
    #expect(e == ToolEventRecord(at: at(0), id: "deploy", level: "info", message: "api v13 serving"))
    #expect(ToolEvents.scripted(sample(0, ["x": 1])) == nil)
    var budget = ToolEventBudget()
    #expect((0..<10).allSatisfy { budget.allows(at(Double($0))) } && !budget.allows(at(11)) && !budget.allows(at(12)))
    #expect(budget.takeHeld() == 2 && budget.held == 0 && budget.allows(at(3601)), "an hour on, room again")
}

/// A poll's run is one sample (§8.1): its lines held till the line that ends it; its exit code is a Nagios run's
/// status; Prometheus' samples are rows.
@Test func aPollsRunIsOneSampleWithItsExitCode() throws {
    var f = ToolFrames(split: nil, poll: true)
    #expect(f.feed("node_load1 0.5").isEmpty && f.feed("up 1").isEmpty)
    let frame = try #require(f.feed(ToolPayload.ranMark + "0").first)
    #expect(f.feed("next").isEmpty, "the next run starts afresh")
    let s = try #require(ToolParse(format: .prometheus).sample(frame, at: at(0)))
    #expect(s.rows("rows").map { $0["name"] } == ["node_load1", "up"])
    let n = try #require(ToolParse(format: .nagios).sample("LOAD CRITICAL - load 9.5 | load1=9.5;2;4\n" + ToolPayload.ranMark + "2", at: at(0)))
    #expect(n.record["status"] == "crit" && ToolValue.object(n.record)["perf.load1"] == 9.5 && n.record["message"] == "LOAD CRITICAL - load 9.5")
    var g = ToolFrames(split: nil, poll: true)
    let bare = try #require(g.feed("{\"a\":1}" + ToolPayload.ranMark + "0").first, "output with no newline at its end: the mark ends its line")
    #expect(ToolParse(format: .json).sample(bare, at: at(0))?.record == ["a": 1])
    #expect(ToolPayload.ran("{\"a\":1}\n" + ToolPayload.ranMark + "1").exit == 1 && ToolPayload.ran("a line").exit == nil, "the run's code, for the engine to judge")
    let nan = try #require(ToolParse(format: .prometheus).sample("x NaN\ny +Inf\nz 2", at: at(0)))
    #expect(ToolMetric(path: "value", rows: "rows", key: "name").values(in: nan, previous: nil, now: at(0)) == ["z": 2], "NaN and +Inf are no value")
    let rate = ToolMetric(path: "value", rows: "rows", key: "name", calc: "rate")
    #expect(rate.values(in: ToolSample(at: at(5), record: nan.record), previous: nan, now: at(5)) == ["z": 0], "nor after a rate")
}
