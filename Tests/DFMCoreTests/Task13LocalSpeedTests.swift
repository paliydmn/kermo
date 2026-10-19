import Foundation
import Testing
@testable import DFMCore

// Task 13 §8.4: local long operations.

/// Firmlinks (`/Users`) aren't mount points, so a walk of `/` goes through them; /System/Volumes/Data is one
/// (with `/`'s own device, which is why it used to be counted twice), and so is /dev.
@Test func theListingSaysWhatIsMounted() throws {
    var root: [String: Bool?] = [:], volumes: [String: Bool?] = [:]
    try DirLister.each("/") { root[$0.name] = $1 }
    try DirLister.each("/System/Volumes") { volumes[$0.name] = $1 }
    #expect(root["Users"] == .some(false))
    #expect(root["dev"] == .some(true))
    #expect(volumes["Data"] == .some(true))
    #expect(try DirLister.list("/").count == root.count)
    // everything under /System/Volumes is a volume of its own; Data has its device, and was walked whole before
    #expect(DirLister.measure("/System/Volumes").files < 10_000)
    var q = SearchQuery(root: "/System/Volumes")
    q.includeHidden = true
    var found = 0
    FileSearch.run(q, isCancelled: { found > 10_000 }) { _ in found += 1 }
    #expect(found < 10_000)
}

/// A two-byte letter cut by the 1 MB edge is folded once both halves are read (only the new bytes are folded).
@Test func aLetterAcrossTheChunkEdgeIsFolded() throws {
    let p = NSTemporaryDirectory() + "k13fold-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: p) }
    var data = Data(repeating: UInt8(ascii: "x"), count: (1 << 20) - 1)
    data.append(contentsOf: Array("ПРИВІТ".utf8))   // П's first byte is the chunk's last
    try data.write(to: URL(fileURLWithPath: p))
    #expect(FileSearch.fileContains(p, Array("привіт".utf8), caseSensitive: false))
    #expect(!FileSearch.fileContains(p, Array("привіт".utf8), caseSensitive: true))
    #expect(FileSearch.fileContains(p, Array("xПР".utf8), caseSensitive: true))
    #expect(!FileSearch.fileContains(p, Array("ПРИВІТx".utf8), caseSensitive: true))
}

private func countTree(_ d: String) throws {
    for i in 0..<20 {
        try FileManager.default.createDirectory(atPath: "\(d)/src/d\(i)", withIntermediateDirectories: true)
        for j in 0..<10 { try Data(count: j).write(to: URL(fileURLWithPath: "\(d)/src/d\(i)/f\(j)")) }
    }
    try FileManager.default.createDirectory(atPath: d + "/dst/src/d3", withIntermediateDirectories: true)
}

/// On this Mac's own disk a copy starts at once and counts its totals alongside. The count ends first: its totals
/// show while the copy goes on (asked here about a file that's there already) and the bar is determinate again.
@Test func aCopyCountsItsTotalsAlongside() throws {
    let d = NSTemporaryDirectory() + "k13count-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: d) }
    try countTree(d)
    try Data("old".utf8).write(to: URL(fileURLWithPath: d + "/dst/src/d3/f5"))
    let job = FileJob(.copy, sources: [d + "/src"], destDir: d + "/dst")
    job.countWhileCopying = true
    let seen = Locked<FileJob.Progress?>(nil)
    job.resolveConflict = { [unowned job] c in
        if c.bothDirs { return (.overwrite, false) }
        for _ in 0..<500 where job.progress.counting { usleep(10_000) }   // the count has its own thread: wait for it
        seen.update { $0 = job.progress }
        return (.overwrite, false)
    }
    job.run()
    let mid = try #require(seen.value)
    #expect(!mid.counting && mid.totalFiles == 200 && mid.totalBytes == 900 && mid.doneFiles < 200)
    let p = job.progress
    #expect(p.state == .done && !p.counting && p.totalFiles == 200 && p.doneFiles == 200 && p.totalBytes == 900)
    #expect(DirLister.measure(d + "/dst/src") == (200, 900))
}

