import Foundation
@testable import DFMCore
import Testing

// Task 23 PR 1: the AI core — what a command may do, secrets, a chat's scope, the tools' targets. No app, no network.

@Test func aiReadOnlyIsAnAllowList() {
    for c in ["cat /etc/nginx/nginx.conf", "sudo cat /etc/shadow", "sudo -n tail -n 50 /var/log/syslog", "ls -la /srv | head -5", "ps aux | grep nginx | wc -l",
              "tail -n 100 /var/log/app.log 2>/dev/null", "grep -rn error /var/log 2>&1 | sort | uniq -c | sort -rn", "df -h; free -m", "cd /srv/app && ls",
              "journalctl -u nginx -n 100 --no-pager", "systemctl status nginx", "sudo systemctl is-active nginx", "docker ps -a", "podman logs --tail 50 web",
              "find /var/log -name '*.log' -mtime +7", "sed -n '10,20p' /etc/hosts", "sed -nE /listen/p nginx.conf", "awk '{print $1}' access.log", "ip a",
              "ip -br addr show", "ip route get 1.1.1.1", "ss -tlnp", "nginx -t", "sudo nginx -T", "date +%s", "date -d yesterday", "hostname -f", "uniq -c names",
              "du -sh /var/* | sort -h", "sort < names", "grep 'a b' f", "sed -n '/server name/p' f", "ls \"My Docs\"", "cat a 2>&1"] {
        #expect(AICommand.isReadOnly(c), Comment(rawValue: c))
    }
    for c in ["rm -rf /srv", "cat a > b", "cat a >> b", "cat a 2>/dev/null.txt", "cat a 2> err", "cat $(rm x)", "cat `rm x`", "cat <(rm x)", "cat a & rm b",
              "cat a\nrm b", "cat a; rm b", "ls | xargs rm", "ls.sh", "/bin/cat a", "FOO=1 cat a", "env cat a", "sudo -i", "sudo su", "sudo sh", "sudo -u www cat a",
              "sudo", "", "  ;  ", "less /etc/passwd", "zgrep x a.gz", "tee x", "echo hi", "sort -o names names", "sort \"-o\" names names", "sort --output=names x", "sort {-o,x} y",
              "sort $X", "uniq a b", "sed -i s/a/b/ f", "sed -ni 1p f", "sed -n '1w out' f", "sed -n 1p;e f", "sed s/a/b/ f", "awk 'BEGIN{system(\"rm x\")}'",
              "awk -f prog.awk", "awk '{print > \"out\"}' f", "awk '{print | \"sh\"}' f", "awk '{\"date\" | getline d}'", "find . -delete", "find . -exec rm {} +",
              "find . -fprint out", "find . -fls out", "journalctl --vacuum-time=1s", "journalctl --rotate", "systemctl restart nginx", "systemctl -H other status x",
              "ip addr add 10.0.0.1/8 dev eth0", "ip route del default", "ip -batch cmds", "ip netns exec x sh", "ss -K dst 10.0.0.1", "nginx", "nginx -s stop",
              "nginx -t -g 'daemon off;'", "date -s 2020-01-01", "date 010100002020", "hostname web-02", "docker exec web sh", "docker rm web", "file -C -m magic",
              "cat a\u{1b}[201~",
              // What the review's agent got through the first version: quotes hiding a separator, GNU's short long options, zsh's =( ).
              "find d1 ';' ls -delete", "find d1 \\; ls -delete", "awk -v cat='touch t5' 'BEGIN { print | cat }'", "sort f ';' cat -o g", "sed -n 1p f ';' cat -i",
              "sed -n 1p f -\\\nid", "sort --o=/tmp/out in", "file --compil x", "date --s=2020-01-01", "journalctl --rot", "ss --di=/tmp/d",
              "journalctl --cursor-file=/tmp/c -n 1", "sort --compress-program=sh f", "uniq - out", "cat a | uniq - out", "uniq -- in -out", "cat =(touch t3)",
              "ls *(e:'touch t4':)", "cat (touch t)", "find . -del*", "sudo cat /dev/watchdog", "cat 'a", "sed -n '$p' f"] {
        #expect(!AICommand.isReadOnly(c), Comment(rawValue: c))
    }
}

