import AppKit
import Testing
@testable import DFileManager

// Review 1, phase 3: keys, not prose — one key bar for the panels, the terminal, the command line, Pickers and windows.

/// The words of a text, letters only: "Show/Hide Sidebar" → show, hide, sidebar; "Mark ↓" → mark.
private func words(_ s: String) -> [String] {
    s.lowercased().split { !$0.isLetter }.map(String.init)
}

/// R-33: a slot's label is words of its command's menu title — no "MkDir" for New Folder…, no "Commands" for Search… —
/// in Title Case. Where the bar says what the menu can't, the exceptions are listed here, each with why.
@MainActor @Test func labelsAreWordsOfTheirMenuTitles() {
    let commands = AppDelegate().makeCommands()
    let exceptions: [String: String] = [
        "file.trash Delete…": "F8 on a server deletes, after a question: no Trash there (the menu item says Delete… then too)",
    ]
    let terminal = AppDelegate.terminalCommands.compactMap { id in commands.first { $0.id == id } }
    let all = KeyBarModel.layers(commands) + KeyBarModel.layers(commands, server: true) + KeyBarModel.layers(terminal, terminal: true)
    var used: Set<String> = []
    for slot in all.flatMap(\.slots) {
        guard let id = slot.id, let c = commands.first(where: { $0.id == id }) else { continue }
        if exceptions["\(id) \(slot.label)"] != nil {
            used.insert("\(id) \(slot.label)")
            continue
        }
        let title = Set(words(c.title))
        #expect(words(slot.label).allSatisfy(title.contains), "\(id): “\(slot.label)” isn't in “\(c.title)”")
        let small: Set<String> = ["to", "in", "of", "by", "as", "and", "or", "on", "for", "at"]
        for (i, w) in slot.label.split(separator: " ").enumerated() where w.first?.isLetter == true {
            #expect(w.first!.isUppercase || i > 0 && small.contains(String(w)), "\(id): “\(slot.label)” isn't in Title Case")
        }
        #expect(!slot.label.contains("("), "\(id): no brackets")
    }
    #expect(used == Set(exceptions.keys), "an exception no slot needs any more goes")
    #expect(KeyBarModel.layers(commands).first { $0.mods == .shift }?.slots.first { $0.key == "⇧F10" }?.label == "Menu",
            "Menu is the context menu's alone")
}

