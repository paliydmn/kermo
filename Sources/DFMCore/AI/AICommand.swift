import Foundation

/// What a shell command the model wants to run may do, told from its words alone.
///
/// The honest limit: this is not a shell. `isReadOnly` is an allow-list and errs towards "changes things": a
/// backslash, a backtick, a separator inside quotes, a `$`, `{` or parenthesis outside single quotes, a path in
/// front of the program, a device under /dev named in the command all make it not read-only — and whatever it
/// passes may run as root (`sudo cat`).
/// `overwrites` catches only what says so itself (`rm`, `mv`, `> file`, `--delete`…): `cp`, `tee`, `sed -i`,
/// `tar x`, a script or `sh -c` can write over a file without a word of it here. So "deleting and overwriting always
/// ask" holds for the typed tools (copy, write), not for a command run under Work-with-commands or All — the card
/// that grants those says so. Reading isn't always free either (a command that never ends: the runner's time limit).
public enum AICommand {
    /// Every command of the list or pipeline is on the allow-list with arguments that only read; no redirection into
    /// a file (`2>/dev/null` and `2>&1` aside), no `<`, no `$`, braces or parentheses for the shell to expand. For a
    /// non-interactive shell, with no terminal: history (`!`), aliases and a pager (`less` has `!command`) aren't
    /// modelled — the runner gives neither. `sudo` / `sudo -n`
    /// in front doesn't change the answer (`sudo cat` reads); `sudo -i`, `sudo su`, `sudo sh` aren't on the list.
    public static func isReadOnly(_ command: String) -> Bool {
        guard let parts = words(command), !parts.isEmpty else { return false }
        return parts.allSatisfy(readsOnly)
    }

    /// The commands of a list or pipeline, each as the words a non-interactive `sh -c` hands over (`glob`: it may
    /// expand to other words). Read scalar by scalar, as the shell reads bytes: to Swift's characters U+037E is a `;`
    /// and a quote with a combining mark isn't a quote. Only single quotes are literal. nil — not told apart
    /// safely: a backslash, a backtick or a control character anywhere; `$ { } ( ) < >` outside single quotes (the
    /// shell expands inside double ones, and a here-document's body isn't words at all); a separator inside quotes
    /// (`find d ';' ls -delete` is one find, not a find and an ls); a quote left open.
    private static func words(_ command: String) -> [[(text: String, glob: Bool)]]? {
        var parts: [[(String, Bool)]] = [[]], word = String.UnicodeScalarView(), quote: Unicode.Scalar?, quoted = false, glob = false
        func end() { if !word.isEmpty || quoted { parts[parts.count - 1].append((String(word), glob)) }; (word, quoted, glob) = (.init(), false, false) }
        func one(_ c: Unicode.Scalar, of set: String) -> Bool { set.unicodeScalars.contains(c) }
        var rest = command.unicodeScalars[...]
        while let c = rest.first {
            if one(c, of: "\\`") || c.value < 0x20 && c != "\n" && c != "\t" || c.value == 0x7f { return nil }
            if quote != "'", one(c, of: "${}()") { return nil }
            if let q = quote {
                if c == q { quote = nil } else if one(c, of: ";&|\n") { return nil } else { word.append(c) }
            } else if c == "'" || c == "\"" {
                (quote, quoted) = (c, true)
            } else if word.isEmpty, !quoted, let quiet = ["2>/dev/null", "2>&1"].first(where: { rest.starts(with: $0.unicodeScalars) }),
                      rest.dropFirst(quiet.count).first.map({ one($0, of: " \t\n;|&") }) != false {
                rest = rest.dropFirst(quiet.count)   // errors to nowhere or into the output, as a whole word
                continue
            } else if one(c, of: "<>") {
                return nil
            } else if c == " " || c == "\t" {
                end()
            } else if one(c, of: ";&|\n") {
                if c == "&" {   // a lone & leaves the command running behind the answer, past the runner's time limit
                    guard rest.dropFirst().first == "&" else { return nil }
                    rest = rest.dropFirst()
                }
                end()
                parts.append([])
            } else {
                if one(c, of: "*?[^#") { glob = true }   // ^ and # are zsh's, with EXTENDED_GLOB
                word.append(c)
            }
            rest = rest.dropFirst()
        }
        guard quote == nil else { return nil }
        end()
        return parts.filter { !$0.isEmpty }
    }

