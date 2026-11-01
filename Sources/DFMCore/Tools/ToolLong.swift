import Foundation

/// A long job (protocol §7.6): started detached on the server as the login user — a session of its own (`setsid`; perl's
/// or python's where there's none: a macOS server, a small busybox), `sudo` only around the command — its output in
/// `~/.cache/kermo/runs/<id>.log`, its exit in `<id>.exit`, its process group in `<id>.pid`; the folder 0700, a job's
/// files gone a week after it ended, at the next start there (Q10); what was uploaded for it, as its command ends. It runs on without Kermo: the start comes back at
/// once with its pid, a follow reads its log from where Kermo left it till the exit comes, Stop… kills its group.
/// The sudo password goes into the script as a secret does (a heredoc a builtin reads) and on to sudo through a pipe —
/// never argv, the environment or a file — checked before anything detaches: a wrong one is `ToolPayload.sudoRefused`
/// (97), asked again at once.
public enum ToolLong {
    /// How a job's commands get root: not at all, `sudo -n`, or this password piped to `sudo -S`.
    public enum Root: Sendable { case none, noPassword, password(String) }

    /// `sudo -n` wanted a password (or refused): the start's exit, sudo's words on stderr. Nothing started.
    public static let wantsPassword: Int32 = 96

    /// A job's id: its start time and a random part — its files' names.
    public static func newID(now: Date = Date()) -> String { "\(Int(now.timeIntervalSince1970))-" + ToolPayload.newNonce().prefix(8) }

    /// Where a `folder` or `file` input is uploaded for job `id` (§7.4) — relative to the login folder, where the job
    /// runs and where SFTP starts: a folder as `<id>.<input>.tar.gz`, a file under its own name after the id. The job
    /// removes it when its command ends (`start`); one whose job never started goes a week later.
    public static func upload(_ id: String, _ input: ToolInput, local: String) -> String {
        ".cache/kermo/upload/\(id)." + (input.info.type == .folder ? input.info.name + ".tar.gz" : (local as NSString).lastPathComponent)
    }

    /// One of a job's files, as shell text.
    static func file(_ id: String, _ ext: String) -> String { "\"$HOME/.cache/kermo/runs/\(id).\(ext)\"" }

    /// The start (§7.6): the folder, the week-old jobs gone, sudo checked, then `job` (a `detached` payload) in a session
    /// of its own; its output after the marker is the job's pid, once the job has written it (in its own session then:
    /// the start's watcher can't reach it). `shell`: the server's `sh` (tests run dash and bash).
    public static func start(_ job: ToolPayload, id: String, root: Root, sudoProgram: String = "sudo", shell: String = "sh") -> ToolPayload {
        let n = job.nonce, s = ShellContext.quote(sudoProgram), (pw, hide, check) = sudo(root, n, s)
        let inner: String = switch root {
        case .none: "(\n\(job.script))"
        case .noPassword: "\(s) -n \(shell) -s <<'KERMO_\(n)_ROOT'\n\(job.script)KERMO_\(n)_ROOT"
        // The password, the marker, the script: as the sudo wrapper of a run (ToolPayload `.password`) reads them.
        case .password: pw + "{ printf '%s\\nKERMO-%s\\n' \"$K_kermo_pw\" \(n); cat <<'KERMO_\(n)_ROOT'\n\(job.script)KERMO_\(n)_ROOT\n} | \(s) -S -p '' -k sh -c "
            + ShellContext.quote("IFS= read -r l; [ \"$l\" = KERMO-\(n) ] || IFS= read -r l; [ \"$l\" = KERMO-\(n) ] || exit 97; exec \(shell) -s")
        }
        let pid = file(id, "pid"), exit = file(id, "exit")
        let body = """
            umask 077
            mkdir -p "$HOME/.cache/kermo/runs" && chmod 700 "$HOME/.cache/kermo" "$HOME/.cache/kermo/runs" || exit 1
            for p in "$HOME/.cache/kermo/runs"/*.pid; do
              [ -f "$p" ] || continue; i=${p%.pid}
              if [ -f "$i.exit" ]; then f=$i.exit; elif kill -0 "$(cat "$p")" 2>/dev/null; then continue; else f=$p; fi
              [ -n "$(find "$f" -mtime +6 2>/dev/null)" ] && rm -f "$i".*
            done
            for f in "$HOME/.cache/kermo/upload"/*; do
              [ -f "$f" ] && [ -n "$(find "$f" -mtime +6 2>/dev/null)" ] && rm -f "$f"
            done
            \(check)if command -v setsid >/dev/null 2>&1; then set -- setsid \(shell) -s
            elif command -v perl >/dev/null 2>&1; then set -- perl -e 'use POSIX; setsid(); exec @ARGV' -- \(shell) -s
            elif command -v python3 >/dev/null 2>&1; then set -- python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \(shell) -s
            else echo "no setsid, perl or python3 here: a job can't outlive the connection" >&2; exit 98
            fi
            rm -f \(pid) \(exit)
            "$@" >\(file(id, "log")) 2>&1 <<'KERMO_\(n)_JOB' &
            echo $$ >\(pid)
            trap 'kermo_stop=1' TERM INT HUP
            \(inner)
            s=$?
            rm -f "$HOME/.cache/kermo/upload/\(id)".*
            echo "$s" >\(file(id, "new")) && mv -f \(file(id, "new")) \(exit)
            KERMO_\(n)_JOB
            n=0
            while [ ! -s \(pid) ]; do
              n=$((n + 1)); [ $n -gt 100 ] && { echo "the job didn't start" >&2; exit 99; }
              sleep 0.1 2>/dev/null || sleep 1
            done
            cat \(pid)
            """
        return ToolPayload(body: body, values: [], sudoProgram: sudoProgram, shell: shell, hide: hide + job.secrets)
    }

