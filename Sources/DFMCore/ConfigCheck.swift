import Foundation

/// A server file's check when it's saved: a command run there on the new text before it takes the file's place, or on
/// the file after (then a failure puts the old text back), and what reloads the service once it passed. Built-in rules
/// for the usual /etc configs; `~/.config/dfilemanager/validators.json` holds the user's own in the same shape, looked at
/// first. Kermo installs nothing: it runs the server's own tools.
public struct ConfigCheck: Codable, Sendable, Equatable {
    public enum When: String, Codable, Sendable { case before, after }

    /// A glob of the server path (`*` crosses "/" too, so `/etc/nginx/*` is all of it); without a "/", of the file's name.
    public var match: String
    /// A shell command there, `%f` the file's path (quoted). nil (`"check": null`): none — a built-in rule for that path
    /// is off.
    public var check: String?
    /// `before` (default): on the partial file next to it, which takes the file's place only if this passes — for a
    /// file that stands alone (sudoers: broken even for a second, `sudo -n` fails, and with it the way back). `after`:
    /// on the file in place — for configs with includes, which only the live tree checks — the old text put back on failure.
    public var when: When?
    /// Offered once the check passed (or the rule has none).
    public var reload: String?
    /// The check works only as root (`nginx -t`, `sshd -t` …): a user's panel doesn't run it.
    public var root: Bool?

    public init(match: String, check: String?, when: When? = nil, reload: String? = nil, root: Bool? = nil) {
        (self.match, self.check, self.when, self.reload, self.root) = (match, check, when, reload, root)
    }

    public var after: Bool { when == .after }
    public var needsRoot: Bool { root == true }

    /// sshd's reload: Debian names the unit ssh, Red Hat sshd.
    public static let sshdReload = "systemctl reload ssh || systemctl reload sshd"
    /// Where systemd listens for sshd (ssh.socket, Ubuntu 22.10 on) a reload doesn't move the port: its generator reads
    /// Port and ListenAddress on daemon-reload, and the socket listens anew on restart.
    public static let sshdSocketReload = "if systemctl is-active -q ssh.socket; then systemctl daemon-reload && systemctl restart ssh.socket; else \(sshdReload); fi"

    /// What to offer reloading once a save went in under this rule: its reload, when its check passed or it has none;
    /// on a user's panel only the user's own rule's (the built-in ones reload services: root's). sshd's, when Port or
    /// ListenAddress changed between `old` and `new`: the ssh.socket way where that's active.
    public func reload(after outcome: Outcome?, on t: SFTPTarget, old: Data?, new: () -> Data?) -> String? {
        guard let reload, t.sudo || !Self.builtIn.contains(self) else { return nil }
        if check != nil { guard case .passed = outcome else { return nil } }
        return reload == Self.sshdReload && Self.listenChanged(old, new()) ? Self.sshdSocketReload : reload
    }

    /// sshd_config's Port and ListenAddress lines differ (keywords in any case, "Port=22" too; comments aren't).
    static func listenChanged(_ old: Data?, _ new: Data?) -> Bool {
        func lines(_ d: Data?) -> [String] {
            String(decoding: d ?? Data(), as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
                ["port", "listenaddress"].contains($0.split(whereSeparator: { " \t=".contains($0) }).first?.lowercased())
            }
        }
        return lines(old) != lines(new)
    }

