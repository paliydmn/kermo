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