    /// The password's heredoc (if any), what to hide, and the check before anything starts.
    private static func sudo(_ root: Root, _ n: String, _ s: String) -> (pw: String, hide: [String], check: String) {
        switch root {
        case .none: return ("", [], "")
        case .noPassword: return ("", [], "\(s) -n true || exit \(wantsPassword)\n")
        case .password(let p):
            let pw = "IFS= read -r K_kermo_pw <<'KERMO_\(n)_PW'\n\(p)\nKERMO_\(n)_PW\n"
            return (pw, [p], pw + "printf '%s\\n' \"$K_kermo_pw\" | \(s) -S -p '' -k true || exit \(ToolPayload.sudoRefused)\n")
        }
    }

    /// The job's log from byte `offset` (negative: that many before its end) as it grows, once a second, till its exit
    /// file comes; then on stderr `KERMO-<nonce>-END <exit>` — `lost` where it ended without one (the server restarted),
    /// `gone` where its log is (`end` reads it).
    public static func follow(id: String, from offset: Int, shell: String = "sh") -> ToolPayload {
        let n = ToolPayload.newNonce()
        let body = """
            f=\(file(id, "log")); x=\(file(id, "exit")); o=\(offset)
            [ -f "$f" ] || { echo "KERMO-\(n)-END gone" >&2; exit 0; }
            p=$(cat \(file(id, "pid")) 2>/dev/null)
            while :; do
              e=
              if [ -f "$x" ]; then e=$(cat "$x")
              elif ! kill -0 "$p" 2>/dev/null; then sleep 1; e=$(cat "$x" 2>/dev/null) || e=lost; fi
              s=$(wc -c <"$f"); s=$((s))
              [ "$o" -lt 0 ] && { o=$((s + o)); [ "$o" -lt 0 ] && o=0; }
              [ "$s" -gt "$o" ] && { tail -c +$((o + 1)) "$f" | head -c $((s - o)); o=$s; }
              [ -n "$e" ] && break
              sleep 1
            done
            echo "KERMO-\(n)-END $e" >&2
            """
        return ToolPayload(body: body, values: [], nonce: n, shell: shell)
    }

    /// A job's log, its last MB: Show Log after a relaunch.
    public static func read(id: String) -> ToolPayload { ToolPayload(body: "tail -c 1048576 \(file(id, "log"))", values: []) }

    /// How a follow ended, from its stderr: the job's exit, or that it has none (`lost`) or no log (`gone`). nil: the
    /// follow itself stopped — the connection went, or it was stopped — and the job may run on.
    public enum End: Sendable, Equatable { case exit(Int32), lost, gone }
    public static func end(_ errors: String, nonce: String) -> End? {
        guard let line = errors.split(separator: "\n").last(where: { $0.hasPrefix("KERMO-\(nonce)-END ") }) else { return nil }
        let word = line.dropFirst("KERMO-\(nonce)-END ".count).trimmingCharacters(in: .whitespaces)
        return word == "gone" ? .gone : Int32(word).map(End.exit) ?? .lost
    }

