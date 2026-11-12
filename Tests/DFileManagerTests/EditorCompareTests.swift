import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Editor E6 PR 4: Compare — side by side on the two panes, a document live against itself or a read-only copy.

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-compare-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}
private func put(_ s: String, _ path: String) throws { try Data(s.utf8).write(to: URL(fileURLWithPath: path)) }
private func read(_ path: String) -> String? { FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } }

@MainActor private func until(_ what: String, _ cond: () -> Bool) async throws {
    for _ in 0..<250 where !cond() { try await Task.sleep(for: .milliseconds(20)) }
    #expect(cond(), "\(what)")
}

/// A fresh editor window with its drafts in `dir`.
@MainActor private func fresh(_ dir: String, onServer: @escaping EditorHost.OnServer = { _, _, _, _ in ({ _ in }, {}) }) -> EditorHost {
    gone()
    EditorHost.restore(dir, onServer: onServer)
    return EditorHost.tabs
}
@MainActor private func gone() {
    guard let h = EditorHost.shared else { return }
    h.stopComparing()
    for e in h.docs { e.closed(); e.host = nil }
    h.drafts?.release()
    h.window?.orderOut(nil)
    EditorHost.shared = nil
}

@MainActor private func opened(_ path: String) async throws -> Editor {
    Editor.open(URL(fileURLWithPath: path))
    try await until("opened \(path)") { Editor.document(at: path) != nil }
    return try #require(Editor.document(at: path))
}

/// A read-only copy of `text`, as Compare makes one of a file.
@MainActor private func copy(_ text: String, of path: String? = nil) -> Editor {
    Editor.snapshot((text, .utf8, false, false, false, nil, Editor.sha(Data(text.utf8))), file: "a.conf", title: "a.conf (on disk)", place: "~",
                    source: path.map { AppDelegate.DiffSide(path: $0) })
}

@MainActor private func c2(_ h: EditorHost) -> Comparison { h.comparison! }

@MainActor private func worked(_ c: Comparison?) async throws {
    try await until("compared") { c.map { $0.words(for: $0.new.view!) != "Comparing…" } == true }
}

/// A test's app (a window and one panel in `dir`) for what goes through it.
@MainActor private func app(_ dir: String) -> AppDelegate {
    let app = AppDelegate()
    app.window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    app.panels = [PanelViewController(tabs: [dir], index: 0, showHidden: false)]
    app.panels.forEach { $0.loadViewIfNeeded() }
    Editor.app = { app }
    return app
}

