import Foundation
import Testing
@testable import DFMCore

// Parse (protocol §4) on recorded output: each format, split, \r, JSON maps, limit, unmatched output, and rows as a
// Picker shows them.

private let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/tools")
private func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }
private func preset(_ name: String) throws -> ToolPreset {
    let dir = name == "restic" ? fixtures : ToolPreset.builtInFolder
    return try #require(ToolSchema.validate(try Data(contentsOf: dir.appendingPathComponent(name + ".json")), file: name + ".json").preset)
}
private func parse(_ format: ToolFormat, _ text: String, _ change: (inout ToolParse) -> Void = { _ in }) -> ToolRecords {
    var p = ToolParse(format: format)
    change(&p)
    return p.records(Data(text.utf8))
}

@Test func ufwRulesByRegex() throws {
    let ufw = try preset("ufw"), list = try #require(ufw.list)
    let r = list.parse.records(try fixture("ufw.list.txt"))
    #expect(r.total == 20)
    #expect(r.unmatched == ["Status: active", "     To                         Action      From", "     --                         ------      ----"])
    #expect(r.rows[7] == ["num": "8", "dest": "192.0.2.10 32768:60999/udp on wlan0", "action": "ALLOW", "dir": "IN", "src": "192.0.2.35",
                          "comment": "media from the Mac"])
    let row = list.view.row(r.rows[4])
    #expect((row.key, row.title, row.subtitle, row.state) == ("5", "Anywhere", "DENY IN · from 203.0.113.7", .bad))
    #expect(list.view.row(r.rows[11]).subtitle == "DENY OUT · from Anywhere")
    #expect(list.view.row(r.rows[0]).detail == "")
}

@Test func fail2banFromItsScriptAsTSV() throws {
    let list = try #require(try preset("fail2ban").list)
    let r = list.parse.records(try fixture("fail2ban.list.tsv"))
    #expect(r.rows.map { $0["ip"]?.text } == ["192.0.2.44", "203.0.113.7", "198.51.100.23", "2001:db8::5"])
    let row = list.view.row(r.rows[1])
    #expect((row.key, row.title, row.subtitle) == ("sshd/203.0.113.7", "203.0.113.7", "banned by sshd"))
}

@Test func tsvAndCSV() {
    let tsv = parse(.tsv, "name\tstate\napi\tready\nweb\t\n")
    #expect(tsv.rows == [["name": "api", "state": "ready"], ["name": "web", "state": ""]])
    #expect(parse(.tsv, "a\tb\tc\n") { $0.names = ["x", "y"] }.unmatched == ["a\tb\tc"])   // more fields than names
    let csv = parse(.csv, "id,note\r\n1,\"a, b\"\n2,\"say \"\"hi\"\"\"\n3,\"two\nlines\"\n")
    #expect(csv.rows.map { $0["note"]?.text } == ["a, b", "say \"hi\"", "two\nlines"])
    #expect(parse(.csv, "1,x\n") { $0.names = ["id", "v"] }.rows == [["id": "1", "v": "x"]])
}

@Test func jsonArraysObjectsAndMaps() throws {
    let restic = try preset("restic")
    let snaps = try #require(restic.list).parse.records(try fixture("restic.list.json"))
    #expect(snaps.rows.map { $0["short_id"]?.text } == ["66132c9a", "d04f20b4"])   // sort: -time
    let row = restic.list!.view.row(snaps.rows[0])
    #expect(row.subtitle == "66132c9a · /etc/demo, /srv/www")   // tags: none, so that part drops
    #expect(row.cells.map(\.field) == ["time", "short_id", "paths", "tags", "hostname"])
    let peers = #"{ "Self": { "HostName": "me" }, "Peer": { "nodekey:b": { "HostName": "db-01" }, "nodekey:a": { "HostName": "web-01" } } }"#
    let map = parse(.json, peers) { $0.rows = "Peer" }
    #expect(map.rows == [["HostName": "web-01", "_key": "nodekey:a"], ["HostName": "db-01", "_key": "nodekey:b"]])
    #expect(parse(.json, #"{ "data": { "list": [1, {"a": 2}] } }"#) { $0.rows = "data.list" }.rows == [["value": 1], ["a": 2]])
    #expect(parse(.json, #"{ "a": 1 }"#).rows == [["a": 1]])
    #expect(!parse(.json, "Error: repository does not exist").matched)
}

