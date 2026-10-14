import Foundation
import Testing
@testable import DFMCore

private func git(_ args: [String], in dir: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    precondition(p.terminationStatus == 0, "git \(args) failed")
}

private func write(_ path: String, _ text: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

@Test func gitStatusOfARealRepo() throws {
    let repo = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-git-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: repo) }
    write(repo + "/clean.txt", "c")
    write(repo + "/edit.txt", "1")
    write(repo + "/src/lib/code.swift", "x")
    git(["init", "-q"], in: repo)
    git(["add", "."], in: repo)
    git(["commit", "-q", "-m", "init"], in: repo)

    write(repo + "/edit.txt", "2")                 // modified, unstaged
    write(repo + "/staged.txt", "s")
    git(["add", "staged.txt"], in: repo)            // added, staged
    write(repo + "/new.txt", "n")                   // untracked
    write(repo + "/src/lib/code.swift", "y")        // change deep inside src/
    write(repo + "/untracked-dir/a", "a")

    let st = try #require(GitStatus.load(repo))
    #expect(st.branch == "main")
    #expect(st.marks["edit.txt"] == " M")
    #expect(st.marks["staged.txt"] == "A ")
    #expect(st.marks["new.txt"] == "??")
    #expect(st.marks["src"] == "•")
    #expect(st.marks["untracked-dir"] == "??")
    #expect(st.marks["clean.txt"] == nil)

    // From inside a subfolder only its own entries show up.
    let sub = try #require(GitStatus.load(repo + "/src"))
    #expect(sub.marks == ["lib": "•"])
    #expect(GitStatus.repoRoot(repo + "/src/lib") == repo)

    // Git Changes: every file at or below the folder, untracked ones one by one; deleted ones only counted.
    #expect(st.changes["untracked-dir"] == "??")
    try FileManager.default.removeItem(atPath: repo + "/clean.txt")
    let all = try #require(GitStatus.load(repo, allUntracked: true))
    #expect(all.changes == ["edit.txt": " M", "staged.txt": "A ", "new.txt": "??", "src/lib/code.swift": " M",
                            "untracked-dir/a": "??", "clean.txt": " D"])
    let (items, deleted) = all.changedItems(in: repo)
    #expect(Set(items.map(\.name)) == ["edit.txt", "staged.txt", "new.txt", "src/lib/code.swift", "untracked-dir/a"])
    #expect(deleted == 1)
    #expect(try #require(GitStatus.load(repo + "/src", allUntracked: true)).changes == ["lib/code.swift": " M"])
}

@Test func gitBranchLineAndRenames() {
    let out = "## main...origin/main [ahead 2, behind 1]\0R  new name.txt\0old.txt\0 M dir/x\0"
    let st = GitStatus.parse(out, repoRoot: "/r", dir: "/r")
    #expect(st.branch == "main" && st.ahead == 2 && st.behind == 1)
    #expect(st.marks == ["new name.txt": "R ", "dir": "•"])
    #expect(GitStatus.parse("## No commits yet on dev\0", repoRoot: "/r", dir: "/r").branch == "dev")
}

@Test func gitStatusParsesEveryBranchAndRecordShape() {
    func parse(_ s: String, dir: String = "/r") -> GitStatus { GitStatus.parse(s, repoRoot: "/r", dir: dir) }
    #expect(parse("## HEAD (no branch)\0").branch == "HEAD (no branch)")
    #expect(parse("## main\0") == GitStatus(branch: "main", root: "/r"))
    #expect(parse("## main...origin/main [ahead 3]\0").ahead == 3)
    #expect(parse("## dev...origin/dev [behind 4]\0") == GitStatus(branch: "dev", ahead: 0, behind: 4, upstream: "origin/dev", root: "/r"))
    #expect(parse("## feature/x-1...origin/feature/x-1 [ahead 1, behind 2]\0").branch == "feature/x-1")
    #expect(parse("").marks.isEmpty)

    let copies = parse("C  copy.txt\0orig.txt\0?? dir/\0?? other/deep/x\0UU merge.c\0")
    #expect(copies.marks == ["copy.txt": "C ", "dir": "??", "other": "•", "merge.c": "UU"])
    #expect(copies.changes == ["copy.txt": "C ", "dir": "??", "other/deep/x": "??", "merge.c": "UU"])
    // An explicit mark on a folder beats "changed inside", in either order.
    #expect(parse(" M d/x\0?? d/\0").marks["d"] == "??")
    #expect(parse("?? d/\0 M d/x\0").marks["d"] == "??")
    #expect(parse("?? \0 M\0").marks.isEmpty)   // malformed records are ignored

    // Listing a subfolder: only its own entries, with the prefix stripped.
    let sub = parse("## main\0 M src/a.swift\0 M src/lib/b.swift\0?? other/c\0 M src\0", dir: "/r/src")
    #expect(sub.marks == ["a.swift": " M", "lib": "•"])
    #expect(sub.changes == ["a.swift": " M", "lib/b.swift": " M"])
    #expect(parse("## main\0 M a\0", dir: "/r/empty").marks.isEmpty)
}