extension EditorWindowTests {
    /// A read-only copy: no typing, no Save, Save As or Rename, no draft, not in the session or ⇧⌘T, no lookup finds it
    /// (F4 on its file opens the document), closing it asks nothing — and that ends the comparison.
    @Test func aCopyIsReadOnlyAndNeverADocument() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { gone(); try? FileManager.default.removeItem(atPath: dir) }
        let h = fresh(dir + "/drafts")
        try put("a\nb\n", dir + "/a.conf")
        try put("a\nB\n", dir + "/b.conf")
        let doc = try await opened(dir + "/b.conf"), snap = copy("a\nb\n", of: dir + "/a.conf")
        h.compare(old: snap, new: doc, snapshots: [snap])
        let c = try #require(h.comparison)
        try await worked(c)
        #expect(h.panes.count == 2 && h.panes[0].active === doc && h.panes[1].active === snap && h.active === doc, "the document stays, the copy beside it; the keys stay")
        snap.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(snap.textView.string == "a\nb\n" && !snap.isEdited && !snap.textView.isEditable)
        #expect(await snap.save() == false && snap.renameRefusal != nil && snap.sessionDoc == nil && snap.reopenable == nil)
        let save = NSMenuItem(title: "Save", action: #selector(Editor.saveDocument(_:)), keyEquivalent: "")
        #expect(!snap.validateMenuItem(save))
        #expect(Editor.document(at: dir + "/a.conf") == nil && snap.heading.subtitle.hasPrefix("Read-only"))
        _ = await h.commit()
        let session = try JSONDecoder().decode(EditorSession.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/drafts/session.json")))
        #expect(!session.docs.contains { $0.id == snap.id } && session.panes?.tabs.joined().contains(snap.id) != true, "never in the session")
        let a = try await opened(dir + "/a.conf")
        #expect(a !== snap && a.textView.isEditable, "F4 on its file: the document, not the copy")
        snap.closeAsking()
        try await until("closed") { !h.docs.contains { $0 === snap } }
        #expect(h.window?.attachedSheet == nil && h.comparison == nil, "nothing asked; the comparison is over")
    }

    /// The colors are the views' own: the storage's attributes, Undo, the edited mark and the draft stay as they were;
    /// a clone of the document elsewhere shows none. Equal lines stand level (blank space across from an added line),
    /// and typing works it out anew, the latest only.
    @Test func comparingChangesNothingInTheText() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        let wrap = UserDefaults.standard.object(forKey: "editorWrap")
        UserDefaults.standard.set(false, forKey: "editorWrap")
        defer { UserDefaults.standard.set(wrap, forKey: "editorWrap"); gone(); try? FileManager.default.removeItem(atPath: dir) }
        let h = fresh(dir + "/drafts")
        try put("one\ntwo\nthree\nfour\n", dir + "/f.conf")
        let doc = try await opened(dir + "/f.conf")
        doc.textView.insertText("zero\n", replacementRange: NSRange(location: 0, length: 0))
        let attrs = { (e: Editor) in (0..<e.storage.length).map { e.storage.attributes(at: $0, effectiveRange: nil).keys.sorted { $0.rawValue < $1.rawValue } } }
        let before = (attrs(doc), doc.isEdited, doc.edits, doc.textView.undoManager?.canUndo)
        let snap = copy("one\nTWO\nthree\nfour\n")
        h.compare(old: snap, new: doc, snapshots: [snap])
        let c = try #require(h.comparison)
        try await worked(c)
        #expect(c.blocks == [TextDiff.Block(old: 0..<0, new: 0..<1), TextDiff.Block(old: 1..<2, new: 2..<3)])
        #expect(c.words(for: doc.current) == "Change 1 of 2" || c.words(for: doc.current) == "2 changes")
        #expect(c.new.mark(at: 0)?.kind == .added && c.new.mark(at: 9)?.kind == .changed && c.old.mark(at: 4)?.kind == .changed)
        #expect(c.old.top > 0 && c.new.top == 0, "blank space before the copy's first line, across from the added one")
        let after = (attrs(doc), doc.isEdited, doc.edits, doc.textView.undoManager?.canUndo)
        #expect(after.0 == before.0 && after.1 == before.1 && after.2 == before.2 && after.3 == before.3, "the text as it was")
        // Level: "three" (old line 2, new line 3) at one height in both views.
        func y(_ e: Editor, _ line: Int) -> CGFloat {
            let v = e.views.first { $0 === c.old.view || $0 === c.new.view }!, lm = v.text.layoutManager!
            return v.text.textContainerOrigin.y + lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: v.ruler.starts[line]), effectiveRange: nil).minY
        }
        #expect(abs(y(snap, 2) - y(doc, 3)) < 0.5, "\(y(snap, 2)) \(y(doc, 3))")

        let (mine, theirs) = (try #require(c.new.view?.pane), try #require(c.old.view?.pane))
        h.clone(doc, from: mine)   // the document shown in the copy's pane too: paused
        let clone = try #require(doc.views.first { $0.pane === theirs })
        #expect(c.paused && clone.text.compared == nil && clone.text.layoutManager?.delegate == nil && c.words(for: c.new.view!) == "Compare paused")
        h.select(snap, in: theirs)
        #expect(!c.paused && h.comparison === c, "back: on again")

        // Live: two quick changes, the result of the last.
        doc.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        doc.textView.insertText("y", replacementRange: NSRange(location: doc.storage.length, length: 0))
        try await until("worked out anew") { c.blocks.count == 3 }
        #expect(c.blocks.last == TextDiff.Block(old: 4..<5, new: 5..<6), "\(c.blocks)")
        #expect(doc.textView.string == "xzero\none\ntwo\nthree\nfour\ny")

        // A line over one side's text (a draft's "changed on disk"): as much blank space over the other's, gone with it.
        let (dv, sv) = (try #require(c.new.view), try #require(c.old.view))
        dv.frame.banner = Banner("changed on disk", [])
        c.levelTops()
        #expect(sv.frame.banner?.frame.height == dv.frame.banner?.frame.height && sv.frame.scroll.frame.maxY == dv.frame.scroll.frame.maxY)
        dv.frame.banner = nil
        c.levelTops()
        #expect(sv.frame.banner == nil)
        dv.frame.banner = Banner("changed on disk", [])
        h.select(Editor.untitled(), in: try #require(sv.pane))   // paused: the other side shows alone, no blank band over it
        c.levelTops()
        #expect(c.paused && sv.frame.banner == nil)
        dv.frame.banner = nil
    }

    /// ⌥⌘↓ ⌥⌘↑ go from change to change while it compares (Focus Pane Below / Above otherwise); ⇧⌘D in the editor window
    /// is Compare With… (Compare Files in the panels); Stop Comparing, a side moved, Join Panes end it, copies closed.
    @Test func compareKeysAndItsEnd() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        let a = app(dir)
        a.commands = a.makeCommands()
        let menu = a.makeMenu()
        defer {
            AppDelegate.keyWindow = { NSApp.keyWindow }
            Editor.app = { NSApp.delegate as? AppDelegate }
            a.panels.forEach { $0.shutdown() }
            gone()
            try? FileManager.default.removeItem(atPath: dir)
        }
        func item(_ id: String) throws -> NSMenuItem { try #require(menu.allItems.first { $0.representedObject as? String == id }) }
        let h = fresh(dir + "/drafts")
        try put("1\n2\n3\n4\n5\n6\n", dir + "/f.txt")
        let doc = try await opened(dir + "/f.txt")
        AppDelegate.keyWindow = { h.window }
        a.updateMenuKeys(menu)
        let (diff, next, stop) = (try item("file.diff"), try item("editor.compare.next"), try item("editor.compare.stop"))
        #expect(a.validateMenuItem(diff) && diff.title == "Compare With…" && !a.validateMenuItem(next))
        let snap = copy("1\nX\n3\n4\nY\n6\n")
        h.compare(old: snap, new: doc, snapshots: [snap])
        let c = try #require(h.comparison)
        try await worked(c)
        #expect(a.validateMenuItem(next) && a.validateMenuItem(stop))
        doc.current.text.setSelectedRange(NSRange(location: 0, length: 0))
        a.run("term.pane.down")
        #expect(doc.current.text.selectedRange().location == 2 && c.words(for: doc.current) == "Change 1 of 2")
        a.run("term.pane.down")
        #expect(doc.current.text.selectedRange().location == 8 && c.words(for: doc.current) == "Change 2 of 2")
        a.run("term.pane.down")
        #expect(doc.current.text.selectedRange().location == 2, "round to the first")
        a.run("term.pane.up")
        #expect(doc.current.text.selectedRange().location == 8)
        #expect(Editor.keys(of: h.window)?.contains { $0.title == "Next Change" && $0.key == "⌥⌘↓" } == true)
        a.run("editor.compare.stop")
        #expect(h.comparison == nil && !h.docs.contains { $0 === snap } && h.panes.count == 1, "the copy closed, its pane with it")
        #expect(doc.current.text.compared == nil && doc.current.ruler.compared == nil && doc.current.text.layoutManager?.delegate == nil)

        // Typed, and before it's worked out again: an old block past the shorter text's end — nothing breaks.
        let tail = copy("1\n2\n3\n4\n5\n6\nA\nB\n")
        h.compare(old: tail, new: doc, snapshots: [tail])
        let t = try #require(h.comparison)
        try await worked(t)
        #expect(t.blocks == [TextDiff.Block(old: 6..<8, new: 6..<6)])
        doc.current.text.insertText("", replacementRange: NSRange(location: 6, length: 6))   // "4\n5\n6\n" gone
        t.regap()
        a.run("term.pane.down")
        try await until("worked out anew") { t.blocks == [TextDiff.Block(old: 3..<8, new: 3..<3)] }
        a.run("editor.compare.stop")

        let other = Editor.untitled()
        other.textView.insertText("1\n2\n", replacementRange: NSRange(location: 0, length: 0))
        h.compare(old: other, new: doc)
        #expect(h.comparison != nil && h.panes.count == 2)
        h.move(doc, from: c2(h).new.view?.pane)
        #expect(h.comparison == nil, "a side moved into the other's pane: over")
        h.compare(old: other, new: doc)
        h.joinPanes()
        #expect(h.comparison == nil && h.docs.contains { $0 === other }, "Join Panes ends it; documents stay")
        a.run("term.pane.down")   // not comparing, one pane: Focus Pane Below beeps, nothing moves
        #expect(h.panes.count == 1)

        AppDelegate.keyWindow = { a.window }
        a.updateMenuKeys(menu)
        _ = a.validateMenuItem(diff)
        #expect(diff.title == "Compare Files")
    }

    /// Copy Change to Left / Right (E6 PR 5): the caret's change as the other side has it, into a document only — one
    /// Undo step back to the text byte for byte, nothing saved; a changed, a removed and an added block; never into a
    /// read-only copy; a result from before the latest typing isn't used; the arrow shows only where it can write.
    @Test func copyChangeGoesIntoADocumentOnly() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        let a = app(dir)
        a.commands = a.makeCommands()
        defer {
            AppDelegate.keyWindow = { NSApp.keyWindow }
            Editor.app = { NSApp.delegate as? AppDelegate }
            a.panels.forEach { $0.shutdown() }
            gone()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let h = fresh(dir + "/drafts")
        AppDelegate.keyWindow = { h.window }
        let (oldText, newText) = ("1\n2\n3\n4\n5\n", "1\nX\n3\n5\nY\n")
        try put(oldText, dir + "/a.txt")
        try put(newText, dir + "/b.txt")
        let x = try await opened(dir + "/a.txt"), y = try await opened(dir + "/b.txt")
        h.compare(old: x, new: y)
        let c = try #require(h.comparison)
        try await worked(c)
        #expect(c.blocks == [TextDiff.Block(old: 1..<2, new: 1..<2), TextDiff.Block(old: 3..<4, new: 3..<3), TextDiff.Block(old: 5..<5, new: 4..<5)])
        let left = try #require(c.side(left: true)), (xSide, ySide) = (c.old, c.new)
        #expect(xSide.view?.doc === x && ySide.view?.doc === y && c.side(left: false) !== left)
        let into = { (e: Editor) in a.run(e === x ? (xSide === left ? "editor.compare.copyLeft" : "editor.compare.copyRight")
                                                   : (ySide === left ? "editor.compare.copyLeft" : "editor.compare.copyRight")) }
        y.current.text.setSelectedRange(NSRange(location: 2, length: 0))   // in "X"
        c.caretMoved(y.current)
        #expect(xSide.arrow?.at == 2 && ySide.arrow?.at == 2, "both are documents: an arrow on each")
        #expect(AppDelegate.editorPickOff("editor.compare.copyLeft", in: h.window) == "editor.compare.copyLeft", "its keys while it compares, whenever it began")
        into(x)   // changed: "2" → "X"
        #expect(x.textView.string == "1\nX\n3\n4\n5\n" && x.isEdited && y.textView.string == newText)
        #expect(h.window?.firstResponder === x.current.text, "the keys where it went: ⌘Z there undoes it")
        #expect(x.textView.undoManager?.undoActionName == "Copy Change")
        x.textView.undoManager?.undo()
        #expect(x.textView.string == oldText, "one Undo: the text as it was")
        try await until("worked out after the undo") { c.fresh && c.blocks.count == 3 }
        y.current.text.setSelectedRange(NSRange(location: 6, length: 0))   // the line after where "4" is missing
        c.caretMoved(y.current)
        #expect(c.old.current == 1 && ySide.arrow?.gap == true && ySide.arrow?.at == 4, "missing here: under the line before")
        into(y)   // "4" goes in
        #expect(y.textView.string == "1\nX\n3\n4\n5\nY\n")
        y.textView.undoManager?.undo()
        #expect(y.textView.string == newText)
        try await until("worked out") { c.fresh && c.blocks.count == 3 }
        y.current.text.setSelectedRange(NSRange(location: 8, length: 0))   // in "Y"
        c.caretMoved(y.current)
        into(x)   // added "Y" at the end
        #expect(x.textView.string == "1\n2\n3\n4\n5\nY\n")
        try await until("worked out anew, at once") { c.fresh && c.blocks.count == 2 }
        #expect(read(dir + "/a.txt") == oldText && read(dir + "/b.txt") == newText, "nothing saved")

        // Typed and copied at once: the result is of the text before the typing — nothing goes over.
        let before = x.textView.string
        y.current.text.setSelectedRange(NSRange(location: 2, length: 0))
        c.caretMoved(y.current)
        y.textView.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        into(x)
        #expect(x.textView.string == before, "a stale result: nothing copied")
        a.run("editor.compare.stop")

        #expect(AppDelegate.editorPickOff("editor.compare.copyLeft", in: h.window) == nil, "not comparing: the key goes on as it is")

        // A read-only copy is never written; its side has no arrow.
        let snap = copy("1\n2\n")
        h.compare(old: snap, new: y, snapshots: [snap])
        let s = try #require(h.comparison)
        try await worked(s)
        y.current.text.setSelectedRange(NSRange(location: 0, length: 0))
        s.caretMoved(y.current)
        #expect(s.old.current != nil && s.old.arrow == nil && s.new.arrow != nil)
        s.copy(into: s.old)
        #expect(snap.textView.string == "1\n2\n" && !snap.isEdited)
        s.copy(into: s.new)
        #expect(y.textView.string.hasPrefix("1\n2\n"), "from the copy into the document")
    }

    /// Every Compare of files goes through `diff`: `diffCommand` set — its program, as before; not set — the built-in,
    /// a file open in a tab as its document (no second copy), another as a read-only copy; a binary one, or `plain`
    /// (a question standing meanwhile) — `diff -u`. The draft banner's Compare makes no file of the draft.
    @Test func everyCompareOfFilesGoesOneWay() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        let a = app(dir)
        var ran: [(String, Bool)] = []
        let runDiff = AppDelegate.runDiff
        AppDelegate.runDiff = { command, _, external, _ in ran.append((command, external)) }
        defer {
            AppDelegate.runDiff = runDiff
            UserDefaults.standard.removeObject(forKey: "diffCommand")
            Editor.app = { NSApp.delegate as? AppDelegate }
            a.panels.forEach { $0.shutdown() }
            gone()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let h = fresh(dir + "/drafts")
        try put("a\n", dir + "/x.conf")
        try put("b\n", dir + "/y.conf")
        try Data([0, 1, 2, 0]).write(to: URL(fileURLWithPath: dir + "/bin"))
        let (x, y) = (AppDelegate.DiffSide(path: dir + "/x.conf"), AppDelegate.DiffSide(path: dir + "/y.conf"))
        UserDefaults.standard.set("tool %1 %2", forKey: "diffCommand")
        await a.diff(x, y, in: a.active)
        #expect(ran.count == 1 && ran[0].1 && ran[0].0.hasPrefix("tool ") && h.comparison == nil, "its program, as before")
        UserDefaults.standard.removeObject(forKey: "diffCommand")
        let doc = try await opened(dir + "/y.conf"), count = h.docs.count
        await a.diff(x, y, in: a.active)
        let c = try #require(h.comparison)
        #expect(c.new.view?.doc === doc && c.old.view?.doc.snapshot?.source?.path == x.path && h.docs.count == count + 1, "y's document, x's copy")
        #expect(ran.count == 1)
        await a.diff(x, AppDelegate.DiffSide(path: dir + "/bin"), in: a.active)
        #expect(ran.count == 2 && !ran[1].1 && ran[1].0.hasPrefix("diff -u"), "not text: diff -u, as before")
        await a.diff(x, y, in: a.active, plain: true)
        #expect(ran.count == 3 && ran[2].0.hasPrefix("diff -u"))

        // Edit in the copy: x's document in its place, the comparison on.
        let snap = try #require(c.old.view?.doc)
        snap.edit()
        try await until("edited") { snap.snapshot == nil && snap.cover == nil }
        #expect(snap.url?.path == x.path && snap.textView.isEditable && Editor.document(at: x.path) === snap && h.comparison === c && !c.paused)

        // The banner's Compare: the document against the file now; no copy of the draft on disk.
        h.stopComparing()
        doc.textView.insertText("mine\n", replacementRange: NSRange(location: 0, length: 0))
        let temps = Editor.comparisons.count
        doc.compareWithDisk()
        try await until("compared with the disk") { h.comparison != nil }
        let d = try #require(h.comparison)
        #expect(d.new.view?.doc === doc && d.old.view?.doc.name == "y.conf (on disk)" && d.old.view?.doc.snapshot?.source == nil)
        #expect(Editor.comparisons.count == temps, "no file of the draft")

        // A document closed while its other side is read isn't brought back as a tab.
        h.stopComparing()
        let gone = try await opened(dir + "/x.conf")
        let late = Task { await a.compare(.file(.init(path: dir + "/y.conf", now: true)), .doc(gone)) }
        gone.close()
        await late.value
        #expect(h.comparison == nil && !h.docs.contains { $0 === gone } && Editor.document(at: dir + "/x.conf") == nil)
        // One file on both sides: said, nothing opened — two spellings of its path too.
        await a.diff(y, y, in: a.active)
        #expect(h.comparison == nil && a.active.statusText.contains("same file"))
        let other = dir.hasPrefix("/private/") ? String(dir.dropFirst("/private".count)) : dir
        await a.diff(AppDelegate.DiffSide(path: other + "/y.conf"), y, in: a.active)
        #expect(h.comparison == nil, "\(other)")
        // Edit while a matching is under way, its file open in a tab: that tab's the side, and it's worked out.
        let xdoc = try await opened(dir + "/x.conf")
        let copyX = Editor.snapshot(("a\n", .utf8, false, false, false, nil, Editor.sha(Data())), file: "x.conf", title: "x.conf (copy)", place: "~",
                                    source: AppDelegate.DiffSide(path: dir + "/x.conf"))
        h.compare(old: copyX, new: doc, snapshots: [copyX])
        let r = try #require(h.comparison)
        copyX.edit()   // right away: the first matching is still running
        #expect(r.old.view?.doc === xdoc)
        try await until("worked out with the document") { r.words(for: r.new.view!) != "Comparing…" && r.new.view?.text.compared != nil }
        h.stopComparing()
        // A tool's file open in its own editor window is read as a copy, never pulled into the editor window.
        try put("{}\n", dir + "/t.json")
        let tool = try Editor.open(URL(fileURLWithPath: dir + "/t.json"), text: nil, beside: NSView()) { _ in }
        defer { tool.close() }
        await a.diff(x, AppDelegate.DiffSide(path: dir + "/t.json"), in: a.active)
        let t = try #require(h.comparison)
        #expect(t.new.view?.doc !== tool && t.new.view?.doc.snapshot != nil && tool.host.tabbed == false && !h.docs.contains { $0 === tool })
    }

    /// Same text, other bytes: said, not "No differences".
    @Test func sameTextOtherLineEndsIsSaid() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { gone(); try? FileManager.default.removeItem(atPath: dir) }
        let h = fresh(dir + "/drafts")
        try put("a\r\nb\r\n", dir + "/w.ini")
        try put("a\nb\n", dir + "/u.ini")
        let w = try await opened(dir + "/w.ini"), u = try await opened(dir + "/u.ini")
        h.compare(old: w, new: u)
        let c = try #require(h.comparison)
        try await worked(c)
        #expect(c.words(for: u.current) == "Same text — line endings differ (CRLF / LF)")
    }

    /// Show Changes in production's question, from an editor only: that save doesn't happen, the server's file now
    /// beside the text; the next ⌘S asks again. Compare in "changed on the server" does the same from an editor.
    @Test func showChangesWritesNothing() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        let a = app(dir)
        defer {
            Editor.app = { NSApp.delegate as? AppDelegate }
            (AppDelegate.answering, ServerLock.servers) = (nil, { [] })
            a.panels.forEach { $0.shutdown() }
            gone()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let h = fresh(dir + "/drafts") { a.remoteEditing($0, $1, $2, in: $3) }
        try FileManager.default.createDirectory(atPath: dir + "/srv", withIntermediateDirectories: true)
        let file = dir + "/srv/app.conf"
        try put("v1\n", file)
        let t = SFTPTarget.local(), cl = try SFTPClient(t)
        let state = AppDelegate.RemoteEdit(baseline: try cl.stat(file))
        cl.close()
        let copyURL = URL(fileURLWithPath: dir + "/copy/app.conf")
        try FileManager.default.createDirectory(atPath: dir + "/copy", withIntermediateDirectories: true)
        try put("v1\n", copyURL.path)
        let (onSaved, onClose) = h.onServer(t, file, state, dir + "/copy")
        Editor.open(copyURL, remote: SavedServer.title(t, file), server: (t, file, state), onSaved: onSaved, onClose: onClose)
        try await until("open") { Editor.editing(t, file) != nil }
        let e = try #require(Editor.editing(t, file))
        var prod = SavedServer(address: "localhost")!
        prod.prod = true
        ServerLock.servers = { [prod] }
        var asked: [[String]] = []
        AppDelegate.answering = { _, buttons, _ in asked.append(buttons); return 1 }   // Show Changes
        e.textView.insertText("v2\n", replacementRange: NSRange(location: e.storage.length, length: 0))
        try put("v1\nv2\n", copyURL.path)   // as its ⌘S wrote it here, before the upload asks
        #expect(await a.upload(copyURL, to: file, on: t, state) == false)
        #expect(asked == [["Save", "Show Changes", "Cancel"]] && read(file) == "v1\n" && e.isEdited, "nothing written")
        try await until("compared") { h.comparison != nil }
        let c = try #require(h.comparison)
        try await worked(c)
        #expect(c.new.view?.doc === e && c.old.view?.doc.snapshot != nil && c.old.view?.doc.textView.string == "v1\n" && c.blocks.count == 1)
        AppDelegate.answering = { _, buttons, _ in asked.append(buttons); return 0 }   // Save
        #expect(await a.upload(copyURL, to: file, on: t, state) && asked.count == 2 && read(file) == "v1\nv2\n", "asked again, then written")
        // Not from an editor (a Revert, another app's save): no Show Changes.
        asked = []
        let other = URL(fileURLWithPath: dir + "/other.conf")
        try put("v3\n", other.path)
        AppDelegate.answering = { _, buttons, _ in asked.append(buttons); return buttons.count - 1 }   // Cancel
        let c2 = try SFTPClient(t), s2 = AppDelegate.RemoteEdit(baseline: try c2.stat(file))
        c2.close()
        #expect(await a.upload(other, to: file, on: t, s2) == false && asked == [["Save", "Cancel"]])
    }
}

