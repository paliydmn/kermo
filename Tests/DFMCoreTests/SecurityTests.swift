import Foundation
import Testing
@testable import DFMCore

// Task 3 security findings. Each `withKnownIssue` pins an open
// finding: the test states the secure behaviour, and starts failing loudly once the fix lands.

private func sandbox() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-sec-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
private func sh(_ args: [String], in dir: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
}

/// S1: browsing a folder runs `git status`; a repo's own config must not run commands.
@Test func browsingAGitRepoDoesNotRunItsFsmonitor() {
    let d = sandbox(), marker = d + "/PWNED"
    defer { try? FileManager.default.removeItem(atPath: d) }
    sh(["/usr/bin/git", "init", "-q", "repo"], in: d)
    sh(["/usr/bin/git", "-C", d + "/repo", "config", "core.fsmonitor", "touch '\(marker)'; false"], in: d)
    _ = GitStatus.load(d + "/repo")
    #expect(!FileManager.default.fileExists(atPath: marker))
}

/// S1: `git status` rehashes stat-dirty files through the repo's clean filter (.git/config + .gitattributes).
@Test func browsingAGitRepoDoesNotRunItsCleanFilter() throws {
    let d = sandbox(), repo = d + "/repo", marker = d + "/PWNED"
    defer { try? FileManager.default.removeItem(atPath: d) }
    sh(["/usr/bin/git", "init", "-q", "repo"], in: d)
    try Data("a".utf8).write(to: URL(fileURLWithPath: repo + "/f"))
    sh(["/usr/bin/git", "add", "f"], in: repo)
    sh(["/usr/bin/git", "-c", "user.name=x", "-c", "user.email=x@x", "commit", "-qm", "i"], in: repo)
    sh(["/usr/bin/git", "config", "filter.x.clean", "touch '\(marker)'; cat"], in: repo)
    try Data("* filter=x\n".utf8).write(to: URL(fileURLWithPath: repo + "/.gitattributes"))
    try Data("b".utf8).write(to: URL(fileURLWithPath: repo + "/f"))
    #expect(GitStatus.load(repo) == nil)
    #expect(!FileManager.default.fileExists(atPath: marker))
    sh(["/usr/bin/git", "config", "--unset", "filter.x.clean"], in: repo)
    #expect(GitStatus.load(repo)?.marks["f"] == " M")   // an ordinary repo still gets its git column

    // core.hooksPath (husky) is allowed: the index-writing status that fires post-index-change must not be ours.
    try FileManager.default.createDirectory(atPath: repo + "/.h", withIntermediateDirectories: true)
    try Data("#!/bin/sh\ntouch '\(marker)'\n".utf8).write(to: URL(fileURLWithPath: repo + "/.h/post-index-change"))
    chmod(repo + "/.h/post-index-change", 0o755)
    sh(["/usr/bin/git", "config", "core.hooksPath", ".h"], in: repo)
    try Data("c".utf8).write(to: URL(fileURLWithPath: repo + "/f"))
    #expect(GitStatus.load(repo)?.marks["f"] == " M")
    #expect(!FileManager.default.fileExists(atPath: marker))
}

/// S3: extracting a selected archive entry whose name starts with "-" must not pass it to tar as an option.
@Test func extractingADashNamedEntryIsNotATarOption() throws {
    let d = sandbox()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let name = "--use-compress-program=false"
    FileManager.default.createFile(atPath: d + "/" + name, contents: Data("x".utf8))
    sh(["/usr/bin/tar", "-cf", d + "/a.tar", "--", name], in: d)
    let index = try ArchiveIndex.read(d + "/a.tar")
    #expect(index.list("")?.map(\.name) == [name])
    try index.extract([name], from: "", to: d + "/out")
    #expect(FileManager.default.fileExists(atPath: d + "/out/" + name))
}

/// S4 (real run): F5 to an SFTP panel used to run `zsh -lc` with an sftp batch in a heredoc; a local file name
/// holding a line "DFM_SFTP_EOF" closed it, and the rest of the name ran as shell commands. Now no shell is
/// involved: the name travels as bytes in an SFTP packet and arrives whole.
@Test func uploadOfANameWithHeredocTerminatorRunsNoShellCommand() throws {
    let d = sandbox()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let name = "report\nDFM_SFTP_EOF\ntouch PWNED #"
    try Data("x".utf8).write(to: URL(fileURLWithPath: d + "/" + name))
    try FileManager.default.createDirectory(atPath: d + "/remote", withIntermediateDirectories: true)
    let job = FileJob(.copy, sources: [d + "/" + name], from: .local, to: .sftp(.local()), destDir: d + "/remote")
    job.run()
    #expect(job.progress.errors.isEmpty, "\(job.progress.errors)")
    #expect(FileManager.default.contents(atPath: d + "/remote/" + name) == Data("x".utf8))
    #expect(!FileManager.default.fileExists(atPath: d + "/PWNED") && !FileManager.default.fileExists(atPath: d + "/remote/PWNED"))
}

