import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Editor E1: Save As is a transaction — the editor takes `dest` as its file only once the text is there whole. Every
// way out before that (a failure, a Cancel) leaves the document as it was: the same file, a server's file still bound.

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-saveas-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func put(_ s: String, _ path: String, mode: Int = 0o644) throws {
    try Data(s.utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, mode_t(mode))
}

private func read(_ path: String) -> String? { FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } }

private func mode(_ path: String) -> mode_t { var st = stat(); stat(path, &st); return st.st_mode & 0o777 }

private func umasked(_ m: mode_t) -> mode_t { let u = umask(0); umask(u); return m & ~u }

@MainActor private func waitUntil(_ what: String, _ cond: () -> Bool) async throws {
    for _ in 0..<250 where !cond() { try await Task.sleep(for: .milliseconds(20)) }
    #expect(cond(), "\(what)")
}

/// Answers the sheet on `w` once it is up.
@MainActor private func answer(_ w: NSWindow?, _ code: NSApplication.ModalResponse) async throws {
    try await waitUntil("a sheet") { w?.attachedSheet != nil }
    guard let w, let sheet = w.attachedSheet else { return }
    w.endSheet(sheet, returnCode: code)
    try await waitUntil("sheet gone") { w.attachedSheet !== sheet }
}

/// Dismisses the error sheet a failed Save As shows, saying what it said.
@MainActor private func dismissed(_ w: NSWindow?) async throws -> String {
    try await waitUntil("an error sheet") { w?.attachedSheet != nil }
    let said = (w?.attachedSheet.flatMap { s in s.contentView.map(allText) } ?? []).joined(separator: " ")
    try await answer(w, .alertFirstButtonReturn)
    return said
}

@MainActor private func allText(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(allText) }

/// A server file's editor, as F4 opens it: its local copy in a folder of its own, bound to `path` on `t`.
@MainActor private func serverEditor(_ dir: String, _ t: SFTPTarget, _ path: String, mode: UInt32? = 0o600, saved: @escaping @MainActor (URL) -> Void = { _ in })
    async throws -> (Editor, URL) {
    let copy = URL(fileURLWithPath: dir + "/copy/" + (path as NSString).lastPathComponent)
    try FileManager.default.createDirectory(atPath: dir + "/copy", withIntermediateDirectories: true)
    try put("SECRET=1\n", copy.path, mode: 0o600)
    let state = AppDelegate.RemoteEdit(baseline: SFTPClient.Attrs(kind: .file, size: 9, mtime: 100, mode: mode))
    Editor.open(copy, remote: "web:" + path, server: (t, path, state), onSaved: saved)
    try await waitUntil("opened") { Editor.editing(t, path) != nil }
    return (try #require(Editor.editing(t, path)), copy)
}

/// A local file's Save As: a new file gets the source's mode (a 0600 secret isn't readable by others after it); a file
/// the panel asked to replace keeps its own mode, as a save keeps it. Through a symlink into its target, the link stays;
/// a link to nothing, or a folder, isn't written. Save As onto this very file is a save.
@MainActor @Test func saveAsOfALocalFileKeepsItsModeAndFollowsLinks() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let fm = FileManager.default
    try put("token\n", dir + "/a.key", mode: 0o600)
    let e = try Editor(URL(fileURLWithPath: dir + "/a.key"))
    defer { e.close() }
    e.textView.string = "token 2\n"
    #expect(await e.saveAs(URL(fileURLWithPath: dir + "/b.key")))
    #expect(mode(dir + "/b.key") == 0o600 && read(dir + "/b.key") == "token 2\n" && read(dir + "/a.key") == "token\n")

    try put("old\n", dir + "/shared.txt", mode: 0o644)
    #expect(await e.saveAs(URL(fileURLWithPath: dir + "/shared.txt")))
    #expect(mode(dir + "/shared.txt") == 0o644 && read(dir + "/shared.txt") == "token 2\n", "replaced: its own mode")

    try put("target\n", dir + "/real.conf")
    try fm.createSymbolicLink(atPath: dir + "/link.conf", withDestinationPath: "real.conf")
    #expect(await e.saveAs(URL(fileURLWithPath: dir + "/link.conf")))
    #expect(try fm.destinationOfSymbolicLink(atPath: dir + "/link.conf") == "real.conf" && read(dir + "/real.conf") == "token 2\n")
    #expect(e.url == URL(fileURLWithPath: dir + "/link.conf"))
    e.textView.string = "token 3\n"
    #expect(await e.saveAs(URL(fileURLWithPath: dir + "/real.conf")), "the same file: a save")
    #expect(read(dir + "/real.conf") == "token 3\n" && e.url == URL(fileURLWithPath: dir + "/link.conf"))

    try fm.createSymbolicLink(atPath: dir + "/dangling.conf", withDestinationPath: "nowhere/x.conf")
    #expect(await !e.saveAs(URL(fileURLWithPath: dir + "/dangling.conf")))
    #expect(try await dismissed(e.window).contains("isn't there"))
    #expect(try fm.destinationOfSymbolicLink(atPath: dir + "/dangling.conf") == "nowhere/x.conf" && !fm.fileExists(atPath: dir + "/nowhere"))
    #expect(mkfifo(dir + "/pipe", 0o644) == 0)
    #expect(await !e.saveAs(URL(fileURLWithPath: dir + "/pipe")), "not read while looking at it: a FIFO waits for good")
    #expect(try await dismissed(e.window).contains("a FIFO"))
    try fm.createDirectory(atPath: dir + "/folder", withIntermediateDirectories: true)
    #expect(await !e.saveAs(URL(fileURLWithPath: dir + "/folder")))
    #expect(try await dismissed(e.window).contains("a folder"))
    #expect(e.url == URL(fileURLWithPath: dir + "/link.conf"), "still the same file")
}

