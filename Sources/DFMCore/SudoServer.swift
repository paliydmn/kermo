import Foundation

/// A root panel's SFTP (`SFTPTarget.sudo`): the server's own sftp-server, run through its `sudo` on the panel's
/// connection — the same protocol, as root. Kermo installs nothing there.
enum SudoServer {
    /// Where systems keep sftp-server; the first executable one is run. Never a path from anywhere else: what the
    /// server prints only picks one of these.
    static let paths = ["/usr/lib/openssh/sftp-server",      // Debian, Ubuntu
                        "/usr/libexec/openssh/sftp-server",  // RHEL, Fedora, Rocky
                        "/usr/lib/ssh/sftp-server",          // Arch, Alpine (openssh-sftp-server)
                        "/usr/libexec/ssh/sftp-server",      // openSUSE
                        "/usr/libexec/sftp-server"]          // BSD, macOS

    /// Servers whose sudo runs sftp-server without a password, by `key`: no need to look again on every session.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: String] = [:]

    private static func key(_ t: SFTPTarget) -> String { "\(t.host):\(t.port ?? 22):\(t.localSudo ?? "")" }

    /// The server's sudo: a test target's stand-in. A local target made root without one runs nothing.
    static func program(_ t: SFTPTarget) -> String { t.localServer == nil ? "sudo" : t.localSudo ?? "/usr/bin/false" }

    /// One command: the first sftp-server of `paths` there, then `sudo -n` on it with nothing to read — it ends at once,
    /// exit 0 if sudo let it run. In `sh`: the login shell may be any.
    static func probe(_ t: SFTPTarget) -> String {
        let script = "for p in \(paths.joined(separator: " ")); do if [ -x \"$p\" ]; then echo \"$p\"; "
            + "exec \(ShellContext.quote(program(t))) -n -- \"$p\" </dev/null; fi; done; exit 127"
        return "sh -c " + ShellContext.quote(script)
    }

    /// The sftp-server to run on `t`'s server, and the password its sudo took if it wants one. A server where it runs
    /// without one is looked at once; a password is never sent unless `sudo -n` refused for want of one just now.
    static func prepare(_ t: SFTPTarget, env: [String: String], cancel: CancelFlag?) throws -> (path: String, password: String?) {
        if let path = lock.withLock({ known[key(t)] }) { return (path, nil) }
        var out = Data()
        let (status, errors) = try SSHCommand.run(t, probe(t), env: env, cancel: cancel) { out += $0 }
        let path = try check(t, out, status, errors, asking: SFTP.sudoPassword != nil)
        guard status != 0 else {
            lock.withLock { known[key(t)] = path }
            return (path, nil)
        }
        return (path, try password(t, path: path, env: env, cancel: cancel))
    }

    /// `probe`'s answer: the path when sudo ran it (exit 0, whatever it said on stderr — a lecture, a warning), else why
    /// not, in plain words. Only how it failed is told by its text. `asking`: a refusal for want of a password returns
    /// the path too (the password is asked for).
    static func check(_ t: SFTPTarget, _ out: Data, _ status: Int32, _ errors: String, asking: Bool = false) throws -> String {
        guard let path = pick(out) else {
            throw SFTPError(message: "sftp-server not found on \(t.host) (looked in \(paths.joined(separator: ", "))). "
                            + "On Alpine sshd serves SFTP itself (internal-sftp): apk add openssh-sftp-server.", connection: true)
        }
        guard status != 0, !(asking && passwordTexts.contains(where: errors.contains)) else { return path }
        throw SFTPError(message: explain(t, path: path, errors) ?? "sudo on \(t.host) didn't run sftp-server: " + (errors.isEmpty ? "exit \(status)" : errors),
                        connection: true)
    }

    /// What sudo says when it wants a password and may not ask (`-n`): sudo 1.8 / 1.9, sudo-rs 0.2.13, sudo-rs 0.2.2.
    static let passwordTexts = ["a password is required", "interactive authentication is required", "authentication failed: interaction required"]

