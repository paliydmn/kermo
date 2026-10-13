import Foundation
import Testing
@testable import DFMCore

// Task 13: a server config's check when it's saved (`ConfigCheck`, validators.json).

/// Each built-in rule by a path it's for: the command, before or after the save, the reload, root only.
@Test func builtInRulesByPath() {
    func rule(_ path: String) -> ConfigCheck? { ConfigCheck.rule(for: path, in: ConfigCheck.builtIn) }
    let rows: [(String, String?, ConfigCheck.When?, String?, Bool?)] = [
        ("/etc/sudoers", "visudo -cf %f", nil, nil, true),
        ("/etc/sudoers.d/90-admins", "visudo -cf %f", nil, nil, true),
        ("/etc/ssh/sshd_config", "sshd -t -f %f", nil, ConfigCheck.sshdReload, true),
        ("/etc/ssh/sshd_config.d/50-port.conf", "sshd -t", .after, ConfigCheck.sshdReload, true),
        ("/etc/haproxy/haproxy.cfg", "haproxy -c -f %f", nil, "systemctl reload haproxy", nil),
        ("/etc/nftables.conf", "nft -c -f %f", nil, nil, true),
        ("/etc/nginx/nginx.conf", "nginx -t", .after, "systemctl reload nginx", true),
        ("/etc/nginx/sites-available/default", "nginx -t", .after, "systemctl reload nginx", true),
        ("/etc/apache2/sites-enabled/000-default.conf", "apachectl configtest", .after, "systemctl reload apache2", nil),
        ("/etc/httpd/conf/httpd.conf", "apachectl configtest", .after, "systemctl reload httpd", nil),
        ("/etc/systemd/system/app.service", "systemd-analyze verify %f", .after, "systemctl daemon-reload", nil),
        ("/etc/systemd/system/backup.timer", "systemd-analyze verify %f", .after, "systemctl daemon-reload", nil),
        ("/etc/postfix/main.cf", "postfix check", .after, "postfix reload", true),
        ("/etc/bind/named.conf.local", "named-checkconf", .after, "rndc reload", nil),
        ("/etc/named.conf", "named-checkconf", .after, "rndc reload", nil),
        ("/srv/app/compose.yaml", "docker compose -f %f config -q", nil, nil, nil),
        ("/opt/web/docker-compose.yml", "docker compose -f %f config -q", nil, nil, nil),
    ]
    for (path, check, when, reload, root) in rows {
        let r = rule(path)
        #expect(r?.check == check && r?.when == when && r?.reload == reload && r?.root == root, "\(path): \(String(describing: r))")
    }
    #expect(rule("/etc/sudoers")?.after == false && rule("/etc/nginx/nginx.conf")?.after == true)
    // Someone else's files: no check.
    for path in ["/etc/hosts", "/etc/sudoers.bak", "/etc/nginx", "/etc/nginxx/a.conf", "/etc/systemd/system/app.socket",
                 "/srv/app/compose.yaml.bak", "/home/me/named.conf", "/home/me/sudoers", "/var/www/nginx/site.conf"] {
        #expect(rule(path) == nil, "\(path)")
    }
}

/// A glob's `*` crosses "/" (so `/opt/app/nginx/**` and `/opt/app/nginx/*` are all of it); one without "/" is the
/// file's name anywhere.
@Test func rulesMatchByGlob() {
    #expect(ConfigCheck(match: "/opt/app/nginx/**", check: "x").matches("/opt/app/nginx/conf.d/a.conf"))
    #expect(ConfigCheck(match: "/opt/app/nginx/*", check: "x").matches("/opt/app/nginx/conf.d/a.conf"))
    #expect(!ConfigCheck(match: "/opt/app/nginx/*", check: "x").matches("/opt/app/nginx"))
    #expect(ConfigCheck(match: "Caddyfile", check: "x").matches("/etc/caddy/Caddyfile"))
    #expect(!ConfigCheck(match: "Caddyfile", check: "x").matches("/etc/caddy/Caddyfile.bak"))
    #expect(ConfigCheck(match: "*.yaml", check: "x").matches("/opt/dpl/conf/web.yaml"))
    #expect(ConfigCheck(match: "/etc/prometheus/*.y*ml", check: "x").matches("/etc/prometheus/prometheus.yml") && ConfigCheck(match: "/etc/prometheus/*.y?ml", check: "x").matches("/etc/prometheus/rules.yaml"))
}

