import Foundation

/// Shell commands for operations that need root. Paths are absolute and shell-quoted; the caller
/// runs them through the system authentication dialog (see `osascriptArguments`).
public enum AdminCommand {
    private static func q(_ s: String) -> String { ShellContext.quote(s) }

    /// ditto keeps mode, owner, ACLs, xattrs and dates; each item lands as destDir/<name>. A folder already there is
    /// merged into (ditto). Anything else goes into a folder of root's own in destDir first (0700: nothing running as
    /// the user gets in), then is renamed into place: rename(2) never follows a link at the name — a link swapped in
    /// after `check` is replaced (a file) or refused (a folder), never written through as root.
    // ponytail: a merge into a folder others (or you) can write still follows links planted inside it, and destDir
    // itself is taken as typed; what's copied is the user's files anyway, which anything running as them can change.
    public static func copy(_ sources: [String], to destDir: String) -> String {
        guard !sources.isEmpty else { return "" }
        let rename = "/usr/bin/perl -T -e 'my ($a, $b) = map { /\\A(.*)\\z/s; $1 } @ARGV; rename($a, $b) or die \"$b: $!\\n\"'"
        let one = "c() { if [ -d \"$2\" ] && [ ! -L \"$2\" ]; then /usr/bin/ditto \"$1\" \"$2\"; return; fi; "
            + "/bin/mkdir -p \"$3\" && t=$(/usr/bin/mktemp -d \"$3/.kermo-admin.XXXXXX\") || return 1; "   // ditto made a new destDir
            + "/usr/bin/ditto \"$1\" \"$t/x\" && \(rename) -- \"$t/x\" \"$2\"; r=$?; /bin/rm -rf \"$t\"; return $r; }; "
        return one + sources.map { "c \(q($0)) \(q((destDir as NSString).appendingPathComponent(($0 as NSString).lastPathComponent))) \(q(destDir))" }
            .joined(separator: " && ")
    }

    /// What a copy or move as root must not do, looked at before the password is asked (a plain F5/F6 checks the
    /// same): a folder into itself or below it (ditto recursed until the disk was full), through a link at
    /// destDir/<name> (root would write where it points), an item onto itself. `existing`: names there already,
    /// which ditto replaces. `destDir` needn't be there yet: ditto makes it, so its nearest folder that is counts.
    // A link put at destDir/<name> after this look: `copy` renames over it, never through it.
    public static func check(_ sources: [String], to destDir: String, move: Bool) -> (refusal: String?, existing: [String]) {
        var there = destDir
        while access(there, F_OK) != 0, there != "/", !there.isEmpty { there = (there as NSString).deletingLastPathComponent }
        var existing: [String] = []
        for src in sources {
            let name = (src as NSString).lastPathComponent, target = (destDir as NSString).appendingPathComponent(name)
            var s = stat(), t = stat()
            guard lstat(src, &s) == 0 else { continue }   // gone: ditto or mv says so
            if s.st_mode & S_IFMT == S_IFDIR, FileJob.isInside(there, s) {
                return ("Cannot \(move ? "move" : "copy") a folder into itself", [])
            }
            guard lstat(target, &t) == 0 else { continue }
            if t.st_mode & S_IFMT == S_IFLNK { return ("“\(name)” in \(destDir) is a link — not followed as root", []) }
            if t.st_dev == s.st_dev && t.st_ino == s.st_ino { return ("“\(name)” is in \(destDir) already", []) }
            existing.append(name)
        }
        return (nil, existing)
    }

