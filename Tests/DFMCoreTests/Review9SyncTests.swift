import Foundation
import Testing
@testable import DFMCore

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9sync-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
private func write(_ path: String, _ text: String, mtime: Double? = nil) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
    if let mtime { try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: path) }
}
private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

/// L7: Synchronize runs the plan made at Compare. Whatever changed on either side since is skipped and reported,
/// never overwritten (or merged into, or trashed) on that stale plan; the rest of the plan still runs.
@Test func syncSkipsWhatChangedSinceCompare() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let (l, r) = (d + "/L", d + "/R")
    write(l + "/edited.txt", "new", mtime: 2_000_000); write(r + "/edited.txt", "old", mtime: 1_000_000)
    write(l + "/fine.txt", "new", mtime: 2_000_000);   write(r + "/fine.txt", "old", mtime: 1_000_000)
    write(l + "/folder/a.txt", "L")
    write(r + "/gone.txt", "R")   // mirror → Trash
    write(r + "/keep.txt", "R")   // mirror → Trash, but edited after Compare

    let plan = DirSync.mirror(DirSync.compare(left: l, right: r), toRight: true)
    #expect(Set(plan.map(\.action)) == [.toRight, .trashRight], "\(plan.map { ($0.path, $0.action) })")

    // After Compare, before Synchronize: someone works in the target.
    write(r + "/edited.txt", "my edit", mtime: 3_000_000)
    write(r + "/folder/mine.txt", "mine")
    write(r + "/keep.txt", "edited")

    let jobs = DirSync.jobs(plan, left: l, right: r)
    for (job, _) in jobs { job.run() }
    #expect(read(r + "/edited.txt") == "my edit")
    #expect(read(r + "/folder/a.txt") == nil && read(r + "/folder/mine.txt") == "mine")   // not merged into
    #expect(read(r + "/keep.txt") == "edited")
    #expect(read(r + "/fine.txt") == "new" && read(r + "/gone.txt") == nil)   // the unchanged part still runs
    let errors = jobs.flatMap { $0.job.progress.errors }
    #expect(errors.count == 3 && errors.allSatisfy { $0.contains("changed since Compare") }, "\(errors)")
    for (job, _) in jobs where job.kind == .trash {   // don't leave test files in the user's Trash
        for t in job.results { try? FileManager.default.removeItem(atPath: t.dst) }
    }
}

/// L8: FAT keeps mtimes to 2 s (so 1 s of slack calls half the files different) and in local time (so a daylight
/// saving change shifts every file by an hour). Both mean the same version, for Synchronize and for Compare Folders.
@Test func mtimeToleranceCoversFatClockAndDaylightSaving() {
    func f(_ size: Int64, _ mtime: Double) -> FileItem { FileItem(name: "a", kind: .file, size: size, mtime: mtime, mode: 0o644, flags: 0) }
    #expect(DirSync.sameMoment(f(1, 100), f(1, 101), tolerance: 1))
    #expect(!DirSync.sameMoment(f(1, 100), f(1, 101.5), tolerance: 1))
    #expect(DirSync.sameMoment(f(1, 100), f(1, 101.5), tolerance: 2))
    #expect(!DirSync.sameMoment(f(1, 100), f(1, 103), tolerance: 2))
    #expect(DirSync.sameMoment(f(1, 100), f(1, 3701), tolerance: 2))      // DST on FAT: same size, an hour apart
    #expect(DirSync.sameMoment(f(1, 3701.5), f(1, 100), tolerance: 2))
    #expect(!DirSync.sameMoment(f(1, 100), f(1, 3703), tolerance: 2))
    #expect(!DirSync.sameMoment(f(1, 100), f(2, 3700), tolerance: 2))     // a different size is a real edit
    #expect(!DirSync.sameMoment(f(1, 100), f(1, 7300), tolerance: 2))
    #expect(!DirSync.sameMoment(f(1, 100), f(1, 3700), tolerance: 1))     // not FAT: mtimes are UTC, an hour is an edit

    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    #expect(DirSync.mtimeTolerance([d, "/no/such/dir"]) == 1)   // APFS: whole seconds are plenty
    #expect(DirCompare.differences(left: [f(1, 100)], right: [f(1, 3700)], tolerance: 2) == ([], []))
    #expect(DirCompare.differences(left: [f(1, 100)], right: [f(1, 101.5)], tolerance: 2) == ([], []))
}

/// L8: on APFS (or anything not FAT) a same-size file written an hour later is a real edit: Synchronize copies it
/// and Compare Folders marks it, instead of taking it for a daylight saving shift.
@Test func sameSizeAnHourLaterIsAnEditOffFat() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    write(d + "/L/status", "state=1", mtime: 1_700_003_600); write(d + "/R/status", "state=0", mtime: 1_700_000_000)
    let plan = DirSync.compare(left: d + "/L", right: d + "/R")
    #expect(plan.map(\.action) == [.toRight])
    #expect(DirSync.mirror(plan, toRight: true).map(\.action) == [.toRight])
    let items = { (s: String) in try! DirLister.list(d + s) }
    #expect(DirCompare.differences(left: items("/L"), right: items("/R")) == (["status"], []))
}