@Test func jsonLinesWithNoise() throws {
    let r = parse(.jsonl, "{\"a\":1}\nwarning: something\n\n{\"a\":2}\n")
    #expect(r.rows == [["a": 1], ["a": 2]])
    #expect(r.unmatched == ["warning: something"])
    let stream = try #require(try preset("system").stream).parse.records(try fixture("system.stream.jsonl"))
    #expect(stream.total == 5)
    guard case .array(let procs)? = stream.rows[3]["procs"] else { Issue.record("no procs"); return }
    #expect(procs.first?["start"] == .string("5828026"))
    #expect(ToolValue.object(stream.rows[0])["load.per_core"] == 0.2)
    let backup = parse(.jsonl, String(decoding: try fixture("restic.backup.jsonl"), as: UTF8.self))
    #expect(backup.rows.last?["message_type"] == "summary")
}

@Test func tablesAndFrames() throws {
    let io = String(decoding: try fixture("iostat.dx.txt"), as: UTF8.self)
    let frames = ToolParse(format: .table, split: "blank").units(io)
    #expect(frames.count == 3)   // the banner, then a frame every interval
    let r = parse(.table, io) { $0.split = "blank" }
    #expect(r.rows.filter { $0["Device"] == "sda" }.count == 2)
    #expect(r.rows.first { $0["Device"] == "sda" }?["%util"] == "2.92")
    // ps: right-aligned numbers stay whole; the last column takes the rest of the line
    let ps = parse(.table, "  PID USER     %CPU COMMAND\n    1 root      0.0 /sbin/init splash\n12345 www-data 31.3 nginx: worker\n")
    #expect(ps.rows == [["PID": "1", "USER": "root", "%CPU": "0.0", "COMMAND": "/sbin/init splash"],
                        ["PID": "12345", "USER": "www-data", "%CPU": "31.3", "COMMAND": "nginx: worker"]])
    // an empty cell: columns by the header's positions
    let gap = parse(.table, "NAME   PORTS    STATUS\napi             Up 2 days\n")
    #expect(gap.rows == [["NAME": "api", "PORTS": "", "STATUS": "Up 2 days"]])
}

@Test func splitIntoBlocks() {
    let certs = "Found the following certs:\n  Certificate Name: a.example.com\n    Expiry Date: 2027-01-01\n  Certificate Name: b.example.com\n    Expiry Date: 2027-02-01\n"
    let r = parse(.regex, certs) {
        $0.split = "^\\s*Certificate Name:"
        $0.pattern = "(?s)Certificate Name: (?<name>\\S+).*Expiry Date: (?<expires>\\S+)"
    }
    #expect(r.rows == [["name": "a.example.com", "expires": "2027-01-01"], ["name": "b.example.com", "expires": "2027-02-01"]])
    #expect(r.unmatched == ["Found the following certs:"])
    #expect(parse(.lines, "a\n\nb\nc\n\nd") { $0.split = "blank" }.rows.map { $0["line"]?.text } == ["a", "b\nc", "d"])
}

/// A carriage return ends a line: a progress bar's states arrive one by one; ANSI colors don't reach a record.
@Test func carriageReturnsAndColors() {
    #expect(parse(.lines, "10%\r50%\r100%\r\ndone\n").rows.map { $0["line"]?.text } == ["10%", "50%", "100%", "done"])
    #expect(parse(.lines, "\u{1b}[32mok\u{1b}[0m\n").rows == [["line": "ok"]])
    #expect(parse(.text, "a\rb").text == "a\rb")
}

@Test func emptyLimitsAndUnmatched() {
    let none = parse(.regex, "") { $0.pattern = "(?<a>x)" }
    #expect(none.matched && none.rows.isEmpty && none.summary == "0 rows")
    let noise = parse(.regex, "\n  \n") { $0.pattern = "(?<a>x)" }
    #expect(noise.matched)
    let wrong = parse(.regex, "busybox: unknown option\nusage: ufw\n") { $0.pattern = "^(?<a>\\d+)$" }
    #expect(!wrong.matched && wrong.summary == "the output didn't match (2 lines)")
    let many = parse(.lines, (1...812).map(String.init).joined(separator: "\n"))
    #expect((many.rows.count, many.total, many.summary) == (500, 812, "500 of 812 rows"))
    #expect(parse(.lines, "a\nb\nc") { $0.limit = 2 }.summary == "2 of 3 rows")
}