    /// Puts the app at `new` in place of `app` (an update), run as the user or as root. It's copied into a folder of the
    /// runner's own beside `app` first (0700) and checked there: `codesign` must find it signed to satisfy `requirement`
    /// (the running Kermo's designated requirement), so nothing swapped in at `new` after Kermo's own check gets
    /// installed. It keeps the old app's owner, and if the second rename fails the old app is put back.
    public static func replaceApp(_ new: String, at app: String, requirement: String) -> String {
        let a = q(app), parent = q((app as NSString).deletingLastPathComponent)
        return "t=$(/usr/bin/mktemp -d \(parent)/.kermo-update.XXXXXX) || exit 1; trap '/bin/rm -rf \"$t\"' EXIT; "
            + "/usr/bin/ditto --noqtn \(q(new)) \"$t/new.app\" && /usr/sbin/chown -R \"$(/usr/bin/stat -f %u:%g \(a))\" \"$t/new.app\" || exit 1; "
            + "/usr/bin/codesign --verify --strict -R \(q("=" + requirement)) \"$t/new.app\" "
            + "|| { echo 'The download isn’t signed as Kermo is; nothing was replaced.' >&2; exit 1; }; "
            + "/bin/mv \(a) \"$t/old.app\" || exit 1; /bin/mv \"$t/new.app\" \(a) || { /bin/mv \"$t/old.app\" \(a); exit 1; }"
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
    /// changed by anything running as them while macOS asks for the password. Then nothing is written if the target
    /// isn't `stamp` ("inode:size:mtime", `stat -f %i:%z:%Fm`; nil: it mustn't exist) — and the write itself
    /// (`writeOver`) opens it without following a link and checks that what it opened is still that inode. Written over
    /// without truncating first and cut to length after: a failed write (a full disk) never leaves an empty file.
    public static func writeContents(_ source: Source, sha256: String, to target: String, stamp: String?, length: Int) -> String {
        let t = q(target)
        let copy = switch source {
        case .text(let text): printing(text)
        case .file(let path): "/bin/cat \(q(path))"
        }
        let unchanged = stamp.map { "[ \"$(/usr/bin/stat -f %i:%z:%Fm \(t))\" = \(q($0)) ]" } ?? "[ ! -e \(t) ]"
        let seen = stamp.map { $0.split(separator: ":").prefix(2).map(String.init) }
        return "c=$(/usr/bin/mktemp /tmp/dfm-admin-save.XXXXXX) || exit 1; trap '/bin/rm -f \"$c\"' EXIT; "
            + "\(copy) > \"$c\" || exit 1; "
            + "[ \"$(/usr/bin/shasum -a 256 < \"$c\")\" = '\(sha256)  -' ] || { echo 'The text arrived changed; nothing was written.' >&2; exit 1; }; "
            + "[ ! -L \(t) ] || { echo '\(isLink)' >&2; exit 1; }; "
            + "\(unchanged) || { echo '\(changedOnDisk)' >&2; exit 1; }; "
            + "umask 022; " + writeOver(target, from: "\"$c\"", inode: seen?.first, size: seen?.dropFirst().first, length: length)
    }
    static let isLink = "It is a symlink now; nothing was written."

    /// Run as root: `from` (a shell word) written over `target` from its start, then cut to `length`. The open doesn't
    /// follow a link at `target` (`O_NOFOLLOW`) and what it opened must be `inode` and `size` (nil: a new file,
    /// `O_EXCL`): a link or another file swapped in after the shell's checks is refused, never written through as
    /// root. The system's perl — the shell has no such open, and code of our own would need to be trusted as root
    /// (signed): /usr/bin is sealed. `-T` ignores PERL5LIB and PERL5OPT.
    static func writeOver(_ target: String, from: String, inode: String?, size: String?, length: Int) -> String {
        let perl = """
        use Fcntl; my ($t, $c, $ino, $size, $len) = map { /\\A(.*)\\z/s; $1 } @ARGV; my $new = $ino eq "-";
        sysopen(my $f, $t, O_WRONLY | O_NOFOLLOW | ($new ? O_CREAT | O_EXCL : 0), 0644) or do { print STDERR
        ($!{ELOOP} ? "\(isLink)" : $!{EEXIST} ? "\(changedOnDisk)" : "$t: $!"), "\\n"; exit 1 };
        my @s = stat($f); if (!$new && ($s[1] != $ino || $s[7] != $size)) { print STDERR "\(changedOnDisk)\\n"; exit 1 }
        open(my $in, "<", $c) or die "$c: $!\\n"; binmode $in; binmode $f; my $d = do { local $/; <$in> };
        for (my $o = 0; $o < length $d;) { my $n = syswrite($f, $d, length($d) - $o, $o); defined $n or die "$t: $!\\n"; $o += $n }
        truncate($f, $len) or die "$t: $!\\n"; close($f) or die "$t: $!\\n";
        """
        return "/usr/bin/perl -T -e \(q(perl)) -- \(q(target)) \(from) \(q(inode ?? "-")) \(q(size ?? "-")) \(length)"
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
