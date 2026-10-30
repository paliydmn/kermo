import Foundation

/// What a Tools run sends (protocol §3, review 2026-10-29 §2.4): a POSIX `sh` script on the stdin of `sh -s`, never
/// a command line for the login shell. It sets the locale, prints a start marker with the server's clock, sets each
/// value as a variable, runs the body with stdin from /dev/null, and on a server keeps a watcher on the real stdin:
/// when ssh goes, its end of file stops the whole session there. Kermo holds stdin open until the run ends
/// (`SSHCommand.run(holdStdin:)`).
public struct ToolPayload: Sendable {
    /// How the body gets root.
    public enum Sudo: Sendable { case none, noPassword, password }

    /// The script for `sh -s`.
    public let script: String
    /// The same with secrets as `•••`: "Show exactly what runs" and the production log.
    public let shown: String
    /// What ssh runs on the server (`sh -s`, `sudo -n sh -s`, or the sudo wrapper); on this Mac, the shell.
    public let command: String
    /// This run's own: in the start marker and the sudo wrapper's.
    public let nonce: String
    public let sudo: Sudo
    /// Values never shown or logged: secrets, and the sudo password `stdin` puts first.
    let secrets: [String]

    /// The payload variables come from: the command (or a script's text), the values its template needed, `env`
    /// (name → its value's shell text), which variables hold secrets, and the text an `accepts` action reads.
    /// `where: .mac` gets no watcher: `kill 0` there would reach Kermo's own process group. `shell`: the server's
    /// `sh` (tests run dash and bash).
    public init(body: String, values: [ToolTemplate.Variable], env: [(name: String, text: String)] = [], secret: Set<String> = [],
                text: String? = nil, sudo: Sudo = .none, where: ToolWhere = .server, nonce: String = ToolPayload.newNonce(),
                sudoProgram: String = "sudo", shell: String = "sh") {
        if [body, text ?? ""].contains(where: { $0.contains("KERMO_\(nonce)") }) || values.contains(where: { $0.value.contains("KERMO_\(nonce)") }) {
            self = ToolPayload(body: body, values: values, env: env, secret: secret, text: text, sudo: sudo, where: `where`,
                               sudoProgram: sudoProgram, shell: shell)   // a fresh nonce: this one is in the text
            return
        }
        let sudo = `where` == .mac ? .none : sudo   // this Mac's part never runs as root
        self.nonce = nonce
        self.sudo = sudo
        let end = "KERMO_\(nonce)"   // a heredoc's last line; a value that holds it gets a fresh nonce
        var real: [String] = [], masked: [String] = []
        func both(_ s: String) { real.append(s); masked.append(s) }
        both("export LC_ALL=C NO_COLOR=1 TERM=dumb COLUMNS=500 PAGER=cat SYSTEMD_PAGER=")
        both("PATH=\"$PATH:/usr/local/sbin:/usr/sbin:/sbin\"; export PATH")   // Debian's users have no sbin
        both("printf 'KERMO-%s %s\\n' \(nonce) \"$(date +%s)\"")
        for v in values {
            if secret.contains(v.name) {   // never in argv: a builtin reads it from a heredoc
                real.append("IFS= read -r \(v.name) <<'\(end)'\n\(v.value)\n\(end)")
                masked.append("IFS= read -r \(v.name) <<'\(end)'\n•••\n\(end)")
            } else { both("\(v.name)=\(ShellContext.quote(v.value))") }
        }
        for e in env { both("export \(e.name)=\(e.text)") }
        // The body's stdin: /dev/null, or an `accepts` action's text in a heredoc — inside the script, never after it.
        let redirect = text == nil ? "</dev/null" : "<<'\(end)'"
        let heredoc = text.map { "\n" + $0 + ($0.hasSuffix("\n") ? "" : "\n") + end } ?? ""
        if `where` == .mac {
            both("{ \(body)\n} \(redirect)\(heredoc)")
            both("exit $?")   // stdin may be held open: `sh -s` mustn't wait there for more script
        } else {
            both("exec 3<&0")
            // The body keeps fd 3 (a read end: it can't hold the watcher's end of file back). Closing it there aborts
            // macOS's bash 3.2 — a macOS server's /bin/sh — with a heredoc on the group, and `3<&- </dev/null` too.
            both("{ \(body)\n} \(redirect) &\(heredoc)")
            both("p=$!")
            // stdin's end = ssh gone: the whole session goes. fd 3 is the pipe the script comes from, so the watcher is
            // the last line: nothing of the script is left there for its `cat` to take.
            both("{ cat <&3; kill -TERM 0; } >/dev/null 2>&1 & exec 3<&-; wait $p; exit $?")
        }
        script = real.joined(separator: "\n") + "\n"
        shown = masked.joined(separator: "\n") + "\n"
        secrets = values.filter { secret.contains($0.name) }.map(\.value).filter { !$0.isEmpty }
        let q = ShellContext.quote
        command = switch sudo {
        case .none: "\(shell) -s"
        case .noPassword: "\(q(sudoProgram)) -n \(shell) -s"
        // stdin: the password, the marker, the payload. If sudo read the password, the first line is the marker;
        // if it read none (NOPASSWD), the second is. Without the marker nothing runs (exit 97): the password never
        // becomes a command (review §2.1).
        case .password: "\(q(sudoProgram)) -S -p '' -k \(shell) -c " + q("IFS= read -r l; [ \"$l\" = KERMO-\(nonce) ] || IFS= read -r l; "
                                                                       + "[ \"$l\" = KERMO-\(nonce) ] || exit 97; exec \(shell) -s")
        }
    }

