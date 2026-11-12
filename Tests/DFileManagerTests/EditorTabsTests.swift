import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Editor E3 + E4: the editor window's tabs — a document each, its own Undo — and their drafts, kept between launches
// (contract §4–§7): written as typed, back after a crash or a quit, every failure said.

extension ServerLockTests {
    /// The editor window is the app's one: the tests of its tabs take turns — with ServerLock's too, whose locks they use.
    @MainActor struct EditorWindowTests {}
}
typealias EditorWindowTests = ServerLockTests.EditorWindowTests

/// A tab of the editor window, by its file.
@MainActor func editorDoc(_ url: URL) -> Editor? { EditorHost.tabs.docs.first { $0.url?.standardizedFileURL == url.standardizedFileURL } }

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-tabs-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func put(_ s: String, _ path: String) throws { try Data(s.utf8).write(to: URL(fileURLWithPath: path)) }
private func perms(_ path: String) -> Int? { (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int }
private func read(_ path: String) -> String? { FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } }

@MainActor private func waitUntil(_ what: String, _ cond: () -> Bool) async throws {
    for _ in 0..<250 where !cond() { try await Task.sleep(for: .milliseconds(20)) }
    #expect(cond(), "\(what)")
}

/// A launch with the drafts in `dir`: the editor window as it comes back.
@MainActor private func launch(_ dir: String, onServer: @escaping EditorHost.OnServer = { _, _, _, _ in ({ _ in }, {}) }) -> EditorHost {
    crash()
    EditorHost.restore(dir, onServer: onServer)
    return EditorHost.tabs
}

/// The editor window gone as at a crash: nothing more written, its documents out of the lookups, the drafts let go.
@MainActor private func crash() {
    guard let h = EditorHost.shared else { return }
    for e in h.docs { e.closed(); e.host = nil }
    h.drafts?.release()
    h.window?.orderOut(nil)
    EditorHost.shared = nil
}

