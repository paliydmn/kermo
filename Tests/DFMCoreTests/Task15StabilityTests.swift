import Foundation
@testable import DFMCore
import Testing

/// Task 15 sss-6: small stability holes — hostile servers, leftovers.

nonisolated(unsafe) private let fm = FileManager.default

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-sss6-" + UUID().uuidString
    try! fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// T-04: sizes added up stay at `Int64.max` instead of trapping past it.
@Test func sizesSaturate() {
    #expect(Int64.max.saturatingAdd(1) == .max)
    #expect(Int64.max.saturatingAdd(.max) == .max)
    #expect(Int64(2).saturatingAdd(3) == 5)
    #expect(Int64.min.saturatingAdd(-1) == .min)
}

/// A server that says every file is `Int64.max` bytes (a hostile or broken sftp-server: `Reader.attrs` clamps each).
private final class HugeSizes: TransferFS, @unchecked Sendable {
    let fs = LocalFS()
    func huge(_ a: SFTPClient.Attrs) -> SFTPClient.Attrs { var a = a; if a.kind == .file { a.size = .max }; return a }
    func lstat(_ path: String) throws -> SFTPClient.Attrs? { try fs.lstat(path).map(huge) }
    func list(_ dir: String) throws -> [(name: String, attrs: SFTPClient.Attrs)] { try fs.list(dir).map { ($0.name, huge($0.attrs)) } }
    func mkdir(_ path: String) throws { try fs.mkdir(path) }
    func remove(_ path: String) throws { try fs.remove(path) }
    func rmdir(_ path: String) throws { try fs.rmdir(path) }
    func rename(_ from: String, _ to: String, replace: Bool) throws { try fs.rename(from, to, replace: replace) }
    func readlink(_ path: String) throws -> String { try fs.readlink(path) }
    func realpath(_ path: String) throws -> String { try fs.realpath(path) }
    func symlink(_ destination: String, at link: String) throws { try fs.symlink(destination, at: link) }
    func setAttrs(_ path: String, mtime: Double?, mode: UInt32?) throws { try fs.setAttrs(path, mtime: mtime, mode: mode) }
    func reader(_ path: String, offset: Int64, size: Int64) throws -> PieceReader { try fs.reader(path, offset: offset, size: size) }
    func writer(_ path: String, offset: Int64) throws -> PieceWriter { try fs.writer(path, offset: offset) }
    func close() {}
}

/// T-04: ⌥Space on a server folder, or the "Scanning…" of a copy from it, added such sizes with `+=`: a trap. Two
/// files in a folder, a folder below it with one more, two of them copied: each sum stays at `Int64.max`.
@Test func hugeServerSizesDontOverflowAMeasure() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    for t in ["a", "b"] {
        try fm.createDirectory(atPath: d + "/\(t)/sub", withIntermediateDirectories: true)
        for f in ["/x", "/y", "/sub/z"] { fm.createFile(atPath: d + "/\(t)" + f, contents: Data("1".utf8)) }
    }
    let m = FileJob(.copy, sources: []).measure(HugeSizes(), d + "/a")
    #expect(m.files == 3 && m.bytes == .max)

    try fm.createDirectory(atPath: d + "/to", withIntermediateDirectories: true)
    let job = FileJob(.copy, sources: [d + "/a", d + "/b"], from: .sftp(.local()), to: .local, destDir: d + "/to")
    job.runAcross(HugeSizes())
    #expect(job.progress.totalFiles == 6 && job.progress.totalBytes == .max)
    #expect(job.progress.doneBytes == .max, "\(job.progress.errors)")
}