    /// The sudo wrapper's exit when no marker came: sudo didn't take the password, and nothing ran.
    public static let sudoRefused: Int32 = 97

    public static func newNonce() -> String { (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

    /// What goes to the command's stdin: with the sudo wrapper, the password and the marker first.
    public func stdin(password: String? = nil) -> Data {
        Data(((sudo == .password ? (password ?? "") + "\nKERMO-\(nonce)\n" : "") + script).utf8)
    }

    /// `data`, text as it may be shown: secrets as `•••`.
    public func mask(_ data: Data) -> Data { secrets.isEmpty ? data : Data(mask(String(decoding: data, as: UTF8.self)).utf8) }

    /// `text` as it may be shown or logged: secrets and the sudo password as `•••`.
    public func mask(_ text: String, password: String? = nil) -> String {
        (secrets + [password].compactMap { $0 }.filter { !$0.isEmpty }).reduce(text) { $0.replacingOccurrences(of: $1, with: "•••") }
    }
}

/// A run's stdout as Kermo reads it: only after the start marker (`KERMO-<nonce> <epoch>`), and the empty line
/// right after it dropped (sudo-rs prints one after a password) — a `.bashrc` banner never reaches a parser. The
/// marker's epoch is the server's clock: `skew` is how far it is from this Mac's.
public struct ToolRunOutput: Sendable {
    public let nonce: String
    public private(set) var started = false
    /// The server's clock minus this Mac's, when the marker came (`ago` and `age` go by the server's).
    public private(set) var skew: TimeInterval?
    private var held = Data(), dropBlank = false

    public init(nonce: String) { self.nonce = nonce }

    /// The run's own part of `chunk`.
    public mutating func feed(_ chunk: Data, now: Date = Date()) -> Data {
        var data = chunk
        if !started {
            held += chunk
            let marker = Data("KERMO-\(nonce) ".utf8)
            var from = held.startIndex
            while let r = held[from...].firstRange(of: marker) {
                guard r.lowerBound == held.startIndex || held[r.lowerBound - 1] == 0x0A else { from = r.upperBound; continue }
                guard let nl = held[r.upperBound...].firstIndex(of: 0x0A) else { return Data() }   // the rest of its line is to come
                skew = Double(String(decoding: held[r.upperBound..<nl], as: UTF8.self)).map { $0 - now.timeIntervalSince1970 }
                started = true
                dropBlank = true
                data = Data(held[(nl + 1)...])
                held = Data()
                break
            }
            guard started else {
                if held.count > 1 << 20 { held = Data(held.suffix(4096)) }   // a banner that long: keep where a marker could start
                return Data()
            }
        }
        if dropBlank, let first = data.first {
            dropBlank = false
            if first == 0x0A { data = Data(data.dropFirst()) } else if first == 0x0D, data.dropFirst().first == 0x0A { data = Data(data.dropFirst(2)) }
        }
        return data
    }
}

extension ToolPayload {
    /// The payload of `run`, a Run of `tool`, with the names of `scope`: its command (a script's text from `scripts`),
    /// the tool's `env` and its own, `sudo` and `where` as the tool says unless the Run does. `secret`: the fields that
    /// are secret inputs. `password`: sudo will want one (the wrapper). Also the command with its values filled in,
    /// for reading ("Will run:"). Throws for a single-string command with an empty field. `sudoProgram`: tests' stand-in.
    public static func of(_ run: ToolRun, in tool: ToolPreset, scope: ToolTemplate.Scope, scripts: [String: String] = [:],
                          secret: Set<String> = [], text: String? = nil, password: Bool = false,
                          nonce: String = newNonce(), sudoProgram: String = "sudo") throws(ToolTemplate.Empty) -> (payload: ToolPayload, willRun: String) {
        var taken: [String: String] = [:]
        let body: ToolTemplate.Command
        if let c = run.command { body = try ToolTemplate.command(c, scope, vars: &taken) }
        else { body = ToolTemplate.Command(text: scripts[run.script ?? ""] ?? "", values: [], shown: "sh -s < \(run.script ?? "")") }
        var values = body.values
        let env = (tool.env ?? [:]).merging(run.env ?? [:]) { $1 }.sorted { $0.key < $1.key }.map { name, t -> (name: String, text: String) in
            let v = ToolTemplate.value(t, scope, vars: &taken)
            values += v.values.filter { !values.contains($0) }
            return (name, v.text)
        }
        let secretVars = Set(secret.compactMap { taken[$0] })
        let sudo: Sudo = (run.sudo ?? tool.sudo ?? false) ? (password ? .password : .noPassword) : .none
        let payload = ToolPayload(body: body.text, values: values, env: env, secret: secretVars, text: text, sudo: sudo,
                                  where: run.where ?? tool.where ?? .server, nonce: nonce, sudoProgram: sudoProgram)
        return (payload, payload.mask(body.shown))
    }
}

extension ToolPayload {
    /// A `terminal` run's command line for the login shell (§2): a terminal has no stdin of Kermo's, so no payload and no
    /// watcher — the tab's end is the run's. `sh -c` with each value set as a variable before the command (never text in
    /// it), the tool's `env`, sbin on the PATH; as root `sudo sh -c`, sudo asking in the terminal if it must. The
    /// locale and TERM stay the terminal's: what runs there is a program for a person. Also the command with its
    /// values, for reading.
    /// ponytail: quoted for sh; a fish or csh login shell may read `'\''` otherwise.
    public static func terminal(_ run: ToolRun, in tool: ToolPreset, scope: ToolTemplate.Scope, scripts: [String: String] = [:])
        throws(ToolTemplate.Empty) -> (line: String, willRun: String) {
        var taken: [String: String] = [:]
        let body: ToolTemplate.Command
        if let c = run.command { body = try ToolTemplate.command(c, scope, vars: &taken) }
        else { body = ToolTemplate.Command(text: scripts[run.script ?? ""] ?? "", values: [], shown: "sh -c < \(run.script ?? "")") }
        var lines = ["PATH=\"$PATH:/usr/local/sbin:/usr/sbin:/sbin\"; export PATH"] + body.values.map { "\($0.name)=\(ShellContext.quote($0.value))" }
        for (name, t) in (tool.env ?? [:]).merging(run.env ?? [:], uniquingKeysWith: { $1 }).sorted(by: { $0.key < $1.key }) {
            let v = ToolTemplate.value(t, scope, vars: &taken)
            lines += v.values.filter { !body.values.contains($0) }.map { "\($0.name)=\(ShellContext.quote($0.value))" } + ["export \(name)=\(v.text)"]
        }
        let sudo = (run.sudo ?? tool.sudo ?? false) && (run.where ?? tool.where) != .mac
        return ((sudo ? "sudo " : "") + "sh -c " + ShellContext.quote((lines + [body.text]).joined(separator: "\n")), body.shown)
    }
}

/// `strip: "cri"` (§6.1): a container runtime's log line, `<time> <stream> <tag> <message>`, as its message. Lines come
/// in pieces: an unfinished one waits for its end.
public struct ToolCRI: Sendable {
    private var rest = Data()
    public init() {}
    public mutating func feed(_ chunk: Data) -> Data {
        rest += chunk
        guard let last = rest.lastIndex(of: 0x0A) else { return Data() }
        let whole = rest[...last]
        rest = Data(rest[(last + 1)...])
        var out = Data()
        for line in whole.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
            let fields = line.split(separator: 0x20, maxSplits: 3, omittingEmptySubsequences: false)
            out += (fields.count == 4 && ["stdout", "stderr"].contains(String(decoding: fields[1], as: UTF8.self)) ? fields[3] : line) + [0x0A]
        }
        return out
    }
}
