import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

@Test func sidebarAutoHidesBelow360AndReturnsFrom400PerPanel() {
    func hidden(_ w: CGFloat, panels: Int = 2, was: Bool) -> Bool {
        SidebarRule.autoHidden(windowWidth: w, sidebarWidth: 200, panels: panels, hidden: was)
    }
    #expect(!hidden(920, was: false))          // 360 per panel: stays
    #expect(hidden(919, was: false))
    #expect(hidden(999, was: true))            // 399.5: still hidden (hysteresis)
    #expect(!hidden(1000, was: true))          // 400: back
    #expect(hidden(1200, panels: 3, was: false) && hidden(1200, panels: 4, was: false))
    #expect(!hidden(1800, panels: 4, was: true))
}

@Test @MainActor func sidebarKeyHasItsOwnLayer() {
    let l = KeyBarModel.layers(AppDelegate().makeCommands()).first { $0.mods == [.control, .command] }
    #expect(l?.slots.map(\.key) == ["⌃⌘K", "⌃⌘S"])
    #expect(l?.slots.map(\.id) == ["go.connect", "view.sidebar"])   // SFTP sits next to the sidebar; ⌘K is SSH
}

@Test func sidebarSectionsFromAppData() {
    let s = SidebarModel.sections(bookmarks: ["/a", "/b"], frecent: ["/b", "/c", "/d", "/a", "/e", "/f", "/g", "/h"],
                                  volumes: [Volume(path: "/", name: "Macintosh HD", free: 1_000_000_000, ejectable: false),
                                            Volume(path: "/Volumes/USB", name: "USB", free: nil, ejectable: true)],
                                  servers: ServerList(), tags: ["work", "home"])
    #expect(s.map(\.id) == ["fav", "freq", "loc", "servers", "tags"])
    #expect(s[0].places == [.folder("/a"), .folder("/b")])
    #expect(s[1].places == ["/c", "/d", "/e", "/f", "/g"].map(Place.folder), "top 5, favorites left out")
    #expect(s[2].places == [.volume(path: "/", name: "Macintosh HD", free: ByteCountFormatter().string(fromByteCount: 1_000_000_000), ejectable: false),
                            .volume(path: "/Volumes/USB", name: "USB", free: "", ejectable: true)])
    #expect(s[3].places == [.connect])
    #expect(s[4].places == [.tagColors, .tag("work"), .tag("home")])
    #expect(SidebarModel.tagColors.count == 7)
}

/// Pins, then the latest used up to 5 rows (always one more than the pins), open servers even past that, then saved
/// and ~/.ssh/config hosts in the rows still free — listed as pins, saved, config, then the rest by name (R9). One row
/// per user@host:port, whatever it was typed as.
@Test func serverRowsArePinsThenLatestThenSavedThenConfig() {
    var prod = SavedServer(address: "deploy@10.0.0.5")!
    prod.name = "prod"
    let ssh = ServerSession(id: UUID(), kind: .ssh, target: prod.target)
    let sftp = ServerSession(id: UUID(), kind: .sftp, target: SFTPTarget(host: "deploy@10.0.0.5", port: 22), dir: "/var")
    var list = ServerList(saved: [prod], recents: ["me@a:/x", "smb://nas/share", "deploy@10.0.0.5", "me@a", "b", "c"],
                          config: ["db", "b"], pins: ["ssh://me@p:2222"])
    func titles(_ l: ServerList) -> [String] { SidebarModel.serverRows(l).map(\.title) }

    #expect(titles(list) == ["me@p", "prod", "b", "c", "me@a"], "pin, then recents by key (no mounts); 5 rows")
    let rows = SidebarModel.serverRows(list)
    #expect(rows[0].pinned && rows[0].target == SFTPTarget(host: "me@p", port: 2222) && rows[0].address == "ssh://me@p:2222")
    #expect(rows[1].saved == prod && rows[1].target == prod.target, "typed, but it's the saved server's row")

    list.recents = ["c"]
    list.sessions = [ssh, sftp]
    let open = SidebarModel.serverRows(list)
    #expect(open.map(\.title) == ["me@p", "prod", "db", "b", "c"], "sessions after recents, then saved / config fill up")
    #expect(open[1].ssh == [ssh] && open[1].sftp == [sftp], "port 22 or none: same server, one row")
    #expect(Place.server(open[1]).stands(for: sftp.id.uuidString) && Place.server(open[1]).selectable && !Place.server(open[4]).selectable)

    // Five pins leave one row for the latest; a server with sessions still shows.
    list.pins = ["p1", "p2", "p3", "p4", "p5"]
    list.recents = ["c", "d"]
    #expect(titles(list) == ["p1", "p2", "p3", "p4", "p5", "prod", "c"])
}