    /// Checked on a test server (task notes): each catches a broken config, the `before` ones on a partial file; those
    /// marked root fail as a user even on a good config (no host keys, pid file, netlink, postfix's own refusal, 0440).
    public static let builtIn: [ConfigCheck] = [
        .init(match: "/etc/sudoers", check: "visudo -cf %f", root: true),
        .init(match: "/etc/sudoers.d/*", check: "visudo -cf %f", root: true),
        .init(match: "/etc/ssh/sshd_config", check: "sshd -t -f %f", reload: sshdReload, root: true),
        .init(match: "/etc/ssh/sshd_config.d/*", check: "sshd -t", when: .after, reload: sshdReload, root: true),
        // haproxy and apache may load a key only root reads (`ssl crt`, SSLCertificateKeyFile): a user's false failure.
        .init(match: "/etc/haproxy/haproxy.cfg", check: "haproxy -c -f %f", reload: "systemctl reload haproxy", root: true),
        .init(match: "/etc/nftables.conf", check: "nft -c -f %f", root: true),   // applied by hand: nft -f
        .init(match: "/etc/nginx/*", check: "nginx -t", when: .after, reload: "systemctl reload nginx", root: true),
        .init(match: "/etc/apache2/*", check: "apachectl configtest", when: .after, reload: "systemctl reload apache2", root: true),
        .init(match: "/etc/httpd/*", check: "apachectl configtest", when: .after, reload: "systemctl reload httpd", root: true),
        // A unit's partial file has no unit suffix: systemd-analyze refuses it.
        .init(match: "/etc/systemd/system/*.service", check: "systemd-analyze verify %f", when: .after, reload: "systemctl daemon-reload"),
        .init(match: "/etc/systemd/system/*.timer", check: "systemd-analyze verify %f", when: .after, reload: "systemctl daemon-reload"),
        .init(match: "/etc/postfix/*", check: "postfix check", when: .after, reload: "postfix reload", root: true),
        .init(match: "/etc/bind/named.conf*", check: "named-checkconf", when: .after, reload: "rndc reload"),   // Debian
        .init(match: "/etc/named.conf", check: "named-checkconf", when: .after, reload: "rndc reload"),          // Red Hat
        .init(match: "compose.yaml", check: compose),
        .init(match: "compose.yml", check: compose),
        .init(match: "docker-compose.yaml", check: compose),
        .init(match: "docker-compose.yml", check: compose),
    ]

    /// The partial file is in the same folder: relative paths and .env are the same. No daemon needed. docker without
    /// its compose plugin is no check, not a failure (exit 127).
    static let compose = #"docker compose version >/dev/null 2>&1 || { echo "no docker compose there"; exit 127; }; docker compose -f %f config -q"#

    /// The rules for a save: the user's (`validators.json`'s bytes, nil: no file) first, then the built-in ones. A file
    /// that isn't a list of rules: the built-in ones, and what's wrong with it.
    public static func rules(_ data: Data?) -> (rules: [ConfigCheck], problem: String?) {
        guard let data else { return (builtIn, nil) }
        do { return (try JSONDecoder().decode([ConfigCheck].self, from: data) + builtIn, nil) } catch {
            return (builtIn, "validators.json: \(error.localizedDescription) Built-in checks only.")
        }
    }

    /// The first rule for `path`.
    public static func rule(for path: String, in rules: [ConfigCheck]) -> ConfigCheck? { rules.first { $0.matches(path) } }

    public func matches(_ path: String) -> Bool {
        fnmatch(match, match.contains("/") ? path : (path as NSString).lastPathComponent, 0) == 0
    }

    /// `command` with `%f` the path, quoted for the server's shell; `%%` a "%".
    public static func expand(_ command: String, path: String) -> String {
        command.components(separatedBy: "%%").map { $0.replacingOccurrences(of: "%f", with: ShellContext.quote(path)) }.joined(separator: "%")
    }

    /// How a check (or a reload) went: its output is stdout and stderr together, in order.
    public enum Outcome: Equatable, Sendable {
        case passed(String)
        case failed(status: Int32, output: String)
        /// Its program isn't on that server — or it said "command not found" (exit 127): "no check for this file". Why, in words.
        case noProgram(String)
        /// Root only, and this is a user's panel: not run.
        case needsRoot
        /// An "after" check that didn't get to run (sudo refused, cancelled): the save is in, unchecked.
        case notRun(String)
    }

    /// A check that didn't get to run: sudo refused, or the server couldn't be reached. Not a verdict on the file.
    public struct NotRun: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The program a command runs: its first word.
    public static func program(_ command: String) -> String {
        command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first { !$0.contains("=") }.map(String.init) ?? ""   // past `VAR=x`
    }