/// The session on disk now.
private func manifest(_ dir: String) throws -> EditorSession {
    try JSONDecoder().decode(EditorSession.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/session.json")))
}

@MainActor private func type(_ e: Editor, _ s: String) {
    e.textView.insertText(s, replacementRange: NSRange(location: (e.textView.string as NSString).length, length: 0))
}

/// Answers the sheet on `w` once it is up; what it said.
@MainActor @discardableResult private func answer(_ w: NSWindow?, _ code: NSApplication.ModalResponse) async throws -> String {
    try await waitUntil("a sheet") { w?.attachedSheet != nil }
    guard let w, let sheet = w.attachedSheet else { return "" }
    func text(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(text) }
    let said = (sheet.contentView.map(text) ?? []).joined(separator: " ")
    w.endSheet(sheet, returnCode: code)
    try await waitUntil("sheet gone") { w.attachedSheet !== sheet }
    return said
}

extension EditorWindowTests {
    /// Documents are tabs of one window, each with its own Undo: undoing in one leaves the other's typing, switching
    /// tabs keeps both, a reload empties only its own. ⌘S and Find… reach the tab shown (it's in the responder chain).
    @Test func tabsShareTheWindowNotTheirUndo() async throws {
        _ = NSApplication.shared
        crash()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = Editor.untitled(), b = Editor.untitled()
        defer { a.close(); b.close() }
        let h = EditorHost.tabs
        #expect(a.window === b.window && h.active === b && h.docs.suffix(2).map { $0 } == [a, b])
        var chain: NSResponder? = b.textView, reaches = false
        while let r = chain { reaches = reaches || r === b; chain = r.nextResponder }
        #expect(reaches, "the shown document is in the responder chain")

        type(b, "bee")
        h.select(a)
        type(a, "ay")
        #expect(a.textView.undoManager !== b.textView.undoManager && a.textView.undoManager?.canUndo == true)
        a.textView.undoManager?.undo()
        #expect(a.textView.string == "" && b.textView.string == "bee", "B's typing stays")
        h.select(b)
        #expect(b.textView.undoManager?.canUndo == true, "switching tabs keeps it")

        try put("one\n", dir + "/c.conf")
        Editor.open(URL(fileURLWithPath: dir + "/c.conf"))
        try await waitUntil("opened") { editorDoc(URL(fileURLWithPath: dir + "/c.conf")) != nil }
        let c = try #require(editorDoc(URL(fileURLWithPath: dir + "/c.conf")))
        defer { c.close() }
        type(c, "two\n")
        try put("three\n", dir + "/c.conf")
        #expect(await c.reload())
        #expect(c.textView.undoManager?.canUndo == false && b.textView.undoManager?.canUndo == true, "a reload empties its own Undo only")
    }

    /// Two tabs of one name say where each is; F4 on an open file chooses its tab (no second one); Move Tab and Next Tab
    /// go round; the tool editor is a window of its own, as before.
    @Test func tabsTellSameNamesApartAndKeepTheirOrder() async throws {
        _ = NSApplication.shared
        crash()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for f in ["x", "y"] {
            try FileManager.default.createDirectory(atPath: "\(dir)/\(f)", withIntermediateDirectories: true)
            try put("\(f)\n", "\(dir)/\(f)/app.conf")
        }
        let x = URL(fileURLWithPath: dir + "/x/app.conf"), y = URL(fileURLWithPath: dir + "/y/app.conf")
        Editor.open(x)
        try await waitUntil("x") { editorDoc(x) != nil }
        Editor.open(y)
        try await waitUntil("y") { editorDoc(y) != nil }
        let (ex, ey) = (try #require(editorDoc(x)), try #require(editorDoc(y)))
        defer { ex.close(); ey.close() }
        let h = EditorHost.tabs
        #expect(h.tabTitle(ex) == "app.conf — x" && h.tabTitle(ey) == "app.conf — y" && ex.tip.hasSuffix("/x · app.conf"))
        Editor.open(URL(fileURLWithPath: dir + "/x/../x/app.conf"))
        try await waitUntil("x chosen") { h.active === ex }
        #expect(h.docs.filter { $0 === ex || $0 === ey }.count == 2, "no second tab")
        h.moveTab(by: 1)
        #expect(h.docs.firstIndex { $0 === ex }! == h.docs.firstIndex { $0 === ey }! + 1)
        h.switchTab(by: 1)
        #expect(h.active === h.docs.first, "past the last: the first")

        let tool = try Editor.open(URL(fileURLWithPath: dir + "/t.json"), text: "{}\n", beside: NSView()) { _ in }
        defer { tool.close() }
        #expect(!tool.host.tabbed && tool.window !== h.window && !h.docs.contains { $0 === tool })
        #expect(Editor.keys(of: tool.window)?.first?.title == "Close" && Editor.keys(of: h.window)?.first?.title == "Back to Panels")
    }

    /// ⌘T, ⌘W, ⌃Tab are the tab commands as they were, with the editor window's branch; Close Editor Window is ⇧⌘W, Move
    /// Tab and All Tabs have no keys, Show Editor works from anywhere.
    @Test func theTabCommandsServeTheEditorWindow() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        app.commands = app.makeCommands()
        func keys(_ id: String) -> [String] { app.commands.first { $0.id == id }?.keys.map(\.display) ?? ["?"] }
        #expect(keys("tab.new") == ["⌘T"] && keys("tab.close") == ["⌘W"] && keys("editor.close") == ["⇧⌘W"])
        #expect(keys("editor.tab.left").isEmpty && keys("editor.tab.right").isEmpty && keys("editor.tabs").isEmpty && keys("editor.show").isEmpty)
        #expect(app.commands.filter { $0.keys.contains(Shortcut("cmd+shift+w")!) }.map(\.id) == ["editor.close"])
        #expect(AppDelegate.appWide.contains("editor.show") && !AppDelegate.appWide.contains("editor.close"))
        let tool = try Editor.open(URL(fileURLWithPath: NSTemporaryDirectory() + "dfm-tabs-\(UUID().uuidString).json"), text: "{}\n", beside: NSView()) { _ in }
        defer { tool.close() }
        #expect(AppDelegate.editor(key: EditorHost.tabs.window) === EditorHost.tabs && AppDelegate.editor(key: tool.window) == nil)
        #expect(AppDelegate.editor(key: nil) == nil)
    }

    /// ⎋ in the find bar closes the bar; then ⎋ goes back to the panels: an unchanged tab closes, a changed one stays and
    /// the window hides.
    @Test func escapeClosesTheFindBarThenGoesBackToThePanels() async throws {
        _ = NSApplication.shared
        crash()
        let a = Editor.untitled(), b = Editor.untitled()
        defer { a.close(); b.close() }
        let h = EditorHost.tabs, w = try #require(h.window)
        type(a, "kept")
        let show = NSMenuItem()
        show.tag = NSTextFinder.Action.showFindInterface.rawValue
        b.textView.performTextFinderAction(show)
        #expect(b.frame.scroll.isFindBarVisible)
        b.textView.cancelOperation(nil)
        #expect(!b.frame.scroll.isFindBarVisible && h.docs.contains { $0 === b } && w.isVisible, "the find bar only")
        b.textView.cancelOperation(nil)
        try await waitUntil("hidden") { !w.isVisible }
        #expect(!h.docs.contains { $0 === b }, "an unchanged tab closes")
        a.revealed()
        a.textView.cancelOperation(nil)
        try await waitUntil("hidden") { !w.isVisible }
        #expect(h.docs.contains { $0 === a }, "a changed one stays")
    }

    /// A crash: what was typed comes back from the last draft — the tabs in order, the one shown, each text and its
    /// state — and the files themselves aren't touched.
    @Test func whatWasTypedComesBackAfterACrash() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { crash(); try? FileManager.default.removeItem(atPath: dir) }
        try put("orig\n", dir + "/a.conf")
        var h = launch(dir + "/drafts")
        let u = Editor.untitled()
        type(u, "notes ✓\nline 2")
        Editor.open(URL(fileURLWithPath: dir + "/a.conf"))
        try await waitUntil("opened") { editorDoc(URL(fileURLWithPath: dir + "/a.conf")) != nil }
        let a = try #require(editorDoc(URL(fileURLWithPath: dir + "/a.conf")))
        type(a, "mine\n")
        h.select(u)
        #expect(await h.commit() == nil)
        #expect(u.frame.text.contains("Unsaved changes · Draft saved ") && u.keepsDrafts && !Editor.unsaved.contains(u.name))
        let session = try manifest(dir + "/drafts")
        #expect(session.docs.map(\.kind) == [.untitled, .local] && session.docs.allSatisfy(\.dirty) && session.active == u.id)
        let fm = FileManager.default
        #expect(perms(dir + "/drafts") == 0o700
                && perms(dir + "/drafts/session.json") == 0o600, "ours only")

        h = launch(dir + "/drafts")
        try await waitUntil("restored") { h.docs.count == 2 && h.docs.allSatisfy { $0.cover == nil } }
        let (u2, a2) = (h.docs[0], h.docs[1])
        #expect(u2.name == u.name && u2.textView.string == "notes ✓\nline 2" && u2.isEdited && h.active === u2)
        #expect(u2.frame.text == "UTF-8 · Unsaved changes", "its state from the start, not only its mark")
        #expect(a2.url?.path == dir + "/a.conf" && a2.textView.string == "orig\nmine\n" && a2.isEdited && a2.frame.banner == nil)
        #expect(read(dir + "/a.conf") == "orig\n", "the file is as it was")
        let next = Editor.untitled()
        #expect(next.name == "Untitled \((Int(u.name.dropFirst(9)) ?? 0) + 1)", "numbered past the restored one")
    }

    /// Every row of contract §6: what each kind of document in the session shows after a launch.
    @Test func eachKindOfDocumentComesBackAsTheContractSays() async throws {
        _ = NSApplication.shared
        crash()
        let dir = try tempDir()
        defer { crash(); try? FileManager.default.removeItem(atPath: dir) }
        let fm = FileManager.default, drafts = dir + "/drafts"
        for (f, s) in [("clean.txt", "clean\n"), ("same.txt", "same\n"), ("changed.txt", "theirs\n"), ("saved.txt", "a\r\nb\r\n")] { try put(s, dir + "/" + f) }
        func local(_ name: String, _ baselineText: String?, mode: UInt16 = 0o600, crlf: Bool = false) -> EditorSession.Doc {
            var d = EditorSession.Doc(kind: .local)
            d.path = dir + "/" + name
            d.baseline = .init(stamp: .init(dev: 1, ino: 2, size: 3, sec: 4, nsec: 5, mode: mode), digest: baselineText.map { Editor.sha(Data($0.utf8)) })
            (d.format.crlf, d.format.finalNewline) = (crlf, crlf)
            return d
        }
        var untitled = EditorSession.Doc(kind: .untitled), empty = EditorSession.Doc(kind: .untitled)
        (untitled.number, untitled.dirty, empty.number) = (3, true, 5)
        let clean = local("clean.txt", "clean\n"), gone = local("gone.txt", "x\n")
        var same = local("same.txt", "same\n"), changed = local("changed.txt", "mine-was\n"), missing = local("missing.txt", "was\n", mode: 0o640)
        var saved = local("saved.txt", "a\r\n", crlf: true)
        (same.dirty, changed.dirty, missing.dirty, saved.dirty) = (true, true, true, true)
        same.selection = [3, 0]
        var parked = EditorSession.Doc(kind: .server), sent = EditorSession.Doc(kind: .server)
        parked.server = .init(SFTPTarget(host: "me@parked.invalid"), root: false, path: "/etc/app.env")
        sent.server = .init(SFTPTarget(host: "me@sent.invalid"), root: true, path: "/etc/nginx.conf")
        (sent.dirty, sent.unsent) = (true, true)
        var broken = EditorSession.Doc(kind: .untitled)
        (broken.number, broken.dirty) = (9, true)
        var s = EditorSession()
        s.docs = [untitled, empty, clean, gone, same, changed, missing, saved, parked, sent, broken]
        (s.active, s.windowOpen) = (same.id, false)
        let (store, _, _) = try DraftStore.open(drafts)
        store.submit(s, texts: [untitled.id: "draft 3", same.id: "same\nmore", changed.id: "mine\n", missing.id: "lost\n", saved.id: "a\nb", sent.id: "listen 80;", broken.id: "x"])
        try await store.flush()
        let rev = try manifest(drafts).docs.last!.revision!
        try put("y", "\(drafts)/rev/\(broken.id.uuidString).\(rev.n)")   // the same length, other bytes
        store.release()

        let h = launch(drafts)
        let reading = try #require(h.docs.first { $0.id == same.id })
        #expect(reading.cover == .loading && !reading.textView.isEditable && reading.frame.cover != nil, "nothing typed into a text still being read")
        try await waitUntil("all read") { h.docs.allSatisfy { $0.cover != .loading } && h.docs.count == 10 }
        #expect(reading.textView.isEditable)
        func doc(_ d: EditorSession.Doc) -> Editor? { h.docs.first { $0.id == d.id } }
        #expect(h.docs.map(\.id) == s.docs.filter { $0.id != gone.id }.map(\.id), "in order; the clean file that's gone has no tab")
        #expect(h.active === doc(same) && h.window?.isVisible == false, "the shown one; the window waits for Show Editor")
        #expect(doc(untitled)?.name == "Untitled 3" && doc(untitled)?.textView.string == "draft 3" && doc(untitled)?.isEdited == true)
        #expect(doc(empty)?.name == "Untitled 5" && doc(empty)?.textView.string == "" && doc(empty)?.isEdited == false)
        #expect(doc(clean)?.textView.string == "clean\n" && doc(clean)?.isEdited == false)
        #expect(doc(same)?.textView.string == "same\nmore" && doc(same)?.isEdited == true && doc(same)?.frame.banner == nil, "its bytes are the baseline's")
        #expect(doc(same)?.textView.selectedRange().location == 3)
        #expect(doc(changed)?.textView.string == "mine\n" && allText(doc(changed)?.frame.banner).contains("changed on disk since your draft"))
        #expect(allText(doc(missing)?.frame.banner).contains("is no longer in") && doc(missing)?.isEdited == true)
        #expect(doc(saved)?.isEdited == false && doc(saved)?.frame.banner == nil, "the draft is what the file has: saved, then a crash")
        #expect(doc(parked)?.cover == .parked && doc(parked)?.textView.string == "" && doc(parked)?.server?.path == "/etc/app.env")
        #expect(doc(sent)?.textView.string == "listen 80;" && doc(sent)?.mark?.string == "↑" && doc(sent)?.server?.target.sudo == true)
        #expect(doc(sent)?.server?.state.unlockFirst == true && doc(sent)?.url.map { fm.fileExists(atPath: $0.deletingLastPathComponent().path) } == false,
                "no connection, no copy until a Save")
        guard case .unreadable(let moved?)? = doc(broken)?.cover else { Issue.record("a damaged draft: \(String(describing: doc(broken)?.cover))"); return }
        #expect(read(moved + "/\(broken.id.uuidString).\(rev.n)") == "y", "moved aside, not deleted")
        #expect(h.window.map { $0.title } != nil)
        h.reveal(try #require(doc(clean)))
        #expect(h.window?.isVisible == true)

        // ⌘S on the draft whose file went: it's back with its own mode.
        let m = try #require(doc(missing))
        #expect(await m.save())
        #expect(read(dir + "/missing.txt") == "lost\n" && perms(dir + "/missing.txt") == 0o640)
        #expect(await h.commit() == nil)
        #expect(!(try manifest(drafts).docs.contains { $0.id == broken.id }), "a draft that couldn't be read isn't named again")
        doc(broken)?.close()
        #expect(fm.fileExists(atPath: moved), "closing its tab leaves the moved file")
    }

    /// A draft that can't be written says so — a red "!" on its tab, why in its status line, Quit and ⌘W ask — keeps
    /// the last good one, and goes once writing works again. A tab doesn't close until the session without it is written.
    @Test func aDraftThatCantBeWrittenSaysSo() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { chmod(dir + "/drafts/rev", 0o700); crash(); try? FileManager.default.removeItem(atPath: dir) }
        let h = launch(dir + "/drafts")
        let u = Editor.untitled(), other = Editor.untitled()
        type(u, "good")
        #expect(await h.commit() == nil)
        chmod(dir + "/drafts/rev", 0o500)
        type(u, " and newer")
        #expect(await h.commit() == "no permission to write there")
        #expect(u.mark?.string == "!" && u.frame.text.contains("Draft not saved: no permission to write there · Save As… keeps the text"))
        #expect(u.draftFailed != nil && other.mark == nil && !Editor.unsaved.contains(u.name), "Quit asks about it itself (finishQuit)")
        let s = try manifest(dir + "/drafts")
        let kept = try #require(s.docs.first { $0.id == u.id }?.revision)
        #expect(read(dir + "/drafts/rev/\(u.id.uuidString).\(kept.n)") == "good", "the last good draft is there")
        #expect(!u.closeAsking())
        try await answer(u.window, .alertThirdButtonReturn)   // Cancel

        chmod(dir + "/drafts", 0o500)
        other.closeAsking()
        try await waitUntil("said") { other.frame.text.contains("Not closed") }
        #expect(h.docs.contains { $0 === other }, "not written without it: stays")
        chmod(dir + "/drafts", 0o700)
        chmod(dir + "/drafts/rev", 0o700)
        #expect(await h.commit() == nil)
        #expect(u.mark?.string == "●" && u.draftFailed == nil && !Editor.unsaved.contains(u.name))
        other.close()
        u.close()
    }

    /// Don't Save drops the draft with the tab: once the question is answered the session without it is on disk, and
    /// the next launch — a crash right after, even — doesn't bring it back.
    @Test func dontSaveDropsTheDraftForGood() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { crash(); try? FileManager.default.removeItem(atPath: dir) }
        var h = launch(dir + "/drafts")
        let u = Editor.untitled()
        type(u, "secret plan")
        #expect(await h.commit() == nil)
        var closed = false
        u.onClose = { closed = true }
        #expect(!u.closeAsking())
        let said = try await answer(u.window, .alertSecondButtonReturn)   // Don't Save
        #expect(said.contains("Don't Save discards them, the draft too."), "\(said)")
        try await waitUntil("closed") { closed }
        #expect(try manifest(dir + "/drafts").docs.isEmpty && (try FileManager.default.contentsOfDirectory(atPath: dir + "/drafts/rev")).isEmpty)
        h = launch(dir + "/drafts")
        #expect(h.docs.isEmpty)
    }

    /// A commit that overtakes a closing tab's own — a tab switch, another app in front, the retry — doesn't name the
    /// tab again: the session on disk is the one without it.
    @Test func aClosingTabIsntNamedByACommitThatOvertakesIt() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { crash(); try? FileManager.default.removeItem(atPath: dir) }
        let h = launch(dir + "/drafts")
        let u = Editor.untitled(), keep = Editor.untitled()
        type(u, "throw away")
        type(keep, "keep")
        #expect(await h.commit() == nil)
        h.close(u)   // Don't Save's way: its commit is queued
        h.checkpoint()   // and another right behind it
        try await waitUntil("closed") { !h.docs.contains { $0 === u } }
        try await h.drafts!.flush()   // what's on disk now: the overtaking commit's session, before the tab's removal writes another
        let s = try manifest(dir + "/drafts")
        #expect(s.docs.map(\.id) == [keep.id], "\(s.docs.map(\.number))")
        keep.close()
    }

    /// Close Editor Window (⇧⌘W, the close button) writes every draft and hides the window: no question, no tab closed
    /// (a server file's copy isn't let go), the session says the window was hidden. If that can't be written the window
    /// stays and says why. Show Editor brings it back.
    @Test func hidingTheWindowKeepsEveryTab() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { chmod(dir + "/drafts", 0o700); crash(); try? FileManager.default.removeItem(atPath: dir) }
        let h = launch(dir + "/drafts")
        let u = Editor.untitled(), w = try #require(h.window)
        var closed = 0
        u.onClose = { closed += 1 }
        type(u, "draft")
        chmod(dir + "/drafts", 0o500)
        #expect(!h.windowShouldClose(w))
        try await waitUntil("said") { u.frame.text.contains("The window stays") }
        #expect(w.isVisible, "the drafts couldn't be saved: it stays")
        chmod(dir + "/drafts", 0o700)
        h.hide()
        try await waitUntil("hidden") { !w.isVisible }
        #expect(h.docs.contains { $0 === u } && closed == 0 && w.attachedSheet == nil)
        let s = try manifest(dir + "/drafts")
        #expect(!s.windowOpen && s.docs.first?.dirty == true)
        h.showEditor()
        #expect(w.isVisible && h.active === u)
        u.close()
        #expect(closed == 1, "closing its tab does")
    }

    /// Quit writes the drafts on the disk itself first (`.terminateLater`, answered every way); one that can't be written
    /// asks — Quit Anyway, Show Editor, Cancel — and nothing quits unasked. Without drafts it quits at once.
    @Test func quitWaitsForTheDrafts() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { chmod(dir + "/drafts/rev", 0o700); crash(); AppDelegate.answering = nil; AppDelegate.replyToQuit = { NSApp.reply(toApplicationShouldTerminate: $0) }
                try? FileManager.default.removeItem(atPath: dir) }
        let h = launch(dir + "/drafts")
        let app = AppDelegate()
        app.terminal = EmbeddedTerminal(covering: NSView())
        var replies: [Bool] = []
        AppDelegate.replyToQuit = { replies.append($0) }
        AppDelegate.answering = { _, _, _ in 0 }   // another test's upload or copy going: Quit
        let u = Editor.untitled()
        type(u, "typed just now")
        #expect(!Editor.unsaved.contains(u.name), "no question about a draft that's kept")
        #expect(app.applicationShouldTerminate(NSApp) == .terminateLater)
        try await waitUntil("answered") { replies == [true] }
        #expect(try manifest(dir + "/drafts").docs.first?.dirty == true)

        chmod(dir + "/drafts/rev", 0o500)
        type(u, ", and more")
        var asked: [(String, [String])] = []
        AppDelegate.answering = { m, b, _ in asked.append((m, b)); return 2 }   // Cancel
        #expect(app.applicationShouldTerminate(NSApp) == .terminateLater)
        try await waitUntil("answered") { replies == [true, false] }
        #expect(asked.first?.0 == "Quit Kermo?" && asked.first?.1 == ["Quit Anyway", "Show Editor", "Cancel"])
        AppDelegate.answering = { _, _, _ in 1 }   // Show Editor
        #expect(await !app.finishQuit() && h.window?.isVisible == true)
        AppDelegate.answering = { _, _, _ in 0 }   // Quit Anyway
        #expect(await app.finishQuit())
        chmod(dir + "/drafts/rev", 0o700)
        u.close()
        crash()
        #expect(app.applicationShouldTerminate(NSApp) == .terminateNow, "no drafts: nothing to wait for")
    }

    /// A server's draft after a launch: no connection till its Save, which makes the copy (ours only) and goes through
    /// the save a server file always takes; a locked server asks Touch ID first. A locked server's draft isn't shown —
    /// nor its folder — till it's unlocked.
    @Test func aServerDraftConnectsOnlyOnSaveAndALockedOneShowsAfterUnlock() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        var locked = SavedServer(address: "localhost")!
        locked.locked = true
        var asked = 0, unlock = false
        ServerLock.servers = { [locked] }
        ServerLock.authenticate = { _ in asked += 1; return unlock }
        defer { ServerLock.servers = { [] }; ServerLock.relock(); crash(); try? FileManager.default.removeItem(atPath: dir) }
        var d = EditorSession.Doc(kind: .server)
        d.server = .init(SFTPTarget(host: "localhost"), root: false, path: "/srv/app/secrets.yml")
        d.dirty = true
        var s = EditorSession()
        s.docs = [d]
        let (store, _, _) = try DraftStore.open(dir + "/drafts")
        store.submit(s, texts: [d.id: "token: 42\n"])
        try await store.flush()
        store.release()
        @MainActor final class Sent { var urls: [URL] = [] }
        let sent = Sent()
        let h = launch(dir + "/drafts") { _, _, _, _ in ({ @MainActor in sent.urls.append($0) }, {}) }
        let e = try #require(h.docs.first)
        try await waitUntil("locked \(String(describing: e.cover))") { e.cover == .locked }
        #expect(e.textView.string == "" && e.heading == ("secrets.yml", "localhost") && asked == 0, "nothing of it before Unlock")
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(Editor.saveDocumentAs(_:)), keyEquivalent: "")
        #expect(e.changed && !e.validateMenuItem(saveAs), "its draft is the change, though the text isn't shown; no Save As of nothing")
        #expect(!e.closeAsking())
        try await answer(e.window, .alertThirdButtonReturn)   // Cancel
        #expect(h.docs.first === e)
        e.connect()
        try await waitUntil("asked") { asked == 1 }
        #expect(e.cover == .locked && e.textView.string == "")
        unlock = true
        e.connect()
        try await waitUntil("shown") { e.cover == nil }
        #expect(e.textView.string == "token: 42\n" && e.isEdited && e.heading.subtitle.contains("/srv/app"))

        let copy = try #require(e.url)
        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
        #expect(await e.save())
        #expect(sent.urls == [copy] && read(copy.path) == "token: 42\n")
        let folder = perms(copy.deletingLastPathComponent().path)
        let file = perms(copy.path)
        #expect(folder == 0o700 && file == 0o600, "the copy is ours only")
        TempCopies.remove(copy.deletingLastPathComponent().path)
    }

    /// A restored server draft's first upload unlocks a locked server first (Touch ID refused: nothing sent, still
    /// unsaved), then goes as any save does — a change on the server since asks before writing over it.
    @Test func aRestoredDraftsFirstUploadUnlocksFirst() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        var locked = SavedServer(address: "localhost")!
        locked.locked = true
        var asked = 0, unlock = false
        ServerLock.servers = { [locked] }
        ServerLock.authenticate = { _ in asked += 1; return unlock }
        defer { ServerLock.servers = { [] }; ServerLock.relock(); AppDelegate.answering = nil; try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/app.conf", copy = URL(fileURLWithPath: dir + "/copy/app.conf")
        try put("v1\n", file)
        try FileManager.default.createDirectory(atPath: dir + "/copy", withIntermediateDirectories: true)
        try put("mine\n", copy.path)
        let c = try SFTPClient(.local())
        let state = AppDelegate.RemoteEdit(baseline: try #require(try c.stat(file)))
        c.close()
        state.unlockFirst = true
        let app = AppDelegate()
        app.window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)   // "wasn't saved" goes there
        app.panels = [PanelViewController(tabs: [dir], index: 0, showHidden: false)]
        app.panels.forEach { $0.loadViewIfNeeded() }
        defer { app.panels.forEach { $0.shutdown() } }
        let (onSaved, _) = app.remoteEditing(.local(), file, state, in: dir + "/copy")
        onSaved(copy)
        #expect(await state.upload?.value == false && asked == 1 && read(file) == "v1\n", "refused: nothing sent")
        unlock = true
        try await Task.sleep(for: .milliseconds(1100))
        try put("v2 from a deploy\n", file)
        var questions: [String] = []
        AppDelegate.answering = { m, _, _ in questions.append(m); return 2 }   // Cancel
        onSaved(copy)
        #expect(await state.upload?.value == false && asked == 2 && questions.first?.contains("changed on") == true, "\(questions)")
        #expect(read(file) == "v2 from a deploy\n" && !state.unlockFirst)
    }
}