@Test func savedServerFromAddressAndBack() throws {
    let s = try #require(SavedServer(address: "sftp://me@nas:2222/share"))
    #expect(s.host == "nas" && s.user == "me" && s.port == 2222 && s.startDir == "/share" && s.name.isEmpty)
    #expect(s.target == SFTPTarget(host: "me@nas", port: 2222) && s.title == "me@nas")
    #expect(SavedServer(address: "prod")?.user == nil && SavedServer(address: "smb://nas/share") == nil)

    let data = try JSONEncoder().encode([s])
    #expect(try JSONDecoder().decode([SavedServer].self, from: data) == [s])
    // Hand-written: only the host is required.
    let hand = try JSONDecoder().decode([SavedServer].self, from: Data(#"[{"host": "box", "port": 22}]"#.utf8))
    #expect(hand.first?.host == "box" && hand.first?.port == 22 && hand.first?.name == "")
}

@Test func savedServerRejectsWhatSshWouldReadAsAnOption() {
    func problem(host: String = "h", user: String? = nil, port: Int? = nil) -> String? {
        var s = SavedServer()
        s.host = host
        s.user = user
        s.port = port
        return s.problem
    }
    #expect(problem() == nil && problem(user: "me", port: 22) == nil)
    #expect(problem(host: "") != nil)
    #expect(problem(host: "-oProxyCommand=touch /tmp/x") != nil)
    #expect(problem(host: "a b") != nil && problem(host: "me@h") != nil)
    #expect(problem(user: "-oProxyCommand=x") != nil && problem(user: "") != nil && problem(user: "a b") != nil)
    #expect(problem(port: 0) != nil && problem(port: 65536) != nil)
    var keyed = SavedServer(address: "me@nas")!
    keyed.identityFile = "/no/such/key"
    #expect(keyed.problem != nil)
    keyed.identityFile = "/etc/hosts"
    #expect(keyed.problem == nil && keyed.target == SFTPTarget(host: "me@nas", identity: "/etc/hosts"))
}

/// The askpass script answers a password prompt from the FIFO, without its dialog.
@Test func askpassAnswersAPasswordPromptFromTheFifo() throws {
    let t = SFTPTarget(host: "me@nas")
    SFTP.password = { $0 == t ? "s3cret" : nil }
    defer { SFTP.password = nil }
    let answer = try SFTP.withPassword(t) { extra in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSHAskpass.env["SSH_ASKPASS"]!)
        p.arguments = ["me@nas's password: "]
        p.environment = SSHAskpass.env.merging(extra) { $1 }
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { p.terminate() }   // the dialog came up instead
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    #expect(answer == "s3cret")
}

/// ServerLock's state is static: these run one at a time.
@Suite(.serialized) @MainActor struct ServerLockTests {

/// Who's asked for Touch ID: every route to a locked server's user@host:port, once per grace period.
@Test func lockedServerAsksOncePerGracePeriod() async {
    var prod = SavedServer(address: "deploy@10.0.0.5")!
    prod.locked = true
    let open = SavedServer(address: "nas")!
    var asked: [String] = [], answer = false
    ServerLock.servers = { [prod, open] }
    ServerLock.authenticate = { asked.append($0); return answer }
    defer { ServerLock.servers = { [] }; ServerLock.relock() }

    #expect(await ServerLock.authorize(open.target) && asked.isEmpty)
    #expect(await !ServerLock.authorize(SFTPTarget(host: "deploy@10.0.0.5", port: 22)), "typed by hand: same server")
    #expect(asked == ["connect to “deploy@10.0.0.5”"] && ServerLock.needsUnlock(prod.target))
    #expect(await !ServerLock.authorize(prod, "edit"), "refused: still locked")
    answer = true
    #expect(await ServerLock.authorize(prod, "edit") && !ServerLock.needsUnlock(prod.target))
    #expect(await ServerLock.authorize(prod.target) && asked.count == 3, "unlocked: no more asking")
    #expect(prod.target.persist == 60 && open.target.persist == nil)
    ServerLock.relock()   // screen locked
    #expect(ServerLock.needsUnlock(prod.target))
    // An unlocked server saved at the same address would hand out the locked one's password: it asks too.
    var twin = SavedServer(address: "deploy@10.0.0.5")!
    twin.name = "twin"
    answer = false
    #expect(await !ServerLock.authorize(twin, "edit") && asked.last == "edit “deploy@10.0.0.5”")
}

/// A panel connecting to a locked server stays where it is when Touch ID is refused; folders of an open one don't ask.
@Test func panelDoesNotConnectToALockedServerUnasked() async throws {
    var local = SavedServer(address: "localhost")!
    local.locked = true
    var asked = 0, answer = false
    ServerLock.servers = { [local] }
    ServerLock.authenticate = { _ in asked += 1; return answer }
    defer { ServerLock.servers = { [] }; ServerLock.relock() }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dfm-lock-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    func settle() async { for _ in 0..<200 where panel.busyMessage != nil { try? await Task.sleep(for: .milliseconds(20)) } }
    panel.loadRemote(.local(), dir: dir, select: nil)
    await settle()
    #expect(asked == 1)
    #expect(panel.remote == nil)
    answer = true
    panel.loadRemote(.local(), dir: dir, select: nil)
    await settle()
    #expect(asked == 2)
    #expect(panel.remote?.dir == dir)
    ServerLock.relock()
    panel.loadRemote(.local(), dir: dir + "/sub", select: nil)
    for _ in 0..<200 where panel.remote?.dir != dir + "/sub" { try? await Task.sleep(for: .milliseconds(20)) }
    #expect(asked == 2, "already open here: not asked again")
    #expect(panel.remote?.dir == dir + "/sub")
}
}

/// The real login keychain: what Save writes, the login reads; Delete leaves nothing.
@Test func passwordRoundTripsThroughTheKeychain() {
    let t = SFTPTarget(host: "me@dfm-test-\(UUID().uuidString).invalid", port: 2222)
    defer { SSHPasswords.set(nil, for: t) }
    #expect(SSHPasswords.get(t) == nil)
    #expect(SSHPasswords.set("pä ss", for: t) == errSecSuccess)
    #expect(SSHPasswords.get(SFTPTarget(host: t.host, port: 2222, identity: "/k", persist: 60)) == "pä ss", "same user@host:port")
    #expect(SSHPasswords.get(SFTPTarget(host: t.host)) == nil, "other port")
    #expect(SSHPasswords.set("new", for: t) == errSecSuccess && SSHPasswords.get(t) == "new")
    SSHPasswords.set(nil, for: t)
    #expect(SSHPasswords.get(t) == nil)
}

/// Saving a server: a password never follows an address change; typed replaces, Forget removes, nothing keeps.
@MainActor @Test func passwordDoesNotFollowAnAddressChange() {
    let app = AppDelegate()
    func server(_ host: String) -> SavedServer { SavedServer(address: "me@\(host)")! }
    let (h1, h2) = ("dfm-a-\(UUID().uuidString).invalid", "dfm-b-\(UUID().uuidString).invalid")
    var a = server(h1)
    defer { [h1, h2].forEach { SSHPasswords.set(nil, for: server($0).target) } }
    SSHPasswords.set("secret", for: a.target)
    app.savedServers = [a]

    app.storePassword(old: a, new: a, typed: "", forget: false)
    #expect(SSHPasswords.get(a.target) == "secret", "nothing typed: kept")
    var moved = a
    moved.host = h2
    app.savedServers = [moved]
    app.storePassword(old: a, new: moved, typed: "", forget: false)
    #expect(SSHPasswords.get(moved.target) == nil, "not carried to the new address")
    #expect(SSHPasswords.get(a.target) == nil, "and gone from the old one: no server uses it")

    // A twin at the old address keeps it; typed goes to the new address only.
    SSHPasswords.set("secret", for: a.target)
    let twin = server(h1)
    app.savedServers = [moved, twin]
    app.storePassword(old: a, new: moved, typed: "other", forget: false)
    #expect(SSHPasswords.get(a.target) == "secret" && SSHPasswords.get(moved.target) == "other")
    // Moved with Forget ticked: the new address's password (another server's) stays.
    app.storePassword(old: moved, new: twin, typed: "", forget: true)
    #expect(SSHPasswords.get(twin.target) == "secret")
    a = twin
    app.storePassword(old: a, new: a, typed: "", forget: true)
    #expect(SSHPasswords.get(a.target) == nil, "forgotten")
}

extension ServerLockTests {
/// A locked server's address stays out of the recents; others go first in line.
@Test func lockedServerIsNotRemembered() {
    var locked = SavedServer(address: "me@dfm-locked.invalid")!
    locked.locked = true
    ServerLock.servers = { [locked] }
    let saved = UserDefaults.standard.stringArray(forKey: "recentServers")
    defer { ServerLock.servers = { [] }; UserDefaults.standard.set(saved, forKey: "recentServers") }
    UserDefaults.standard.set(["old"], forKey: "recentServers")
    let app = AppDelegate()
    app.remember("me@dfm-locked.invalid:/etc")
    app.remember("me@dfm-locked.invalid:22")   // a path that looks like a port: same server
    app.remember("me@nas")
    #expect(UserDefaults.standard.stringArray(forKey: "recentServers") == ["me@nas", "old"])
}
}

/// ⌘E in a picker edits the highlighted row (when it can be edited) instead of running it.
@MainActor @Test func pickerCommandEEditsTheHighlightedRow() async {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    var ran: [String] = []
    Picker.show(over: window, placeholder: "", items: [
        Picker.Item(title: "plain") { ran.append("run plain") },
        Picker.Item(title: "mine", edit: { ran.append("edit mine") }) { ran.append("run mine") },
    ])
    let panel = Picker.current!.panel
    func cmdE() -> Bool {
        panel.performKeyEquivalent(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                          windowNumber: panel.windowNumber, context: nil, characters: "e",
                                                          charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14)!)
    }
    #expect(!cmdE(), "first row: nothing to edit")
    (panel.contentView?.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)?.selectRowIndexes([1], byExtendingSelection: false)
    #expect(cmdE() && Picker.current == nil, "edits and closes")
    await Task.yield()
    for _ in 0..<50 where ran.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(ran == ["edit mine"])
}

/// P9: a network share's row comes from the kernel's figures (MNT_NOWAIT), never from a statfs or getattrlist on it:
/// on a dead share those never return, and the sidebar would stop refreshing for every volume. Local disks are read.
@Test func networkVolumesAreNotAsked() throws {
    let dead = SidebarModel.Mount(path: "/Volumes/dead-\(UUID().uuidString)", type: "smbfs", local: false, free: 4096 * 1000, total: 1 << 30)
    let v = SidebarModel.volumes([dead])
    #expect(v == [Volume(path: dead.path, name: (dead.path as NSString).lastPathComponent, free: 4096 * 1000, ejectable: true)])

    let mounts = SidebarModel.mounts()
    #expect(!mounts.contains { $0.path == "/dev" }, "hidden mounts stay out, as with .skipHiddenVolumes")
    let root = try #require(SidebarModel.volumes(mounts).first { $0.path == "/" })
    let rv = try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey])
    #expect(root.name == rv.volumeName && (root.free ?? 0) > 0 && !root.ejectable)
}
