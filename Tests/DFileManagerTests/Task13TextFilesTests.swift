import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Text files Quick Look shows as an icon, and the file actions next to them.

@MainActor private func waitUntil(_ done: () -> Bool) async {
    for _ in 0..<500 { if done() { return }; try? await Task.sleep(for: .milliseconds(10)) }
}
private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t13text-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// ⌃Q: a text with a name Quick Look doesn't know shows as text, F3's colors; a binary one, and what Quick Look
/// knows, stay with Quick Look; over 256 KB, the first part and a line that says so.
@MainActor @Test func quickViewShowsTextQuickLookWouldNot() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    FileManager.default.createFile(atPath: d + "/hosts", contents: Data("127.0.0.1 localhost\n".utf8))
    FileManager.default.createFile(atPath: d + "/blob", contents: Data([0x7f, 0x45, 0x4c, 0x46] + [UInt8](repeating: 0, count: 64) + [1, 2, 3]))
    FileManager.default.createFile(atPath: d + "/notes.txt", contents: Data("plain\n".utf8))
    FileManager.default.createFile(atPath: d + "/big.conf", contents: Data(repeating: UInt8(ascii: "x"), count: TextPeek.limit + 10))
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    panel.setQuickView(true)
    panel.preview(URL(fileURLWithPath: d + "/hosts"))
    await waitUntil { panel.peekedText != nil }
    #expect(panel.peekedText == "127.0.0.1 localhost\n")
    panel.preview(URL(fileURLWithPath: d + "/blob"))
    await waitUntil { panel.peekedText == nil }
    #expect(panel.peekedText == nil, "binary: Quick Look's")
    panel.preview(URL(fileURLWithPath: d + "/big.conf"))
    await waitUntil { panel.peekedText != nil }
    #expect(panel.peekedText?.hasSuffix("··· first 256 KB · F3 views it all ···\n") == true)
    #expect(panel.peekedText?.utf16.count == TextPeek.limit + "\n\n··· first 256 KB · F3 views it all ···\n".utf16.count)
    panel.preview(URL(fileURLWithPath: d + "/notes.txt"))
    #expect(panel.peekedText == nil, "Quick Look shows .txt itself, at once")
    panel.preview(URL(fileURLWithPath: d + "/hosts"))
    await waitUntil { panel.peekedText != nil }
    panel.preview(URL(fileURLWithPath: d))   // a folder: Quick Look's, once looked at
    await waitUntil { panel.peekedText == nil }
    #expect(panel.peekedText == nil)
    // No setQuickView(false): QLPreviewView's close asserts outside a window.
}

/// ⌘Y: texts get a `.txt` copy, binary files none; each call's copies replace the ones before.
@Test func quickLookGetsTxtCopiesOfTexts() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    FileManager.default.createFile(atPath: d + "/hosts", contents: Data("127.0.0.1 localhost\n".utf8))
    FileManager.default.createFile(atPath: d + "/blob", contents: Data([0x7f, 0x45, 0x4c, 0x46] + [UInt8](repeating: 0, count: 64)))
    let hosts = URL(fileURLWithPath: d + "/hosts"), blob = URL(fileURLWithPath: d + "/blob")
    let first = TextCopies.make([hosts, blob, URL(fileURLWithPath: d)])
    #expect(first.keys.map(\.path) == [hosts.path])
    let copy = try #require(first[hosts])
    #expect(copy.lastPathComponent == "hosts.txt" && copy.path.hasPrefix(TextCopies.dir + "/"))
    #expect(FileManager.default.contents(atPath: copy.path) == Data("127.0.0.1 localhost\n".utf8))
    let second = TextCopies.make([hosts])
    #expect(!FileManager.default.fileExists(atPath: copy.path), "the ones before go")
    #expect(second[hosts].map { FileManager.default.fileExists(atPath: $0.path) } == true)
    TempCopies.remove(TextCopies.dir)
}

/// ⇧F5: one copy under the typed name, several with the typed suffix — each next to itself (a search lists many folders).
@Test func copiesAsGoNextToThemselves() {
    #expect(AppDelegate.copiesAs(["/a/x.conf"], "x.conf.bak").map(\.to) == ["/a/x.conf.bak"])
    #expect(AppDelegate.copiesAs(["/a/x.conf", "/b/y"], ".bak").map(\.to) == ["/a/x.conf.bak", "/b/y.bak"])
    #expect(AppDelegate.copiesAs(["/a/x"], "y").map(\.from) == ["/a/x"])
}

/// ⇧F5 here: a folder goes whole under its new name, the original as it was.
@Test func aFolderCopiesAsAWhole() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d + "/conf.d/sub", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: d + "/conf.d/sub/a.conf", contents: Data("a\n".utf8))
    let (from, to) = AppDelegate.copiesAs([d + "/conf.d"], "conf.d.bak")[0]
    let job = FileJob(.copy, sources: [from], destDir: d, targetName: (to as NSString).lastPathComponent)
    job.run()
    #expect(FileManager.default.contents(atPath: d + "/conf.d.bak/sub/a.conf") == Data("a\n".utf8))
    #expect(FileManager.default.fileExists(atPath: d + "/conf.d/sub/a.conf"))
}

/// Each runs this Mac's sftp-server: they take turns.
@Suite(.serialized) @MainActor struct TextFileServerTests {

/// ⇧F5 on a server: a copy there under the new name (`copy-data` when the server has it).
@Test func aServerFileCopiesAsThere() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    FileManager.default.createFile(atPath: d + "/site.conf", contents: Data("listen 80;\n".utf8))
    let canCopyData = try SFTPClient.session(.local(), cancel: CancelFlag()) { $0.canCopyData }
    let job = FileJob(.copy, sources: [d + "/site.conf"], from: .sftp(.local()), to: .sftp(.local()), destDir: d, targetName: "site.conf.bak")
    job.run()
    #expect(job.progress.errors.isEmpty)
    #expect(FileManager.default.contents(atPath: d + "/site.conf.bak") == Data("listen 80;\n".utf8), "copy-data: \(canCopyData)")
}

/// ⇧F5 never replaces: a name that's there (a dangling link too) is taken, here and on a server.
@Test func copyAsSeesTakenNames() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    FileManager.default.createFile(atPath: d + "/a.bak", contents: nil)
    try FileManager.default.createSymbolicLink(atPath: d + "/gone.bak", withDestinationPath: d + "/nowhere")
    let paths = [d + "/a.bak", d + "/gone.bak", d + "/free.bak"]
    #expect(AppDelegate.taken(paths, on: nil) == [d + "/a.bak", d + "/gone.bak"])
    #expect(try SFTPClient.session(.local(), cancel: CancelFlag()) { AppDelegate.taken(paths, on: $0) } == [d + "/a.bak", d + "/gone.bak"])
}

/// ⇧F4 on a server: an empty `rw-r--r--` file; an existing one is an error and keeps what it had.
@Test func aNewServerFileNeverEmptiesOne() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    FileManager.default.createFile(atPath: d + "/taken.conf", contents: Data("keep\n".utf8))
    try SFTPClient.session(.local(), cancel: CancelFlag()) { c in
        try AppDelegate.newServerFile(c, d + "/new.conf")
        #expect(throws: (any Error).self) { try AppDelegate.newServerFile(c, d + "/taken.conf") }
    }
    let a = try FileManager.default.attributesOfItem(atPath: d + "/new.conf")
    #expect(a[.size] as? Int == 0 && a[.posixPermissions] as? Int == 0o644)
    #expect(FileManager.default.contents(atPath: d + "/taken.conf") == Data("keep\n".utf8))
}
}
