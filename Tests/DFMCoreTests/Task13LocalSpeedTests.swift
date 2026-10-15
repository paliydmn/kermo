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

/// On this Mac's own disk a copy starts at once and counts its totals alongside; they end up the same, and the
/// bar is determinate again when it's done. A disk image (the RAM disk), a stick or a share counts first, as before.
@Test func aCopyCountsItsTotalsAlongside() throws {
    let d = NSTemporaryDirectory() + "k13count-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: d) }
    for i in 0..<20 {
        try FileManager.default.createDirectory(atPath: "\(d)/src/d\(i)", withIntermediateDirectories: true)
        for j in 0..<10 { try Data(count: j).write(to: URL(fileURLWithPath: "\(d)/src/d\(i)/f\(j)")) }
    }
    try FileManager.default.createDirectory(atPath: d + "/dst", withIntermediateDirectories: true)
    let job = FileJob(.copy, sources: [d + "/src"], destDir: d + "/dst")
    job.countWhileCopying = true
    job.run()
    let p = job.progress
    #expect(p.state == .done && !p.counting)
    #expect(p.totalFiles == 200 && p.doneFiles == 200 && p.totalBytes == 900 && p.doneBytes == 900)
    #expect(DirLister.measure(d + "/dst/src") == (200, 900))

    #expect(FileJob.isInternal(Foundation.NSTemporaryDirectory()))
    if d.hasPrefix(ramDisk + "/") { #expect(!FileJob.isInternal(d)) }
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
