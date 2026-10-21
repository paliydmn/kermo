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
    defer { try? FileManager.default.removeItem(atPath: dir); AppDelegate.unitState = { try Services.state($0, on: $1, wait: $2, env: $3, cancel: $4) } }
    let t = try standIns(dir, slow: true)
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let app = AppDelegate()
    app.panels = [panel]
    ServerLock.servers = { [] }
    nonisolated(unsafe) var now = Services.UnitState(active: "active", sub: "running")
    AppDelegate.unitState = { _, _, _, _, _ in now }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let s = SavedServer(target: t)
    let units = [ServiceUnit(unit: "db.service", active: "active", sub: "running"), ServiceUnit(unit: "web.service", active: "failed", sub: "failed")]
    let list = Picker.show(over: window, placeholder: "", items: units.map { app.serviceItem($0, on: t, of: s) }, query: "web")
    defer { Picker.dismiss() }
    #expect(list.highlighted?.title == "web" && list.highlighted?.subtitleColor == .systemRed, "failed shows red, highlighted or not")
    let cmdR = { list.panel.performKeyEquivalent(with: key(15, "r", .command, window: list.panel.windowNumber)) }
    #expect(cmdR() && Picker.current === list, "stays open")
    #expect(cmdR() && panel.statusText == "web: one change at a time — another is being asked", "a second ⌘R before the first runs")
    await until { list.highlighted?.busy == true }
    #expect(list.highlighted?.subtitle == "Restarting…" && list.highlighted?.busy == true)
    let menu = try #require(list.highlighted?.menu?())
    #expect(menu.items.map(\.title) == ["Status", "Live Logs", "Edit Unit File…", "Refresh Status", "Copy Service Name", "",
                                        "Start", "Stop…", "Restart", "Reload", "", "Enable at Boot", "Disable at Boot", "", "Reset Failed State"])
    #expect(menu.items.filter(\.isEnabled).map(\.title) == ["Status", "Live Logs", "Edit Unit File…", "Refresh Status", "Copy Service Name"],
            "no other change while one runs")
    let restartItem = try #require(menu.items.first { $0.title == "Restart" })
    #expect(restartItem.keyEquivalent == "r" && restartItem.toolTip == "web is restarting… wait for it")
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
    await until { list.highlighted?.subtitle == "Starting…" }
    #expect(list.highlighted?.subtitle == "Starting…")
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
        AppDelegate.unitState = { try Services.state($0, on: $1, wait: $2, env: $3, cancel: $4) }
        AppDelegate.answering = nil
        ServerLock.servers = { [] }
    }
    let t = try standIns(dir)
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let app = AppDelegate()
    app.panels = [panel]
    AppDelegate.unitState = { _, _, _, _, _ in .init(active: "active", sub: "running") }
    var prod = SavedServer(address: "localhost")!
    prod.prod = true
    ServerLock.servers = { [prod] }
    var whileAsked: String?
    AppDelegate.answering = { _, _, d in whileAsked = Picker.current?.highlighted?.subtitle; return d ?? 0 }   // ↩: Cancel
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let unit = ServiceUnit(unit: "web.service", active: "active", sub: "running")
    let list = Picker.show(over: window, placeholder: "", items: [app.serviceItem(unit, on: t, of: SavedServer(target: t))])
    #expect(list.panel.performKeyEquivalent(with: key(15, "r", .command, window: list.panel.windowNumber)))
    await until { !list.said.isEmpty }
    #expect(list.said == "web: not restarted — cancelled; nothing ran" && Picker.current === list)
    #expect(whileAsked == "active · running", "nothing says Restarting… before it's asked")
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
    #expect(menu?.items.count == 15 && list.highlighted?.title == "b", "the clicked row is what it acts on")
    #expect(rightClick(table.rect(ofRow: 2).maxY + 200) == nil && list.highlighted?.title == "b", "an empty spot: no menu")
    let odd = rightClick(table.rect(ofRow: 2).midY)
    #expect(odd?.items.filter(\.isEnabled).map(\.title) == ["Copy Service Name"], "only its name copied")
    #expect(odd?.items.first?.toolTip == "“x;reboot.service” has characters Kermo won't put into a command: nothing runs on it")
    #expect(Picker.menuKeys.contains(Shortcut("ctrl+return")!) && Picker.menuKeys.contains(Shortcut("shift+f10")!))
}

/// What doesn't apply is greyed, saying why: a reload without ExecReload, enable on an enabled unit, disable and
/// enable on a static one, a reset of one not failed, a stop of one not running. ⌘C copies the unit's whole name.
@MainActor @Test func whatDoesntApplyIsGreyedAndTheNameIsCopied() throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let app = AppDelegate()
    app.panels = [panel]
    let s = SavedServer(target: .local())
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))   // not the user's clipboard
    defer { pb.releaseGlobally() }
    func why(_ u: ServiceUnit) -> [String: String] {
        Dictionary(uniqueKeysWithValues: app.serviceActions(u, on: .local(), of: s, pasteboard: pb).compactMap { a in a.why.map { (a.title, $0) } })
    }
    var u = ServiceUnit(unit: "cron.service", active: "active", sub: "running")
    (u.canReload, u.unitFile) = (false, "enabled")
    #expect(why(u) == ["Reload": "cron can't reload: it has no ExecReload (Restart is the other way)",
                       "Enable at Boot": "cron is enabled at boot already", "Reset Failed State": "cron isn't failed"])
    (u.active, u.sub, u.unitFile, u.canReload) = ("inactive", "dead", "static", nil)
    #expect(why(u)["Stop…"] == "cron isn't running" && why(u)["Disable at Boot"] == "cron is static (its unit has no [Install] section): nothing to change at boot")
    (u.active, u.unitFile) = ("failed", nil)
    #expect(why(u).isEmpty, "what systemctl didn't say: let systemctl say it")
    app.serviceItem(u, on: .local(), of: s, pasteboard: pb).keys[Shortcut("cmd+c")!]?()
    #expect(pb.string(forType: .string) == "cron.service" && panel.statusText == "Copied “cron.service”")
}

