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
}
