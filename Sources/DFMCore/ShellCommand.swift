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

    public init(dir: String, otherDir: String?, cursor: String?, targets: [String]) {
        self.dir = dir; self.otherDir = otherDir; self.cursor = cursor; self.targets = targets
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
