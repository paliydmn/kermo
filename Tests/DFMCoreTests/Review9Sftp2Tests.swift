import Foundation
import Testing
@testable import DFMCore

// Task 9 QA follow-up, servers (R4, R20, R21, R22): the real /usr/libexec/sftp-server on pipes, in temp folders.

private nonisolated(unsafe) let fm = FileManager.default

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9sftp2-" + UUID().uuidString
    try! fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func put(_ p: String, _ s: String) { try! Data(s.utf8).write(to: URL(fileURLWithPath: p)) }
private func text(_ p: String) -> String? { fm.contents(atPath: p).map { String(decoding: $0, as: UTF8.self) } }

/// R4: renaming only by case works on a server whose disk ignores case (Foo and foo are one file there), and
/// still refuses a name taken by another item. Nothing is deleted, no temporary name is left behind.
@Test func renameOnlyByCaseOnAServer() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let c = try SFTPClient(.local())
    defer { c.close() }
    put(d + "/Foo", "foo's")
    put(d + "/bar", "bar's")
    try fm.createDirectory(atPath: d + "/Dir", withIntermediateDirectories: true)   // the server renames folders another way
    let ignoresCase = try c.lstat(d + "/foo") != nil
    if ignoresCase {
        try c.rename(d + "/Foo", d + "/foo")
        try c.rename(d + "/Dir", d + "/dir")
        #expect(try fm.contentsOfDirectory(atPath: d).sorted() == ["bar", "dir", "foo"])
        #expect(text(d + "/foo") == "foo's")
    } else {
        put(d + "/foo", "another")
        #expect(throws: (any Error).self) { try c.rename(d + "/Foo", d + "/foo") }
        #expect(text(d + "/Foo") == "foo's" && text(d + "/foo") == "another")
    }
    let name = ignoresCase ? "foo" : "Foo"
    let e = #expect(throws: (any Error).self) { try c.rename(d + "/" + name, d + "/bar") }
    #expect(e?.localizedDescription.contains("already exists") == true, "\(String(describing: e))")
    #expect(text(d + "/" + name) == "foo's" && text(d + "/bar") == "bar's")
    #expect(try !fm.contentsOfDirectory(atPath: d).contains { $0.hasPrefix(".dfm-") })
}

/// An sftp-server behind a proxy that hides its extensions (no posix-rename), as some servers have none.
private func serverWithoutExtensions(in dir: String) -> SFTPTarget {
    let path = dir + "/sftp-no-extensions"
    try! """
    #!/usr/bin/perl
    use strict; use warnings; use IPC::Open2; use IO::Select;
    my $pid = open2(my $out, my $in, '/usr/libexec/sftp-server');
    binmode($_) for \\*STDIN, \\*STDOUT, $out, $in;
    sub put { my ($fh, $d) = @_; while (length $d) { my $n = syswrite($fh, $d); die unless defined $n; substr($d, 0, $n) = '' } }
    my ($version, $first) = ('', 1);
    my $sel = IO::Select->new(\\*STDIN, $out);
    while (my @ready = $sel->can_read) {
        for my $fh (@ready) {
            my $n = sysread($fh, my $chunk, 1 << 16);
            exit 0 unless $n;
            if ($fh != $out) { put($in, $chunk); next }
            unless ($first) { put(\\*STDOUT, $chunk); next }
            $version .= $chunk;
            next if length $version < 4 || length $version < 4 + unpack('N', $version);
            substr($version, 0, 4 + unpack('N', $version), '');
            put(\\*STDOUT, pack('N C N', 5, 2, 3) . $version);
            $first = 0;
        }
    }
    """.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    return .local(server: path)
}

/// R4: renaming over an existing name on a server without posix-rename (remove it, then rename) — F6 → Overwrite.
/// A name differing only in case may be the item itself there: it's renamed, not deleted as "the one in the way".
@Test func replacingRenameOnlyByCaseWithoutPosixRename() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let c = try SFTPClient(serverWithoutExtensions(in: d))
    defer { c.close() }
    try #require(c.extensions["posix-rename@openssh.com"] == nil)
    put(d + "/Foo", "foo's")
    put(d + "/bar", "bar's")
    put(d + "/baz", "baz's")
    let ignoresCase = try c.lstat(d + "/foo") != nil
    if !ignoresCase { put(d + "/foo", "another") }
    try c.rename(d + "/Foo", d + "/foo", replace: true)
    #expect(text(d + "/foo") == "foo's")
    try c.rename(d + "/bar", d + "/baz", replace: true)   // another file in the way: replaced, as before
    #expect(try fm.contentsOfDirectory(atPath: d).filter { !$0.hasPrefix("sftp-") }.sorted() == ["baz", "foo"])
    #expect(text(d + "/baz") == "bar's")
}

