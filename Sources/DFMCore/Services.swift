import Foundation

/// A systemd service of a server, as `systemctl list-units --type=service --all` says it: what Services… lists.
public struct ServiceUnit: Equatable, Sendable, Decodable {
    public var unit: String, load: String, active: String, sub: String, description: String

    public init(unit: String, load: String = "loaded", active: String, sub: String, description: String = "") {
        (self.unit, self.load, self.active, self.sub, self.description) = (unit, load, active, sub, description)
    }

    /// "nginx" for nginx.service.
    public var name: String { unit.hasSuffix(".service") ? String(unit.dropLast(".service".count)) : unit }
    public var failed: Bool { active == "failed" }
    /// Kermo puts it into a command (quoted): only a name made of what systemd allows in one — letters, digits and
    /// `:_.@\-` (its escapes are `\x2d`) — not starting with `-`, ending in `.service`. Anything else is shown only.
    public var safe: Bool { unit.hasSuffix(".service") && Services.safeName(unit, more: ":_.@\\-") }
}

/// The server's services: one ssh command over its connection, the user's own (`systemctl` lists them for anyone).
public enum Services {
    /// `name` is all ASCII letters and digits and `more`, not empty, and starts with a letter or digit (never an option).
    static func safeName(_ name: String, more: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII, CharacterSet.alphanumerics.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || more.unicodeScalars.contains($0)) }
    }

    /// In `sh` (the login shell may be any): JSON where systemd has it (230 and later) — an older one ignores
    /// `--output=json` and prints its table, which then goes plain — each said by a line first (a login script may
    /// print before it).
    static let script = "LC_ALL=C; export LC_ALL; command -v systemctl >/dev/null 2>&1 || { echo kermo-none; exit 0; }; "
        + "j=$(systemctl list-units --type=service --all --output=json --no-pager 2>/dev/null); "
        + "case $j in '['*) echo kermo-json; printf '%s\\n' \"$j\";; "
        + "*) echo kermo-plain; exec systemctl list-units --type=service --all --plain --no-legend --no-pager;; esac"

    /// The services of `t`'s server, those systemd has a unit for (`--all` adds the ones only named somewhere,
    /// `not-found`): failed first, then by name. Throws a failed login as ssh said it, and in plain words a server
    /// without systemd, or one whose systemctl failed.
    public static func read(on t: SFTPTarget, server: String, env: [String: String] = [:], cancel: CancelFlag? = nil) throws -> [ServiceUnit] {
        var out = Data()
        let (status, errors) = try SSHCommand.run(t, "sh -c " + ShellContext.quote(script), env: env, cancel: cancel, options: ["-x", "-a"]) { out += $0 }
        return try outcome(status: status, output: String(decoding: out, as: UTF8.self), errors: errors, server: server).get()
    }

    static func outcome(status: Int32, output: String, errors: String, server: String) -> Result<[ServiceUnit], SFTPError> {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let at = lines.firstIndex(where: { ["kermo-json", "kermo-plain", "kermo-none"].contains($0) }) else {
            return .failure(SFTPError(message: errors.isEmpty ? "Couldn't look at the services of \(server) (exit \(status))" : errors))
        }
        if lines[at] == "kermo-none" { return .failure(SFTPError(message: "\(server) has no systemd (no systemctl there)")) }
        guard status == 0 else { return .failure(SFTPError(message: "systemctl failed on \(server): " + (errors.isEmpty ? "exit \(status)" : errors))) }
        let rest = lines[(at + 1)...].joined(separator: "\n")
        let units = lines[at] == "kermo-json" ? parse(json: rest) : parse(plain: rest)
        guard let units else { return .failure(SFTPError(message: "systemctl on \(server) said something Kermo can't read")) }
        return .success(sorted(units.filter { $0.load != "not-found" }))
    }

    /// `--output=json`: an array of {unit, load, active, sub, job, description}.
    static func parse(json: String) -> [ServiceUnit]? { try? JSONDecoder().decode([ServiceUnit].self, from: Data(json.utf8)) }

    /// `--plain --no-legend`: unit, load, active and sub, then the description, spaces between.
    static func parse(plain: String) -> [ServiceUnit] {
        plain.split(whereSeparator: \.isNewline).compactMap { line in
            var words = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true).map(String.init)
            if words.first == "●" || words.first == "*" {   // a failed unit's mark, where --plain leaves it
                words = line.drop { $0 == " " }.dropFirst().split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true).map(String.init)
            }
            guard words.count >= 4 else { return nil }
            return ServiceUnit(unit: words[0], load: words[1], active: words[2], sub: words[3],
                               description: words.count > 4 ? words[4].trimmingCharacters(in: .whitespaces) : "")
        }
    }

    /// Failed first (what one looks for), then by name.
    public static func sorted(_ units: [ServiceUnit]) -> [ServiceUnit] {
        units.sorted { a, b in a.failed != b.failed ? a.failed : a.name.lowercased() < b.name.lowercased() }
    }

    // What runs on a unit (`safe` only: its name goes in quoted, and never where an option could be).
    public static func status(_ u: ServiceUnit) -> String { "systemctl status --no-pager -- " + ShellContext.quote(u.unit) }
    public static func log(_ u: ServiceUnit) -> String { "journalctl -u " + ShellContext.quote(u.unit) + " -n 200 -f --no-pager" }
    public static func restart(_ u: ServiceUnit) -> String { "systemctl restart -- " + ShellContext.quote(u.unit) }

    /// The unit's file on the server (its `FragmentPath`); nil where systemd made it up (a generated unit has none).
    public static func unitFile(_ u: ServiceUnit, on t: SFTPTarget, env: [String: String] = [:], cancel: CancelFlag? = nil) throws -> String? {
        let path = try SSHCommand.capture(t, "systemctl show -p FragmentPath --value -- " + ShellContext.quote(u.unit), env: env, cancel: cancel)
            .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return path.hasPrefix("/") ? path : nil
    }
}