// Editor E6 PR 5: Send to Terminal (⌃↩) and Execute in Terminal (⌃⇧↩).
extension EditorWindowTests {
    /// Into a shell of the file's machine at its prompt only. Send types (no ^U, no ↩); Execute clears the line, types,
    /// ↩, and steps the caret to the next line with something on it; the document's tab from then on (no `cd` again),
    /// another document's first Execute `cd`s it; several lines only as a bracketed paste; a program holding the
    /// terminal gets nothing (a new tab). A server's Execute starts a new SSH tab that runs it as the server's user,
    /// asked first on production (↩ = Cancel) and in its production log; a server's Send never types into a tab whose
    /// shell hasn't asked for text.
    @Test func sendAndExecuteGoToTheFilesShell() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        let a = app(dir)
        a.commands = a.makeCommands()
        let panels = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        a.window.setContentSize(panels.frame.size)
        a.window.contentView!.addSubview(panels)
        a.terminal = EmbeddedTerminal(covering: panels)
        var typed: [(tab: UUID, text: String)] = []
        let typing = EmbeddedTerminal.typing, log = AuditLog.path
        EmbeddedTerminal.typing = { t, b in typed.append((t.id, String(decoding: b, as: UTF8.self))) }
        AuditLog.path = dir + "/audit.jsonl"
        defer {
            (EmbeddedTerminal.typing, AuditLog.path) = (typing, log)
            (AppDelegate.answering, ServerLock.servers) = (nil, { [] })
            AppDelegate.keyWindow = { NSApp.keyWindow }
            Editor.app = { NSApp.delegate as? AppDelegate }
            a.terminal.tabs.forEach { $0.view.process?.terminate() }
            a.panels.forEach { $0.shutdown() }
            gone()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let h = fresh(dir + "/drafts")
        AppDelegate.keyWindow = { h.window }
        for d in ["one", "two"] { try FileManager.default.createDirectory(atPath: dir + "/" + d, withIntermediateDirectories: true) }
        try put("echo one\n\n   \necho two\n", dir + "/one/run.sh")
        try put("echo b\n", dir + "/two/b.sh")
        let e = try await opened(dir + "/one/run.sh")
        func send(_ text: String, run: Bool, from owner: Editor, on t: SFTPTarget? = nil, in folder: String) async -> AppDelegate.ToTerminal {
            await a.toTerminal(text, run: run, on: t, folder: folder, path: folder + "/x", owner: owner, askOn: h.window)
        }

        // Send: a new shell in the file's folder; typed, nothing run.
        #expect(await send("echo one\n", run: false, from: e, in: dir + "/one") != .notSent(""))
        let shell = try #require(a.terminal.current)
        #expect(a.terminal.tabs.count == 1 && shell.host == nil && shell.shellCwd == dir + "/one")
        let paste = { (s: String) in shell.bracketed ? "\u{1b}[200~" + s + "\u{1b}[201~" : s }
        #expect(typed.map(\.text) == [paste("echo one")], "no ^U, no ↩")

        let menu = a.makeMenu()
        a.updateMenuKeys(menu)
        for id in ["editor.send", "editor.execute"] {
            #expect(a.validateMenuItem(try #require(menu.allItems.first { $0.representedObject as? String == id })), "\(id): in the editor window, comparing or not")
        }
        e.current.text.setSelectedRanges([NSValue(range: NSRange(location: 0, length: 2)), NSValue(range: NSRange(location: 5, length: 2))], affinity: .downstream, stillSelecting: false)
        a.editorToTerminal(run: true)
        #expect(typed.count == 1, "several selections: nothing sent")

        // Execute from the editor: the same tab (its own: no cd), ^U … ↩, the caret to the next line with something on it.
        e.current.text.setSelectedRange(NSRange(location: 2, length: 0))
        a.editorToTerminal(run: true)
        try await until("ran") { typed.count == 2 }
        #expect(typed[1].tab == shell.id && typed[1].text == "\u{15}" + paste("echo one") + "\r")
        try await until("stepped") { e.current.text.selectedRange().location == 14 }   // over the empty and the blank line

        // Another document: the current shell at its prompt, but elsewhere — its folder first.
        let b = try await opened(dir + "/two/b.sh")
        #expect(await send("echo b", run: true, from: b, in: dir + "/two") != .notSent(""))
        #expect(typed.count == 4 && typed[2].text == "\u{15} cd \(ShellContext.quote(dir + "/two"))\r" && typed[3].text.hasSuffix("echo b" + (shell.bracketed ? "\u{1b}[201~\r" : "\r")))

        // Send into a tab that isn't a document's: it doesn't become its own — its first Execute still `cd`s.
        try FileManager.default.createDirectory(atPath: dir + "/three", withIntermediateDirectories: true)
        try put("ls\n", dir + "/three/c.sh")
        let c3 = try await opened(dir + "/three/c.sh")
        #expect(await send("ls", run: false, from: c3, in: dir + "/three") != .notSent("") && typed.last?.tab == shell.id)
        #expect(await send("ls", run: true, from: c3, in: dir + "/three") != .notSent(""))
        #expect(typed[typed.count - 2].text == "\u{15} cd \(ShellContext.quote(dir + "/three"))\r", "in its folder, not where the Send found the shell")
        #expect(AppDelegate.ownTabs.object(forKey: c3) as UUID? == shell.id && AppDelegate.ownTabs.object(forKey: e) == nil && AppDelegate.ownTabs.object(forKey: b) == nil,
                "one tab, one document's: the others' folder is gone from it")

