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
