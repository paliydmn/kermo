import Foundation

/// MC-style placeholders for the command line and user menu. Everything is shell-quoted.
///   %f  cursor name        %F  cursor full path
///   %s  target names       %S  target full paths   (targets = marked items, or the cursor item)
///   %d  current folder     %D  other panel's folder
///   %%  a literal %
/// On a server panel the names and folders are the server's, quoted for its POSIX shell.
public struct ShellContext: Sendable {
    public var dir: String
    public var otherDir: String?      // nil: the other panel is on another machine, so %D means nothing here
    public var cursor: String?        // name in `dir`
    public var targets: [String]      // names in `dir`
    public var server: SFTPTarget?    // where `dir` is; nil: this Mac

    public init(dir: String, otherDir: String?, cursor: String?, targets: [String], server: SFTPTarget? = nil) {
        self.dir = dir; self.otherDir = otherDir; self.cursor = cursor; self.targets = targets; self.server = server
    }

    /// nil when the command uses %D and there's no other folder on this machine.
    public func expand(_ command: String) -> String? {
        func full(_ name: String) -> String { (dir as NSString).appendingPathComponent(name) }
        var out = ""
        var it = command.makeIterator()
        while let ch = it.next() {
            guard ch == "%" else { out.append(ch); continue }
            switch it.next() {
            case "f": out += cursor.map(Self.quoteName) ?? ""
            case "F": out += cursor.map { Self.quote(full($0)) } ?? ""
            case "s": out += targets.map(Self.quoteName).joined(separator: " ")
            case "S": out += targets.map { Self.quote(full($0)) }.joined(separator: " ")
            case "d": out += Self.quote(dir)
            case "D":
                guard let otherDir else { return nil }
                out += Self.quote(otherDir)
            case "%": out += "%"
            case let other?: out += "%" + String(other)
            case nil: out += "%"
            }
        }
        return out
    }

    /// What the embedded terminal types to move a running shell to `path`: ^U clears a half-typed line.
    /// nil if the path isn't `isTypeable`.
    public static func typedCd(_ path: String) -> String? { isTypeable(path) ? "\u{15} cd \(quote(path))\r" : nil }

    /// Whether text may be typed into a shell as it is: no C0 control or DEL. The line editor acts on those (^C, ^U, ↩,
    /// ESC) before the shell sees any quotes, so the rest of a crafted name would run as a command. Checked for every
    /// line the app types — a `cd`, a ⌘E command with %f / %s, ⌃↩, dropped files.
    public static func isTypeable(_ text: String) -> Bool { !text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }

    /// POSIX single-quote quoting: safe for any byte sequence the shell may see. A leading "=" is quoted too:
    /// zsh expands `=ls` to /bin/ls.
    public static func quote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-+=:@,".contains($0) } && !s.isEmpty && !s.hasPrefix("=")
            ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A bare name: "./" in front of a leading "-", so `rm %s` on a file named "-rf" doesn't read it as options.
    public static func quoteName(_ name: String) -> String { quote(name.hasPrefix("-") ? "./" + name : name) }
}

/// Send / Execute in Terminal's text — an editor's line or selection — as the bytes a line editor gets.
public enum TerminalText {
    public enum Refusal: Error, Equatable {
        case empty, control, severalLines, tab

        public var words: String {
            switch self {
            case .empty: "Nothing to send: an empty line"
            case .control: "A control character in the text — nothing sent"
            case .severalLines: "Several lines go only into a shell that takes a paste whole — nothing sent"
            case .tab: "A tab would complete, not type, in a shell that doesn't take a paste whole — nothing sent"
            }
        }
    }

    /// The text as it goes: CRLF and CR as LF, one final line end dropped (a selection of whole lines); nothing but
    /// spaces is `.empty`. Never a control character but a line end or a tab (ESC, ^C, ^U act before the shell reads a
    /// word, and an ESC would end a bracketed paste early — `\e[201~` — and run the rest as typed), nor DEL or C1.
    public static func checked(_ text: String) -> Result<String, Refusal> {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if t.hasSuffix("\n") { t.removeLast() }
        if t.allSatisfy(\.isWhitespace) { return .failure(.empty) }
        if t.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" || (0x7f...0x9f).contains($0.value) }) { return .failure(.control) }
        return .success(t)
    }