/// The encoding question counts for Save As too: Cancel there writes nothing and keeps the file; a file that appeared
/// at `dest` while it was up isn't written over; Save writes Windows-1251.
@MainActor @Test func saveAsAsksAboutTheEncoding() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let cp = dir + "/old.conf", text = "# Коментар\n".data(using: .windowsCP1251)!
    try text.write(to: URL(fileURLWithPath: cp))
    let e = try Editor(URL(fileURLWithPath: cp))
    defer { e.close() }
    let dest = URL(fileURLWithPath: dir + "/new.conf")
    #expect(await !e.saveAs(dest))
    try await answer(e.window, .alertSecondButtonReturn)   // Cancel
    #expect(!FileManager.default.fileExists(atPath: dest.path) && e.url == URL(fileURLWithPath: cp))

    #expect(await !e.saveAs(dest))
    try await waitUntil("asked") { e.window?.attachedSheet != nil }
    try put("theirs\n", dest.path)   // while the question is up
    try await answer(e.window, .alertFirstButtonReturn)   // Save
    #expect(try await dismissed(e.window).contains("appeared"))
    #expect(read(dest.path) == "theirs\n" && e.url == URL(fileURLWithPath: cp))

    try FileManager.default.removeItem(atPath: dest.path)
    #expect(await e.saveAs(dest), "answered Save once")
    #expect(FileManager.default.contents(atPath: dest.path) == text && e.url == dest)
}

/// A file deleted while it's open comes back with its own mode on ⌘S, not the umask's: a 0600 secret stays owner-only.
@MainActor @Test func aDeletedFileComesBackWithItsMode() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try put("SECRET=1\n", dir + "/.env", mode: 0o600)
    let e = try Editor(URL(fileURLWithPath: dir + "/.env"))
    defer { e.close() }
    try FileManager.default.removeItem(atPath: dir + "/.env")
    e.textView.string = "SECRET=2\n"
    #expect(await e.save())
    #expect(mode(dir + "/.env") == 0o600 && read(dir + "/.env") == "SECRET=2\n")
}

/// Save As… is off for a tool's file (Kermo reads it where it is) and while a sheet is up (the save panel's own: a second
/// ⇧⌘S opens no second panel); File ▸ Save As… is ⇧⌘S, and Synchronize Folders moved to ⌥⌘S.
@MainActor @Test func saveAsIsShiftCommandSAndSyncMoved() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try put("x\n", dir + "/x.txt")
    let e = try Editor(URL(fileURLWithPath: dir + "/x.txt"))
    defer { e.close() }
    let item = NSMenuItem(title: "Save As…", action: #selector(Editor.saveDocumentAs(_:)), keyEquivalent: "s")
    #expect(e.validateMenuItem(item))
    e.window?.beginSheet(NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)) { _ in }   // as the save panel is
    #expect(!e.validateMenuItem(item))
    e.window?.attachedSheet.map { e.window?.endSheet($0) }

    let tool = try Editor.open(URL(fileURLWithPath: dir + "/t.json"), text: "{}\n", beside: NSView()) { _ in }
    defer { tool.close() }
    #expect(!tool.validateMenuItem(item))

    let app = AppDelegate()
    app.commands = app.makeCommands()
    let menu = app.makeMenu()
    let saveAs = try #require(menu.allItems.first { $0.action == #selector(Editor.saveDocumentAs(_:)) })
    #expect(saveAs.keyEquivalent == "s" && saveAs.keyEquivalentModifierMask == [.command, .shift])
    #expect(app.commands.first { $0.id == "panel.sync" }?.keys.first == Shortcut("cmd+opt+s"))
    #expect(app.commands.allSatisfy { !$0.keys.contains(Shortcut("cmd+shift+s")!) }, "⇧⌘S is Save As's alone")
}