/// R-32: ⇧ ⌥ ⌘ ⌃ chips in place of "Hold — ▾": held, a chip lights and its layer shows; a click keeps it (outlined),
/// a second click or ⎋ lets go, as does a command.
@MainActor @Test func modifierChipsHoldAndPin() async {
    let bar = KeyBarView()
    bar.reload(AppDelegate().makeCommands())
    func state(_ f: NSEvent.ModifierFlags) -> (held: Bool, pinned: Bool) { bar.chipStates.first { $0.flag == f }.map { ($0.held, $0.pinned) } ?? (false, false) }
    func click(_ f: NSEvent.ModifierFlags) {
        func chips(_ v: NSView) -> [ModChip] { v.subviews.flatMap { ($0 as? ModChip).map { [$0] } ?? chips($0) } }
        let c = chips(bar).first { $0.flag == f }!
        _ = (c.target as? NSObject)?.perform(c.action, with: c)
    }
    #expect(bar.chipStates.map(\.flag) == [.shift, .option, .command, .control])
    #expect(bar.shownSlots.first?.key == "F1")

    bar.modifiersChanged(.command)
    for _ in 0..<100 where bar.mods != .command { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(state(.command) == (true, false) && bar.shownSlots.allSatisfy { $0.key.hasPrefix("⌘") })
    bar.modifiersChanged([])
    #expect(bar.mods == [] && state(.command) == (false, false))

    click(.shift)
    #expect(bar.pinned == .shift && state(.shift) == (false, true) && bar.shownSlots.contains { $0.key == "⇧F6" })
    click(.command)
    #expect(bar.pinned == [.shift, .command] && bar.shownSlots.contains { $0.key == "⇧⌘P" }, "two chips: their combination")
    click(.command)
    click(.shift)
    #expect(bar.pinned == [] && bar.shownSlots.first?.key == "F1", "a second click lets go")
    click(.option)
    #expect(bar.unpin() && bar.pinned == [] && !bar.unpin(), "⎋ lets go; then ⎋ is the panel's again")
    click(.control)
    bar.commandRan("view.terminal")
    #expect(bar.pinned == [], "a command lets go too")

    func chipLabels() -> [String] {
        func chips(_ v: NSView) -> [ModChip] { v.subviews.flatMap { ($0 as? ModChip).map { [$0] } ?? chips($0) } }
        return chips(bar).compactMap { $0.accessibilityLabel() }
    }
    click(.shift)
    #expect(chipLabels() == ["Shift layer, pinned", "Option layer", "Command layer", "Control layer"])
}

/// R-36: with the terminal up the bar shows the terminal's commands from the registry — its panes' too — and ⌃O goes
/// back to the panels. None of them is a bare F-key: each one's first key shows at rest.
@MainActor @Test func theTerminalsKeysComeFromTheRegistry() {
    let commands = AppDelegate().makeCommands()
    let bar = KeyBarView()
    bar.terminalShown = { true }
    bar.frame = NSRect(x: 0, y: 0, width: 1400, height: 30)
    bar.reload(commands)
    let rest = bar.shownSlots
    #expect(rest.first == KeySlot(key: "⌃O", label: "Panels", id: "view.terminal"))
    #expect(rest.contains(KeySlot(key: "⌘T", label: "New Tab", id: "tab.new")) && rest.contains { $0.id == "term.split.right" })
    #expect(rest.compactMap(\.id).allSatisfy(AppDelegate.terminalCommands.contains))
    let terminal = AppDelegate.terminalCommands.compactMap { id in commands.first { $0.id == id } }
    let panes = KeyBarModel.layers(terminal, terminal: true).first { $0.mods == [.command, .option] }?.slots.compactMap(\.id)
    #expect(panes == ["term.pane.left", "term.pane.right", "term.pane.up", "term.pane.down"])
    #expect(!KeyBarModel.layers(commands).flatMap(\.slots).contains { $0.id?.hasPrefix("term.pane.") == true }, "not on the panels' bar")
}

/// R-36: the command line's keys, listed by its key handler, are the bar while it has the focus and its placeholder —
/// one list. Not ⌃↩: macOS gives it to a text field's context menu, so Insert Name stays the panel's.
@MainActor @Test func theCommandLinesKeysAreOneList() {
    let keys = AppDelegate.commandLineKeys
    #expect(keys.map(\.key) == ["↩", "⇧↩", "⌘↩", "↑↓", "⎋", "%f %s %d %D"])
    let hint = AppDelegate.commandHint(root: nil)
    for k in keys { #expect(hint.contains(k.key), "\(k.key)") }
    let commands = AppDelegate().makeCommands()
    let bar = KeyBarView()
    bar.frame = NSRect(x: 0, y: 0, width: 1400, height: 30)
    bar.reload(commands)
    var ran: [String] = []
    bar.onRun = { ran.append($0) }
    bar.canRun = { _ in false }   // a text field has the focus: the panels' commands are off, the line's own aren't
    bar.list = keys
    #expect(bar.shownSlots == keys)
    func buttons(_ v: NSView) -> [NSButton] { v.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
    let run = buttons(bar).first { $0.identifier?.rawValue == "cmdline.shell" }!
    #expect(run.isEnabled && !(buttons(bar).first { $0.accessibilityLabel() == "↑↓, History" }?.isEnabled ?? true))
    _ = (run.target as? NSObject)?.perform(run.action, with: run)
    #expect(ran == ["cmdline.shell"])
}
