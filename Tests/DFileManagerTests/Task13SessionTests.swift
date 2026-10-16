import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 13 (В6): what a restart brings back.

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
    #expect(panel.parked != nil)
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
    for id in ["open", "open.inside", "go.home", "go.connect", "go.path", "tab.new", "tab.next", "view.hidden", "view.refresh",
               "panel.switch", "admin.rootPanel", "app.palette", "server.services"] {
        #expect(AppDelegate.runsParked(id), "\(id)")
    }
    for id in ["file.copy", "file.move", "file.mkdir", "file.new", "file.delete", "file.edit", "edit.pasteMove", "mark.toggle",
               "search", "cmdline.focus", "view.terminal", "go.tree", "usermenu", "admin.mkdir", "git.commit", "panel.same"] {
        #expect(!AppDelegate.runsParked(id), "\(id)")
    }
    let ids = Set(AppDelegate().makeCommands().map(\.id))
    for id in ["open", "open.inside", "panel.switch", "panel.add", "panel.close", "admin.rootPanel", "admin.userPanel", "admin.auditLog",
               "usermenu.edit", "validators.edit", "go.tree", "go.linktarget", "view.terminal", "view.dirsizes",
               "server.history"] + AppDelegate.toOther {
        #expect(ids.contains(id), "\(id)")
    }
}

extension ServerLockTests {
/// ↩ on a parked tab of a locked server asks for Touch ID first; refused, it stays parked. Then it connects, the cursor
/// on its saved name; a root tab as root.
@Test func returnOnAParkedTabConnects() async throws {
    var local = SavedServer(address: "localhost")!
    local.locked = true
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
    #expect(rootPanel.remote?.target == root && rootPanel.remote?.target.sudo == true)
}
}