    private static func readsOnly(_ all: [(text: String, glob: Bool)]) -> Bool {
        var w = all.map(\.text)[...]
        if w.first == "sudo" { w = w.dropFirst(w.dropFirst().first == "-n" ? 2 : 1) }
        // `>` here was quoted — awk's `print > "file"`. A device, the kernel's log, another process's pipe: reading
        // one may do things (a watchdog, a tape) or take what was another reader's — as far as the words say:
        // `cat /de?/x`, a FIFO elsewhere, `grep -r x /` on BSD they don't. An option with a letter beyond ASCII: the
        // program reads bytes (`-o` + a combining mark is still -o), the rules below read characters.
        guard let name = w.first, !w.contains(where: { a in   // `ip addr show dev eth0`: a word of its own there
            a.unicodeScalars.contains(">") || name != "ip" && a.split(separator: "/").contains { $0 == "dev" || $0 == "fd" } || a.contains("kmsg") || a.contains("trace_pipe")
                || a.unicodeScalars.first == "-" && !a.unicodeScalars.allSatisfy(\.isASCII)
        }) else { return false }
        let args = Array(w.dropFirst())
        // Names to read taken from stdin (xargs under another name), GNU df's sync(2); grep reading devices.
        if long(args, ["--files0-from", "--sync"]) { return false }
        if name.hasSuffix("grep"), short(args, "RD") || long(args, ["--dereference-recursive", "--devices"]) { return false }
        // None of their other options writes a file or runs a program: whatever a glob expands to.
        if plain.contains(name) { return true }
        // A glob may expand to an option (`sort *` next to a file named -o): not for a program whose options matter.
        return !all.contains(where: \.glob) && rules[name]?(args) == true
    }

    /// Programs with no argument that writes a file, deletes or runs another program (GNU and BSD).
    private static let plain: Set<String> = ["cat", "zcat", "head", "tail", "grep", "egrep", "fgrep", "ls", "stat", "wc", "df", "du", "free",
                                             "uptime", "uname", "whoami", "id", "ps", "lsblk", "findmnt", "cut", "tr", "pwd", "cd"]

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
    /// The subcommand is the first word after the program, with no option in between (one with a value would shift
    /// it). Options after it are the rule's to refuse: GNU and cobra take the program's own there too.
    private static func sub(_ args: [String], _ allowed: Set<String>) -> Bool { args.first.map(allowed.contains) == true }

