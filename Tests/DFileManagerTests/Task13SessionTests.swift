import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 13 (В6, В7): what a restart brings back, and Touch ID for sudo.

@MainActor private func waitUntil(_ done: () -> Bool) async {
    for _ in 0..<500 { if done() { return }; try? await Task.sleep(for: .milliseconds(10)) }
}
private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t13s-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
/// Defaults of their own: the debug build's standard ones are the user's Kermo's.
private func scratchDefaults() -> (UserDefaults, String) {
    let name = "dfm-test-session-" + UUID().uuidString
    return (UserDefaults(suiteName: name)!, name)
}

/// The session is one key; the old ones are still read when it isn't there, and still written for an older Kermo.
@Test func aSessionComesBackAndTheOldKeysAreRead() throws {
    let (d, name) = scratchDefaults()
    defer { d.removePersistentDomain(forName: name) }
    let web = SFTPTarget(host: "k13@web1.invalid", port: 2222)
    let s = Session(panels: [Session.Panel(tabs: [Session.Tab(path: "/tmp", cursor: "a b", server: web, root: true, dir: "/etc/nginx"),
                                                   Session.Tab(path: "/usr", cursor: nil)], index: 1),
                             Session.Panel(tabs: [Session.Tab(path: "/")], index: 0)],
                    active: 1, dividers: [0.3])
    s.save(d)
    #expect(Session.load(d) == s)
    #expect(d.array(forKey: "panelTabs") as? [[String]] == [["/tmp", "/usr"], ["/"]] && d.array(forKey: "panelTabIndex") as? [Int] == [1, 0])

    d.set(Data("not json".utf8), forKey: "panelSession")   // unreadable: as before it existed
    #expect(Session.load(d).panels.map { $0.tabs.map(\.path) } == [["/tmp", "/usr"], ["/"]] && Session.load(d).panels[0].index == 1)
    d.removeObject(forKey: "panelSession")
    d.removeObject(forKey: "panelTabs")
    d.removeObject(forKey: "panelTabIndex")
    d.set(["/a", "/b"], forKey: "panelPaths")
    #expect(Session.load(d) == Session(panels: [Session.Panel(tabs: [Session.Tab(path: "/a")], index: 0), Session.Panel(tabs: [Session.Tab(path: "/b")], index: 0)]))

    s.save(d)   // then an older Kermo ran, and moved: its keys are newer
    d.set([["/var"], ["/"]], forKey: "panelTabs")
    #expect(Session.load(d).panels.map { $0.tabs.map(\.path) } == [["/var"], ["/"]])
    s.save(d)
    d.set([0, 0], forKey: "panelTabIndex")
    #expect(Session.load(d).panels.map(\.index) == [0, 0] && Session.load(d).panels[0].tabs[0].server == nil)
}

/// The dividers come back as saved when they make sense for the panels there are; otherwise even.
@Test func dividersComeBackOnlyWhenTheyFit() {
    #expect(Session.dividers([0.3], panels: 2) == [0.3])
    #expect(Session.dividers([0.3, 0.6], panels: 3) == [0.3, 0.6])
    #expect(Session.dividers([], panels: 2) == [0.5], "never saved")
    #expect(Session.dividers([0.3], panels: 3) == [1.0 / 3, 2.0 / 3], "a panel added by hand since")
    #expect(Session.dividers([0.6, 0.3], panels: 3) == [1.0 / 3, 2.0 / 3])
    #expect(Session.dividers([0.01], panels: 2) == [0.5] && Session.dividers([0.99], panels: 2) == [0.5], "a panel squeezed to nothing")
}