/// S7: names reach `zsh -lc` (user menu, ⌘E) through ShellContext.quote; zsh expands a leading `=`,
/// and a leading `-` turns a file name into an option.
@Test func shellQuoteNeutralisesZshEqualsAndLeadingDash() {
    #expect(ShellContext.quote("=ls") == "'=ls'")
    #expect(ShellContext.quote("a=b") == "a=b")
    #expect(ShellContext(dir: "/d", otherDir: "/o", cursor: "-rf", targets: ["-rf", "--x y"]).expand("rm %s; ls %f %F")
            == "rm ./-rf './--x y'; ls ./-rf /d/-rf")
}

/// S2: the ⌃O terminal types `cd <quoted path>` into the shell; C0 controls in a folder name (^C, ^U, ^D…)
/// act on the line editor before the shell sees the quotes, so the rest of the name runs as a command.
@Test func terminalCdLineCarriesNoControlCharacters() {
    #expect(ShellContext.typedCd("/tmp/dir-\u{3}touch PWNED\r") == nil)
    #expect(ShellContext.typedCd("/tmp/dir-\u{7f}x") == nil)
    #expect(ShellContext.typedCd("/tmp/it's ü") == "\u{15} cd '/tmp/it'\\''s ü'\r")
}

/// F4: Sync "compare by content" must not open FIFOs (open blocks forever without a writer).
@Test(.timeLimit(.minutes(1))) func syncByContentDoesNotHangOnFifos() async {
    let d = sandbox()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for side in ["l", "r"] {
        try! FileManager.default.createDirectory(atPath: d + "/" + side, withIntermediateDirectories: true)
        #expect(mkfifo(d + "/\(side)/pipe", 0o644) == 0)
    }
    let finished = QAFlag()
    Thread { _ = DirSync.compare(left: d + "/l", right: d + "/r", byContent: true); finished.set() }.start()
    for _ in 0..<30 where !finished.value { try? await Task.sleep(for: .milliseconds(100)) }
    #expect(finished.value)
    if !finished.value {   // unblock the stuck open() so the thread can end
        for side in ["l", "r"] { if let h = FileHandle(forWritingAtPath: d + "/\(side)/pipe") { try? h.close() } }
    }
}

/// S8: highlighting runs on every viewer/editor open; a crafted file must not pin a core for long.
@Test(arguments: [("/* x\n", Syntax.Language.clike), ("<!-- x\n", .xml), ("<![CDATA[ x\n", .xml)])   // (""" pairs up with itself)
func syntaxHighlightOfUnterminatedCommentsIsBounded(opener: String, lang: Syntax.Language) {
    let text = String(repeating: opener, count: 8_000)   // 8k openers, no closer (200 KB of "/* x" took 27 s)
    let t0 = Date()
    let tokens = Syntax.tokens(text, lang)
    let secs = Date().timeIntervalSince(t0)
    #expect(secs < 0.2, "highlighting \(text.utf16.count / 1000) KB took \(secs) s")
    #expect(tokens.first.map { NSMaxRange($0.range) } == text.utf16.count)   // unclosed: runs to the end, like editors
}

/// S12: a right-to-left override must not make "…exe" look like "…txt" in the listing.
@Test func bidiControlsInNamesAreShownNotApplied() {
    let it = FileItem(name: "rtl-\u{202E}txt.exe", kind: .file, size: 0, mtime: 0, mode: 0, flags: 0)
    #expect(it.displayName == "rtl-⟨U+202E⟩txt.exe")
    #expect(FileItem(name: "plain ü.txt", kind: .file, size: 0, mtime: 0, mode: 0, flags: 0).displayName == "plain ü.txt")
}

final class QAFlag: @unchecked Sendable {
    private let l = NSLock(); private var v = false
    var value: Bool { l.withLock { v } }
    func set() { l.withLock { v = true } }
}
