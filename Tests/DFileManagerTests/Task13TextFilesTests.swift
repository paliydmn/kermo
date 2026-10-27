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
@MainActor @Test func quickLookGetsTxtCopiesOfTexts() throws {
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
    // Two search hits with one name: a copy each.
    try FileManager.default.createDirectory(atPath: d + "/a", withIntermediateDirectories: false)
    try FileManager.default.createDirectory(atPath: d + "/b", withIntermediateDirectories: false)
    FileManager.default.createFile(atPath: d + "/a/config", contents: Data("a\n".utf8))
    FileManager.default.createFile(atPath: d + "/b/config", contents: Data("b\n".utf8))
    let a = URL(fileURLWithPath: d + "/a/config"), b = URL(fileURLWithPath: d + "/b/config")
    let both = TextCopies.make([a, b])
    #expect(both[a].flatMap { FileManager.default.contents(atPath: $0.path) } == Data("a\n".utf8))
    #expect(both[b].flatMap { FileManager.default.contents(atPath: $0.path) } == Data("b\n".utf8))
    // One asked for earlier that runs later leaves the newer copies alone.
    let older = TextCopies.ticket(), newer = TextCopies.ticket()
    let kept = TextCopies.make([hosts], ticket: newer)
    #expect(TextCopies.make([a], ticket: older).isEmpty)
    #expect(kept[hosts].map { FileManager.default.fileExists(atPath: $0.path) } == true)
    // Past the first ones: a copy as Quick Look comes to it, next to the latest ones; none once newer ones came.
    let more = TextCopies.one(b, ticket: newer)
    #expect(more.flatMap { FileManager.default.contents(atPath: $0.path) } == Data("b\n".utf8))
    #expect(kept[hosts].map { FileManager.default.fileExists(atPath: $0.path) } == true)
    #expect(TextCopies.one(blob, ticket: newer) == nil, "binary: Quick Look's")
    _ = TextCopies.make([], ticket: TextCopies.ticket())
    #expect(TextCopies.one(a, ticket: newer) == nil)
    #expect(!FileManager.default.fileExists(atPath: more!.path))
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

/// A server's folder menu: SSH Here, its services and containers; nothing that's this Mac's only.
@Test func aServersFolderMenu() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    panel.loadRemote(.local(), dir: d, select: nil)
    await waitUntil { panel.remote?.dir == d }
    let menu = NSMenu()
    panel.fillMenu(menu, row: -1)
    #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["New File…", "New Folder…", "Paste", "SSH Here", "Copy Path", "Show Hidden Files",
                                                                      "Sort By", "Calculate Folder Sizes", "Services…", "Containers…"])
    // Copy Path there: the server's paths — the folder's from its menu, the cursor's file's otherwise.
    FileManager.default.createFile(atPath: d + "/site.conf", contents: nil)
    panel.reload(select: "site.conf")
    await waitUntil { panel.currentName == "site.conf" }
    #expect(panel.targetPaths == [d + "/site.conf"])
    var seen: [String] = []
    panel.onCommand = { _ in seen = panel.targetPaths }
    menu.performActionForItem(at: menu.indexOfItem(withTitle: "Copy Path"))
    #expect(seen == [d])
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
        #expect { try AppDelegate.newServerFile(c, d + "/taken.conf") } throws: { $0.localizedDescription == "“taken.conf” already exists." }
    }
    let a = try FileManager.default.attributesOfItem(atPath: d + "/new.conf")
    #expect(a[.size] as? Int == 0 && a[.posixPermissions] as? Int == 0o644)
    #expect(FileManager.default.contents(atPath: d + "/taken.conf") == Data("keep\n".utf8))
}
}

/// Right-click on empty space or "..": the folder's menu, each item a command acting on the folder (Copy Path: its
/// path, not the cursor's file). A row's has New File… and Copy Here As….
@MainActor @Test func theFolderMenuIsCommands() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    FileManager.default.createFile(atPath: d + "/a.conf", contents: nil)
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.listedItems.count == 1 }
    panel.moveCursor(toName: "a.conf")
    let sorts = UserDefaults.standard.object(forKey: "folderSort")
    defer { UserDefaults.standard.set(sorts, forKey: "folderSort") }
    let ids = Set(AppDelegate().makeCommands().map(\.id))
    func items(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }

    let folder = NSMenu()
    panel.fillMenu(folder, row: -1)
    #expect(folder.items.filter { !$0.isSeparatorItem }.map(\.title) == ["New File…", "New Folder…", "Paste", "Open in Terminal", "Copy Path",
                                                                        "Reveal in Finder", "Get Info", "Show Hidden Files", "Sort By", "Calculate Folder Sizes"])
    #expect(items(folder).compactMap { $0.representedObject as? String }.allSatisfy(ids.contains))
    #expect(items(folder).first { $0.title == "Name" }?.state == .on && items(folder).first { $0.title == "Reverse" }?.state == .off)
    var seen: [URL] = []
    panel.onCommand = { _ in seen = panel.targetURLs }
    folder.performActionForItem(at: folder.indexOfItem(withTitle: "Copy Path"))
    #expect(seen.map(\.path) == [d])
    #expect(panel.targetURLs.map(\.lastPathComponent) == ["a.conf"], "after it, the cursor's again")
    let parent = NSMenu()
    panel.fillMenu(parent, row: 0)   // ".."
    #expect(parent.items.map(\.title) == folder.items.map(\.title))

    let row = NSMenu()
    panel.fillMenu(row, row: 1)
    let titles = row.items.map(\.title)
    #expect(titles.firstIndex(of: "New File…")! < titles.firstIndex(of: "Rename…")!)
    #expect(titles.firstIndex(of: "Copy Here As…") == titles.firstIndex(of: "Rename…")! + 1)
    #expect(row.items.compactMap { $0.representedObject as? String }.filter { $0 != "open" }.allSatisfy(ids.contains))

    // Sort By acts as a header click would; Reverse turns it round.
    panel.reverseSort()
    let reversed = NSMenu()
    panel.fillMenu(reversed, row: -1)
    #expect(items(reversed).first { $0.title == "Reverse" }?.state == .on)
    panel.sort(by: .size)
    #expect(panel.table.sortDescriptors.first?.key == "size" && panel.table.sortDescriptors.first?.ascending == false)
    panel.sort(by: .name)
}

/// The Shift layer of the key bar: the file actions side by side, as F-keys in order.
@MainActor @Test func theShiftLayerHasTheFileActionsInOrder() {
    let shift = KeyBarModel.layers(AppDelegate().makeCommands()).first { $0.mods == .shift }!.slots
    let fkeys = shift.filter { $0.key.hasPrefix("⇧F") }.map { "\($0.key) \($0.label)" }
    #expect(fkeys == ["⇧F2 Differences", "⇧F4 New File", "⇧F5 Copy Here As", "⇧F6 Rename", "⇧F8 Delete", "⇧F10 Menu"], "\(shift.map(\.key))")
}

/// The production log names where a copy went: the new name for one copied under it.
@MainActor @Test func theLogNamesACopysNewName() {
    #expect(AuditLog.destination(FileJob(.copy, sources: ["/s/a"], destDir: "/s", targetName: "a.bak")) == "/s/a.bak")
    #expect(AuditLog.destination(FileJob(.copy, sources: ["/s/a", "/s/b"], destDir: "/d")) == "/d")
    #expect(AuditLog.destination(FileJob(.delete, sources: ["/s/a"])) == nil)
}