    /// What the terminal is sent: `clear` — ^U first (Execute: a half-typed line would take the text as its tail);
    /// a line editor that asked for `bracketed` paste gets it as one paste (several lines too: none runs till ↩),
    /// else one line without a tab only; `run` — ↩ after it.
    public static func bytes(_ text: String, bracketed: Bool, run: Bool, clear: Bool) -> Result<[UInt8], Refusal> {
        let t: String
        switch checked(text) {
        case .failure(let r): return .failure(r)
        case .success(let s): t = s
        }
        if !bracketed, t.contains("\n") { return .failure(.severalLines) }
        if !bracketed, t.contains("\t") { return .failure(.tab) }
        let body = Array(t.utf8)
        return .success((clear ? [0x15] : []) + (bracketed ? pasteStart + body + pasteEnd : body) + (run ? [0x0d] : []))
    }

    static let pasteStart: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e], pasteEnd: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]

    /// Execute's command for a new SSH tab, which runs it itself (nothing is typed while ssh may ask a password in the
    /// tab): in `dir`, then the user's shell. One block on lines of its own, all of it in `dir` or none of it — a `;` list,
    /// a trailing `&` or `\\`, a `# comment` stay inside it and leave the shell after it alone; `:` keeps a block of
    /// comments from being empty.
    public static func command(_ text: String, in dir: String) -> String { SSHCommand.shell(in: dir, after: "{\n" + text + "\n:\n}") }
}

/// What a typed command may destroy, told from its words (quotes aren't parsed).
public enum ShellRisk {
    /// Programs that delete or write over what is there (`AICommand.overwrites` asks for these on any server).
    public static let removes: Set<String> = ["rm", "mv", "dd", "truncate", "shred", "unlink"]

    /// R1: a command that removes, moves, re-owns, truncates or stops things, which asks first on a production server:
    /// `rm`, `mv`, `chmod`, `chown`, `dd`, `truncate`, `shred`, `unlink`, `find … -delete / -exec`, `rsync --delete`,
    /// `git clean / reset --hard`, `systemctl stop|restart|disable|mask|kill`, and `> file` — in any command of a list
    /// or pipeline (`cd x && rm -rf y`, `ls; rm x`, `… | xargs rm`, `$(…)`), behind sudo / doas / env / xargs, their
    /// options, VAR=value and a path (/bin/rm). Quotes aren't parsed: a separator inside them asks once too often.
    public static func isDangerous(_ command: String) -> Bool {
        command.components(separatedBy: CharacterSet(charactersIn: ";&|\n()`")).contains(where: isDangerousOne) || writesOver(command)
    }

    private static func isDangerousOne(_ command: String) -> Bool {
        var words = command.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        let name = { (w: String) in (w as NSString).lastPathComponent }   // /usr/bin/sudo, /bin/rm
        var takesValue = ["-u", "-g"]   // `sudo -u www rm …`
        while let w = words.first, ["sudo", "doas", "env", "nohup", "command", "exec", "time", "xargs"].contains(name(w)) || w.hasPrefix("-") || w.contains("=") {
            if name(w) == "xargs" { takesValue = ["-I", "-n", "-P", "-L", "-s", "-E"] }   // `xargs -I {} rm {}`
            words = words.dropFirst(takesValue.contains(w) ? 2 : 1)
        }
        guard let first = words.first.map({ String(name($0).drop(while: { $0 == "\\" })) }) else { return false }   // `\rm`: past the alias
        let rest = words.dropFirst()
        switch first {
        case "systemctl": return rest.first { !$0.hasPrefix("-") }.map { ["stop", "restart", "disable", "mask", "kill"].contains($0) } == true
        case "find": return rest.contains { ["-delete", "-exec", "-execdir", "-ok"].contains($0) }
        case "rsync": return rest.contains { $0.hasPrefix("--delete") || $0 == "--remove-source-files" }
        case "git":
            let sub = rest.first { !$0.hasPrefix("-") }
            return sub == "clean" || sub == "reset" && rest.contains("--hard")
        default: return removes.contains(first) || ["chmod", "chown"].contains(first)
        }
    }

    /// `> file` (not `>>`, `>&2`, nor into /dev/null): the file is emptied before the command even runs.
    public static func writesOver(_ command: String) -> Bool {
        let c = Array(command)
        for i in c.indices where c[i] == ">" && (i == 0 || c[i - 1] != ">") {
            let after = c[(i + 1)...]
            if after.first == ">" || after.first == "&" { continue }
            let target = String(after.drop { $0 == " " || $0 == "\t" }.prefix { !$0.isWhitespace && !";&|)".contains($0) })
            if !target.isEmpty && target != "/dev/null" { return true }
        }
        return false
    }
}