@Test func gitWorktreesAndNonRepos() throws {
    let base = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-wt-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: base) }
    write(base + "/repo/a.txt", "a")
    git(["init", "-q"], in: base + "/repo")
    git(["add", "."], in: base + "/repo")
    git(["commit", "-q", "-m", "init"], in: base + "/repo")
    git(["worktree", "add", "-q", "-b", "wt-branch", base + "/wt"], in: base + "/repo")

    #expect(GitStatus.repoRoot(base + "/wt") == base + "/wt")   // .git is a file there
    let st = try #require(GitStatus.load(base + "/wt"))
    #expect(st.branch == "wt-branch" && st.marks.isEmpty)
    write(base + "/wt/new.txt", "n")
    #expect(GitStatus.load(base + "/wt")?.marks == ["new.txt": "??"])

    try FileManager.default.createDirectory(atPath: base + "/plain", withIntermediateDirectories: true)
    #expect(GitStatus.repoRoot(base + "/plain") == nil)
    #expect(GitStatus.load(base + "/plain") == nil)
    #expect(GitStatus.load(base + "/does-not-exist") == nil)
}

@Test func gitDiffCommandShowsTrackedAndUntrackedAsAdded() throws {
    let repo = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-diff-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: repo) }
    write(repo + "/a.txt", "old\n")
    write(repo + "/clean.txt", "c\n")
    git(["init", "-q"], in: repo)
    git(["add", "."], in: repo)
    git(["commit", "-q", "-m", "init"], in: repo)
    write(repo + "/a.txt", "new\n")
    write(repo + "/it's new.txt", "fresh\n")

    func run(_ tracked: [String], _ untracked: [String]) -> (out: String, status: Int32) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", GitStatus.diffCommand(tracked: tracked.map { repo + "/" + $0 }, untracked: untracked.map { repo + "/" + $0 })]
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        p.standardOutput = out
        try! p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }
    let both = run(["a.txt"], ["it's new.txt"])
    #expect(both.status == 1)
    #expect(both.out.contains("-old") && both.out.contains("+new") && both.out.contains("+fresh"))
    #expect(run(["clean.txt"], []) == ("", 0))   // "Files are identical."

    #expect(GitStatus.trustedRoot(repo) == repo)
    git(["config", "core.fsmonitor", "touch pwned"], in: repo)
    #expect(GitStatus.trustedRoot(repo) == nil)
}

@Test func gitBranchLineSaysUpstreamDetachedAndConflicts() {
    func parse(_ s: String, dir: String = "/r") -> GitStatus { GitStatus.parse(s, repoRoot: "/r", dir: dir) }
    let tracked = parse("## main...origin/main [ahead 1, behind 2]\0")
    #expect(tracked.upstream == "origin/main" && !tracked.gone && !tracked.detached)
    let gone = parse("## feat...origin/feat [gone]\0")
    #expect(gone.branch == "feat" && gone.upstream == "origin/feat" && gone.gone && gone.ahead == 0)
    #expect(parse("## local-only\0").upstream == nil)
    #expect(parse("## No commits yet on dev\0").upstream == nil)
    let detached = parse("## HEAD (no branch)\0")
    #expect(detached.detached && detached.upstream == nil)

    let st = parse("## main\0UU a.c\0AA b.c\0DU c.c\0M  d.c\0MM e.c\0 M f.c\0?? g.c\0R  h.c\0old.c\0", dir: "/r")
    #expect(st.conflicts == 3 && st.staged == 3)   // UU AA DU; M_, MM, R_
    #expect(st.root == "/r" && st.subdir == "")
    let sub = parse("## main\0 M src/lib/a.c\0", dir: "/r/src/lib")
    #expect(sub.subdir == "src/lib" && sub.changes == ["a.c": " M"])
}

@Test func gitRefsListLocalThenRemoteOnlyThenTags() {
    let line = { (head: String, ref: String, track: String) in "\(head)\0\(ref)\0abc1234\03 hours ago\0\(track)\0Subject, with\ttab\n" }
    let out = line("", "refs/heads/feat", "[gone]") + line("*", "refs/heads/main", "[ahead 1]") + line("", "refs/remotes/origin/HEAD", "")
        + line("", "refs/remotes/origin/main", "") + line("", "refs/remotes/origin/fix/a", "") + line("", "refs/tags/v1.0", "") + "broken\n"
    let refs = GitStatus.parseRefs(out)
    #expect(refs.map(\.name) == ["feat", "main", "origin/fix/a", "v1.0"])
    #expect(refs.map(\.kind) == [.local, .local, .remote, .tag])
    #expect(refs[0].gone && !refs[0].current && refs[1].current && !refs[1].gone)
    #expect(refs[1] == GitStatus.Ref(name: "main", kind: .local, hash: "abc1234", subject: "Subject, with\ttab", age: "3 hours ago", current: true))
}