/// The copy ends before its count: what it did is its totals, and the count, once it gets going, changes nothing.
@Test func aCopyDoneBeforeItsCountTakesWhatItDid() throws {
    let d = NSTemporaryDirectory() + "k13count-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: d) }
    try countTree(d)
    let job = FileJob(.copy, sources: [d + "/src"], destDir: d + "/dst")
    job.countWhileCopying = true
    let gate = DispatchSemaphore(value: 0), counted = DispatchSemaphore(value: 0)
    job.beforeCounting = { gate.wait(); counted.signal() }
    job.resolveConflict = { _ in (.overwrite, false) }
    job.run()
    var p = job.progress
    #expect(p.state == .done && !p.counting && p.totalFiles == 200 && p.doneFiles == 200 && p.totalBytes == 900)
    gate.signal()
    counted.wait()
    usleep(50_000)   // the count after it, cut short (the copy is over): it must not write its totals
    p = job.progress
    #expect(p.totalFiles == 200 && p.totalBytes == 900 && !p.counting)
}

/// The RAM disk test.sh makes, if it's there: a mount point whose parent (/Volumes) is on this Mac's own volume.
/// Mounting an image for a test asks for Touch ID on macOS 27, so the tests use the one already mounted.
private let ramDisk = "/Volumes/KermoRAM"
private var ramDiskMounted: Bool {
    var mounted = false
    try? DirLister.each("/Volumes") { if $0.name == "KermoRAM" { mounted = $1 == true } }
    return mounted && access(ramDisk, W_OK) == 0
}

