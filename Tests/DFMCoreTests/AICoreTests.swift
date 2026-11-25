import Foundation
@testable import DFMCore
import Testing

// Task 23 PR 1: the AI core — what a command may do, secrets, a chat's scope, the tools' targets. No app, no network.

@Test func aiReadOnlyIsAnAllowList() {
    for c in ["cat /etc/nginx/nginx.conf", "sudo cat /etc/shadow", "sudo -n tail -n 50 /var/log/syslog", "ls -la /srv | head -5", "ps aux | grep nginx | wc -l",
              "tail -n 100 /var/log/app.log 2>/dev/null", "grep -rn error /var/log 2>&1 | sort | uniq -c | sort -rn", "df -h; free -m", "cd /srv/app && ls",
              "journalctl -u nginx -n 100 --no-pager", "systemctl status nginx", "sudo systemctl is-active nginx", "docker ps -a", "podman logs --tail 50 web",
              "find /var/log -name '*.log' -mtime +7", "sed -n '10,20p' /etc/hosts", "sed -nE /listen/p nginx.conf", "awk '{print $1}' access.log", "ip a",
              "ip -br addr show", "ip route get 1.1.1.1", "ss -tlnp", "nginx -t", "sudo nginx -T", "date +%s", "date -u +%F", "netstat -tlnp", "systemctl status --no-pager nginx", "podman ps -a", "cat файл.txt", "nginx -t -q", "hostname -f", "uniq -c names",
              "du -sh /var/* | sort -h", "grep 'a b' f", "sed -n '/server name/p' f", "ls \"My Docs\"", "cat a 2>&1",
              "grep -E 'a{2}|\\$' f".replacingOccurrences(of: "|\\$", with: ""), "grep '$HOME' f", "sed -n '10,20p' f", "awk -F: '{print $1 \"(\" $3 \")\"}' /etc/passwd",
              "cat *.log", "ls -la /var/log/*.gz",
              "ip addr show dev eth0", "docker ps --format '{{.Names}}'", "podman logs --tail=50 web", "grep -rn x /srv/*.conf", "cd /srv && ls && df -h",
              "docker ps -aq", "docker logs --follow web", "wc -l /var/log/*.log", "cat *", "ls ~", "cat ~/notes.txt", "zcat a.gz"] {
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
              "ls *(e:'touch t4':)", "cat (touch t)", "find . -del*", "sudo cat /dev/watchdog", "cat 'a", "cat </dev/kmsg",
              // …and through the second: only single quotes are literal.
              "cat \"`touch t`\"", "awk \"$(touch t)\"", "sort -t \"\\\"\" -o out -t \\\" in", "awk $'BEGIN{sys\\x74em(\"touch t\")}'", "cat \"$X\"",
              "awk \"{print $1}\" f", "sudo sort *", "sed -n 1p *", "cat \"a\u{7}b\"", "ls ${HOME}", "awk {print} f",
              // …and the third review: a here-document, Unicode that Swift's characters fold into syntax, options after a subcommand, BSD.
              "cat <<pwd\nls '$(touch t)'\npwd", "cat <<<x", "sort < names", "find /srv \u{37e} ls -delete", "find /srv '\u{301};cat '\u{301} -exec touch x '{}' +",
              "cat a \u{600}; rm b", "cat a >\u{301}out", "cat a \u{600}>out", "uniq a \u{301}b", "nginx -q", "sudo nginx -q", "uniq in -out",
              "date -f -%Y%m%d%H%M -- -202001010000", "date -d -d 010100002020", "date -d yesterday", "systemctl status -H root@other nginx",
              "systemctl show -M box x", "podman ps --root /tmp/x", "podman ps --url ssh://root@other/x", "podman info --conmon /tmp/prog", "netstat -z",
              "sort ^x", "awk '{print > \"out\"}' f",
              // …and the fourth (task 23 PR 2, before run_command leans on it): podman's own options under either name, options
              // spelled past ASCII, busybox date, devices by another road, names from stdin, awk naming its input, a job left behind.
              "sudo podman ps --cpu-profile /etc/passwd", "sudo podman info --memory-profile=/etc/shadow", "sudo docker ps --root /tmp/x",
              "docker info --conmon /tmp/prog", "docker ps --runtime /tmp/prog", "podman ps --syslog", "cd /etc && sudo sort -o\u{301}x in",
              "sudo sort -o\u{200d}passwd in", "sort --o=\u{301}out in", "sudo ss -D\u{301}dump", "systemctl status -H\u{301}x@10.0.0.5 nginx",
              "journalctl --cursor-f=\u{301}c -n 1", "wc --files0-fro=\u{301}x", "sudo date +%s +1011200", "sudo -n date -u +%F +10112002030",
              "sudo grep -R x /dev", "sudo grep -r x /dev", "sudo grep -D read -r x /", "grep --devices=read -r x /", "cd / && sudo cat dev/watchdog",
              "cd /dev && cat watchdog", "find / -name watchdog -print0 | sudo wc --files0-from=-", "ls | sudo sort --files0-from=-", "du --files0-from=x",
              "find / -name watchdog | sudo file -s -f -", "file --files-from=x", "sudo awk 'NR==1{ARGV[ARGC++]=\"/de\" \"v/watchdog\"}' /etc/hostname",
              "awk '{print}' /inet/tcp/0/10.0.0.5/25", "find . -rm", "sudo find /srv -name '*.log' -rm", "tail -f /var/log/syslog &",
              "sudo tail -f /var/log/syslog 2>&1 &", "df --sync", "df --sy", "sudo cat /proc/kmsg", "sudo cat /sys/kernel/debug/tracing/trace_pipe",
              "sudo head -c 100 /proc/1234/fd/0", "sudo journalctl --image=/x.raw", "sudo systemctl status --image=/x.raw nginx",
              // …and PR 2a's own review: gawk's other spellings, this Mac's case-folding disk, a glob that may bring an option.
              "awk '{print}' /inet4/tcp/0/10.0.0.5/25", "awk 'BEGIN{print SYMTAB[\"ARG\" \"V\"][1]}' f", "cat /DEV/ttys003", "wc *", "grep x *",
              "sudo grep x [a-z]*", "du ?", "docker ps -ax", "docker logs --follow --root /x web",
              // …and the sixth (task 23 PR 3): ~user, a device path glued to an option, zcat -r, a glob after a dash, file -p.
              "sudo cat ~sys/watchdog", "cd ~sys && sudo cat watchdog", "cat x=~sys/watchdog", "cd / && sudo grep -fdev/watchdog x /etc/hostname",
              "cd / && sudo du -Xdev/watchdog /etc", "cd / && sudo du --exclude-from=dev/watchdog /etc", "cd / && sort -R --random-source=dev/watchdog f",
              "cd /proc/1234 && sudo grep -ffd/0 x /etc/hostname", "sudo zcat -r /", "sudo zcat -rf /", "zcat --recursive .", "df --s*", "wc --files0-fro*",
              "du -*", "sudo grep x -? /", "wc *\u{301}", "grep x ?\u{301} /", "sudo file -p /etc/passwd", "file --preserve-date x"] {
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
    // Review 6 PR 8: keys written with a dash or another prefix, a command line's flags, Apache's MD5 hashes.
    let pw = "pass" + "word", apr = "$apr" + "1$abcdefgh$ABCDEFGHIJKLMNOPQRSTUV"
    let more: [(String, String, Int)] = [
        ("APP_KEY=base64:abcDEF123=", "APP_KEY=•••", 1), ("api-key: abc123", "api-key: •••", 1), ("X-Api-Key: abc123", "X-Api-Key: •••", 1),
        ("api_keys: abc", "api_keys: •••", 1), ("\"privateKeyHex\": \"0abc\"", "\"privateKeyHex\": •••", 1), ("apiKeyValue: abc", "apiKeyValue: •••", 1), ("ENCRYPTION_KEY=abc", "ENCRYPTION_KEY=•••", 1),
        ("mysql --\(pw) hunter2 --host db", "mysql --\(pw) ••• --host db", 1), ("mysql --\(pw)=hunter2", "mysql --\(pw)=•••", 1),
        ("vault login --token 'a b'", "vault login --token •••", 1), ("x --db-passphrase abc", "x --db-passphrase •••", 1),
        ("curl --api-key abc --api_key def", "curl --api-key ••• --api_key •••", 2), ("admin:\(apr)", "admin:•••", 1),
        // Hidden on purpose — a key's name says secret, whatever follows it: errs towards hiding.
        ("api-key-rotation-days: 30", "api-key-rotation-days: •••", 1), ("--\(pw)-file=/etc/pw", "--\(pw)-file=•••", 1),
        // Not secrets: a port, a next flag, a path given as one, keys that only end in "key", plain words.
        ("ssh -p 2222 web-01", "ssh -p 2222 web-01", 0), ("mysql --\(pw) --host db", "mysql --\(pw) --host db", 0),
        ("x --\(pw)-file /etc/pw", "x --\(pw)-file /etc/pw", 0), ("x --no-\(pw) db", "x --no-\(pw) db", 0), ("x --token-file /t", "x --token-file /t", 0),
        ("KEY=value", "KEY=value", 0), ("PUBLIC_KEY=ssh-ed25519 AAAA", "PUBLIC_KEY=ssh-ed25519 AAAA", 0), ("SSH_KEY=/root/.ssh/id", "SSH_KEY=/root/.ssh/id", 0),
        ("primary_key: id", "primary_key: id", 0), ("sort_keys=True", "sort_keys=True", 0), ("foreign_keys=ON", "foreign_keys=ON", 0),
        ("app_keyboard=us", "app_keyboard=us", 0), ("Forgot your \(pw)? Reset it.", "Forgot your \(pw)? Reset it.", 0),
    ]
    for (text, masked, hidden) in more {
        let m = AISecrets.mask(text)
        #expect(m.text == masked && m.hidden == hidden, Comment(rawValue: text + " → " + m.text))
        #expect(AISecrets.mask(m.text).text == m.text, "masked twice is masked once: \(text)")
    }
    #expect(AISecrets.mask("token: Bearer abcdefghijkl123").text == "token: ••• •••", "the token goes, not only the word before it")
    let long = String(repeating: "a.", count: 20_000) + String(repeating: "aB-_9", count: 8_000), start = Date()
    #expect(AISecrets.mask(long).hidden == 0 && Date().timeIntervalSince(start) < 1, "a long token-like run isn't quadratic")
    for word in ["api_key_", "pass" + "word", "app-key."] {
        let names = String(repeating: word, count: 5000), began = Date()
        #expect(AISecrets.mask(names).hidden == 0 && Date().timeIntervalSince(began) < 1, "a long run of key names isn't quadratic: \(word)")
    }
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
    #expect(decide(s, "run_command", [AITarget(web, "/dev", .run("sudo cat watchdog"))]) == .outside([.init(place: web, level: .work, commands: true)]),
            "run in /dev, a name is a device")
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
    #expect(decide(s, "copy", copy, overwrites: false) == .ask(.betweenMachines) && decide(s, "copy", copy) == .ask(.betweenMachines),
            "from one machine to another: asked each time, in scope too")
    let here = [AITarget(.mac, "/tmp/a", .read), AITarget(.mac, "~/Downloads", .write)]
    #expect(decide(s, "copy", here, overwrites: false) == .allowed && decide(s, "copy", here) == .ask(.overwrites), "within one machine: as before")

    // All: everything but what is asked always.
    s.grant(web, .all)
    #expect(decide(s, "write_file", [AITarget(web, "/etc/passwd", .write)], overwrites: false) == .allowed)
    #expect(decide(s, "write_file", [AITarget(web, "/etc/passwd", .write)]) == .ask(.overwrites) && decide(s, "run_command", run("mv a b")) == .ask(.overwrites))
    #expect(decide(s, "copy", [AITarget(web, "/srv/a", .remove), AITarget(.mac, "~/Downloads", .write)], overwrites: false) == .ask(.removes), "a move, when there is one")

    // All on both ends still asks for a copy between them — server to server, this Mac to a server — and a removal
    // and production stay the stronger reasons told.
    s.grant(.mac, .all)
    let other = AIPlace.server("backup")
    s.grant(other, .all)
    #expect(decide(s, "copy", [AITarget(web, "/srv/a", .read), AITarget(other, "/srv", .write)], overwrites: false) == .ask(.betweenMachines))
    #expect(decide(s, "copy", [AITarget(.mac, "/tmp/a", .read), AITarget(web, "/srv", .write)], overwrites: false) == .ask(.betweenMachines))
    #expect(decide(s, "copy", [AITarget(web, "/srv/a", .read), AITarget(web, "/srv/b", .write)], overwrites: false) == .allowed)
    #expect(decide(s, "copy", [AITarget(.mac, "/tmp/a", .read), AITarget(prodDB, "/srv", .write)], overwrites: false) == .outside([.init(place: prodDB, level: .work, folder: "/srv")]))
    // Production: reading is free in scope, every change asks.
    s.grant(prodDB, .all)
    #expect(decide(s, "read_file", [AITarget(prodDB, "/etc/hosts", .read)]) == .allowed && decide(s, "run_command", run("ps aux", on: prodDB)) == .allowed)
    #expect(decide(s, "run_command", run("make", on: prodDB)) == .ask(.production) && decide(s, "run_command", run("rm x", on: prodDB)) == .ask(.production))
    #expect(decide(s, "write_file", [AITarget(prodDB, "/srv/a", .write)], overwrites: false) == .ask(.production))
    #expect(decide(s, "copy", [AITarget(.mac, "/tmp/a", .read), AITarget(prodDB, "/srv", .write)], overwrites: false) == .ask(.production))

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