@Test func aiOverwritesIsWhatTheCommandSaysItself() {
    for c in ["rm x", "sudo rm -rf /srv/old", "rmdir d", "mv a b", "sh -c 'rm x'", "ls | xargs rm", "/bin/rm x", "truncate -s 0 log", "shred key", "dd if=a of=b",
              "mkfs.ext4 /dev/sdb1", "unlink x", "find . -name '*.tmp' -delete", "rsync -a --delete a/ b/", "rsync --delete-after a b", "rsync -a --del a b", "rsync --remove-source-files a b",
              "git clean -fd", "git reset --hard", "git rm x", "echo x > file", "cat a 2> err", "(rm x)"] {
        #expect(AICommand.overwrites(c), Comment(rawValue: c))
    }
    // Not asked always (README §4): services, sudo, permissions; and what the words don't say — the honest limit.
    for c in ["systemctl restart nginx", "sudo systemctl stop nginx", "chmod 600 key", "chown www x", "echo x >> log", "ls 2>/dev/null", "make 2>&1", "mkdir d",
              "cp a b", "tee out", "sed -i s/a/b/ f", "tar xf a.tar", "cat rmdir.log"] {
        #expect(!AICommand.overwrites(c), Comment(rawValue: c))
    }
    #expect(ShellRisk.isDangerous("chmod +x a") && ShellRisk.isDangerous("rm x") && !ShellRisk.isDangerous("rmdir x"), "the production question's list is its own")
}

@Test func aiSecretsAreMasked() {
    // Made of parts: nothing here may look like a key to a scanner (the pre-commit hook, GitHub).
    let key = "PRIVATE " + "KEY", aws = "AKIA" + "IOSFODNN7EXAMPLE", gh = "ghp" + "_abcdefghijklmnopqrstuvwx"
    let pem = "-----BEGIN OPENSSH \(key)-----\nb3BlbnNzaC1rZXk\nAAAA\n-----END OPENSSH \(key)-----"
    let cases: [(String, String, Int)] = [
        ("key:\n\(pem)\nend", "key:\n•••\nend", 1),
        ("-----BEGIN RSA \(key)-----\nMIIEow", "•••", 1),   // cut before its END
        ("Authorization: Bearer eyJhbGciOi.J9-abc_123", "Authorization: Bearer •••", 1),
        ("Authorization: Basic dXNlcjpwYXNzd29yZA==", "Authorization: Basic •••", 1),
        ("postgres://app:s3cr3t@db-01:5432/app", "postgres://app:•••@db-01:5432/app", 1),
        ("http://web-01:8080/a@b", "http://web-01:8080/a@b", 0),
        ("DB_PASSWORD=hunter2\nPORT=80", "DB_PASSWORD=•••\nPORT=80", 1),
        ("export API_KEY='a b c'", "export API_KEY=•••", 1),
        ("{\"password\": \"a b\", \"user\": \"me\"}", "{\"password\": •••, \"user\": \"me\"}", 1),
        ("db:\n  password: \"cut off", "db:\n  password: •••", 1),
        ("secret_token: abc # x", "secret_token: ••• # x", 1),
        ("aws \(aws) and \(gh)", "aws ••• and •••", 2),
        ("root:$6$salt$abcdefghijklmnopqrstuvwxyz012345:19000:0", "root:•••:19000:0", 1),
        ("listen 80; server_name web-01;", "listen 80; server_name web-01;", 0),
        ("'password' => 'hunter22',", "'password' => •••,", 1),
        ("DB_PASSWORD=abc;def,ghi", "DB_PASSWORD=•••", 1),
        ("\"password\": \"ab\\\"cdSECRET\"", "\"password\": •••", 1),
        ("password:\nuser: bob", "password:\nuser: bob", 0),
        ("redis://:s3cretpw@cache:6379/0", "redis://:•••@cache:6379/0", 1),
        ("-----BEGIN PGP \(key) BLOCK-----\nlQOY\n-----END PGP \(key) BLOCK-----", "•••", 1),
        ("root:$6$rounds=5000$salt$abcdefghijklmnopqrstuvwxyz:19000", "root:•••:19000", 1),
        ("authorization: bearer abcdefghijkl123", "authorization: bearer •••", 1),
    ]
    for (text, masked, hidden) in cases {
        let m = AISecrets.mask(text)
        #expect(m.text == masked && m.hidden == hidden, Comment(rawValue: text))
    }
    #expect(AISecrets.mask("token: Bearer abcdefghijkl123").text == "token: ••• •••", "the token goes, not only the word before it")
    let long = String(repeating: "a.", count: 20_000) + String(repeating: "aB-_9", count: 8_000), start = Date()
    #expect(AISecrets.mask(long).hidden == 0 && Date().timeIntervalSince(start) < 1, "a long token-like run isn't quadratic")
}

