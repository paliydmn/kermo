import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Review 6, PR 6: what's written — Compress, the editor's save, the askpass helper, names tar reads as more.

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r6s-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// `/usr/bin/tar` with `args`: its exit status.
private func tar(_ args: [String], in dir: String) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    p.arguments = args
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

/// В13: tar reads a leading "@" as "the entries of that archive": Compress on Synology's @eaDir failed ("can't open").
/// "./" goes in front of it, as of a "-" — by the first scalar, so a "-" with a mark joined is one too.
@Test func aNameStartingWithAtIsPackedAsItself() throws {
    #expect(ArchiveIndex.createArguments("/o.zip", names: ["@eaDir", "-x", "-\u{301}y", "a@b"], in: "/d").suffix(4)
            == ["./@eaDir", "./-x", "./-\u{301}y", "a@b"])
    #expect(ShellContext.quoteName("@x") == "./@x" && ShellContext.quoteName("a@x") == "a@x")
    #expect(ShellContext(dir: "/d", otherDir: nil, cursor: nil, targets: ["@eaDir"]).expand("tar -cf x.tar %s") == "tar -cf x.tar ./@eaDir")

    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: dir + "/@eaDir", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir + "/@eaDir/thumb", contents: Data("t".utf8))
    #expect(try tar(ArchiveIndex.createArguments(dir + "/o.tar", names: ["@eaDir"], in: dir), in: dir) == 0)
    let index = try ArchiveIndex.read(dir + "/o.tar")
    #expect(index.list("@eaDir")?.map(\.name) == ["thumb"])
}

/// By the clock: a loaded full run keeps the main actor busy (a listing took over 20 s there).
@MainActor private func until(_ done: () -> Bool, seconds: Double = 60) async {
    let end = Date().addingTimeInterval(seconds)
    while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
}

/// В1, В21: Compress read the panel's folder after its question — a panel gone elsewhere meanwhile had tar pack that
/// folder's item of the same name — and tar wrote straight into the archive: ⎋ or a full disk left a cut-off one that
/// looked whole. Now the folder is the items', and tar packs beside the archive, which it becomes on exit 0.
@MainActor @Test func compressPacksTheItemsFromWhereTheyWereAsked() async throws {
    let a = try tempDir(), b = try tempDir(), out = try tempDir()
    defer { for d in [a, b, out] { try? FileManager.default.removeItem(atPath: d) } }
    FileManager.default.createFile(atPath: a + "/f.txt", contents: Data("A".utf8))
    FileManager.default.createFile(atPath: b + "/f.txt", contents: Data("B".utf8))
    let app = AppDelegate()
    app.panels = [PanelViewController(tabs: [a], index: 0, showHidden: false), PanelViewController(tabs: [out], index: 0, showHidden: false)]
    app.panels.forEach { $0.loadViewIfNeeded() }
    defer { app.panels.forEach { $0.shutdown() } }
    defer { NSApp.windows.filter { $0.title.hasPrefix("Compress into") }.forEach { $0.close() } }
    let panel = app.panels[0]
    await until { panel.listedItems.count == 1 }
    panel.table.selectRowIndexes([1], byExtendingSelection: false)   // row 0 is ..
    try #require(panel.cursorURL?.path == a + "/f.txt", "\(String(describing: panel.cursorURL))")
    AppDelegate.prompting = { _ in
        panel.navigate(to: b)   // the panel goes elsewhere while the question is up
        await until { panel.path == b && panel.listedItems.count == 1 }
        return out + "/f.zip"
    }
    defer { AppDelegate.prompting = nil }
    app.compressDialog()
    let over = { (name: String) in NSApp.windows.first { $0.title.hasSuffix("/" + name) }?.docFrame?.text.hasPrefix("exit") == true }
    await until { over("f.zip") && FileManager.default.fileExists(atPath: out + "/f.zip") }
    let index = try ArchiveIndex.read(out + "/f.zip")
    try index.extract(["f.txt"], from: "", to: out + "/x")
    #expect(try String(contentsOfFile: out + "/x/f.txt", encoding: .utf8) == "A", "the item asked about, not the folder's the panel went to")
    #expect(try FileManager.default.contentsOfDirectory(atPath: out).sorted() == ["f.zip", "x"], "no packing file left")

    // tar fails — the item gone while the question was up: nothing under the archive's name, no packing file.
    FileManager.default.createFile(atPath: b + "/g.txt", contents: Data("G".utf8))
    for _ in 0..<60 where panel.cursorURL?.lastPathComponent != "g.txt" {
        panel.reload(select: "g.txt")
        await until({ panel.cursorURL?.lastPathComponent == "g.txt" }, seconds: 1)
    }
    try #require(panel.cursorURL?.path == b + "/g.txt")
    AppDelegate.prompting = { _ in try? FileManager.default.removeItem(atPath: b + "/g.txt"); return out + "/g.zip" }
    app.compressDialog()
    await until { NSApp.windows.contains { $0.title.hasSuffix("/g.zip") } }
    try #require(NSApp.windows.contains { $0.title.hasSuffix("/g.zip") }, "the second Compress ran")
    await until { over("g.zip") && !((try? FileManager.default.contentsOfDirectory(atPath: out)) ?? []).contains { $0.hasPrefix(".dfm-pack-") } }
    try? await Task.sleep(for: .milliseconds(300))
    #expect(try FileManager.default.contentsOfDirectory(atPath: out).sorted() == ["f.zip", "x"], "no g.zip that looks whole")
}

