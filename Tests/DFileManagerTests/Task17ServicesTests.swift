import AppKit
import DFMCore
import Testing
@testable import DFileManager

private func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = [], window: Int = 0) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: window, context: nil,
                     characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
}

/// Part of ServerLockTests: one picker at a time (`Picker.current`), and localhost locked or production meanwhile.
extension ServerLockTests {
private func until(_ done: () -> Bool) async {
    for _ in 0..<250 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
}

/// A stand-in systemctl as root, through a stand-in sudo; `slow`: a restart that takes a while.
private func standIns(_ dir: String, slow: Bool = false) throws -> SFTPTarget {
    try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
    try Data("#!/bin/sh\necho \"$*\" >> \(dir)/systemctl.log\n\(slow ? "sleep 0.5\n" : "")[ -f \(dir)/fail ] && { echo 'Job for web.service failed.'; exit 1; }\nexit 0\n".utf8)
        .write(to: URL(fileURLWithPath: dir + "/bin/systemctl"))
    chmod(dir + "/bin/systemctl", 0o755)
    let sudo = dir + "/sudo"
    try Data("#!/bin/sh\n[ \"$1\" = -n ] && [ \"$2\" = -- ] || exit 2\nshift 2\nPATH=\(dir)/bin:$PATH exec \"$@\"\n".utf8).write(to: URL(fileURLWithPath: sudo))
    chmod(sudo, 0o755)
    return SFTPTarget.local(sudo: sudo).asRoot(false)
}

/// ⌘R in Services… keeps the list: the row says "Restarting…" and a second ⌘R waits for it (one restart ran); then
/// the row has the state read again, and the line under the list says which service, where, when — until the next.
@MainActor @Test func aRestartKeepsTheListAndSaysHowItWent() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-svc-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: dir); AppDelegate.unitState = { try Services.state($0, on: $1, env: $2, cancel: $3) } }
    let t = try standIns(dir, slow: true)
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let app = AppDelegate()
    app.panels = [panel]
    ServerLock.servers = { [] }
    nonisolated(unsafe) var now = Services.UnitState(active: "active", sub: "running")
    AppDelegate.unitState = { _, _, _, _ in now }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let s = SavedServer(target: t)
    let units = [ServiceUnit(unit: "db.service", active: "active", sub: "running"), ServiceUnit(unit: "web.service", active: "failed", sub: "failed")]
    let list = Picker.show(over: window, placeholder: "", items: units.map { app.serviceItem($0, on: t, of: s) }, query: "web")
    defer { Picker.dismiss() }
    #expect(list.highlighted?.title == "web" && list.highlighted?.subtitleColor == .systemRed, "failed shows red, highlighted or not")
    let cmdR = { list.panel.performKeyEquivalent(with: key(15, "r", .command, window: list.panel.windowNumber)) }
    #expect(cmdR() && Picker.current === list, "stays open")
    #expect(list.highlighted?.subtitle == "Restarting…" && list.highlighted?.busy == true)
    let menu = try #require(list.highlighted?.menu?())
    #expect(menu.items.map(\.title) == ["Status", "Live Logs", "Edit Unit File…", "", "Start", "Restart"])
    #expect(menu.items.filter(\.isEnabled).map(\.title) == ["Status", "Live Logs", "Edit Unit File…"], "no other change while one runs")
    #expect(menu.items.last?.keyEquivalent == "r" && menu.items.last?.toolTip == "web is restarting… wait for it")
    #expect(menu.items.first?.keyEquivalent == "", "↩ in an open menu runs the highlighted item, not Status")
    #expect(cmdR())
    #expect(panel.statusText == "web is restarting… wait for it")
    await until { !list.said.isEmpty }
    #expect(list.said.hasPrefix("✓ web restarted on localhost at ") && list.said.hasSuffix(" — active · running"), "\(list.said)")
    #expect(list.highlighted?.subtitle == "active · running" && list.highlighted?.subtitleColor == nil && list.highlighted?.busy == false)
    #expect(list.rows.map(\.title) == ["web"] && Picker.current === list, "what's typed stays")
    #expect((try? String(contentsOfFile: dir + "/systemctl.log", encoding: .utf8)) == "restart -- web.service\n", "once")

    // Exit 0, failed a second later: a warning, not a success. A failed one: its first line, and its whole output.
    now = .init(active: "failed", sub: "failed")
    try Data().write(to: URL(fileURLWithPath: dir + "/fail"))
    #expect(cmdR())
    await until { list.said.hasPrefix("✕") }
    #expect(list.said.hasPrefix("✕ web: the restart failed on localhost at ") && list.said.hasSuffix(": Job for web.service failed. — now failed"), "\(list.said)")
    func buttons(_ v: NSView) -> [NSButton] { v.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
    let output = try #require(buttons(list.panel.contentView!).first { $0.title == "Output…" && !$0.isHidden })
    var asked: (String, Bool)?
    AppDelegate.answering = { m, _, _ in asked = (m, Picker.current?.isHolding == true); return 0 }
    defer { AppDelegate.answering = nil }
    _ = (output.target as? NSObject)?.perform(output.action)   // not performClick: in a test run it ended the run (the main loop stopped)
    await until { asked != nil }
    #expect(asked?.0 == "“systemctl restart -- web.service” on localhost" && asked?.1 == true, "its sheet holds the list open")
    try FileManager.default.removeItem(atPath: dir + "/fail")
    list.highlighted?.menu?()?.items.first { $0.title == "Start" }.map { item in _ = (item.target as? NSObject)?.perform(item.action) }
    await until { list.said.contains("the start") }
    #expect(list.said.hasPrefix("⚠ web: the start completed on localhost at ") && list.said.hasSuffix(", but the service is failed"), "\(list.said)")
    #expect((try? String(contentsOfFile: dir + "/systemctl.log", encoding: .utf8))?.hasSuffix("start -- web.service\n") == true)
}

