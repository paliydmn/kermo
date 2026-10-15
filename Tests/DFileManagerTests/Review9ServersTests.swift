import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

/// R9: using a server doesn't move any row: pins, saved servers, ~/.ssh/config hosts in their own order, then the rest
/// by name — whatever was used last.
@Test func serverRowsKeepTheirOrderWhateverWasUsedLast() {
    let web = SavedServer(address: "deploy@web")!
    var list = ServerList(saved: [web], recents: ["c2", "c1", "me@x"], config: ["c1", "c2"], pins: ["p"])
    func titles() -> [String] { SidebarModel.serverRows(list).map(\.title) }
    #expect(titles() == ["p", "deploy@web", "c1", "c2", "me@x"])
    list.recents = ["me@x", "c1", "deploy@web", "c2"]
    #expect(titles() == ["p", "deploy@web", "c1", "c2", "me@x"])
}

/// R9: the production tag is kept with the server in servers.json; older files without it read as not production.
@Test func prodTagIsSavedWithTheServer() throws {
    let plain = try JSONDecoder().decode(SavedServer.self, from: Data(#"{"host": "web"}"#.utf8))
    #expect(!plain.prod)
    var s = plain
    s.prod = true
    #expect(try JSONDecoder().decode(SavedServer.self, from: JSONEncoder().encode(s)).prod)
}

/// R9: a copy asks about production where it goes; a move also where it comes from (the originals go there).
@Test func transferChangesFilesWhereItGoesAndForAMoveWhereItComesFrom() {
    let a = SFTPTarget(host: "a"), b = SFTPTarget(host: "b")
    #expect(AppDelegate.changed(from: .sftp(a), to: .local, move: false).isEmpty)
    #expect(AppDelegate.changed(from: .sftp(a), to: .local, move: true) == [a])
    #expect(AppDelegate.changed(from: .local, to: .sftp(b), move: false) == [b])
    #expect(AppDelegate.changed(from: .sftp(a), to: .sftp(b), move: true) == [a, b])
}

/// R9: a server's name stays whole in a narrow sidebar next to what's open (SSH, SFTP: icons, no words). A name too
/// long for the row is cut, never the icons: nothing goes past the row's end.
@MainActor @Test func serverNameStaysWholeNextToItsButtons() throws {
    func layout(_ title: String, width: CGFloat) throws -> (name: NSTextField, row: NSStackView) {
        let s = SavedServer(address: "root@\(title)")!
        let row = ServerRow(target: s.target, saved: s, title: title,
                            sessions: [ServerSession(id: UUID(), kind: .ssh, target: s.target),
                                       ServerSession(id: UUID(), kind: .sftp, target: s.target, dir: "/etc")])
        let view = try #require(SidebarController().outlineView(NSOutlineView(), viewFor: nil, item: SidebarController.Node(place: .server(row))) as? NSStackView)
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 22))   // the column holds the row to its width
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: cell.leadingAnchor), view.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                                     view.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        cell.layoutSubtreeIfNeeded()
        return (try #require(view.arrangedSubviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == title }), view)
    }
    func fits(_ row: NSStackView, _ width: CGFloat) -> Bool {
        row.arrangedSubviews.allSatisfy { $0.frame.maxX <= width } && row.arrangedSubviews.compactMap { $0 as? ServerChips }
            .allSatisfy { chips in chips.arrangedSubviews.allSatisfy { $0.frame.width >= $0.intrinsicContentSize.width } }
    }
    for width: CGFloat in [140, 180, 220] {
        let (name, row) = try layout("nas-backup", width: width)
        #expect(name.frame.width >= name.intrinsicContentSize.width, "\(width)")
        #expect(row.frame.width == width && fits(row, width), "\(width)")
        let (long, longRow) = try layout("production-db-primary-eu", width: width)
        #expect(long.frame.width < long.intrinsicContentSize.width && fits(longRow, width), "\(width)")
    }
}