@MainActor private func allText(_ v: NSView?) -> String {
    guard let v else { return "" }
    func text(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(text) }
    return text(v).joined(separator: " ")
}

extension EditorWindowTests {
    /// "Changed on the server since you opened it": ↑ while it asks; Overwrite sends the text, and its tab is saved — it stayed ↑ "Not
    /// uploaded" with the server already holding it (and after a launch asked again). Cancel leaves it ↑.
    @Test func overwritingAChangedServerFileLeavesItsTabSaved() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { AppDelegate.answering = nil; try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/app.conf", copy = URL(fileURLWithPath: dir + "/copy.conf")
        try put("v1\n", file)
        let c = try SFTPClient(.local())
        let state = AppDelegate.RemoteEdit(baseline: try #require(try c.stat(file)))
        c.close()
        try put("mine\n", copy.path)
        let e = try Editor.open(copy, text: nil, beside: NSView()) { _ in }
        defer { e.close() }
        let app = AppDelegate()
        app.panels = [PanelViewController(tabs: [dir], index: 0, showHidden: false)]
        app.panels.forEach { $0.loadViewIfNeeded() }
        defer { app.panels.forEach { $0.shutdown() } }
        try put("v2 from a deploy\n", file)   // another size: a change
        var whileAsked: [Bool] = []
        AppDelegate.answering = { _, _, _ in whileAsked.append(e.isEdited); return 2 }   // Cancel
        #expect(await !app.upload(copy, to: file, on: .local(), state))
        #expect(e.isEdited && read(file) == "v2 from a deploy\n", "Cancel: still to send")
        #expect(await e.save(), "⌘S again: the copy first")
        AppDelegate.answering = { _, _, _ in whileAsked.append(e.isEdited); return 0 }   // Overwrite
        #expect(await app.upload(copy, to: file, on: .local(), state))
        #expect(read(file) == "mine\n")
        #expect(!e.isEdited, "sent: not ↑")
        #expect(whileAsked == [true, true], "↑ while it asks (Compare too): closing the tab then asks")
    }

    /// A ↑ tab saved again: its ↑ goes from the tab itself, not only from its state — the tab was drawn while the ↑
    /// still stood, and stayed so till something else redrew the tabs.
    @Test func aSavedTabLosesItsUpArrow() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir + "/f.conf")
        try put("a\n", url.path)
        Editor.open(url)
        try await waitUntil("open") { editorDoc(url) != nil }
        let e = try #require(editorDoc(url))
        defer { e.close() }
        func drawn() -> String {
            func titles(_ v: NSView) -> [String] { ((v as? NSButton).map { [$0.attributedTitle.string] } ?? []) + v.subviews.flatMap(titles) }
            return (e.window?.contentView.map(titles) ?? []).first { $0.contains("f.conf") } ?? ""
        }
        Editor.markUnsaved(url)   // an upload that failed
        #expect(drawn().contains("↑"))
        #expect(await e.save())
        #expect(!drawn().contains("↑") && !drawn().contains("●"), "\(drawn())")
    }
}


