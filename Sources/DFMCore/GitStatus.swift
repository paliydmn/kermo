import Foundation

/// `git status` for the folder a panel shows: a code per visible name plus branch and ahead/behind.
public struct GitStatus: Sendable, Equatable {
    public var branch = ""
    public var ahead = 0
    public var behind = 0
    /// Name in the listed folder → porcelain "XY" code ("M ", " M", "??", "A ", "UU"…), or "•" for a
    /// folder with changes somewhere inside.
    public var marks: [String: String] = [:]
    /// Every change at or below the listed folder: path relative to it → porcelain code.
    public var changes: [String: String] = [:]

    /// Walks up from `dir` looking for `.git` (a folder, or a file for worktrees/submodules).
    public static func repoRoot(_ dir: String) -> String? {
        var d = (dir as NSString).resolvingSymlinksInPath
        while true {
            var s = stat()
            if lstat((d as NSString).appendingPathComponent(".git"), &s) == 0 { return d }
            let parent = (d as NSString).deletingLastPathComponent
            if parent == d || parent.isEmpty { return nil }
            d = parent
        }
    }

    /// Runs git (call off the main thread). nil if `dir` isn't in a work tree, git fails, or the repo's own
    /// config isn't known to be inert (see `isInert`). `allUntracked` lists each untracked file, not just "dir/".
    public static func load(_ dir: String, allUntracked: Bool = false) -> GitStatus? {
        guard let root = trustedRoot(dir),
              let data = git(["-c", "core.fsmonitor=false", "status", "--ignore-submodules=all", "--porcelain=v1", "-b", "-z"]
                             + (allUntracked ? ["--untracked-files=all"] : []) + ["--", "."], in: dir)
        else { return nil }
        return parse(String(decoding: data, as: UTF8.self), repoRoot: root, dir: (dir as NSString).resolvingSymlinksInPath)
    }

    /// The work tree `dir` is in, if that repo's own config can't make git run a command (see `isInert`).
    /// Check it right before running git there.
    public static func trustedRoot(_ dir: String) -> String? {
        guard let root = repoRoot(dir),
              let config = git(["config", "--list", "--show-scope", "--no-includes", "-z"], in: dir),
              isInert(String(decoding: config, as: UTF8.self))
        else { return nil }
        return root
    }

    /// The same status for a server folder: `run` sends a command line to the server and returns what it printed
    /// (nil: it failed). The repo's config is read and checked here first, as for `load`; a server's git before
    /// 2.26 (no --show-scope) fails that check, so no column there.
    public static func remote(_ dir: String, run: (String) -> Data?) -> GitStatus? {
        let git = "LC_ALL=C GIT_OPTIONAL_LOCKS=0 git --no-optional-locks "
        guard let head = run(SSHCommand.inDir(dir, git + "rev-parse --show-toplevel --show-prefix && "
                                                   + git + "config --list --show-scope --no-includes -z")) else { return nil }
        // "root\nprefix/\n" (the prefix empty at the root), then the config records
        let parts = String(decoding: head, as: UTF8.self).split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, isInert(parts[2]),
              let out = run(SSHCommand.inDir(dir, git + "-c core.fsmonitor=false status --ignore-submodules=all --porcelain=v1 -b -z -- ."))
        else { return nil }
        return parse(String(decoding: out, as: UTF8.self), repoRoot: parts[0], dir: parts[1].isEmpty ? parts[0] : parts[0] + "/" + parts[1].dropLast())
    }

