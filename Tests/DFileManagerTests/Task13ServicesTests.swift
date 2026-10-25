import AppKit
import DFMCore
import Testing
@testable import DFileManager

@Suite(.serialized) @MainActor struct ServicesAppTests {
    private func until(_ done: () -> Bool) async {
        for _ in 0..<250 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// A row says the service, its state ("failed" once, not twice) and its description, cut to fit; ↩ ⌘L ⌘E ⌘R act on
    /// it. One whose name Kermo won't put into a command keeps its row, but each key only says why. Containers alike.
    @Test func rowsSayWhatRunsAndActOnlyOnPlainNames() throws {
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-svc-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
        panel.loadViewIfNeeded()
        defer { panel.shutdown() }
        let app = AppDelegate()
        app.panels = [panel]
        let s = SavedServer(target: .local())
        let web = app.serviceItem(ServiceUnit(unit: "web.service", active: "active", sub: "running", description: "Web server"), on: .local(), of: s)
        #expect(web.title == "web" && web.subtitle == "active · running" && web.detail == "Web server" && web.verb == "Status")
        #expect(web.actions.map(\.key.display) == ["⌘L", "⌘R", "⌘E", "⌘C"])
        let failed = app.serviceItem(ServiceUnit(unit: "backup.service", active: "failed", sub: "failed",
                                                 description: "A description that goes on for much longer than a row has room for"), on: .local(), of: s)
        #expect(failed.subtitle == "failed" && failed.detail == "A description that goes on for much lon…")
        let evil = app.serviceItem(ServiceUnit(unit: "x;reboot.service", active: "active", sub: "running"), on: .local(), of: s)
        #expect(evil.title == "x;reboot")
        evil.run()
        #expect(panel.statusText == "“x;reboot.service” has characters Kermo won't put into a command: nothing runs on it")
        panel.flash("")
        evil.actions.first { $0.key == Shortcut("cmd+r") }?.run()
        #expect(panel.statusText.hasPrefix("“x;reboot.service” has"))

        let box = app.containerItem(ContainerInfo(name: "api", state: "running", status: "Up 5 minutes", image: "registry.example.com/api:2"),
                                    tool: "podman", on: .local(), of: s)
        #expect(box.title == "api" && box.subtitle == "running · Up 5 minutes" && box.detail == "registry.example.com/api:2")
        #expect(box.actions.map(\.key.display) == ["⌘R", "⌘C"] && box.verb == "Live Logs")
        let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))   // not the user's clipboard
        defer { pb.releaseGlobally() }
        let odd = app.containerItem(ContainerInfo(name: "-x", state: "exited", status: "", image: "busybox"), tool: "docker", on: .local(), of: s, pasteboard: pb)
        #expect(odd.subtitle == "exited")
        odd.actions.first { $0.key == Shortcut("cmd+c") }?.run()
        #expect(pb.string(forType: .string) == "-x", "copying the name is fine")
        odd.run()
        #expect(panel.statusText.hasPrefix("“-x” has characters"))
    }

    /// A unit file only root may write, opened by its user, says how to save it; one the user may write, or opened as root, doesn't.
    @Test func aRootsFileSaysHowToSaveIt() {
        var a = SFTPClient.Attrs.nothing
        (a.mode, a.uid) = (0o644, 0)
        #expect(AppDelegate.rootsOnly(a, for: SFTPTarget(host: "me@web")))
        #expect(!AppDelegate.rootsOnly(a, for: SFTPTarget(host: "me@web").asRoot()))
        #expect(!AppDelegate.rootsOnly(a, for: SFTPTarget(host: "root@web")))
        #expect(!AppDelegate.rootsOnly(a, for: SFTPTarget(host: "web")), "an alias's user may be root: nothing said")
        var mine = a
        mine.uid = 1000
        #expect(!AppDelegate.rootsOnly(mine, for: SFTPTarget(host: "me@web")))
        var shared = a
        shared.mode = 0o664
        #expect(!AppDelegate.rootsOnly(shared, for: SFTPTarget(host: "me@web")))
    }

    /// A note for a file's editor is said once its window is open (it opens after the file is read, off the main thread).
    @Test func anEditorsNoteShowsOnceItsOpen() async throws {
        _ = NSApplication.shared
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-svc-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir + "/k.service")
        try Data("[Unit]\n".utf8).write(to: url)
        Editor.open(url, note: "“k.service” is root's")
        await until { Editor.window(for: url) != nil }
        let w = try #require(Editor.window(for: url))
        defer { w.close() }
        #expect(w.statusText == "“k.service” is root's")
    }

    /// A follow's remote command ends with ssh; anything else runs as it did.
    @Test func aFollowsCommandEndsWithSSH() {
        #expect(Shell.remote("journalctl -u x.service -f", in: "/", follow: true) == SSHCommand.inDir("/", SSHCommand.endsWithSSH("journalctl -u x.service -f")))
        #expect(Shell.remote("ls", in: "/srv", follow: false) == "cd -- /srv && ls")
    }

    /// Services… and Containers… are in each server's menu, after Forward Port… and Tunnels ▸, and in ⌘⇧P.
    @Test func servicesAndContainersAreInEachServersMenu() {
        let app = AppDelegate()
        let titles = app.serverMenu(.server(ServerRow(target: SFTPTarget(host: "me@web.invalid"), saved: nil, title: "web"))).map(\.title)
        let at = titles.firstIndex(of: "Forward Port…")
        #expect(at != nil && titles[at! + 2] == "Services…" && titles[at! + 3] == "Containers…", "after Tunnels ▸: \(titles)")
        for (q, title) in [("journalctl", "Services…"), ("docker", "Containers…")] {
            let hits = HeaderSearchModel.results(q, commands: app.makeCommands(), folders: [], files: [], recent: [])
            #expect(hits.first?.hits.first?.title == title)
        }
    }
}