// Editor E6 PR 2: the tab strip — rename from the tab, its menu, Close Others, reopen a closed tab, the panels' keys there.

/// A test's app for what an editor does through it (a server's rename, Reveal): a window and one panel in `dir`.
@MainActor private func testApp(_ dir: String) -> AppDelegate {
    let app = AppDelegate()
    app.window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    app.panels = [PanelViewController(tabs: [dir], index: 0, showHidden: false)]
    app.panels.forEach { $0.loadViewIfNeeded() }
    Editor.app = { app }
    return app
}

/// A server file open in a tab, over the local SFTP server: its copy in `dir/copy`.
@MainActor private func openOnServer(_ path: String, in dir: String, host h: EditorHost) async throws -> Editor {
    let t = SFTPTarget.local(), c = try SFTPClient(t)
    let state = AppDelegate.RemoteEdit(baseline: try #require(try c.stat(path)))
    c.close()
    let copy = URL(fileURLWithPath: dir + "/copy-" + UUID().uuidString + "/" + (path as NSString).lastPathComponent)
    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: path, toPath: copy.path)
    let (onSaved, onClose) = h.onServer(t, path, state, copy.deletingLastPathComponent().path)
    Editor.open(copy, remote: SavedServer.title(t, path), server: (t, path, state), onSaved: onSaved, onClose: onClose)
    try await waitUntil("opened") { Editor.editing(t, path) != nil }
    return try #require(Editor.editing(t, path))
}

