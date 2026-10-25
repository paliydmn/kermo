import AppKit
import Testing
@testable import DFileManager

@MainActor private func layers() -> (NSEvent.ModifierFlags) -> [KeySlot]? {
    let all = KeyBarModel.layers(AppDelegate().makeCommands())
    return { m in all.first { $0.mods == m }?.slots }
}

@Test @MainActor func baseLayerIsExactlyF1ToF10() {
    #expect(layers()([])!.map(\.key) == (1...10).map { "F\($0)" })
    #expect(layers()([])!.map(\.label) == ["Keys", "Menu", "View", "Edit", "Copy", "Move", "MkDir", "Trash", "Commands", "Tree"])
}

@Test @MainActor func optionDigitDuplicatesCollapseIntoAHint() {
    let l = layers()
    #expect(l([.shift, .option]) == [KeySlot(key: "⌥⇧4 5 6 8", label: "= ⇧F4 5 6 8", id: nil)],
            "P-6 (review 1): ⇧⌥4/5/6/8 duplicate ⇧F4/F5/F6/F8 — the hint names those, not 1…0")
    let opt = l(.option)!
    #expect(!opt.contains { $0.key == "⌥5" || $0.key == "⌥0" })
    #expect(opt.last == KeySlot(key: "⌥1…0", label: "= F1…F10", id: nil))
    #expect(opt.prefix(5).map(\.key) == ["⌥F1", "⌥F5", "⌥F7", "⌥F9", "⌥F10"])
}

@Test @MainActor func oneSlotPerCommandPerLayer() {
    let commands = AppDelegate().makeCommands()
    let ids = Set(commands.map(\.id))
    for (mods, slots) in KeyBarModel.layers(commands) {
        let real = slots.compactMap(\.id)
        #expect(Set(real).count == real.count, "\(KeyBarModel.symbol(mods))")
        #expect(real.allSatisfy(ids.contains))
    }
    let shift = layers()(.shift)!
    #expect(shift.filter { $0.id == "file.delete" }.map(\.key) == ["⇧F8"])   // not also ⇧⌦
    #expect(shift.contains { $0.key == "⇧↑" } && shift.contains { $0.key == "⇧↓" })
}

@Test @MainActor func layerOrderIsStable() {
    let mods = KeyBarModel.layers(AppDelegate().makeCommands()).map(\.mods)
    #expect(Array(mods.prefix(7)) == Array(KeyBarModel.order.prefix(7)))
    #expect(mods == KeyBarModel.layers(AppDelegate().makeCommands()).map(\.mods))
}

@Test func overflowBecomesPlusN() {
    let s = (1...12).map { KeySlot(key: "\($0)", label: "", id: "\($0)") }
    #expect(KeyBarModel.fit(s, capacity: 10).shown.count == 9 && KeyBarModel.fit(s, capacity: 10).more == 3)
    #expect(KeyBarModel.fit(s, capacity: 12).more == 0 && KeyBarModel.fit(s, capacity: 12).shown == s)
}

@Test @MainActor func cheatSheetFiltersByTextAndLayer() {
    let commands = AppDelegate().makeCommands()
    let all = KeyHelp.sections(commands)
    #expect(all.map(\.title).first == "File" && all.map(\.title).last == "Keyboard")
    let zip = KeyHelp.sections(commands, query: "zip").flatMap(\.rows)
    #expect(zip.contains { $0.title == "Compress…" })
    let ctrlCmd = KeyHelp.sections(commands, layer: [.command, .shift]).flatMap(\.rows)
    #expect(ctrlCmd.contains { $0.title == "Search…" && $0.keys == "⇧⌘P" })
}

/// P-1 (review 1): every command with a key is on F1, under its menu: F1's menus are the menu bar's (Git was missing).
@Test @MainActor func cheatSheetListsEveryBoundKey() {
    let commands = AppDelegate().makeCommands()
    #expect(Set(commands.compactMap(\.menu)).isSubset(of: AppDelegate.menus), "a new menu goes into AppDelegate.menus")
    #expect(Set(KeyHelp.groups) == Set(AppDelegate.menus))
    let rows = KeyHelp.sections(commands).flatMap { s in s.rows.map { "\(s.title): \($0.title)" } }
    for c in commands where !c.keys.isEmpty && !c.hidden {
        #expect(rows.contains("\(c.menu ?? "Keyboard"): \(c.title)"), "\(c.id) isn't on F1")
    }
    #expect(KeyHelp.sections(commands).contains { $0.title == "Git" && $0.rows.contains { $0.title == "Switch Branch…" && $0.keys == "⌃B" } })
}

/// P-3 (review 1): on a server's panel F8 deletes, after a question — the bar says so; on this Mac it's the Trash.
@Test @MainActor func f8SaysDeleteOnAServer() {
    let commands = AppDelegate().makeCommands()
    func f8(server: Bool) -> String? { KeyBarModel.layers(commands, server: server).first { $0.mods == [] }?.slots.first { $0.key == "F8" }?.label }
    #expect(f8(server: false) == "Trash" && f8(server: true) == "Delete…")
    let cmd = KeyBarModel.layers(commands, server: true).first { $0.mods == .command }?.slots
    #expect(cmd?.first { $0.id == "file.trash" }?.label == "Delete…", "⌘⌫ too")
}
