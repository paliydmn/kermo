import Foundation
import Testing
@testable import DFMCore

// Task 15, sss-2 (F-01): a save to a server never leaves the file empty — the real /usr/libexec/sftp-server on
// pipes, behind a proxy that breaks the connection or fails a write where a test says.

private nonisolated(unsafe) let fm = FileManager.default

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t15-" + UUID().uuidString
    try! fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func put(_ p: String, _ s: String) { try! Data(s.utf8).write(to: URL(fileURLWithPath: p)) }
private func text(_ p: String) -> String? { fm.contents(atPath: p).map { String(decoding: $0, as: UTF8.self) } }
private func inode(_ p: String) -> ino_t { var st = stat(); lstat(p, &st); return st.st_ino }
private func partials(_ d: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: d)) ?? []).filter { $0.hasPrefix(".dfm-partial-") } }

/// The sftp-server behind a proxy. `bare`: it announces no extensions (no copy-data, no posix-rename — OpenSSH
/// before 9.0 has no copy-data). The first OPEN for writing of a path ending in "/`name`": `drop` passes its handle
/// on and hangs up; `failWrite` answers the first WRITE on that handle with a failure itself.
private func proxy(in dir: String, name: String = "", bare: Bool = false, drop: Bool = false, failWrite: Bool = false) -> String {
    let path = dir + "/sftp-proxy-" + UUID().uuidString.prefix(8)
    try! """
    #!/usr/bin/perl
    use strict; use warnings; use IPC::Open2; use IO::Select;
    my $pid = open2(my $out, my $in, '/usr/libexec/sftp-server');
    binmode($_) for \\*STDIN, \\*STDOUT, $out, $in;
    my ($fromClient, $fromServer, $first, $opened, $failed, %want, $handle) = ('', '', 1, 0, 0);
    sub put { my ($fh, $d) = @_; while (length $d) { my $n = syswrite($fh, $d); die unless defined $n; substr($d, 0, $n) = '' } }
    sub packets { my $b = shift; my @p; while (length $$b >= 4) { my $l = unpack('N', $$b); last if length $$b < 4 + $l; push @p, substr($$b, 0, 4 + $l, '') } @p }
    my $sel = IO::Select->new(\\*STDIN, $out);
    while (my @ready = $sel->can_read) {
        for my $fh (@ready) {
            my $n = sysread($fh, my $chunk, 1 << 16);
            exit 0 unless $n;
            if ($fh == $out) {
                $fromServer .= $chunk;
                for my $p (packets(\\$fromServer)) {
                    my ($type, $id) = unpack('x4 C N', $p);
                    if ($first) { $first = 0; put(\\*STDOUT, \(bare ? "pack('N C N', 5, 2, 3)" : "$p")); next }
                    if ($type == 102 && delete $want{$id}) {
                        $handle = substr($p, 13, unpack('x9 N', $p));
                        if (\(drop ? 1 : 0)) { put(\\*STDOUT, $p); exit 0 }
                    }
                    put(\\*STDOUT, $p);
                }
                next;
            }
            $fromClient .= $chunk;
            for my $p (packets(\\$fromClient)) {
                my ($type, $id) = unpack('x4 C N', $p);
                if ($type == 3 && !$opened) {
                    my $l = unpack('x9 N', $p);
                    my ($path, $flags) = (substr($p, 13, $l), unpack("x13 x$l N", $p));
                    if (($flags & 2) && $path =~ m{/\\Q\(name)\\E$}) { $opened = 1; $want{$id} = 1 }
                }
                if ($type == 6 && \(failWrite ? 1 : 0) && !$failed && defined $handle && substr($p, 13, unpack('x9 N', $p)) eq $handle) {
                    $failed = 1; put(\\*STDOUT, pack('N C N N N N', 17, 101, $id, 4, 0, 0)); next
                }
                put($in, $p);
            }
        }
    }
    """.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    return path
}

