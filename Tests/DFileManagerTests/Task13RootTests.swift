import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 13: a server panel as root (`SFTPTarget.sudo`).

/// A stand-in for a server's sudo that runs what follows `-n --` (DFMCore's tests have the logging one).
func fakeSudo(in dir: String) throws -> String {
    let path = dir + "/sudo"
    try Data("#!/bin/sh\n[ \"$1\" = -n ] && [ \"$2\" = -- ] || exit 2\nexec \"$3\"\n".utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, 0o755)
    return path
}

/// Dragged or copied out of a root panel, items are its user's: the pasteboard never carries root. A drag from a root
/// panel of this app is that panel's again at the drop — known from the drag's source, not from the pasteboard.
@Test @MainActor func rootItemsOnAPasteboardAreTheUsers() {
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))
    defer { pb.releaseGlobally() }
    let root = SFTPTarget(host: "deploy@web").asRoot()
    pb.clearContents()
    pb.writeObjects(TransferItems(from: .sftp(root), paths: ["/etc/hosts"]).pasteboardWriters)
    let items = TransferItems(pb)!
    #expect(items == TransferItems(from: .sftp(root.asRoot(false)), paths: ["/etc/hosts"]))
    #expect(PanelViewController.dropped(items, from: root) == TransferItems(from: .sftp(root), paths: ["/etc/hosts"]))
    #expect(PanelViewController.dropped(items, from: nil) == items, "from another app, or ⌘V: the user's")
    #expect(PanelViewController.dropped(items, from: SFTPTarget(host: "deploy@db").asRoot()) == items, "another server's root panel")
    #expect(PanelViewController.dropped(items, from: root.asRoot(false)) == items)
}

/// Reopen as Root / as User: ⌃⌘R / ⌃⇧⌘R, in the Server menu and ⌘⇧P (keymap.json can rebind them); "Open SFTP
/// as Root" is in a server's sidebar menu.
@MainActor @Test func rootPanelCommandsAreThere() {
    let commands = AppDelegate().makeCommands()
    for (id, title, key) in [("admin.rootPanel", "Reopen as Root", "⌃⌘R"), ("admin.userPanel", "Reopen as User", "⌃⇧⌘R")] {
        let c = commands.first { $0.id == id }
        #expect(c?.title == title && c?.menu == "Server" && c?.keys.map(\.display) == [key])
        #expect(commands.filter { $0.keys.contains { $0.display == key } }.count == 1, "\(key) is theirs alone")
        #expect(c?.keys.first?.takenByMacOS == nil)
    }
    let found = HeaderSearchModel.results("as root", commands: commands, folders: [], files: [], recent: [])
    #expect(found.flatMap(\.hits).contains { if case .command(let id) = $0.target { id == "admin.rootPanel" } else { false } }, "\(found)")
}

/// A root panel's file history is its server's: the same folder as the user's panel, root's saves next to theirs.
@Test func rootSavesKeepVersionsInTheServersFolder() throws {
    let root = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-rhist-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: root) }
    let h = ServerHistory(root: root), user = SFTPTarget(host: "me@web", port: 2222)
    #expect(h.folder(user.asRoot()) == h.folder(user))
    #expect(h.keep(Data("v".utf8), SFTPClient.Attrs(kind: .file, size: 1, mtime: 0, mode: nil), of: user.asRoot(), "/etc/hosts") == nil)
    #expect(h.versions(of: user, "/etc/hosts").count == 1)
}

