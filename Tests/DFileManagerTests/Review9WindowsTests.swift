import AppKit
import Testing
@testable import DFileManager

/// U2 (task 9): a Window menu brings the panels back from a viewer or editor — ⌘0, a key no command uses.
@MainActor @Test func windowMenuReturnsToTheMainWindow() throws {
    _ = NSApplication.shared
    let app = AppDelegate()
    let menu = app.makeMenu()
    let window = try #require(menu.items.compactMap(\.submenu).first { $0.title == "Window" })
    // By title: `NSApp.windowsMenu` is global, and a test running beside this one may have made its own menu (D-108).
    #expect(NSApp.windowsMenu?.title == window.title && NSApp.windowsMenu?.items.contains { $0.title == "Main Window" } == true, "AppKit lists the open windows there")
    let main = try #require(window.items.first { $0.title == "Main Window" })
    #expect(main.action == #selector(AppDelegate.showMainWindow(_:)))
    #expect(main.keyEquivalent == "0" && main.keyEquivalentModifierMask == .command)
    #expect(app.validateMenuItem(main), "enabled while another window is key")
    #expect(!app.makeCommands().contains { $0.keys.contains(Shortcut("cmd+0")!) }, "⌘0 is free in the default keymap")
    #expect(!menu.items.compactMap(\.submenu).flatMap(\.items).contains { $0 !== main && $0.keyEquivalent == "0" && $0.keyEquivalentModifierMask == .command })
}

/// U3 (task 9): ⌘W closes a viewer / editor window instead of a tab hidden behind it; over the main window
/// (itself, a sheet, a picker) it still closes a tab. Closing goes through the editor's unsaved-changes question.
@MainActor @Test func commandWClosesTheAuxiliaryWindowThatIsKey() throws {
    _ = NSApplication.shared
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-review9-windows-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try Data("text\n".utf8).write(to: URL(fileURLWithPath: dir + "/doc.txt"))
    func window(_ style: NSWindow.StyleMask) -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: style, backing: .buffered, defer: true)
    }
    let main = window([.titled, .closable, .miniaturizable, .resizable])
    let e = try Editor(URL(fileURLWithPath: dir + "/doc.txt"))
    let editor = try #require(e.window)
    defer { e.close() }

    #expect(AppDelegate.windowToClose(key: editor, main: main) === editor)
    #expect(AppDelegate.windowToClose(key: main, main: main) == nil, "the main window: Close Tab")
    #expect(AppDelegate.windowToClose(key: nil, main: main) == nil)
    let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
    #expect(AppDelegate.windowToClose(key: panel, main: main) == nil, "a picker or sheet over the panels")
    #expect(AppDelegate.windowToClose(key: window([.titled, .resizable]), main: main) == nil, "no close button (Multi-Rename)")

    // Unsaved changes: the editor asks first, the window stays.
    e.textView.string = "changed\n"
    e.textView.didChangeText()
    editor.performClose(nil)
    #expect(editor.isDocumentEdited && editor.attachedSheet != nil, "Save / Cancel / Don't Save")
}