/// On a production server the question asks over the list; its Cancel isn't a restart — nothing ran, the list stays
/// and says so. ⌘R with the list closed says in the status line how it went.
@MainActor @Test func aDeclinedRestartSaysNothingRanAndAClosedListUsesTheStatusLine() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-svc-" + UUID().uuidString
    defer {
        try? FileManager.default.removeItem(atPath: dir)
        AppDelegate.unitState = { try Services.state($0, on: $1, env: $2, cancel: $3) }
        AppDelegate.answering = nil
        ServerLock.servers = { [] }
    }
    let t = try standIns(dir)
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let app = AppDelegate()
    app.panels = [panel]
    AppDelegate.unitState = { _, _, _, _ in .init(active: "active", sub: "running") }
    var prod = SavedServer(address: "localhost")!
    prod.prod = true
    ServerLock.servers = { [prod] }
    AppDelegate.answering = { _, _, d in d ?? 0 }   // ↩: Cancel
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let unit = ServiceUnit(unit: "web.service", active: "active", sub: "running")
    let list = Picker.show(over: window, placeholder: "", items: [app.serviceItem(unit, on: t, of: SavedServer(target: t))])
    #expect(list.panel.performKeyEquivalent(with: key(15, "r", .command, window: list.panel.windowNumber)))
    await until { !list.said.isEmpty }
    #expect(list.said == "web: not restarted — cancelled; nothing ran" && Picker.current === list)
    #expect(list.highlighted?.subtitle == "active · running" && !FileManager.default.fileExists(atPath: dir + "/systemctl.log"))
    Picker.dismiss()

    AppDelegate.answering = { _, _, _ in 0 }   // Restart
    app.serviceItem(unit, on: t, of: SavedServer(target: t)).keys[Shortcut("cmd+r")!]?()
    await until { panel.statusText.hasPrefix("web restarted") }
    #expect(panel.statusText.hasPrefix("web restarted on localhost at ") && panel.statusText.hasSuffix(" — active · running"), "\(panel.statusText)")
}

/// A picker that holds (something asks: Touch ID, a question, a password) stays when it loses the key to none of the
/// app's windows; one that doesn't hold closes, as ever. It opens on what was typed and highlighted last, and says so as it closes.
@MainActor @Test func aHoldingPickerStaysAndOneReopensWhereItWas() async {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    var closed: (String, String?)?
    let items = ["a", "b", "c"].map { id in
        var it = Picker.Item(title: id) {}
        it.id = id
        return it
    }
    let p = Picker.show(over: window, placeholder: "", items: items, select: "c", onClose: { closed = ($0, $1) })
    #expect(p.highlighted?.id == "c")
    let note = Notification(name: NSWindow.didResignKeyNotification)
    await p.holding {
        p.windowDidResignKey(note)
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(Picker.current === p, "kept while it asks")
    }
    p.windowDidResignKey(note)
    #expect(Picker.current == nil && closed?.0 == "" && closed?.1 == "c")
    let q = Picker.show(over: window, placeholder: "", items: items, query: "b", select: "b")
    #expect(q.rows.map(\.id) == ["b"] && q.highlighted?.id == "b")
    Picker.dismiss()
}

/// A row's menu: right-click on a row highlights it first and acts on it; an empty spot has none. A name Kermo won't
/// put into a command greys every action, saying why.
@MainActor @Test func aServicesMenuActsOnTheRowClicked() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let app = AppDelegate()
    let s = SavedServer(target: .local())
    let units = ["a", "b", "x;reboot"].map { ServiceUnit(unit: "\($0).service", active: "active", sub: "running") }
    let list = Picker.show(over: window, placeholder: "", items: units.map { app.serviceItem($0, on: .local(), of: s) })
    defer { Picker.dismiss() }
    let table = try #require(list.panel.contentView?.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? PickerTable }.first)
    table.layoutSubtreeIfNeeded()
    func rightClick(_ y: CGFloat) -> NSMenu? {
        let at = table.convert(NSPoint(x: 20, y: y), to: nil)
        let e = NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: [], timestamp: 0, windowNumber: list.panel.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        return table.menu(for: e)
    }
    #expect(list.highlighted?.title == "a")
    let menu = rightClick(table.rect(ofRow: 1).midY)
    #expect(menu?.items.count == 6 && list.highlighted?.title == "b", "the clicked row is what it acts on")
    #expect(rightClick(table.rect(ofRow: 2).maxY + 200) == nil && list.highlighted?.title == "b", "an empty spot: no menu")
    let odd = rightClick(table.rect(ofRow: 2).midY)
    #expect(odd?.items.allSatisfy { !$0.isEnabled } == true)
    #expect(odd?.items.first?.toolTip == "“x;reboot.service” has characters Kermo won't put into a command: nothing runs on it")
    #expect(Picker.menuKeys.contains(Shortcut("ctrl+return")!) && Picker.menuKeys.contains(Shortcut("shift+f10")!))
}
}