    static let ran = "kermo-ran", missing = "kermo-no-program"

    /// What runs there, in `sh` (the login shell may be any): the sbin folders in PATH (a user's on Debian has none, and
    /// haproxy, apachectl live there), a line saying it runs — sudo let it, whatever its exit status — whether the
    /// program is there, then the command with its stderr on stdout, in order, apart from sudo's own words.
    static func script(_ command: String) -> String {
        "PATH=\"$PATH:/usr/local/sbin:/usr/sbin:/sbin\"; echo \(ran); command -v \(ShellContext.quote(program(command))) >/dev/null 2>&1 || "
            + "{ echo \(missing); exit 0; }; exec 2>&1; " + command
    }

    /// Runs `command` (expanded) on `t`'s server — on a root panel's as root, through its sudo (`sudo -n`; where it wants
    /// a password, the one the panel's sudo took, kept or asked: on stdin, never in the command line); else as its user.
    /// `root`: the command works only as root — on a user's panel it doesn't run. One ssh command over the panel's
    /// connection; where sudo wants a password, two (`-n` first, every time: a password goes nowhere else).
    public static func run(_ command: String, on t: SFTPTarget, root: Bool = false, env: [String: String] = [:], cancel: CancelFlag? = nil) throws -> Outcome {
        if root && !t.sudo { return .needsRoot }
        let ranLine = Data((ran + "\n").utf8)
        let status: Int32, out: Data
        do {
            if t.sudo {
                (status, out, _) = try SudoServer.run(t, script: script(command), env: env, cancel: cancel) { $0.range(of: ranLine) != nil }
            } else {
                var o = Data()
                let (s, errors) = try SSHCommand.run(t, "sh -c " + ShellContext.quote(script(command)), env: env, cancel: cancel, options: ["-x", "-a"]) { o += $0 }
                guard o.range(of: ranLine) != nil else { throw SFTPError(message: errors.isEmpty ? "exit \(s)" : errors) }
                (status, out) = (s, o)
            }
        } catch let e as SFTPError {
            throw NotRun(message: "“\(program(command))” couldn't run on \(t.host)\(t.sudo ? " as root" : ""): \(e.message)")
        }
        let text = String(decoding: out, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")   // sshd's messages end in CRLF
        let after = String(text[text.range(of: ran + "\n")!.upperBound...])   // a login script may print before it
        if after.hasPrefix(missing + "\n") { return .noProgram("no \(program(command)) there") }
        if status == 127 { return .noProgram(after.split(whereSeparator: \.isNewline).last.map(String.init) ?? "no \(program(command)) there") }
        return status == 0 ? .passed(after) : .failed(status: status, output: after)
    }
}

extension SFTPClient {
    /// A save's check failed: the server's file is as it was (before), or was put back (after) — or why not.
    public struct CheckFailed: LocalizedError {
        public let rule: ConfigCheck
        public let status: Int32
        public let output: String
        /// What the server's file is now, said in a sentence; "" for a "before" check (as it was).
        public var now = ""
        /// An "after" check's: the next save's baseline — what this save left there: the old text put back, no file, or
        /// its own text (a change someone else made since is asked about then, never taken as the baseline).
        public var attrs: Attrs?
        public var program: String { ConfigCheck.program(rule.check ?? "") }
        public var errorDescription: String? { "“\(program)” found a problem (exit \(status)): \(output)" }
    }

