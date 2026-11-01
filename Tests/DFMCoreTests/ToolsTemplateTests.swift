import Foundation
import Testing
@testable import DFMCore

// Templates (protocol §5): what counts as a placeholder, values as variables in commands (never spliced in), parts,
// nested fields, display formats, the order of names.

@Test func whatCountsAsAPlaceholder() {
    func names(_ s: String) -> [String] { ToolTemplate.placeholders(in: s).map { $0.name + ($0.format.map { ":" + $0 } ?? "") } }
    #expect(names("ufw delete {num}") == ["num"])
    #expect(names("{failure.stage} at {updated_at:ago}") == ["failure.stage", "updated_at:ago"])
    #expect(names("journalctl --since @{from}") == ["from"])
    #expect(names("echo ${HOME} $HOME") == [])                                  // shell's own
    #expect(names("find . -name x -exec rm {} \\;") == [])
    #expect(names("cp x.{a,b}") == [])
    #expect(names("awk '{ print $1 }'") == [])
    #expect(names("docker ps --format '{{.Names}}' '{{json .}}'") == [])     // Go's
    #expect(names("{1st} {_x} {имя} {a-b}") == [])                            // from a letter; ASCII; no dashes
    #expect(names("awk '{print}'") == ["print"])                                  // no escape: put it in a script
    #expect(names("{x:} {x:1}") == [])
}

/// The shell context of each place in a command, as the shell reads it.
@Test func quotesAsTheShellReadsThem() {
    let t = #"a '{x}' "{y} $(z {w}) `v {u}`" {t}"#
    let q = ToolTemplate.quotes(in: t)
    let at = Dictionary(uniqueKeysWithValues: ToolTemplate.placeholders(in: t).map { ($0.name, q($0.range.lowerBound)) })
    #expect(at == ["x": .single, "y": .double, "w": .bare, "u": .bare, "t": .bare])
}

private func scope(_ row: ToolRecord = [:], inputs: ToolRecord = [:], vars: ToolRecord = [:], kermo: ToolRecord = [:]) -> ToolTemplate.Scope {
    ToolTemplate.Scope(inputs: inputs, rows: [row], vars: vars, kermo: kermo)
}

@Test func valuesBecomeVariablesNotText() throws {
    var taken: [String: String] = [:]
    let c = try ToolTemplate.command(.one("fail2ban-client set {jail} unbanip {ip}"), scope(["jail": "sshd", "ip": "203.0.113.7"]), vars: &taken)
    #expect(c.text == #"fail2ban-client set "$K_jail" unbanip "$K_ip""#)
    #expect(c.values == [.init(name: "K_jail", value: "sshd"), .init(name: "K_ip", value: "203.0.113.7")])
    #expect(c.shown == "fail2ban-client set sshd unbanip 203.0.113.7")
    let n = try ToolTemplate.command(.one("dpl logs {failure.stage} {%util} {a_b} {a.b} {a.b}"),
                                     scope(["failure": .object(["stage": "build"]), "a_b": "1", "a": .object(["b": "2"])]), vars: &taken)
    #expect(n.text == #"dpl logs "$K_failure_stage" {%util} "$K_a_b" "$K_a_b2" "$K_a_b2""#)   // the same name: the same variable
    #expect(n.values.map(\.value) == ["build", "1", "2"])
    let shown = try ToolTemplate.command(.one("echo {x}"), scope(["x": "a b"]), vars: &taken).shown
    #expect(shown == "echo 'a b'")   // for reading: one argument, as the shell would take it
}

@Test func partsWithoutAValueDropOut() throws {
    var taken: [String: String] = [:]
    let parts = ToolStrings.many(["restic restore {id} --target {target}", "--include {path}"])
    let all = try ToolTemplate.command(parts, scope(["id": "d04f20b4"], inputs: ["target": "/tmp/r", "path": "/etc"]), vars: &taken)
    #expect(all.text == #"restic restore "$K_id" --target "$K_target" --include "$K_path""#)
    let some = try ToolTemplate.command(parts, scope(["id": "d04f20b4"], inputs: ["target": "/tmp/r", "path": ""]), vars: &taken)
    #expect(some.text == #"restic restore "$K_id" --target "$K_target""#)
    #expect(throws: ToolTemplate.Empty(field: "id")) { try ToolTemplate.command(parts, scope(inputs: ["target": "/tmp/r"]), vars: &taken) }
    #expect(throws: ToolTemplate.Empty(field: "ip")) { try ToolTemplate.command(.one("whois {ip}"), scope(), vars: &taken) }
    #expect(ToolTemplate.parts(["{last_status}", "at {failure.stage}", "v{active_version}"],
                               scope(["last_status": "failed", "active_version": 7])) == "failed · v7")
}