extension ServerLockTests {   // swaps `AppDelegate.answering`
    /// An upload still going when Save As made the server file a local one asks in that editor's window (not on the
    /// main window behind it), and says the text it couldn't send is kept in the copy — the editor's own file is saved,
    /// not marked unsaved by the server's answer.
    @MainActor @Test func anUploadAfterSaveAsAsksInItsEditor() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/app.conf", copy = URL(fileURLWithPath: dir + "/copy/app.conf")
        try put("v1\n", file)
        try FileManager.default.createDirectory(atPath: dir + "/copy", withIntermediateDirectories: true)
        try put("mine\n", copy.path)
        let c = try SFTPClient(.local())
        let state = AppDelegate.RemoteEdit(baseline: try #require(try c.stat(file)))
        c.close()
        Editor.open(copy, remote: "local:" + file, server: (.local(), file, state))
        try await waitUntil("opened") { Editor.editing(.local(), file) != nil }
        let e = try #require(Editor.editing(.local(), file))
        defer { e.close() }
        let mine = URL(fileURLWithPath: dir + "/mine.conf")
        #expect(await e.saveAs(mine))
        #expect(Editor.window(for: copy) == nil && Editor.asking(about: copy) === e.window, "its questions still find it")

        try await Task.sleep(for: .milliseconds(1100))
        try put("v2 from a deploy\n", file)
        let app = AppDelegate()
        app.panels = [PanelViewController(tabs: [dir], index: 0, showHidden: false)]
        app.panels.forEach { $0.loadViewIfNeeded() }
        defer { app.panels.forEach { $0.shutdown() } }
        var asked: [String] = []
        AppDelegate.answering = { m, _, _ in asked.append(m); return 2 }   // Cancel
        defer { AppDelegate.answering = nil }
        #expect(await !app.upload(copy, to: file, on: .local(), state))
        #expect(asked.count == 1 && asked.first?.contains("changed on") == true, "\(asked)")
        #expect(AppDelegate.answeredInfo.contains(copy.path), "the unsent text is in the copy: \(AppDelegate.answeredInfo)")
        #expect(!e.isEdited && read(mine.path) == "mine\n" && read(file) == "v2 from a deploy\n")
    }
}

extension EditorWindowTests {   // the editor window: one for the app, its tabs
    /// Every way a Save As of a server file can fail before the text is whole in `dest` — the folder read-only, the write
    /// stopping midway, the rename refused, a file appearing there meanwhile — leaves it bound to the server: same copy,
    /// same title, its chips, and the next ⌘S goes up again. The window keeps the text; nothing is left half-written.
    @Test func aFailedSaveAsLeavesTheServerFileBound() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { chmod(dir + "/ro", 0o755); try? FileManager.default.removeItem(atPath: dir) }
        let t = SFTPTarget(host: "me@e1-failed.invalid")
        var uploads = 0
        let (e, copy) = try await serverEditor(dir, t, "/srv/app/.env") { _ in uploads += 1 }
        defer { e.close() }
        e.textView.string = "SECRET=2\n"
        e.textDidChange(Notification(name: NSText.didChangeNotification))
        func stillBound(_ why: String) {
            #expect(e.url == copy && Editor.editing(t, "/srv/app/.env") === e && e.server?.path == "/srv/app/.env", "\(why)")
            #expect(e.window?.title == ".env" && e.window?.subtitle.contains("e1-failed") == true && e.window?.representedURL == nil, "\(why)")
            #expect(e.textView.string == "SECRET=2\n" && e.isEdited, "\(why): the text stays, unsaved")
            #expect(read(copy.path) == "SECRET=1\n", "\(why)")
            #expect(try! FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["copy", "ro", "theirs.env"], "\(why): no temp file left")
        }

        try FileManager.default.createDirectory(atPath: dir + "/ro", withIntermediateDirectories: true)
        try put("THEIRS=1\n", dir + "/theirs.env")
        chmod(dir + "/ro", 0o555)
        #expect(await !e.saveAs(URL(fileURLWithPath: dir + "/ro/.env")))
        #expect(try await dismissed(e.window).contains("Couldn't save"))
        stillBound("read-only folder")

