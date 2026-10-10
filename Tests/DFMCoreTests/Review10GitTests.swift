import Foundation
import Testing
@testable import DFMCore

// Task 10, I9 (tasks/task10_review_v2/README.md §6): git log / blame, stage / unstage, status on a server.

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

/// A repo with src/a.txt committed twice, src/b.txt committed once.
private func repo() -> String {
    let repo = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-i9-" + UUID().uuidString
    write(repo + "/src/a.txt", "one\n")
    write(repo + "/src/b.txt", "b\n")
    git(["init", "-q"], in: repo)
    git(["add", "."], in: repo)
    git(["commit", "-q", "-m", "first"], in: repo)
    write(repo + "/src/a.txt", "one\ntwo\n")
    git(["commit", "-q", "-am", "second"], in: repo)
    return repo
}

@Test(.enabled(if: GitStatus.available)) func gitLogAndBlameOfAFile() throws {
    let repo = repo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    let log = String(decoding: try #require(GitStatus.history(repo + "/src/a.txt", blame: false)), as: UTF8.self)
    #expect(log.contains("    second") && log.contains("    first") && log.contains("+two"), "both commits, with their patches")
    #expect(!log.contains("\u{1b}["), "no colors")
    let blame = String(decoding: try #require(GitStatus.history(repo + "/src/a.txt", blame: true)), as: UTF8.self)
    #expect(blame.split(separator: "\n").count == 2 && blame.contains(") one") && blame.contains(") two"))

    write(repo + "/src/new.txt", "n\n")
    #expect(GitStatus.history(repo + "/src/new.txt", blame: false)?.isEmpty == true, "untracked: no commits")
    #expect(GitStatus.history(repo + "/src/new.txt", blame: true) == nil)
}

@Test(.enabled(if: GitStatus.available)) func stageAndUnstage() throws {
    let repo = repo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    write(repo + "/src/a.txt", "changed\n")
    write(repo + "/src/new.txt", "n\n")
    let src = repo + "/src"
    #expect(GitStatus.load(src)?.marks == ["a.txt": " M", "new.txt": "??"])
    #expect(GitStatus.stage([src + "/a.txt", src + "/new.txt"], in: src))
    #expect(GitStatus.load(src)?.marks == ["a.txt": "M ", "new.txt": "A "])
    #expect(GitStatus.stage([src + "/a.txt", src + "/new.txt"], in: src, undo: true))
    #expect(GitStatus.load(src)?.marks == ["a.txt": " M", "new.txt": "??"])
}

/// The panel's git column on a server: the same status over its connection (here a test target's local shell).
@Test(.enabled(if: GitStatus.available)) func statusOnAServerFolder() throws {
    let repo = repo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    write(repo + "/src/a.txt", "changed\n")
    write(repo + "/top.txt", "t\n")
    let run = { (command: String) in SSHCommand.output(.local(), command) }
    let sub = try #require(GitStatus.remote(repo + "/src", run: run))
    #expect(sub == GitStatus.load(repo + "/src") && sub.marks == ["a.txt": " M"] && sub.branch == "main")
    #expect(GitStatus.remote(repo, run: run)?.marks == ["src": "•", "top.txt": "??"])
    #expect(GitStatus.remote(NSTemporaryDirectory(), run: run) == nil, "not a work tree")
}

/// A repo whose own config can run commands gets no git at all — log, blame, stage, here or on a server.
@Test(.enabled(if: GitStatus.available)) func untrustedRepoConfigRunsNothing() throws {
    let repo = repo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    write(repo + "/.gitattributes", "* filter=x\n")
    git(["config", "filter.x.clean", "touch " + repo + "/ran"], in: repo)
    write(repo + "/src/a.txt", "changed\n")
    #expect(GitStatus.history(repo + "/src/a.txt", blame: false) == nil)
    #expect(GitStatus.history(repo + "/src/a.txt", blame: true) == nil)
    #expect(!GitStatus.stage([repo + "/src/a.txt"], in: repo))
    #expect(GitStatus.remote(repo, run: { SSHCommand.output(.local(), $0) }) == nil)
    #expect(!FileManager.default.fileExists(atPath: repo + "/ran"))
}

/// A name starting with ":" is a name, not pathspec magic (":notes" isn't "notes").
@Test(.enabled(if: GitStatus.available)) func gitHistoryAndStageTakeNamesLiterally() throws {
    let repo = repo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    write(repo + "/src/:notes", "colon\n")
    write(repo + "/src/notes", "plain\n")
    git(["add", "src/notes"], in: repo)
    git(["commit", "-q", "-m", "plain notes"], in: repo)
    #expect(GitStatus.stage([repo + "/src/:notes"], in: repo + "/src"))
    git(["commit", "-q", "-m", "colon notes"], in: repo)
    let log = String(decoding: try #require(GitStatus.history(repo + "/src/:notes", blame: false)), as: UTF8.self)
    #expect(log.contains("colon notes") && !log.contains("plain notes"), "\(log)")
}

