import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

@MainActor
private func waitUntil(_ done: () -> Bool) async {
    for _ in 0..<1000 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
private func serverPanel(_ dir: String) async throws -> PanelViewController {
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    panel.loadRemote(.local(), dir: dir, select: nil)
    await waitUntil { panel.remote?.dir == dir }
    try #require(panel.remote?.dir == dir)
    return panel
}

private func tempDir(_ tag: String) throws -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-\(tag)-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d + "/one/deep", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: d + "/two", withIntermediateDirectories: true)
    try Data("abc".utf8).write(to: URL(fileURLWithPath: d + "/one/deep/a"))
    try Data("hello".utf8).write(to: URL(fileURLWithPath: d + "/two/b"))
    return d
}

/// ⌥Space on a server counts every folder (this Mac's du has no -b: walked); Space down the list queues each after the
/// walk running; another folder starts with none.
@MainActor @Test func serverFolderSizes() async throws {
    let d = try tempDir("rsizes")
    defer { try? FileManager.default.removeItem(atPath: d) }
    let panel = try await serverPanel(d)
    defer { panel.shutdown() }
    #expect(panel.statusText.hasPrefix("🌐 sftp · localhost · 2 items · ") && panel.statusText.hasSuffix(" free"), "what's free there, as on this Mac")

    panel.computeAllDirSizes()
    await waitUntil { panel.dirSizes.count == 2 }
    #expect(panel.dirSizes == ["one": 3, "two": 5])

    panel.loadRemote(.local(), dir: d + "/one", select: nil)
    await waitUntil { panel.remote?.dir == d + "/one" }
    #expect(panel.dirSizes.isEmpty)
    panel.loadRemote(.local(), dir: d, select: nil)
    await waitUntil { panel.remote?.dir == d }
    panel.moveCursor(toName: "one")
    panel.toggleMark(move: 0)
    panel.moveCursor(toName: "two")
    panel.toggleMark(move: 0)   // while "one" is still being counted
    await waitUntil { panel.dirSizes.count == 2 }
    #expect(panel.dirSizes == ["one": 3, "two": 5])
}

/// A server's du gives the sizes it can (one "at least": ≥ in the Size column), a name it left out is walked; a server
/// whose du doesn't count is remembered, and walked from then on without asking it again.
@MainActor @Test func serverSizesByDu() async throws {
    let d = try tempDir("rdu")
    defer { try? FileManager.default.removeItem(atPath: d) }
    let name = "sftp-server-du-" + UUID().uuidString.prefix(8)   // a target of its own: `noDu` isn't another test's
    try FileManager.default.createSymbolicLink(atPath: d + "/" + name, withDestinationPath: "/usr/libexec/sftp-server")
    let t = SFTPTarget.local(server: d + "/" + name)
    final class Asked: @unchecked Sendable {   // touched on the main thread only
        var names: [[String]] = []
        var answer: [String: ServerSizes.Size]? = ["one": .init(bytes: 4096, partial: true)]
    }
    let asked = Asked()
    let real = PanelViewController.measureRemote
    PanelViewController.measureRemote = { names, dir, target, env, cancel in
        guard target == t else { return try real(names, dir, target, env, cancel) }   // another test's
        return DispatchQueue.main.sync {
            asked.names.append(names)
            return asked.answer
        }
    }
    defer { PanelViewController.measureRemote = real }
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    panel.loadRemote(t, dir: d, select: nil)
    await waitUntil { panel.remote?.dir == d }

    panel.computeAllDirSizes()
    await waitUntil { panel.dirSizes.count == 2 }
    #expect(panel.dirSizes == ["one": 4096, "two": 5] && panel.partialSizes == ["one"], "two: walked")
    #expect(asked.names == [["one", "two"]])
    panel.moveCursor(toName: "one")
    let row = panel.table.selectedRow
    let cell = panel.tableView(panel.table, viewFor: panel.table.tableColumns.first { $0.identifier.rawValue == "size" }, row: row) as? NSTableCellView
    #expect(cell?.textField?.stringValue.hasPrefix("≥ ") == true)

    asked.answer = nil   // this server's du doesn't count
    panel.loadRemote(t, dir: d + "/one", select: nil)
    await waitUntil { panel.remote?.dir == d + "/one" }
    panel.computeAllDirSizes()
    await waitUntil { panel.dirSizes.count == 1 }
    #expect(panel.dirSizes == ["deep": 3] && asked.names.count == 2 && PanelViewController.noDu.contains(t))
    panel.loadRemote(t, dir: d, select: nil)
    await waitUntil { panel.remote?.dir == d }
    panel.computeAllDirSizes()
    await waitUntil { panel.dirSizes.count == 2 }
    #expect(panel.dirSizes == ["one": 3, "two": 5] && asked.names.count == 2, "not asked again")
    PanelViewController.noDu.remove(t)
}