/// The sftp-server behind a proxy that sends each of its answers twice, and after each an answer to a request
/// never made.
private func chattyServer(in dir: String) -> String {
    let path = dir + "/sftp-chatty"
    try! """
    #!/usr/bin/perl
    use strict; use warnings; use IPC::Open2; use IO::Select;
    my $pid = open2(my $out, my $in, '/usr/libexec/sftp-server');
    binmode($_) for \\*STDIN, \\*STDOUT, $out, $in;
    my ($fromServer, $first, $k) = ('', 1, 0);
    sub put { my ($fh, $d) = @_; while (length $d) { my $n = syswrite($fh, $d); die unless defined $n; substr($d, 0, $n) = '' } }
    my $sel = IO::Select->new(\\*STDIN, $out);
    while (my @ready = $sel->can_read) {
        for my $fh (@ready) {
            my $n = sysread($fh, my $chunk, 1 << 16);
            exit 0 unless $n;
            if ($fh != $out) { put($in, $chunk); next }
            $fromServer .= $chunk;
            while (length $fromServer >= 4 && length $fromServer >= 4 + unpack('N', $fromServer)) {
                my $p = substr($fromServer, 0, 4 + unpack('N', $fromServer), '');
                put(\\*STDOUT, $p);
                if ($first) { $first = 0; next }
                put(\\*STDOUT, $p . pack('N C N N N N', 17, 101, 0x7f000000 + $k++, 0, 0, 0));
            }
        }
    }
    """.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    return path
}

/// T-06: an answer to a request never made, or one answered already, stayed in the session's `responses` for
/// good (up to 1 MiB each, a session lives on). They're dropped now; the session goes on working.
@Test func answersNobodyAskedForArentKept() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let c = try SFTPClient(.local(sudo: try fakeSudo(d, #"[ "$1" = -n ] || exit 2; exec \#(chattyServer(in: d))"#), selinux: true))
    defer { c.close() }
    for _ in 0..<20 { #expect(try c.lstat(d)?.kind == .dir) }
    #expect(try c.list(d).map(\.name).contains("sftp-chatty"))
    #expect(c.heldAnswers == 0)
}

/// T-06: answers piling up past `heldLimit` (a hostile server holding 1 MiB an answer for every request in flight)
/// end the session with a protocol error, as other breaches do; the next call throws instead of waiting.
@Test func answersPilingUpEndTheSession() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    for i in 0..<50 { fm.createFile(atPath: d + "/file-with-a-longish-name-\(i)", contents: nil) }
    let c = try SFTPClient(.local())
    defer { c.close() }
    c.heldLimit = 100
    let e = #expect(throws: SFTPError.self) { try c.list(d) }
    #expect(e?.message.contains("protocol error") == true, "\(e?.message ?? "")")
    #expect(throws: SFTPError.self) { try c.lstat(d) }
}

/// T-11: when /tmp/dfm-ssh-<uid> isn't ours, each run made a random folder there and left it behind. Only that one
/// is removed at quit; a predictable one that is ours stays (the next run, or another Kermo, uses it).
@Test func onlyARandomControlDirIsRemoved() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let ours = SFTP.controlDir(predictable: d + "/ours")
    #expect(ours == (d + "/ours", false))
    SFTP.removeControlDir(ours)
    #expect(fm.fileExists(atPath: d + "/ours"))

    try fm.createSymbolicLink(atPath: d + "/swapped", withDestinationPath: d + "/ours")   // not a folder of ours
    let random = SFTP.controlDir(predictable: d + "/swapped")
    defer { if random.dir.hasPrefix("/tmp/dfm-ssh-") { try? fm.removeItem(atPath: random.dir) } }
    #expect(random.random && random.dir.hasPrefix("/tmp/dfm-ssh-") && random.dir != SFTP.controlDir)
    fm.createFile(atPath: random.dir + "/askpass", contents: nil)
    SFTP.removeControlDir(random)
    #expect(!fm.fileExists(atPath: random.dir))
    #expect(fm.fileExists(atPath: d + "/ours"))
}

/// S-05: Copy/Move as Administrator ran ditto/mv as root without what F5/F6 look at first.
@Test func adminCopyChecksWhatF5Checks() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    try fm.createDirectory(atPath: d + "/Work/backup", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: d + "/shared", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: d + "/to", withIntermediateDirectories: true)
    fm.createFile(atPath: d + "/a.txt", contents: Data("a".utf8))
    fm.createFile(atPath: d + "/to/a.txt", contents: Data("old".utf8))
    try fm.createSymbolicLink(atPath: d + "/shared/Work", withDestinationPath: "/etc")
    let work = [d + "/Work"]
    for dest in [d + "/Work", d + "/Work/backup", d + "/Work/backup/new/deeper", d + "/WORK/backup"] {
        #expect(AdminCommand.check(work, to: dest, move: false).refusal == "Cannot copy a folder into itself", "\(dest)")
    }
    #expect(AdminCommand.check(work, to: d + "/Work/backup", move: true).refusal == "Cannot move a folder into itself")
    #expect(AdminCommand.check(work, to: d + "/shared", move: false).refusal == "“Work” in \(d)/shared is a link — not followed as root")
    #expect(AdminCommand.check([d + "/a.txt"], to: d, move: false).refusal == "“a.txt” is in \(d) already")
    #expect(AdminCommand.check([d + "/a.txt", d + "/Work"], to: d + "/to", move: false) == (nil, ["a.txt"]))
    #expect(AdminCommand.check(work, to: d + "/elsewhere/new", move: false) == (nil, []))
}