@Test func aiPathsAreNormalByTheirWordsAlone() {
    #expect(AITarget.normal("/srv//app/./x/") == "/srv/app/x" && AITarget.normal("/") == "/" && AITarget.normal("~/Downloads", home: "/Users/me") == "/Users/me/Downloads")
    for p in ["", "srv/app", "./x", "~/x", "~", "/srv/app/../etc", "/..", "/a/\u{7}b", "/a\nb"] { #expect(AITarget.normal(p) == nil, Comment(rawValue: p)) }
    #expect(AITarget(.mac, nil, .write) == nil && AITarget(.mac, "x", .read) == nil && AITarget(.server("a"), "~/x", .read) == nil)
    #expect(AITarget(.mac, "~/x", .read)?.path == NSHomeDirectory() + "/x" && AITarget(.server("a"), nil, .run("ls"))?.path == nil)
}

private let web = AIPlace.server("web"), prodDB = AIPlace.server("db")
private func tool(_ name: String) -> AITool { AITools.all.first { $0.name == name }! }
private func decide(_ s: AIScope, _ name: String, _ targets: [AITarget?], overwrites: Bool = true) -> AIScope.Decision {
    s.check(AICall(tool(name), targets.map { $0! }, overwrites: overwrites)) { $0 == prodDB }
}

@Test func aiScopeDecidesEveryCall() {
    var s = AIScope()
    let read = [AITarget(web, "/etc/hosts", .read)], write = [AITarget(web, "/srv/app/conf/a.conf", .write)]
    func run(_ c: String, on p: AIPlace = web) -> [AITarget?] { [AITarget(p, nil, .run(c))] }

    // Nothing granted: everything is a request, never a silent no — and never allowed.
    #expect(decide(s, "read_file", read) == .outside([.init(place: web, level: .view)]))
    #expect(decide(s, "run_command", run("ls")) == .outside([.init(place: web, level: .view)]))
    #expect(decide(s, "run_command", run("make")) == .outside([.init(place: web, level: .work, commands: true)]))
    #expect(decide(s, "write_file", write) == .outside([.init(place: web, level: .work, folder: "/srv/app/conf/a.conf")]))

    // View: reads and read-only commands.
    s.grant(web, .view)
    #expect(decide(s, "read_file", read) == .allowed && decide(s, "run_command", run("sudo cat /etc/shadow | wc -l")) == .allowed)
    #expect(decide(s, "run_command", run("make")) == .outside([.init(place: web, level: .work, commands: true)]))
    #expect(decide(s, "read_file", [AITarget(.mac, "/etc/hosts", .read)]) == .outside([.init(place: .mac, level: .view)]), "this Mac is a place like any other")

    // Work: its folders — by whole names — and commands only when given.
    s.grant(web, .work, folder: "/srv/app/")
    #expect(decide(s, "write_file", write, overwrites: false) == .allowed && decide(s, "write_file", write) == .ask(.overwrites), "an existing file, or not known yet")
    #expect(decide(s, "write_file", [AITarget(web, "/srv/app", .write)], overwrites: false) == .allowed)
    for p in ["/srv/app2/a", "/srv", "/srv/ap", "/etc/passwd"] {
        #expect(decide(s, "write_file", [AITarget(web, p, .write)], overwrites: false) == .outside([.init(place: web, level: .work, folder: p)]), Comment(rawValue: p))
    }
    #expect(decide(s, "run_command", run("make")) == .outside([.init(place: web, level: .work, commands: true)]), "a folder doesn't hold a command in")
    s.grant(web, .view, folder: "/etc", commands: true)
    #expect(s.grants[web] == .init(level: .work, folders: ["/srv/app"]), "a folder and commands asked with View are nothing: they'd wake up at a later Work")
    s.grant(web, .work, commands: true)
    #expect(s.grants[web] == .init(level: .work, folders: ["/srv/app"], commands: true), "granting widens only")
    #expect(decide(s, "run_command", run("make")) == .allowed && decide(s, "run_command", run("sudo systemctl restart nginx")) == .allowed)
    #expect(decide(s, "run_command", run("rm -rf build")) == .ask(.overwrites) && decide(s, "run_command", run("echo x > f")) == .ask(.overwrites))

    // A copy: read there, write here — both must be in.
    let copy = [AITarget(web, "/var/log/app.log", .read), AITarget(.mac, "~/Downloads", .write)]
    let need = AIScope.Need(place: .mac, level: .work, folder: NSHomeDirectory() + "/Downloads")
    #expect(decide(s, "copy", copy, overwrites: false) == .outside([need]))
    s.grant(need)
    #expect(decide(s, "copy", copy, overwrites: false) == .allowed && decide(s, "copy", copy) == .ask(.overwrites))

    // All: everything but what is asked always.
    s.grant(web, .all)
    #expect(decide(s, "write_file", [AITarget(web, "/etc/passwd", .write)], overwrites: false) == .allowed)
    #expect(decide(s, "write_file", [AITarget(web, "/etc/passwd", .write)]) == .ask(.overwrites) && decide(s, "run_command", run("mv a b")) == .ask(.overwrites))
    #expect(decide(s, "copy", [AITarget(web, "/srv/a", .remove), AITarget(.mac, "~/Downloads", .write)], overwrites: false) == .ask(.removes), "a move, when there is one")

    // Production: reading is free in scope, every change asks.
    s.grant(prodDB, .all)
    #expect(decide(s, "read_file", [AITarget(prodDB, "/etc/hosts", .read)]) == .allowed && decide(s, "run_command", run("ps aux", on: prodDB)) == .allowed)
    #expect(decide(s, "run_command", run("make", on: prodDB)) == .ask(.production) && decide(s, "run_command", run("rm x", on: prodDB)) == .ask(.production))
    #expect(decide(s, "write_file", [AITarget(prodDB, "/srv/a", .write)], overwrites: false) == .ask(.production))

    // A call that doesn't fit its tool is asked, never guessed.
    #expect(decide(s, "read_file", []) == .ask(.unclear) && decide(s, "read_file", write, overwrites: false) == .ask(.unclear))
    #expect(decide(s, "propose_edit", write, overwrites: false) == .ask(.unclear) && decide(AIScope(), "focus", []) == .allowed)
    #expect(decide(s, "copy", [AITarget(prodDB, "/a", .read)]) == .ask(.unclear), "half a copy")
    #expect(decide(AIScope(), "read_file", write) == .outside([.init(place: web, level: .work, folder: "/srv/app/conf/a.conf")]), "outside first: not one click past the scope")
    #expect(decide(s, "run_command", run("find d ';' ls -delete")) == .ask(.overwrites))

    s.revoke(web)
    #expect(decide(s, "read_file", read) == .outside([.init(place: web, level: .view)]) && s.grants[prodDB] != nil)
    var odd = AIScope()
    odd.grant(web, .work, folder: "")
    odd.grant(web, .work, folder: "../etc")
    #expect(odd.grants[web]?.folders == [], "a folder that isn't a path is no folder — not /")
    #expect(decide(odd, "write_file", write, overwrites: false) == .outside([.init(place: web, level: .work, folder: "/srv/app/conf/a.conf")]))
}

/// Whatever is asked for — once granted, the same call is never outside again; what is asked always, still is.
@Test func aiGrantingWhatIsNeededIsEnough() {
    let calls: [(String, [AITarget?], asks: Bool)] = [
        ("read_file", [AITarget(web, "/a", .read)], false), ("run_command", [AITarget(web, nil, .run("make install"))], false),
        ("run_command", [AITarget(prodDB, "/srv", .run("make"))], true), ("write_file", [AITarget(web, "/srv/a", .write)], true),
        ("copy", [AITarget(prodDB, "/a", .read), AITarget(.mac, "/tmp/x", .write)], true), ("copy", [AITarget(web, "/a", .remove), AITarget(web, "/b", .write)], true),
    ]
    for (name, targets, asks) in calls {
        var s = AIScope()
        guard case .outside(let needs) = decide(s, name, targets) else { Issue.record("\(name): nothing granted, and not outside"); continue }
        needs.forEach { s.grant($0) }
        let after = decide(s, name, targets)
        if case .outside = after { Issue.record("\(name): still outside after \(needs)") }
        #expect((after != .allowed) == asks, "\(name): overwriting, removing and production still ask")
    }
}

@Test func aiToolsTellWhatACallTouches() throws {
    let names = AITools.all.map(\.name)
    #expect(names == ["focus", "request_scope", "list_folder", "read_file", "terminal_output", "server_info", "run_command", "copy", "write_file", "propose_edit",
                      "open_in_editor"] && Set(names).count == names.count)
    for t in AITools.all {   // a schema both tool use and MCP take: an object, every required name a property, every place's argument a parameter
        guard case .object(let o) = t.schema, case .object(let props)? = o["properties"], case .array(let required)? = o["required"] else { Issue.record("\(t.name)"); continue }
        #expect(o["type"] == "object" && required.allSatisfy { if case .string(let n) = $0 { props[n] != nil } else { false } }, Comment(rawValue: t.name))
        #expect(try JSONSerialization.jsonObject(with: JSONEncoder().encode(t.schema)) is [String: Any])
        for p in t.places {
            var args = [p.server, p.path].compactMap { $0 }
            if case .run(let a) = p.access { args.append(a) }
            #expect(args.allSatisfy { a in t.params.contains { $0.name == a && !$0.bool } }, Comment(rawValue: t.name))
        }
        #expect(t.places.isEmpty == ["focus", "request_scope"].contains(t.name) && (t.kind != .read || t.places.allSatisfy { $0.access == .read }))
    }

    let places: (String) -> AIPlace? = { ["mac": .mac, "web-01": web][$0] }
    #expect(tool("copy").targets(["from_server": "web-01", "from_path": "/var/log/app.log", "to_server": "mac", "to_folder": "~/Downloads/"], resolve: places)
            == [AITarget(web, "/var/log/app.log", .read)!, AITarget(.mac, NSHomeDirectory() + "/Downloads", .write)!])
    #expect(tool("run_command").targets(["server": "web-01", "command": "ls"], resolve: places) == [AITarget(web, nil, .run("ls"))!])
    #expect(tool("run_command").targets(["server": "web-01", "command": "ls", "folder": "/srv"], resolve: places) == [AITarget(web, "/srv", .run("ls"))!])
    #expect(tool("focus").targets([:], resolve: places) == [] && tool("server_info").targets(["server": "mac"], resolve: places) == [AITarget(.mac, nil, .read)!])
    #expect(tool("request_scope").targets(["server": "web-01", "level": "work", "commands": true, "why": "deploy"], resolve: places) == [])
    // Malformed: nothing may be done — nil, never an empty list that reads as "touches nothing".
    let bad: [(String, [String: ToolValue])] = [
        ("read_file", ["server": "web-01"]), ("read_file", ["server": "nobody", "path": "/a"]), ("read_file", ["server": "web-01", "path": "a"]),
        ("read_file", ["server": "web-01", "path": "/a/../b"]), ("read_file", ["server": "web-01", "path": "~/a"]), ("read_file", ["server": "web-01", "path": 1]),
        ("read_file", ["server": "web-01", "path": "/a", "extra": "x"]), ("run_command", ["server": "web-01"]), ("run_command", ["server": "web-01", "command": true]),
        ("request_scope", ["server": "web-01", "level": "root", "why": "x"]), ("request_scope", ["server": "web-01", "level": "work", "commands": "yes", "why": "x"]),
        ("focus", ["server": "web-01"]), ("write_file", ["server": "web-01", "path": "/a"]),
    ]
    for (name, args) in bad { #expect(tool(name).targets(args, resolve: places) == nil, Comment(rawValue: "\(name) \(args)")) }
}

