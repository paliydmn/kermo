import Foundation

/// What Kermo learns about a server once per connection (protocol §10.2), in the same round trip as `requires`.
public struct ToolFacts: Sendable, Hashable, Codable {
    public var os = "", osLike = "", osVersion = "", pkg = "", initSystem = "", userland = "", arch = ""

    public init() {}

    /// Prints `kermo-fact NAME=value` lines, in POSIX sh (busybox, BSD, macOS included).
    public static let script = #"""
        if [ -r /etc/os-release ]; then
          for k in ID ID_LIKE VERSION_ID; do printf 'kermo-fact %s=%s\n' "$k" "$(sed -n "s/^$k=//p" /etc/os-release | head -n 1 | tr -d "\"'")"; done
        else
          printf 'kermo-fact ID=%s\nkermo-fact VERSION_ID=%s\n' "$(uname -s | tr A-Z a-z)" "$(sw_vers -productVersion 2>/dev/null || uname -r)"
        fi
        p=none; for c in apt-get dnf yum apk pacman zypper brew; do if command -v $c >/dev/null 2>&1; then p=$c; break; fi; done
        if [ -d /run/systemd/system ]; then i=systemd; elif [ -d /run/openrc ] || command -v openrc >/dev/null 2>&1; then i=openrc; else i=none; fi
        if ls --version 2>/dev/null | grep -qE 'GNU|uutils'; then u=gnu; elif ls --help 2>&1 | grep -qi busybox; then u=busybox; else u=other; fi
        printf 'kermo-fact pkg=%s\nkermo-fact init=%s\nkermo-fact userland=%s\nkermo-fact arch=%s\n' "$p" "$i" "$u" "$(uname -m)"
        """#

    /// The facts in `script`'s output. A value is the server's data: one line, printable, at most 64 characters.
    public static func read(_ out: String) -> ToolFacts {
        var f = ToolFacts()
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("kermo-fact ") {
            let pair = line.dropFirst("kermo-fact ".count)
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let value = String(String.UnicodeScalarView(pair[pair.index(after: eq)...].unicodeScalars
                .filter { $0.properties.generalCategory != .control }.prefix(64)))
            switch pair[..<eq] {
            case "ID": f.os = value
            case "ID_LIKE": f.osLike = value
            case "VERSION_ID": f.osVersion = value
            case "pkg": f.pkg = value
            case "init": f.initSystem = value
            case "userland": f.userland = value
            case "arch": f.arch = value
            default: break
            }
        }
        return f
    }

    /// Whether the server is `name` or like it: a preset for `debian` shows on Mint (ID_LIKE "ubuntu debian").
    public func isOS(_ name: String) -> Bool { os == name || osLike.split(separator: " ").contains { $0 == name } }

    /// Kermo's own names for templates (§5.3).
    public var names: [String: ToolValue] {
        ["os": .string(os), "os_version": .string(osVersion), "pkg": .string(pkg), "init": .string(initSystem), "arch": .string(arch)]
    }
}

/// `requires` of every tool and action a server could show, and its facts, in one run over a connection that's
/// already up (§10.5). Only trusted tools are asked: an untrusted one runs nothing.
public enum ToolBatch {
    /// A `requires` to ask: a tool's (`action` nil) or an action's.
    public struct Item: Sendable, Hashable {
        public var tool: String
        public var action: String?
        public var run: ToolRun
        /// "ufw", or "dpl/deploy" for an action.
        public var name: String { action.map { "\(tool)/\($0)" } ?? tool }
    }

    /// What a server said: its facts, and the tools and actions whose `requires` passed.
    public struct Answer: Sendable, Hashable {
        public var facts: ToolFacts
        public var passed: Set<String>
        /// The tools it was asked about (nil: not known — an answer kept before Kermo noted it).
        public var asked: Set<String>?
        public init(facts: ToolFacts, passed: Set<String>, asked: Set<String>? = nil) { (self.facts, self.passed, self.asked) = (facts, passed, asked) }

        /// A tool without `requires` is everywhere.
        public func has(_ tool: ToolPreset) -> Bool { tool.requires == nil || passed.contains(tool.id) }
        /// Whether this answer says anything of `tool`: one trusted since wasn't asked about yet.
        public func checked(_ tool: ToolPreset) -> Bool { tool.requires == nil || asked?.contains(tool.id) != false }
        public func has(_ action: ToolAction, of tool: ToolPreset) -> Bool {
            action.spec.requires == nil || passed.contains("\(tool.id)/\(action.spec.id)")
        }

        /// The actions shown on this server, in order: those whose `requires` passed, and of same-key variants only the
        /// first that did (§10.3).
        public func visible(_ actions: [ToolAction], of tool: ToolPreset) -> [ToolAction] {
            var keys = Set<String>()
            return actions.filter { a in has(a, of: tool) && (a.spec.key.map { keys.insert($0).inserted } ?? true) }
        }
    }

    public static func items(_ tools: [ToolPreset]) -> [Item] {
        tools.flatMap { t in
            [t.requires.map { Item(tool: t.id, action: nil, run: $0) }].compactMap { $0 }
                + t.allActions.compactMap { a in a.action.spec.requires.map { Item(tool: t.id, action: a.action.spec.id, run: $0) } }
        }
    }

    /// One payload: the facts, then each `requires` in a subshell of its own (its values set there), as the login user
    /// — a `sudo: true` on the requires itself through `sudo -n`. Its line says `kermo-ok <n>` when it passed: the
    /// index, never a name from a file. `scope` gives each tool's names (its vars, Kermo's); `scripts` its scripts' text.
    public static func payload(_ items: [Item], scope: (String) -> ToolTemplate.Scope, scripts: (String) -> [String: String],
                               nonce: String = ToolPayload.newNonce()) -> ToolPayload {
        var body = ToolFacts.script
        for (n, item) in items.enumerated() {
            var taken: [String: String] = [:]
            let text: String
            if let c = item.run.command {
                guard let cmd = try? ToolTemplate.command(c, scope(item.tool), vars: &taken) else { continue }   // an empty field: not here
                text = cmd.values.map { "\($0.name)=\(ShellContext.quote($0.value))\n" }.joined() + cmd.text
            } else if let s = item.run.script, let t = scripts(item.tool)[s] { text = t } else { continue }
            let run = item.run.sudo == true ? "sudo -n sh -c \(ShellContext.quote(text))" : "(\n\(text)\n)"
            body += "\n\(run) >/dev/null 2>&1 </dev/null && echo 'kermo-ok \(n)'"
        }
        return ToolPayload(body: body, values: [], nonce: nonce)
    }

    public static func read(_ out: String, _ items: [Item]) -> Answer {
        var passed = Set<String>()
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("kermo-ok ") {
            if let n = Int(line.dropFirst("kermo-ok ".count)), items.indices.contains(n) { passed.insert(items[n].name) }
        }
        return Answer(facts: ToolFacts.read(out), passed: passed, asked: Set(items.map(\.tool)))
    }

    /// Asks `t`'s server — only over its live connection: none (`hasMaster`), and the answer is nil ("Connect to see
    /// tools"); nil too if it fails or takes over 10 s. `command`: what runs the payload (tests: a local shell).
    /// ponytail: a master that dies between the check and the run makes ssh log in again; the answers are kept per
    /// server (PR 2), so this asks seldom.
    public static func ask(_ t: SFTPTarget, _ items: [Item], scope: (String) -> ToolTemplate.Scope, scripts: (String) -> [String: String],
                           hasMaster: (SFTPTarget) -> Bool = live, command: (ToolPayload) -> String = { $0.command }) -> Answer? {
        guard hasMaster(t) else { return nil }
        let p = payload(items, scope: scope, scripts: scripts)
        let flag = CancelFlag(), hold = CancelFlag()
        Timeouts.queue.asyncAfter(deadline: .now() + 10) { flag.cancel() }
        var reader = ToolRunOutput(nonce: p.nonce), out = Data()
        guard (try? ToolExec.channel(t, cancel: flag) { try SSHCommand.run(t, command(p), cancel: flag, stdin: p.stdin(), holdStdin: hold) { out += reader.feed($0) } }) != nil,
              reader.started else { return nil }
        return read(String(decoding: out, as: UTF8.self), items)
    }

    /// A master this app started and that still answers (`ssh -O check`, on this Mac only).
    public static func live(_ t: SFTPTarget) -> Bool {
        SFTP.masterTargets.contains { $0.isSameServer(as: t) } && SFTP.isConnected(t)
    }
}