/// T-08: `ssh -O exit` to a master that stopped answering waited for good — and Quit with it. A stand-in ssh that
/// hangs is cut off after `stopWait`.
@Test func stoppingAHungMasterReturns() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let ssh = d + "/ssh"
    try Data("#!/bin/sh\necho \"$*\" > '\(d)/args'\nexec sleep 60\n".utf8).write(to: URL(fileURLWithPath: ssh))
    chmod(ssh, 0o755)
    let t = SFTPTarget(host: "me@dfm-hung-\(UUID().uuidString.prefix(8)).invalid")
    SFTP.noteMaster(t)
    let start = Date()
    SFTP.stopMaster(t, now: true, ssh: ssh)
    let took = Date().timeIntervalSince(start)
    #expect(took >= SFTP.stopWait - 0.5 && took < SFTP.stopWait + 2, "\(took)")
    #expect(try String(contentsOfFile: d + "/args", encoding: .utf8).contains("-O exit"))
    #expect(!SFTP.masterTargets.contains(t))
}

/// D-063: an extract cut short by Quit (tar stopped, its question open) left its hidden staging folder — as big as the
/// archive — until a later extract there a day on. A quit removes those still in use; one already done isn't touched.
@Test func aQuitRemovesStagingFoldersInUse() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let running = ArchiveIndex.stagingFolder(in: d), done = ArchiveIndex.stagingFolder(in: d)
    for s in [running, done] { try fm.createDirectory(atPath: s + "/ro", withIntermediateDirectories: true) }
    fm.createFile(atPath: running + "/ro/big", contents: Data(count: 1000))
    chmod(running + "/ro", 0o555)   // tar makes such folders
    ArchiveIndex.discardStaging(done)
    try fm.createDirectory(atPath: done, withIntermediateDirectories: true)   // a name a later run might reuse: not ours now
    ArchiveIndex.discardLiveStaging(under: d)
    #expect(!fm.fileExists(atPath: running))
    #expect(fm.fileExists(atPath: done))
}

private func footprint() -> Int64 {
    var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return r == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}

/// sss-1's tail: a zip's one name 20 000 folders deep (40 KB) kept every folder's full path as a key — n²/2 bytes,
/// some 400 MB (a pax tar's name can be any length). By component it's a few MB, and every folder still lists.
@Test func aDeepArchiveTakesLittleMemory() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["-I", "-c", "import zipfile; zipfile.ZipFile('d.zip', 'w').writestr('a/' * 20000 + 'x.txt', 'X')"]
    p.currentDirectoryURL = URL(fileURLWithPath: d)
    try p.run()
    p.waitUntilExit()
    let before = footprint()
    let idx = try ArchiveIndex.read(d + "/d.zip")
    let grew = footprint() - before
    #expect(grew < 100 << 20, "\(grew >> 20) MB")
    let inner = Array(repeating: "a", count: 20000).joined(separator: "/")
    #expect(idx.list(inner)?.map(\.name) == ["x.txt"])
    #expect(idx.list("a/a")?.map(\.name) == ["a"] && idx.list("a/b") == nil && idx.list("")?.first?.kind == .dir)
}