extension ServerLockTests {
private func until(_ done: () -> Bool) async {
    for _ in 0..<250 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
}

/// ⌘R on a service restarts it as root, through the server's sudo (`sudo -n`), whatever panel it was looked at from;
/// the status line says it went.
@Test func aServiceRestartsAsRoot() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-svc-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try Data("#!/bin/sh\necho \"$*\" >> \(dir)/systemctl.log\n".utf8).write(to: URL(fileURLWithPath: dir + "/bin/systemctl"))
    chmod(dir + "/bin/systemctl", 0o755)
    let sudo = dir + "/sudo"   // as root: with the stand-in systemctl in PATH
    try Data("#!/bin/sh\necho \"$*\" > \(dir)/sudo.log\n[ \"$1\" = -n ] && [ \"$2\" = -- ] || exit 2\nshift 2\nPATH=\(dir)/bin:$PATH exec \"$@\"\n".utf8)
        .write(to: URL(fileURLWithPath: sudo))
    chmod(sudo, 0o755)
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let app = AppDelegate()
    app.panels = [panel]
    ServerLock.servers = { [] }
    let user = SFTPTarget.local(sudo: sudo).asRoot(false)   // looked at from a user's panel
    AppDelegate.unitState = { _, _, _, _, _ in .init(active: "active", sub: "running") }
    defer { AppDelegate.unitState = { try Services.state($0, on: $1, wait: $2, env: $3, cancel: $4) } }
    let item = app.serviceItem(ServiceUnit(unit: "web.service", active: "active", sub: "running"), on: user, of: SavedServer(target: user))
    item.actions.first { $0.key == Shortcut("cmd+r") }?.run()
    await until { panel.statusText.hasPrefix("web restarted") }
    #expect(panel.statusText.hasPrefix("web restarted on localhost at "), "\(panel.statusText)")
    #expect((try? String(contentsOfFile: dir + "/systemctl.log", encoding: .utf8)) == "restart -- web.service\n")
    #expect((try? String(contentsOfFile: dir + "/sudo.log", encoding: .utf8))?.hasPrefix("-n -- sh -c ") == true)
}