extension ServerLockTests {
/// The header says root: "root@host:/dir #"; on a production server "🟣 PROD" in front, as for its user. Reopened as
/// the user: as before. The status line says SFTP, the header and the tab where (phase 4, R-28). (Its colors: by eye.)
@Test func rootPanelHeaderSaysRoot() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-rhead-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let root = SFTPTarget.local(sudo: try fakeSudo(in: dir))
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    func open(_ t: SFTPTarget) async {
        panel.loadRemote(t, dir: dir, select: nil)
        for _ in 0..<250 where panel.remote?.target != t || panel.busyMessage != nil { try? await Task.sleep(for: .milliseconds(20)) }
    }
    await open(root)
    #expect(panel.headerText == "root@localhost:\(dir)" && panel.headerChips == [.root])
    #expect(panel.statusText == "1 item" && panel.statusChipWords.last == "SFTP", "\(panel.statusText) \(panel.statusChipWords)")
    #expect(SavedServer.title(root, "/etc/hosts") == "root@localhost:/etc/hosts" && Chip.of(root) == [.root], "its editor's title")
    var prod = SavedServer(address: "localhost")!
    prod.prod = true
    ServerLock.servers = { [prod] }
    defer { ServerLock.servers = { [] } }
    panel.showPath()
    #expect(panel.headerText == "root@localhost:\(dir)" && panel.headerChips == [.prod, .root])
    await open(root.asRoot(false))
    #expect(panel.headerText == "localhost:\(dir)" && panel.headerChips == [.prod])
    ServerLock.servers = { [] }
    panel.showPath()
    #expect(panel.headerText == "localhost:\(dir)" && panel.headerChips.isEmpty)
}

/// A sudo password sudo took is kept for the server's next sessions (root or not: one user@host:port), not asked again;
/// a refused one goes before the next ask; the screen locking (relock) or Disconnect forgets it.
@Test func sudoPasswordsAreKeptWhileInUse() async {
    let t = SFTPTarget(host: "me@web").asRoot()
    var asked: [Bool] = []
    let was = SudoPasswords.ask
    SudoPasswords.ask = { _, wrong in asked.append(wrong); return ("typed", false) }
    defer { SudoPasswords.ask = was; SudoPasswords.forget() }
    #expect(await Blocking.run { SudoPasswords.password(t, wrong: false) } == "typed" && asked == [false])
    #expect(await Blocking.run { SudoPasswords.password(t, wrong: false) } == "typed" && asked == [false, false], "not taken yet: asked again")
    SudoPasswords.taken(t, "typed")
    #expect(await Blocking.run { SudoPasswords.password(t, wrong: false) } == "typed" && asked.count == 2)
    #expect(await Blocking.run { SudoPasswords.password(SFTPTarget(host: "me@web", port: 22).asRoot(), wrong: false) } == "typed" && asked.count == 2)
    _ = await Blocking.run { SudoPasswords.password(t, wrong: true) }
    #expect(asked == [false, false, true], "refused: asked")
    _ = await Blocking.run { SudoPasswords.password(t, wrong: false) }
    #expect(asked.count == 4, "the refused one was forgotten, not given again")
    SudoPasswords.taken(t, "typed")
    ServerLock.relock()
    _ = await Blocking.run { SudoPasswords.password(t, wrong: false) }
    #expect(asked.count == 5, "screen locked: forgotten")
    SudoPasswords.taken(t, "typed")
    await AppDelegate().disconnectNow(SudoPasswords.key(t))
    _ = await Blocking.run { SudoPasswords.password(t, wrong: false) }
    #expect(asked.count == 6, "disconnected: forgotten")
}