/// A tar that fails (an item gone) leaves neither the archive nor its packing file; a file that appeared under the
/// archive's name while it packed stays as it is.
@Test func aFailedOrBeatenPackLeavesNothingOfItsOwn() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/f.txt", contents: Data("f".utf8))
    let archive = dir + "/out.tar.gz", tmp = ArchiveIndex.packingPath(for: archive)
    #expect((tmp as NSString).lastPathComponent.hasPrefix(".dfm-pack-") && tmp.hasSuffix(".tar.gz") && (tmp as NSString).deletingLastPathComponent == dir)
    let long = "1. " + String(repeating: "й", count: 120) + ".zip"   // 248 bytes: the name fits, so must the packing one
    let packing = (ArchiveIndex.packingPath(for: "/d/" + long) as NSString).lastPathComponent
    #expect(packing.hasSuffix(".zip") && packing.utf8.count < 255, "\(packing)")
    #expect(ArchiveIndex.packingPath(for: "/d/x.TAR.XZ").hasSuffix(".TAR.XZ"))

    let failed = try tar(ArchiveIndex.createArguments(tmp, names: ["f.txt", "gone"], in: dir), in: dir)
    #expect(failed != 0 && FileManager.default.fileExists(atPath: tmp), "tar leaves what it wrote")
    try ArchiveIndex.publish(tmp, as: archive, exit: failed)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["f.txt"])

    #expect(try tar(ArchiveIndex.createArguments(tmp, names: ["f.txt"], in: dir), in: dir) == 0)
    FileManager.default.createFile(atPath: archive, contents: Data("theirs".utf8))   // appeared meanwhile
    #expect(throws: ArchiveError.self) { try ArchiveIndex.publish(tmp, as: archive, exit: 0) }
    #expect(FileManager.default.contents(atPath: archive) == Data("theirs".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["f.txt", "out.tar.gz"])

    try FileManager.default.removeItem(atPath: archive)
    #expect(try tar(ArchiveIndex.createArguments(tmp, names: ["f.txt"], in: dir), in: dir) == 0)
    try ArchiveIndex.publish(tmp, as: archive, exit: 0)
    #expect(try ArchiveIndex.read(archive).list("")?.map(\.name) == ["f.txt"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["f.txt", "out.tar.gz"])
}

