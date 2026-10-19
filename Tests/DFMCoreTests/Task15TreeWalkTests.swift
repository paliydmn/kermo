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

/// F-10: on a server a file replacing a folder (or a folder a file) is copied whole under a temporary name first;
/// the old one goes only then. A copy that fails (an unreadable source) leaves the old one as it was — before, the
/// folder was deleted first, so neither was left — and no temporary copy behind.
@Test func replacingAFolderWithAFileOnAServerKeepsItUntilTheNewOneIsWhole() throws {
    let d = tempDir()
    defer { sh("chmod -R u+rw .", in: d); try? FileManager.default.removeItem(atPath: d) }
    func copy(_ name: String) -> FileJob {
        let job = FileJob(.copy, sources: [d + "/src/" + name], from: .local, to: .sftp(.local()), destDir: d + "/dst")
        job.resolveConflict = { _ in (.overwrite, true) }
        job.resolveError = { _, _ in (.skip, false) }
        job.run()
        return job
    }
    func names() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: d + "/dst").sorted()) ?? [] }
    sh("mkdir -p src/dir dst/file dst/dir && echo new > src/file && echo old > dst/file/a && echo new > src/dir/b && echo old > dst/dir2", in: d)
    sh("rmdir dst/dir && mv dst/dir2 dst/dir", in: d)   // dst: file/ is a folder, dir is a file

    sh("chmod 000 src/file", in: d)
    #expect(!copy("file").progress.errors.isEmpty)
    #expect(exists(d + "/dst/file/a") && names() == ["dir", "file"], "the old folder stays, nothing left beside it")
    sh("chmod 644 src/file && echo bad > src/dir/c && chmod 000 src/dir/c", in: d)
    #expect(!copy("dir").progress.errors.isEmpty)
    #expect(FileJob.lstat(d + "/dst/dir").map { $0.st_mode & S_IFMT == S_IFREG } == true && names() == ["dir", "file"], "the old file stays")

    sh("chmod 644 src/dir/c && rm src/dir/c", in: d)
    #expect(copy("file").progress.errors.isEmpty && copy("dir").progress.errors.isEmpty)
    #expect(FileJob.lstat(d + "/dst/file").map { $0.st_mode & S_IFMT == S_IFREG } == true && exists(d + "/dst/dir/b"))
    #expect(names() == ["dir", "file"])
}

/// F-13: ⇧F8 stops at a volume mounted inside the tree, as `rm -r --one-file-system` does: what's on it stays, so
/// does the folder it's mounted in and the ones above, and the summary names it. (A folder stands in for the mount
/// point: mounting one in a test asks for Touch ID.)
@Test func deleteStopsAtAMountPoint() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    sh("mkdir -p top/mnt top/sub && echo x > top/mnt/x && echo y > top/sub/y && echo a > top/a.txt", in: d)
    let job = FileJob(.delete, sources: [d + "/top"])
    job.crossesVolume = { p, m, dev in p.hasSuffix("/top/mnt") || DirLister.crosses(p, m, dev) }
    job.resolveError = { p, m in Issue.record("asked: \(p): \(m)"); return (.skip, false) }
    job.run()
    #expect(exists(d + "/top/mnt/x") && !exists(d + "/top/sub") && !exists(d + "/top/a.txt"))
    #expect(job.progress.errors == [d + "/top/mnt: another volume is mounted here — skipped"])
}

/// F-13: F6 to another volume copies and deletes item by item; it stops at a volume mounted inside too (moving it
/// would empty it). The rest moves, the folders that hold it stay. This Mac's disk → the RAM disk test.sh makes.
@Test(.enabled(if: FileManager.default.isWritableFile(atPath: "/Volumes/KermoRAM")))
func aMoveToAnotherVolumeStopsAtAMountPoint() throws {
    let src = Foundation.NSTemporaryDirectory() + "k15mnt-" + UUID().uuidString   // this Mac's volume, a few bytes
    let dst = "/Volumes/KermoRAM/k15mnt-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: src); try? FileManager.default.removeItem(atPath: dst) }
    try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
    sh("mkdir -p t/mnt t/sub && echo x > t/mnt/x && echo y > t/sub/y", in: src)
    let job = FileJob(.move, sources: [src + "/t"], destDir: dst)
    job.crossesVolume = { p, m, dev in p.hasSuffix("/t/mnt") || DirLister.crosses(p, m, dev) }
    job.run()
    #expect(exists(dst + "/t/sub/y") && !exists(dst + "/t/mnt") && !exists(src + "/t/sub"))
    #expect(exists(src + "/t/mnt/x"), "what's on it stays where it is")
    #expect(job.progress.errors == [src + "/t/mnt: another volume is mounted here — skipped"])
}