        e.writeText = { h, data in   // the disk fills up halfway
            try h.write(contentsOf: data.prefix(4))
            throw POSIXError(.ENOSPC)
        }
        #expect(await !e.saveAs(URL(fileURLWithPath: dir + "/mine.env")))
        _ = try await dismissed(e.window)
        #expect(!FileManager.default.fileExists(atPath: dir + "/mine.env"))
        #expect(await !e.saveAs(URL(fileURLWithPath: dir + "/theirs.env")), "over a file the panel asked to replace")
        _ = try await dismissed(e.window)
        #expect(read(dir + "/theirs.env") == "THEIRS=1\n", "never cut short")
        stillBound("write stopped midway")
        e.writeText = { try $0.write(contentsOf: $1) }

        e.willRename = { _ in try? FileManager.default.removeItem(atPath: dir + "/theirs.env"); mkdir(dir + "/theirs.env", 0o755) }   // the rename can't replace a folder
        #expect(await !e.saveAs(URL(fileURLWithPath: dir + "/theirs.env")))
        _ = try await dismissed(e.window)
        rmdir(dir + "/theirs.env")
        try put("THEIRS=1\n", dir + "/theirs.env")
        stillBound("rename refused")

        e.willRename = { _ in try? put("APPEARED=1\n", dir + "/mine.env") }   // between the panel and the rename
        #expect(await !e.saveAs(URL(fileURLWithPath: dir + "/mine.env")))
        #expect(try await dismissed(e.window).contains("appeared"))
        #expect(read(dir + "/mine.env") == "APPEARED=1\n", "not written over")
        try FileManager.default.removeItem(atPath: dir + "/mine.env")
        e.willRename = { _ in }
        stillBound("a file appeared")