        // Several lines: only as one bracketed paste.
        shell.view.feed(text: "\u{1b}[?2004l")
        let k = typed.count
        #expect(await send("make\nls", run: true, from: e, in: dir + "/one") == .notSent(TerminalText.Refusal.severalLines.words) && typed.count == k)
        #expect(await send("a\u{1b}[201~b", run: false, from: e, in: dir + "/one") == .notSent(TerminalText.Refusal.control.words) && typed.count == k)
        shell.view.feed(text: "\u{1b}[?2004h")
        #expect(await send("make\nls", run: true, from: e, in: dir + "/one") != .notSent(""))
        #expect(typed.last?.text == "\u{15}\u{1b}[200~make\nls\u{1b}[201~\r")


        // A program holds the terminal: a new tab, never into it.
        shell.view.send(txt: "sleep 3\r")   // to the shell itself, not the recorder
        try await until("sleeping") { !shell.isAtPrompt }
        let n = typed.count
        #expect(await send("echo again", run: true, from: e, in: dir + "/one") != .notSent(""))
        #expect(a.terminal.tabs.count == 2 && typed.count == n + 1 && typed.last?.tab != shell.id && typed.last?.tab == a.terminal.current?.id)

        // The keys: ⌃↩ / ⌃⇧↩ only while the editor window's text has them; the panels' ⌃↩ stays theirs.
        #expect(h.window?.makeFirstResponder(try #require(h.active).current.text) == true)   // the shown tab's text
        #expect(AppDelegate.editorPickOff("cmdline.insert", in: h.window) == "editor.send" && AppDelegate.editorPickOff("cmdline.insertPaths", in: h.window) == "editor.execute")
        h.window?.makeFirstResponder(nil)
        #expect(AppDelegate.editorPickOff("cmdline.insert", in: h.window) == nil, "the find bar's ⌃↩ is its own")
        #expect(AppDelegate.editorPickOff("cmdline.insert", in: a.window) == nil && AppDelegate.editorPickOff("term.pane.left", in: h.window) == "term.pane.left")
        #expect(Editor.keys(of: h.window)?.contains { $0.title == "Execute in Terminal" && $0.key == "⌃⇧↩" } == true)