/// A server tab comes back parked: its header says where, one row says ↩ connects, and nothing is connected or counted
/// as a session. Other tabs are as they were; leaving it goes to its local folder.
@MainActor @Test func aServerTabComesBackParked() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    FileManager.default.createFile(atPath: d + "/local.txt", contents: nil)
    let web = SFTPTarget(host: "k13@web1.invalid")
    let saved = [Session.Tab(path: d, cursor: "nginx.conf", server: web, dir: "/etc/nginx"), Session.Tab(path: d, cursor: "local.txt")]
    let panel = PanelViewController(session: saved, index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    try? await Task.sleep(for: .milliseconds(300))   // whatever would list or connect has started by now
    #expect(panel.parked?.target == web && panel.parked?.dir == "/etc/nginx")
    #expect(panel.remote == nil && panel.connecting == nil && panel.busyMessage == nil && panel.remoteTabs.isEmpty)
    #expect(panel.headerText == "🌐 k13@web1.invalid:/etc/nginx")
    #expect(panel.table.numberOfRows == 1 && panel.item(at: 0) == nil && panel.listedItems.isEmpty)
    #expect(panel.parkedHint == "Not connected — ↩ connects to k13@web1.invalid" && panel.statusText.contains("not connected"))
    #expect(panel.sessionTabs == saved, "saved again as it came")
    #expect(panel.targetItems.isEmpty && panel.plainFolder == nil)

    let menu = NSMenu()
    panel.fillMenu(menu, row: 0)
    #expect(menu.items.map(\.title) == ["Connect"], "the folder's menu would act on the local folder behind it")

    panel.switchTab(by: 1)   // a local tab: as before, its cursor back
    await waitUntil { panel.currentName == "local.txt" }
    #expect(panel.parked == nil && panel.currentName == "local.txt")
    panel.switchTab(by: 1)
    await waitUntil { panel.parked != nil }
    #expect(panel.parked?.target == web && panel.remoteTabs.isEmpty && panel.sessionTabs == saved)

    panel.reload()   // ⌘R: still nothing listed
    try? await Task.sleep(for: .milliseconds(300))
    #expect(panel.parked != nil && panel.listedItems.isEmpty && panel.table.numberOfRows == 1)
    panel.navigate(to: d + "/gone")   // a way out that fails: it stays parked, the error said
    await waitUntil { panel.statusText.contains("gone") }
    try? await Task.sleep(for: .milliseconds(300))
    #expect(panel.parked != nil && panel.path == d && panel.statusText.contains("gone"))
    // Off it and straight back, before the local tab's listing is in: each tab keeps its own.
    panel.switchTab(by: 1)
    panel.switchTab(by: 1)
    await waitUntil { panel.parked != nil }
    try? await Task.sleep(for: .milliseconds(300))
    #expect(panel.parked?.target == web && panel.sessionTabs == saved)
    panel.goUp()   // ⌘↑ (any way out): the tab's own folder
    await waitUntil { panel.parked == nil && panel.listedItems.count == 1 }
    #expect(panel.path == d && panel.remote == nil && panel.listedItems.map(\.name) == ["local.txt"])
}