extension EditorWindowTests {
    /// A tab renames its file on this Mac: tab, title and colors follow, its changed text stays and the session names
    /// the new path at once; ⌘S then writes there without asking. Not onto a file another tab has, a taken name, a
    /// tool's file, nor while it saves. A panel's ⇧F6 (the same rename) takes the tab along.
    @Test func aTabRenamesItsFileOnThisMac() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { crash(); try? FileManager.default.removeItem(atPath: dir) }
        let h = launch(dir + "/drafts")
        try put("key = 1\n", dir + "/app.conf")
        try put("other\n", dir + "/taken.yaml")
        try put("x\n", dir + "/b.conf")
        let url = URL(fileURLWithPath: dir + "/app.conf"), b = URL(fileURLWithPath: dir + "/b.conf")
        Editor.open(b)
        try await waitUntil("b") { editorDoc(b) != nil }
        Editor.open(url)
        try await waitUntil("opened") { editorDoc(url) != nil }
        let (e, eb) = (try #require(editorDoc(url)), try #require(editorDoc(b)))
        type(e, "more = 2\n")
        await e.rename(to: "app.yaml")
        let new = URL(fileURLWithPath: dir + "/app.yaml")
        #expect(e.url == new && read(new.path) == "key = 1\n" && read(url.path) == nil, "the file moved; what's typed isn't in it")
        #expect(e.window?.title == "app.yaml" && h.tabTitle(e) == "app.yaml" && e.tip.hasSuffix("app.yaml") && e.language == .yaml)
        #expect(e.isEdited && e.textView.string == "key = 1\nmore = 2\n")
        #expect(try manifest(dir + "/drafts").docs.first { $0.id == e.id }?.path == new.path, "the draft follows it at once")
        #expect(await e.save() && e.window?.attachedSheet == nil, "the same file: no “changed on disk”")
        #expect(read(new.path) == "key = 1\nmore = 2\n" && read(url.path) == nil, "the old name isn't made again")

        await eb.rename(to: "app.yaml")
        #expect(eb.frame.text == "“app.yaml” is open in the editor — nothing was renamed." && eb.url == b)
        await eb.rename(to: "taken.yaml")
        #expect(try await answer(eb.window, .alertFirstButtonReturn).contains("already exists") && read(dir + "/taken.yaml") == "other\n" && eb.url == b)
        let gate = DispatchSemaphore(value: 0)
        eb.willRename = { _ in gate.wait() }
        type(eb, "y\n")
        let saving = Task { await eb.save() }
        try await waitUntil("saving") { eb.saving }
        await eb.rename(to: "c.conf")
        #expect(eb.frame.text == "Not renamed: it's being saved")
        gate.signal()
        #expect(await saving.value && read(b.path) == "x\ny\n")
        eb.willRename = { _ in }
        let tool = try Editor.open(URL(fileURLWithPath: dir + "/t.json"), text: "{}\n", beside: NSView()) { _ in }
        defer { tool.close() }
        await tool.rename(to: "u.json")
        #expect(tool.frame.text == "Not renamed: Kermo reads a tool's file where it is")

        #expect(Editor.renameRefused(b.path, to: new.path) == "“app.yaml” is open in the editor — nothing was renamed.")
        _ = try AppDelegate.rename(b.path, to: "notes")   // the panel's ⇧F6
        await Editor.renamed(b.path, to: dir + "/notes")
        #expect(eb.url?.path == dir + "/notes" && eb.language == nil && h.tabTitle(eb) == "notes")

        h.beginRename(eb)   // the field on its tab, then ↩
        let field = try #require(h.renameField)
        #expect(field.stringValue == "notes" && h.renameField != nil)
        field.stringValue = "notes.ini"
        #expect(h.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try await waitUntil("renamed by ↩") { eb.url?.lastPathComponent == "notes.ini" }
        #expect(h.renameField == nil && read(dir + "/notes.ini") == "x\ny\n" && eb.language == .ini)
    }

