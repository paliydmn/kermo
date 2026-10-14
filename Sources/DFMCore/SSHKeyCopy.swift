import Foundation

/// Copy SSH Key to Server…: this Mac's public key into the server's authorized_keys, as ssh-copy-id does it — but over
/// the shared connection (one login, the one the user already made) and then checked by a login with the key alone.
public enum SSHKeyCopy {
    /// A public key file's line ("ssh-ed25519 AAAA… comment"), or nil if it isn't one: one line, nothing else.
    public static func line(_ pub: String) -> String? {
        let line = pub.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = line.split(separator: " ")
        guard !line.contains(where: \.isNewline), words.count >= 2,
              ["ssh-", "ecdsa-", "sk-"].contains(where: words[0].hasPrefix), words[1].allSatisfy({ $0.isLetter || $0.isNumber || "+/=".contains($0) })
        else { return nil }
        return line
    }

    static let added = "kermo-added", had = "kermo-had"

    /// What runs there, in `sh`: the key line on stdin (never the command line), the file as $1 (relative: to the home
    /// folder). Owner-only folder and file when it makes them (umask), the line added only if it isn't there, after a
    /// newline if the file's last line has none; SELinux labels as sshd wants them, where there are any.
    static let script = """
        f=$1; umask 077; IFS= read -r k || [ -n "$k" ] || exit 3
        case $f in */*) d=${f%/*};; *) d=.;; esac
        mkdir -p -- "$d" || exit 2
        if [ -f "$f" ] && grep -qxF -- "$k" "$f"; then echo \(had); exit 0; fi
        if [ -s "$f" ] && [ -n "$(tail -c1 -- "$f")" ]; then echo >> "$f" || exit 2; fi
        printf '%s\\n' "$k" >> "$f" || exit 2
        command -v restorecon >/dev/null 2>&1 && restorecon -F -- "$d" "$f" >/dev/null 2>&1
        echo \(added)
        """

    /// Adds `key` (a `line`) to `file` on `t`'s server, as its user, over the shared connection (a login first if it's
    /// down: `env`'s askpass). true: added; false: it was there already. Throws what the server said.
    public static func install(_ key: String, on t: SFTPTarget, file: String = ".ssh/authorized_keys", env: [String: String] = [:],
                               cancel: CancelFlag? = nil) throws -> Bool {
        var out = Data()
        let (status, errors) = try SSHCommand.run(t.asRoot(false), "sh -c " + ShellContext.quote(script) + " sh " + ShellContext.quote(file),
                                                  env: env, cancel: cancel, options: ["-x", "-a"], stdin: Data((key + "\n").utf8)) { out += $0 }
        let lines = String(decoding: out, as: UTF8.self).split(separator: "\n")
        if lines.contains(Substring(added)) { return true }
        if lines.contains(Substring(had)) { return false }
        throw SFTPError(message: errors.isEmpty ? "Couldn't add the key on \(t.host) (exit \(status))" : errors)
    }

    /// Logs in to `t`'s server with the private key `identity` alone and runs `true` — a login of its own, past the shared
    /// connection (that one would pass whatever the key). `options`: ssh's, before the host. nil: it worked; else what
    /// ssh said. A passphrase is asked through `env`'s askpass.
    // ponytail: IdentitiesOnly still lets ~/.ssh/config's IdentityFile for that host be tried after `-i`: where one of
    // those already works, a key that didn't go in passes too. `-F` with a stripped config if that ever misleads.
    public static func verify(_ t: SFTPTarget, identity: String, options: [String] = [], env: [String: String] = [:],
                              cancel: CancelFlag? = nil) throws -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "PreferredAuthentications=publickey",
                       "-o", "ConnectTimeout=15", "-x", "-a", "-T"] + options
            + SFTPTarget(host: t.host, port: t.port, identity: identity).arguments() + ["true"]
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let err = Pipe()
        (p.standardInput, p.standardOutput, p.standardError) = (FileHandle.nullDevice, FileHandle.nullDevice, err)
        try p.run()
        try? err.fileHandleForWriting.close()
        let previous = cancel?.onCancel { p.terminate() } ?? nil
        defer { cancel?.onCancel(previous) }
        let said = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if cancel?.isCancelled == true { throw CancellationError() }
        guard p.terminationStatus != 0 else { return nil }
        let text = String(decoding: said, as: UTF8.self).split(whereSeparator: \.isNewline).filter { !$0.contains("Warning: Permanently added") }
        return text.isEmpty ? "ssh exited with status \(p.terminationStatus)" : text.joined(separator: "\n")
    }
}
