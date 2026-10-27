import AppKit
import Testing
@testable import DFileManager

// Review 1, phase 6: Settings ▸ Keys — press a key to give it to a command; clashes as Reload Config words them.

/// keymap.json keeps only what you changed: a command back on its own keys has no entry.
@MainActor @Test func keymapKeepsOnlyChangedCommands() {
    let home = [Shortcut("cmd+shift+h")!], mine = [Shortcut("ctrl+opt+h")!]
    var f = AppDelegate.keymap(["file.copy": ["f5"]], setting: "go.home", to: mine, defaults: home)
    #expect(f == ["file.copy": ["f5"], "go.home": ["ctrl+opt+h"]])
    f = AppDelegate.keymap(f, setting: "go.home", to: home, defaults: home)
    #expect(f == ["file.copy": ["f5"]])
    #expect(AppDelegate.keymap([:], setting: "go.home", to: [], defaults: home) == ["go.home": []], "no keys at all is a change")
}

/// One way to put keymap.json on the registry, Reload Config's and the Keys tab's: an entry's key leaves the command
/// it was a default of.
@MainActor @Test func bindGivesAnEntrysKeyAway() {
    let b = AppDelegate.bind(AppDelegate().makeCommands(), ["go.home": ["cmd+d"], "nope": ["f1"], "file.copy": ["f5", "cmd+zz"]])
    #expect(b.commands.first { $0.id == "go.home" }?.keys == [Shortcut("cmd+d")!])
    #expect(b.commands.first { $0.id == "go.bookmark" }?.keys == [], "⌘D went to Home")
    #expect(b.keymap[Shortcut("cmd+d")!]?.id == "go.home")
    #expect(b.problems == ["keymap.json: file.copy: bad key “cmd+zz”", "keymap.json: unknown command “nope”"])
}

/// keymap.json as written.
@MainActor private func file() -> [String: [String]] { (try? AppDelegate.readKeymap()) ?? ["?": []] }

extension ServerLockTests {
    /// The Keys tab in a config folder of its own (`AppDelegate.keymapDir`); keymap.json as written.
    private func keys(_ body: (AppDelegate, KeysPane) async throws -> Void) async throws {
        _ = NSApplication.shared
        let dir = NSTemporaryDirectory() + "kermo-keys-" + UUID().uuidString, was = AppDelegate.keymapDir
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        AppDelegate.keymapDir = dir
        defer { AppDelegate.keymapDir = was; try? FileManager.default.removeItem(atPath: dir) }
        let app = AppDelegate()
        app.applyConfig(reportProblems: false)
        let pane = KeysPane(app: app)
        try await body(app, pane)
    }

    @Test func aKeyPressedIsTheCommandsAndWritten() async throws {
        try await keys { app, pane in
            pane.record("go.home", replacing: Shortcut("cmd+shift+h"))
            #expect(pane.recording?.id == "go.home")
            pane.pressed(Shortcut("ctrl+opt+h")!)
            #expect(pane.recording == nil && file() == ["go.home": ["ctrl+opt+h"]])
            #expect(app.commands.first { $0.id == "go.home" }?.keys == [Shortcut("ctrl+opt+h")!], "applied as Reload Config does")
            #expect(NSApp.mainMenu?.allItems.first { $0.representedObject as? String == "go.home" }?.keyEquivalent == "h")

            pane.record("go.home", replacing: nil)   // ＋
            pane.pressed(Shortcut("ctrl+opt+j")!)
            #expect(file() == ["go.home": ["ctrl+opt+h", "ctrl+opt+j"]])
            pane.record("go.home", replacing: Shortcut("ctrl+opt+h"))
            pane.pressed(Shortcut("backspace")!)   // ⌫ removes it
            #expect(file() == ["go.home": ["ctrl+opt+j"]])
            pane.record("go.home", replacing: nil)
            pane.pressed(Shortcut("esc")!)   // ⎋ cancels
            #expect(pane.recording == nil && file() == ["go.home": ["ctrl+opt+j"]])

            try Data(#"{"go.home": ["ctrl+opt+k"]}"#.utf8).write(to: URL(fileURLWithPath: AppDelegate.keymapPath))   // by hand
            pane.reload()
            #expect(pane.shown.first { $0.id == "go.home" }?.keys == [Shortcut("ctrl+opt+k")!], "read again")
            pane.reset("go.home")
            #expect(file() == [:] && app.commands.first { $0.id == "go.home" }?.keys == [Shortcut("cmd+shift+h")!])
        }
    }

    /// A clash is the answer Reload Config gives: another command's key asks Use Here / Cancel; the menu's own keys and
    /// those macOS takes are said, and nothing changes.
    @Test func clashesAreSaidAsReloadConfigSaysThem() async throws {
        try await keys { app, pane in
            pane.record("go.home", replacing: Shortcut("cmd+shift+h"))
            pane.pressed(Shortcut("cmd+d")!)
            #expect(pane.said == "⌘D is Bookmark This Folder (Go)." && file() == [:])
            pane.useHere()
            #expect(file() == ["go.home": ["cmd+d"]] && app.commands.first { $0.id == "go.bookmark" }?.keys == [])

            let fixed = AppDelegate.fixedKeys(try #require(NSApp.mainMenu)), home = [Shortcut("cmd+shift+h")!]
            for spec in ["cmd+c", "cmd+m"] {
                pane.reset("go.home")
                pane.record("go.home", replacing: home[0])
                pane.pressed(Shortcut(spec)!)
                let reload = AppDelegate.keymapProblems("go.home", [Shortcut(spec)!], was: home, fixed: fixed).map { $0.replacingOccurrences(of: "keymap.json: go.home: ", with: "") }
                #expect(!reload.isEmpty && pane.said == reload.joined(separator: "; "), "\(spec): \(pane.said ?? "")")
                #expect(file() == [:])
            }
            #expect(pane.said?.contains("macOS takes it first") == true)
        }
    }

    /// Reset All… asks first, its ↩ on Cancel: it can't be undone.
    @Test func resetAllAsks() async throws {
        try await keys { app, pane in
            pane.record("go.home", replacing: nil)
            pane.pressed(Shortcut("ctrl+opt+h")!)
            var asked: (String, Int?)?
            AppDelegate.answering = { title, buttons, ret in asked = (title, ret); return buttons.count - 1 }
            defer { AppDelegate.answering = nil }
            await pane.resetAll()
            #expect(asked?.0 == "Reset all shortcuts?" && asked?.1 == 1 && file() == ["go.home": ["shift+cmd+h", "ctrl+opt+h"]], "\(file())")
            AppDelegate.answering = { _, _, _ in 0 }
            await pane.resetAll()
            #expect(file() == [:])
        }
    }
}