/// R4: F6 → Overwrite of a file onto itself reached by another spelling — through a symlinked folder (the other
/// panel opened that way), or "." typed in the dialog — on a server without posix-rename keeps the file: it's a
/// rename, not "remove the one in the way, then rename" (which deleted it). Another file there is still replaced.
@Test func replacingRenameOntoItselfByAnotherPathWithoutPosixRename() throws {
    let d = tempDir(), tools = tempDir()
    defer { for p in [d, tools] { try? fm.removeItem(atPath: p) } }
    let t = serverWithoutExtensions(in: tools)
    let c = try SFTPClient(t)
    try #require(c.extensions["posix-rename@openssh.com"] == nil)
    c.close()
    put(d + "/Foo", "foo's")
    try fm.createSymbolicLink(atPath: d + "/link", withDestinationPath: ".")
    for destDir in [d + "/link", d + "/."] {
        let job = FileJob(.move, sources: [d + "/Foo"], from: .sftp(t), to: .sftp(t), destDir: destDir)
        job.resolveConflict = { _ in (.overwrite, false) }
        job.run()
        #expect(job.progress.state == .done && job.progress.errors.isEmpty, "\(destDir): \(job.progress.errors)")
        #expect(text(d + "/Foo") == "foo's", "\(destDir)")
        #expect(try fm.contentsOfDirectory(atPath: d).sorted() == ["Foo", "link"], "\(destDir)")
    }
    put(d + "/Bar", "bar's")   // another file through the link: replaced, as before
    let job = FileJob(.move, sources: [d + "/Bar"], from: .sftp(t), to: .sftp(t), destDir: d + "/link", targetName: "Foo")
    job.resolveConflict = { _ in (.overwrite, false) }
    job.run()
    #expect(job.progress.state == .done && job.progress.errors.isEmpty, "\(job.progress.errors)")
    #expect(text(d + "/Foo") == "bar's")
    #expect(try fm.contentsOfDirectory(atPath: d).sorted() == ["Foo", "link"])
}

/// R20: "Overwrite if Newer" onto a server, which keeps whole seconds: a file uploaded before (same second, the Mac's
/// fraction lost there) isn't "newer" and stays; one a second or more newer still replaces it.
@Test func overwriteIfNewerComparesWholeSecondsWithAServer() throws {
    let home = tempDir(), remote = tempDir()
    defer { for d in [home, remote] { try? fm.removeItem(atPath: d) } }
    let t: Double = 1_000_000_000
    for (name, fraction) in [("same", 0.5), ("newer", 1.5)] {
        put(home + "/" + name, "new " + name)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: t + fraction)], ofItemAtPath: home + "/" + name)
        put(remote + "/" + name, "old " + name)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: t)], ofItemAtPath: remote + "/" + name)
    }
    let job = FileJob(.copy, sources: [home + "/same", home + "/newer"], from: .local, to: .sftp(.local()), destDir: remote)
    job.resolveConflict = { _ in (.overwriteIfNewer, false) }
    job.run()
    #expect(job.progress.state == .done && job.progress.errors.isEmpty, "\(job.progress.errors)")
    #expect(text(remote + "/same") == "old same")
    #expect(text(remote + "/newer") == "new newer")
}

/// R21: F5 to a server path that is a symlink to a folder copies into that folder, as on this Mac — not over the
/// link as a new name, where Overwrite deleted the link.
@Test func aSymlinkToAFolderOnAServerIsAFolderToCopyInto() throws {
    let d = tempDir()
    defer { try? fm.removeItem(atPath: d) }
    let c = try SFTPClient(.local())
    defer { c.close() }
    try fm.createDirectory(atPath: d + "/real", withIntermediateDirectories: true)
    put(d + "/file", "x")
    try fm.createSymbolicLink(atPath: d + "/to-dir", withDestinationPath: "real")
    try fm.createSymbolicLink(atPath: d + "/to-file", withDestinationPath: "file")
    try fm.createSymbolicLink(atPath: d + "/dangling", withDestinationPath: "nowhere")
    #expect(try c.isFolder(d + "/real") && c.isFolder(d + "/to-dir"))
    for p in ["file", "to-file", "dangling", "missing"] { #expect(try !c.isFolder(d + "/" + p), "\(p)") }
}

private func randomData(_ n: Int) -> Data {
    var d = Data(count: n)
    d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }
    return d
}

/// R22: Retry after an upload's connection dropped, the source rewritten meanwhile (same size, another date): the
/// copy starts over from the new version, not the old one's first part spliced with the new one's rest.
@Test func retryAfterTheSourceChangedStartsOver() throws {
    let name = "sftp-server-r22-" + UUID().uuidString.prefix(8)
    let from = tempDir(), to = tempDir()
    defer { try? fm.removeItem(atPath: from); try? fm.removeItem(atPath: to) }
    let server = from + "/" + name
    try fm.createSymbolicLink(atPath: server, withDestinationPath: "/usr/libexec/sftp-server")
    let src = from + "/huge"
    try randomData(50_000_000).write(to: URL(fileURLWithPath: src))
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: src)
    let job = FileJob(.copy, sources: [src], from: .local, to: .sftp(.local(server: server)), destDir: to)
    job.resolveError = { _, _ in (.retry, false) }
    let finished = DispatchSemaphore(value: 0)
    job.onFinish = { finished.signal() }
    job.start()
    let deadline = Date().addingTimeInterval(20)
    while job.progress.doneBytes == 0 || job.progress.state != .running {
        try #require(Date() < deadline && job.progress.state != .done, "never saw the transfer start")
    }
    job.isPaused = true
    let changed = randomData(50_000_000)
    try changed.write(to: URL(fileURLWithPath: src), options: .atomic)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_100_000_000)], ofItemAtPath: src)
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    kill.arguments = ["-f", name]
    try kill.run()
    kill.waitUntilExit()
    usleep(200_000)
    job.isPaused = false
    #expect(finished.wait(timeout: .now() + 60) == .success)
    #expect(job.progress.state == .done, "\(job.progress.errors)")
    #expect(fm.contents(atPath: to + "/huge") == changed)
    #expect(try fm.attributesOfItem(atPath: to + "/huge")[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_100_000_000))
}

