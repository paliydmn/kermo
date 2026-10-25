import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Review 1, phase 2: the context of an action shows where you act.

/// A place's color, one rule everywhere: production's purple wins over root's orange; anywhere else, nil (the theme's
/// accent). Themes with a background keep their own accent: MC's and Far's cyan, else the folders' color.
@Test func aPlacesColorIsProductionsThenRoots() {
    #expect(Chip.tint([]) == nil && Chip.tint([.locked]) == nil)
    #expect(Chip.tint([.root]) == Palette.root && Chip.tint([.root, .locked]) == Palette.root)
    #expect(Chip.tint([.prod]) == Palette.prod && Chip.tint([.prod, .root]) == Palette.prod)
    func theme(_ name: String) -> Theme { Theme.all.first { $0.name == name }! }
    #expect(theme("System").accent == Palette.accent)
    #expect(theme("Midnight Commander").accent == theme("Midnight Commander").grid && theme("Far Manager").accent == theme("Far Manager").grid)
    #expect(theme("Dracula").accent == theme("Dracula").dir)
}

/// With 3–4 panels F5/F6 go to the panel active before, while it's there; else the next one to the right. Only that
/// panel says "→ F5", and the mark moves with the target: click a panel, then another.
@MainActor @Test func theTargetPanelSaysF5() {
    #expect(AppDelegate.targetIndex(active: 0, previous: nil, count: 2) == 1 && AppDelegate.targetIndex(active: 1, previous: 0, count: 2) == 0)
    #expect(AppDelegate.targetIndex(active: 1, previous: 0, count: 3) == 0 && AppDelegate.targetIndex(active: 0, previous: 2, count: 4) == 2)
    #expect(AppDelegate.targetIndex(active: 2, previous: nil, count: 3) == 0 && AppDelegate.targetIndex(active: 1, previous: 1, count: 3) == 2, "none before: the next")
    let app = AppDelegate(), host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    app.terminal = EmbeddedTerminal(covering: host)
    app.panels = (0..<3).map { _ in PanelViewController(tabs: [NSTemporaryDirectory()], index: 0, showHidden: false) }
    app.panels.forEach { $0.loadViewIfNeeded() }
    defer { app.panels.forEach { $0.shutdown() } }
    func marks() -> [Bool] { app.panels.map(\.targetMarkShown) }
    app.activate(app.panels[1])
    #expect(marks() == [true, false, false] && app.other === app.panels[0])
    app.activate(app.panels[2])
    #expect(marks() == [false, true, false] && app.other === app.panels[1])
    app.activate(app.panels[0])
    #expect(marks() == [false, false, true], "back to the first: the last is where F5 goes")
    app.panels.removeLast()
    app.activate(app.panels[1])
    #expect(marks() == [false, false], "two panels: no mark")
}

extension ServerLockTests {
/// The active panel has a line under its path bar in its place's color — the theme's accent here, purple on a
/// production server, orange on a root panel, purple on a production root panel; an inactive one has none.
@Test func onlyTheActivePanelHasALine() throws {
    var prod = SavedServer(address: "me@web.invalid")!
    prod.prod = true
    ServerLock.servers = { [prod] }
    defer { ServerLock.servers = { [] } }
    let d = NSTemporaryDirectory()
    func line(_ tab: Session.Tab, active: Bool) -> NSColor? {
        let panel = PanelViewController(session: [tab], index: 0, showHidden: false)
        panel.loadViewIfNeeded()
        defer { panel.shutdown() }
        panel.isActive = active
        return panel.headerLine
    }
    let here = Session.Tab(path: d), web = Session.Tab(path: d, server: prod.target, dir: "/"), db = SFTPTarget(host: "me@db.invalid")
    #expect(line(here, active: true) == Theme.current.accent && line(here, active: false) == nil)
    #expect(line(web, active: true) == Palette.prod && line(web, active: false) == nil)
    #expect(line(Session.Tab(path: d, server: db, root: true, dir: "/"), active: true) == Palette.root)
    #expect(line(Session.Tab(path: d, server: prod.target, root: true, dir: "/"), active: true) == Palette.prod)
}

/// A server tab shows production and root by its chips, as the terminal's tabs do: an inactive production tab doesn't
/// look like one on this Mac.
@Test func serverTabsCarryTheirChips() {
    var prod = SavedServer(address: "me@web.invalid")!
    prod.prod = true
    ServerLock.servers = { [prod] }
    defer { ServerLock.servers = { [] } }
    let d = NSTemporaryDirectory()
    let panel = PanelViewController(session: [Session.Tab(path: d), Session.Tab(path: d, server: prod.target, dir: "/"),
                                              Session.Tab(path: d, server: SFTPTarget(host: "me@db.invalid"), root: true, dir: "/")], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let said = panel.tabBar.arrangedSubviews.compactMap { ($0 as? NSButton)?.attributedTitle }.map { t in
        var chips: [String] = []
        t.enumerateAttribute(.attachment, in: NSRange(location: 0, length: t.length)) { a, _, _ in
            if let d = (a as? NSTextAttachment)?.image?.accessibilityDescription { chips.append(d) }
        }
        return chips
    }
    #expect(said == [[], ["production"], ["root"]])
}
}