    /// sudo's refusal in plain words; nil for anything else.
    static func explain(_ t: SFTPTarget, path: String, _ errors: String) -> String? {
        let user = t.host.contains("@") ? String(t.host[..<t.host.lastIndex(of: "@")!]) : "<user>"
        if passwordTexts.contains(where: errors.contains) {
            return "sudo on \(t.host) needs a password to run sftp-server as root. To open it without one, allow it there in sudoers: "
                + "\(user) ALL=(root) NOPASSWD: \(path)"
        }
        if errors.contains("must have a tty") {
            return "sudo on \(t.host) runs only from a terminal (Defaults requiretty), and sftp-server has none. "
                + "To open it as root, allow it there in sudoers: Defaults:\(user) !requiretty"
        }
        return nil
    }

    private static let asking = NSLock()
    /// How long the session waits for sftp-server's first answer after the password (tests: less).
    nonisolated(unsafe) static var versionWait: TimeInterval = 10

    /// A password sudo takes (`SFTP.sudoPassword`), tried alone first with `sudo -S -k -v` and end of file: a wrong one
    /// costs one attempt there. Sent with the first packet instead, that packet would count as a second attempt and
    /// the session hang. Three tries, as sudo's own. One at a time: sessions behind a dialog take the answer it got.
    static func password(_ t: SFTPTarget, path: String, env: [String: String], cancel: CancelFlag?) throws -> String {
        try asking.withLock {
            var wrong = false
            for _ in 0..<3 {
                if cancel?.isCancelled == true { throw CancellationError() }
                guard let password = SFTP.sudoPassword?(t, wrong) else { throw CancellationError() }
                guard !password.contains(where: \.isNewline) else { wrong = true; continue }   // sudo reads one line
                let (status, errors) = try SSHCommand.run(t, "\(ShellContext.quote(program(t))) -S -p '' -k -v", env: env, cancel: cancel,
                                                          stdin: Data((password + "\n").utf8)) { _ in }
                if status == 0 {
                    SFTP.sudoPasswordTaken?(t, password)
                    return password
                }
                if errors.contains("invalid option") { throw noStdinPassword(t, path: path) }   // sudo-rs 0.2.2: no -p
                wrong = true
            }
            throw SFTPError(message: "sudo on \(t.host) refused the password 3 times.", connection: true)
        }
    }

    /// sudo-rs 0.2.2 takes no password this way (no `-p`; and it reads all of stdin, not a line).
    static func noStdinPassword(_ t: SFTPTarget, path: String) -> SFTPError {
        let user = t.host.contains("@") ? String(t.host[..<t.host.lastIndex(of: "@")!]) : "<user>"
        return SFTPError(message: "sudo on \(t.host) can't take a password from Kermo (it reads no password line from stdin, as sudo-rs 0.2.2). "
                         + "To open it as root, allow sftp-server without one there in sudoers: \(user) ALL=(root) NOPASSWD: \(path)", connection: true)
    }

    /// The path `probe` printed. A login script may print too: only a line that is one of `paths` counts.
    static func pick(_ out: Data) -> String? {
        String(decoding: out, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init).first(where: paths.contains)
    }

    /// Looked at again next time (a session that didn't start: sudoers may have changed).
    static func forget(_ t: SFTPTarget) { _ = lock.withLock { known.removeValue(forKey: key(t)) } }

    /// The session's program and arguments: ssh running `sudo … -- <path>` there (`-T`: a command, not the sftp
    /// subsystem), or a test target's stand-in sudo itself.
    /// `password`: sudo reads it from stdin, a line before the first packet (`-S`, no prompt, no ticket: `-k`).
    static func launch(_ t: SFTPTarget, path: String, password: Bool = false) -> (program: String, arguments: [String]) {
        let words = (password ? ["-S", "-p", "", "-k"] : ["-n"]) + ["--", path]
        if t.localServer != nil { return (program(t), words) }
        let command = (["sudo"] + words).map { $0.isEmpty ? "''" : $0 }.joined(separator: " ")
        return ("/usr/bin/ssh", SFTP.connectionOptions(t) + ["-x", "-a", "-T"] + t.arguments() + [command])
    }
}
