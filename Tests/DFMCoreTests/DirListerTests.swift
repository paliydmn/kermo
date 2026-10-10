import Foundation
import Testing
@testable import DFMCore

private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "dfm-list-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

@Test func listMatchesFoundationOnEveryKind() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fm = FileManager.default
    let old = Date(timeIntervalSince1970: 1_234_567_890)
    try Data("12345".utf8).write(to: URL(fileURLWithPath: d + "/five.txt"))
    try fm.setAttributes([.modificationDate: old, .posixPermissions: 0o640], ofItemAtPath: d + "/five.txt")
    try Data().write(to: URL(fileURLWithPath: d + "/empty"))
    try fm.createDirectory(atPath: d + "/sub dir", withIntermediateDirectories: false)
    try fm.createSymbolicLink(atPath: d + "/link", withDestinationPath: "five.txt")
    try fm.createSymbolicLink(atPath: d + "/dangling", withDestinationPath: "nowhere")
    try Data("h".utf8).write(to: URL(fileURLWithPath: d + "/flagged"))
    #expect(chflags(d + "/flagged", UInt32(UF_HIDDEN)) == 0)
    #expect(mkfifo(d + "/pipe", 0o644) == 0)
    let long = String(repeating: "n", count: 255)
    try Data("L".utf8).write(to: URL(fileURLWithPath: d + "/" + long))
    try Data("U".utf8).write(to: URL(fileURLWithPath: d + "/Їжак і ñandú.txt"))

    let fast = try DirLister.list(d)
    let slow = try DirLister.listFoundation(d)
    func norm(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }
    #expect(Set(fast.map { norm($0.name) }) == Set(slow.map { norm($0.name) }))
    #expect(fast.count == 9)
    let oracle = Dictionary(slow.map { (norm($0.name), $0) }, uniquingKeysWith: { a, _ in a })
    for f in fast {
        let s = try #require(oracle[norm(f.name)], "\(f.name)")
        #expect(f.kind == s.kind, "\(f.name)")
        if f.kind == .file { #expect(f.size == s.size, "\(f.name)") }
        #expect(abs(f.mtime - s.mtime) < 1, "\(f.name)")
    }
    let by = Dictionary(fast.map { (norm($0.name), $0) }, uniquingKeysWith: { a, _ in a })
    #expect(by["five.txt"]?.size == 5 && (by["five.txt"]?.mode ?? 0) & 0o777 == 0o640)
    #expect(abs((by["five.txt"]?.mtime ?? 0) - old.timeIntervalSince1970) < 0.001)
    #expect(by["empty"]?.size == 0 && by["sub dir"]?.kind == .dir && by["sub dir"]?.size == 0)
    #expect(by["link"]?.kind == .link && by["dangling"]?.kind == .link)
    #expect(by["pipe"]?.kind == .other)
    #expect((by["flagged"]?.flags ?? 0) & UInt32(UF_HIDDEN) != 0 && by["flagged"]?.isHidden == true)
    #expect((by["sub dir"]?.flags ?? 1) & UInt32(UF_HIDDEN) == 0)
    #expect(by[long]?.size == 1)
    #expect(by["Їжак і ñandú.txt"]?.size == 1)
}

@Test func listOfManyLongNamesSpansSeveralSyscalls() throws {
    // ~260 bytes per entry × 3000 > the 256 KB buffer, so getattrlistbulk has to be called repeatedly.
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let pad = String(repeating: "x", count: 190)
    for i in 0..<3000 { _ = FileManager.default.createFile(atPath: "\(d)/\(pad)\(i)", contents: nil) }
    let names = Set(try DirLister.list(d).map(\.name))
    #expect(names.count == 3000)
    #expect(names == Set(try FileManager.default.contentsOfDirectory(atPath: d)))
}

@Test func listErrorsAndEmptyDir() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    #expect(try DirLister.list(d).isEmpty)
    #expect(throws: POSIXError.self) { try DirLister.list(d + "/missing") }
    try Data("x".utf8).write(to: URL(fileURLWithPath: d + "/file"))
    #expect(throws: POSIXError.self) { try DirLister.list(d + "/file") }
}

@Test func measureEdgeCases() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try Data(count: 7).write(to: URL(fileURLWithPath: d + "/f"))
    try FileManager.default.createDirectory(atPath: d + "/empty", withIntermediateDirectories: false)
    #expect(DirLister.measure(d + "/f") == (1, 7))          // a single file is itself
    #expect(DirLister.measure(d + "/missing") == (0, 0))
    #expect(DirLister.measure(d + "/empty") == (0, 0))
    #expect(DirLister.measure(d) == (1, 7))
    #expect(DirLister.measure(d, isCancelled: { true }) == (0, 0))   // stops before counting anything
}