/// Prometheus' text format: a record a sample line — its name, labels (escapes undone) and value, the timestamp
/// left out, comments skipped; Nagios: the whole run, its status from the exit code, the first line, every number
/// of the performance data, the long form's too. A Nagios run's code is its status, never a failure up to 3.
@Test func prometheusAndNagios() throws {
    let prom = ToolParse(format: .prometheus).records(try fixture("node.metrics.prom"))
    #expect(prom.unmatched.isEmpty && prom.rows.count == 7, "\(prom.unmatched)")
    #expect(prom.rows[0] == ["name": "node_load1", "value": "0.21"])
    #expect(prom.rows[1] == ["name": "node_filesystem_avail_bytes", "device": "/dev/sda1", "fstype": "ext4", "mountpoint": "/", "value": "2.0735033344e+10"])
    #expect(prom.rows[3]["value"] == "1027" && prom.rows[4]["handler"] == "/say \"hi\"\n", "the timestamp isn't the value; escapes undone")
    #expect(prom.rows[5]["value"]?.number?.isNaN == true && prom.rows[6]["value"]?.number == .infinity)
    #expect(!parse(.prometheus, "not a sample line\n").matched)
    #expect(parse(.prometheus, #"container_cpu{name="web",value="x"} 12"#).rows == [["name": "container_cpu", "value": "12", "label_name": "web", "label_value": "x"]],
            "the sample's own name and value; the labels so called beside them")

    let disk = ToolParse(format: .nagios).records(try fixture("check_disk.nagios.txt"), exit: 1)
    #expect(disk.rows == [["status": "warn", "message": "DISK WARNING - free space: / 3326 MB (16% inode=91%);",
                           "perf": .object(["/": 16642, "/boot": 30, "used %": 84, "inode %": 9])]], "\(disk.rows)")
    #expect(ToolParse(format: .nagios).records(Data("PROCS OK: 90 processes\n".utf8), exit: 0).rows.first?["status"] == "ok")
    #expect(ToolParse(format: .nagios).records(Data("sh: check_x: not found\n".utf8), exit: 127).rows.first?["status"] == "unknown")
    #expect(ToolRun().succeeded(2, format: .nagios) && !ToolRun().succeeded(127, format: .nagios) && !ToolRun().succeeded(2))
}

@Test func sortNumbersAsNumbers() {
    let text = "9\tb\n10\ta\n9\tc\n"
    #expect(parse(.tsv, text) { $0.names = ["n", "s"]; $0.sort = "n" }.rows.map { $0["s"]?.text } == ["b", "c", "a"])   // stable
    #expect(parse(.tsv, text) { $0.names = ["n", "s"]; $0.sort = "-n" }.rows.map { $0["s"]?.text } == ["a", "b", "c"])
    #expect(parse(.tsv, text) { $0.names = ["n", "s"]; $0.sort = "-s" }.rows.map { $0["s"]?.text } == ["c", "b", "a"])
}

@Test func exitCodesThatCountAsSuccess() {
    #expect(ToolRun().succeeded(0) && !ToolRun().succeeded(1))
    #expect(ToolRun(exitOk: [0, 1]).succeeded(1) && !ToolRun(exitOk: [0, 1]).succeeded(2))
}

/// dpl's units: one deploy.json each, the unit from its folder, `strategy` from its conf, the subtitle from parts. The
/// fixtures are dpl 0.7.1's own files (a check under way, a failed start with the earlier version serving, a failed
/// first build, a domain, a rollback, a failed first start, an http-server).
@Test func dplUnitsFromFiles() throws {
    let list = try #require(try preset("dpl").list)
    let units = ["api", "web", "worker", "shop", "blog", "cron", "edge"]
    let files = try units.map { u in
        ToolFile(path: "/opt/dpl/state/\(u)/deploy.json", data: try fixture("dpl.list.\(u).json"),
                 also: u == "api" ? try fixture("dpl.conf.api.yaml") : nil)
    }
    let r = list.parse.records(files: files, name: list.view.name, also: list.view.also?.pattern)
    let rows = r.rows.map { list.view.row($0) }
    #expect(rows.map(\.key) == units)
    #expect(rows.map(\.subtitle) == ["check · v1 · switching to v2 · parallel", "failed · at startup · v3", "failed · at build", "ready · v2",
                                     "ready · v3 · rollback of v1", "failed · at startup · v1", "ready · v1"])
    #expect(rows.map(\.state) == [.busy, .bad, .bad, .ok, .ok, .bad, .ok])
    #expect(rows[0].cells.map(\.text) == ["api", "app", "check", "v1", "parallel", rows[0].cells[5].text])
    #expect(rows[0].cells[2].value == "check")   // a state column: the raw value, the view draws the mark
    let broken = list.parse.records(files: [ToolFile(path: "/opt/dpl/state/x/deploy.json", data: Data("{".utf8))], name: "unit", also: nil)
    #expect(broken.unmatched == ["/opt/dpl/state/x/deploy.json"])
}

