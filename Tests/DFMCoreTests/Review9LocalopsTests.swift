import Foundation
import Testing
@testable import DFMCore

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9local-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
private func write(_ path: String, _ text: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
}
private func names(_ dir: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() }

/// L16: a move within one volume is a rename per item — no walk over the tree before it, nor after.
@Test func sameVolumeMoveCountsItemsNotTree() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for n in ["a", "b", "c"] { write(d + "/src/tree/\(n).txt", n) }
    write(d + "/src/one.txt", "1")
    try! FileManager.default.createDirectory(atPath: d + "/dst", withIntermediateDirectories: true)
    let job = FileJob(.move, sources: [d + "/src/tree", d + "/src/one.txt"], destDir: d + "/dst")
    job.run()
    #expect(names(d + "/dst/tree") == ["a.txt", "b.txt", "c.txt"] && names(d + "/src").isEmpty)
    let p = job.progress
    #expect(p.totalFiles == 2 && p.doneFiles == 2 && p.totalBytes == 0, "\(p)")
    #expect(p.state == .done)
}

/// L16: merging into a folder that's there, and skipping, still ends at 100%, not past it.
@Test func sameVolumeMoveMergeAndSkipStayInStep() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    write(d + "/src/tree/a.txt", "a"); write(d + "/src/tree/b.txt", "b")
    write(d + "/dst/tree/b.txt", "old")
    let job = FileJob(.move, sources: [d + "/src/tree"], destDir: d + "/dst")
    job.resolveConflict = { c in (c.bothDirs ? .overwrite : .skip, false) }
    job.run()
    #expect(names(d + "/dst/tree") == ["a.txt", "b.txt"])
    #expect(names(d + "/src/tree") == ["b.txt"])   // skipped, left where it was
    #expect(job.progress.doneFiles == job.progress.totalFiles)
}

@Test func sameVolumeIsByDevice() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    write(d + "/f", "x")
    #expect(FileJob.sameVolume(d + "/f", d))
    #expect(!FileJob.sameVolume(d + "/f", "/dev"))    // devfs: another device
    #expect(!FileJob.sameVolume(d + "/missing", d))
}

/// L9/L16: a folder reached through a link (~/usb → /Volumes/USB) is on the volume the link points to — a rename
/// there would end in "Cross-device link". The item moved is a link itself: it stays where it is.
@Test func sameVolumeFollowsTheFolderLinkNotTheItem() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    write(d + "/f", "x")
    try FileManager.default.createSymbolicLink(atPath: d + "/usb", withDestinationPath: "/dev")
    #expect(!FileJob.sameVolume(d + "/f", d + "/usb"))
    #expect(FileJob.sameVolume(d + "/usb", d))
}

/// L15: a new copy is written under a hidden partial name and renamed once whole — mid-copy (a crash, a pulled
/// stick) the real name never holds a cut-off file; cancel leaves nothing behind.
/// The source sits on the sealed system volume, so it can't be cloned: the bytes really get copied.
@Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Library/Fonts/Apple Color Emoji.ttc")))
func newCopyGoesThroughPartialFile() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let src = "/System/Library/Fonts/Apple Color Emoji.ttc", dst = d + "/Apple Color Emoji.ttc"
    let job = FileJob(.copy, sources: [src], destDir: d)
    let finished = DispatchSemaphore(value: 0)
    job.onFinish = { finished.signal() }
    job.start()
    let deadline = Date().addingTimeInterval(10)
    while job.progress.doneBytes == 0 && job.progress.state != .done && Date() < deadline { usleep(1000) }
    job.isPaused = true   // the worker stops at the next block
    usleep(200_000)
    let mid = names(d)
    #expect(job.progress.state == .running, "copied before it could be watched")
    #expect(!mid.contains("Apple Color Emoji.ttc"), "\(mid)")
    #expect(mid.count == 1 && mid[0].hasPrefix(".dfm-partial-"), "\(mid)")
    job.cancel()
    finished.wait()
    #expect(names(d).isEmpty)
    #expect(FileJob.lstat(dst) == nil)
}

/// L15: the partial + rename keeps what a direct copy kept: mode, xattrs, dates, symlinks as links.
@Test func newCopyKeepsMetadataAndLeavesNoPartial() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    write(d + "/src/f.txt", "data")
    chmod(d + "/src/f.txt", 0o640)
    #expect(setxattr(d + "/src/f.txt", "com.dfm.test", "v", 1, 0, 0) == 0)
    let mtime = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: d + "/src/f.txt")
    symlink("f.txt", d + "/src/link")
    try FileManager.default.createDirectory(atPath: d + "/dst", withIntermediateDirectories: true)
    let job = FileJob(.copy, sources: [d + "/src/f.txt", d + "/src/link"], destDir: d + "/dst")
    job.run()
    #expect(names(d + "/dst") == ["f.txt", "link"])
    let s = try #require(FileJob.lstat(d + "/dst/f.txt"))
    #expect(s.st_mode & 0o777 == 0o640 && s.st_mtimespec.tv_sec == 1_000_000)
    var v: UInt8 = 0
    #expect(getxattr(d + "/dst/f.txt", "com.dfm.test", &v, 1, 0, 0) == 1 && v == UInt8(ascii: "v"))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: d + "/dst/link") == "f.txt")
    #expect(job.results.map(\.dst) == [d + "/dst/f.txt", d + "/dst/link"])
}
