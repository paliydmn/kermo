import Foundation
import os

/// One Tools run of mode once (protocol §2, §3.2): its payload over the server's connection — or this Mac's `sh` for
/// `where: mac` (`SFTPTarget.local()`) — stdin held open while it runs, stdout read after the start marker. It's
/// stopped past `timeout` or 16 MB of output; a line keeps its first 1 MB. sudo: `sudo -n` first; only where that
/// refused for want of a password, the wrapper with the password (kept, Keychain or asked) — three tries, as sudo's
/// own, one server's dialog at a time.
public enum ToolExec {
    public struct Ran: Sendable {
        public var status: Int32 = 0
        /// stdout after the marker.
        public var out = Data()
        public var errors = ""
        /// The marker came: the payload ran, whatever its exit.
        public var started = false
        /// The server's clock minus this Mac's (`ToolRunOutput.skew`).
        public var skew: TimeInterval?
        /// Why it was stopped before its end: "it took over 30 s", "over 16 MB of output".
        public var stopped: String?
        /// The sudo password it ran with: masked in all that's shown and logged.
        public var password: String?
        public var text: String { String(decoding: out, as: UTF8.self) }
        public init() {}
    }

    /// The sudo password wasn't given (the dialog's Cancel): nothing ran.
    public struct NoPassword: LocalizedError {
        public var errorDescription: String? { "no sudo password" }
    }

    public static let maxOutput = 16 << 20, maxLine = 1 << 20

    /// Servers whose `sudo -n` wanted a password this session: their runs go to the wrapper at once, one round trip
    /// instead of two (the wrapper runs with NOPASSWD too, should sudoers change).
    private static let wantPassword = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private static func key(_ t: SFTPTarget) -> String { "\(t.host):\(t.port ?? 22)" }
    /// Tests: `t`'s sudo asked afresh.
    static func forget(_ t: SFTPTarget) { _ = wantPassword.withLock { $0.remove(key(t)) } }
    /// Whether `t`'s sudo wanted a password this session (a `follow` run starts with the wrapper then).
    public static func wantsPassword(_ t: SFTPTarget) -> Bool { wantPassword.withLock { $0.contains(key(t)) } }
    /// `t`'s sudo wanted a password (a long job's start found it).
    static func remember(wantsPassword t: SFTPTarget) { _ = wantPassword.withLock { $0.insert(key(t)) } }

    // MARK: Channels

    /// Sessions Tools may hold at once on one server's connection (§2): OpenSSH allows 10 (MaxSessions), and past them
    /// ssh quietly opens a connection of its own — a new login. One more waits for a free one; `waiting` hears when a
    /// wait starts (true) and ends (false).
    /// ponytail: counts Tools' runs only — Services…, SFTP panels and terminals ride the same connection uncounted; a
    /// count kept in SFTP would see them all.
    nonisolated(unsafe) public static var channels = 9
    nonisolated(unsafe) public static var waiting: (@Sendable (SFTPTarget, Bool) -> Void)?
    private static let slots = NSCondition()
    nonisolated(unsafe) private static var inUse: [String: Int] = [:]

    /// A `files` list read over SFTP (§3.1), in one session that counts as a channel: as root where the tool runs as
    /// root — dpl's `deploy.json` is 0600 — through the server's sudo, as a root panel's. A file or folder that can't be
    /// read throws with its path; one that isn't there is left out. `kept`: watching's session, kept from one read to
    /// the next (its target is the session's: as root or not).
    public static func files(_ list: ToolList, of p: ToolPreset, _ scope: ToolTemplate.Scope, on t: SFTPTarget, env: [String: String],
                             cancel: CancelFlag, kept: KeptSession? = nil) throws -> ToolRecords {
        func gone<T>(_ path: String, _ body: () throws -> T) throws -> T? {
            do {
                return try body()
            } catch let e as SFTPError where e.code == SFTPClient.NO_SUCH_FILE {
                return nil
            } catch let e as SFTPError where e.code != nil {   // a refusal, said with its path (not a lost connection)
                throw SFTPError(message: "\(path): \(e.message)", code: e.code)
            }
        }
        return try channel(t.asRoot(false), cancel: cancel) {
            try SFTP.session(t.asRoot(list.run.sudo ?? p.sudo ?? false), env: env, cancel: cancel, on: kept) { c in
                try list.records(scope, list: { dir in try gone(dir) { try c.list(dir).map { ($0.name, $0.attrs.kind) } } },
                                 read: { path in try gone(path) { try c.read(path, max: 1 << 20) } })   // ponytail: a file's first MB — state files are small
            }
        }
    }