/// What a value does in the shell: one argument, whatever it holds — run for real with /bin/sh.
@Test(arguments: ["a';rm -rf /;'", "$(id)", "`id`", "a\nb", "-h evil", "{x}", "a b  *", "\"; echo pwned; \""])
func aValueIsAlwaysOneArgument(_ value: String) throws {
    for command in ["printf '<%s>' {x}", #"printf '<%s>' "pre {x} post""#, "printf '<%s>' x{x}y", "printf '<%s>' '{x}'"] {
        var taken: [String: String] = [:]
        let c = try ToolTemplate.command(.one(command), scope(["x": .string(value)]), vars: &taken)
        let script = c.values.map { "\($0.name)=\(ShellContext.quote($0.value))" }.joined(separator: "\n") + "\n" + c.text
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let got = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let want = switch command {
        case "printf '<%s>' {x}": "<\(value)>"
        case #"printf '<%s>' "pre {x} post""#: "<pre \(value) post>"
        case "printf '<%s>' x{x}y": "<x\(value)y>"
        default: #"<"$K_x">"#   // the author's single quotes: literal text, as the validator warns
        }
        #expect(got == want, "\(command) with \(value.debugDescription)")
    }
}

@Test func anEnvValueIsAValueWithItsTextQuoted() {
    var taken: [String: String] = [:]
    let v = ToolTemplate.value("sftp:{host}:/srv/a b;c", scope(kermo: ["host": "web-01"]), vars: &taken)
    #expect(v.text == #"sftp:"$K_host"':/srv/a b;c'"#)
    #expect(v.shown == "sftp:web-01:/srv/a b;c")
    #expect(ToolTemplate.value("", scope(), vars: &taken).text == "''")
}

@Test func suspiciousValuesAreRefused() {
    #expect(ToolTemplate.refusal("203.0.113.7") == nil)
    #expect(ToolTemplate.refusal("-h evil") != nil)
    #expect(ToolTemplate.refusal("a\nb") != nil)
    #expect(ToolTemplate.refusal("a\u{1b}[2J") != nil)
    #expect(ToolTemplate.refusal("tab\there") != nil)
    #expect(ToolTemplate.refusal("-5", pattern: "^-?\\d+$") == nil)   // an input's pattern may allow a leading "-"
    #expect(ToolTemplate.refusal("-x", pattern: "^-?\\d+$") != nil)
}

/// §5.3: the action's inputs, the row, its parent rows, the tool's vars, Kermo's own.
@Test func theOrderOfNames() {
    let s = ToolTemplate.Scope(inputs: ["a": "input"], rows: [["a": "row", "b": "row"], ["b": "parent", "c": "parent"]],
                               vars: ["c": "var", "d": "var"], kermo: ["d": "kermo", "server": "web-01"])
    #expect(["a", "b", "c", "d", "server", "none"].map { s.value($0)?.text } == ["input", "row", "parent", "var", "web-01", nil])
}

@Test func displayFormats() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let v: ToolRecord = ["size": 1_400_000_000, "kb": 1_367_188, "pct": 42.04, "ms": 120, "slow": 1234, "days": 12, "one": 1, "v": 13,
                         "t": .string("2027-01-15T07:59:30Z"), "u": .number(1_800_000_000 - 300), "ns": .string("2027-01-15T07:24:59.123456789Z"),
                         "list": .array(["a", "b", "c"]), "flag": true, "none": .null]
    func show(_ t: String) -> String { ToolTemplate.text(t, scope(v), now: now) }
    let gb = ByteCountFormatter.string(fromByteCount: 1_400_000_000, countStyle: .file)   // "1.4 GB" in this Mac's locale, as the app shows sizes
    #expect(show("{size:bytes} {kb:kbytes} {pct:%} {ms:ms} {slow:ms}") == "\(gb) \(gb) 42 % 120 ms 1.2 s")
    #expect(show("{days:days} {one:days} {v:v}") == "12 days 1 day v13")
    #expect(show("{u:ago} · {t:ago} · {ns:ago}") == "5 min ago · just now · 35 min ago")
    #expect(show("{list} {flag} [{none}] [{missing}] {pct}") == "a, b, c true [] [] 42.04")
    #expect(show("{size:bytes}") == show("{size:bytes}"))
    #expect(ToolTemplate.date(.string("2027-01-15T08:00:00Z")) == Date(timeIntervalSince1970: 1_800_000_000))
    let dt = DateFormatter()
    dt.locale = Locale(identifier: "en_US_POSIX")
    dt.dateFormat = "EEE dd.MM HH:mm"
    #expect(show("{u:datetime}") == dt.string(from: now - 300))
}

/// A Bool is a number to metrics (`ok`: 1 or 0), never a time.
@Test func aBoolIsNoTime() {
    #expect(ToolTemplate.date(.bool(true)) == nil && ToolValue.bool(true).number == 1 && ToolValue.bool(false).number == 0)
}

/// `only`: an action is offered on a row where each field it names has one of its values — a number as its text, a
/// dotted path into the row; none named: on every row.
@Test func onlyOffersAnActionOnTheRowsItNames() throws {
    let a = try JSONDecoder().decode(ToolAction.self, from: Data(#"{ "id": "deploy", "command": "true", "only": { "kind": ["app", "job"], "n.port": ["80"] } }"#.utf8))
    #expect(a.offered(on: ["kind": "app", "n": .object(["port": 80])]))
    #expect(!a.offered(on: ["kind": "site", "n": .object(["port": 80])]) && !a.offered(on: ["kind": "job"]) && !a.offered(on: [:]))
    let any = try JSONDecoder().decode(ToolAction.self, from: Data(#"{ "id": "logs", "command": "true" }"#.utf8))
    #expect(any.offered(on: [:]))
}
