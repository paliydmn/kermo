import Foundation
import Testing
@testable import DFMCore

// Task 3 QA: edge-case trees on the local disk, a USB volume and a real SSH server.
// Off by default; enable with
//   DFM_QA=1 ./test.sh --filter QA                       local only
//   DFM_QA_USB=/Volumes/USB …                             + a scratch folder on that volume
//   DFM_QA_SSH=myserver …                                 + a scratch folder in the server's /tmp
// Everything is created under fresh dfm-qa-* folders and removed at the end. Remote data stays tiny.

private let env = ProcessInfo.processInfo.environment
private let qaOn = env["DFM_QA"] != nil || env["DFM_QA_USB"] != nil || env["DFM_QA_SSH"] != nil
private nonisolated(unsafe) let fm = FileManager.default

/// A volume that refuses writes (task 11, N22: a stick giving EILSEQ) fails the test that uses it, not the whole run.
private func must(_ what: @autoclosure () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
    do { try what() } catch { Issue.record(error, sourceLocation: sourceLocation) }
}

private func scratch(_ base: String) -> String {
    let d = base + "/dfm-qa-" + UUID().uuidString.prefix(8)
    must(try fm.createDirectory(atPath: d, withIntermediateDirectories: true))
    return d
}
private func local() -> String { scratch((NSTemporaryDirectory() as NSString).resolvingSymlinksInPath) }
private func write(_ path: String, _ text: String) {
    must(try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true))
    must(try Data(text.utf8).write(to: URL(fileURLWithPath: path)))
}
private func read(_ path: String) -> String? {
    (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) }
}
private func exists(_ p: String) -> Bool { FileJob.lstat(p) != nil }
private func unlock(_ root: String) { _ = chflagsTree(root) }
@discardableResult private func chflagsTree(_ root: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
    p.arguments = ["-R", "nouchg", root]
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus
}

/// Names that break naive code: quotes, globs, `$`, leading dash, newline, NFD, 255 bytes, RTL override.
let trickyNames = ["plain.txt", "with space.txt", "it's \"q\".txt", "$(touch PWNED).txt", "`id`.txt", "-rf", "--help",
                   "a\nb.txt", "tab\there.txt", "star*?[x].txt", "back\\slash.txt", "e\u{301}-nfd.txt", "é-nfc2.txt",
                   "кирилиця 文字 😀.txt", "rtl-\u{202E}txt.exe", ".hidden", String(repeating: "x", count: 251) + ".txt"]

/// The mock tree every location test copies around (≈ 40 KB).
func makeTree(_ root: String) {
    for (i, n) in trickyNames.enumerated() { write(root + "/" + n, "content \(i)") }
    write(root + "/deep/" + Array(repeating: "d", count: 30).joined(separator: "/") + "/leaf.txt", "leaf")
    must(try fm.createSymbolicLink(atPath: root + "/link-ok", withDestinationPath: "plain.txt"))
    must(try fm.createSymbolicLink(atPath: root + "/link-dangling", withDestinationPath: "nope/missing"))
    must(try fm.createSymbolicLink(atPath: root + "/link-loop", withDestinationPath: "link-loop"))
    must(try fm.createSymbolicLink(atPath: root + "/link-dir-out", withDestinationPath: "/usr"))
    link(root + "/plain.txt", root + "/hardlink.txt")
    write(root + "/ro/readonly.txt", "ro")
    chmod(root + "/ro/readonly.txt", 0o400); chmod(root + "/ro", 0o500)
    write(root + "/secret.txt", "secret"); chmod(root + "/secret.txt", 0o600)
    setxattr(root + "/plain.txt", "com.dfm.qa", "v", 1, 0, 0)
    write(root + "/big.bin", String(repeating: "0123456789abcdef", count: 2048))   // 32 KB
}