    /// `work` on one of `t`'s channels, once one is free; ⎋ (`cancel`) while waiting throws. `limit`: tests' own.
    public static func channel<T>(_ t: SFTPTarget, limit: Int = channels, cancel: CancelFlag, _ work: () throws -> T) throws -> T {
        let k = key(t)
        var waited = false
        slots.lock()
        while inUse[k, default: 0] >= limit {
            if !waited {
                waited = true
                slots.unlock()
                waiting?(t, true)
                slots.lock()
                continue
            }
            if cancel.isCancelled { slots.unlock(); throw CancellationError() }
            slots.wait(until: Date().addingTimeInterval(0.2))
        }
        inUse[k, default: 0] += 1
        slots.unlock()
        if waited { waiting?(t, false) }
        defer {
            slots.lock()
            inUse[k, default: 1] -= 1
            slots.broadcast()
            slots.unlock()
        }
        return try work()
    }

    /// `payload(password)`: the payload, the sudo wrapper's when `password`. `cancel`: ⎋. `command`: what runs it
    /// (tests: in a session of its own).
    public static func run(_ payload: (_ password: Bool) -> ToolPayload, on t: SFTPTarget, timeout: Double, cancel: CancelFlag,
                           env: [String: String] = [:], command: @escaping (ToolPayload) -> String = { $0.command }) throws -> Ran {
        let first = payload(false)
        if first.sudo != .noPassword || !wantPassword.withLock({ $0.contains(key(t)) }) {
            let r = try once(first, on: t, password: nil, timeout: timeout, cancel: cancel, env: env, command: command)
            guard first.sudo == .noPassword, !r.started, r.stopped == nil, SudoServer.passwordTexts.contains(where: r.errors.contains) else { return r }
            wantPassword.withLock { _ = $0.insert(key(t)) }
        }
        let p = payload(true)
        return try SudoServer.asking.withLock {
            var wrong = false, said = ""
            for _ in 0..<3 {
                if cancel.isCancelled { throw CancellationError() }
                guard let password = SFTP.sudoPassword?(t, wrong) else { throw NoPassword() }
                guard !password.contains(where: \.isNewline) else { wrong = true; continue }   // sudo reads one line
                var r = try once(p, on: t, password: password, timeout: timeout, cancel: cancel, env: env, command: command)
                r.password = password
                if r.started {
                    SFTP.sudoPasswordTaken?(t, password)
                    return r
                }
                if r.stopped != nil { return r }
                if r.errors.contains("invalid option") { throw SudoServer.noStdinPassword(t, path: nil) }   // sudo-rs before 0.2.13: no -p
                // It took the password but won't run a shell for this user: asking again won't help.
                if SudoServer.notAllowedTexts.contains(where: r.errors.contains) { throw SFTPError(message: "sudo on \(t.host) refused: " + r.errors) }
                (wrong, said) = (true, r.errors)   // no marker (exit 97), or sudo's own "try again"
            }
            throw SFTPError(message: "sudo on \(t.host) refused the password 3 times" + (said.isEmpty ? "." : ": " + said))
        }
    }

