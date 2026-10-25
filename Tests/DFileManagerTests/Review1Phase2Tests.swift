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

/// F5 and F6 say where they go when it isn't plain: a server by its name (production's in purple, bold), or a folder's
/// name with 3–4 panels. Two panels here: nothing more, as before.
@MainActor @Test func copyAndMoveSayWhere() {
    #expect(KeyBarModel.target(server: nil, folder: "/Users/me/site", panels: 2) == nil)
    #expect(KeyBarModel.target(server: ("web-01", true), folder: "/Users/me", panels: 2) == .init(name: "web-01", prod: true))
    #expect(KeyBarModel.target(server: ("db-01", false), folder: "/Users/me", panels: 4)?.text == "→ db-01")
    #expect(KeyBarModel.target(server: nil, folder: "/Users/me/site", panels: 3) == .init(name: "site") && KeyBarModel.target(server: nil, folder: "/", panels: 3)?.text == "→ /")
    let bar = KeyBarView()
    bar.reload(AppDelegate().makeCommands())
    func title(_ id: String) -> NSAttributedString? {
        func buttons(_ v: NSView) -> [NSButton] { v.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        return buttons(bar).first { $0.identifier?.rawValue == id }?.attributedTitle
    }
    #expect(title("file.copy")?.string == "F5 Copy")
    bar.target = .init(name: "web-01", prod: true)
    for id in ["file.copy", "file.move"] {
        let t = title(id)
        #expect(t?.string.hasSuffix(" → web-01") == true && t?.attribute(.foregroundColor, at: t!.length - 1, effectiveRange: nil) as? NSColor == Palette.prod)
    }
    #expect(title("file.view")?.string == "F3 View", "other keys go nowhere")
}

/// A server's row shows a root panel there: its SFTP mark in root's orange, saying so, at rest and under the mouse; a
/// user's panel keeps green.
@MainActor @Test func aRootSessionIsOrangeInTheSidebar() throws {
    let t = SFTPTarget(host: "me@web.invalid")
    func sftp(_ sessions: [SFTPTarget]) throws -> [NSButton] {
        let row = ServerRow(target: t, title: "web", sessions: sessions.map { ServerSession(id: UUID(), kind: .sftp, target: $0, dir: "/") })
        let view = try #require(SidebarController().outlineView(NSOutlineView(), viewFor: nil, item: SidebarController.Node(place: .server(row))) as? NSStackView)
        return view.arrangedSubviews.filter { $0 is ServerChips || $0 is ServerToolbar }.flatMap { ($0 as! NSStackView).arrangedSubviews }
            .compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("sftp ") == true }
    }
    let root = try sftp([t.asRoot()])
    #expect(root.count == 2 && root.allSatisfy { $0.contentTintColor == Palette.root })
    #expect(root.map(\.toolTip) == ["1 SFTP panel open as root", "1 open as root — click to go there  ·  ⌘-click: another one"])
    let both = try sftp([t, t.asRoot()])
    #expect(both.first?.contentTintColor == Palette.root && both.first?.toolTip == "2 SFTP panels open, 1 as root")
    #expect(try sftp([t]).allSatisfy { $0.contentTintColor == Palette.ok })
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

/// A production server's file in the viewer: titled and marked as in the editor — "host:path" and PROD in its title bar.
@Test func theViewerSaysProduction() throws {
    var prod = SavedServer(address: "me@web.invalid")!
    prod.prod = true
    ServerLock.servers = { [prod] }
    defer { ServerLock.servers = { [] } }
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "dfm-p2-" + UUID().uuidString + ".log")
    try Data("line\n".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let v = Viewer.show(url, remote: (prod.target, "/var/log/app.log", 0))
    defer { v.window?.close() }
    #expect(v.window?.title == "me@web.invalid:/var/log/app.log")
    let chips = v.window?.titlebarAccessoryViewControllers.flatMap { $0.view.subviews.compactMap { ($0 as? NSImageView)?.image?.accessibilityDescription } }
    #expect(chips == ["production"])
}
}
