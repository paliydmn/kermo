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