        // A server: production asks (↩ = Cancel: nothing), Run starts a new SSH tab that runs it, as the user, logged.
        let t = SFTPTarget(host: "pr5@dfm-pr5.invalid")
        var prod = SavedServer(address: "pr5@dfm-pr5.invalid")!
        prod.prod = true
        ServerLock.servers = { [prod] }
        var asked = 0
        AppDelegate.answering = { _, buttons, safe in asked += 1; return safe ?? buttons.count - 1 }   // ↩
        let tabs = a.terminal.tabs.count
        #expect(await send("systemctl reload app", run: true, from: e, on: t.asRoot(), in: "/srv") == .cancelled)
        #expect(asked == 1 && a.terminal.tabs.count == tabs)
        AppDelegate.answering = { _, _, _ in 0 }   // ⌘↩ Run
        #expect(await send("systemctl reload app", run: true, from: e, on: t.asRoot(), in: "/srv") != .notSent(""))
        let ssh = try #require(a.terminal.current)
        #expect(ssh.kind == .ssh(t) && ssh.command == TerminalText.command("systemctl reload app", in: "/srv"), "as the user, never root")
        Config.flush()
        #expect(read(dir + "/audit.jsonl")?.contains("\"command\":\"systemctl reload app\"") == true)
        #expect(typed.last?.tab != ssh.id, "nothing typed into it")