private func sh(_ command: String) -> (status: Int32, err: String) {
    let p = Process(), err = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    p.standardError = err
    try? p.run()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

/// D-080: root's write in Save as Administrator came after a shell check for a link, two steps apart: a link (or
/// another file) swapped in between was written through as root. The write itself now opens without following a
/// link and checks the inode it opened. Run here as us, each case right at the write.
@Test func theRootWriteNeverFollowsALinkSwappedIn() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    try Data("NEW TEXT".utf8).write(to: URL(fileURLWithPath: d + "/new"))
    try Data("old text, longer\n".utf8).write(to: URL(fileURLWithPath: d + "/target"))
    try Data("someone else's\n".utf8).write(to: URL(fileURLWithPath: d + "/elsewhere"))
    var st = stat()
    lstat(d + "/target", &st)
    let (ino, size) = ("\(st.st_ino)", "\(st.st_size)")
    func write(inode: String?, size: String?) -> (status: Int32, err: String) {
        sh(AdminCommand.writeOver(d + "/target", from: ShellContext.quote(d + "/new"), inode: inode, size: size, length: 8))
    }

    #expect(write(inode: ino, size: size).status == 0)
    #expect(fm.contents(atPath: d + "/target") == Data("NEW TEXT".utf8), "written over, cut to length")

    try Data("old text, longer\n".utf8).write(to: URL(fileURLWithPath: d + "/target"))
    lstat(d + "/target", &st)
    try fm.removeItem(atPath: d + "/target")
    try fm.createSymbolicLink(atPath: d + "/target", withDestinationPath: d + "/elsewhere")   // swapped in
    let link = write(inode: "\(st.st_ino)", size: "\(st.st_size)")
    #expect(link.status != 0 && link.err.contains(AdminCommand.isLink), "\(link)")
    #expect(fm.contents(atPath: d + "/elsewhere") == Data("someone else's\n".utf8))

    try fm.removeItem(atPath: d + "/target")
    try fm.linkItem(atPath: d + "/elsewhere", toPath: d + "/target")   // another file under the name, a hard link
    let other = write(inode: "\(st.st_ino)", size: "\(st.st_size)")
    #expect(other.status != 0 && other.err.contains(AdminCommand.changedOnDisk), "\(other)")
    #expect(fm.contents(atPath: d + "/elsewhere") == Data("someone else's\n".utf8))

    let made = write(inode: nil, size: nil)   // "a new file" while one is there: never written over
    #expect(made.status != 0 && made.err.contains(AdminCommand.changedOnDisk), "\(made)")
    try fm.removeItem(atPath: d + "/target")
    #expect(write(inode: nil, size: nil).status == 0 && fm.contents(atPath: d + "/target") == Data("NEW TEXT".utf8))
}

/// S-05's race: a link put at destDir/<name> after the check (a folder of the user's that root copies into) sent
/// ditto's copy wherever it pointed. New items and replaced files go through a folder of root's own, then rename:
/// over a link, never through it. A folder already there is merged into, as ditto did. Run here as us.
@Test func anAdminCopyRenamesOverALinkNeverThroughIt() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    for p in ["/src/dir", "/dest/merge", "/elsewhere", "/src/merge"] { try fm.createDirectory(atPath: d + p, withIntermediateDirectories: true) }
    fm.createFile(atPath: d + "/src/f", contents: Data("new f".utf8))
    fm.createFile(atPath: d + "/src/dir/in", contents: Data("in".utf8))
    fm.createFile(atPath: d + "/src/merge/a", contents: Data("a".utf8))
    fm.createFile(atPath: d + "/dest/merge/kept", contents: Data("kept".utf8))
    fm.createFile(atPath: d + "/elsewhere/f", contents: Data("theirs".utf8))
    try fm.createSymbolicLink(atPath: d + "/dest/f", withDestinationPath: d + "/elsewhere/f")   // swapped in after check
    try fm.createSymbolicLink(atPath: d + "/dest/dir", withDestinationPath: d + "/elsewhere")

    let r = sh(AdminCommand.copy([d + "/src/f", d + "/src/merge"], to: d + "/dest"))
    #expect(r.status == 0, "\(r.err)")
    #expect(fm.contents(atPath: d + "/elsewhere/f") == Data("theirs".utf8), "not written through the link")
    #expect(fm.contents(atPath: d + "/dest/f") == Data("new f".utf8) && (try? fm.destinationOfSymbolicLink(atPath: d + "/dest/f")) == nil)
    #expect(fm.contents(atPath: d + "/dest/merge/kept") != nil && fm.contents(atPath: d + "/dest/merge/a") == Data("a".utf8), "merged")

    let dir = sh(AdminCommand.copy([d + "/src/dir"], to: d + "/dest"))
    #expect(dir.status != 0, "a folder onto a link: refused")
    #expect(try fm.contentsOfDirectory(atPath: d + "/elsewhere") == ["f"])
    #expect(try fm.contentsOfDirectory(atPath: d + "/dest").sorted() == ["dir", "f", "merge"], "no root folder left behind")
}