/// The scope row's own word (task 23 PR 8): a place's level down and up, View forgetting folders and commands; what
/// changes something is one predicate for the scope and for Ask.
@Test func aScopeIsSetDownAndUpByTheUser() {
    var s = AIScope()
    s.grant(web, .work, folder: "/srv/app")
    s.set(web, .all)
    #expect(s.grants[web] == AIScope.Grant(level: .all, folders: ["/srv/app"], commands: false))
    s.set(web, .work)
    #expect(s.grants[web] == AIScope.Grant(level: .work, folders: ["/srv/app"], commands: true))
    s.set(web, .view)
    #expect(s.grants[web] == AIScope.Grant(level: .view))
    s.set(web, .work)   // from View: commands, no folder — a write still asks for its folder
    let write = AICall(tool("write_file"), [AITarget(web, "/srv/app/x", .write)!], overwrites: false)
    #expect(s.check(write, prod: { _ in false }) == .outside([AIScope.Need(place: web, level: .work, folder: "/srv/app/x")]))
    #expect(s.covers(AIScope.Need(place: web, level: .work, commands: true)) && !s.covers(AIScope.Need(place: web, level: .work, folder: "/srv"))
            && s.covers(AIScope.Need(place: web, level: .view)) && !s.covers(AIScope.Need(place: web, level: .all)) && !s.covers(AIScope.Need(place: .mac, level: .view)))
    s.grant(.mac, .all)
    s.set(.mac, .work)   // this Mac runs no commands
    #expect(s.grants[.mac] == AIScope.Grant(level: .work) && s.covers(AIScope.Need(place: .mac, level: .view)))
    #expect(!AIScope.changes(AITarget(web, nil, .run("ls -l"))!) && !AIScope.changes(AITarget(web, "/etc", .read)!))
    #expect(AIScope.changes(AITarget(web, nil, .run("ls > x"))!) && AIScope.changes(AITarget(web, "/dev", .run("cat watchdog"))!)
            && AIScope.changes(AITarget(web, nil, .run("tar -czf a.tgz b"))!) && AIScope.changes(AITarget(web, "/a", .write)!))
}