/// В2: a save whose copyfile failed (an ACL or an xattr the disk won't take) left the file 0600 and said nothing. Its
/// mode comes over at least now, and the save says what didn't.
@Test func aSaveThatCantCarryTheAttributesKeepsTheModeAndSaysSo() throws {
    let dir = try tempDir(), path = dir + "/notes.txt"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644])
    let written = Editor.write(Data("new".utf8), to: path, name: "notes.txt", unlessChangedFrom: nil, hook: { _ in },
                               writing: { try $0.write(contentsOf: $1) }, willRename: { _ in },
                               copyAttributes: { _, _ in errno = ENOTSUP; return -1 })
    guard case .written(_, _, let note) = written else { Issue.record("\(written)"); return }
    #expect(note?.contains("permissions only") == true, "\(String(describing: note))")
    #expect(FileManager.default.contents(atPath: path) == Data("new".utf8))
    #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o644)

    // Its group too: else it takes the folder's, and the group bits would be for another group. On the Mac's own temp
    // folder: the tests' RAM disk ignores owners.
    let own = Foundation.NSTemporaryDirectory() + "dfm-r6s-" + UUID().uuidString, file = own + "/notes.txt"
    try FileManager.default.createDirectory(atPath: own, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: own) }
    FileManager.default.createFile(atPath: file, contents: Data("old".utf8), attributes: [.posixPermissions: 0o640])
    var groups = [gid_t](repeating: 0, count: 64), st = stat()
    let n = Int(getgroups(Int32(groups.count), &groups))
    stat(own, &st)
    let other = try #require(groups.prefix(max(n, 0)).first { $0 != st.st_gid }, "a second group of ours")
    chown(file, geteuid(), other)
    stat(file, &st)
    try #require(st.st_gid == other, "this disk keeps owners")
    _ = Editor.write(Data("new".utf8), to: file, name: "notes.txt", unlessChangedFrom: nil, hook: { _ in },
                     writing: { try $0.write(contentsOf: $1) }, willRename: { _ in }, copyAttributes: { _, _ in errno = ENOTSUP; return -1 })
    stat(file, &st)
    #expect(st.st_gid == other && st.st_mode & 0o7777 == 0o640, "gid \(st.st_gid), not \(other); mode \(String(st.st_mode & 0o7777, radix: 8))")
}

/// В3: the askpass script was written once a launch, in /tmp, which macOS's daily cleanup empties of files untouched
/// for 3 days: a Kermo running longer asked no password again. Gone, it's written again — its folder too, 0700.
@Test func theAskpassScriptComesBackAfterTmpsCleanup() throws {
    let root = try tempDir(), dir = root + "/ssh"
    defer { try? FileManager.default.removeItem(atPath: root) }
    let mode = { (p: String) in (try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? Int) ?? nil }
    #expect(SSHAskpass.env(in: dir)["SSH_ASKPASS"] == dir + "/askpass")
    #expect(mode(dir) == 0o700 && mode(dir + "/askpass") == 0o700)
    unlink(dir + "/askpass")
    _ = SSHAskpass.env(in: dir)
    #expect(mode(dir + "/askpass") == 0o700, "written again")
    try FileManager.default.removeItem(atPath: dir)
    _ = SSHAskpass.env(in: dir)
    #expect(mode(dir) == 0o700 && mode(dir + "/askpass") == 0o700, "its folder too")
    #expect(try String(contentsOfFile: dir + "/askpass", encoding: .utf8) == SSHAskpass.script())

    // The folder isn't ours (a link to another one, say): no script in it is given to ssh.
    try FileManager.default.removeItem(atPath: dir)
    try FileManager.default.createDirectory(atPath: root + "/elsewhere", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: dir, withDestinationPath: root + "/elsewhere")
    let env = SSHAskpass.env(in: dir)
    #expect(env["SSH_ASKPASS"] == nil && env["SSH_ASKPASS_REQUIRE"] == "never", "\(env)")
    #expect(!FileManager.default.fileExists(atPath: root + "/elsewhere/askpass"))
}