/// ⌘S into a symlink (nginx's sites-enabled/*): the new text is renamed over the file it points to — a new inode
/// there, the link still a link, no partial file left in either folder.
@Test func saveIntoASymlinkRenamesOverItsTarget() throws {
    let d = tempDir(), avail = d + "/sites-available", enabled = d + "/sites-enabled"
    defer { try? fm.removeItem(atPath: d) }
    try fm.createDirectory(atPath: avail, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: enabled, withIntermediateDirectories: true)
    put(avail + "/site", "old text\n")
    try fm.createSymbolicLink(atPath: enabled + "/site", withDestinationPath: "../sites-available/site")
    put(d + "/local", "new text\n")
    let c = try SFTPClient(.local())
    defer { c.close() }
    let a = try c.download(enabled + "/site", to: d + "/base")
    let ino = inode(avail + "/site")
    var kept: Data?
    let after = try c.upload(d + "/local", to: enabled + "/site", baseline: a) { _, old in kept = old }
    #expect(try fm.destinationOfSymbolicLink(atPath: enabled + "/site") == "../sites-available/site")
    #expect(text(avail + "/site") == "new text\n")
    #expect(inode(avail + "/site") != ino, "renamed over, not written into")
    #expect(partials(avail).isEmpty && partials(enabled).isEmpty)
    #expect(kept == Data("old text\n".utf8), "the history keeps what it replaced")
    #expect(after.size == 9 && after.kind == .file, "the next baseline is the file's, through the link")
}

/// A symlink to a file not there yet: the save makes it (and the link leads somewhere). One into a folder that isn't
/// ours to write in: the partial file goes next to the link and is copied into the file. Neither is refused.
@Test func saveIntoADanglingOrLockedInLink() throws {
    let d = tempDir(), locked = d + "/locked"
    defer { chmod(locked, 0o755); try? fm.removeItem(atPath: d) }
    try fm.createDirectory(atPath: locked, withIntermediateDirectories: true)
    put(locked + "/f", "old\n")
    chmod(locked, 0o555)
    try fm.createSymbolicLink(atPath: d + "/dangling", withDestinationPath: "missing.conf")
    try fm.createSymbolicLink(atPath: d + "/in-locked", withDestinationPath: "locked/f")
    put(d + "/local", "new\n")
    let c = try SFTPClient(.local())
    defer { c.close() }
    try c.upload(d + "/local", to: d + "/dangling", baseline: .nothing)
    #expect(text(d + "/missing.conf") == "new\n" && (try? fm.destinationOfSymbolicLink(atPath: d + "/dangling")) == "missing.conf")
    let ino = inode(locked + "/f")
    try c.upload(d + "/local", to: d + "/in-locked", baseline: try c.stat(d + "/in-locked"))
    #expect(text(locked + "/f") == "new\n" && inode(locked + "/f") == ino)
    #expect(partials(d).isEmpty && partials(locked).isEmpty)
}

/// A root panel's ⌘S on another owner's file (no SELinux): the partial file gets the file's owner and group, then is
/// renamed over it — a new inode, never a moment as root's. Here the stand-in sudo runs as this user, so "another
/// owner" is another of its groups (the partial file takes its folder's). The user's own panel writes into it.
@Test func rootSaveGivesThePartialTheFilesOwner() throws {
    // This Mac's own temp folder: test.sh's RAM disk ignores owners. A few bytes.
    let d = (Foundation.NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t15-" + UUID().uuidString
    try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: d) }
    var st = stat()
    stat(d, &st)
    var groups = [gid_t](repeating: 0, count: 64)
    let n = Int(getgroups(64, &groups))
    guard let other = groups.prefix(max(0, n)).first(where: { $0 != st.st_gid }) else { return }
    for root in [true, false] {
        let file = d + "/f\(root)"
        put(file, "old text, longer\n")
        chown(file, uid_t.max, other)   // -1: the owner stays
        chmod(file, 0o640)
        put(d + "/local", "new text\n")
        let c = try SFTPClient(root ? .local(sudo: try fakeSudo(d)) : .local())
        defer { c.close() }
        let ino = inode(file)
        try c.upload(d + "/local", to: file, baseline: try c.stat(file))
        var now = stat()
        lstat(file, &now)
        #expect(text(file) == "new text\n" && now.st_gid == other && now.st_mode & 0o7777 == 0o640)
        #expect((now.st_ino != ino) == root, root ? "renamed over" : "written into")
        #expect(partials(d).isEmpty)
    }
}