/// A `files` template's paths (§3.1): `*` of the template matches names in its folder — not a dot name, and before the
/// last part only a folder; a value stays as it is, even with `*` in it; no such folder gives nothing; a path not from
/// `/` is the login folder's; an empty value names no file.
@Test func filesTemplateNamesPaths() throws {
    let tree: [String: [(name: String, folder: Bool)]] = [
        "/opt/d*l/state": [("web", true), ("api", true), (".old", true), ("serve.pid", false)],
        "./logs": [("a.log", false), ("b.txt", false), ("c.log", true)],
    ]
    var listed: [String] = []
    func list(_ dir: String) -> [(name: String, folder: Bool)]? { listed.append(dir); return tree[dir] }
    let scope = ToolTemplate.Scope(vars: ["base": "/opt/d*l"])
    #expect(try ToolFile.paths("{base}/state/*/deploy.json", scope, list: list) == ["/opt/d*l/state/api/deploy.json", "/opt/d*l/state/web/deploy.json"])
    #expect(listed == ["/opt/d*l/state"], "the value's * is a name, not a wildcard")
    #expect(try ToolFile.paths("logs/*.log", scope, list: list) == ["./logs/a.log", "./logs/c.log"], "the last part: any kind")
    #expect(try ToolFile.paths("{base}/gone/*/x", scope, list: list) == [])
    #expect(try ToolFile.paths("{base}/conf/web.yaml", scope, list: list) == ["/opt/d*l/conf/web.yaml"] && listed.count == 3, "no wildcard: not listed")
    #expect(throws: ToolTemplate.Empty(field: "nope")) { try ToolFile.paths("{nope}/x", scope, list: list) }
}

/// A `files` list read through `list` and `read` (§3.1): each file a record, its folder the `name`, `also`'s fields from
/// the file that record's fields name; a file gone since the listing, or an `also` that can't be read, costs nothing.
@Test func filesListReadsEachFileAndItsAlso() throws {
    let list = try #require(try preset("dpl").list)
    let files: [String: Data] = [
        "/srv/dpl/state/api/deploy.json": try fixture("dpl.list.api.json"), "/srv/dpl/state/web/deploy.json": try fixture("dpl.list.web.json"),
        "/srv/dpl/conf/api.yaml": try fixture("dpl.conf.api.yaml"),
    ]
    struct Denied: Error {}
    var read: [String] = []
    let r = try list.records(ToolTemplate.Scope(vars: ["base": "/srv/dpl"]), list: { _ in [("api", true), ("gone", true), ("web", true)] }) { path in
        read.append(path)
        if path.hasSuffix("web.yaml") { throw Denied() }
        return files[path]
    }
    #expect(r.rows.map { $0["unit"]?.text } == ["api", "web"] && r.rows.map { $0["strategy"]?.text } == ["parallel", nil])
    #expect(read == ["/srv/dpl/state/api/deploy.json", "/srv/dpl/state/gone/deploy.json", "/srv/dpl/state/web/deploy.json",
                     "/srv/dpl/conf/api.yaml", "/srv/dpl/conf/web.yaml"])
}

/// A level down (`output: "list"`): the row's own fields first, then its parent's.
@Test func aRowOneLevelDown() throws {
    let biggest = try #require(try preset("system").actions?.first { $0.spec.id == "biggest" })
    let list = try #require(biggest.spec.list)
    let r = list.parse.records(Data("812344\t/var\n2048\t/var/log\n".utf8))
    let row = list.view.row(r.rows[0], ToolTemplate.Scope(rows: [["mount": "/"]]))
    #expect((row.title, row.detail) == ("/var", ToolTemplate.show(812344, "kbytes")))
    #expect(ToolTemplate.Scope(rows: [r.rows[1], ["mount": "/"]]).value("mount") == "/")
}

/// `strip: "cri"`: a container runtime's log line as its message; one that isn't stays; a line comes whole.
@Test func criLinesAreTheirMessage() {
    var cri = ToolCRI()
    #expect(cri.feed(Data("2026-10-30T10:00:00.1Z stdout F listening on :8080\n2026-10-30T10:00:01Z std".utf8)) == Data("listening on :8080\n".utf8))
    #expect(cri.feed(Data("err P half a line\nplain text\n".utf8)) == Data("half a line\nplain text\n".utf8))
}