    /// Stop… (§7.6): TERM to the job's process group — root's through sudo: a user's kill reaches sudo, which passes it
    /// to its command only, and root's children run on — then KILL after 5 s, the exit written as 137 then. Nothing
    /// where the job is over already. Always the shell's own `kill`: procps-ng 4.0's `kill -TERM -<group>` says 0 and
    /// kills nothing.
    public static func stop(id: String, root: Root, sudoProgram: String = "sudo", shell: String = "sh") -> ToolPayload {
        let n = ToolPayload.newNonce(), s = ShellContext.quote(sudoProgram), (_, hide, check) = sudo(root, n, s), x = file(id, "exit")
        let kill: String = switch root {
        case .none: "kill \"$@\""
        case .noPassword: "\(s) -n \(shell) -c 'kill \"$@\"' sh \"$@\""
        case .password: "printf '%s\\n' \"$K_kermo_pw\" | \(s) -S -p '' -k \(shell) -c 'kill \"$@\"' sh \"$@\""
        }
        let body = """
            [ -f \(x) ] && exit 0
            p=$(cat \(file(id, "pid"))) || exit 1
            \(check)k() { \(kill); }
            k -TERM -"$p"
            n=0; while [ ! -f \(x) ] && [ $n -lt 5 ]; do sleep 1; n=$((n + 1)); done
            [ -f \(x) ] || { k -KILL -"$p"; echo 137 >\(x); }
            """
        return ToolPayload(body: body, values: [], sudoProgram: sudoProgram, shell: shell, hide: hide)
    }

    /// `make(root)` on `t` — a start or a Stop — as root where `root`: `sudo -n` first, and only where that wanted a
    /// password, with the password (kept, Keychain or asked; three tries, one server's dialog at a time), as `ToolExec`
    /// asks it. `command`: what runs a payload (tests: in a session of its own).
    public static func run(root: Bool, on t: SFTPTarget, cancel: CancelFlag, env: [String: String] = [:],
                           command: @escaping (ToolPayload) -> String = { $0.command }, _ make: (Root) -> ToolPayload) throws -> ToolExec.Ran {
        func once(_ r: Root) throws -> ToolExec.Ran { try ToolExec.once(make(r), on: t, password: nil, timeout: 30, cancel: cancel, env: env, command: command) }
        guard root else { return try once(.none) }
        if !ToolExec.wantsPassword(t) {
            let r = try once(.noPassword)
            guard r.status == wantsPassword, SudoServer.passwordTexts.contains(where: r.errors.contains) else { return r }
            ToolExec.remember(wantsPassword: t)
        }
        return try SudoServer.asking.withLock {
            var wrong = false, said = ""
            for _ in 0..<3 {
                if cancel.isCancelled { throw CancellationError() }
                guard let password = SFTP.sudoPassword?(t, wrong) else { throw ToolExec.NoPassword() }
                guard !password.contains(where: \.isNewline) else { wrong = true; continue }   // sudo reads one line
                var r = try once(.password(password))
                r.password = password
                if r.status != ToolPayload.sudoRefused {
                    if r.stopped == nil { SFTP.sudoPasswordTaken?(t, password) }
                    return r
                }
                if SudoServer.notAllowedTexts.contains(where: r.errors.contains) { throw SFTPError(message: "sudo on \(t.host) refused: " + r.errors) }
                (wrong, said) = (true, r.errors)
            }
            throw SFTPError(message: "sudo on \(t.host) refused the password 3 times" + (said.isEmpty ? "." : ": " + said))
        }
    }

    /// What a log line says of the job's progress (§7.6): `pattern`'s group `percent`, or `percent` / `fraction` — a
    /// field of a JSON line; `text`, the template the card shows (the line's fields). nil: nothing of it here.
    public static func progress(_ p: ToolProgress, line: String) -> (fraction: Double, text: String?)? {
        var record = ToolRecord(), value: Double?
        if let pattern = p.pattern {
            guard let re = try? Regex(pattern), let m = line.firstMatch(of: re) else { return nil }
            for g in m.output.dropFirst() { if let name = g.name, let s = g.substring { record[name] = .string(String(s)) } }
            value = record["percent"]?.number.map { $0 / 100 }
        } else if case .object(let o)? = (try? JSONSerialization.jsonObject(with: Data(line.utf8))).map(ToolValue.init(any:)) {
            record = o
            let doc = ToolValue.object(o)
            if let f = p.percent { value = doc[f]?.number.map { $0 / 100 } } else if let f = p.fraction { value = doc[f]?.number }
        }
        guard let value else { return nil }
        return (min(max(value, 0), 1), p.text.map { ToolTemplate.text($0, .init(rows: [record])) })
    }

    /// The last record of a job's log read as `format` (§7.6): what its `done` takes its fields from.
    public static func last(_ log: Data, format: ToolFormat) -> ToolRecord? { ToolParse(format: format, limit: .max).records(log).rows.last }
}