/// A container of a server, as `docker ps -a` (or `podman ps -a`) says it: what Containers… lists.
public struct ContainerInfo: Equatable, Sendable {
    public var name: String, state: String, status: String, image: String

    public init(name: String, state: String, status: String, image: String) {
        (self.name, self.state, self.status, self.image) = (name, state, status, image)
    }

    public var running: Bool { state == "running" }
    /// Kermo puts it into a command (quoted): only a name docker allows, `[A-Za-z0-9][A-Za-z0-9_.-]*`.
    public var safe: Bool { Services.safeName(name, more: "_.-") }
}

public enum Containers {
    /// docker if there is one, else podman — said by a line first. A template, not `{{json .}}`: podman's `Names` is an
    /// array there, docker's a string. No `{{.State}}`: docker before 20.10 has none (`state(of:)` reads the status).
    static let script = "LC_ALL=C; export LC_ALL; f='{{.Names}}\\t{{.Status}}\\t{{.Image}}'; "
        + "if command -v docker >/dev/null 2>&1; then echo kermo-docker; exec docker ps -a --format \"$f\"; "
        + "elif command -v podman >/dev/null 2>&1; then echo kermo-podman; exec podman ps -a --format \"$f\"; else echo kermo-none; fi"

    /// The containers of `t`'s server — those its user may see (rootless podman: the user's own) — running first, then
    /// by name, and which tool listed them (what then runs on them).
    public static func read(on t: SFTPTarget, server: String, env: [String: String] = [:], cancel: CancelFlag? = nil) throws -> (tool: String, containers: [ContainerInfo]) {
        var out = Data()
        let (status, errors) = try SSHCommand.run(t, "sh -c " + ShellContext.quote(script), env: env, cancel: cancel, options: ["-x", "-a"]) { out += $0 }
        return try outcome(status: status, output: String(decoding: out, as: UTF8.self), errors: errors, server: server).get()
    }

    static func outcome(status: Int32, output: String, errors: String, server: String) -> Result<(tool: String, containers: [ContainerInfo]), SFTPError> {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let at = lines.firstIndex(where: { ["kermo-docker", "kermo-podman", "kermo-none"].contains($0) }) else {
            return .failure(SFTPError(message: errors.isEmpty ? "Couldn't look at the containers of \(server) (exit \(status))" : errors))
        }
        let tool = String(lines[at].dropFirst("kermo-".count))
        if tool == "none" { return .failure(SFTPError(message: "\(server) has neither docker nor podman")) }
        guard status == 0 else { return .failure(SFTPError(message: "\(tool) failed on \(server): " + (errors.isEmpty ? "exit \(status)" : errors))) }
        let all = lines[(at + 1)...].compactMap { line -> ContainerInfo? in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return f.count >= 3 ? ContainerInfo(name: f[0], state: state(of: f[1]), status: f[1], image: f[2...].joined(separator: "\t")) : nil
        }
        return .success((tool, all.sorted { a, b in a.running != b.running ? a.running : a.name.lowercased() < b.name.lowercased() }))
    }

    /// The state docker's and podman's status says: "Up 3 hours" running, "Up 2 days (Paused)" paused, "Exited (0) …"
    /// exited, "Created" created…
    static func state(of status: String) -> String {
        if status.hasPrefix("Up ") || status == "Up" { return status.hasSuffix("(Paused)") ? "paused" : "running" }
        return status.split(separator: " ").first.map { $0.lowercased() } ?? ""
    }

    // What runs on one (`safe` only).
    public static func logs(_ c: ContainerInfo, tool: String) -> String { "\(tool) logs --tail 200 -f -- " + ShellContext.quote(c.name) }
    public static func restart(_ c: ContainerInfo, tool: String) -> String { "\(tool) restart -- " + ShellContext.quote(c.name) }
}

extension SSHCommand {
    /// `command` — one simple command, a follow (`journalctl -f`, `docker logs -f`) — so that it ends with this Mac's ssh: without a terminal
    /// sshd sends it no signal, and one that prints nothing for hours would run on. ssh's stdin, held open here and
    /// never written, reaches a watcher there; once ssh is gone it's at its end, and the watcher stops the command. Not a
    /// newline on stderr each second, as folder sizes' du has: an output window would show those. In `sh`: the login
    /// shell may be any. The exit status is the command's.
    public static func endsWithSSH(_ command: String) -> String {
        // An `&` command reads /dev/null: the watcher gets ssh's stdin through fd 3, and its own output goes nowhere,
        // so it never holds the channel open after the command's end.
        "sh -c " + ShellContext.quote("exec 3<&0; " + command + " & p=$!; { cat <&3; kill $p; } >/dev/null 2>&1 & exec 3<&-; wait $p")
    }
}
