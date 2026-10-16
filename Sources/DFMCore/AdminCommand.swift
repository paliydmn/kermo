import Foundation

/// Shell commands for operations that need root. Paths are absolute and shell-quoted; the caller
/// runs them through the system authentication dialog (see `osascriptArguments`).
public enum AdminCommand {
    private static func q(_ s: String) -> String { ShellContext.quote(s) }

    /// ditto keeps mode, owner, ACLs, xattrs and dates; each item lands as destDir/<name>.
    public static func copy(_ sources: [String], to destDir: String) -> String {
        sources.map { "/usr/bin/ditto \(q($0)) \(q((destDir as NSString).appendingPathComponent(($0 as NSString).lastPathComponent)))" }
            .joined(separator: " && ")
    }

    /// -n: never overwrite something already there.
    public static func move(_ sources: [String], to destDir: String) -> String {
        "/bin/mv -n " + sources.map(q).joined(separator: " ") + " " + q(destDir + "/")
    }

    public static func delete(_ paths: [String]) -> String {
        "/bin/rm -rf -- " + paths.map(q).joined(separator: " ")
    }

    public static func mkdir(_ path: String) -> String { "/bin/mkdir -p \(q(path))" }

    /// Overwrites the file's contents in place, so its owner, mode, ACL and hard links stay as they were.
    /// Never through a symlink: as root, a link planted in a folder others can write would aim this anywhere.
    public static func writeContents(from temp: String, to target: String) -> String {
        "[ ! -L \(q(target)) ] && /bin/cat \(q(temp)) > \(q(target))"
    }

    /// -h: a symlink's own mode, never its target's (same as chown/chflags below).
    public static func chmod(_ mode: String, _ path: String) -> String { "/bin/chmod -h \(q(mode)) \(q(path))" }
    public static func chown(_ owner: String, _ path: String) -> String { "/usr/sbin/chown -h \(q(owner)) \(q(path))" }
    public static func chflags(_ flags: String, _ path: String) -> String { "/usr/bin/chflags -h \(q(flags)) \(q(path))" }

    /// `osascript` arguments that run `command` as root after the standard macOS password prompt.
    /// The command travels as argv, never spliced into AppleScript source, so only shell quoting matters.
    public static func osascriptArguments(_ command: String) -> [String] {
        ["-e", "on run argv", "-e", "do shell script (item 1 of argv) with administrator privileges", "-e", "end run", command]
    }
}

/// Touch ID for sudo in Terminal: `pam_tid.so` in /etc/pam.d/sudo_local, which /etc/pam.d/sudo includes (macOS 14 and
/// later) and macOS updates leave alone — they reset `sudo` itself.
public enum SudoTouchID {
    public static let file = "/etc/pam.d/sudo_local"

    public enum State: Equatable, Sendable { case on, off, noFile }

    /// `text`: sudo_local's, nil when there's none. On: an `auth … pam_tid.so` line not commented out.
    public static func state(_ text: String?) -> State {
        guard let text else { return .noFile }
        return text.split(whereSeparator: \.isNewline).contains { isTouchID($0) } ? .on : .off
    }

    private static func isTouchID(_ line: Substring) -> Bool {
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return f.count >= 3 && f[0] == "auth" && f[2].contains("pam_tid.so")
    }

    /// sudo_local with Touch ID on: the file as it is (none: the template), its commented-out pam_tid line uncommented,
    /// the rest as it was. No such line: it's added at the end — after pam_reattach (tmux), which must come first.
    public static func enabled(_ current: String?, template: String) -> String {
        var lines = (current ?? template).components(separatedBy: "\n")
        let commented = lines.firstIndex { l in
            let t = l.drop { $0 == " " || $0 == "\t" }
            return t.hasPrefix("#") && isTouchID(t.drop { $0 == "#" || $0 == " " || $0 == "\t" })
        }
        if let i = commented {
            lines[i] = String(lines[i].drop { $0 == " " || $0 == "\t" || $0 == "#" })
        } else {
            lines.insert("auth       sufficient     pam_tid.so", at: lines.last == "" ? lines.count - 1 : lines.count)
        }
        let text = lines.joined(separator: "\n")
        return text.hasSuffix("\n") ? text : text + "\n"
    }

    /// Run as root: `temp`'s text into sudo_local, never through a symlink (`AdminCommand.writeContents`); a new file
    /// is 0644 whatever the umask — PAM refuses one others can write.
    public static func command(from temp: String) -> String { "umask 022 && " + AdminCommand.writeContents(from: temp, to: file) }
}