/// "Save in Keychain": there once sudo took it, an item apart from the ssh password (neither reads the other); used when
/// memory forgot it; a refused one goes from there; a saved server's address change or deletion takes it too.
@Test func sudoPasswordInTheKeychain() async {
    let host = "me@dfm-sudo-\(UUID().uuidString).invalid"
    let t = SFTPTarget(host: host).asRoot()
    defer { SSHPasswords.set(nil, for: t, sudo: true); SSHPasswords.set(nil, for: t); SudoPasswords.forget() }
    var answers: [(password: String, save: Bool)?] = [("pw1", true)]
    let was = SudoPasswords.ask
    SudoPasswords.ask = { _, _ in answers.isEmpty ? nil : answers.removeFirst() }
    defer { SudoPasswords.ask = was }
    #expect(await Blocking.run { SudoPasswords.password(t, wrong: false) } == "pw1")
    #expect(SSHPasswords.get(t, sudo: true) == nil, "not before sudo took it")
    SudoPasswords.taken(t, "pw1")
    #expect(SSHPasswords.get(t, sudo: true) == "pw1" && SSHPasswords.get(t) == nil)
    SSHPasswords.set("ssh-pw", for: t)
    #expect(SSHPasswords.get(t) == "ssh-pw" && SSHPasswords.get(t, sudo: true) == "pw1", "two items")
    SudoPasswords.forget()   // the screen locked
    #expect(await Blocking.run { SudoPasswords.password(t, wrong: false) } == "pw1" && answers.isEmpty, "from the Keychain, not asked")
    answers = [("pw2", false)]
    #expect(await Blocking.run { SudoPasswords.password(t, wrong: true) } == "pw2")
    #expect(SSHPasswords.get(t, sudo: true) == nil && SSHPasswords.get(t) == "ssh-pw", "refused: out of the Keychain; the ssh one stays")
    SudoPasswords.taken(t, "pw2")
    #expect(SSHPasswords.get(t, sudo: true) == nil, "not ticked: not saved")

    SSHPasswords.set("pw3", for: t, sudo: true)
    let app = AppDelegate()
    let a = SavedServer(address: host)!
    var moved = a
    moved.host = "dfm-elsewhere-\(UUID().uuidString).invalid"
    app.savedServers = [moved]
    app.storePassword(old: a, new: moved, typed: "", forget: false)
    #expect(SSHPasswords.get(t, sudo: true) == nil && SSHPasswords.get(t) == nil, "the saved server moved: both go")
}

/// The server sheet's "Forget the saved sudo password" removes it where it was — from the Keychain and from memory —
/// and leaves the ssh password alone.
@Test func serverSheetForgetsTheSudoPassword() async {
    let host = "me@dfm-fsudo-\(UUID().uuidString).invalid"
    let s = SavedServer(address: host)!
    defer { SSHPasswords.set(nil, for: s.target); SSHPasswords.set(nil, for: s.target, sudo: true); SudoPasswords.forget() }
    SSHPasswords.set("ssh-pw", for: s.target)
    SSHPasswords.set("sudo-pw", for: s.target, sudo: true)
    SudoPasswords.taken(s.target.asRoot(), "sudo-pw")
    let app = AppDelegate()
    app.savedServers = [s]
    app.storePassword(old: s, new: s, typed: "", forget: false, forgetSudo: false)
    #expect(SSHPasswords.get(s.target, sudo: true) == "sudo-pw", "not ticked: kept")
    app.storePassword(old: s, new: s, typed: "", forget: false, forgetSudo: true)
    #expect(SSHPasswords.get(s.target, sudo: true) == nil && SSHPasswords.get(s.target) == "ssh-pw")
    var asked = 0
    let was = SudoPasswords.ask
    SudoPasswords.ask = { _, _ in asked += 1; return nil }
    defer { SudoPasswords.ask = was }
    #expect(await Blocking.run { SudoPasswords.password(s.target.asRoot(), wrong: false) } == nil && asked == 1, "gone from memory too")
}

/// A locked server's root panel asks for Touch ID as its user's does (same user@host:port); refused, the panel stays.
@Test func rootPanelOfALockedServerAsks() async throws {
    var local = SavedServer(address: "localhost")!
    local.locked = true
    var asked = 0, answer = false
    ServerLock.servers = { [local] }
    ServerLock.authenticate = { _ in asked += 1; return answer }
    defer { ServerLock.servers = { [] }; ServerLock.relock() }
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-rootlock-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let root = SFTPTarget.local(sudo: try fakeSudo(in: dir))
    #expect(ServerLock.needsUnlock(root) && ServerLock.server(for: root)?.id == local.id)

    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    func settle() async { for _ in 0..<250 where panel.busyMessage != nil { try? await Task.sleep(for: .milliseconds(20)) } }
    panel.loadRemote(root, dir: dir, select: nil)
    await settle()
    #expect(asked == 1 && panel.remote == nil)
    answer = true
    panel.loadRemote(root, dir: dir, select: nil)
    await settle()
    #expect(asked == 2 && panel.remote?.target == root.persisting(60), "a locked server's linger (D-081)")
}
}