        #expect(await e.save())
        try await waitUntil("uploaded") { uploads == 1 }
        #expect(read(copy.path) == "SECRET=2\n", "⌘S still saves the server's copy and sends it up")
    }

    /// Save As of a server file: once written, the editor edits the new local file — no server, no chips, its own title —
    /// with the mode it had there (an `.env` 0600 stays 0600; unknown: owner only), and the next ⌘S writes it, not the copy.
    @Test func saveAsOfAServerFileKeepsItsModeAndLeavesTheServer() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for (i, (there, want)) in [(UInt32?(0o600), mode_t(0o600)), (nil, 0o600), (0o4755, 0o755)].enumerated() {
            let t = SFTPTarget(host: "me@e1-mode\(i).invalid")
            let (e, copy) = try await serverEditor(dir + "/\(i)", t, "/srv/app/.env", mode: there)
            defer { e.close() }
            e.chips = [.root]   // as a root panel's file shows it
            #expect(e.window?.titlebarAccessoryViewControllers.count == 1)
            e.textView.string = "SECRET=3\n"
            let mine = URL(fileURLWithPath: dir + "/\(i)/mine.env")
            #expect(await e.saveAs(mine))
            #expect(e.url == mine && e.server == nil && Editor.editing(t, "/srv/app/.env") == nil)
            #expect(e.window?.title == "mine.env" && e.window?.representedURL == mine && e.window?.titlebarAccessoryViewControllers.isEmpty == true)
            #expect(mode(mine.path) == umasked(want), "mode \(String(there ?? 0, radix: 8)) there")
            e.textView.string = "SECRET=4\n"
            #expect(await e.save())
            #expect(read(mine.path) == "SECRET=4\n" && read(copy.path) == "SECRET=1\n")
        }
    }

    /// Save As onto a file another editor window has open writes nothing — two windows on one file would each save over
    /// the other — and that window comes forward, saying why.
    @Test func saveAsOntoAFileOpenElsewhereWritesNothing() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try put("a\n", dir + "/a.txt")
        try put("b\n", dir + "/b.txt")
        Editor.open(URL(fileURLWithPath: dir + "/b.txt"))
        try await waitUntil("b open") { Editor.window(for: URL(fileURLWithPath: dir + "/b.txt")) != nil }
        let other = try #require(Editor.window(for: URL(fileURLWithPath: dir + "/b.txt")))
        defer { editorDoc(URL(fileURLWithPath: dir + "/b.txt"))?.close() }
        let e = try Editor(URL(fileURLWithPath: dir + "/a.txt"))
        defer { e.close() }
        e.textView.string = "mine\n"
        #expect(await !e.saveAs(URL(fileURLWithPath: dir + "/b.txt")))
        #expect(try await dismissed(other).contains("is open in this window"))
        #expect(read(dir + "/b.txt") == "b\n" && e.url == URL(fileURLWithPath: dir + "/a.txt"))
    }

    /// The file the save panel asked about replacing is checked again right before the write: one changed meanwhile, or
    /// swapped for a link to another file of yours, isn't written over. Answering the encoding question looks again for a
    /// window that opened the destination meanwhile.
    @Test func aReplacedFileIsCheckedAgainBeforeTheWrite() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cp = dir + "/old.conf"
        try "# Коментар\n".data(using: .windowsCP1251)!.write(to: URL(fileURLWithPath: cp))
        func asking(_ dest: String) async throws -> Editor {   // a Windows-1251 file: Save As asks first
            let e = try Editor(URL(fileURLWithPath: cp))
            #expect(await !e.saveAs(URL(fileURLWithPath: dest)))
            try await waitUntil("asked") { e.window?.attachedSheet != nil }
            return e
        }

        try put("theirs\n", dir + "/a.conf")
        let a = try await asking(dir + "/a.conf")
        defer { a.close() }
        try put("theirs, newer\n", dir + "/a.conf")
        try await answer(a.window, .alertFirstButtonReturn)   // Save
        #expect(try await dismissed(a.window).contains("changed after you chose to replace it"))
        #expect(read(dir + "/a.conf") == "theirs, newer\n" && a.url == URL(fileURLWithPath: cp))

        try put("mine\n", dir + "/victim")
        try put("theirs\n", dir + "/b.conf")
        let b = try await asking(dir + "/b.conf")
        defer { b.close() }
        try FileManager.default.removeItem(atPath: dir + "/b.conf")
        try FileManager.default.createSymbolicLink(atPath: dir + "/b.conf", withDestinationPath: dir + "/victim")
        try await answer(b.window, .alertFirstButtonReturn)
        _ = try await dismissed(b.window)
        #expect(read(dir + "/victim") == "mine\n", "not written through the link swapped in")

        let c = try await asking(dir + "/c.conf")
        defer { c.close() }
        try put("c\n", dir + "/c.conf")
        Editor.open(URL(fileURLWithPath: dir + "/c.conf"))
        try await waitUntil("c open") { Editor.window(for: URL(fileURLWithPath: dir + "/c.conf")) != nil }
        let other = try #require(Editor.window(for: URL(fileURLWithPath: dir + "/c.conf")))
        defer { editorDoc(URL(fileURLWithPath: dir + "/c.conf"))?.close() }
        try await answer(c.window, .alertFirstButtonReturn)
        #expect(try await dismissed(other).contains("is open in this window"))
        #expect(read(dir + "/c.conf") == "c\n")
    }

    /// A question about a document shows its window first: out of the Dock, key, in front — a sheet on a window out of sight
    /// waits unseen, and the upload behind it with it.
    @Test func aQuestionShowsItsWindowFirst() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir + "/a.conf")
        try put("a\n", url.path)
        Editor.open(url)
        try await waitUntil("opened") { Editor.window(for: url) != nil }
        let w = try #require(Editor.window(for: url))
        defer { editorDoc(url)?.close() }
        w.miniaturize(nil)
        try await waitUntil("in the Dock") { w.isMiniaturized }
        #expect(Editor.asking(about: url) === w)
        try await waitUntil("back") { !w.isMiniaturized && w.isVisible }
        w.orderOut(nil)
        _ = Editor.asking(about: url)
        #expect(w.isVisible)
    }

    /// F4 on a server's file already open shows that window: one file, one window — the second download's copy goes.
    /// This Mac's file by its path, however it's spelled.
    @Test func aServerFileOpensInOneWindow() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let t = SFTPTarget(host: "me@e1-once.invalid")
        let (e, _) = try await serverEditor(dir + "/1", t, "/etc/app.conf")
        defer { e.close() }
        let again = URL(fileURLWithPath: dir + "/2/app.conf")
        try FileManager.default.createDirectory(atPath: dir + "/2", withIntermediateDirectories: true)
        try put("x\n", again.path)
        var dropped = false
        Editor.open(again, server: (t, "/etc/app.conf", AppDelegate.RemoteEdit(baseline: .nothing)), onClose: { dropped = true })
        #expect(dropped && Editor.window(for: again) == nil, "the second copy is let go")

        let local = URL(fileURLWithPath: dir + "/2/app.conf")
        Editor.open(local)
        try await waitUntil("opened") { Editor.window(for: local) != nil }
        _ = try #require(Editor.window(for: local))
        defer { editorDoc(local)?.close() }
        Editor.open(URL(fileURLWithPath: dir + "/2/../2/app.conf"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(EditorHost.tabs.docs.filter { $0.url?.standardizedFileURL == local.standardizedFileURL }.count == 1, "no second tab")
    }
}