    /// An Untitled takes a name and no file: its language by it, Save As offers it (`name`), the session keeps it and a
    /// launch brings it back. A session without the field reads as before, one with a field an older Kermo doesn't
    /// know reads too. Two Untitleds of one name are just that name.
    @Test func anUntitledTakesANameAndNoFile() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { crash(); try? FileManager.default.removeItem(atPath: dir) }
        let h = launch(dir + "/drafts")
        let u = Editor.untitled(), v = Editor.untitled()
        type(u, "a: 1\n")
        await u.rename(to: "deploy.yaml")
        await v.rename(to: "deploy.yaml")
        #expect(u.name == "deploy.yaml" && u.url == nil && u.language == .yaml)
        #expect(h.tabTitle(u) == "deploy.yaml" && h.tabTitle(v) == "deploy.yaml" && v.window?.title == "deploy.yaml")
        await u.rename(to: "a/b")
        #expect(u.name == "deploy.yaml" && u.frame.text == "Not renamed: A name can't contain “/”")
        _ = await h.commit(durable: true)
        let s = try manifest(dir + "/drafts")
        #expect(s.docs.first { $0.id == u.id }?.name == "deploy.yaml" && !FileManager.default.fileExists(atPath: dir + "/deploy.yaml"))

        let back = launch(dir + "/drafts")
        let r = try #require(back.docs.first { $0.id == u.id })
        try await waitUntil("restored") { r.textView.string == "a: 1\n" }
        #expect(r.name == "deploy.yaml" && r.language == .yaml && r.isEdited)

        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        var docs = try #require(json["docs"] as? [[String: Any]])
        docs = docs.map { var d = $0; d.removeValue(forKey: "name"); d["fromANewerKermo"] = 1; return d }
        json["docs"] = docs
        let old = try JSONDecoder().decode(EditorSession.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.docs.count == s.docs.count && old.docs.allSatisfy { $0.name == nil } && old.version == EditorSession.current)
    }

    /// Close Other Tabs / to the Right ask each changed tab in turn (Don't Save, Save, Cancel as ⌘W); an unchanged one
    /// just goes; Cancel keeps that tab and the rest. The tab's menu offers what fits it.
    @Test func closeOthersAsksEachChangedTabInTurn() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { crash(); try? FileManager.default.removeItem(atPath: dir) }
        let h = launch(dir + "/drafts")
        let k = Editor.untitled(), a = Editor.untitled(), c = Editor.untitled(), d = Editor.untitled(), z = Editor.untitled()
        type(a, "a")
        type(d, "d")
        func menu(_ e: Editor) -> [String] { h.tabMenu(for: e).map { $0.isSeparatorItem ? "—" : $0.title + ($0.isEnabled ? "" : " (off)") } }
        #expect(menu(z) == ["Close Tab", "Close Other Tabs", "Close Tabs to the Right (off)", "—", "Rename…", "Copy Path (off)", "Reveal in Panel (off)"])
        h.closeRight(of: k)
        #expect(try await answer(h.window, .alertSecondButtonReturn).contains(a.name))   // Don't Save
        #expect(try await answer(h.window, .alertThirdButtonReturn).contains(d.name))   // Cancel: d and z stay
        try await waitUntil("a and c closed") { h.docs.map(\.id) == [k.id, d.id, z.id] }
        _ = c
        h.closeOthers(than: k)
        #expect(try await answer(h.window, .alertSecondButtonReturn).contains(d.name))
        try await waitUntil("all but k") { h.docs.map(\.id) == [k.id] && h.active === k }
        type(k, "k")
        h.middleClicked(0)   // the middle button: ⌘W's question
        #expect(try await answer(h.window, .alertThirdButtonReturn).contains(k.name) && h.docs.map(\.id) == [k.id])
        h.doubleClickedPastTabs()
        #expect(h.docs.count == 2 && h.active?.url == nil && h.active !== k)
        h.moveTab(from: 1, to: 0)
        #expect(h.docs.last === k)
        _ = await h.commit()
        #expect(try manifest(dir + "/drafts").docs.last?.id == k.id, "a drag's order is the session's")
    }

    /// ⇧⌘T: the last closed tab first, back where it was with its caret — this Mac's file as it is now, a Don't Save's
    /// text as it was; its file open meanwhile is only chosen; twenty at most.
    @Test func reopenClosedTabBringsTabsBackWhereTheyWere() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { crash(); try? FileManager.default.removeItem(atPath: dir) }
        let h = launch(dir + "/drafts")
        try put("one\ntwo\n", dir + "/f.conf")
        let f = URL(fileURLWithPath: dir + "/f.conf")
        let u = Editor.untitled()
        Editor.open(f)
        try await waitUntil("f") { editorDoc(f) != nil }
        let ef = try #require(editorDoc(f))
        let w = Editor.untitled()
        let at = try #require(h.docs.firstIndex { $0 === ef })
        ef.textView.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(ef.closeAsking())
        try await waitUntil("f closed") { editorDoc(f) == nil }
        type(u, "scratch")
        #expect(!u.closeAsking())
        try await answer(h.window, .alertSecondButtonReturn)   // Don't Save
        try await waitUntil("u closed") { !h.docs.contains { $0 === u } }
        try put("one\ntwo\nthree\n", dir + "/f.conf")

        h.reopenClosed()
        let ru = try #require(h.docs.first { $0.id == u.id })
        try await waitUntil("its text") { ru.textView.string == "scratch" }
        #expect(ru.isEdited && ru.name == u.name && h.docs.firstIndex { $0 === ru } == at - 1)
        _ = await h.commit()
        let back = try #require(try manifest(dir + "/drafts").docs.first { $0.id == u.id })
        #expect(back.dirty && back.revision != nil, "its text is a draft again, not only in memory")
        h.reopenClosed()
        let rf = try #require(editorDoc(f))
        try await waitUntil("read") { rf.cover == nil }
        #expect(rf.textView.string == "one\ntwo\nthree\n" && !rf.isEdited && h.docs.firstIndex { $0 === rf } == at && rf.textView.selectedRange().location == 4)
        #expect(h.docs.firstIndex { $0 === w } == at + 1)

        #expect(rf.closeAsking())
        try await waitUntil("closed again") { editorDoc(f) == nil }
        Editor.open(f)
        try await waitUntil("open again") { editorDoc(f) != nil }
        let again = try #require(editorDoc(f))
        h.select(w)
        h.reopenClosed()
        #expect(h.docs.filter { $0.url == f }.count == 1 && h.active === again, "one file, one tab")

        for _ in 0..<21 { Editor.untitled().closeAsking() }
        try await waitUntil("21 closed") { h.docs.count == 3 }
        for _ in 0..<21 { h.reopenClosed() }
        #expect(h.docs.count == 23, "twenty kept")
    }

    /// A server's file renamed from its tab: production asks first with both names (↩ Cancel) and logs it; the tab, its
    /// title and colors follow; the next save goes to the new path and the old name doesn't come back; the session has
    /// it at once. Not while an upload is under way. A locked server: Touch ID before the field.
    @Test func aTabRenamesItsFileOnItsServer() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        let wasLog = AuditLog.path
        AuditLog.path = dir + "/audit.jsonl"
        let app = testApp(dir)
        defer {
            Editor.app = { NSApp.delegate as? AppDelegate }
            (AppDelegate.answering, AuditLog.path, ServerLock.servers) = (nil, wasLog, { [] })
            ServerLock.relock()
            app.panels.forEach { $0.shutdown() }
            crash()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let h = launch(dir + "/drafts") { app.remoteEditing($0, $1, $2, in: $3) }
        try FileManager.default.createDirectory(atPath: dir + "/srv", withIntermediateDirectories: true)
        try put("v1\n", dir + "/srv/app.conf")
        let from = dir + "/srv/app.conf", to = dir + "/srv/app.yaml"
        let e = try await openOnServer(from, in: dir, host: h)
        type(e, "v2\n")
        var prod = SavedServer(address: "localhost")!
        prod.prod = true
        ServerLock.servers = { [prod] }
        var asked: [String] = []
        AppDelegate.answering = { m, _, ret in asked.append(m); return ret ?? 0 }   // ↩
        await e.rename(to: "app.yaml")
        #expect(asked.count == 1 && asked[0].contains("“app.conf” to “app.yaml”") && e.server?.path == from && read(from) == "v1\n")
        AppDelegate.answering = { m, _, _ in asked.append(m); return 0 }   // Rename; then the save's Save
        await e.rename(to: "app.yaml")
        #expect(e.server?.path == to && read(to) == "v1\n" && read(from) == nil)
        #expect(e.name == "app.yaml" && e.window?.title == "app.yaml" && e.language == .yaml && e.isEdited)
        #expect(try manifest(dir + "/drafts").docs.first { $0.id == e.id }?.server?.path == to)
        Config.flush()
        let log = (try? String(contentsOfFile: AuditLog.path, encoding: .utf8)) ?? ""
        #expect(log.contains("\"action\":\"rename\"") && log.contains("app.conf") && log.contains("app.yaml"), "\(log)")
        #expect(await e.save())
        #expect(await e.server?.state.upload?.value == true)
        #expect(read(to) == "v1\nv2\n" && read(from) == nil, "the save went to the new name")

        var locked = SavedServer(address: "localhost")!
        locked.locked = true
        ServerLock.servers = { [locked] }
        ServerLock.relock()
        var asks = 0, unlock = false, hold = true
        ServerLock.authenticate = { _ in asks += 1; while hold { try? await Task.sleep(for: .milliseconds(20)) }; return unlock }
        defer { ServerLock.authenticate = { _ in false } }
        e.server?.state.unlockFirst = true
        type(e, "v3\n")
        #expect(await e.save())
        try await waitUntil("uploading") { (e.server?.state.sending ?? 0) > 0 }
        await e.rename(to: "app2.yaml")
        #expect(e.frame.text == "Not renamed: an upload to localhost is still going" && e.server?.path == to)
        hold = false
        _ = await e.server?.state.upload?.value
        if let sheet = e.window?.attachedSheet { e.window?.endSheet(sheet) }   // "wasn't saved": Touch ID refused
        asks = 0
        h.beginRename(e)
        try await waitUntil("asked") { asks == 1 }
        #expect(h.renameField == nil, "no field without Touch ID")
        unlock = true
        h.beginRename(e)
        try await waitUntil("the field") { h.renameField != nil }
        #expect(h.renameField?.stringValue == "app.yaml" && h.renameField?.currentEditor()?.selectedRange == NSRange(location: 0, length: 3))
        h.endRename(nil)   // ⎋
        #expect(h.renameField == nil && e.server?.path == to && e.window?.firstResponder === e.textView)

        // A panel's ⇧F6 of it through another spelling of the server (its root panel's, a kept connection's): the tab follows.
        let moved = dir + "/srv/app2.yaml"
        #expect(await app.renameOnServer(SFTPTarget.local().persisting(60), to, to: moved, in: app.panels[0]) { _ in })
        #expect(e.server?.path == moved && read(moved) == "v1\nv2\n" && e.name == "app2.yaml")
    }

    /// A server's file gone from the server since it was opened (deleted, or renamed elsewhere): a save asks before
    /// making it again under its old name — ↩ is Cancel, nothing written; Save makes it. A file that wasn't there when it
    /// was opened (a new one) is made without a question.
    @Test func aSaveAsksBeforeMakingAGoneServerFileAgain() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        let app = testApp(dir)
        defer {
            Editor.app = { NSApp.delegate as? AppDelegate }
            AppDelegate.answering = nil
            app.panels.forEach { $0.shutdown() }
            try? FileManager.default.removeItem(atPath: dir)
        }
        let file = dir + "/app.conf", copy = URL(fileURLWithPath: dir + "/copy/app.conf")
        try put("v1\n", file)
        try FileManager.default.createDirectory(atPath: dir + "/copy", withIntermediateDirectories: true)
        try put("mine\n", copy.path)
        let c = try SFTPClient(.local())
        let state = AppDelegate.RemoteEdit(baseline: try #require(try c.stat(file)))
        c.close()
        try FileManager.default.removeItem(atPath: file)   // deleted there, or renamed outside its tab
        var asked: [String] = []
        AppDelegate.answering = { m, _, ret in asked.append(m); return ret ?? 0 }   // ↩
        #expect(await app.upload(copy, to: file, on: .local(), state) == false)
        #expect(asked == ["“app.conf” is gone from localhost since you opened it"] && read(file) == nil, "\(asked)")
        AppDelegate.answering = { _, _, _ in 0 }   // Save
        #expect(await app.upload(copy, to: file, on: .local(), state) && read(file) == "mine\n")
        // A link whose file is gone (sites-enabled → sites-available): asked too, the link left as it is.
        try put("v1\n", dir + "/real.conf")
        try FileManager.default.createSymbolicLink(atPath: dir + "/link.conf", withDestinationPath: "real.conf")
        let c2 = try SFTPClient(.local())
        let linked = AppDelegate.RemoteEdit(baseline: try #require(try c2.stat(dir + "/link.conf")))
        c2.close()
        try FileManager.default.removeItem(atPath: dir + "/real.conf")
        asked = []
        AppDelegate.answering = { m, _, ret in asked.append(m); return ret ?? 0 }
        #expect(await app.upload(copy, to: dir + "/link.conf", on: .local(), linked) == false && asked.count == 1 && read(dir + "/real.conf") == nil)
        asked = []
        AppDelegate.answering = { m, _, _ in asked.append(m); return 1 }
        #expect(await app.upload(copy, to: dir + "/new.conf", on: .local(), AppDelegate.RemoteEdit(baseline: .nothing)) && asked.isEmpty)
    }

    /// ⇧⌘T on a server's tab: an unchanged one comes back parked — nothing downloaded, no Touch ID — and a Don't Save's
    /// draft on a locked server stays locked till it's unlocked.
    @Test func aReopenedServerTabConnectsOnlyOnAClick() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        let app = testApp(dir)
        defer {
            Editor.app = { NSApp.delegate as? AppDelegate }
            ServerLock.servers = { [] }
            ServerLock.relock()
            app.panels.forEach { $0.shutdown() }
            crash()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let h = launch(dir + "/drafts") { app.remoteEditing($0, $1, $2, in: $3) }
        try put("v1\n", dir + "/a.conf")
        let path = dir + "/a.conf"
        let e = try await openOnServer(path, in: dir, host: h)
        #expect(e.closeAsking())
        try await waitUntil("closed") { Editor.editing(.local(), path) == nil }
        var locked = SavedServer(address: "localhost")!
        locked.locked = true
        var asks = 0
        ServerLock.servers = { [locked] }
        ServerLock.authenticate = { _ in asks += 1; return false }
        defer { ServerLock.authenticate = { _ in false } }
        h.reopenClosed()
        let r = try #require(Editor.editing(.local(), path))
        try await waitUntil("parked") { r.cover == .parked }
        #expect(asks == 0 && r.url.map { FileManager.default.fileExists(atPath: $0.path) } == false && r.heading.title == "a.conf")

        #expect(r.closeAsking())
        try await waitUntil("closed") { Editor.editing(.local(), path) == nil }
        ServerLock.servers = { [] }
        let open = try await openOnServer(path, in: dir, host: h)
        type(open, "secret\n")
        ServerLock.servers = { [locked] }
        ServerLock.relock()
        #expect(!open.closeAsking())
        try await answer(h.window, .alertSecondButtonReturn)   // Don't Save
        try await waitUntil("closed") { Editor.editing(.local(), path) == nil }
        h.reopenClosed()
        let back = try #require(Editor.editing(.local(), path))
        try await waitUntil("locked") { back.cover == .locked }
        #expect(back.textView.string == "" && asks == 0 && back.copyablePath == nil && !back.revealable)
        ServerLock.authenticate = { _ in asks += 1; return true }
        back.connect()
        try await waitUntil("unlocked") { back.cover == nil }
        #expect(back.textView.string.hasSuffix("secret\n") && back.isEdited && asks == 1)
    }

    /// The editor window takes the panels' ⇧F6, ⇧⌘C and ⇧⌘T for its tab — Rename…, Copy Path (an Untitled has none),
    /// Reopen Closed Tab — on those keys; F10 and ⌥0 stay the text's. The panels keep them as they were. ⇧⌘T reopens over
    /// a server panel or a parked one in the main window, where Folder Tree refuses; a tool's editor has no tabs.
    @Test func theTabsKeysAreBranchesOfThePanelsCommands() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        let app = testApp(dir)
        app.commands = app.makeCommands()
        let menu = app.makeMenu()
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)), panels = NSView(frame: parent.bounds)
        parent.addSubview(panels)
        app.terminal = EmbeddedTerminal(covering: panels)
        defer {
            AppDelegate.keyWindow = { NSApp.keyWindow }
            Editor.app = { NSApp.delegate as? AppDelegate }
            app.panels.forEach { $0.shutdown() }
            crash()
            try? FileManager.default.removeItem(atPath: dir)
        }
        func keys(_ id: String) -> [String] { app.commands.first { $0.id == id }?.keys.map(\.display) ?? [] }
        func item(_ id: String) throws -> NSMenuItem { try #require(menu.allItems.first { $0.representedObject as? String == id }) }
        #expect(keys("go.tree") == ["F10", "⌥0", "⌥F10", "⇧⌘T"] && keys("file.rename").first == "⇧F6" && keys("edit.copyPath").first == "⇧⌘C")
        app.updateMenuKeys(menu)
        #expect(try item("go.tree").title == "Folder Tree…" && item("file.rename").title == "Rename…")

        let h = launch(dir + "/drafts")
        try put("x\n", dir + "/f.conf")
        let f = URL(fileURLWithPath: dir + "/f.conf")
        Editor.open(f)
        try await waitUntil("f") { editorDoc(f) != nil }
        let e = try #require(editorDoc(f))
        AppDelegate.keyWindow = { h.window }
        app.updateMenuKeys(menu)
        let tree = try item("go.tree"), rename = try item("file.rename"), copy = try item("edit.copyPath")
        #expect(app.validateMenuItem(tree) && tree.title == "Reopen Closed Tab" && tree.keyEquivalent == "t" && tree.keyEquivalentModifierMask == [.command, .shift])
        #expect(app.validateMenuItem(rename) && rename.keyEquivalent == Shortcut("shift+f6")!.menuKey && rename.keyEquivalentModifierMask == .shift)
        #expect(app.validateMenuItem(copy) && copy.keyEquivalent == "c" && copy.keyEquivalentModifierMask == [.command, .shift])
        #expect(!menu.allItems.contains { $0.keyEquivalent == Shortcut("f10")!.menuKey }, "F10 is no item's key there: nothing, as before")
        let board = NSPasteboard(name: .init("kermo-test-" + UUID().uuidString))
        e.copyPath(to: board)
        #expect(board.string(forType: .string) == f.path)
        let u = Editor.untitled()
        let before = board.changeCount
        u.copyPath(to: board)
        #expect(app.validateMenuItem(copy) && board.changeCount == before, "its key stays as tabs change; an Untitled has no path to copy")

        let remote = try #require(app.panels.first)
        remote.loadRemote(.local(), dir: dir, select: nil)
        try await waitUntil("connected") { remote.remote != nil && remote.connecting == nil }
        let parked = PanelViewController(session: [Session.Tab(path: dir, cursor: "x", server: SFTPTarget(host: "me@web1.invalid"), dir: "/etc")], index: 0, showHidden: false)
        parked.loadViewIfNeeded()
        defer { parked.shutdown() }
        for order in [[remote, parked], [parked, remote]] {
            app.panels = order
            let n = h.docs.count
            #expect(h.active?.closeAsking() == true)
            try await waitUntil("closed") { h.docs.count == n - 1 }
            app.run("go.tree", key: Shortcut("cmd+shift+t"))
            #expect(h.docs.count == n && !app.active.statusText.contains("Not available"), "\(app.active.statusText)")
        }
        app.panels = [remote, parked]

        let tool = try Editor.open(URL(fileURLWithPath: dir + "/t.json"), text: "{}\n", beside: NSView()) { _ in }
        defer { tool.close() }
        AppDelegate.keyWindow = { tool.window }
        app.updateMenuKeys(menu)
        #expect(!app.validateMenuItem(tree) && tree.title == "Folder Tree…" && app.validateMenuItem(rename), "no tabs to reopen; Rename says why not")
    }
}
