import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Editor E1: Untitled documents — New Editor Document (⌘N) from anywhere, nothing on disk until Save picks where.

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-untitled-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor private func waitUntil(_ what: String, _ cond: () -> Bool) async throws {
    for _ in 0..<250 where !cond() { try await Task.sleep(for: .milliseconds(20)) }
    #expect(cond(), "\(what)")
}

/// The finalNewline setting is global: these take turns.
@Suite(.serialized) @MainActor struct UntitledTests {
    /// ⌘N makes “Untitled N”, N one past the highest open; UTF-8, LF, the final newline as the setting says (nothing to
    /// judge by otherwise), the text in focus, no file and no saved window state. An empty one closes without asking; one
    /// with text asks Save… / Don't Save and is named at quit.
    @Test func anUntitledIsNumberedAndAsksOnlyWithText() async throws {
        _ = NSApplication.shared
        let real = Editor.finalNewlineSetting
        defer { Editor.finalNewlineSetting = real }
        Editor.finalNewlineSetting = { nil }
        let a = Editor.untitled(), b = Editor.untitled()
        defer { a.close() }
        let n = try #require(Int(a.name.dropFirst("Untitled ".count)))
        #expect(a.window?.title == "Untitled \(n)" && b.window?.title == "Untitled \(n + 1)")
        #expect(a.url == nil && a.window?.representedURL == nil && a.window?.isRestorable == false && !a.finalNewline)
        #expect(a.window?.firstResponder === a.textView && a.window?.statusText.contains("UTF-8") == true)
        #expect(a.windowShouldClose(a.window!), "empty: no question")

        b.textView.insertText("todo\n", replacementRange: NSRange(location: 0, length: 0))
        #expect(b.window?.isDocumentEdited == true && Editor.unsaved.contains(b.name))
        var closed = false
        b.onClose = { closed = true }
        #expect(!b.windowShouldClose(b.window!))
        let sheet = try #require(b.window?.attachedSheet)
        let buttons = (sheet.contentView.map(Self.buttons) ?? []).map(\.title)
        #expect(buttons.contains("Save…") && buttons.contains("Don't Save"), "\(buttons)")
        b.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)   // Don't Save
        try await waitUntil("closed") { closed }
        #expect(!Editor.unsaved.contains(b.name))

        Editor.finalNewlineSetting = { true }
        let c = Editor.untitled()
        defer { c.close() }
        #expect(c.finalNewline && c.window?.title == "Untitled \(n + 1)", "one past the highest open now")
    }

    private static func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }

    /// An Untitled's Save As writes a new file with the umask's mode and from then edits it — its name, its colors;
    /// over an existing file it keeps that file's mode. The next ⌘S writes there.
    @Test func anUntitledSavesAsAFile() async throws {
        _ = NSApplication.shared
        let real = Editor.finalNewlineSetting
        defer { Editor.finalNewlineSetting = real }
        Editor.finalNewlineSetting = { nil }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let u = Editor.untitled()
        defer { u.close() }
        u.textView.insertText("#!/bin/sh\necho hi", replacementRange: NSRange(location: 0, length: 0))
        let dest = URL(fileURLWithPath: dir + "/hi.sh")
        #expect(await u.saveAs(dest))
        var st = stat()
        stat(dest.path, &st)
        let mask = umask(0)
        umask(mask)
        #expect(st.st_mode & 0o777 == 0o666 & ~mask)
        #expect(FileManager.default.contents(atPath: dest.path) == Data("#!/bin/sh\necho hi".utf8))
        #expect(u.url == dest && u.window?.title == "hi.sh" && u.window?.representedURL == dest && u.window?.isDocumentEdited == false)
        u.textView.insertText("\n", replacementRange: NSRange(location: (u.textView.string as NSString).length, length: 0))
        #expect(await u.save())
        #expect(FileManager.default.contents(atPath: dest.path) == Data("#!/bin/sh\necho hi\n".utf8))

        let other = Editor.untitled()
        defer { other.close() }
        #expect(other.name == "Untitled 1", "the one saved as hi.sh is a file now: it doesn't count")
        other.textView.insertText("notes", replacementRange: NSRange(location: 0, length: 0))
        FileManager.default.createFile(atPath: dir + "/notes.txt", contents: Data("old".utf8), attributes: [.posixPermissions: 0o640])
        #expect(await other.saveAs(URL(fileURLWithPath: dir + "/notes.txt")))
        stat(dir + "/notes.txt", &st)
        #expect(st.st_mode & 0o777 == 0o640 && FileManager.default.contents(atPath: dir + "/notes.txt") == Data("notes".utf8))
    }
}

/// New Editor Document is the app's own (⌘N in File): it works over an editor, a viewer, Tools, the terminal, a list or a
/// parked server tab, and keeps its key while another window is key. An Untitled's Save starts in the active panel's
/// folder on this Mac.
@MainActor @Test func newEditorDocumentWorksFromAnywhere() throws {
    _ = NSApplication.shared
    let app = AppDelegate()
    app.commands = app.makeCommands()
    let menu = app.makeMenu()
    let item = try #require(menu.allItems.first { $0.representedObject as? String == "editor.new" })
    #expect(item.title == "New Editor Document" && app.commands.first { $0.id == "editor.new" }?.menu == "File")
    #expect(AppDelegate.appWide.contains("editor.new") && AppDelegate.runsInList("editor.new") && AppDelegate.runsParked("editor.new"))
    #expect(app.commands.filter { $0.keys.contains(Shortcut("cmd+n")!) }.map(\.id) == ["editor.new"])
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)), panels = NSView(frame: parent.bounds)
    parent.addSubview(panels)
    app.terminal = EmbeddedTerminal(covering: panels)
    app.window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)   // not key: say an editor is
    app.updateMenuKeys(menu)
    #expect(item.keyEquivalent == "n" && item.keyEquivalentModifierMask == .command)
    #expect(menu.allItems.first { $0.representedObject as? String == "file.view" }?.keyEquivalent == "", "the panels' own are off there")

    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let p = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    p.loadViewIfNeeded()
    defer { p.shutdown() }
    #expect(p.localFolder?.path == dir)
}
