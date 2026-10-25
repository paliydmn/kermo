import AppKit
import Testing
@testable import DFileManager

private func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = [], window: Int = 0) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: window, context: nil,
                     characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
}

/// P14 (task 9): shortcuts resolve by physical key. On a Ukrainian layout the E key types "у", and ⌘E must still be ⌘E.
@Test func keymapResolvesByPhysicalKeyOnACyrillicLayout() {
    #expect(Shortcut(event: key(14, "у", .command)) == Shortcut("cmd+e"))
    #expect(Shortcut(event: key(14, "у", [.command, .capsLock])) == Shortcut("cmd+e"), "Caps Lock isn't a modifier")
    #expect(Shortcut(event: key(14, "у", .command)) != Shortcut("cmd+shift+e"))
}

/// P14: the ISO § key (top left, key code 10) does whatever the ANSI ` key does, in both of the positions ISO keyboards report it.
@Test func isoSectionKeyActsAsBacktick() {
    #expect(Shortcut(event: key(10, "§")) == Shortcut("`"))
    #expect(Shortcut(event: key(10, "§", .command)) == Shortcut("cmd+`"))
    #expect(Shortcut(event: key(10, "§")).name == "`" && Shortcut(event: key(10, "§")).display == "`")
    #expect(Shortcut(event: key(50, "`")) == Shortcut("`"))
}

/// P14: the picker's ⌘E (edit the highlighted row) checked the typed character, so it never fired on a Cyrillic layout.
@MainActor @Test func pickerCommandEIsAPhysicalKey() async {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    var ran: [String] = []
    Picker.show(over: window, placeholder: "", items: [Picker.Item(title: "mine", actions: [.init(key: Shortcut("cmd+e")!, label: "Edit") { ran.append("edit") }]) { ran.append("run") }])
    let panel = Picker.current!.panel
    #expect(panel.performKeyEquivalent(with: key(14, "у", .command, window: panel.windowNumber)) && Picker.current == nil, "edits and closes")
    await Task.yield()
    for _ in 0..<50 where ran.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(ran == ["edit"])
}

/// P12 (task 9): no default binding sits on a shortcut macOS takes first (⌘⌥D toggles Dock hiding, so Diff never fired),
/// and ⌘M is left to the Window menu's Minimize, as in every Mac app.
@MainActor @Test func defaultKeymapAvoidsSystemShortcuts() throws {
    _ = NSApplication.shared
    let app = AppDelegate()
    let commands = app.makeCommands()
    let reserved = ["cmd+opt+d", "cmd+m", "cmd+h", "cmd+opt+h", "cmd+q", "cmd+space", "cmd+opt+space", "cmd+tab", "cmd+shift+3", "cmd+shift+4",
                    "cmd+shift+5", "ctrl+cmd+q", "cmd+opt+esc", "ctrl+cmd+space", "ctrl+space", "ctrl+opt+space", "ctrl+up", "ctrl+down",
                    "ctrl+left", "ctrl+right", "cmd+`"]
    for spec in reserved {
        let k = Shortcut(spec)!
        if let c = commands.first(where: { $0.keys.contains(k) }) { Issue.record("\(c.id) is on \(k.display), which macOS takes first") }
        #expect(k.takenByMacOS != nil, "\(spec): a keymap.json written by Edit Keymap… before the move is warned about at launch")
    }
    for c in commands { for k in c.keys { #expect(k.takenByMacOS == nil, "\(c.id) on \(k.display)") } }
    #expect(commands.first { $0.id == "file.diff" }!.keys == [Shortcut("cmd+shift+d")!])
    let menu = app.makeMenu()
    let minimize = try #require(menu.items.compactMap(\.submenu).first { $0.title == "Window" }?.items.first { $0.title == "Minimize" })
    #expect(minimize.keyEquivalent == "m" && minimize.keyEquivalentModifierMask == .command)
    #expect(minimize.action == #selector(NSWindow.performMiniaturize(_:)))
}