/// Stop asks first on any server, saying what it means (↩ = Cancel); Refresh Status reads it again and runs nothing.
@MainActor @Test func stopAsksEverywhereAndRefreshRunsNothing() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-svc-" + UUID().uuidString
    defer {
        try? FileManager.default.removeItem(atPath: dir)
        AppDelegate.unitState = { try Services.state($0, on: $1, wait: $2, env: $3, cancel: $4) }
        AppDelegate.answering = nil
    }
    let t = try standIns(dir)
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let app = AppDelegate()
    app.panels = [panel]
    ServerLock.servers = { [] }
    nonisolated(unsafe) var waited: [Bool] = []
    AppDelegate.unitState = { _, _, wait, _, _ in waited.append(wait); return .init(active: "inactive", sub: "dead", unitFile: "enabled") }
    var asked: [(String, [String], Int?)] = []
    AppDelegate.answering = { m, b, d in asked.append((m, b, d)); return asked.count == 1 ? d ?? 0 : 0 }   // Cancel, then Stop
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    var unit = ServiceUnit(unit: "web.service", active: "active", sub: "running")
    unit.unitFile = "enabled"
    let list = Picker.show(over: window, placeholder: "", items: [app.serviceItem(unit, on: t, of: SavedServer(target: t))])
    defer { Picker.dismiss() }
    func press(_ title: String) {
        list.highlighted?.menu?()?.items.first { $0.title == title }.map { item in _ = (item.target as? NSObject)?.perform(item.action) }
    }
    press("Stop…")
    await until { !list.said.isEmpty }
    #expect(asked.first?.0 == "Stop web on localhost?" && asked.first?.1 == ["Stop", "Cancel"] && asked.first?.2 == 1)
    #expect(list.said == "web: not stopped — cancelled; nothing ran" && !FileManager.default.fileExists(atPath: dir + "/systemctl.log"))
    press("Stop…")
    await until { list.said.hasPrefix("✓") }
    #expect(list.said.hasPrefix("✓ web stopped on localhost at ") && list.highlighted?.subtitle == "inactive · dead", "\(list.said)")
    #expect((try? String(contentsOfFile: dir + "/systemctl.log", encoding: .utf8)) == "stop -- web.service\n" && waited == [true])
    press("Refresh Status")
    await until { list.said.hasPrefix("↻") }
    #expect(list.said.hasPrefix("↻ web on localhost at ") && list.said.hasSuffix(" — inactive · dead, enabled at boot") && waited == [true, false])
    #expect((try? String(contentsOfFile: dir + "/systemctl.log", encoding: .utf8)) == "stop -- web.service\n", "nothing ran")
}

/// ⌘R in Containers… keeps the list too: the row says it runs, then the container's state, and the line says how it went.
@MainActor @Test func aContainersRestartKeepsTheList() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-ctr-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir); AppDelegate.containerState = { try Containers.state($0, tool: $1, on: $2, env: $3, cancel: $4) } }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let app = AppDelegate()
    app.panels = [panel]
    ServerLock.servers = { [] }
    AppDelegate.containerState = { _, _, _, _, _ in Thread.sleep(forTimeInterval: 0.3); return "exited" }
    let tool = dir + "/podman"   // a stand-in: the command's first word
    try Data("#!/bin/sh\necho \"$*\" >> \(dir)/podman.log\n".utf8).write(to: URL(fileURLWithPath: tool))
    chmod(tool, 0o755)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let c = ContainerInfo(name: "api", state: "running", status: "Up 5 minutes", image: "api:2")
    let list = Picker.show(over: window, placeholder: "", items: [app.containerItem(c, tool: tool, on: .local(), of: SavedServer(target: .local()))])
    defer { Picker.dismiss() }
    #expect(list.panel.performKeyEquivalent(with: key(15, "r", .command, window: list.panel.windowNumber)) && Picker.current === list)
    await until { list.highlighted?.busy == true }
    #expect(list.highlighted?.subtitle == "Restarting…")
    await until { !list.said.isEmpty }
    #expect(list.said.hasPrefix("⚠ api: the restart completed on localhost at ") && list.said.hasSuffix(", but the container is exited"), "\(list.said)")
    #expect(list.highlighted?.subtitle == "exited" && list.highlighted?.busy == false)
    #expect((try? String(contentsOfFile: dir + "/podman.log", encoding: .utf8)) == "restart -- api\n")
}
}