/// An sftp-server behind a proxy that answers the first WRITE at `offset` with a failure itself, and passes on
/// everything else: the writes after it land, as they may on a real server after an error.
private func serverFailingOneWrite(in dir: String, at offset: Int) -> SFTPTarget {
    let path = dir + "/sftp-fail-one-write"
    try! """
    #!/usr/bin/perl
    use strict; use warnings; use IPC::Open2; use IO::Select;
    my $pid = open2(my $out, my $in, '/usr/libexec/sftp-server');
    binmode($_) for \\*STDIN, \\*STDOUT, $out, $in;
    my ($fromClient, $fromServer, $failed) = ('', '', 0);
    sub put { my ($fh, $d) = @_; while (length $d) { my $n = syswrite($fh, $d); die unless defined $n; substr($d, 0, $n) = '' } }
    sub packets { my $b = shift; my @p; while (length $$b >= 4) { my $l = unpack('N', $$b); last if length $$b < 4 + $l; push @p, substr($$b, 0, 4 + $l, '') } @p }
    my $sel = IO::Select->new(\\*STDIN, $out);
    while (my @ready = $sel->can_read) {
        for my $fh (@ready) {
            my $n = sysread($fh, my $chunk, 1 << 16);
            exit 0 unless $n;
            if ($fh == $out) { $fromServer .= $chunk; put(\\*STDOUT, $_) for packets(\\$fromServer); next }
            $fromClient .= $chunk;
            for my $p (packets(\\$fromClient)) {
                my ($type, $id, $hlen) = unpack('x4 C N N', $p);
                if ($type == 6 && !$failed) {
                    my ($hi, $lo) = unpack("x13 x$hlen N N", $p);
                    if ($hi * 4294967296 + $lo == \(offset)) { $failed = 1; put(\\*STDOUT, pack('N C N N N N', 17, 101, $id, 4, 0, 0)); next }
                }
                put($in, $p);
            }
        }
    }
    """.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    return .local(server: path)
}

/// R22: one write the server failed, the ones sent after it written: Retry continues from where the file is whole,
/// not from its end past a hole of zeros.
@Test func retryAfterAFailedWriteLeavesNoHole() throws {
    let from = tempDir(), to = tempDir()
    defer { try? fm.removeItem(atPath: from); try? fm.removeItem(atPath: to) }
    let data = randomData(4 << 20)
    try data.write(to: URL(fileURLWithPath: from + "/f"))
    let job = FileJob(.copy, sources: [from + "/f"], from: .local, to: .sftp(serverFailingOneWrite(in: from, at: 3 * 32_768)), destDir: to)
    nonisolated(unsafe) var errors = 0
    job.resolveError = { _, _ in errors += 1; return (.retry, false) }
    job.run()
    #expect(job.progress.state == .done && errors == 1, "\(job.progress.errors)")
    #expect(fm.contents(atPath: to + "/f") == data)
}

/// R22: the source rewritten (bigger, another date) while the failed write's question is up, before (0) or after
/// (3 MB) part of it was written whole: Retry copies the new version from the start, all of it, with its date.
@Test(arguments: [0, 3 << 20]) func retryAfterAFailedWriteTakesTheChangedSource(failingAt offset: Int) throws {
    let from = tempDir(), to = tempDir()
    defer { try? fm.removeItem(atPath: from); try? fm.removeItem(atPath: to) }
    try randomData(4 << 20).write(to: URL(fileURLWithPath: from + "/f"))
    let changed = randomData(5 << 20)
    let job = FileJob(.copy, sources: [from + "/f"], from: .local, to: .sftp(serverFailingOneWrite(in: from, at: offset)), destDir: to)
    nonisolated(unsafe) var errors = 0
    job.resolveError = { _, _ in
        errors += 1
        try! changed.write(to: URL(fileURLWithPath: from + "/f"))
        try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_100_000_000)], ofItemAtPath: from + "/f")
        return (.retry, false)
    }
    job.run()
    #expect(job.progress.state == .done && errors == 1, "\(job.progress.errors)")
    #expect(fm.contents(atPath: to + "/f") == changed)
    #expect(try fm.attributesOfItem(atPath: to + "/f")[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_100_000_000))
}
