import Foundation
import Testing
@testable import DFMCore

/// root/proj/{a.txt, sub/b.txt, sub/deep/c.txt}
private func sampleTree() -> String {
    let root = NSTemporaryDirectory() + "dfm-arc-" + UUID().uuidString
    for (rel, text) in ["proj/a.txt": "A", "proj/sub/b.txt": "B", "proj/sub/deep/c.txt": "C"] {
        let p = root + "/" + rel
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: URL(fileURLWithPath: p))
    }
    return root
}

private func sh(_ cmd: String, in dir: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.environment = ["COPYFILE_DISABLE": "1", "PATH": "/usr/bin:/bin"]
    try! p.run()
    p.waitUntilExit()
    precondition(p.terminationStatus == 0, "command failed: \(cmd)")
}

private func names(_ items: [FileItem]?) -> [String] { (items ?? []).map(\.name).sorted() }
private func read(_ path: String) -> String? {
    (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) }
}

@Test func browseAndExtractTarGz() throws {
    let root = sampleTree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    sh("tar czf t.tar.gz proj", in: root)
    let idx = try ArchiveIndex.read(root + "/t.tar.gz")
    #expect(names(idx.list("")) == ["proj"])
    #expect(names(idx.list("proj")) == ["a.txt", "sub"])
    #expect(names(idx.list("proj/sub/deep")) == ["c.txt"])
    #expect(idx.list("proj")?.first { $0.name == "a.txt" }?.size == 1)

    let dest = root + "/out"
    try idx.extract(["sub"], from: "proj", to: dest)   // a folder from inside, without the proj/ prefix
    #expect(read(dest + "/sub/deep/c.txt") == "C")
    #expect(!FileManager.default.fileExists(atPath: dest + "/proj"))
    #expect(!FileManager.default.fileExists(atPath: dest + "/a.txt"))
}

@Test func dotSlashTarballs() throws {
    let root = sampleTree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    sh("tar cf ../dot.tar .", in: root + "/proj")   // entries "./a.txt", "./sub/…"
    let idx = try ArchiveIndex.read(root + "/dot.tar")
    #expect(names(idx.list("")) == ["a.txt", "sub"])
    let dest = root + "/out"
    try idx.extract(["b.txt"], from: "sub", to: dest)
    #expect(read(dest + "/b.txt") == "B")
}

@Test func zipWithoutFolderEntries() throws {
    let root = sampleTree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    sh("zip -q -r -D z.zip proj", in: root)   // -D: no entries for folders
    let idx = try ArchiveIndex.read(root + "/z.zip")
    #expect(idx.format.lowercased().contains("zip"))
    #expect(names(idx.list("proj")) == ["a.txt", "sub"])
    #expect(idx.list("proj")?.first { $0.name == "sub" }?.kind == .dir)
    let dest = root + "/out"
    try idx.extract(["a.txt", "sub"], from: "proj", to: dest)
    #expect(read(dest + "/a.txt") == "A" && read(dest + "/sub/b.txt") == "B")
}

@Test func createThenRead() throws {
    let root = sampleTree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    for ext in ["zip", "tar.xz", "7z"] {
        let archive = root + "/new." + ext
        try ArchiveIndex.tar(ArchiveIndex.createArguments(archive, names: ["proj"], in: root))
        let idx = try ArchiveIndex.read(archive)
        #expect(names(idx.list("proj/sub")) == ["b.txt", "deep"], "\(ext)")
        #expect(!names(idx.list("proj")).contains { $0.hasPrefix("._") }, "\(ext): no AppleDouble junk")
    }
}

@Test func archiveDetectionAndUnsafePaths() throws {
    #expect(ArchiveIndex.isArchive("backup.TAR.GZ") && ArchiveIndex.isArchive("a.zip") && ArchiveIndex.isArchive("x.7z"))
    #expect(!ArchiveIndex.isArchive("notes.txt") && !ArchiveIndex.isArchive("log.gz"))
    #expect(ArchiveIndex.normalize("./a//b/") == "a/b")
    #expect(ArchiveIndex.normalize("/etc/../../passwd") == "etc/passwd")
    #expect(throws: ArchiveError.self) { try ArchiveIndex.read("/etc/hosts") }
}