extension ServerLockTests {
/// R9: what a change on a production server asks names it (by user@host:port, like a lock); others add nothing.
@Test func prodNoteNamesTheProductionServer() {
    var prod = SavedServer(address: "root@db")!
    prod.prod = true
    ServerLock.servers = { [prod, SavedServer(address: "root@web")!] }
    defer { ServerLock.servers = { [] } }
    #expect(SavedServer.isProd(SFTPTarget(host: "root@db", port: 22)) && !SavedServer.isProd(SFTPTarget(host: "root@web")))
    #expect(SavedServer.prodNote([SFTPTarget(host: "root@web")]).isEmpty)
    #expect(SavedServer.prodNote([SFTPTarget(host: "root@db"), SFTPTarget(host: "root@db")]) == "“root@db” is a production server. ")
}

/// R9 + R23: the editor of a file on a production server says so in its title, as the panel header does.
@Test func prodServerFileEditorTitleSaysProd() {
    var prod = SavedServer(address: "root@db")!
    prod.prod = true
    ServerLock.servers = { [prod] }
    defer { ServerLock.servers = { [] } }
    #expect(SavedServer.title(SFTPTarget(host: "root@db"), "/etc/my.cnf") == "🟣 PROD root@db:/etc/my.cnf")
    #expect(SavedServer.title(SFTPTarget(host: "web"), "/etc/nginx/nginx.conf") == "web:/etc/nginx/nginx.conf")
}

/// R9(c): an editor's first save to a production server asks before it overwrites the file there (until okayed);
/// later ⌘S of that editor, and saves to other servers, don't.
@Test func remoteEditAsksOnceBeforeOverwritingOnProd() {
    var prod = SavedServer(address: "root@db")!
    prod.prod = true
    ServerLock.servers = { [prod] }
    defer { ServerLock.servers = { [] } }
    let attrs = SFTPClient.Attrs(kind: .file, size: 2, mtime: 0, mode: nil)
    let state = AppDelegate.RemoteEdit(baseline: attrs)
    #expect(state.prodNote(SFTPTarget(host: "root@db")) == "“root@db” is a production server. ")
    state.prodConfirmed = true
    #expect(state.prodNote(SFTPTarget(host: "root@db")).isEmpty, "okayed once: later saves go up")
    #expect(AppDelegate.RemoteEdit(baseline: attrs).prodNote(SFTPTarget(host: "root@web")).isEmpty)
}
}

/// R27: the sidebar's SSH icon follows the sessions: an SSH tab whose ssh ended (`exit`) leaves no green badge.
@MainActor @Test func endedSSHSessionLeavesNoBadge() throws {
    let t = SFTPTarget(host: "root@web")
    let row = ServerRow(target: t, title: "web", sessions: [ServerSession(id: UUID(), kind: .ssh, target: t, running: false),
                                                           ServerSession(id: UUID(), kind: .sftp, target: t, dir: "/")])
    let view = try #require(SidebarController().outlineView(NSOutlineView(), viewFor: nil, item: SidebarController.Node(place: .server(row))) as? NSStackView)
    let chips = try #require(view.arrangedSubviews.first { $0 is ServerChips } as? NSStackView)
    #expect(chips.arrangedSubviews.map { $0.accessibilityLabel() } == ["1 SFTP panel open"])
    let actions = try #require(view.arrangedSubviews.first { $0 is ServerToolbar } as? NSStackView).arrangedSubviews.compactMap { $0 as? NSButton }
    #expect(actions.first { $0.accessibilityLabel() == "SSH" }?.contentTintColor == .secondaryLabelColor, "as on a server with nothing open")
}

/// R27: a panel leaving the server for a local folder ends its session there (the sidebar's SFTP badge goes with it).
@MainActor @Test func panelLeavingTheServerEndsItsSession() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r27-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    var changes = 0
    panel.onSessionsChange = { changes += 1 }
    panel.loadRemote(.local(), dir: dir, select: nil)
    for _ in 0..<500 where panel.remoteTabs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    try #require(panel.remoteTabs.count == 1)
    let before = changes
    panel.closeRemote(panel.remoteTabs[0].id)   // a local place (Favorites, ⌘P) opens next to it instead (task 10 §1)
    for _ in 0..<500 where !panel.remoteTabs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(panel.remoteTabs.isEmpty && changes > before)
}