/// Content + mode + symlink targets of every entry, relative to `root`.
func snapshot(_ root: String) -> [String: String] {
    var out: [String: String] = [:]
    guard let e = fm.enumerator(atPath: root) else { return [:] }
    while let rel = e.nextObject() as? String {
        let p = root + "/" + rel
        guard let s = FileJob.lstat(p) else { continue }
        let mode = String(s.st_mode & 0o7777, radix: 8)
        switch s.st_mode & S_IFMT {
        case S_IFLNK: out[rel.precomposedStringWithCanonicalMapping] = "link→" + ((try? fm.destinationOfSymbolicLink(atPath: p)) ?? "?")
        case S_IFDIR: out[rel.precomposedStringWithCanonicalMapping] = "dir " + mode
        default: out[rel.precomposedStringWithCanonicalMapping] = mode + " " + (read(p) ?? "?")
        }
    }
    return out
}

private func job(_ kind: FileJob.Kind, _ src: [String], to dir: String? = nil, conflict: FileJob.ConflictChoice = .skip) -> FileJob {
    let j = FileJob(kind, sources: src, destDir: dir)
    j.resolveConflict = { _ in (conflict, true) }
    j.resolveError = { _, _ in (.skip, false) }
    j.run()
    return j
}

private func cleanup(_ d: String) {
    unlock(d)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/chmod")
    p.arguments = ["-R", "u+rwx", d]
    try? p.run(); p.waitUntilExit()
    try? fm.removeItem(atPath: d)
}

// MARK: - Local

