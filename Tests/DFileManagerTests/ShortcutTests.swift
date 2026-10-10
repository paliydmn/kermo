import AppKit
import Testing
@testable import DFileManager

@Test func shortcutSpecsParse() {
    let s = Shortcut("cmd+shift+.")!
    #expect(s.flags == [.command, .shift] && s.keyCode == 47)
    #expect(s.spec == "shift+cmd+." && Shortcut(s.spec) == s)
    #expect(s.display == "⇧⌘.")
    #expect(Shortcut("CMD+Shift+.") == s)
    #expect(Shortcut("alt+5") == Shortcut("opt+5"))
    #expect(Shortcut("ctrl+opt+shift+cmd+x")!.spec == "ctrl+opt+shift+cmd+x")
    #expect(Shortcut("cmd+opt+ctrl+shift+x")!.display == "⌃⌥⇧⌘X")
    #expect(Shortcut("f5")!.menuKey == String(Character(UnicodeScalar(NSF5FunctionKey)!)))
    #expect(Shortcut("return")!.menuKey == "\r" && Shortcut("kpstar")!.display == "*" && Shortcut("backspace")!.display == "⌫")
    #expect(Shortcut("f12") != nil && Shortcut("f13") == nil)
    for bad in ["", "cmd+", "super+a", "cmd+nokey", "a+b", "shift"] { #expect(Shortcut(bad) == nil, "\(bad)") }
    #expect(Shortcut("shift") == nil)   // a lone modifier isn't a key
}

@Test func shortcutEqualityIgnoresHowItWasSpelled() {
    let a = Shortcut("cmd+a")!, b = Shortcut("CMD+A")!
    #expect(a == b && a.hashValue == b.hashValue)
    #expect(Set([a, b, Shortcut("cmd+b")!]).count == 2)
}

@Test @MainActor func defaultKeymapIsConsistent() {
    let commands = AppDelegate().makeCommands()
    #expect(commands.count > 50)
    #expect(Set(commands.map(\.id)).count == commands.count, "command ids must be unique")
    var owner: [Shortcut: String] = [:]
    for c in commands {
        #expect(!c.title.isEmpty, "\(c.id)")
        for k in c.keys {
            if let other = owner[k] { Issue.record("\(c.id) and \(other) both use \(k.spec)") }
            owner[k] = c.id
        }
    }
    func has(_ id: String, _ specs: String...) -> Bool {
        commands.contains { c in c.id == id && specs.allSatisfy { c.keys.contains(Shortcut($0)!) } }
    }
    #expect(has("app.palette", "cmd+shift+p", "f9", "opt+9"))
    #expect(has("go.tree", "f10", "opt+0", "opt+f10"))
    #expect(commands.first { $0.id == "file.compress" }!.aliases.contains("zip"))
}

@Test func undoKeepsTrashLogInStep() {
    let t = NSHomeDirectory() + "/.Trash/a.txt"
    let log = [t: "/x/a.txt", "/other": "/y"]
    #expect(AppDelegate.trashLog(log, after: [(from: t, to: "/x/a.txt")]) == ["/other": "/y"])   // undo of Move to Trash
    #expect(AppDelegate.trashLog(["/other": "/y"], after: [(from: "/x/a.txt", to: t)]) == log)  // redo, or undo of Put Back
    #expect(AppDelegate.trashLog(log, after: [(from: "/x/b", to: "/x/c")]) == log)              // plain rename
}