/// Each listing of a server panel was an SFTP session of its own (`ssh -O check`, a new ssh, the handshake). The panel
/// keeps one while it shows the server; leaving the server closes it.
@MainActor @Test func serverPanelKeepsOneSessionWhileOnTheServer() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-kept-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    panel.loadRemote(.local(), dir: dir, select: nil)
    for _ in 0..<500 where panel.remote?.dir != dir { try await Task.sleep(for: .milliseconds(10)) }
    let first = try #require(panel.kept?.client)
    panel.loadRemote(.local(), dir: dir + "/sub", select: nil)
    for _ in 0..<500 where panel.remote?.dir != dir + "/sub" { try await Task.sleep(for: .milliseconds(10)) }
    #expect(panel.remote?.dir == dir + "/sub" && panel.kept?.client === first && first.isConnected, "one session for both")
    panel.navigate(to: dir, history: .none)   // leaves the server
    for _ in 0..<500 where panel.remote != nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(panel.remote == nil && panel.kept == nil && !first.isConnected)
}

/// Swaps `Masters.stopper` for a recorder: no ssh runs.
@Suite(.serialized) @MainActor struct MastersTests {
    final class Stops: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(SFTPTarget, Bool)] = []
        func add(_ t: SFTPTarget, _ now: Bool) { lock.withLock { list.append((t, now)) } }
        var all: [(SFTPTarget, Bool)] { lock.withLock { list } }
    }

    private func recording(_ body: (Stops) async throws -> Void) async rethrows {
        let stops = Stops(), saved = Masters.stopper
        Masters.stopper = { stops.add($0, $1) }
        defer { Masters.stopper = saved }
        try await body(stops)
    }

    /// R10: Disconnect (sidebar menu, Go ▸ Disconnect Server, also with the terminal up) ends that server's shared
    /// connection at once (`-O exit`), whatever key or ControlPersist it was opened with; other servers' stay.
    @Test func disconnectEndsThatServersConnectionNow() async throws {
        let commands = AppDelegate().makeCommands()
        #expect(commands.contains { $0.id == "server.disconnect" && $0.menu == "Go" } && AppDelegate.terminalCommands.contains("server.disconnect"))
        try await recording { stops in
            let mine = SFTPTarget(host: "root@dfm-r10.invalid", port: 22, identity: "~/.ssh/k", persist: 60)
            SFTP.noteMaster(mine)
            SFTP.noteMaster(SFTPTarget(host: "root@dfm-r10-other.invalid"))
            AppDelegate().disconnect(SFTPTarget(host: "root@dfm-r10.invalid"))
            for _ in 0..<300 where stops.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            #expect(stops.all.map(\.0) == [mine] && stops.all.allSatisfy(\.1))
        }
    }

    /// R10 after R17: a wake or network change stopped the master (`-O stop`: no socket, no longer tracked) while an
    /// SSH tab still runs on it. Disconnect ends that tab's ssh itself; the tab stays, to reconnect.
    @Test func disconnectEndsAnSSHTabOnAStoppedConnection() async throws {
        _ = NSApplication.shared
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let panels = NSView(frame: parent.bounds)
        parent.addSubview(panels)
        let term = EmbeddedTerminal(covering: panels)
        defer { term.tabs.forEach { $0.view.process?.terminate() } }
        let t = SFTPTarget(host: "root@dfm-r10-woke.invalid"), other = SFTPTarget(host: "root@dfm-r10-else.invalid")
        term.restore([t, other])   // tabs without a process; a stand-in ssh runs in each
        for tab in term.tabs {
            tab.exitStatus = nil
            term.launch(tab, "/bin/sleep", ["60"], cwd: nil)
        }
        let (mine, theirs) = (term.tabs[0], term.tabs[1])
        try #require(mine.isRunning && theirs.isRunning)
        let app = AppDelegate()
        app.terminal = term
        try await recording { stops in
            await app.disconnectNow(ServerRow.key(t))
            for _ in 0..<400 where mine.exitStatus == nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!mine.isRunning && mine.exitStatus != nil && mine.reconnect != nil, "its ssh ended; the tab says so and offers Reconnect")
            #expect(term.tabs.contains { $0 === mine }, "the tab stays, to reconnect")
            #expect(theirs.isRunning, "another server's session goes on")
            #expect(stops.all.allSatisfy { ServerRow.key($0.0) == ServerRow.key(t) })
        }
    }

    /// R17: when the Mac wakes, every shared connection stops taking sessions (`-O stop`), so the next remote
    /// operation logs in fresh instead of riding a dead one for ~90 s.
    @Test func wakeStopsEverySharedConnection() async throws {
        let center = NotificationCenter()
        Masters.stopOnWake(center)
        try await recording { stops in
            let t = SFTPTarget(host: "root@dfm-r17.invalid")
            SFTP.noteMaster(t)
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
            for _ in 0..<300 where !stops.all.contains(where: { $0.0 == t }) { try await Task.sleep(for: .milliseconds(10)) }
            #expect(stops.all.contains { $0.0 == t && !$0.1 })
        }
    }

    /// Server panels keep their SFTP session between listings. A stopped connection (wake, network change, Disconnect)
    /// takes the panels' sessions on it along: the next listing connects afresh instead of waiting ~90 s on a dead one.
    @Test func stoppedConnectionTakesItsPanelSessionsAlong() async throws {
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-kept-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for name in ["a", "b"] { try FileManager.default.createSymbolicLink(atPath: dir + "/" + name, withDestinationPath: "/usr/libexec/sftp-server") }
        let (t, u) = (SFTPTarget.local(server: dir + "/a"), SFTPTarget.local(server: dir + "/b"))
        let (kt, ku) = (KeptSession(t), KeptSession(u))
        defer { kt.close(); ku.close() }
        _ = try SFTP.list(t, dir, on: kt)
        _ = try SFTP.list(u, dir, on: ku)
        SFTP.noteMaster(t)
        SFTP.noteMaster(u)
        try await recording { stops in
            await Masters.stop(now: false) { $0 == t }
            #expect(stops.all.map(\.0) == [t])
            #expect(kt.client?.isConnected == false && ku.client?.isConnected == true, "another server's stays")
        }
    }

    /// R17: the network monitor's first report is where it starts; each different one after it stops the connections.
    @Test func onlyANetworkChangeStopsConnections() {
        let fired = Stops(), t = SFTPTarget(host: "x")
        let path = Masters.changes { (_: String) in fired.add(t, false) }
        for p in ["wifi", "wifi", "wifi+ethernet", "wifi+ethernet", "none", "wifi"] { path(p) }
        #expect(fired.all.count == 3)
    }
}