/// Connecting, the panel says a server is in use all along — connecting, then showing it — never neither: the app ends
/// the connections nobody uses (`releaseIdleServers`), and stopped this one right after its first listing, so the next
/// session (a save, a preview, Reopen as Root) logged in again.
@Test @MainActor func aServerConnectedIsNeverUnusedOnTheWay() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-inuse-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    var unused = 0, calls = 0
    panel.onSessionsChange = { [unowned panel] in
        calls += 1
        if panel.connecting == nil && panel.remoteTabs.isEmpty { unused += 1 }
    }
    panel.loadRemote(.local(), dir: dir, select: nil)
    for _ in 0..<250 where panel.remote == nil || panel.connecting != nil { try? await Task.sleep(for: .milliseconds(20)) }
    #expect(panel.remote?.target == .local() && calls >= 2 && unused == 0, "\(calls) changes, \(unused) with nothing in use")
}

/// On a root panel the command line's keys say ⌘E runs as the user, in one hint more (R-31); elsewhere as before.
@Test @MainActor func commandLineSaysWhoseShellOnARootPanel() {
    #expect(AppDelegate.commandLineKeys(root: nil) == AppDelegate.commandLineKeys)
    #expect(AppDelegate.commandLineKeys(root: SFTPTarget(host: "deploy@web").asRoot()).last == KeySlot(key: "", label: "Runs as deploy, not root", id: nil))
    #expect(AppDelegate.commandLineKeys(root: SFTPTarget(host: "web").asRoot()).last?.label == "Runs as your user, not root")
}

/// A save goes over the session of the panel showing that server: from a root panel, no new sudo (where sudo wants a
/// password: no look, no check, no second session). Another server, or no panel on it: a session of its own.
@Test @MainActor func savesRideThePanelsSession() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-rsave-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let fake = dir + "/sudo"
    try Data("#!/bin/sh\necho \"$*\" >> \"$0.log\"\n[ \"$1\" = -n ] || exit 2\nexec \"$3\"\n".utf8).write(to: URL(fileURLWithPath: fake))
    chmod(fake, 0o755)
    let root = SFTPTarget.local(sudo: fake)
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    panel.loadRemote(root, dir: dir, select: nil)
    for _ in 0..<250 where panel.remote?.target != root || panel.connecting != nil { try? await Task.sleep(for: .milliseconds(20)) }
    let kept = try #require(AppDelegate.keptSession(of: root, in: [panel]))
    #expect(AppDelegate.keptSession(of: root.asRoot(false), in: [panel]) == nil && AppDelegate.keptSession(of: root, in: []) == nil)
    let sessions = { (try? String(contentsOfFile: fake + ".log", encoding: .utf8))?.split(separator: "\n").count ?? 0 }
    let before = sessions()
    try Data("old".utf8).write(to: URL(fileURLWithPath: dir + "/f.conf"))
    try Data("new".utf8).write(to: URL(fileURLWithPath: dir + "/l"))
    let attrs = try await Blocking.run {
        try SFTP.session(root, env: [:], cancel: CancelFlag(), on: kept) { c in try c.upload(dir + "/l", to: dir + "/f.conf", baseline: nil) }
    }
    #expect(attrs.size == 3 && FileManager.default.contents(atPath: dir + "/f.conf") == Data("new".utf8))
    #expect(sessions() == before, "no new sudo run for the save")
}
