import Foundation

/// What a shell command the model wants to run may do, told from its words alone.
///
/// The honest limit: this is not a shell. `isReadOnly` is an allow-list and errs towards "changes things": a
/// backslash, a parenthesis, a separator inside quotes, a `$` or a `{` outside awk, a path in front of the program,
/// a device under /dev all make a command not read-only — and whatever it passes may run as root (`sudo cat`).
/// `overwrites` catches only what says so itself (`rm`, `mv`, `> file`, `--delete`…): `cp`, `tee`, `sed -i`,
/// `tar x`, a script or `sh -c` can write over a file without a word of it here. So "deleting and overwriting always
/// ask" holds for the typed tools (copy, write), not for a command run under Work-with-commands or All — the card
/// that grants those says so. Reading isn't always free either (a command that never ends: the runner's time limit).
public enum AICommand {
    /// Every command of the list or pipeline is on the allow-list with arguments that only read; no redirection into
    /// a file (`2>/dev/null` and `2>&1` aside), no `$( )`, backticks, parentheses or backslashes. `sudo` / `sudo -n`
    /// in front doesn't change the answer (`sudo cat` reads); `sudo -i`, `sudo su`, `sudo sh` aren't on the list.
    public static func isReadOnly(_ command: String) -> Bool {
        guard let parts = words(command), !parts.isEmpty else { return false }
        return parts.allSatisfy(readsOnly)
    }