/// D-084: the mount points in /proc/self/mounts, with its octal escapes.
@Test func serverMountPointsAreRead() {
    let text = "/dev/sda1 / ext4 rw 0 0\nnas:/v /mnt/my\\040share nfs4 rw 0 0\ntmpfs /run/a\\134b tmpfs rw 0 0\n\n"
    #expect(FileJob.mounts(text) == ["/mnt/my share", "/run/a\\b"])
}

/// D-084: ⇧F8 on a server walked into a share mounted inside the folder (an NFS home, a bind mount) and emptied it;
/// a move off a server deleted it after copying it. Both stop there now, as on this Mac, and say so. A move from
/// this Mac to a server too. The server here is this Mac's sftp-server; its mount list a file of the test's.
@Test func serverDeletesAndMovesStopAtMountPoints() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    for p in ["/srv/tree/mnt", "/srv/tree/sub", "/mac", "/up/tree/mnt"] { try fm.createDirectory(atPath: d + p, withIntermediateDirectories: true) }
    for p in ["/srv/tree/mnt/precious", "/srv/tree/sub/f", "/srv/tree/g", "/up/tree/mnt/precious", "/up/tree/g"] { fm.createFile(atPath: d + p, contents: Data("x".utf8)) }
    try Data("nas:/v \(d)/srv/tree/mnt nfs4 rw 0 0\n".utf8).write(to: URL(fileURLWithPath: d + "/mounts"))

    let del = FileJob(.delete, sources: [d + "/srv/tree"], from: .sftp(.local()), to: .sftp(.local()), destDir: nil)
    del.mountsFile = d + "/mounts"
    del.runAcross()
    #expect(fm.fileExists(atPath: d + "/srv/tree/mnt/precious"))
    #expect(!fm.fileExists(atPath: d + "/srv/tree/sub") && !fm.fileExists(atPath: d + "/srv/tree/g"))
    #expect(del.progress.errors == ["\(d)/srv/tree/mnt: another volume is mounted here — skipped"])

    fm.createFile(atPath: d + "/srv/tree/g", contents: Data("x".utf8))
    let down = FileJob(.move, sources: [d + "/srv/tree"], from: .sftp(.local()), to: .local, destDir: d + "/mac")
    down.mountsFile = d + "/mounts"
    down.runAcross()
    #expect(fm.fileExists(atPath: d + "/srv/tree/mnt/precious") && !fm.fileExists(atPath: d + "/mac/tree/mnt"))
    #expect(fm.fileExists(atPath: d + "/mac/tree/g") && !fm.fileExists(atPath: d + "/srv/tree/g"))
    #expect(down.progress.errors == ["\(d)/srv/tree/mnt: another volume is mounted here — skipped"])

    try fm.createDirectory(atPath: d + "/to", withIntermediateDirectories: true)
    let up = FileJob(.move, sources: [d + "/up/tree"], from: .local, to: .sftp(.local()), destDir: d + "/to")
    up.crossesVolume = { p, _, _ in p.hasSuffix("/mnt") }
    up.runAcross()
    #expect(fm.fileExists(atPath: d + "/up/tree/mnt/precious") && !fm.fileExists(atPath: d + "/to/tree/mnt"))
    #expect(fm.fileExists(atPath: d + "/to/tree/g") && !fm.fileExists(atPath: d + "/up/tree/g"))
}