/// The app's copies of server files (`ServerCopies`) are one list: these tests take turns.
@Suite(.serialized) @MainActor struct ServerCopiesTests {

/// ⌃Q / ⌘Y on a server show a local copy of the cursor's file once fetched; a folder or a file over the cap has
/// none; the copies outlive the folder (Quick Look's Open with may have one open in another app) until quit.
@Test func serverFilePreviews() async throws {
    let d = try tempDir("rpreview")
    defer { try? FileManager.default.removeItem(atPath: d) }
    let big = open(d + "/two/big.bin", O_CREAT | O_WRONLY, 0o600)   // sparse: nothing written
    ftruncate(big, PanelViewController.previewLimit + 1)
    close(big)
    try Data("c".utf8).write(to: URL(fileURLWithPath: d + "/c"))
    let panel = try await serverPanel(d + "/two")
    defer { panel.shutdown() }

    panel.moveCursor(toName: "b")
    #expect(panel.previewURL() == nil)   // on its way
    await waitUntil { panel.previewURL() != nil }
    let copy = try #require(panel.previewURL())
    #expect(copy.lastPathComponent == "b" && (try? String(contentsOf: copy, encoding: .utf8)) == "hello")
    #expect(panel.quickLookURLs == [copy])

    panel.moveCursor(toName: "big.bin")
    #expect(panel.previewURL() == nil)
    panel.moveCursor(toName: "b")
    #expect(panel.previewURL() == copy)
    try await Task.sleep(for: .milliseconds(500))
    #expect(!panel.statusText.contains("too big"))   // only passed by

    panel.moveCursor(toName: "big.bin")
    #expect(panel.previewURL() == nil)
    await waitUntil { panel.statusText.contains("too big") }   // once it rested there: by the clock it's flaky (busy main actor)
    #expect(panel.statusText.contains("too big"))
    #expect(panel.previewURL() == nil && panel.quickLookURLs.isEmpty)

    panel.moveCursor(toName: "b")
    #expect(panel.previewURL() == copy)   // still here: not fetched again

    panel.loadRemote(.local(), dir: d, select: nil)
    await waitUntil { panel.remote?.dir == d }
    #expect(FileManager.default.fileExists(atPath: copy.path))
    panel.moveCursor(toName: "one")
    #expect(panel.previewURL() == nil)

    ServerCopies.quit()   // untouched: they go
    #expect(!FileManager.default.fileExists(atPath: copy.path))
}

/// A server file's copy another app saves (↩, Quick Look's Open with) goes up once it stops changing — only when
/// the bytes changed; one that didn't make it is kept at quit.
@Test func anotherAppsSaveGoesToTheServer() async throws {
    let d = try tempDir("rcopy")
    defer { try? FileManager.default.removeItem(atPath: d) }
    try Data("one\n".utf8).write(to: URL(fileURLWithPath: d + "/srv.txt"))
    let tmp = NSTemporaryDirectory() + "dfm-sftp-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let local = URL(fileURLWithPath: tmp + "/srv.txt")
    let attrs = try SFTPClient.session(.local(), cancel: CancelFlag()) { try $0.download(d + "/srv.txt", to: local.path) }
    func server() -> String? { FileManager.default.contents(atPath: d + "/srv.txt").map { String(decoding: $0, as: UTF8.self) } }
    var sent = 0
    ServerCopies.upload = { c in
        sent += 1
        guard let a = try? SFTPClient.session(.local(), cancel: CancelFlag(), { try $0.upload(c.url.path, to: c.path, baseline: c.state.baseline) })
        else { return false }
        c.state.baseline = a
        return true
    }
    let copy = ServerCopies.Copy(local, .local(), d + "/srv.txt", listed: (attrs.size, attrs.mtime), baseline: attrs, preview: false)
    ServerCopies.add(copy)
    ServerCopies.tick()
    #expect(sent == 0)   // untouched

    try Data("two\n".utf8).write(to: local)
    ServerCopies.tick()
    #expect(sent == 0)   // still being written, maybe
    ServerCopies.tick()
    await waitUntil { copy.pending == 0 && server() == "two\n" }
    #expect(sent == 1 && server() == "two\n" && copy.synced && copy.uploaded)

    try Data("two\n".utf8).write(to: local)   // the same bytes saved again
    ServerCopies.tick()
    ServerCopies.tick()
    #expect(sent == 1)

    ServerCopies.upload = { _ in false }   // declined (production) or failed
    try Data("three\n".utf8).write(to: local)
    ServerCopies.tick()
    ServerCopies.tick()
    await waitUntil { copy.pending == 0 }
    #expect(ServerCopies.unsynced.map(\.url) == [local] && server() == "two\n")
    ServerCopies.quit()
    #expect(FileManager.default.fileExists(atPath: local.path))   // the only copy of that text
    #expect(FileManager.default.fileExists(atPath: tmp + "/" + TempCopies.keptMarker))
}

/// The byte budget takes the oldest untouched previews, never one an app edited.
@Test func previewBudgetSparesEditedCopies() throws {
    func copy(_ name: String, _ mb: Int64, preview: Bool = true) throws -> ServerCopies.Copy {
        let tmp = NSTemporaryDirectory() + "dfm-sftp-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmp + "/" + name, contents: Data())
        let a = SFTPClient.Attrs(kind: .file, size: mb << 20, mtime: 0)   // what the server said: no bytes here
        return ServerCopies.Copy(URL(fileURLWithPath: tmp + "/" + name), .local(), "/srv/" + name, listed: (a.size, 0), baseline: a, preview: preview)
    }
    let edited = try copy("edited", 200), old = try copy("old", 200), new = try copy("new", 100)
    edited.uploaded = true
    ServerCopies.add(edited)
    ServerCopies.add(old)
    ServerCopies.add(new)
    #expect(ServerCopies.copies.map(\.url) == [edited.url, new.url])
    #expect(!FileManager.default.fileExists(atPath: old.dir) && FileManager.default.fileExists(atPath: edited.url.path))
    ServerCopies.quit()
    #expect(!FileManager.default.fileExists(atPath: edited.dir) && !FileManager.default.fileExists(atPath: new.dir))
}
}