@Test func archiveNamesAndArgumentShapes() {
    for n in ["a.tar.zst", "a.tar.lz4", "A.APK", "x.tgz", "x.TBZ2", "x.txz", "x.rar", "x.iso", "x.cpio", "x.xar", "x.jar", "x.ipa"] {
        #expect(ArchiveIndex.isArchive(n), "\(n)")
    }
    for n in ["x.gz", "x.bz2", "x.tar.gz.bak", "archive", ".zip.txt", "x.zipx", ""] { #expect(!ArchiveIndex.isArchive(n), "\(n)") }
    #expect(ArchiveIndex.createArguments("/o.zip", names: ["-weird", "plain"], in: "/d") == ["-a", "-c", "-f", "/o.zip", "-C", "/d", "./-weird", "plain"])
    #expect(ArchiveIndex.normalize("") == "" && ArchiveIndex.normalize("...") == "..." && ArchiveIndex.normalize("a/./b/../c") == "a/b/c")
}

@Test func extractArgumentsStripTheRightDepth() throws {
    let root = sampleTree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    sh("tar cf plain.tar proj", in: root)
    sh("tar cf ../dot.tar .", in: root + "/proj")
    let plain = try ArchiveIndex.read(root + "/plain.tar"), dot = try ArchiveIndex.read(root + "/dot.tar")
    #expect(plain.extractArguments([], from: "proj/sub", to: "/d") == ["-x", "-f", root + "/plain.tar", "-C", "/d"])   // whole archive
    #expect(plain.extractArguments(["a.txt"], from: "", to: "/d").suffix(1) == ["a.txt"])
    #expect(!plain.extractArguments(["a.txt"], from: "", to: "/d").contains("--strip-components"))
    #expect(plain.extractArguments(["deep", "b.txt"], from: "proj/sub", to: "/d").suffix(5) == ["--strip-components", "2", "--", "proj/sub/deep", "proj/sub/b.txt"])
    #expect(dot.extractArguments(["c.txt"], from: "sub/deep", to: "/d").suffix(4) == ["--strip-components", "3", "--", "./sub/deep/c.txt"])
    #expect(dot.extractArguments(["a.txt"], from: "", to: "/d").suffix(4) == ["--strip-components", "1", "--", "./a.txt"])
}

@Test func wholeArchiveEmptyArchiveAndLinks() throws {
    let root = sampleTree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    sh("ln -s a.txt proj/link && tar cf t.tar proj", in: root)
    let idx = try ArchiveIndex.read(root + "/t.tar")
    #expect(idx.list("proj")?.first { $0.name == "link" }?.kind == .link)
    #expect(idx.list("nope") == nil && idx.list("proj/a.txt") == nil)
    #expect(!idx.format.isEmpty && idx.format != "archive")   // e.g. "POSIX pax interchange format"
    try idx.extract([], from: "", to: root + "/all")
    #expect(read(root + "/all/proj/sub/deep/c.txt") == "C")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root + "/all/proj/link") == "a.txt")

    sh("tar cf empty.tar -T /dev/null", in: root)
    let empty = try ArchiveIndex.read(root + "/empty.tar")
    #expect(empty.list("")?.isEmpty == true && empty.list("x") == nil)
}

@Test func absolutePathEntriesStayInsideTheDestination() throws {
    let root = sampleTree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    sh("tar cPf abs.tar \"$PWD/proj/a.txt\"", in: root)   // entry "/private/tmp/.../proj/a.txt" (or /var/...)
    let idx = try ArchiveIndex.read(root + "/abs.tar")
    let top = try #require(idx.list("")?.first)
    #expect(top.kind == .dir && !top.name.isEmpty && !top.name.hasPrefix("/"))
    let real = try #require(realpath(root, nil))   // NSString's resolvingSymlinksInPath drops "/private"
    defer { free(real) }
    let inner = String(String(cString: real).dropFirst()) + "/proj"
    #expect(names(idx.list(inner)) == ["a.txt"])
    try idx.extract(["a.txt"], from: inner, to: root + "/out")   // bsdtar matches the stored "/…" name
    #expect(read(root + "/out/a.txt") == "A")
    #expect(!FileManager.default.fileExists(atPath: "/" + inner + "/out"))   // nothing escaped to the original location
    #expect(read(root + "/proj/a.txt") == "A")                                // the original was never touched
}

@Test func corruptAndMissingArchivesThrow() throws {
    let root = sampleTree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    sh("tar czf t.tar.gz proj", in: root)
    let data = try Data(contentsOf: URL(fileURLWithPath: root + "/t.tar.gz"))
    try data.prefix(60).write(to: URL(fileURLWithPath: root + "/cut.tar.gz"))
    #expect(throws: ArchiveError.self) { try ArchiveIndex.read(root + "/cut.tar.gz") }
    #expect(throws: ArchiveError.self) { try ArchiveIndex.read(root + "/missing.zip") }
    #expect(throws: ArchiveError.self) { try ArchiveIndex.read(root + "/t.tar.gz").extract(["nope"], from: "proj", to: root + "/o") }
    let e = ArchiveError("x")
    #expect(e.errorDescription == "x" && e.localizedDescription == "x")
}

@Test func unicodeEntryNames() throws {
    let root = sampleTree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    sh("printf U > 'proj/Їжак ñ.txt' && zip -q -r u.zip proj", in: root)
    let idx = try ArchiveIndex.read(root + "/u.zip")
    let name = try #require(idx.list("proj")?.map(\.name).first { $0.precomposedStringWithCanonicalMapping == "Їжак ñ.txt" })
    try idx.extract([name], from: "proj", to: root + "/out")
    #expect(read(root + "/out/" + name) == "U")
}

@Test func namesWithGlobCharactersExtractLiterally() throws {
    let root = sampleTree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    sh("printf G > 'proj/a[1].txt' && printf S > 'proj/star*.txt' && tar cf g.tar proj", in: root)
    let idx = try ArchiveIndex.read(root + "/g.tar")
    #expect(names(idx.list("proj")).contains("a[1].txt"))
    try idx.extract(["a[1].txt", "star*.txt"], from: "proj", to: root + "/out")
    #expect(read(root + "/out/a[1].txt") == "G" && read(root + "/out/star*.txt") == "S")
}