@Test func aiToolsTellWhatACallTouches() throws {
    let names = AITools.all.map(\.name)
    #expect(names == ["focus", "request_scope", "plan", "list_folder", "read_file", "terminal_output", "server_info", "tools", "tool_action", "run_command", "copy",
                      "write_file", "propose_edit", "open_in_editor"] && Set(names).count == names.count)
    for t in AITools.all {   // a schema both tool use and MCP take: an object, every required name a property, every place's argument a parameter
        guard case .object(let o) = t.schema, case .object(let props)? = o["properties"], case .array(let required)? = o["required"] else { Issue.record("\(t.name)"); continue }
        #expect(o["type"] == "object" && required.allSatisfy { if case .string(let n) = $0 { props[n] != nil } else { false } }, Comment(rawValue: t.name))
        #expect(try JSONSerialization.jsonObject(with: JSONEncoder().encode(t.schema)) is [String: Any])
        for p in t.places {
            var args = [p.server, p.path].compactMap { $0 }
            if case .run(let a) = p.access { args.append(a) }
            #expect(args.allSatisfy { a in t.params.contains { $0.name == a && $0.fields == nil } }, Comment(rawValue: t.name))
        }
        #expect(t.places.isEmpty == ["focus", "request_scope", "plan"].contains(t.name) && (t.kind != .read || t.places.allSatisfy { $0.access == .read }))
    }

    let places: (String) -> AIPlace? = { ["mac": .mac, "web-01": web][$0] }
    #expect(tool("copy").targets(["from_server": "web-01", "from_path": "/var/log/app.log", "to_server": "mac", "to_folder": "~/Downloads/"], resolve: places)
            == [AITarget(web, "/var/log/app.log", .read)!, AITarget(.mac, NSHomeDirectory() + "/Downloads", .write)!])
    #expect(tool("run_command").targets(["server": "web-01", "command": "ls"], resolve: places) == [AITarget(web, nil, .run("ls"))!])
    #expect(tool("run_command").targets(["server": "web-01", "command": "ls", "folder": "/srv"], resolve: places) == [AITarget(web, "/srv", .run("ls"))!])
    #expect(tool("focus").targets([:], resolve: places) == [] && tool("server_info").targets(["server": "mac"], resolve: places) == [AITarget(.mac, nil, .read)!])
    // A Tools action is the strictest till the session knows it (task 23 PR 9); then its tool says: a look, a change, one that asks.
    #expect(tool("tool_action").targets(["server": "web-01", "tool": "ufw", "action": "allow", "inputs": [["name": "port", "value": "80"]]], resolve: places)
            == [AITarget(web, nil, .tool(changes: true, asks: true))!])
    var scope = AIScope()
    scope.grant(web, .view)
    func act(_ changes: Bool, _ asks: Bool, prod: Bool = false) -> AIScope.Decision {
        scope.check(AICall(tool("tool_action"), [AITarget(web, nil, .tool(changes: changes, asks: asks))!]), prod: { _ in prod })
    }
    #expect(act(false, false) == .allowed && !AIScope.changes(AITarget(web, nil, .tool(changes: false, asks: true))!), "a look: View is enough, in Ask too")
    #expect(act(true, false) == .outside([AIScope.Need(place: web, level: .work, commands: true)]), "a change: commands, as a command")
    scope.grant(web, .all)
    #expect(act(true, false) == .allowed && act(true, true) == .ask(.always) && act(false, true) == .ask(.always) && act(true, false, prod: true) == .ask(.production))
    #expect(tool("request_scope").targets(["needs": [["server": "web-01", "level": "commands", "folder": "", "why": "deploy"]]], resolve: places) == [])
    #expect(tool("plan").targets(["steps": [["text": "Run it", "state": "doing"]]], resolve: places) == [])
    #expect(AITools.forAgents.map(\.name) == names.filter { $0 != "plan" }, "an outside agent shows its own plan")
    // Malformed: nothing may be done — nil, never an empty list that reads as "touches nothing".
    let bad: [(String, [String: ToolValue])] = [
        ("read_file", ["server": "web-01"]), ("read_file", ["server": "nobody", "path": "/a"]), ("read_file", ["server": "web-01", "path": "a"]),
        ("read_file", ["server": "web-01", "path": "/a/../b"]), ("read_file", ["server": "web-01", "path": "~/a"]), ("read_file", ["server": "web-01", "path": 1]),
        ("read_file", ["server": "web-01", "path": "/a", "extra": "x"]), ("run_command", ["server": "web-01"]), ("run_command", ["server": "web-01", "command": true]),
        ("request_scope", ["server": "web-01", "level": "view", "why": "x"]),   // the old form
        ("request_scope", ["needs": [["server": "web-01", "level": "view", "why": "x"]]]), ("request_scope", ["needs": [["server": "web-01", "level": "view", "folder": false, "why": "x"]]]),
        ("plan", ["steps": [["text": "a"]]]), ("plan", ["steps": "a, b"]),
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

/// A line for a shell that may be fish: no backslash inside single quotes, where fish alone reads it as an escape; a
/// quote, a backslash or a separator with a mark joined to it is still one (the shell reads bytes, not Characters).
@Test func quotesForAnyShell() throws {
    for text in ["plain", "it's", #"a\b"#, #"a\'b"#, #"\\'"#, "two\nlines", "", "=ls", "a'\u{301}b", "a\u{600}'b", "a\u{D4E};b", "кирилиця"] {
        let quoted = ShellContext.quote(text)
        // Read by scalars as fish reads it: a backslash only outside the quotes, where it takes the next one as it is.
        var inside = false, escaped = false
        for c in quoted.unicodeScalars {
            if escaped { escaped = false } else if c == "'" { inside.toggle() } else if c == "\\" { #expect(!inside, "\(quoted)"); escaped = true }
        }
        #expect(!inside, "\(quoted)")
        let sh = Process(), out = Pipe()
        (sh.executableURL, sh.arguments, sh.standardOutput) = (URL(fileURLWithPath: "/bin/sh"), ["-c", "printf %s " + quoted], out)
        try sh.run()
        sh.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == text, "\(quoted)")
    }
    #expect(ShellContext.quoteName("-\u{301}x") == "'./-\u{301}x'", "a leading - with a mark on it")
}


/// `ssh prod` typed in a local tab: where it goes, as its arguments say (task 23 PR 6, the chip's production guess).
@Test func aiSSHDestinationFromItsArguments() {
    let d = { (s: String) in SSHCommand.destination(s.split(separator: " ").map(String.init)) }
    #expect(d("ssh prod") == SFTPTarget(host: "prod"))
    #expect(d("ssh -v root@web ls -la") == SFTPTarget(host: "root@web"))
    #expect(d("ssh -p 2222 -l deploy -i /k db") == SFTPTarget(host: "deploy@db", port: 2222))
    #expect(d("ssh -tp2222 -A -o ServerAliveInterval=5 -J jump db") == SFTPTarget(host: "db", port: 2222))
    #expect(d("ssh -- -odd") == SFTPTarget(host: "-odd"))
    #expect(d("ssh -v") == nil && d("ssh -p") == nil && d("ssh") == nil)
}