    /// Programs that read only with the right arguments: true = these arguments only read.
    private static let rules: [String: @Sendable ([String]) -> Bool] = [
        "file": { !short($0, "Cfs") && !long($0, ["--compile", "--files-from", "--special-files"]) },   // -f: names from a file or stdin; -s reads devices
        "hostname": { $0.allSatisfy(["-f", "-s", "-i", "-I", "-d", "-A"].contains) },   // a name sets it
        // -s, a bare date, BSD's `-f format date` set the clock: only how to print now.
        // One +FORMAT: busybox takes a second `+word` for the time to set.
        "date": { $0.filter { $0.hasPrefix("+") }.count <= 1 && $0.allSatisfy { $0.hasPrefix("+") || ["-u", "-R", "--utc", "--universal", "--rfc-email"].contains($0) || $0.hasPrefix("-I") || $0.hasPrefix("--iso-8601") } },
        "netstat": { !short($0, "z") },   // FreeBSD's -z resets the counters
        "sort": { !short($0, "o") && !long($0, ["--output", "--compress-program"]) },
        "uniq": { a in   // a second name is the file written — BSD's may start with a dash once a name came: the one name is the last word
            let names = a.indices.filter { a[$0] == "-" || !a[$0].hasPrefix("-") }
            return !a.contains("--") && names.count <= 1 && names.allSatisfy { $0 == a.count - 1 }
        },
        "sed": { a in   // only `sed -n` printing lines: no -i, no `w file`, no `e command`
            let flags = a.filter { $0.hasPrefix("-") }, address = #"(\d+|/[^/;{}]*/)"#
            return flags.contains { $0.contains("n") } && flags.allSatisfy { $0.dropFirst().allSatisfy("nEr".contains) }
                && named(a).first?.range(of: "^\(address)(,\(address))?p$", options: .regularExpression) != nil
        },
        // No system(), no getline from a command, no program from a file; `|` and `>` are refused before. ARGV: a
        // program names its own input (a device, pieced together); gawk's /inet/ is a connection.
        "awk": { a in
            a.allSatisfy { !$0.hasPrefix("-") || $0.hasPrefix("-F") || $0 == "-v" }
                && !a.contains { w in ["system", "getline", "@", "ARGV", "ARGC", "/inet/"].contains(where: w.contains) }
        },
        "find": { a in !a.contains { ["-delete", "-rm", "-exec", "-execdir", "-ok", "-okdir", "-fls"].contains($0) || $0.hasPrefix("-fprint") } },
        "journalctl": { !long($0, ["--vacuum", "--rotate", "--flush", "--sync", "--setup-keys", "--update-catalog", "--relinquish", "--smart-relinquish", "--cursor-file",
                                    "--image", "--root"]) },   // an image is attached as a loop device and mounted
        "systemctl": { sub($0, ["status", "is-active", "is-enabled", "is-failed", "list-units", "list-timers", "list-unit-files", "list-sockets",
                                "list-dependencies", "cat", "show"])
                       && !short($0, "HM") && !long($0, ["--host", "--machine", "--image", "--root"]) },   // another machine: an ssh from there
        "ip": { a in   // `ip addr add`, `ip route del`, `ip -batch file` change things
            let n = named(a)
            return a.filter { $0.hasPrefix("-") }.allSatisfy(["-4", "-6", "-br", "-brief", "-o", "-oneline", "-c", "-color", "-j", "-json", "-p", "-pretty",
                                                              "-s", "-stats", "-d", "-details", "-h", "-human"].contains)
                && n.first.map(["a", "addr", "address", "r", "route", "l", "link", "n", "neigh", "rule"].contains) == true
                && (n.count == 1 || ["show", "list", "ls", "get"].contains(n[1]))
        },
        "ss": { !short($0, "KD") && !long($0, ["--kill", "--diag"]) },   // -K closes sockets, -D writes a file
        // The test only (-q alone starts the server). As root it creates the log files its config names, if missing.
        "nginx": { ($0.contains("-t") || $0.contains("-T")) && $0.allSatisfy(["-t", "-T", "-q"].contains) },
        "docker": containers, "podman": containers,   // podman-docker's `docker` is podman
    ]
    /// A subcommand that shows, and only the options named here, spelled out: podman takes its own after the
    /// subcommand too — another storage, host or runtime, a profile written over any file (`--cpu-profile`).
    private static let containers: @Sendable ([String]) -> Bool = { a in
        sub(a, ["ps", "logs", "inspect", "images", "version", "info"]) && a.filter { $0.hasPrefix("-") }.allSatisfy {
            ["-a", "--all", "-q", "--quiet", "-n", "--last", "-l", "--latest", "-s", "--size", "--no-trunc", "--format", "-f", "--filter", "--tail", "--since",
             "--until", "-t", "--timestamps", "--details"].contains(String($0.prefix { $0 != "=" }))
        }
    }

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