@Suite(.enabled(if: ramDiskMounted)) struct MountPointTests {
    /// A walk of /Volumes neither counts nor searches the volumes mounted there, as before.
    @Test func mountedVolumesAreNotCrossed() {
        #expect(DirLister.measure("/Volumes").bytes < 1 << 20)
        var found: [String] = []
        var q = SearchQuery(root: "/Volumes")
        q.includeHidden = true
        FileSearch.run(q, isCancelled: { found.count > 10_000 }) { found.append($0.name) }
        #expect(!found.contains { $0.hasPrefix("KermoRAM/") })
    }

    /// A move counts first even where a copy would count alongside: it deletes its sources from under the count.
    @Test func aMoveNeverCountsAlongside() throws {
        let src = Foundation.NSTemporaryDirectory() + "k13move-" + UUID().uuidString   // this Mac's volume
        let dst = ramDisk + "/k13move-" + UUID().uuidString                            // another one
        defer { try? FileManager.default.removeItem(atPath: src); try? FileManager.default.removeItem(atPath: dst) }
        try FileManager.default.createDirectory(atPath: src + "/t", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: URL(fileURLWithPath: src + "/t/f"))
        let job = FileJob(.move, sources: [src + "/t"], destDir: dst)
        job.countWhileCopying = true
        let ran = Locked(false)
        job.beforeCounting = { ran.update { $0 = true } }
        job.run()
        #expect(!ran.value)
        #expect(job.progress.totalFiles == 1 && job.progress.doneFiles == 1 && FileJob.lstat(dst + "/t/f") != nil)
    }

    /// F6 of a Finder-locked file to another volume does what `mv` does: the copy lands (locked), the original can't
    /// be deleted, so it stays and that's the one error. Nothing hidden is left behind.
    @Test func aLockedFileMovedAcrossVolumesStaysToo() throws {
        let src = Foundation.NSTemporaryDirectory() + "k15lock-" + UUID().uuidString   // this Mac's volume
        let dst = ramDisk + "/k15lock-" + UUID().uuidString                            // another one
        defer {
            for dir in [src, dst] { for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] { lchflags(dir + "/" + n, 0) } }
            try? FileManager.default.removeItem(atPath: src)
            try? FileManager.default.removeItem(atPath: dst)
        }
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: URL(fileURLWithPath: src + "/a.txt"))
        #expect(lchflags(src + "/a.txt", UInt32(UF_IMMUTABLE)) == 0)
        let job = FileJob(.move, sources: [src + "/a.txt"], destDir: dst)
        job.run()
        #expect(job.progress.errors == ["\(src)/a.txt: Operation not permitted"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst) == ["a.txt"])
        #expect(try String(contentsOfFile: dst + "/a.txt", encoding: .utf8) == "a" && FileJob.lstat(src + "/a.txt") != nil)
        #expect(FileJob.lstat(dst + "/a.txt").map { $0.st_flags & UInt32(UF_IMMUTABLE) } == UInt32(UF_IMMUTABLE))
    }

    /// sss-1 follow-up: F5 of a locked, transparently compressed file to another volume (no clone there) lands locked.
    @Test func aLockedCompressedFileCopiedAcrossVolumesStaysLocked() throws {
        let src = ramDisk + "/k15comp-" + UUID().uuidString                              // compresses (ditto --hfsCompression)
        let dst = Foundation.NSTemporaryDirectory() + "k15comp-" + UUID().uuidString     // this Mac's volume; the file is small
        defer {
            for dir in [src, dst] { for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] { lchflags(dir + "/" + n, 0) } }
            try? FileManager.default.removeItem(atPath: src)
            try? FileManager.default.removeItem(atPath: dst)
        }
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
        let text = String(repeating: "compress me please\n", count: 10_000)
        try Data(text.utf8).write(to: URL(fileURLWithPath: src + "/plain.txt"))
        let ditto = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["--hfsCompression", "--noclone", src + "/plain.txt", src + "/a.txt"])
        ditto.waitUntilExit()
        let flags = try #require(FileJob.lstat(src + "/a.txt")?.st_flags)
        try #require(flags & UInt32(UF_COMPRESSED) != 0, "the RAM disk didn't compress")
        #expect(lchflags(src + "/a.txt", flags | UInt32(UF_IMMUTABLE)) == 0)
        let job = FileJob(.copy, sources: [src + "/a.txt"], destDir: dst)
        job.run()
        #expect(job.progress.errors.isEmpty)
        #expect(try String(contentsOfFile: dst + "/a.txt", encoding: .utf8) == text)
        #expect(FileJob.lstat(dst + "/a.txt").map { $0.st_flags & UInt32(UF_IMMUTABLE) } == UInt32(UF_IMMUTABLE))
    }

    /// A move whose folder merges into a mount point: /Volumes is on the source's volume, /Volumes/KermoRAM isn't,
    /// so what's inside is copied over and deleted, never renamed (EXDEV).
    @Test func aMoveMergingIntoAMountPointCopies() throws {
        let src = Foundation.NSTemporaryDirectory() + "k13move-" + UUID().uuidString   // this Mac's volume, as /Volumes
        let name = "k13move-" + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(atPath: src)
            try? FileManager.default.removeItem(atPath: ramDisk + "/" + name)
        }
        try FileManager.default.createDirectory(atPath: src + "/KermoRAM/\(name)/sub", withIntermediateDirectories: true)
        try Data("a".utf8).write(to: URL(fileURLWithPath: src + "/KermoRAM/\(name)/a"))
        try Data("b".utf8).write(to: URL(fileURLWithPath: src + "/KermoRAM/\(name)/sub/b"))
        try #require(FileJob.sameVolume(src + "/KermoRAM", "/Volumes"))
        let job = FileJob(.move, sources: [src + "/KermoRAM"], destDir: "/Volumes")
        job.resolveConflict = { c in (c.bothDirs ? .overwrite : .skip, false) }   // merge KermoRAM, nothing else
        job.resolveError = { path, message in Issue.record("\(path): \(message)"); return (.skip, false) }
        job.run()
        #expect(job.progress.errors.isEmpty)
        #expect(try String(contentsOfFile: "\(ramDisk)/\(name)/a", encoding: .utf8) == "a")
        #expect(try String(contentsOfFile: "\(ramDisk)/\(name)/sub/b", encoding: .utf8) == "b")
        #expect(!FileManager.default.fileExists(atPath: src + "/KermoRAM"))
    }
}
