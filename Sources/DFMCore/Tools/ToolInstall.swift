import Foundation

/// Install and Uninstall (protocol §10.6): the preset's `install` or `uninstall` as an action Kermo makes for a server —
/// its package manager's command, or the vendor's script fetched and checked on this Mac — always `long` and always
/// asked, as root (Uninstall `dangerous` too); its `precheck` in one run before the question.
extension ToolInstall {
    /// The actions' ids: never a preset's (`[a-z0-9-]+`), so a job's `action` says it was Kermo's Install or Uninstall.
    public static let actionID = "kermo:install", uninstallID = "kermo:uninstall"

    /// The command for a server whose `pkg` fact (§10.2) is `pkg`: `apt-get` takes `apt`. nil: none there — `yum` too:
    /// the fact says yum only where there's no dnf, so a dnf command would fail there.
    public func command(pkg: String) -> String? {
        switch pkg {
        case "apt-get": apt
        case "dnf": dnf
        case "apk": apk
        case "pacman": pacman
        case "zypper": zypper
        case "brew": brew
        default: nil
        }
    }

    /// What Install runs on a server whose `pkg` fact is `pkg`: its package manager's command — as root, but brew's
    /// (brew won't run as root) — else the script, as root, `env` as variables: its text goes among the tool's scripts
    /// under its address (no preset's script has `/` in its name). nil: nothing for this system.
    public func run(pkg: String) -> ToolRun? {
        if let c = command(pkg: pkg) { return ToolRun(command: .one(c), sudo: pkg != "brew") }
        return script.map { ToolRun(script: $0.url, sudo: true, env: $0.env) }
    }

    /// Install… (Uninstall… for `uninstall`) on a server whose `pkg` fact is `pkg`: `long`, asked even off production
    /// (`confirm`) — Uninstall as `dangerous` — ending with `after`, or what `keeps`. nil: nothing for this system.
    public func action(pkg: String, title: String, uninstall: Bool = false) -> ToolAction? {
        guard let run = run(pkg: pkg) else { return nil }
        var spec = ToolAction.Spec(id: uninstall ? Self.uninstallID : Self.actionID)
        (spec.title, spec.long, spec.confirm, spec.output) = ((uninstall ? "Uninstall " : "Install ") + title + "…", true, true, .line)
        (spec.dangerous, spec.done) = uninstall ? (true, "removed" + (keeps.map { "; \($0) stay" } ?? "")) : (nil, after ?? "installed")
        return ToolAction(run: run, spec: spec)
    }

    /// The prechecks in one run as the login user (as `requires`, §10.5): each in a subshell of its own, its values
    /// set there, its output then `KERMO-<nonce>-PRE <n> <exit>`. nil: a field it names is empty. `shell`: the server's
    /// `sh` (tests run dash and bash).
    public func prechecks(_ scope: ToolTemplate.Scope, nonce: String = ToolPayload.newNonce(), shell: String = "sh") -> ToolPayload? {
        var body: [String] = []
        for (n, c) in (precheck ?? []).enumerated() {
            var taken: [String: String] = [:]
            guard let cmd = try? ToolTemplate.command(.one(c.command), scope, vars: &taken) else { return nil }
            let text = cmd.values.map { "\($0.name)=\(ShellContext.quote($0.value))\n" }.joined() + cmd.text
            body.append("o=$( (\n\(text)\n) 2>&1 </dev/null ); s=$?\nprintf '%s\\nKERMO-%s-PRE \(n) %s\\n' \"$o\" \(nonce) \"$s\"")
        }
        return ToolPayload(body: body.joined(separator: "\n"), values: [], nonce: nonce, shell: shell)
    }