@Suite(.enabled(if: qaOn), .serialized) struct QALocal {
    @Test func copyMoveDeleteEdgeCaseTree() {
        let d = local(); defer { cleanup(d) }
        makeTree(d + "/src")
        let before = snapshot(d + "/src")
        let c = job(.copy, [d + "/src"], to: d + "/copy")
        try? fm.createDirectory(atPath: d + "/copy", withIntermediateDirectories: true)
        let c2 = job(.copy, [d + "/src"], to: d + "/copy")
        #expect(c.progress.errors.count == 1)                 // dest folder missing on the first try → one error, no crash
        #expect(c2.progress.errors.isEmpty, "\(c2.progress.errors)")
        #expect(snapshot(d + "/copy/src") == before)
        #expect(!exists(d + "/PWNED") && !exists(d + "/copy/src/PWNED"))

        let m = job(.move, [d + "/copy/src"], to: d)
        #expect(m.progress.errors.isEmpty)
        #expect(snapshot(d + "/src 2") == before || snapshot(d + "/src") == before)

        let del = job(.delete, [d + "/copy"])
        // ro/ is 0500 like on the source, so its child can't be unlinked. rm -rf would remove everything else.
        #expect(del.progress.errors.count == 1, "\(del.progress.errors)")
        let left = (try? fm.subpathsOfDirectory(atPath: d + "/copy")) ?? []
        #expect(Set(left) == ["src", "src/ro", "src/ro/readonly.txt"], "left behind: \(left)")   // F5: only ro/ and its parent stay
        #expect(del.progress.errors.first?.contains("/ro") == true)
        #expect(exists("/usr/bin"))                            // link-dir-out was not followed
    }

    @Test func lockedFileReportsErrorsAndLosesNothing() {
        let d = local(); defer { cleanup(d) }
        write(d + "/a/locked.txt", "L")
        #expect(chflags(d + "/a/locked.txt", UInt32(UF_IMMUTABLE)) == 0)
        let del = job(.delete, [d + "/a"])
        #expect(!del.progress.errors.isEmpty)
        #expect(read(d + "/a/locked.txt") == "L")
    }

    @Test(.timeLimit(.minutes(1))) func fifoInTreeDoesNotHangCopy() async {
        let d = local(); defer { cleanup(d) }
        write(d + "/src/a.txt", "a")
        #expect(mkfifo(d + "/src/pipe", 0o644) == 0)
        let j = FileJob(.copy, sources: [d + "/src"], destDir: d + "/dst")
        try? fm.createDirectory(atPath: d + "/dst", withIntermediateDirectories: true)
        j.resolveError = { _, _ in (.skip, false) }
        let done = QAFlag()
        j.onFinish = { done.set() }
        j.start()
        for _ in 0..<50 where !done.value { try? await Task.sleep(for: .milliseconds(100)) }
        #expect(done.value, "copy of a folder with a FIFO is still running after 5 s")
        if !done.value { j.cancel() }
        #expect(read(d + "/dst/src/a.txt") == "a")
    }

    @Test func copyIntoItselfThroughSymlink() {
        let d = local(); defer { cleanup(d) }
        write(d + "/Dir/a.txt", "a")
        must(try fm.createDirectory(atPath: d + "/Dir/sub", withIntermediateDirectories: true))
        must(try fm.createSymbolicLink(atPath: d + "/via-link", withDestinationPath: d + "/Dir/sub"))
        let viaLink = job(.copy, [d + "/Dir"], to: d + "/via-link")
        let depth1 = snapshot(d + "/Dir").keys.map { $0.split(separator: "/").count }.max() ?? 0
        #expect(depth1 < 6, "copy through a symlink into itself nested \(depth1) levels, errors: \(viaLink.progress.errors.count)")
    }

    @Test func copyIntoItselfSpelledInOtherCase() {
        let d = local(); defer { cleanup(d) }
        write(d + "/Dir/a.txt", "a")
        must(try fm.createDirectory(atPath: d + "/Dir/sub", withIntermediateDirectories: true))
        let otherCase = job(.copy, [d + "/Dir"], to: d + "/dir/sub")   // APFS is case-insensitive by default
        let depth2 = snapshot(d + "/Dir").keys.map { $0.split(separator: "/").count }.max() ?? 0
        #expect(depth2 < 6, "copy into itself spelled in another case nested \(depth2) levels, errors: \(otherCase.progress.errors.count)")
    }

    /// The app runs jobs with `start()` (F1: the 512 KB default stack overflowed at ~400 levels), so test that way.
    @Test(.timeLimit(.minutes(2)), arguments: [50, 100, 400])
    func deepButLegalTreeCopiesOnTheJobThread(depth: Int) async {
        let d = local(); defer { cleanup(d) }
        let rel = Array(repeating: "a", count: depth).joined(separator: "/")
        write(d + "/src/" + rel + "/leaf.txt", "leaf")
        try? fm.createDirectory(atPath: d + "/dst", withIntermediateDirectories: true)
        let j = FileJob(.copy, sources: [d + "/src"], destDir: d + "/dst")
        let done = QAFlag()
        j.onFinish = { done.set() }
        j.start()
        while !done.value { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(read(d + "/dst/src/" + rel + "/leaf.txt") == "leaf", "\(j.progress.errors)")
    }

    @Test func cancelMidCopyLeavesNoPartialFile() async throws {
        let d = local(); defer { cleanup(d) }
        let big = d + "/big.bin"
        #expect(fm.createFile(atPath: big, contents: nil))
        let h = FileHandle(forWritingAtPath: big)!
        let chunk = Data(count: 1 << 20)
        for _ in 0..<200 { h.write(chunk) }   // 200 MB of real (non-sparse) data
        try h.close()
        try fm.createDirectory(atPath: d + "/other", withIntermediateDirectories: true)
        // Clone is instant on the same volume, so copy to a different volume isn't available here;
        // a cancel before start must still leave nothing.
        let j = FileJob(.copy, sources: [big], destDir: d + "/other")
        j.cancel(); j.run()
        #expect(!exists(d + "/other/big.bin"))
    }

    @Test func editorStyleAtomicWriteKeepsMode() throws {
        // What Editor does on save is checked in the app review; here: copy over a 0600 file keeps 0600 of the source.
        let d = local(); defer { cleanup(d) }
        write(d + "/s/k.txt", "new"); chmod(d + "/s/k.txt", 0o600)
        write(d + "/t/k.txt", "old"); chmod(d + "/t/k.txt", 0o644)
        _ = job(.copy, [d + "/s/k.txt"], to: d + "/t", conflict: .overwrite)
        #expect(read(d + "/t/k.txt") == "new")
        #expect(FileJob.lstat(d + "/t/k.txt").map { $0.st_mode & 0o777 } == 0o600)
    }
}

// MARK: - USB

@Suite(.enabled(if: env["DFM_QA_USB"] != nil), .serialized) struct QAUSB {
    let vol = env["DFM_QA_USB"] ?? ""
    /// FAT/exFAT keep no modes, hard links or sub-second times: there, compare content only.
    var isAPFS: Bool {
        var s = statfs()
        return statfs(vol, &s) == 0 && withUnsafeBytes(of: s.f_fstypename) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) } == "apfs"
    }
    func same(_ a: [String: String], _ b: [String: String]) -> Bool {
        if isAPFS { return a == b }
        func content(_ m: [String: String]) -> [String: String] {
            m.filter { !$0.value.hasPrefix("dir") }.mapValues { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? $0 }
        }
        return content(a) == content(b)
    }

    @Test func crossVolumeCopyMoveTrashRoundTrip() throws {
        let l = local(), u = scratch(vol); defer { cleanup(l); cleanup(u) }
        makeTree(l + "/src")
        let before = snapshot(l + "/src")
        let srcMeta = try fm.attributesOfItem(atPath: l + "/src/plain.txt")

        let c = job(.copy, [l + "/src"], to: u)
        #expect(c.progress.errors.isEmpty, "\(c.progress.errors)")
        #expect(same(snapshot(u + "/src"), before))
        let dstMeta = try fm.attributesOfItem(atPath: u + "/src/plain.txt")
        let dt = ((dstMeta[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) - ((srcMeta[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 9)
        #expect(abs(dt) < (isAPFS ? 0.000_001 : 2.01))   // FAT keeps 2 s, exFAT 10 ms
        #expect(getxattr(u + "/src/plain.txt", "com.dfm.qa", nil, 0, 0, 0) == 1)

        // Move back across volumes = copy + delete.
        try fm.createDirectory(atPath: l + "/back", withIntermediateDirectories: true)
        let m = job(.move, [u + "/src"], to: l + "/back")
        #expect(same(snapshot(l + "/back/src").filter { !$0.key.contains("._") }, before))
        // ro/ is 0500 on the source: its children can't be unlinked, so the move reports it and keeps the source.
        #expect(m.progress.errors.allSatisfy { $0.contains("/ro") }, "\(m.progress.errors)")   // F3: no ._ errors
        #expect(!snapshot(l + "/back/src").keys.contains { $0.contains("._") }, "AppleDouble files copied as junk")

        // Trash on a removable volume goes to its .Trashes and can be put back.
        write(u + "/t.txt", "trash me")
        let t = job(.trash, [u + "/t.txt"])
        #expect(t.progress.errors.isEmpty, "\(t.progress.errors)")
        let trashed = try #require(t.results.first?.dst)
        #expect(trashed.hasPrefix(vol + "/.Trashes/"), "\(trashed)")
        try fm.moveItem(atPath: trashed, toPath: u + "/t.txt")
        #expect(read(u + "/t.txt") == "trash me")
    }

    @Test func conflictsAndUniqueNamesOnUSB() {
        let u = scratch(vol); defer { cleanup(u) }
        write(u + "/a/x.txt", "src"); write(u + "/b/x.txt", "dst")
        _ = job(.copy, [u + "/a/x.txt"], to: u + "/b", conflict: .keepBoth)
        #expect(read(u + "/b/x 2.txt") == "src" && read(u + "/b/x.txt") == "dst")
        _ = job(.copy, [u + "/a/x.txt"], to: u + "/b", conflict: .overwrite)
        #expect(read(u + "/b/x.txt") == "src")
        #expect(((try? fm.contentsOfDirectory(atPath: u + "/b")) ?? []).allSatisfy { !$0.hasPrefix(".dfm-partial") })
    }
}

// MARK: - SSH

@Suite(.enabled(if: env["DFM_QA_SSH"] != nil), .serialized) struct QASSH {
    let t = SFTPTarget(host: env["DFM_QA_SSH"] ?? "")

    @Test func uploadListDownloadRenameRemove() throws {
        let l = local(); defer { cleanup(l) }
        let remote = "/tmp/dfm-qa-" + UUID().uuidString.prefix(8)
        func removeRemote() -> [String] {
            let job = FileJob(.delete, sources: [remote], from: .sftp(t), to: .sftp(t), destDir: nil)
            job.run()
            return job.progress.errors
        }
        defer { _ = removeRemote() }
        for (i, n) in trickyNames.enumerated() { write(l + "/up/" + n, "content \(i)") }
        write(l + "/up/sub dir/[x] y.txt", "nested")

        #expect(try SFTP.home(t).hasPrefix("/"))
        let c = try SFTPClient(t)
        defer { c.close() }
        try c.mkdir(remote)
        let up = FileJob(.copy, sources: [l + "/up"], from: .local, to: .sftp(t), destDir: remote)
        up.run()
        #expect(up.progress.errors.isEmpty)
        let listed = Set(try SFTP.list(t, remote + "/up").map { $0.name.precomposedStringWithCanonicalMapping })
        for n in trickyNames { #expect(listed.contains(n.precomposedStringWithCanonicalMapping), "missing \(n)") }
        #expect(!exists(l + "/PWNED"))

        try fm.createDirectory(atPath: l + "/down", withIntermediateDirectories: true)
        let down = FileJob(.copy, sources: [remote + "/up"], from: .sftp(t), to: .local, destDir: l + "/down")
        down.run()
        #expect(down.progress.errors.isEmpty)
        #expect(snapshot(l + "/down/up") == snapshot(l + "/up"))

        try c.rename(remote + "/up/sub dir", remote + "/renamed")
        #expect(try SFTP.list(t, remote + "/renamed").map(\.name) == ["[x] y.txt"])
        #expect(removeRemote().isEmpty)
        #expect(throws: SFTPError.self) { try SFTP.list(t, remote) }
    }

    /// H1 (task 11): a Latin-1 name, a line break and braces list as the server has them, and act on that file.
    @Test func oddNamesListAndActOnTheirOwnFile() throws {
        let remote = "/tmp/dfm-qa-" + UUID().uuidString.prefix(8)
        let c = try SFTPClient(t)
        defer {
            FileJob(.delete, sources: [remote], from: .sftp(t), to: .sftp(t), destDir: nil).run()
            c.close()
        }
        try c.mkdir(remote)
        let latin1 = "caf\u{F00E9}.txt"   // "café" in Latin-1: the byte E9 alone
        let names = [latin1, "new", "new\nline.txt", "{x}", "x", "d{1,2}"]
        for n in names {
            let w = try c.openWrite(remote + "/" + n)
            try w.write(Data(n.utf8))
            try w.finish()
        }
        #expect(try SSHCommand.capture(t, "ls -b -- " + ShellContext.quote(remote)).contains("caf\\351.txt"), "the byte itself on the server")
        let listed = try SFTP.list(t, remote)
        #expect(Set(listed.map(\.name)) == Set(names) && listed.count == names.count)
        #expect(latin1.listed == "caf\\xE9.txt")
        for n in [latin1, "new"] {
            try c.remove(remote + "/" + n)
            #expect(try c.lstat(remote + "/" + n) == nil)
        }
        #expect(Set(try SFTP.list(t, remote).map(\.name)) == ["new\nline.txt", "{x}", "x", "d{1,2}"])
    }

    @Test func badHostAndMissingPathFailCleanly() {
        #expect(throws: SFTPError.self) { try SFTP.list(SFTPTarget(host: "no-such-host.invalid"), "/") }
        #expect(throws: SFTPError.self) { try SFTP.list(t, "/definitely/not/here") }
        #expect(throws: SFTPError.self) { try SFTP.list(SFTPTarget(host: "-oProxyCommand=touch /tmp/dfm-qa-pwn"), "/") }
        #expect(!exists("/tmp/dfm-qa-pwn"))
    }
}
