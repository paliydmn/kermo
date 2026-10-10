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
    #expect(parse("## main\0") == GitStatus(branch: "main"))
    #expect(parse("## main...origin/main [ahead 3]\0").ahead == 3)
    #expect(parse("## dev...origin/dev [behind 4]\0") == GitStatus(branch: "dev", ahead: 0, behind: 4))
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