/// validators.json: the user's rules first (the first that matches wins, so one overrides a built-in rule), a
/// `"check": null` turns the check off for its paths (the rest of a built-in rule's still have theirs), an unknown key
/// is ignored. A file that isn't a list of rules: the built-in ones, and what's wrong.
@Test func validatorsJSONGoesFirst() throws {
    let json = #"""
        [
          {"match": "/etc/nginx/sites-enabled/*", "check": null},
          {"match": "/etc/caddy/Caddyfile", "check": "caddy validate --adapter caddyfile --config %f", "reload": "systemctl reload caddy", "note": "mine"},
          {"match": "/etc/prometheus/*.yml", "check": "promtool check config %f", "when": "before", "root": false},
          {"match": "/etc/haproxy/haproxy.cfg", "check": "haproxy -c -V -f %f", "when": "after"}
        ]
        """#
    let (rules, problem) = ConfigCheck.rules(Data(json.utf8))
    #expect(problem == nil && rules.count == 4 + ConfigCheck.builtIn.count && Array(rules.suffix(ConfigCheck.builtIn.count)) == ConfigCheck.builtIn)
    let off = try #require(ConfigCheck.rule(for: "/etc/nginx/sites-enabled/default", in: rules))
    #expect(off.check == nil && off.reload == nil, "null: no check, and nothing reloaded")
    #expect(ConfigCheck.rule(for: "/etc/nginx/nginx.conf", in: rules)?.check == "nginx -t", "the rest of nginx keeps its built-in check")
    #expect(ConfigCheck.rule(for: "/etc/caddy/Caddyfile", in: rules)?.reload == "systemctl reload caddy")
    #expect(ConfigCheck.rule(for: "/etc/prometheus/prometheus.yml", in: rules)?.needsRoot == false)
    let mine = try #require(ConfigCheck.rule(for: "/etc/haproxy/haproxy.cfg", in: rules))
    #expect(mine.check == "haproxy -c -V -f %f" && mine.after && mine.reload == nil, "the user's rule, whole: no built-in field mixed in")
    #expect(ConfigCheck.rules(nil) == (ConfigCheck.builtIn, nil), "no file: the built-in rules")

    for broken in ["[{\"match\": \"/etc/x\"", "{\"match\": \"/etc/x\", \"check\": \"true\"}", "[{\"check\": \"true\"}]",
                   "[{\"match\": \"/etc/x\", \"check\": \"true\", \"when\": \"later\"}]", ""] {
        let (r, p) = ConfigCheck.rules(Data(broken.utf8))
        #expect(r == ConfigCheck.builtIn && p?.hasPrefix("validators.json: ") == true && p?.hasSuffix("Built-in checks only.") == true, "\(broken)")
    }
}

/// `%f` is the path quoted for the server's shell — spaces, quotes, `$`, a leading "-" stay one word, nothing runs;
/// `%%` is a "%".
@Test func checkCommandQuotesThePath() {
    #expect(ConfigCheck.expand("visudo -cf %f", path: "/etc/sudoers.d/90-admins") == "visudo -cf /etc/sudoers.d/90-admins")
    #expect(ConfigCheck.expand("sshd -t -f %f", path: "/etc/ssh/.dfm-partial-1 a'b$(id)") == #"sshd -t -f '/etc/ssh/.dfm-partial-1 a'\''b$(id)'"#)
    #expect(ConfigCheck.expand("x %f %f", path: "/a b") == "x '/a b' '/a b'")
    #expect(ConfigCheck.expand("date +%%s; echo 100%% %%f %f", path: "/x") == "date +%s; echo 100% %f /x")
    #expect(ConfigCheck.expand("nginx -t", path: "/etc/nginx/nginx.conf") == "nginx -t")
}

/// `ConfigCheck.run`'s outcome, or its error as a failure with status -1 (`#expect` of a `try … == .case(…)` doesn't compile).
private func ran(_ command: String, on t: SFTPTarget, root: Bool = false) -> ConfigCheck.Outcome {
    do { return try ConfigCheck.run(command, on: t, root: root) } catch { return .failed(status: -1, output: "\(error)") }
}

/// What a save offers to reload: the rule's reload once its check passed (or it has none) — never after a check that
/// didn't run; on a user's panel only the user's own rule's (the built-in ones reload services, root's work). sshd: the
/// ssh.socket way when Port or ListenAddress changed (any case, `=` too; not a comment), else its reload.
@Test func reloadOffersAfterAPassedCheck() {
    let root = SFTPTarget(host: "me@web").asRoot(), user = SFTPTarget(host: "me@web")
    func builtIn(_ path: String) -> ConfigCheck { ConfigCheck.rule(for: path, in: ConfigCheck.builtIn)! }
    let nginx = builtIn("/etc/nginx/nginx.conf")
    #expect(nginx.reload(after: .passed(""), on: root, old: nil) { nil } == "systemctl reload nginx")
    for o: ConfigCheck.Outcome? in [nil, .needsRoot, .noProgram("nginx"), .notRun("cancelled")] {
        #expect(nginx.reload(after: o, on: root, old: nil) { nil } == nil, "\(String(describing: o))")
    }
    #expect(builtIn("/etc/haproxy/haproxy.cfg").reload(after: .passed(""), on: user, old: nil) { nil } == nil, "a service's reload is root's")
    #expect(builtIn("/etc/nftables.conf").reload(after: .passed(""), on: root, old: nil) { nil } == nil, "nft -f: by hand")
    let mine = ConfigCheck(match: "/opt/app/*.yaml", check: "app check %f", reload: "app reload")
    #expect(mine.reload(after: .passed(""), on: user, old: nil) { nil } == "app reload", "the user's own rule runs as the user")
    #expect(ConfigCheck(match: "/opt/app/x", check: nil, reload: "app reload").reload(after: nil, on: user, old: nil) { nil } == "app reload", "no check: offered")

    let sshd = builtIn("/etc/ssh/sshd_config")
    func sshdReload(_ old: String?, _ new: String) -> String? { sshd.reload(after: .passed(""), on: root, old: old.map { Data($0.utf8) }) { Data(new.utf8) } }
    #expect(sshdReload("Port 22\nPermitRootLogin no\n", "Port 22\nPermitRootLogin yes\n") == ConfigCheck.sshdReload)
    #expect(sshdReload("Port 22\n", "Port 2222\n") == ConfigCheck.sshdSocketReload)
    #expect(sshdReload("#Port 22\n", "#Port 2222\n") == ConfigCheck.sshdReload, "comments aren't settings")
    #expect(sshdReload("", "  port=2222\n") == ConfigCheck.sshdSocketReload)
    #expect(sshdReload("ListenAddress 0.0.0.0\n", "ListenAddress 127.0.0.1\n") == ConfigCheck.sshdSocketReload)
    #expect(sshdReload(nil, "Port 2222\n") == ConfigCheck.sshdSocketReload, "no old text: as changed")
    #expect(builtIn("/etc/ssh/sshd_config.d/port.conf").reload(after: .passed(""), on: root, old: Data("Port 22".utf8)) { Data("Port 2200".utf8) } == ConfigCheck.sshdSocketReload)
    #expect(ConfigCheck.sshdSocketReload == "if systemctl is-active -q ssh.socket; then systemctl daemon-reload && systemctl restart ssh.socket; else systemctl reload ssh || systemctl reload sshd; fi")
}

private func checkDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-check-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// A stand-in validator: fails on a file with "BAD" in it, saying so on stderr.
let badCheck = #"sh -c 'echo "checking $1"; grep -q BAD "$1" && { echo "line 1: BAD here" >&2; exit 1; }; echo ok' check %f"#

// These run processes: in the one serialized suite with the rest (`SudoPasswordTests`).
extension SudoPasswordTests {

/// A check runs on the file's server (`.local()`: this Mac's sh) as the panel's user: its exit status (255 too, as
/// `sshd -t` gives) and output, stdout and stderr in order; `%f` with a space and a quote is one word there. A program
/// that isn't there is no check, not a failure; a root-only check on a user's panel isn't run at all.
@Test func checksRunOnTheServerAsThePanelsUser() throws {
    let d = checkDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let file = d + "/a b'c.conf"
    try Data("listen 80; BAD\n".utf8).write(to: URL(fileURLWithPath: file))
    #expect(ran(ConfigCheck.expand(badCheck, path: file), on: .local()) == .failed(status: 1, output: "checking \(file)\nline 1: BAD here\n"))
    try Data("listen 80;\n".utf8).write(to: URL(fileURLWithPath: file))
    #expect(ran(ConfigCheck.expand(badCheck, path: file), on: .local()) == .passed("checking \(file)\nok\n"))
    #expect(ran("sh -c 'echo no >&2; exit 255'", on: .local()) == .failed(status: 255, output: "no\n"))
    #expect(ran("kermo-no-such-validator -t %f", on: .local()) == .noProgram("kermo-no-such-validator"))
    #expect(ran("sshd -t", on: .local(), root: true) == .needsRoot)
}

/// On a root panel the check runs through the server's sudo (`sudo -n -- sh -c …`); its own exit status counts, not sudo's.
@Test func rootChecksRunThroughSudo() throws {
    let d = checkDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fake = try fakeSudo(d), t = SFTPTarget.local(sudo: fake)
    #expect(ran("sh -c 'echo as root'", on: t, root: true) == .passed("as root\n"))
    #expect(sudoLog(fake).count == 1 && sudoLog(fake)[0].hasPrefix("-n -- sh -c PATH="))
    #expect(ran("sh -c 'echo broken >&2; exit 1'", on: t) == .failed(status: 1, output: "broken\n"))
    #expect(ran("kermo-no-such-validator", on: t) == .noProgram("kermo-no-such-validator"))
}

/// Where sudo wants a password: `-n` first, then the password (the panel's, kept — or asked) as a line on stdin,
/// never in the command line or sudo's log. A wrong one asks again; a check that fails after the password was taken
/// is the file's failure, not the password's (told by what the script printed, not the exit status).
@Test func rootChecksWithASudoPassword() throws {
    let d = checkDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fake = try fakeSudo(d, Self.passwordSudo)
    let a = Answers(["nope", "kermo-test-pw"])
    try Self.answering(a) {
        #expect(ran("sh -c 'echo bad >&2; exit 1'", on: .local(sudo: fake), root: true) == .failed(status: 1, output: "bad\n"))
        #expect(a.wrong == [false, true] && a.taken == ["kermo-test-pw"])
        #expect(sudoLog(fake).map { String($0.prefix(19)) } == ["-n -- sh -c PATH=\"$", "-S -p  -k -- sh -c ", "-S -p  -k -- sh -c "])
    }
    #expect(!(try String(contentsOfFile: fake + ".log", encoding: .utf8)).contains("kermo-test-pw"))
}

/// sudo that won't run it (NOPASSWD for sftp-server only, no other rule): its words, nothing asked — the check didn't
/// run, which is no verdict on the file. Wanting a password with no way to ask: said so.
@Test func rootCheckSudoWontRunSaysWhy() throws {
    let d = checkDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fake = try fakeSudo(d, #"echo "Sorry, user me is not allowed to execute '/bin/sh' as root on web." >&2; exit 1"#)
    let a = Answers(["kermo-test-pw"])
    try Self.answering(a) {
        let e = #expect(throws: ConfigCheck.NotRun.self) { try ConfigCheck.run("visudo -cf /x", on: .local(sudo: fake), root: true) }
        #expect(e?.message == "“visudo” couldn't run on localhost as root: sudo on localhost refused: Sorry, user me is not allowed to execute '/bin/sh' as root on web.")
        #expect(a.wrong.isEmpty)
    }
    let pw = try fakeSudo(d, Self.passwordSudo)
    let e = #expect(throws: ConfigCheck.NotRun.self) { try ConfigCheck.run("visudo -cf /x", on: .local(sudo: pw), root: true) }
    #expect(e?.message == "“visudo” couldn't run on localhost as root: sudo on localhost needs a password")
}

/// "Before": the check runs on the partial file next to it — a failure leaves the server's file as it was (renamed over
/// it or copied into it: a symlink's target, another owner's file, SELinux), the partial file gone, no version kept;
/// the check's words come back. Then a good text goes in. Exact round trips of ⌘S (2 KB, opened with F4): 8 checked or
/// not — the check is an ssh command, no SFTP packet (8 on the code before, `rootSaveWritesInPlaceUnderSELinux`); a
/// failed one 6 (a symlink 7: one more to follow it).
@Test func badTextNeverReplacesTheFile() throws {
    let d = checkDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let rule = ConfigCheck(match: "*.conf", check: badCheck)
    func put(_ p: String, _ text: String) throws { try Data((text + String(repeating: "#", count: 2048 - text.count)).utf8).write(to: URL(fileURLWithPath: p)) }
    func partials() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: d))?.filter { $0.hasPrefix(".dfm-partial-") } ?? [] }
    for link in [false, true] {
        let file = d + "/site\(link ? "-link" : "").conf", real = link ? d + "/real.conf" : file
        try put(real, "good\n")
        if link { try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: real) }
        let c = try SFTPClient(.local())
        defer { c.close() }
        let a = try c.download(file, to: d + "/l")
        try put(d + "/l", "BAD\n")
        var kept = 0, before = c.roundTrips
        let e = #expect(throws: SFTPClient.CheckFailed.self) {
            try c.save(d + "/l", to: file, baseline: a, rule: rule) { _, _ in kept += 1 }
        }
        let failTrips = c.roundTrips - before
        #expect(e?.status == 1 && e?.output == "checking \(d)/\(partials().first ?? ".dfm-partial-…")\nline 1: BAD here\n" || e?.output.hasSuffix("line 1: BAD here\n") == true)
        #expect(e?.output.contains("/.dfm-partial-") == true, "checked the partial file, not the file")
        #expect(String(decoding: FileManager.default.contents(atPath: real)!, as: UTF8.self).hasPrefix("good\n") && partials().isEmpty && kept == 0, "link: \(link)")
        #expect(failTrips == (link ? 7 : 6), "a failed check: \(failTrips) round trips (link: \(link)) — the write, the check, the partial removed")
        try put(d + "/l", "fine\n")
        before = c.roundTrips
        let (attrs, outcome) = try c.save(d + "/l", to: file, baseline: a, rule: rule) { _, _ in kept += 1 }
        #expect(c.roundTrips - before == (link ? 13 : 8), "checked and saved: as unchecked (link: \(link))")
        #expect(outcome == .passed("checking \(d)/\(partials().first ?? "")\nok\n") || outcome.map { if case .passed = $0 { true } else { false } } == true)
        #expect(String(decoding: FileManager.default.contents(atPath: real)!, as: UTF8.self).hasPrefix("fine\n") && attrs.size == 2048 && partials().isEmpty && kept == 1)
        if link { #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: file)) == real, "still a link") }
    }
    // No rule, a rule without a check, an "after" rule (not yet): `upload` as it was.
    let c = try SFTPClient(.local())
    defer { c.close() }
    try put(d + "/plain.conf", "x\n"); try put(d + "/l", "BAD\n")
    for r in [nil, ConfigCheck(match: "*", check: nil, reload: "true")] {
        #expect(try c.save(d + "/l", to: d + "/plain.conf", baseline: nil, rule: r).outcome == nil)
    }
}

/// A check that couldn't run — sudo refused it — isn't a pass: before, nothing goes in (sudoers, sshd_config are never
/// put in unchecked). A root-only check on a user's panel isn't run: the save goes in and says so.
@Test func uncheckedBeforeRules() throws {
    let d = checkDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try Data("old".utf8).write(to: URL(fileURLWithPath: d + "/sudoers"))
    try Data("new".utf8).write(to: URL(fileURLWithPath: d + "/l"))
    let rule = ConfigCheck(match: "*/sudoers", check: "visudo -cf %f", root: true)
    let refusing = try fakeSudo(d, #"[ "$3" = sh ] && { echo "Sorry, user me is not allowed to execute '/bin/sh' as root on web." >&2; exit 1; }; shift 2; exec "$@""#)
    let root = try SFTPClient(.local(sudo: refusing))
    defer { root.close() }
    #expect(throws: ConfigCheck.NotRun.self) { try root.save(d + "/l", to: d + "/sudoers", baseline: nil, rule: rule) }
    #expect(FileManager.default.contents(atPath: d + "/sudoers") == Data("old".utf8))
    let user = try SFTPClient(.local())
    defer { user.close() }
    #expect(try user.save(d + "/l", to: d + "/sudoers", baseline: nil, rule: rule).outcome == .needsRoot)
    #expect(FileManager.default.contents(atPath: d + "/sudoers") == Data("new".utf8))
}

/// "After": the check runs on the file in place; a failure puts back the text this save replaced — the bytes the save
/// itself read, over the same upload, never the history folder's — and keeps no version of the bad text. The version
/// it replaced is in the history. Exact round trips (2 KB, opened with F4): 8 when it passes, as unchecked; 16 when
/// it's put back (the put-back is a save of its own, checked against what this one wrote).
@Test func badTextIsPutBack() throws {
    let d = checkDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let h = ServerHistory(root: d + "/history"), rule = ConfigCheck(match: "*.conf", check: badCheck, when: .after, reload: "true")
    let file = d + "/site.conf"
    func put(_ p: String, _ text: String) throws { try Data((text + String(repeating: "#", count: 2048 - text.count)).utf8).write(to: URL(fileURLWithPath: p)) }
    func text() -> String { String(decoding: FileManager.default.contents(atPath: file)!, as: UTF8.self) }
    try put(file, "good\n")
    let c = try SFTPClient(.local())
    defer { c.close() }
    let a = try c.download(file, to: d + "/l")
    try put(d + "/l", "BAD\n")
    var before = c.roundTrips
    let e = #expect(throws: SFTPClient.CheckFailed.self) {
        try c.save(d + "/l", to: file, baseline: a, rule: rule) { h.keep($1, $0, of: c.target, file) }
    }
    #expect(c.roundTrips - before == 16, "\(c.roundTrips - before) round trips")
    #expect(e?.output == "checking \(file)\nline 1: BAD here\n", "the file in place, not a partial one")
    #expect(e?.now == "Put back: the file on localhost is as it was before this save." && text().hasPrefix("good\n"))
    let now = try c.stat(file)
    #expect(e?.attrs?.size == now.size && e?.attrs?.mtime == now.mtime, "the editor's next baseline: what's there")
    let versions = h.versions(of: c.target, file)
    #expect(versions.count == 1 && FileManager.default.contents(atPath: versions[0].path).map { String(decoding: $0, as: UTF8.self).hasPrefix("good\n") } == true,
            "the version this save replaced; none of the bad text")
    try put(d + "/l", "fine\n")
    before = c.roundTrips
    let ok = try c.save(d + "/l", to: file, baseline: e?.attrs, rule: rule) { h.keep($1, $0, of: c.target, file) }
    #expect(c.roundTrips - before == 8 && ok.outcome == .passed("checking \(file)\nok\n") && text().hasPrefix("fine\n") && h.versions(of: c.target, file).count == 2)
}

/// Not put back: someone wrote the file between the save and the check (here the check itself) — theirs stays, as
/// "changed on the server" always does; a file over 5 MB (its old text wasn't kept). A new file is removed, unless it
/// changed meanwhile. Each says so, and
/// gives what's there now as the next baseline. An "after" check that can't run, or is root only on a user's panel:
/// the save is in, unchecked, and says so.
@Test func putBackOnlyWhatThisSaveReplaced() throws {
    let d = checkDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let c = try SFTPClient(.local())
    defer { c.close() }
    try Data("mine".utf8).write(to: URL(fileURLWithPath: d + "/l"))
    func failed(_ name: String, _ check: String) -> SFTPClient.CheckFailed? {
        #expect(throws: SFTPClient.CheckFailed.self) { try c.save(d + "/l", to: d + "/" + name, baseline: nil, rule: ConfigCheck(match: "*", check: check, when: .after)) }
    }
    try Data("old".utf8).write(to: URL(fileURLWithPath: d + "/theirs.conf"))
    let theirs = failed("theirs.conf", #"sh -c 'echo theirs > "$1"; exit 1' x %f"#)
    #expect(theirs?.now == "Not put back: it changed on localhost meanwhile, and what's there now stays.")
    #expect(FileManager.default.contents(atPath: d + "/theirs.conf") == Data("theirs\n".utf8) && theirs?.attrs?.size == 7)

    try Data(repeating: 0x61, count: Int(ServerHistory.fileLimit) + 1).write(to: URL(fileURLWithPath: d + "/big.conf"))
    #expect(failed("big.conf", "false")?.now == "Not put back: it's over 5 MB, so its old text wasn't kept. The file on localhost has your text.")
    #expect(FileManager.default.contents(atPath: d + "/big.conf") == Data("mine".utf8))
    let new = failed("new.conf", "false")
    #expect(new?.now == "Removed: there was no such file on localhost before this save." && new?.attrs == .nothing)
    #expect(!FileManager.default.fileExists(atPath: d + "/new.conf"), "a new broken drop-in doesn't stay to stop the next restart")
    #expect(failed("new2.conf", #"sh -c 'echo theirs > "$1"; exit 1' x %f"#)?.now == "Not removed: it changed on localhost meanwhile, and what's there now stays.")

    let refusing = try fakeSudo(d, #"[ "$3" = sh ] && { echo "Sorry, user me is not allowed to execute '/bin/sh' as root on web." >&2; exit 1; }; shift 2; exec "$@""#)
    let root = try SFTPClient(.local(sudo: refusing))
    defer { root.close() }
    let r = try root.save(d + "/l", to: d + "/nginx.conf", baseline: nil, rule: ConfigCheck(match: "*", check: "nginx -t", when: .after, root: true))
    #expect(r.outcome == .notRun("“nginx” couldn't run on localhost as root: sudo on localhost refused: Sorry, user me is not allowed to execute '/bin/sh' as root on web."))
    #expect(try c.save(d + "/l", to: d + "/nginx.conf", baseline: nil, rule: ConfigCheck(match: "*", check: "nginx -t", when: .after, root: true)).outcome == .needsRoot)
}
}