    static func once(_ p: ToolPayload, on t: SFTPTarget, password: String?, timeout: Double, cancel: CancelFlag,
                     env: [String: String], command: (ToolPayload) -> String) throws -> Ran {
        var ran = Ran(), reader = ToolRunOutput(nonce: p.nonce)
        let run = CancelFlag(), stopped = OSAllocatedUnfairLock<String?>(initialState: nil)
        let previous = cancel.onCancel { run.cancel() }
        defer { _ = cancel.onCancel(previous) }
        let timer = DispatchWorkItem {
            stopped.withLock { $0 = $0 ?? "it took over \(Int(timeout)) s" }
            run.cancel()
        }
        Timeouts.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        do {
            (ran.status, ran.errors) = try channel(t, cancel: run) {
                try SSHCommand.run(t, command(p), env: env, cancel: run, stdin: p.stdin(password: password), holdStdin: CancelFlag()) { chunk in
                    ran.out += reader.feed(chunk)
                    if ran.out.count > maxOutput {
                        stopped.withLock { $0 = $0 ?? "over 16 MB of output" }
                        run.cancel()
                    }
                }
            }
        } catch is CancellationError {
            guard let why = stopped.withLock({ $0 }), !cancel.isCancelled else { throw CancellationError() }
            ran.stopped = why
        }
        (ran.started, ran.skew) = (reader.started, reader.skew)
        ran.out = lines(ran.out)
        ran.errors = p.mask(ran.errors, password: password)
        return ran
    }

    /// Each line at most `maxLine` bytes: the rest of a longer one goes.
    static func lines(_ d: Data) -> Data {
        guard d.count > maxLine else { return d }
        var out = Data(), at = d.startIndex
        while at < d.endIndex {
            let nl = d[at...].firstIndex(of: 0x0A) ?? d.endIndex
            out += d[at..<min(nl, at + maxLine)]
            if nl < d.endIndex { out.append(0x0A) }
            at = nl < d.endIndex ? nl + 1 : nl
        }
        return out
    }

    /// Exit 127 or 126 in words (§10.4), naming the program from what the shell said — every shell has these codes,
    /// each its own words: "apt-get isn't on web-01 (Fedora 44 · dnf)". nil for any other exit.
    public static func notHere(_ r: Ran, server: String, facts: ToolFacts?) -> String? {
        guard r.status == 127 || r.status == 126 else { return nil }
        let said = r.status == 127 ? "(?:command )?not found" : "[Pp]ermission denied"
        let program = (try? Regex("([^\\s:]+): \(said)")).flatMap { r.errors.firstMatch(of: $0)?.output[1].substring }.map(String.init) ?? "a command"
        if r.status == 126 { return "\(program) can't be run on \(server): permission" }
        let system = facts?.said ?? ""
        return "\(program) isn't on \(server)" + (system.isEmpty ? "" : " (\(system))")
    }
}

extension ToolFacts {
    /// The server's system for people: "Fedora 44 · dnf".
    public var said: String {
        [os.isEmpty ? "" : os.prefix(1).uppercased() + os.dropFirst() + (osVersion.isEmpty ? "" : " " + osVersion), pkg == "none" ? "" : pkg]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension ToolVersion {
    /// The program's version in `version.command`'s output: the pattern's group `v`.
    public func found(in out: String) -> String? {
        guard let r = try? Regex(pattern), let m = out.firstMatch(of: r) else { return nil }
        return m.output["v"]?.substring.map(String.init)
    }

    /// Whether `v` is within `tested` (">=0.6 <0.7"; each part an operator and a version, compared number by number).
    /// nil: nothing to say — no `tested`, or `v` is one of `unknown` (a build whose number says nothing).
    public func tested(_ v: String) -> Bool? {
        guard let tested, !(unknown ?? []).contains(v) else { return nil }
        func parts(_ s: Substring) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        func compare(_ a: [Int], _ b: [Int]) -> Int {
            for i in 0..<max(a.count, b.count) where (a.indices.contains(i) ? a[i] : 0) != (b.indices.contains(i) ? b[i] : 0) {
                return (a.indices.contains(i) ? a[i] : 0) < (b.indices.contains(i) ? b[i] : 0) ? -1 : 1
            }
            return 0
        }
        return tested.split(separator: " ").allSatisfy { rule in
            let op = rule.prefix { "<>=".contains($0) }, c = compare(parts(Substring(v)), parts(rule.dropFirst(op.count)))
            switch op {
            case ">=": return c >= 0
            case ">": return c > 0
            case "<=": return c <= 0
            case "<": return c < 0
            default: return c == 0
            }
        }
    }
}