/// R23: the editor of a server file is titled host:/path, not its local copy's /var/folders/…/dfm-sftp-UUID/name;
/// after Save As it's the new local file's.
@MainActor @Test func remoteEditorIsTitledWithTheServerPath() async throws {
    _ = NSApplication.shared
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-sftp-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try Data("worker_processes 1;\n".utf8).write(to: URL(fileURLWithPath: dir + "/nginx.conf"))
    let e = try Editor(URL(fileURLWithPath: dir + "/nginx.conf"), remote: "web:/etc/nginx/nginx.conf")
    defer { e.close() }
    let w = try #require(e.window)
    #expect(w.title == "web:/etc/nginx/nginx.conf" && !w.subtitle.contains("dfm-sftp-") && w.representedURL == nil)
    #expect(await e.saveAs(URL(fileURLWithPath: dir + "/mine.conf")))
    #expect(w.title == "mine.conf" && w.representedURL?.lastPathComponent == "mine.conf")
}

/// A server row at rest says what's open — SSH, SFTP and tunnels listening in green with a count from 2 (tunnels red
/// when one failed) — and under the mouse offers SSH, SFTP, Tunnels ▸ (a server with tunnels) and ⋯ instead.
/// Production is in its color, not red; a locked server's icon says so; the tooltip says all of it.
@MainActor @Test func serverRowSaysItsStateAndOffersItsActions() throws {
    var s = SavedServer(address: "root@db:2222")!
    s.prod = true
    s.locked = true
    s.tunnels = [Tunnel(localPort: 15432, port: 5432), Tunnel(localPort: 16379, port: 6379)]
    let row = ServerRow(target: s.target, saved: s, title: "db",
                        sessions: [ServerSession(id: UUID(), kind: .ssh, target: s.target), ServerSession(id: UUID(), kind: .ssh, target: s.target),
                                   ServerSession(id: UUID(), kind: .sftp, target: s.target, dir: "/")],
                        tunnels: ["Postgres", "Redis"], failedTunnels: ["Redis: db can't resolve cache"])
    let view = try #require(SidebarController().outlineView(NSOutlineView(), viewFor: nil, item: SidebarController.Node(place: .server(row))) as? NSStackView)
    let name = try #require(view.arrangedSubviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "db" })
    #expect(name.textColor == SavedServer.color && SavedServer.color != .systemRed)
    #expect((view.arrangedSubviews.first as? NSImageView)?.image?.accessibilityDescription == "Server, locked")
    let chips = try #require(view.arrangedSubviews.first { $0 is ServerChips } as? NSStackView)
    let toolbar = try #require(view.arrangedSubviews.first { $0 is ServerToolbar } as? NSStackView)
    let shown = chips.arrangedSubviews.compactMap { $0 as? NSButton }
    #expect(shown.map { $0.accessibilityLabel() } == ["2 SSH sessions open", "1 SFTP panel open", "2 tunnels listening, one failed"])
    #expect(shown.map(\.title) == ["2", "", "2"] && shown.map(\.contentTintColor) == [.systemGreen, .systemGreen, .systemRed])
    #expect(toolbar.arrangedSubviews.map { $0.accessibilityLabel() } == ["SSH", "SFTP", "Tunnels", "Server menu"])
    #expect(toolbar.isHidden && !chips.isHidden, "at rest: the state")
    #expect(view.toolTip == """
        root@db:2222 · locked · production · SSH 2, SFTP 1 open
        Tunnels listening: Postgres, Redis
        Redis: db can't resolve cache
        Click: its session · double-click: SSH · ⋯ or right-click: everything else
        """)
    let rowView = HoverRowView()
    rowView.addSubview(view)
    rowView.isSelected = true
    #expect(toolbar.isHidden && !chips.isHidden, "selected — the current server: still its state")
    func mouse(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, trackingNumber: 0, userData: nil)!
    }
    rowView.mouseEntered(with: mouse(.mouseEntered))
    #expect(!toolbar.isHidden && chips.isHidden, "under the mouse: the actions")
    rowView.mouseExited(with: mouse(.mouseExited))
    #expect(toolbar.isHidden && !chips.isHidden)

    let plain = ServerRow(target: SFTPTarget(host: "web"), title: "web", status: .failed("Connection refused"))
    let quiet = try #require(SidebarController().outlineView(NSOutlineView(), viewFor: nil, item: SidebarController.Node(place: .server(plain))) as? NSStackView)
    #expect((quiet.arrangedSubviews.first { $0 is ServerChips } as? NSStackView)?.arrangedSubviews.isEmpty == true, "nothing open, nothing shown")
    #expect((quiet.arrangedSubviews.first { $0 is ServerToolbar } as? NSStackView)?.arrangedSubviews.map { $0.accessibilityLabel() } == ["SSH", "SFTP", "Server menu"],
            "no tunnels: no Tunnels button")
    #expect((quiet.arrangedSubviews.first as? NSImageView)?.image?.accessibilityDescription == "Server, its last connection failed")
    #expect(quiet.toolTip?.hasPrefix("web\nConnection refused\n") == true)

    // Tunnels listening, none failed: green, as what's open. The actions take clicks around their icons, as tall as a
    // row lets them.
    let up = ServerRow(target: s.target, saved: s, title: "db", tunnels: ["Postgres"])
    let upView = try #require(SidebarController().outlineView(NSOutlineView(), viewFor: nil, item: SidebarController.Node(place: .server(up))) as? NSStackView)
    #expect((upView.arrangedSubviews.first { $0 is ServerChips } as? NSStackView)?.arrangedSubviews.map { ($0 as? NSButton)?.contentTintColor } == [.systemGreen])
    let actions = try #require(upView.arrangedSubviews.first { $0 is ServerToolbar } as? NSStackView)
    actions.isHidden = false
    for (height, side) in [(24.0, 22.0), (18, 18)] {
        upView.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        upView.layoutSubtreeIfNeeded()
        let sizes = actions.arrangedSubviews.map { $0.alignmentRect(forFrame: $0.frame).size }   // the frame takes clicks a bit past it
        #expect(sizes.allSatisfy { $0.width >= 22 && $0.height == side }, "\(height): \(sizes)")
    }
}
