import Foundation

/// Folder sizes on a server by its own `du` (Space / ⌥Space on a server panel): one command over the connection instead
/// of an SFTP walk of every folder. `du -slbx`: GNU and busybox both know it — apparent bytes (`-b`), each hard link
/// counted (`-l`) and nothing past the folder's file system (`-x`), as the walk counts. BSD's du has no `-b`: then the walk.
public enum ServerSizes {
    public struct Size: Equatable, Sendable {
        public var bytes: Int64
        /// du couldn't read all of it: at least this much.
        public var partial = false
        public init(bytes: Int64, partial: Bool = false) { (self.bytes, self.partial) = (bytes, partial) }
    }

    /// The line the script prints before du's own: whatever a login script printed comes before it.
    static let marker = "kermo-sizes"
    static let ran = "kermo-ran", noDu = "kermo-no-du"

    /// What runs there, in `sh` (the login shell may be any), after `set -- <dir> <names…>`: in C (du's complaints in
    /// English, as `parse` reads them), in the folder; a du that counts bytes, or says so; then du, its exit status the
    /// script's. ⎋ ends ssh, and without a terminal sshd sends du no signal: a quiet du would run on to its end. So a
    /// watcher writes a newline to stderr each second — once ssh is gone that write fails (SIGPIPE, or EPIPE where it's
    /// ignored) and it kills du. Its sleep holds no stream open: the command ends when du does.
    static let script = """
        echo \(ran); LC_ALL=C; export LC_ALL; cd -- "$1" || exit 2; shift
        du -slbx /dev/null >/dev/null 2>&1 || { echo \(noDu); exit 0; }
        echo \(marker)
        du -slbx -- "$@" & p=$!
        ( trap 'kill $p 2>/dev/null; exit' PIPE; while echo >&2; do sleep 1 >/dev/null 2>&1; done; kill $p 2>/dev/null ) & w=$!
        wait $p; s=$?; kill $w 2>/dev/null; exit $s
        """

    /// The sizes of the folders `names` in `dir` on `t`'s server, by its du — on a root panel's as root, through its sudo
    /// (`sudo -n`; a password only where that refused for want of one). One ssh command over the connection for every
    /// few thousand names (a command line there is one argument: Linux takes 128 KiB). nil: no du there that counts
    /// bytes (BSD, macOS) — the caller walks instead. Throws what went wrong otherwise; CancellationError on ⎋.
    /// A name with a newline (du's line would break) or with bytes that aren't UTF-8 (`WireName`: a command line can't
    /// name them) isn't asked about: no size for it here, as for one that's gone — the caller walks those.
    public static func measure(_ names: [String], in dir: String, on t: SFTPTarget, env: [String: String] = [:],
                               cancel: CancelFlag? = nil) throws -> [String: Size]? {
        var out: [String: Size] = [:]
        let names = names.filter { !$0.contains("\n") && !$0.unicodeScalars.contains(where: WireName.isEscape) }
        for chunk in chunks(names) {
            let script = "set -- " + ([dir] + chunk).map(ShellContext.quote).joined(separator: " ") + "\n" + Self.script
            let status: Int32, output: Data, errors: String
            if t.sudo {
                (status, output, errors) = try SudoServer.run(t, script: script, env: env, cancel: cancel) { $0.range(of: Data((ran + "\n").utf8)) != nil }
            } else {
                var o = Data()
                (status, errors) = try SSHCommand.run(t, "sh -c " + ShellContext.quote(script), env: env, cancel: cancel, options: ["-x", "-a"]) { o += $0 }
                output = o
            }
            let text = String(decoding: output, as: UTF8.self)
            let lines = text.split(separator: "\n")
            if lines.contains(Substring(noDu)) { return nil }
            guard lines.contains(Substring(marker)), status == 0 || status == 1 else {
                let said = errors.split(whereSeparator: \.isNewline).joined(separator: "\n")   // the watcher's blank lines out
                throw SFTPError(message: said.isEmpty ? "du failed on \(t.host) (exit \(status))" : said)
            }
            out.merge(parse(text, errors: errors, status: status, names: chunk)) { $1 }
        }
        return out
    }

    /// Names in runs whose command line stays well under 128 KiB: each quoted for the script, and the script again.
    static func chunks(_ names: [String], budget: Int = 65_536) -> [[String]] {
        var out: [[String]] = [], run: [String] = [], size = 0
        for n in names {
            let cost = ShellContext.quote(ShellContext.quote(n)).utf8.count + 1
            if !run.isEmpty && size + cost > budget { out.append(run); (run, size) = ([], 0) }
            run.append(n)
            size += cost
        }
        return run.isEmpty ? out : out + [run]
    }

    /// du's answer for `names` (each an argument, as given): a line "<bytes>\t<name>" for each it could look at — stdout
    /// is read whatever the exit status, as du prints what it could and exits 1. A name with no line has no size (gone
    /// meanwhile). Exit 1: the names its `du:` lines on stderr point into are partial; a line that points nowhere among
    /// them (a name du quotes its own way) makes them all partial — "at least" is true either way.
    static func parse(_ output: String, errors: String, status: Int32, names: [String]) -> [String: Size] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let at = lines.firstIndex(of: Substring(marker)) else { return [:] }
        let wanted = Set(names)
        var out: [String: Size] = [:]
        for line in lines[(at + 1)...] {
            guard let tab = line.firstIndex(of: "\t"), let bytes = Int64(line[..<tab]), bytes >= 0 else { continue }
            let name = String(line[line.index(after: tab)...])
            if wanted.contains(name) { out[name] = Size(bytes: bytes) }
        }
        guard status != 0 else { return out }
        var partial = Set<String>(), all = false
        for line in errors.split(whereSeparator: \.isNewline) where line.hasPrefix("du: ") {
            // "du: cannot read directory 'b/locked': Permission denied" (GNU, uutils), "du: can't open 'b/locked': …",
            // "du: missing: No such file or directory" (busybox)
            let path = line.range(of: " '").map { line[$0.upperBound...] } ?? line.dropFirst(4).prefix { $0 != ":" }   // not the ' in "can't"
            let name = String(path.prefix { $0 != "/" && $0 != "'" })
            if wanted.contains(name) { partial.insert(name) } else { all = true }
        }
        for name in out.keys where all || partial.contains(name) { out[name]!.partial = true }
        return out
    }
}