    /// `upload` with the file's check (`rule`, nil: none). "Before": on the partial file, before it takes the file's place
    /// — a failure leaves the file as it was (`CheckFailed`), and so does a check that couldn't run (`ConfigCheck.NotRun`:
    /// sudoers and sshd_config never go in unchecked). "After": on the file in place; a failure puts back the text this
    /// save replaced (the bytes `replaced` got: never looked for elsewhere) over the same `upload` — unless someone
    /// changed it meanwhile (`ChangedOnServer`: theirs stays), or its old text wasn't kept (over `ServerHistory.fileLimit`);
    /// a new file is removed (unless it changed meanwhile). Once the file is replaced, ⎋ stops nothing (`hold`): what it
    /// comes to is said, never lost to a cancel. The new text isn't kept as a version. A check that couldn't run
    /// leaves the save in (`.notRun`). Returns the new attributes and how the check went (nil: none for this file).
    /// `checking`: an "after" check starts (⎋ stops nothing from here on).
    public func save(_ local: String, to remote: String, baseline: Attrs?, force: Bool = false, cancel: CancelFlag? = nil, rule: ConfigCheck?,
                     env: [String: String] = [:], replaced: ((Attrs, Data?) -> Void)? = nil,
                     checking: (() -> Void)? = nil) throws -> (attrs: Attrs, outcome: ConfigCheck.Outcome?) {
        guard let rule, let command = rule.check else {
            return (try upload(local, to: remote, baseline: baseline, force: force, cancel: cancel, replaced: replaced), nil)
        }
        var outcome: ConfigCheck.Outcome?
        if !rule.after {
            let attrs = try upload(local, to: remote, baseline: baseline, force: force, cancel: cancel, replaced: replaced) { [target] partial in
                let o = try ConfigCheck.run(ConfigCheck.expand(command, path: partial), on: target, root: rule.needsRoot, env: env, cancel: cancel)
                if case .failed(let status, let output) = o { throw CheckFailed(rule: rule, status: status, output: output) }
                outcome = o
            }
            return (attrs, outcome)
        }
        var old: Data?, had = false
        let attrs = try upload(local, to: remote, baseline: baseline, force: force, cancel: cancel) { a, data in
            (had, old) = (true, data)
            replaced?(a, data)
        }
        // ponytail: ⎋ in the moment between the rename and this still loses what happened, as for any save.
        cancel?.hold()
        checking?()
        do {
            outcome = try ConfigCheck.run(ConfigCheck.expand(command, path: remote), on: target, root: rule.needsRoot, env: env, cancel: cancel)
        } catch let e as ConfigCheck.NotRun {
            return (attrs, .notRun(e.message))
        } catch is CancellationError {   // the sudo password asked for the check: Cancel
            return (attrs, .notRun("cancelled"))
        }
        guard case .failed(let status, let output) = outcome else { return (attrs, outcome) }
        var failed = CheckFailed(rule: rule, status: status, output: output, attrs: attrs)
        let host = target.host
        guard let old else {
            if had {
                failed.now = "Not put back: it's over \(ServerHistory.fileLimit >> 20) MB, so its old text wasn't kept. The file on \(host) has your text."
            } else if let now = try? lstat(remote), now.size == attrs.size, now.mtime == attrs.mtime {
                // A new file: back as it was is none (a broken drop-in left in conf.d would stop the next restart).
                do {
                    try remove(remote)
                    (failed.now, failed.attrs) = ("Removed: there was no such file on \(host) before this save.", .nothing)
                } catch {
                    failed.now = "Not removed: \(error.localizedDescription). The file on \(host) has your text."
                }
            } else {
                failed.now = "Not removed: it changed on \(host) meanwhile, and what's there now stays."
            }
            throw failed
        }
        let tmp = NSTemporaryDirectory() + "dfm-putback-" + UUID().uuidString
        defer { unlink(tmp) }
        do {
            guard FileManager.default.createFile(atPath: tmp, contents: old, attributes: [.posixPermissions: 0o600]) else { throw LocalFS.posixError() }
            failed.attrs = try upload(tmp, to: remote, baseline: attrs)
            failed.now = "Put back: the file on \(host) is as it was before this save."
        } catch is ChangedOnServer {
            failed.now = "Not put back: it changed on \(host) meanwhile, and what's there now stays."
        } catch {
            failed.now = "Not put back: \(error.localizedDescription). The file on \(host) may have your text."
        }
        throw failed
    }
}