/// On a production server ⌘R asks first and ↩ is Cancel: nothing runs, nothing is logged; Restart runs it.
@Test func aRestartOnProductionAsksAndReturnIsCancel() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-svc-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
    let was = AuditLog.path
    AuditLog.path = dir + "/audit.jsonl"
    defer { AuditLog.path = was; ServerLock.servers = { [] }; AppDelegate.answering = nil; try? FileManager.default.removeItem(atPath: dir) }
    try Data("#!/bin/sh\necho \"$*\" >> \(dir)/systemctl.log\n".utf8).write(to: URL(fileURLWithPath: dir + "/bin/systemctl"))
    chmod(dir + "/bin/systemctl", 0o755)
    let sudo = dir + "/sudo"
    try Data("#!/bin/sh\n[ \"$1\" = -n ] && [ \"$2\" = -- ] || exit 2\nshift 2\nPATH=\(dir)/bin:$PATH exec \"$@\"\n".utf8).write(to: URL(fileURLWithPath: sudo))
    chmod(sudo, 0o755)
    var prod = SavedServer(address: "localhost")!
    prod.prod = true
    ServerLock.servers = { [prod] }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let app = AppDelegate()
    app.panels = [panel]
    let t = SFTPTarget.local(sudo: sudo).asRoot(false)
    var asked: [(String, [String], Int?)] = []
    AppDelegate.answering = { m, b, d in asked.append((m, b, d)); return d ?? 0 }   // ↩
    let unit = ServiceUnit(unit: "web.service", active: "active", sub: "running")
    #expect(await app.runThere(Services.restart(unit), on: t.asRoot(), action: "restart", busy: "…", done: "Restarted",
                               ask: ("Restart web on localhost?", "Restart"), in: panel) == false)
    #expect(asked.count == 1 && asked[0].1 == ["Restart", "Cancel"] && asked[0].2 == 1, "↩ is Cancel")
    Config.flush()
    #expect(!FileManager.default.fileExists(atPath: dir + "/systemctl.log") && !FileManager.default.fileExists(atPath: AuditLog.path))
    AppDelegate.answering = { _, _, _ in 0 }   // Restart
    AppDelegate.unitState = { _, _, _, _, _ in .init(active: "active", sub: "running") }
    defer { AppDelegate.unitState = { try Services.state($0, on: $1, wait: $2, env: $3, cancel: $4) } }
    app.serviceItem(unit, on: t, of: SavedServer(target: t)).actions.first { $0.key == Shortcut("cmd+r") }?.run()
    await until { FileManager.default.fileExists(atPath: AuditLog.path) }
    Config.flush()
    #expect((try? String(contentsOfFile: dir + "/systemctl.log", encoding: .utf8)) == "restart -- web.service\n")
    #expect((try? String(contentsOfFile: AuditLog.path, encoding: .utf8))?.contains(#""action":"restart""#) == true)
}

/// On a production server a restart asks first (↩ = Cancel) and says what runs, as whom; elsewhere it just runs.
@Test func aRestartAsksFirstOnProduction() {
    let web = SFTPTarget(host: "me@web")
    #expect(AppDelegate.prodQuestion("systemctl restart -- nginx.service", on: web.asRoot()) == nil)
    var prod = SavedServer(address: "me@web")!
    prod.prod = true
    ServerLock.servers = { [prod] }
    defer { ServerLock.servers = { [] } }
    #expect(AppDelegate.prodQuestion("systemctl restart -- nginx.service", on: web.asRoot())
            == "“me@web” is a production server. Runs “systemctl restart -- nginx.service” on me@web as root.")
    #expect(AppDelegate.prodQuestion("podman restart -- api", on: web) == "“me@web” is a production server. Runs “podman restart -- api” on me@web.")
}
}

/// A server a look logged in to keeps its connection for its ControlPersist though no panel shows it (the next look
/// needs no login); then, or after Disconnect, it goes as any idle one.
@MainActor @Test func aLooksConnectionStaysForItsPersist() async {
    let app = AppDelegate()
    let web = SFTPTarget(host: "me@web.invalid"), db = SFTPTarget(host: "me@db.invalid", persist: 30)
    #expect(Set(app.idleServers([web, db]).map(\.host)) == ["me@web.invalid", "me@db.invalid"], "nothing shows them")
    app.noteLook(web)
    app.noteLook(db)
    #expect(app.idleServers([web, db]).isEmpty)
    #expect(app.idleServers([web, db], now: Date().addingTimeInterval(60)).map(\.host) == ["me@db.invalid"], "a locked one's short persist")
    #expect(app.idleServers([web, db], now: Date().addingTimeInterval(601)).count == 2)
    app.noteLook(web)
    await app.disconnectNow(ServerRow.key(web))
    #expect(app.idleServers([web]).map(\.host) == ["me@web.invalid"], "Disconnect ends the keep")
}