    /// A file's history (`git log --follow -p`) or `git blame`, as text for the viewer. nil: not in a work tree
    /// whose config is inert, or git failed (blame of an untracked file). No external diff, textconv or colors.
    public static func history(_ file: String, blame: Bool) -> Data? {
        let dir = (file as NSString).deletingLastPathComponent, name = (file as NSString).lastPathComponent
        guard trustedRoot(dir) != nil else { return nil }
        return git(["--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "color.ui=never"]   // ":notes" is a name, no pathspec magic
                   + (blame ? ["blame", "--no-textconv"] : ["log", "--follow", "-p", "--no-ext-diff", "--no-textconv"]) + ["--", name], in: dir)
    }

    /// `git add` (deletions too) or, `undo`, `git reset` of `paths` in the work tree `dir` is in: staged / unstaged.
    /// False if it didn't run (see `trustedRoot`) or failed (an ignored file).
    public static func stage(_ paths: [String], in dir: String, undo: Bool = false) -> Bool {
        guard trustedRoot(dir) != nil else { return false }
        return git(["--literal-pathspecs", "-c", "core.fsmonitor=false"] + (undo ? ["reset", "-q"] : ["add", "-A"]) + ["--"] + paths, in: dir) != nil
    }

    /// Git Diff as one shell line: `tracked` paths against HEAD, then each untracked file as wholly added
    /// (`--no-index` takes exactly two paths). Exit 1 = there are differences, as for diff(1). No external
    /// diff drivers or textconv; run it only where `trustedRoot` passed.
    public static func diffCommand(tracked: [String], untracked: [String]) -> String {
        let diff = "/usr/bin/git --no-pager --no-optional-locks -c core.fsmonitor=false diff --no-ext-diff --no-textconv --exit-code"
        return ((tracked.isEmpty ? [] : [diff + " HEAD -- " + tracked.map(ShellContext.quote).joined(separator: " ")])
            + untracked.map { diff + " --no-index -- /dev/null " + ShellContext.quote($0) }).joined(separator: "; ")
    }

    /// Without Command Line Tools `/usr/bin/git` is a shim that pops up "install developer tools" on every run.
    /// Checked once; when false no git runs, so the git column, Git Changes and Git Diff stay off.
    public static let available = gitInstalled(developerDir: developerDir())

    /// `xcode-select -p` names a folder (CLT or Xcode.app) that really has git in it.
    static func gitInstalled(developerDir: String?) -> Bool {
        developerDir.map { FileManager.default.isExecutableFile(atPath: $0 + "/usr/bin/git") } ?? false
    }

    private static func developerDir() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// Killed after `timeout`: a repo on a stale network mount, or one whose .gitignore is a FIFO, blocks git forever.
    static func git(_ args: [String], in dir: String, timeout: TimeInterval = 30) -> Data? {
        guard available else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["--no-optional-locks", "-C", dir] + args
        p.environment = ProcessInfo.processInfo.environment.merging(["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]) { $1 }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let kill = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        kill.cancel()
        return p.terminationReason == .exit && p.terminationStatus == 0 ? data : nil
    }

    /// A browsed repo is untrusted data: its .git/config can name commands `git status` runs (core.fsmonitor,
    /// filter.<x>.clean through .gitattributes, include.path pulling in more). Allow-list, not deny-list: any
    /// repo-level key outside these means no git column for that folder. The user's own global/system config is trusted.
    static func isInert(_ configList: String) -> Bool {
        let records = configList.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        return stride(from: 0, to: records.count - 1, by: 2).allSatisfy { i in
            guard records[i] == "local" || records[i] == "worktree" else { return true }
            let key = records[i + 1].prefix { $0 != "\n" }
            let section = String(key.prefix { $0 != "." }), name = section + "." + (key.split(separator: ".").last ?? "")
            return inertSections.contains(section) || inertKeys.contains(name)
        }
    }
    private static let inertSections: Set<String> = ["branch", "user", "gui", "pull", "push", "init", "color", "i18n", "status"]
    private static let inertKeys: Set<String> = [   // "section.name", any subsection
        "core.repositoryformatversion", "core.filemode", "core.bare", "core.logallrefupdates", "core.ignorecase",
        "core.precomposeunicode", "core.symlinks", "core.autocrlf", "core.eol", "core.untrackedcache",
        "core.sparsecheckout", "core.sparsecheckoutcone", "core.worktree", "extensions.objectformat", "extensions.refstorage",
        "extensions.worktreeconfig", "remote.url", "remote.pushurl", "remote.fetch", "remote.push", "remote.tagopt",
        "remote.mirror", "remote.prune", "remote.gh-resolved", "submodule.url", "submodule.path", "submodule.active",
        "lfs.repositoryformatversion", "lfs.access",
        "core.hookspath",   // husky; status with --no-optional-locks writes no index, so post-index-change never runs
    ]

    static func parse(_ output: String, repoRoot: String, dir: String) -> GitStatus {
        var st = GitStatus()
        let prefix = dir == repoRoot ? "" : String(dir.dropFirst(repoRoot.count + 1)) + "/"
        var records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let rec = records.popFirst() {
            if rec.hasPrefix("## ") {
                parseBranch(String(rec.dropFirst(3)), into: &st)
                continue
            }
            guard rec.count > 3 else { continue }
            let code = String(rec.prefix(2))
            let path = String(rec.dropFirst(3))
            if code.first == "R" || code.first == "C" { _ = records.popFirst() }   // renames carry the old path next
            guard path.hasPrefix(prefix) else { continue }
            let rest = path.dropFirst(prefix.count)
            st.changes[String(rest.hasSuffix("/") ? rest.dropLast() : rest)] = code
            let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = parts.first.map(String.init) else { continue }
            // "dir/" alone is an untracked folder; anything deeper marks the folder as "changed inside".
            if parts.count == 1 { st.marks[first] = code } else if st.marks[first] == nil { st.marks[first] = "•" }
        }
        return st
    }

    /// `changes` as panel rows named by their path relative to `dir` (the folder `load` ran in). Deleted files
    /// aren't on disk to show; they're only counted.
    public func changedItems(in dir: String) -> (items: [FileItem], deleted: Int) {
        var deleted = 0
        let items = changes.keys.compactMap { rel -> FileItem? in
            guard let it = FileSearch.lstatItem((dir as NSString).appendingPathComponent(rel)) else { deleted += 1; return nil }
            return it.renamed(rel)
        }
        return (items, deleted)
    }

    /// "main...origin/main [ahead 1, behind 2]", "No commits yet on main", "HEAD (no branch)".
    private static func parseBranch(_ s: String, into st: inout GitStatus) {
        var head = s
        if let r = s.range(of: " [") {
            head = String(s[..<r.lowerBound])
            for part in s[r.upperBound...].dropLast().split(separator: ",") {
                let kv = part.split(separator: " ")
                if kv.count == 2, let n = Int(kv[1]) {
                    if kv[0] == "ahead" { st.ahead = n } else if kv[0] == "behind" { st.behind = n }
                }
            }
        }
        if head.hasPrefix("No commits yet on ") { head = String(head.dropFirst("No commits yet on ".count)) }
        st.branch = head.components(separatedBy: "...").first ?? head
    }
}

/// Runs `run` one at a time, for refreshes that come faster than they finish (`git status` on every reload of
/// a busy repo): a request while one runs only marks it to run once more after. A run for the same key starts at
/// least `interval` after the previous one ended, so a slow one doesn't run back to back. A new key (another
/// folder) doesn't wait, not even for a run still going for the old one: that run is left to finish on its own.
@MainActor public final class SingleFlight {
    private let interval: Duration
    private let run: @MainActor () async -> Void
    private var again = false
    private var key = ""
    private var flight = 0, running = false   // `flight` numbers the loop that owns the requests; older loops just stop
    private var last: (key: String, end: ContinuousClock.Instant)?

    public init(interval: Duration = .seconds(1), run: @escaping @MainActor () async -> Void) {
        self.interval = interval
        self.run = run
    }

    public func request(key: String) {
        let newKey = key != self.key
        self.key = key
        again = true
        guard !running || newKey else { return }
        running = true
        flight += 1
        let mine = flight
        Task {
            while again, flight == mine {
                if let last, last.key == self.key { try? await Task.sleep(until: last.end + interval, clock: .continuous) }
                guard flight == mine else { return }
                again = false
                let key = self.key
                await run()
                guard flight == mine else { return }
                last = (key, .now)
            }
            if flight == mine { running = false }
        }
    }
}