@Test func aiContextShellIsThePanels() {
    let web = SFTPTarget(host: "deploy@web-01.invalid")
    let here = AIContext.Panel(dir: "/Users/me", cursor: "a b", targets: ["a b", "c"], folder: .init(server: nil, dir: "/Users/me"))
    let there = AIContext.Panel(server: web.asRoot(), dir: "/etc", cursor: "hosts", targets: ["hosts"], folder: .init(server: web.asRoot(), dir: "/etc"))
    var s = AIContext(active: here, other: here).shell
    #expect(s.dir == "/Users/me" && s.otherDir == "/Users/me" && s.cursor == "a b" && s.targets == ["a b", "c"] && s.server == nil && s.expand("%S") == "'/Users/me/a b' /Users/me/c")
    #expect(AIContext(active: here, other: there).shell.otherDir == nil && AIContext(active: there, other: here).shell.otherDir == nil, "another machine")
    s = AIContext(active: there, other: .init(server: web, dir: "/srv", folder: .init(server: web, dir: "/srv"))).shell
    #expect(s.otherDir == "/srv" && s.server == web.asRoot(), "the same server, as root or not")
    #expect(AIContext(active: here, other: .init(dir: "/x", folder: nil)).shell.otherDir == nil, "a server tab not connected")
    let list = AIContext.Panel(server: web, dir: ".", cursor: "nginx", targets: ["nginx"], list: "Services", folder: .init(server: web, dir: "/srv"))
    s = AIContext(active: list, other: there).shell
    #expect(s.dir == "." && s.otherDir == nil && s.expand("systemctl status %f") == "systemctl status nginx")
}