        // Send to a server whose shell never asks for text (ssh can't connect): nothing typed.
        ServerLock.servers = { [] }
        let before = typed.count
        if case .notSent = await send("ls", run: false, from: b, on: t, in: "/srv") {} else { Issue.record("typed into a tab that never asked") }
        #expect(typed.count == before)
    }
}

// Editor E6 PR 5: Quick Open (⌘P in the editor window).
extension EditorWindowTests {
    /// ⌘P in the editor window: its tabs, then Recent, then the files under the document's repository — Picker at once,
    /// the folder after; each file once; not hidden, .git, node_modules, a package's insides, nor through a link out of
    /// it; the walk stops at its limit; ↩ on an open file is its tab (no second one), a Recent server file opens as F4's.
    /// Recent: written 0600, newest first, never a locked server's; a damaged file reads as an empty list.
    @Test func quickOpenListsTabsRecentAndTheRepository() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        let a = app(dir)
        a.commands = a.makeCommands()
        let menu = a.makeMenu()
        let limit = AppDelegate.quickOpenLimit
        defer {
            AppDelegate.quickOpenLimit = limit
            (AppDelegate.answering, ServerLock.servers) = (nil, { [] })
            Picker.dismiss()
            AppDelegate.keyWindow = { NSApp.keyWindow }
            Editor.app = { NSApp.delegate as? AppDelegate }
            a.panels.forEach { $0.shutdown() }
            gone()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let h = fresh(dir + "/drafts") { a.remoteEditing($0, $1, $2, in: $3) }
        let repo = dir + "/repo", fm = FileManager.default
        for d in ["/.git", "/src/api", "/node_modules/x", "/Tool.app/Contents", "/.cache"] { try fm.createDirectory(atPath: repo + d, withIntermediateDirectories: true) }
        try fm.createDirectory(atPath: dir + "/outside", withIntermediateDirectories: true)
        for f in ["/README.md", "/src/app.ts", "/src/api/server.ts", "/node_modules/x/index.js", "/Tool.app/Contents/Info.plist", "/.cache/c", "/.env"] { try put("x\n", repo + f) }
        try put("x\n", dir + "/outside/secret.txt")
        try fm.createSymbolicLink(atPath: repo + "/linked", withDestinationPath: dir + "/outside")
        try put("x\n", dir + "/notes.txt")
        a.editorRecent = RecentFiles()
        let e = try await opened(repo + "/src/app.ts")
        #expect(a.editorRecent.entries.first == RecentFiles.Entry(path: repo + "/src/app.ts"), "F4 puts it first in Recent")
        a.editorRecent.visit(RecentFiles.Entry(path: repo + "/README.md"))   // also in the repository: once, as Recent
        a.editorRecent.visit(RecentFiles.Entry(path: dir + "/notes.txt"))
        AppDelegate.keyWindow = { h.window }
        a.updateMenuKeys(menu)
        let jump = try #require(menu.allItems.first { $0.representedObject as? String == "go.jump" })
        #expect(a.validateMenuItem(jump) && jump.title == "Quick Open…" && jump.keyEquivalent == "p")
        a.run("go.jump")
        let p = try #require(Picker.current)
        try await until("the folder came in") { p.groups.count == 3 }
        #expect(p.groups.prefix(2) == ["Tabs", "Recent"] && p.rows.prefix(3).map(\.title) == ["app.ts", "notes.txt", "README.md"], "tabs, then Recent; the open file once")
        #expect(p.groups[2] == "In " + (repo as NSString).abbreviatingWithTildeInPath, "the repository's root, not the file's folder")
        #expect(Set(p.rows.filter { $0.group.hasPrefix("In ") }.map(\.title)) == ["server.ts"], "\(p.rows.map(\.title))")
        func type(_ q: String) { p.field.stringValue = q; p.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)) }
        type("srvts")
        try await until("ranked off the main thread") { p.rows.first?.title == "server.ts" }
        type("app")
        try await until("ranked") { p.rows.first?.title == "app.ts" }
        let tab = try #require(p.rows.first)
        #expect(tab.group == "Tabs")
        Picker.dismiss()
        let docs = h.docs.count
        tab.run()
        #expect(h.active === e && h.docs.count == docs, "its tab, no second one")

        // A Recent server file: as F4 opens it.
        let t = SFTPTarget.local()
        try put("srv\n", dir + "/served.conf")
        a.editorRecent.visit(RecentFiles.Entry(path: dir + "/served.conf", server: t))
        a.run("go.jump")
        let q = try #require(Picker.current)
        try await until("listed") { q.rows.contains { $0.title == "served.conf" } }
        let served = try #require(q.rows.first { $0.title == "served.conf" })
        Picker.dismiss()
        served.run()
        try await until("downloaded and open") { Editor.editing(t, dir + "/served.conf") != nil }
        #expect(a.editorRecent.entries.first == RecentFiles.Entry(path: dir + "/served.conf", server: t))
        Config.flush()
        let attrs = try fm.attributesOfItem(atPath: Config.path("editor-recent.json"))
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        // A locked server's file isn't remembered.
        var locked = SavedServer(address: "me@dfm-pr5-locked.invalid")!
        locked.locked = true
        ServerLock.servers = { [locked] }
        let before = a.editorRecent
        let server = e.server
        e.server = (locked.target, "/etc/x", AppDelegate.RemoteEdit(baseline: .nothing))
        a.rememberRecent(e)
        e.server = server
        #expect(a.editorRecent == before)

        // The walk's limit: Picker says it's the first ones.
        AppDelegate.quickOpenLimit = (files: 3, seconds: 5)
        for i in 0..<10 { try put("x\n", repo + "/src/f\(i).txt") }
        a.run("go.jump")
        try await until("listed") { Picker.current?.groups.isEmpty == false }
        try await Task.sleep(for: .milliseconds(300))
        #expect(Picker.current?.groups == ["Tabs", "Recent"], "a server's file shown: no folder walked")
        Picker.dismiss()
        h.select(e)
        a.run("go.jump")
        let r = try #require(Picker.current)
        try await until("the first files") { r.groups.count == 3 }
        #expect(r.rows.filter { $0.group.hasPrefix("In ") }.count <= 3)

        // A damaged list: empty, and the file stays as it was.
        try put("{ not json", dir + "/editor-recent.json")
        let damaged = Config.loadKeeping("editor-recent.json", as: RecentFiles.self, in: dir)
        #expect(damaged.value == nil && damaged.problem != nil && read(dir + "/editor-recent.json") == "{ not json")
    }
}
