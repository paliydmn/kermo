import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

/// An editor of its own (not the shared window) on `text` in a file named `name`.
@MainActor private func editor(_ name: String, _ text: String) throws -> (Editor, String) {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-comfort-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: dir + "/" + name))
    return (try Editor(URL(fileURLWithPath: dir + "/" + name)), dir)
}

@MainActor private func key(_ e: Editor, _ s: Selector) { e.textView.doCommand(by: s) }   // as a key does: the delegate first

/// Tab puts in the file's own indent (YAML never a tab, a Makefile its tab), ↩ keeps the line's indent, a selection of
/// lines takes Tab and ⇧Tab whole, and each is one Undo.
@MainActor @Test func tabAndReturnFollowTheFilesIndent() throws {
    _ = NSApplication.shared
    let (y, dir) = try editor("app.yml", "a:\n  b: 1\n")
    defer { y.close(); try? FileManager.default.removeItem(atPath: dir) }
    y.textView.setSelectedRange(NSRange(location: 9, length: 0))   // end of "  b: 1"
    key(y, #selector(NSResponder.insertNewline(_:)))
    key(y, #selector(NSResponder.insertTab(_:)))
    #expect(y.textView.string == "a:\n  b: 1\n    \n" && y.indent == .spaces(2))
    y.pickIndent(.tabs)
    #expect(y.indent == .spaces(2), "YAML takes no tab")

    let (m, dir2) = try editor("Makefile", "all:\n")
    defer { m.close(); try? FileManager.default.removeItem(atPath: dir2) }
    m.textView.setSelectedRange(NSRange(location: 4, length: 0))
    key(m, #selector(NSResponder.insertNewline(_:)))
    key(m, #selector(NSResponder.insertTab(_:)))
    #expect(m.textView.string == "all:\n\t\n")

    let (c, dir3) = try editor("site.conf", "server {\n    listen 80;\n}\nx\n")
    defer { c.close(); try? FileManager.default.removeItem(atPath: dir3) }
    c.textView.setSelectedRange(NSRange(location: 8, length: 0))   // after "{"
    key(c, #selector(NSResponder.insertNewline(_:)))
    #expect(c.textView.string == "server {\n    \n    listen 80;\n}\nx\n" && c.textView.selectedRange().location == 13)
    c.textView.undoManager?.undo()
    #expect(c.textView.string == "server {\n    listen 80;\n}\nx\n")
    c.textView.setSelectedRange(NSRange(location: 0, length: 25))   // "server {" … "}"
    key(c, #selector(NSResponder.insertTab(_:)))
    #expect(c.textView.string == "    server {\n        listen 80;\n    }\nx\n")
    key(c, #selector(NSResponder.insertBacktab(_:)))
    key(c, #selector(NSResponder.insertBacktab(_:)))
    #expect(c.textView.string == "server {\nlisten 80;\n}\nx\n")
    c.textView.undoManager?.undo()
    #expect(c.textView.string == "server {\n    listen 80;\n}\nx\n", "one ⇧Tab, one Undo")
}

/// ⌥↓ / ⇧⌥↓ / ⇧⌘K / ⌘/ change the text as one Undo each, mark it changed, and say where the caret is.
@MainActor @Test func lineCommandsAreOneUndoEachAndTheCaretIsSaid() throws {
    _ = NSApplication.shared
    let (e, dir) = try editor("hosts.conf", "one\n\ttwo\nthree\n")
    defer { e.close(); try? FileManager.default.removeItem(atPath: dir) }
    e.textView.setSelectedRange(NSRange(location: 1, length: 0))
    e.moveLines(up: false)
    #expect(e.textView.string == "\ttwo\none\nthree\n" && e.isEdited && e.textView.selectedRange().location == 6)
    e.textView.undoManager?.undo()
    #expect(e.textView.string == "one\n\ttwo\nthree\n")
    e.textView.setSelectedRange(NSRange(location: 1, length: 0))
    e.duplicateLines()
    #expect(e.textView.string == "one\none\n\ttwo\nthree\n" && e.textView.selectedRange().location == 5)
    e.deleteLines()
    #expect(e.textView.string == "one\n\ttwo\nthree\n" && e.textView.selectedRange().location == 4)
    e.toggleComment()
    #expect(e.textView.string == "one\n\t# two\nthree\n", "at the line's indent")
    e.toggleComment()
    #expect(e.textView.string == "one\n\ttwo\nthree\n")

    e.go(to: "2:3")
    #expect(e.textView.selectedRange() == NSRange(location: 6, length: 0))
    e.sayPosition()
    #expect(e.frame.position == "Ln 2, Col 6 · Tabs", "a tab is four columns")
    e.textView.setSelectedRange(NSRange(location: 2, length: 8))
    e.sayPosition()
    #expect(e.frame.position == "Ln 1, Col 3 · 3 lines, 8 selected · Tabs")
    e.go(to: "99")
    #expect(e.textView.selectedRange().location == 15, "past the last line: the last one (the empty line after the last newline)")

    let (j, dir2) = try editor("a.json", "{\"a\": 1}\n")
    defer { j.close(); try? FileManager.default.removeItem(atPath: dir2) }
    j.toggleComment()
    #expect(j.textView.string == "{\"a\": 1}\n" && !j.isEdited, "JSON has no comments")
}

/// ⌘= / ⌘− size the editors' text (kept), ⌥Z wraps or not, Show Invisibles marks tabs: a new editor opens so.
@MainActor @Test func textSizeWrapAndInvisiblesAreKept() throws {
    _ = NSApplication.shared
    let keys = ["editorFontSize", "editorWrap", "editorInvisibles"], was = keys.map { UserDefaults.standard.object(forKey: $0) }
    defer { for (k, v) in zip(keys, was) { UserDefaults.standard.set(v, forKey: k) } }
    UserDefaults.standard.set(35.0, forKey: "editorFontSize")
    Editor.zoom(by: 2)
    #expect(Editor.fontSize == 36, "36 at most")
    UserDefaults.standard.set(12.0, forKey: "editorFontSize")
    Editor.zoom(by: 2)
    UserDefaults.standard.set(true, forKey: "editorWrap")
    Editor.toggleWrap()
    UserDefaults.standard.set(false, forKey: "editorInvisibles")
    Editor.toggleInvisibles()
    let (a, dir) = try editor("a.sh", "\techo\n")
    defer { a.close(); try? FileManager.default.removeItem(atPath: dir) }
    #expect(a.textView.font?.pointSize == 14 && !Editor.wraps && Editor.invisibles)
    #expect(a.textView.textContainer?.widthTracksTextView == false && a.frame.scroll.hasHorizontalScroller)
    #expect((a.textView as? EditorTextView)?.tabMarks == true && a.textView.layoutManager?.showsInvisibleCharacters == true)
}

/// A bracket by the caret is lit with its pair.
@MainActor @Test func aBracketByTheCaretLightsItsPair() throws {
    _ = NSApplication.shared
    let (e, dir) = try editor("x.js", "f(a[1]);\n")
    defer { e.close(); try? FileManager.default.removeItem(atPath: dir) }
    e.textView.setSelectedRange(NSRange(location: 2, length: 0))   // after "("
    e.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
    #expect((e.textView as? EditorTextView)?.brackets == [NSRange(location: 1, length: 1), NSRange(location: 6, length: 1)])
    e.textView.setSelectedRange(NSRange(location: 8, length: 0))
    e.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
    #expect((e.textView as? EditorTextView)?.brackets == [])
}
