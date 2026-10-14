import Foundation

/// One command on several servers at once (Run on Servers…), as F2 runs one on a server: no terminal, the server's
/// login shell parsing the command, one ssh each over its shared connection.
public enum MultiRun {
    public struct Server: Sendable {
        public var name: String
        public var target: SFTPTarget
        public init(name: String, target: SFTPTarget) { (self.name, self.target) = (name, target) }
    }

    /// How a server's run ended: its exit status; not run (no login, no connection — ssh's words are its last line);
    /// stopped (⎋); skipped (locked, Touch ID refused: the app's, never `run`'s).
    public enum Outcome: Sendable, Equatable { case exit(Int32), notRun(String), stopped, skipped }

    /// Runs `command` on each server, `limit` at a time. Logins (a master to start) go one at a time, so password
    /// dialogs come one after another; a server whose connection is up doesn't wait for them. `line`: each whole line
    /// as it comes — stdout's, or stderr's (`error`) — with its server's index, one call at a time: a line never mixes
    /// two servers' text, nor is cut by a read. `cancel` stops them all. Blocks; returns each one's outcome, in order.
    /// `login`: in place of the master's (tests), always called, one at a time.
    // ponytail: a login to a server that doesn't answer holds the others' logins up to ConnectTimeout (15 s).
    public static func run(_ servers: [Server], _ command: String, env: [String: String] = [:], limit: Int = 8, cancel: CancelFlag,
                           login: (@Sendable (SFTPTarget, CancelFlag) throws -> Void)? = nil,
                           line: @escaping @Sendable (_ server: Int, _ text: String, _ error: Bool) -> Void) -> [Outcome] {
        let lock = NSLock(), gate = NSLock(), say = NSLock()
        nonisolated(unsafe) var outcomes = [Outcome](repeating: .stopped, count: servers.count), next = 0
        let flags = servers.map { _ in CancelFlag() }   // one each: a flag holds one handler, and each run hooks its ssh in
        let previous = cancel.onCancel { flags.forEach { $0.cancel() } }
        defer { cancel.onCancel(previous) }
        let said: @Sendable (Int, String, Bool) -> Void = { i, text, error in say.withLock { line(i, text, error) } }

        func serve(_ i: Int) {
            let t = servers[i].target, flag = flags[i]
            let out = Lines { said(i, $0, false) }, err = Lines { text in
                if !text.contains("Warning: Permanently added") { said(i, text, true) }
            }
            do {
                if let login { try gate.withLock { if !flag.isCancelled { try login(t, flag) } } }
                else if !(t.localServer != nil || SFTP.isConnected(t)) {
                    try gate.withLock { if !flag.isCancelled { try SFTP.startMaster(t, env: env, cancel: flag) } }
                }
                guard !flag.isCancelled else { return }
                let (status, _) = try SSHCommand.run(t, command, env: env, cancel: flag, onErrors: { err.add($0) }) { out.add($0) }
                out.end()
                err.end()
                lock.withLock { outcomes[i] = .exit(status) }
            } catch is CancellationError {
                out.end()
                err.end()
            } catch {
                let why = error.localizedDescription
                said(i, why, true)
                lock.withLock { outcomes[i] = .notRun(why) }
            }
        }
        let done = DispatchGroup()
        for _ in 0..<min(max(limit, 1), servers.count) {   // each takes the next server once it's through with one
            done.enter()
            Thread {
                while let i = lock.withLock({ () -> Int? in
                    defer { next += 1 }
                    return next < servers.count ? next : nil
                }) { serve(i) }
                done.leave()
            }.start()
        }
        done.wait()
        return lock.withLock { outcomes }
    }

    /// "web1 │ ", the name padded to `width` so the lines of every server line up.
    public static func label(_ name: String, width: Int) -> String {
        name + String(repeating: " ", count: max(0, width - name.count)) + " │ "
    }

    /// "✓ 5  ✗ 1 (db2: exit 1)  🔒 1 skipped (vault)  ⎋ 2 stopped" — what's there of it.
    public static func summary(_ results: [(name: String, outcome: Outcome)]) -> String {
        var ok = 0, failed: [String] = [], skipped: [String] = [], stopped = 0
        for (name, outcome) in results {
            switch outcome {
            case .exit(0): ok += 1
            case .exit(let s): failed.append("\(name): exit \(s)")
            case .notRun: failed.append("\(name): not run")
            case .skipped: skipped.append(name)
            case .stopped: stopped += 1
            }
        }
        return [ok > 0 ? "✓ \(ok)" : nil,
                failed.isEmpty ? nil : "✗ \(failed.count) (\(failed.joined(separator: ", ")))",
                skipped.isEmpty ? nil : "🔒 \(skipped.count) skipped (\(skipped.joined(separator: ", ")))",
                stopped > 0 ? "⎋ \(stopped) stopped" : nil].compactMap { $0 }.joined(separator: "  ")
    }
}

/// A stream's whole lines, as they come: a line's end ("\n", a "\r" before it dropped) lets it go; `end` gives what's
/// left without one. From one thread at a time.
final class Lines: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let line: (String) -> Void
    init(_ line: @escaping (String) -> Void) { self.line = line }

    func add(_ data: Data) {
        let whole = lock.withLock { () -> [Data] in
            pending += data
            guard let last = pending.lastIndex(of: 0x0a) else { return [] }
            defer { pending = Data(pending[(last + 1)...]) }
            return pending[..<last].split(separator: 0x0a, omittingEmptySubsequences: false).map { Data($0) }
        }
        whole.forEach(say)
    }

    func end() {
        let rest = lock.withLock { () -> Data in
            defer { pending = Data() }
            return pending
        }
        if !rest.isEmpty { say(rest) }
    }

    private func say(_ d: Data) {
        var s = String(decoding: d, as: UTF8.self)
        if s.hasSuffix("\r") { s.removeLast() }
        line(s)
    }
}
