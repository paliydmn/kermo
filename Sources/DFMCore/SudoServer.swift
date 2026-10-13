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

    /// The sftp-server `t`'s sudo runs without a password, looked for once per server.
    static func prepare(_ t: SFTPTarget, env: [String: String], cancel: CancelFlag?) throws -> String {
        if let path = lock.withLock({ known[key(t)] }) { return path }
        var out = Data()
        let (status, errors) = try SSHCommand.run(t, probe(t), env: env, cancel: cancel) { out += $0 }
        guard let path = pick(out), status == 0 else {
            throw SFTPError(message: "sudo on \(t.host) didn't run sftp-server: " + (errors.isEmpty ? "exit \(status)" : errors), connection: true)
        }
        lock.withLock { known[key(t)] = path }
        return path
    }

    /// The path `probe` printed. A login script may print too: only a line that is one of `paths` counts.
    static func pick(_ out: Data) -> String? {
        String(decoding: out, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init).first(where: paths.contains)
    }

    /// Looked at again next time (a session that didn't start: sudoers may have changed).
    static func forget(_ t: SFTPTarget) { _ = lock.withLock { known.removeValue(forKey: key(t)) } }

    /// The session's program and arguments: ssh running `sudo … -- <path>` there (`-T`: a command, not the sftp
    /// subsystem), or a test target's stand-in sudo itself.
    static func launch(_ t: SFTPTarget, path: String) -> (program: String, arguments: [String]) {
        let words = ["-n", "--", path]
        if t.localServer != nil { return (program(t), words) }
        return ("/usr/bin/ssh", SFTP.connectionOptions(t) + ["-x", "-a", "-T"] + t.arguments() + [(["sudo"] + words).joined(separator: " ")])
    }
}
