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

    /// Where `writeContents` gets the text: in the command itself, or a temp file of the user's when that's too long.
    public enum Source: Sendable { case text(String), file(String) }

    /// The longest command `writeContents` puts the text in: half of what osascript's argv took when measured
    /// (1 044 483 bytes, ARG_MAX 1 MiB less the environment). Longer goes through a temp file.
    public static let argvLimit = 512 << 10

    /// What a write that found the file changed since `stamp` says on stderr: the editor asks as it does for any change.
    public static let changedOnDisk = "changed on disk while the password was asked"

    /// `printf` of `text`, quoted for the shell: text that travels in the command, not in a file.
    public static func printing(_ text: String) -> String { "/usr/bin/printf '%s' \(q(text))" }

    /// Overwrites the file's contents in place, so its owner, mode, ACL and hard links stay as they were. Root copies the
    /// text into a file of its own first and writes only if it hashes to `sha256`: a temp file of the user's could be
    /// changed by anything running as them while macOS asks for the password. Then nothing is written if the target is
    /// now a symlink (as root, a link planted in a folder others can write would aim this anywhere) or isn't `stamp`
    /// ("inode:size:mtime", `stat -f %i:%z:%Fm`; nil: it mustn't exist). Written over without truncating first and cut
    /// to length after, so a failed write (a full disk) leaves the new text over the old, never an empty file.
    // ponytail: the symlink check and the write are two calls, a link swapped in between is followed — only an
    // O_NOFOLLOW open as root closes that (D-080: a root helper, which needs Developer ID signing).
    public static func writeContents(_ source: Source, sha256: String, to target: String, stamp: String?, length: Int) -> String {
        let t = q(target)
        let copy = switch source {
        case .text(let text): printing(text)
        case .file(let path): "/bin/cat \(q(path))"
        }
        let unchanged = stamp.map { "[ \"$(/usr/bin/stat -f %i:%z:%Fm \(t))\" = \(q($0)) ]" } ?? "[ ! -e \(t) ]"
        return "c=$(/usr/bin/mktemp /tmp/dfm-admin-save.XXXXXX) || exit 1; trap '/bin/rm -f \"$c\"' EXIT; "
            + "\(copy) > \"$c\" || exit 1; "
            + "[ \"$(/usr/bin/shasum -a 256 < \"$c\")\" = '\(sha256)  -' ] || { echo 'The text arrived changed; nothing was written.' >&2; exit 1; }; "
            + "[ ! -L \(t) ] || { echo 'It is a symlink now; nothing was written.' >&2; exit 1; }; "
            + "\(unchanged) || { echo '\(changedOnDisk)' >&2; exit 1; }; "
            + "umask 022; /bin/dd if=\"$c\" of=\(t) bs=1m conv=notrunc status=none && /bin/dd if=/dev/null of=\(t) bs=1 seek=\(length) status=none"
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
    /// the rest as it was. No such line, or pam_reattach (tmux) below it, which must come first: the line goes at the end.
    public static func enabled(_ current: String?, template: String) -> String {
        var lines = (current ?? template).components(separatedBy: "\n")
        let commented = lines.firstIndex { l in
            let t = l.drop { $0 == " " || $0 == "\t" }
            return t.hasPrefix("#") && isTouchID(t.drop { $0 == "#" || $0 == " " || $0 == "\t" })
        }
        if let i = commented, !lines[(i + 1)...].contains(where: { !$0.drop { $0 == " " || $0 == "\t" }.hasPrefix("#") && $0.contains("pam_reattach") }) {
            lines[i] = String(lines[i].drop { $0 == " " || $0 == "\t" || $0 == "#" })
        } else {
            if let i = commented { lines.remove(at: i) }
            lines.insert("auth       sufficient     pam_tid.so", at: lines.last == "" ? lines.count - 1 : lines.count)
        }
        let text = lines.joined(separator: "\n")
        return text.hasSuffix("\n") ? text : text + "\n"
    }

    /// Run as root: `text` into sudo_local, never through a symlink; a new file is 0644 whatever the umask (PAM refuses
    /// one others can write). The text is in the command itself (osascript's argv): a temp file of the user's could be
    /// changed by anything running as them while macOS asks for the password.
    public static func command(writing text: String) -> String {
        "umask 022 && [ ! -L \(file) ] && \(AdminCommand.printing(text)) > \(file)"
    }
}
