import Foundation
import Testing
@testable import DFMCore

/// Task 15 sss-5: walks of a tree — as root on a server, across mount points, after Compare.

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-sss5-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func sh(_ c: String, in dir: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", c]
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    try! p.run()
    p.waitUntilExit()
}

private func exists(_ p: String) -> Bool { FileJob.lstat(p) != nil }

/// S-03: a root panel doesn't go into a folder someone else can change — group or others may write without the
/// sticky bit, or it isn't root's. Delete keeps it (and the folders above), copy leaves it out, a folder isn't copied
/// into a `destDir` like that; each is named once, nothing asked. The stand-in sudo runs as this Mac's user, who is
/// "root" here unless `rootUID` says otherwise.
@Test func aRootSessionDoesntGoIntoFoldersOthersCanChange() throws {
    let d = tempDir()
    defer { sh("chmod -R u+w .", in: d); try? FileManager.default.removeItem(atPath: d) }
    let root = SFTPTarget.local(sudo: try fakeSudo(d))
    func tree() {
        sh("rm -rf top && mkdir -p top/ok top/open top/group top/sticky && for f in ok open group sticky; do echo x > top/$f/f; done"
           + " && chmod 777 top/open && chmod 775 top/group && chmod 1777 top/sticky", in: d)
    }
    func ask(_ job: FileJob) -> FileJob {
        job.resolveError = { p, m in Issue.record("asked: \(p): \(m)"); return (.skip, false) }
        job.run()
        return job
    }
    let said = { (p: String) in "\(p): someone else on the server can change this folder — not entered as root. Do it as its owner, or in a terminal there" }

    tree()
    var job = ask(FileJob(.delete, sources: [d + "/top"], from: .sftp(root), to: .sftp(root), destDir: nil))
    #expect(!exists(d + "/top/ok") && !exists(d + "/top/sticky"), "entered and deleted")
    #expect(exists(d + "/top/open/f") && exists(d + "/top/group/f") && exists(d + "/top"), "kept, with the folder above")
    #expect(job.progress.errors.sorted() == [said(d + "/top/group"), said(d + "/top/open")])

    tree()
    sh("mkdir out", in: d)
    job = ask(FileJob(.copy, sources: [d + "/top"], from: .sftp(root), to: .local, destDir: d + "/out"))
    #expect(exists(d + "/out/top/ok/f") && exists(d + "/out/top/sticky/f"))
    #expect(!exists(d + "/out/top/open") && !exists(d + "/out/top/group"))
    #expect(job.progress.errors.sorted() == [said(d + "/top/group"), said(d + "/top/open")])

    // into a folder its owner (or anyone) can change: no folder, a file still goes (partial, then rename)
    sh("mkdir shared && chmod 777 shared && echo y > one.txt", in: d)
    job = ask(FileJob(.copy, sources: [d + "/top/ok", d + "/one.txt"], from: .local, to: .sftp(root), destDir: d + "/shared"))
    #expect(!exists(d + "/shared/ok") && exists(d + "/shared/one.txt"))
    #expect(job.progress.errors == [said(d + "/shared")])

    // owned by someone else: not root's, so not even the top is gone into
    tree()
    let real = SFTPTarget.local(sudo: try fakeSudo(d), rootUID: 0)
    job = ask(FileJob(.delete, sources: [d + "/top"], from: .sftp(real), to: .sftp(real), destDir: nil))
    #expect(exists(d + "/top/ok/f") && job.progress.errors == [said(d + "/top")])

    // the user's own session goes everywhere, as before
    job = ask(FileJob(.delete, sources: [d + "/top"], from: .sftp(.local()), to: .sftp(.local()), destDir: nil))
    #expect(!exists(d + "/top") && job.progress.errors.isEmpty)
}