    /// The commands of a list or pipeline, each as the words the shell hands over: quotes gone, what they held kept
    /// whole. nil — not told apart safely: a backslash, a backtick, a parenthesis, a control character, a quote left
    /// open, a separator inside quotes (`find d ';' ls -delete` is one find, not a find and an ls).
    private static func words(_ command: String) -> [[String]]? {
        var parts: [[String]] = [[]], word = "", quote: Character?, quoted = false
        func end() { if !word.isEmpty || quoted { parts[parts.count - 1].append(word) }; (word, quoted) = ("", false) }
        var rest = Substring(command)
        while let c = rest.first {
            if let q = quote {
                if c == q { quote = nil } else if ";&|\n".contains(c) { return nil } else { word.append(c) }
            } else if c == "'" || c == "\"" {
                (quote, quoted) = (c, true)
            } else if "\\`()".contains(c) || c.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" || $0.value == 0x7f }) {
                return nil
            } else if word.isEmpty, !quoted, let quiet = ["2>/dev/null", "2>&1"].first(where: rest.hasPrefix),
                      rest.dropFirst(quiet.count).first.map({ " \t\n;|&".contains($0) }) != false {
                rest = rest.dropFirst(quiet.count)   // errors to nowhere or into the output, as a whole word
                continue
            } else if c == " " || c == "\t" {
                end()
            } else if ";&|\n".contains(c) {
                end()
                parts.append([])
            } else {
                word.append(c)
            }
            rest = rest.dropFirst()
        }
        guard quote == nil else { return nil }
        end()
        return parts.filter { !$0.isEmpty }
    }

    private static func readsOnly(_ all: [String]) -> Bool {
        var w = all[...]
        if w.first == "sudo" { w = w.dropFirst(w.dropFirst().first == "-n" ? 2 : 1) }
        guard let name = w.first, !w.contains(where: { $0.contains(">") || $0.hasPrefix("/dev/") }) else { return false }
        // A `$` or `{` could become an option once the shell expands it (`sort {-o,x}`), and so could a glob that
        // starts like one (`find . -del*` next to a file named -delete); awk's `$1` and `{ }` are its own.
        guard name == "awk" || !w.contains(where: { $0.contains("$") || $0.contains("{") }) else { return false }
        guard !w.contains(where: { $0.hasPrefix("-") && $0.contains(where: "*?[".contains) }) else { return false }
        let args = Array(w.dropFirst())
        return plain.contains(name) || rules[name]?(args) == true
    }

    /// Programs with no argument that writes, deletes or runs another program.
    private static let plain: Set<String> = ["cat", "zcat", "head", "tail", "grep", "egrep", "fgrep", "ls", "stat", "wc", "df", "du", "free",
                                             "uptime", "uname", "whoami", "id", "ps", "netstat", "lsblk", "findmnt", "cut", "tr", "pwd", "cd"]

    private static func short(_ args: [String], _ letters: String) -> Bool {
        args.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains(where: letters.contains) }
    }
    /// A long option that starts like one of `names` — or is its start: GNU takes `--o=x` for `--output=x`.
    private static func long(_ args: [String], _ names: [String]) -> Bool {
        args.contains { a in
            let o = a.prefix { $0 != "=" }
            return o.hasPrefix("--") && o.count > 2 && names.contains { o.hasPrefix($0) || $0.hasPrefix(o) }
        }
    }
    private static func named(_ args: [String]) -> [String] { args.filter { !$0.hasPrefix("-") } }
    /// The subcommand is the first word after the program, with no option in between (one with a value would shift it).
    private static func sub(_ args: [String], _ allowed: Set<String>) -> Bool { args.first.map(allowed.contains) == true }

    /// Programs that read only with the right arguments: true = these arguments only read.
    private static let rules: [String: @Sendable ([String]) -> Bool] = [
        "file": { !short($0, "C") && !long($0, ["--compile"]) },
        "hostname": { $0.allSatisfy(["-f", "-s", "-i", "-I", "-d", "-A"].contains) },   // a name sets it
        "date": { a in   // -s and a bare date set the clock
            !short(a, "s") && !long(a, ["--set"])
                && a.indices.allSatisfy { a[$0].hasPrefix("-") || a[$0].hasPrefix("+") || $0 > 0 && ["-d", "--date", "-r", "--reference"].contains(a[$0 - 1]) }
        },
        "sort": { !short($0, "o") && !long($0, ["--output", "--compress-program"]) },
        "uniq": { a in !a.contains("--") && a.filter { $0 == "-" || !$0.hasPrefix("-") }.count <= 1 },   // a second name is the file written
        "sed": { a in   // only `sed -n` printing lines: no -i, no `w file`, no `e command`
            let flags = a.filter { $0.hasPrefix("-") }, address = #"(\d+|/[^/;{}]*/)"#
            return flags.contains { $0.contains("n") } && flags.allSatisfy { $0.dropFirst().allSatisfy("nEr".contains) }
                && named(a).first?.range(of: "^\(address)(,\(address))?p$", options: .regularExpression) != nil
        },
        "awk": { a in   // no system(), no getline from a command, no program from a file; `|` and `>` are refused before
            a.allSatisfy { !$0.hasPrefix("-") || $0.hasPrefix("-F") || $0 == "-v" } && !a.contains { w in ["system", "getline", "@"].contains(where: w.contains) }
        },
        "find": { a in !a.contains { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fls"].contains($0) || $0.hasPrefix("-fprint") } },
        "journalctl": { !long($0, ["--vacuum", "--rotate", "--flush", "--sync", "--setup-keys", "--update-catalog", "--relinquish", "--smart-relinquish", "--cursor-file"]) },
        "systemctl": { sub($0, ["status", "is-active", "is-enabled", "is-failed", "list-units", "list-timers", "list-unit-files", "list-sockets",
                                "list-dependencies", "cat", "show"]) },
        "ip": { a in   // `ip addr add`, `ip route del`, `ip -batch file` change things
            let n = named(a)
            return a.filter { $0.hasPrefix("-") }.allSatisfy(["-4", "-6", "-br", "-brief", "-o", "-oneline", "-c", "-color", "-j", "-json", "-p", "-pretty",
                                                              "-s", "-stats", "-d", "-details", "-h", "-human"].contains)
                && n.first.map(["a", "addr", "address", "r", "route", "l", "link", "n", "neigh", "rule"].contains) == true
                && (n.count == 1 || ["show", "list", "ls", "get"].contains(n[1]))
        },
        "ss": { !short($0, "KD") && !long($0, ["--kill", "--diag"]) },   // -K closes sockets, -D writes a file
        "nginx": { !$0.isEmpty && $0.allSatisfy(["-t", "-T", "-q"].contains) },
        "docker": { sub($0, containers) },
        "podman": { sub($0, containers) },
    ]
    private static let containers: Set<String> = ["ps", "logs", "inspect", "images", "version", "info"]

    /// The command says itself that it deletes or writes over something: `rm`, `rmdir`, `mv`, `dd`, `truncate`,
    /// `shred`, `unlink`, `mkfs…` as any word of it (`sh -c 'rm x'`, `xargs rm` — once too often for `echo rm`),
    /// `-delete`, `--del…` (rsync's `--delete`, however short), `--remove-source-files`, `git clean`, `--hard`, and `> file` (`ShellRisk.writesOver`).
    /// Narrower than `ShellRisk.isDangerous` on purpose: chmod, chown and stopping a service aren't asked always.
    public static func overwrites(_ command: String) -> Bool {
        let w = command.components(separatedBy: CharacterSet(charactersIn: ";&|\n()`'\"\\").union(.whitespaces)).map { ($0 as NSString).lastPathComponent }
        return w.contains { ShellRisk.removes.contains($0) || $0 == "rmdir" || $0.hasPrefix("mkfs") || $0 == "-delete" || $0.hasPrefix("--del")
                            || $0 == "--remove-source-files" || $0 == "--hard" }
            || w.contains("git") && w.contains("clean") || ShellRisk.writesOver(command)
    }
}