    /// Why Install stops, from what `prechecks` printed: the first that failed, its `title` and what was found —
    /// "Podman 4.8 or newer is needed (found 4.3)". A precheck passes on exit 0, its `pattern` found in its output
    /// (group `v`, else the match) and that at least `min`. nil: all passed.
    public func refusal(prechecks out: String, nonce: String) -> String? {
        var said: [Int: (out: String, status: Int32)] = [:], text = ""
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let mark = "KERMO-\(nonce)-PRE "
            guard line.hasPrefix(mark) else { text += line + "\n"; continue }
            let f = line.dropFirst(mark.count).split(separator: " ")
            if f.count == 2, let n = Int(f[0]), let s = Int32(f[1]) { said[n] = (text, s) }
            text = ""
        }
        for (n, c) in (precheck ?? []).enumerated() {
            guard let (o, s) = said[n] else { return "\(c.title): its check didn't run" }
            let first = o.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) }
            guard s == 0 else { return "\(c.title) is needed" + (first.map { " (\($0))" } ?? "") }
            guard let p = c.pattern else { continue }
            guard let re = try? Regex(p), let m = o.firstMatch(of: re) else { return "\(c.title) is needed (not found)" }
            let v = String(m.output["v"]?.substring ?? m.output[0].substring ?? "")
            if let min = c.min, ToolVersion(command: "", pattern: "", tested: ">=" + min).tested(v) == false { return "\(c.title) is needed (found \(v))" }
        }
        return nil
    }

    /// For people (the trust sheet, the tool's page): what it installs with, by system — the script's address, its
    /// values and the start of its sha256.
    public var lines: [ToolRuns.Line] {
        let commands: [(String, String?)] = [("apt", apt), ("dnf", dnf), ("apk", apk), ("pacman", pacman), ("zypper", zypper), ("brew", brew)]
        var lines = commands.compactMap { name, c in c.map { ToolRuns.Line(what: name, how: $0, root: name != "brew") } }
        if let s = script {
            lines.append(ToolRuns.Line(what: "script", how: s.said + (s.sha256.map { " (sha256 \($0.prefix(12))…)" } ?? " (no sha256: not run)"), root: true))
        }
        if let stays = leaves?.said { lines.append(ToolRuns.Line(what: "stays on the server", how: stays)) }
        if let k = keeps { lines.append(ToolRuns.Line(what: "stays after it", how: k)) }
        return lines
    }
}

extension ToolInstall.Script {
    /// "https://dpl.cesbo.com/install.sh DPL_VERSION=0.7.1": its address and its values, as people read them.
    public var said: String { ([url] + (env ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: " ") }
}

extension ToolInstall.Leaves {
    /// "services dpl; /usr/local/bin/dpl, {base}; ports 80, 443": what stays after Install. nil: nothing said.
    public var said: String? {
        let stays = [services.map { "services " + $0.joined(separator: ", ") }, paths.map { $0.joined(separator: ", ") },
                     ports.map { "ports " + $0.map(String.init).joined(separator: ", ") }, note].compactMap { $0 }
        return stays.isEmpty ? nil : stays.joined(separator: "; ")
    }
}

extension ToolLong {
    /// Clean Up Kermo Files (§10.6): `~/.cache/kermo`'s size (`kermo-size <KB>`, nothing where there's none) and how many
    /// jobs still run from it (`kermo-running <n>`); with `remove`, the folder gone — not while a job runs there (exit 3:
    /// its log and uploads are in it).
    public static func cleanUp(remove: Bool, shell: String = "sh") -> ToolPayload {
        let body = """
            d="$HOME/.cache/kermo"; r=0
            for p in "$d"/runs/*.pid; do
              [ -f "$p" ] && [ ! -f "${p%.pid}.exit" ] && kill -0 "$(cat "$p")" 2>/dev/null && r=$((r + 1))
            done
            printf 'kermo-size %s\\nkermo-running %s\\n' "$(du -sk "$d" 2>/dev/null | cut -f1)" "$r"
            """ + (remove ? "\n[ \"$r\" -eq 0 ] || exit 3\nrm -rf \"$d\"" : "")
        return ToolPayload(body: body, values: [], shell: shell)
    }

    /// What `cleanUp` said: the folder's size in bytes (nil: there's none) and the jobs running from it.
    public static func cleanUpSaid(_ out: String) -> (bytes: Int?, running: Int) {
        var bytes: Int?, running = 0
        for line in out.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("kermo-size ") { bytes = Int(line.dropFirst("kermo-size ".count)).map { $0 * 1024 } }
            if line.hasPrefix("kermo-running ") { running = Int(line.dropFirst("kermo-running ".count)) ?? 0 }
        }
        return (bytes, running)
    }
}