/// The Git section's actions on a real repo with a bare "origin" next to it: no network, nothing global changed.
@Test func gitActionsCommitSwitchPublishPullFetch() throws {
    let base = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-gitact-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: base) }
    let repo = base + "/repo", other = base + "/other", noSign = ["-c", "commit.gpgsign=false"]
    func act(_ args: [String], in dir: String = repo) -> (ok: Bool, output: String) { GitStatus.act(args, in: dir) }
    write(repo + "/a.txt", "1")
    write(other + "/.keep", "")

    // init: in a plain folder; not again inside a work tree
    #expect(GitStatus.initialize(repo).ok)
    try FileManager.default.createDirectory(atPath: repo + "/sub", withIntermediateDirectories: true)
    let again = GitStatus.initialize(repo + "/sub")
    #expect(!again.ok && again.output.contains(repo))
    git(["config", "user.name", "t"], in: repo)
    git(["config", "user.email", "t@t"], in: repo)
    git(["switch", "-q", "-c", "main"], in: repo)

    // commit everything; then amend
    #expect(act(["add", "-A"]).ok)
    #expect(act(noSign + ["commit", "-q", "-m", "first"]).ok)
    write(repo + "/b.txt", "2")
    #expect(act(["add", "-A"]).ok)
    #expect(act(noSign + ["commit", "-q", "--amend", "-m", "first, amended"]).ok)
    #expect(GitStatus.refs(repo)?.first?.subject == "first, amended")
    let nothing = act(noSign + ["commit", "-m", "empty"])
    #expect(!nothing.ok && nothing.output.contains("nothing to commit"))   // git's own words come back

    // a branch: create, switch back, -d refuses an unmerged one
    #expect(act(["switch", "-q", "-c", "feat"]).ok)
    write(repo + "/c.txt", "3")
    #expect(act(["add", "-A"]).ok && act(noSign + ["commit", "-q", "-m", "on feat"]).ok)
    #expect(act(["switch", "-q", "main"]).ok)
    let refuse = act(["branch", "-d", "feat"])
    #expect(!refuse.ok && refuse.output.contains("not fully merged"))
    let bad = act(["switch", "-c", "two words"])
    #expect(!bad.ok && bad.output.contains("not a valid branch name"))

    // publish to a bare origin, then a second clone pushes and the first pulls --ff-only
    git(["init", "-q", "--bare", base + "/origin.git"], in: base)
    #expect(act(["remote", "add", "origin", base + "/origin.git"]).ok)
    #expect(GitStatus.load(repo)?.upstream == nil)
    #expect(act(["push", "-q", "-u", "origin", "main"]).ok)
    #expect(act(["push", "-q", "-u", "origin", "feat"]).ok)
    #expect(GitStatus.load(repo)?.upstream == "origin/main")
    git(["clone", "-q", base + "/origin.git", other + "/clone"], in: base)
    write(other + "/clone/d.txt", "4")
    git(["add", "-A"], in: other + "/clone")
    git(["commit", "-q", "-m", "from the clone"], in: other + "/clone")
    git(["push", "-q", "origin", "main"], in: other + "/clone")
    git(["push", "-q", "origin", "--delete", "feat"], in: other + "/clone")
    #expect(act(["fetch", "-q", "--prune"]).ok)
    let behind = try #require(GitStatus.load(repo))
    #expect(behind.behind == 1 && behind.fetched != nil)
    #expect(act(["pull", "-q", "--ff-only"]).ok)
    #expect(GitStatus.load(repo)?.behind == 0)
    let refs = try #require(GitStatus.refs(repo))
    #expect(refs.first { $0.name == "feat" }?.gone == true)   // merged elsewhere and pruned: shown dimmed
    #expect(!refs.contains { $0.kind == .remote && $0.name == "origin/main" })   // main is local already

    // a remote-only branch becomes a local one that tracks it
    git(["switch", "-q", "-c", "fix"], in: other + "/clone")
    git(["push", "-q", "-u", "origin", "fix"], in: other + "/clone")
    #expect(act(["fetch", "-q"]).ok)
    #expect(GitStatus.refs(repo)?.contains { $0.kind == .remote && $0.name == "origin/fix" } == true)
    #expect(act(["switch", "-q", "--track", "origin/fix"]).ok)
    #expect(GitStatus.load(repo)?.branch == "fix" && GitStatus.load(repo)?.upstream == "origin/fix")

    // a repo whose config can run commands: nothing runs
    git(["config", "core.fsmonitor", "touch pwned"], in: repo)
    let refused = act(["status"])
    #expect(!refused.ok && refused.output.contains("config can run commands"))
    #expect(GitStatus.refs(repo) == nil)
}

@Test func gitActionStopsOnCancel() throws {
    let repo = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-gitcancel-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: repo) }
    write(repo + "/a.txt", "1")
    git(["init", "-q"], in: repo)
    write(repo + "/.git/hooks/pre-commit", "#!/bin/sh\nsleep 30\n")
    chmod(repo + "/.git/hooks/pre-commit", 0o755)
    git(["add", "."], in: repo)
    let flag = CancelFlag()
    Timeouts.queue.asyncAfter(deadline: .now() + 0.5) { flag.cancel() }
    let start = Date()
    let r = GitStatus.act(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-m", "x"], in: repo, cancel: flag)
    #expect(!r.ok && Date().timeIntervalSince(start) < 10)   // the hook's sleep went with git
}