/// A parked root tab says root (#), and so does what's saved again.
@MainActor @Test func aRootTabComesBackParkedAsRoot() async {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let panel = PanelViewController(session: [Session.Tab(path: d, server: SFTPTarget(host: "k13@web1.invalid"), root: true, dir: "/etc")],
                                    index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    #expect(panel.parked?.target.sudo == true && panel.headerText.hasSuffix(":/etc #") && panel.statusText.hasPrefix("#"))
    #expect(panel.sessionTabs.first?.root == true)
}

/// A parked tab keeps no connection alive: the app ends a master that only a parked tab is on.
@MainActor @Test func aParkedTabIsNoSession() {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let web = SFTPTarget(host: "k13@web1.invalid")
    let app = AppDelegate()
    app.panels = [PanelViewController(session: [Session.Tab(path: d, server: web, dir: "/")], index: 0, showHidden: false),
                  PanelViewController(tabs: [d], index: 0, showHidden: false)]
    app.panels.forEach { $0.loadViewIfNeeded() }
    defer { app.panels.forEach { $0.shutdown() } }
    #expect(app.idleServers([web]) == [web])
    app.panels.swapAt(0, 1)   // %D in a command: never the local folder behind the other, parked panel
    #expect(app.shellContext.otherDir == nil)
}

/// A folder over 5000 names (sorted off the main thread) comes back with the cursor on its saved name.
@MainActor @Test func theCursorComesBackInABigFolder() async {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for i in 0..<(PanelViewController.sortOnMain + 1000) { FileManager.default.createFile(atPath: d + String(format: "/f%05d", i), contents: nil) }
    let panel = PanelViewController(session: [Session.Tab(path: d, cursor: "f04321")], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.listedItems.count == PanelViewController.sortOnMain + 1000 && panel.currentName != nil }
    #expect(panel.currentName == "f04321")
    #expect(panel.sessionTabs.first?.cursor == "f04321")
}

/// On a parked tab only what doesn't touch its files runs; the rest says ↩ connects. Every id named there is a command.
@MainActor @Test func aParkedTabRunsOnlyWhatLeavesItsFilesAlone() {
    for id in ["open", "open.inside", "go.home", "go.connect", "go.path", "go.bookmark", "tab.new", "tab.next", "view.hidden", "view.refresh",
               "panel.switch", "panel.focus2", "admin.rootPanel", "admin.sudoTouchID", "app.palette", "server.services"] {
        #expect(AppDelegate.runsParked(id), "\(id)")
    }
    for id in ["file.copy", "file.move", "file.mkdir", "file.new", "file.delete", "file.edit", "edit.pasteMove", "mark.toggle",
               "search", "cmdline.focus", "view.terminal", "go.tree", "usermenu", "admin.mkdir", "git.commit", "panel.same"] {
        #expect(!AppDelegate.runsParked(id), "\(id)")
    }
    let ids = Set(AppDelegate().makeCommands().map(\.id))
    for id in AppDelegate.parkedRuns.union(AppDelegate.parkedRefuses).union(AppDelegate.toOther).union(["panel.focus1", "panel.focus4"]) {
        #expect(ids.contains(id), "\(id)")
    }
}

extension ServerLockTests {
/// ↩ on a parked tab of a locked server asks for Touch ID first; refused, it stays parked. Then it connects, the cursor
/// on its saved name; a root tab as root.
@Test func returnOnAParkedTabConnects() async throws {
    var local = SavedServer(address: "localhost")!
    local.locked = true
    local.name = "k13 box"
    var asked = 0, answer = false
    ServerLock.servers = { [local] }
    ServerLock.authenticate = { _ in asked += 1; return answer }
    defer { ServerLock.servers = { [] }; ServerLock.relock() }
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    FileManager.default.createFile(atPath: d + "/b.conf", contents: nil)
    FileManager.default.createFile(atPath: d + "/a.conf", contents: nil)
    let panel = PanelViewController(session: [Session.Tab(path: d, cursor: "b.conf", server: .local(), dir: d)], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    func settle() async { for _ in 0..<250 where panel.busyMessage != nil { try? await Task.sleep(for: .milliseconds(20)) } }
    #expect(panel.parkedHint == "Not connected — ↩ connects to k13 box", "a saved server by its name")
    panel.openCursor(intoPackage: false)
    await settle()
    #expect(asked == 1 && panel.remote == nil && panel.parked != nil)
    answer = true
    panel.openCursor(intoPackage: false)
    await waitUntil { panel.remote != nil && panel.currentName != nil }
    #expect(asked == 2 && panel.parked == nil && panel.remote?.dir == d && panel.currentName == "b.conf")
    #expect(panel.remoteTabs.count == 1)

    let root = SFTPTarget.local(sudo: try fakeSudo(in: d))
    let rootPanel = PanelViewController(session: [Session.Tab(path: d, server: root, root: true, dir: d)], index: 0, showHidden: false)
    rootPanel.loadViewIfNeeded()
    defer { rootPanel.shutdown() }
    rootPanel.openCursor(intoPackage: false)
    await waitUntil { rootPanel.remote != nil }
    #expect(rootPanel.remote?.target == root.persisting(60) && rootPanel.remote?.target.sudo == true, "a locked server's linger (D-081)")
}

/// Enable Touch ID for sudo: asks, then writes sudo_local from the template with pam_tid uncommented — the command is
/// the one write to /etc/pam.d/sudo_local and nothing else. On already: says so, asks nothing. Cancel: nothing runs.
@Test func touchIDForSudoAsksThenWritesSudoLocalOnly() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let template = "# sudo_local: local config file which survives system update and is included for sudo\n"
        + "# uncomment following line to enable Touch ID for sudo\n#auth       sufficient     pam_tid.so\n"
    try Data(template.utf8).write(to: URL(fileURLWithPath: d + "/sudo_local.template"))
    var asked: [(String, [String], Int?)] = [], ran: [String] = []
    let (dir, admin) = (AppDelegate.pamDir, AppDelegate.runAsAdmin)
    AppDelegate.pamDir = d
    AppDelegate.runAsAdmin = { command in   // the real command, run by sh on the copy's sudo_local instead of /etc's
        ran.append(command)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command.replacingOccurrences(of: SudoTouchID.file, with: d + "/sudo_local")]
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? .ok : .failed("exit \(p.terminationStatus)")
    }
    defer { AppDelegate.pamDir = dir; AppDelegate.runAsAdmin = admin; AppDelegate.answering = nil }
    let app = AppDelegate()
    app.panels = [PanelViewController(tabs: [d], index: 0, showHidden: false), PanelViewController(tabs: [d], index: 0, showHidden: false)]
    app.panels.forEach { $0.loadViewIfNeeded() }
    defer { app.panels.forEach { $0.shutdown() } }

    AppDelegate.answering = { m, b, def in asked.append((m, b, def)); return 1 }   // Cancel
    app.enableSudoTouchID()
    await waitUntil { asked.count == 1 }
    try? await Task.sleep(for: .milliseconds(100))
    #expect(asked.first?.0 == "Let sudo in Terminal use Touch ID?" && asked.first?.1 == ["Enable", "Cancel"] && asked.first?.2 == nil,
            "↩ is Enable, ⎋ Cancel")
    #expect(ran.isEmpty)

    AppDelegate.answering = { m, b, def in asked.append((m, b, def)); return 0 }   // Enable
    app.enableSudoTouchID()
    await waitUntil { app.panels[0].statusText.contains("Touch ID for sudo is on") }
    #expect(app.panels[0].statusText == "Touch ID for sudo is on — new Terminal windows use it")
    let on = template.replacingOccurrences(of: "\n#auth", with: "\nauth")
    try #require(ran.count == 1)
    #expect(ran[0] == SudoTouchID.command(writing: on) && ran[0].components(separatedBy: "/etc/").count == 3, "sudo_local, and only it")
    #expect(try String(contentsOfFile: d + "/sudo_local", encoding: .utf8) == on)

    app.panels[0].flash("")
    app.enableSudoTouchID()
    await waitUntil { app.panels[0].statusText == "Touch ID for sudo is already on" }
    #expect(app.panels[0].statusText == "Touch ID for sudo is already on" && asked.count == 2 && ran.count == 1)

    // A symlink (managed by something else): left alone, nothing asked.
    try FileManager.default.removeItem(atPath: d + "/sudo_local")
    try FileManager.default.createSymbolicLink(atPath: d + "/sudo_local", withDestinationPath: d + "/sudo_local.template")
    app.enableSudoTouchID()
    await waitUntil { app.panels[0].statusText.contains("symlink") }
    #expect(app.panels[0].statusText.contains("is a symlink") && asked.count == 2 && ran.count == 1)
}

/// A Cancel that isn't ↩ still answers ⎋.
@MainActor @Test func cancelKeepsEscapeBesideAnotherDefault() {
    let a = AppDelegate.alert("?", info: "", ["Enable", "Cancel"], default: 0)
    #expect(a.buttons.map(\.keyEquivalent) == ["\r", "\u{1b}"])
}
}
