import AppKit
import DFMCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSTextFieldDelegate, NSWindowDelegate, NSToolbarDelegate {
    private(set) var window: NSWindow!
    var panels: [PanelViewController] = []   // set at launch (tests: their own)
    /// Servers a look (Services…, Containers…, Forward Port…, Run on Servers) logged in to, by key, until when their
    /// connection is kept for the next look though nothing shows them: its ControlPersist, as plain ssh keeps it.
    var looked: [String: Date] = [:]
    /// Services… (ServerServices.swift): what runs on a service now ("Restarting…"), by `serviceID` — its row says so,
    /// and its other changes wait — and what each server's list had typed and highlighted when it closed.
    var serviceRuns: [String: String] = [:]
    var servicesKept: [String: (query: String, id: String?)] = [:]
    private(set) var ops: OpsController!
    /// Move jobs an undo/redo started (across volumes): their own undo is registered already.
    var replayJobs: [FileJob] = []
    /// Synchronize's jobs not finished yet: the production log calls them "sync". Weak: one cancelled while queued never
    /// finishes, and its address may be another job's later.
    let syncJobs = NSHashTable<FileJob>.weakObjects()
    /// The last undo/redo's disk work: each waits for the one before (`afterUndoWork`).
    var undoWork: Task<Void, Never>?
    var terminal: EmbeddedTerminal!   // set in tests
    private var split: NSSplitView!
    private var sidebarItem: NSSplitViewItem!
    private var sidebarWidth: CGFloat = 200   // last width while shown, for the auto-hide rule
    private var sidebarAnimating = false   // the toggle's own window growth is no resize for the rule (B1)
    let sidebar = SidebarController()
    let search = HeaderSearch()
    private var splitController: NSSplitViewController!
    private var volumes: [Volume] = []
    var disks: [Disk] = []   // DiskArbitration's that Kermo may mount
    var diskWatch: DiskWatch?
    var volumeBusy: Set<String> = []   // mounting, unmounting, ejecting: mount points, and BSD names of those not mounted
    private var configHosts: [String] = []   // ~/.ssh/config aliases
    private var sftpErrors: [String: String] = [:]   // host → its last failure, until any panel gets through
    private var sidebarRefresh: Task<Void, Never>?
    private var activeIndex = 0
    private var restoredDividers: [Double] = []   // the session's, till the panels are first laid out
    /// Where F5/F6 go: the panel that was active before this one (with 2 panels, simply the other one).
    private weak var target: PanelViewController?
    var quickViewOn = false
    private let promptLabel = NSTextField(labelWithString: "")
    private let cmdField = NSTextField(string: "")
    private var historyIndex = 0
    private(set) var commands: [Command] = []
    private var keymap: [Shortcut: Command] = [:]
    let keyBar = KeyBarView()
    /// Narrowest main window: two 360 pt panels, and the key bar's six file actions plus "+N" (U4).
    static let minWidth: CGFloat = 720
    private var responderObservation: NSKeyValueObservation?
    let defaults = UserDefaults.standard
    var bookmarks: [String] = Config.noting(Config.loadEach("bookmarks.json", as: String.self))
    let tunnels = Tunnels()
    var savedServers: [SavedServer] = Config.noting(Config.loadEach("servers.json", as: SavedServer.self)) {
        didSet {
            tunnels.sync(savedServers)   // a tunnel gone or changed: its port follows
            Task { await ServerLock.learn(again: true) }
        }
    }
    var serverPins: [String] = Config.noting(Config.loadEach("server-pins.json", as: String.self))   // addresses, in pin order
    var frecency: Frecency = Config.noting(Config.loadKeeping("frecency.json", as: Frecency.self)) ?? Frecency()
    private var visitsSinceSave = 0

    var active: PanelViewController { panels[activeIndex] }
    var other: PanelViewController {
        if let t = target, t !== active, panels.contains(where: { $0 === t }) { return t }
        return panels[(activeIndex + 1) % panels.count]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyConfig(reportProblems: false)
        SFTP.password = { SSHPasswords.get($0) }
        SFTP.hasPassword = { SSHPasswords.has($0) }
        SFTP.sudoPassword = { SudoPasswords.password($0, wrong: $1) }
        SFTP.sudoPasswordTaken = { SudoPasswords.taken($0, $1) }
        ServerLock.servers = { [unowned self] in savedServers }
        ServerCopies.upload = { [unowned self] c in await upload(c.url, to: c.path, on: c.target, c.state) }
        AuditLog.failed = { [unowned self] in active.flash($0, error: true) }
        ServerLock.relockOnScreenLockAndSleep()
        ServerLock.onRelock = { [unowned self] in
            tunnels.relock(savedServers)
            for s in savedServers where s.locked { looked[ServerRow.key(s.target)] = nil }   // a locked server's look ends with the lock
            releaseIdleServers()
        }
        tunnels.changed = { [unowned self] in refreshSidebar() }
        tunnels.say = { [unowned self] in active.flash($0, error: $1) }
        // Back from a locked screen or sleep: the tunnels that went off with it are named once (`relock`).
        let back: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { if NSApp.isActive { (NSApp.delegate as? AppDelegate)?.tunnels.sayHeldNote() } }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: back)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: back)
        Masters.stopOnWake()
        Masters.stopOnNetworkChange()
        Task { _ = await Blocking.run { GitStatus.available } }   // runs xcode-select: not on the main thread at first use
        DispatchQueue.global(qos: .utility).async { TempCopies.sweep() }

        // Session: each panel's tabs (a server's parked: no connection without a click), the active one, the dividers.
        let session = Session.load(defaults)
        let showHidden = defaults.bool(forKey: "showHidden")
        panels = (0..<min(max(session.panels.count, 2), 4)).map { i in
            let p = session.panels.indices.contains(i) ? session.panels[i] : Session.Panel(tabs: [Session.Tab(path: "/")], index: 0)
            return PanelViewController(session: p.tabs, index: p.index, showHidden: showHidden)
        }
        panels.forEach(wire)
        activeIndex = min(max(session.active, 0), panels.count - 1)
        restoredDividers = session.dividers

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 750),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // closed while a viewer keeps the app alive: `window` must not dangle
        window.undoManager?.levelsOfUndo = 100   // each step holds its paths (and a move's jobs): not a whole day's worth
        window.title = "Kermo"
        ops = OpsController(window: window, historyDir: Config.dir) { [unowned self] in jobFinished($0) }
        ops.onRetry = { [unowned self] in retryFailed($0, $1) }
        ops.onShow = { [unowned self] in showItem(on: $0, in: $1, select: $2) }
        let toolbar = NSToolbar(identifier: "Main")   // after `ops`: it asks for the Activity button at once
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact   // one row: the title bar's height, plus room for the controls
        window.contentView = makeContent()
        applyTheme()
        window.setContentSize(NSSize(width: 1200, height: 750))
        window.center()
        window.contentMinSize.width = Self.minWidth
        window.setFrameAutosaveName("MainWindow")
        window.delegate = self
        applySidebarRule()
        setUpSidebar()
        setUpSearch()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(active.table)
        updatePanelStates()
        updatePrompt()
        Task {   // a locked server's alias saved too must not listen unasked
            await ServerLock.learn()
            tunnels.startSaved(savedServers)
        }
        startUpdateChecks()
        NSApp.activate()
        // The terminal eats control keys, so its commands (⌃O, ⌘T, ⌘W, ⌃⇥ …) are picked off here first.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] e in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard e.window === window else { return false }
                if terminal.hasFocus {
                    if terminal.handleKey(e) { return true }
                    if let c = keymap[Shortcut(event: e)], Self.terminalCommands.contains(c.id) {
                        run(c.id)
                        return true
                    }
                }
                // ⌘↩ in the ⌘E field: with ⌘ it's a key equivalent, which the field editor never turns into insertNewline:.
                if cmdField.currentEditor() === window.firstResponder, Shortcut(event: e) == Shortcut("cmd+return") {
                    runCommandLine(in: .terminalApp)
                    return true
                }
                return e.keyCode == 53 && keyBar.unpin()   // ⎋ releases a layer pinned from "Hold ▾"
            }
            return handled ? nil : e
        }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [unowned self] e in
            MainActor.assumeIsolated {
                keyBar.modifiersChanged(NSApp.keyWindow === window ? e.modifierFlags.intersection([.command, .option, .control, .shift]) : [])
            }
            return e
        }
        // Focus moving into a text field (or the terminal) enables / disables the bar's slots.
        responderObservation = window.observe(\.firstResponder) { [keyBar] _, _ in
            MainActor.assumeIsolated { keyBar.render() }
        }
        if !configProblems.isEmpty { showError(JobErrorMessage(configProblems.joined(separator: "\n"))) }
        show(pendingOpen)
    }

    // MARK: - Opening paths (`fm`, Finder's Open With)

    private var pendingOpen: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if panels.isEmpty { pendingOpen = urls } else { show(urls) }   // at launch this comes before didFinishLaunching
    }

    /// First path in the active panel, second in the other one; a file opens its folder with the cursor on it.
    /// The main window comes forward with them, also when a viewer kept the app alive after it was closed.
    private func show(_ urls: [URL]) {
        let places = Array(zip(urls.filter(\.isFileURL).map(\.standardizedFileURL), [active, other]))
        pendingOpen = []
        showMainWindow(nil)
        Task {
            // Off the main thread: a path on a share that doesn't answer.
            let kinds = await Blocking.run(.userInitiated) { () -> [Bool?] in   // folder or not; nil: nothing there
                places.map { url, _ in
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) ? isDir.boolValue : nil
                }
            }
            for ((url, panel), isDir) in zip(places, kinds) {
                guard let isDir else { continue }
                if isDir { panel.navigate(to: url.path) }
                else { panel.navigate(to: url.deletingLastPathComponent().path, select: url.lastPathComponent) }
            }
        }
    }

    /// Window ▸ Main Window (⌘0) and `fm`: back to the panels from a viewer or editor, or after closing them.
    @objc func showMainWindow(_ sender: Any?) { window.makeKeyAndOrderFront(nil) }

    func applicationDidResignActive(_ notification: Notification) { keyBar.reset() }
    func applicationDidBecomeActive(_ notification: Notification) { tunnels.sayHeldNote() }

    func applicationWillTerminate(_ notification: Notification) {
        saveSession()   // the cursors, the active panel, the dividers: none of them saves it as it changes
        Config.save("frecency.json", frecency)
        tunnels.stopAll()   // first: a client connecting now would start a login
        // No logged-in connection outlives the app. All at once: each may take up to `SFTP.stopWait`.
        let masters = Array(SFTP.masterTargets)
        DispatchQueue.concurrentPerform(iterations: masters.count) { SFTP.stopMaster(masters[$0], now: true) }
        Shell.terminateAll()   // nor does a `tail -f` in an output window
        ArchiveIndex.discardLiveStaging()   // after tar is gone: an extract cut short leaves no hidden copy behind
        ServerCopies.quit()   // the server files' copies on the server go; the others are kept
        TempCopies.remove(TextCopies.dir)
        SFTP.removeControlDir()   // after the masters and tunnels: their sockets and the askpass script are in it
        Config.flush()   // the session, frecency and the last production lines are on disk before the app goes
    }

    /// What quitting would lose — unsaved editors, running copies, SSH sessions, programs in shells: one
    /// confirmation for all of it (⌘Q and closing the last window).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmQuit() ? .terminateNow : .terminateCancel
    }

    /// Another window (viewer, editor) keeps the app alive: the main window just hides and sessions go on.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.windows.contains { Self.keepsAlive($0, besides: sender) } || confirmQuit()
    }
    /// One in the Dock counts too: it isn't visible, the app lives on with it — and the quit question, answered here
    /// for nothing, was never asked again: ⌘Q later lost its unsaved text unasked.
    static func keepsAlive(_ w: NSWindow, besides sender: NSWindow) -> Bool {
        w !== sender && (w.isVisible || w.isMiniaturized) && w.canBecomeMain
    }

    private var quitConfirmed = false
    private func confirmQuit() -> Bool {
        guard !quitConfirmed else { return true }
        var lost: [String] = []
        let unsaved = Editor.unsaved
        if !unsaved.isEmpty { lost.append("Unsaved changes: " + unsaved.joined(separator: ", ")) }
        if ops.pending > 0 {
            lost.append("\(ops.pending) file operation\(ops.pending == 1 ? "" : "s") running or queued (a copy to a server stops part way)")
        }
        if RemoteEdit.uploading > 0 { lost.append("Edited server text still uploading (its local copy is kept)") }
        let notUp = ServerCopies.unsynced.filter { $0.pending == 0 }   // still uploading: said above
        if !notUp.isEmpty { lost.append("Saved in another app, not on the server: " + notUp.map { "“\($0.url.lastPathComponent)” (kept in \($0.dir))" }.joined(separator: ", ")) }
        let editing = ServerCopies.editing
        if !editing.isEmpty {
            lost.append("Edited in another app: " + editing.map { "“\($0.url.lastPathComponent)”" }.joined(separator: ", ") + " — saves after quitting don't reach the server")
        }
        if let busy = Shell.busy { lost.append(busy) }
        if let note = tunnels.quitNote() { lost.append(note) }
        lost += terminal.tabs.compactMap(\.busyWith)
        guard !lost.isEmpty else { return true }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Quit Kermo?"
        a.informativeText = (lost.map { "• " + $0 }.joined(separator: "\n") + "\n\nAll of this ends.").bidiVisible
        a.addButton(withTitle: "Quit").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        quitConfirmed = a.runModal() == .alertFirstButtonReturn
        return quitConfirmed
    }

    /// A server nothing shows any more (no panel tab, no running SSH tab, not connecting) keeps no logged-in
    /// connection: closing its last session closes that too, instead of ControlPersist's 10 minutes — unless a look
    /// used it lately (`looked`): the next look, a minute later, needn't log in again (a password asked again).
    func releaseIdleServers() {
        let idle = idleServers(SFTP.masterTargets)
        guard !idle.isEmpty else { return }
        DispatchQueue.global().async { for t in idle { SFTP.stopMaster(t, now: false) } }
    }

    /// Of `masters`, the connections `releaseIdleServers` ends.
    func idleServers(_ masters: Set<SFTPTarget>, now: Date = Date()) -> [SFTPTarget] {
        looked = looked.filter { $0.value > now }
        let inUse = Set(panels.flatMap { $0.remoteTabs.map(\.target) + [$0.connecting].compactMap { $0 } }.map(ServerRow.key)
                        + (terminal?.tabs ?? []).filter { $0.exitStatus == nil }.compactMap(\.target).map(ServerRow.key))   // starting or running
            .union(tunnels.inUse)   // else the next client would log in again
            .union(looked.keys)
        return masters.filter { !inUse.contains(ServerRow.key($0)) }
    }

    /// A look logged in to `t`'s server (or rode its connection): kept for its ControlPersist from now.
    func noteLook(_ t: SFTPTarget) { looked[ServerRow.key(t)] = Date().addingTimeInterval(TimeInterval(t.persist ?? 600)) }

    private func recordVisit(_ path: String) {
        frecency.visit(path)
        visitsSinceSave += 1
        if visitsSinceSave >= 20 {
            visitsSinceSave = 0
            Config.save("frecency.json", frecency)
        }
    }

    private var configProblems: [String] = []

    /// Builds commands with keymap.json overrides applied (user bindings win over defaults) and rebuilds menus.
    func applyConfig(reportProblems: Bool) {
        var cmds = makeCommands()
        var problems: [String] = []
        var overridden = Set<String>()
        do {
            for (id, specs) in try Config.load("keymap.json", as: [String: [String]].self) ?? [:] {
                guard let i = cmds.firstIndex(where: { $0.id == id }) else { problems.append("keymap.json: unknown command “\(id)”"); continue }
                cmds[i].keys = specs.compactMap { spec in
                    guard let k = Shortcut(spec) else { problems.append("keymap.json: \(id): bad key “\(spec)”"); return nil }
                    // Edit Keymap… once wrote every default into the file, ⌘⌥D and ⌘M among them: those never fire.
                    if let what = k.takenByMacOS { problems.append("keymap.json: \(id): \(k.display) never arrives — macOS takes it first (\(what))") }
                    return k
                }
                overridden.insert(id)
            }
        } catch {
            problems.append("keymap.json: \(error.localizedDescription)")
        }
        var map: [Shortcut: Command] = [:]
        for c in cmds where !overridden.contains(c.id) {
            for k in c.keys {
                precondition(map[k] == nil, "default \(k.display) bound to both \(map[k]!.id) and \(c.id)")
                map[k] = c
            }
        }
        for c in cmds where overridden.contains(c.id) { for k in c.keys { map[k] = c } }
        for i in cmds.indices { cmds[i].keys = cmds[i].keys.filter { map[$0]?.id == cmds[i].id } }
        commands = cmds
        keymap = map
        keyBar.reload(cmds)
        refreshSidebar()   // section headers show keys
        NSApp.mainMenu = makeMenu()
        configProblems = Config.unreadable + problems   // the state files' once, at launch
        Config.unreadable = []
        if reportProblems {
            if problems.isEmpty { active.flash("Config reloaded") } else { showError(JobErrorMessage(problems.joined(separator: "\n"))) }
        }
    }

    private func saveSession() { session.save(defaults) }

    /// What a restart brings back.
    var session: Session {
        let w = split?.bounds.width ?? 0
        return Session(panels: panels.map { Session.Panel(tabs: $0.sessionTabs, index: $0.tabIndex) }, active: activeIndex,
                       dividers: w > 0 ? panels.dropLast().map { Double($0.view.frame.maxX / w) } : [])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dock click with the main window closed (a viewer kept the app alive): bring it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !window.isVisible { showMainWindow(nil) }
        return true
    }

    // MARK: - Panels (2–4)

    private func wire(_ panel: PanelViewController) {
        panel.showPerms = defaults.bool(forKey: "showPerms")
        panel.onFocus = { [unowned self, unowned panel] in activate(panel) }
        panel.onCommandKey = { [unowned self] in runKey($0) }
        panel.onCommand = { [unowned self] in run($0) }
        panel.onCursorChange = { [unowned self, unowned panel] in
            if quickViewOn && panel === active { other.preview(active.previewURL()) }
        }
        panel.onTransfer = { [unowned self] items, side, dir, move in
            enqueueTransfer(items.paths, from: items.from, to: dir, on: side, name: nil, move: move)
        }
        panel.onSessionsChange = { [unowned self] in
            refreshSidebar()
            releaseIdleServers()
        }
        panel.onGone = { [unowned self] in forgetGone([$0]) }
        panel.onGitChange = { [unowned self, unowned panel] in if panel === active { updateGitRow() } }
        panel.onRemoteResult = { [unowned self] target, error in
            guard sftpErrors[target.host] != error else { return }
            sftpErrors[target.host] = error
            refreshSidebar()
        }
        panel.onPathChange = { [unowned self, unowned panel] in
            saveSession()
            updatePrompt()
            if panel.remote == nil && panel.parked == nil { recordVisit(panel.path) }   // a parked tab's folder isn't on screen
            // Frequent re-ranks a moment later, so the list doesn't jump while you're browsing.
            sidebarRefresh?.cancel()
            sidebarRefresh = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { self?.refreshSidebar() }
            }
        }
    }

    private func activate(_ panel: PanelViewController) {
        guard let i = panels.firstIndex(where: { $0 === panel }), i != activeIndex else { return }
        if quickViewOn {   // the preview panel can't become the active one
            quickViewOn = false
            panels.forEach { $0.setQuickView(false) }
        }
        target = active
        activeIndex = i
        updatePanelStates()
        updatePrompt()
    }

    private func updatePanelStates() {
        for p in panels {
            p.isActive = p === active
            p.isTarget = panels.count > 2 && p === other
        }
    }

    /// Tab: next panel, left to right.
    func focusNext() { window.makeFirstResponder(panels[(activeIndex + 1) % panels.count].table) }

    func focusPanel(_ i: Int) {
        guard panels.indices.contains(i) else { return NSSound.beep() }
        window.makeFirstResponder(panels[i].table)
    }

    /// New panel right of the active one, on the same folder.
    func addPanel() {
        guard panels.count < 4 else { return active.flash("Four panels at most") }
        let p = PanelViewController(tabs: [active.path], index: 0, showHidden: defaults.bool(forKey: "showHidden"))
        wire(p)
        panels.insert(p, at: activeIndex + 1)
        split.insertArrangedSubview(p.view, at: activeIndex + 1)
        equalizePanels()
        window.makeFirstResponder(p.table)
        saveSession()
        applySidebarRule()
    }

    func closePanel() {
        guard panels.count > 2 else { return active.flash("Two panels at least") }
        if quickViewOn { toggleQuickView() }
        let closing = active, next = other
        panels.removeAll { $0 === closing }
        closing.shutdown()
        closing.view.removeFromSuperview()
        activeIndex = panels.firstIndex { $0 === next }!
        target = nil
        equalizePanels()
        window.makeFirstResponder(next.table)
        updatePanelStates()
        updatePrompt()
        saveSession()
        applySidebarRule()
        refreshSidebar()        // its server tabs are gone: not shown open any more,
        releaseIdleServers()    // nor their connections kept 10 minutes for nobody
    }

    /// Even widths; at launch, the dividers where they were (`restoredDividers`).
    private func equalizePanels() {
        let saved = restoredDividers
        restoredDividers = []
        DispatchQueue.main.async { [self] in
            for (i, f) in Session.dividers(saved, panels: panels.count).enumerated() { split.setPosition(split.bounds.width * f, ofDividerAt: i) }
        }
    }

    // MARK: - Sidebar

    /// ⌃⌘S / toolbar button: the user's choice, remembered. Shown on a cramped window, it stays until the next resize.
    func toggleSidebar() {
        let show = sidebarItem.isCollapsed
        defaults.set(show, forKey: "sidebarVisible")
        collapseSidebar(!show, animated: true)
    }

    /// Hidden while it has the keys, the outline resigns to the window and they go nowhere: back to the panel first.
    private func collapseSidebar(_ hide: Bool, animated: Bool) {
        if hide, sidebar.hasFocus { sidebar.onLeave?() }
        guard animated else { sidebarItem.isCollapsed = hide; return }
        sidebarAnimating = true
        NSAnimationContext.runAnimationGroup { _ in sidebarItem.animator().isCollapsed = hide } completionHandler: { [self] in
            MainActor.assumeIsolated { sidebarAnimating = false }
        }
    }

    /// ⌃⇧S: the keys go to the sidebar (shown if hidden); ⎋ there brings them back.
    func focusSidebar() {
        if sidebarItem.isCollapsed { toggleSidebar() }
        sidebar.focus()
    }

    /// Not while the toggle animates: showing the sidebar grows the window frame by frame, and collapsing it midway
    /// leaves the split view's size pin on the panels — the window then can't change its width (B1).
    private func applySidebarRule() {
        guard !sidebarAnimating, defaults.object(forKey: "sidebarVisible") as? Bool ?? true else { return }
        if !sidebarItem.isCollapsed { sidebarWidth = sidebar.view.frame.width }
        let hide = SidebarRule.autoHidden(windowWidth: window.frame.width, sidebarWidth: sidebarWidth, panels: panels.count,
                                          hidden: sidebarItem.isCollapsed)
        if hide != sidebarItem.isCollapsed { collapseSidebar(hide, animated: false) }
    }

    func windowDidResize(_ notification: Notification) { applySidebarRule() }

    private func setUpSearch() {
        search.results = { [unowned self] q, flag in
            let fav = bookmarks.map { SearchHit(title: Bookmark.title($0), subtitle: ($0 as NSString).abbreviatingWithTildeInPath, detail: "★", target: .folder($0)) }
            let freq = frecency.ranked().filter { !bookmarks.contains($0) }.prefix(300).map {
                SearchHit(title: Self.folderName($0), subtitle: ($0 as NSString).abbreviatingWithTildeInPath, target: .folder($0))
            }
            let vols = volumes.map { SearchHit(title: $0.name, subtitle: $0.path, detail: "volume", target: .folder($0.path)) }
            let servers = (defaults.stringArray(forKey: "recentServers") ?? []).map { SearchHit(title: $0, detail: "server", target: .server($0)) }
            let commands = commands, folders = fav + freq + vols + servers, files = active.listedItems.map(\.name)
            let recent = defaults.stringArray(forKey: "searchRecent") ?? []
            return await Blocking.run(.userInitiated) {
                HeaderSearchModel.results(q, commands: commands, folders: folders, files: files, recent: recent, cancel: flag)
            }
        }
        search.onCancel = { [unowned self] in window.makeFirstResponder(active.table) }
        // Compared as targets: a command chosen before folders were kept is stored as its bare id.
        func forget(_ t: SearchHit.Target) -> [String] { (defaults.stringArray(forKey: "searchRecent") ?? []).filter { SearchHit.Target(key: $0) != t } }
        search.onRemove = { [unowned self] hit in defaults.set(forget(hit.target), forKey: "searchRecent") }
        search.onChoose = { [unowned self] hit, otherPanel in
            window.makeFirstResponder(active.table)
            if let key = hit.target.key {
                defaults.set(Array(([key] + forget(hit.target)).prefix(HeaderSearchModel.recentMax)), forKey: "searchRecent")
            }
            switch hit.target {
            case .command(let id): run(id)
            case .folder(let p):
                if let r = Bookmark.remote(p) { openBookmark(r, panel: otherPanel ? other : nil) } else { (otherPanel ? other : active).navigate(to: p) }
            case .server(let s): connect(s)
            case .file(let name): active.moveCursor(toName: name)
            case .disk(let q): searchDialog(name: q)
            }
        }
    }

    private static func folderName(_ p: String) -> String { p == "/" ? "/" : (p as NSString).lastPathComponent }

    private func setUpSidebar() {
        sidebar.keyFor = { [unowned self] id in commands.first { $0.id == id }?.keys.first?.display ?? "" }
        sidebar.onOpen = { [unowned self] in openPlace($0, $1) }
        sidebar.onTag = { [unowned self] in openPlace(.tag($0), []) }
        sidebar.onFavorites = { [unowned self] in
            bookmarks = $0
            Config.save("bookmarks.json", bookmarks)
            refreshSidebar()
        }
        sidebar.onTransfer = { [unowned self] items, dir, move in enqueueTransfer(items.paths, from: items.from, to: dir, name: nil, move: move) }
        sidebar.onVolume = { [unowned self] v, action in
            switch action {
            case .mount: if let d = v.disk { mountVolume(d) }
            case .unmount: ejectVolume(v.path, unmount: true)
            case .eject: ejectVolume(v.path)
            }
        }
        sidebar.onLeave = { [unowned self] in window.makeFirstResponder(active.table) }
        sidebar.onCommandKey = { [unowned self] in runKey($0) }
        sidebar.onServer = { [unowned self] in serverAction($0, $1, $2) }
        sidebar.serverMenu = { [unowned self] in serverMenu($0) }
        sidebar.onGitCommand = { [unowned self] in run($0) }
        sidebar.gitMenu = { [unowned self] in gitMenu() }
        sidebar.sectionMenu = { [unowned self] id in
            id != "servers" ? [] : [MenuAction.item("New Server…") { [unowned self] in editServer(SavedServer(), title: "New Server") },
                                    MenuAction.item("Connect…") { [unowned self] in showConnect(ssh: true) },
                                    MenuAction.item("Run on Servers…") { [unowned self] in runOnServers() },
                                    MenuAction.item("Edit SSH Config") { [unowned self] in editSSHConfig() }]
        }
        NotificationCenter.default.addObserver(self, selector: #selector(reloadVolumes), name: NSWindow.didBecomeKeyNotification, object: window)
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            ws.addObserver(self, selector: #selector(reloadVolumes), name: n, object: nil)
        }
        ws.addObserver(self, selector: #selector(volumeGone(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        refreshSidebar()
        reloadVolumes()
        diskWatch = DiskWatch { [weak self] in
            self?.disks = $0
            self?.refreshSidebar()
        }
        let tick = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(volumeTick), userInfo: nil, repeats: true)
        tick.tolerance = 5
    }

    /// Free space moves without a notice: read again every 30 s while Kermo is the app in front.
    @objc private func volumeTick() { if NSApp.isActive { reloadVolumes() } }

    /// Off the main thread: a hung network mount must not freeze the window. ~/.ssh/config comes along
    /// (also when the window becomes key), so edits to it show up without a restart.
    @objc func reloadVolumes() { volumeRuns.request(key: "") }

    /// A panel on a disk that went away leaves it now (up to /Volumes), not at its next re-list.
    @objc private func volumeGone(_ n: Notification) {
        guard let vol = (n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path else { return }
        for p in panels where p.remote == nil && (p.path == vol || p.path.hasPrefix(vol + "/")) { p.reload() }
    }

    /// One at a time: on a dead mount each read hangs for good, and every focus of the window would add another.
    private lazy var volumeRuns = SingleFlight(interval: .zero) { [weak self] in await self?.loadVolumes() }

    private func loadVolumes() async {
        let (new, hosts) = await Blocking.run { (SidebarModel.volumes(), SSHConfig.hosts().map(\.alias)) }
        // Free space differs by some bytes at every read: the sidebar is rebuilt only when what it shows has changed.
        let same = new.map { SidebarModel.row($0) } == volumes.map { SidebarModel.row($0) } && new.map(\.device) == volumes.map(\.device) && hosts == configHosts
        (volumes, configHosts) = (new, hosts)
        if !same { refreshSidebar() }
    }

    /// The sidebar row of where you are: the terminal's tab, the active panel's server tab, or its folder.
    private var sidebarKey: String? {
        if terminal.isShown { return terminal.current?.id.uuidString }
        return active.remoteTabs.first(where: \.isCurrent)?.id.uuidString ?? (active.parked == nil ? active.path : nil)   // parked: no row is it
    }

    func refreshSidebar() {
        guard window != nil else { return }
        var servers = ServerList(saved: savedServers, recents: defaults.stringArray(forKey: "recentServers") ?? [], config: configHosts,
                                 pins: serverPins)
        servers.sessions = terminal.tabs.compactMap { t in
            if case .ssh(let target) = t.kind { ServerSession(id: t.id, kind: .ssh, target: target, running: t.isRunning) } else { nil }
        } + panels.flatMap(\.remoteTabs).map { ServerSession(id: $0.id, kind: .sftp, target: $0.target, dir: $0.dir) }
        servers.connecting = Set(panels.compactMap(\.connecting?.host))
        servers.errors = sftpErrors
        for s in savedServers {
            let key = ServerRow.key(s.target), on = tunnels.listening(s).map(\.title)
            let failed = s.tunnels.compactMap { t in tunnels.state(t, of: s)?.error.map { "\(t.title): \($0)" } }
            if !on.isEmpty { servers.tunnels[key, default: []] += on }
            if !failed.isEmpty { servers.failedTunnels[key, default: []] += failed }
        }
        for st in tunnels.temporaries() {   // Forward Port's: on any server, an unsaved one's row stays while they do
            let key = ServerRow.key(st.server.target)
            servers.tunnels[key, default: []].append(st.tunnel.title + " (temporary)")   // the row's tooltip
            if let e = st.error { servers.failedTunnels[key, default: []].append("\(st.tunnel.title): \(e)") }
            if !servers.forwarded.contains(where: { ServerRow.key($0) == key }) { servers.forwarded.append(st.server.target) }
        }
        sidebar.show(SidebarModel.sections(bookmarks: bookmarks, frecent: frecency.ranked(), volumes: volumes, disks: disks, busy: volumeBusy, servers: servers,
                                           tags: defaults.stringArray(forKey: "recentTags") ?? []))
        sidebar.highlight(sidebarKey)
    }

    /// While ⌃O's shell is up, local places `cd` it instead; servers and tags need the panels.
    private func openPlace(_ place: Place, _ mods: NSEvent.ModifierFlags) {
        if let p = place.path {
            if terminal.isShown { return terminal.cd(p) ? () : NSSound.beep() }
            if mods.contains(.option) { other.navigate(to: p); return }
            if mods.contains(.command), active.remote == nil { active.newTab() }   // from a server tab it gets one anyway
            active.navigate(to: p)
            return
        }
        switch place {
        case .volume(let v): if let d = v.disk, !v.mounted { mountVolume(d) { [unowned self] in openPlace(.folder($0), mods) } }   // then as any place
        case .serverFolder(let e):
            guard let r = Bookmark.remote(e) else { return NSSound.beep() }
            openBookmark(r, newTab: mods.contains(.command), panel: mods.contains(.option) ? other : nil)
        case .server(let r): serverAction(r, .row, mods)
        case .connect: showConnect(ssh: true)
        case .tag(let name):
            if terminal.isShown { toggleTerminal() }
            searchTag(name)
        default: break
        }
    }

    // MARK: - Server sessions (sidebar rows)

    private func panel(with id: UUID) -> PanelViewController? { panels.first { $0.remoteTabs.contains { $0.id == id } } }

    /// Goes to the session's terminal tab, or to its panel and file tab.
    private func showSession(_ s: ServerSession) {
        if s.kind == .ssh {
            terminal.select(s.id)
            if !terminal.isShown { window.makeFirstResponder(terminal.show()) }
            return
        }
        guard let p = panel(with: s.id) else { return }
        if terminal.isShown { toggleTerminal() }
        window.makeFirstResponder(p.table)
        p.showTab(s.id)
    }

    private func closeSession(_ s: ServerSession) {
        if s.kind == .ssh { terminal.close(s.id) } else { panel(with: s.id)?.closeRemote(s.id) }
    }

    /// Disconnect: the server's shared connection ends now (`ssh -O exit`), its SSH sessions with it (their tabs stay,
    /// to reconnect), its file tabs go back to their folders, and its tunnels turn off (else the next client would
    /// connect again). Asks first while an SSH session runs there or a tunnel listens.
    func disconnect(_ t: SFTPTarget) {
        let key = ServerRow.key(t)
        let live = (terminal?.tabs ?? []).filter { $0.isRunning && $0.target.map(ServerRow.key) == key }
        let listening = tunnels.described(server: key)
        let info = [live.isEmpty ? nil : live.count == 1 ? "Its SSH session ends." : "Its \(live.count) SSH sessions end.",
                    listening.isEmpty ? nil : "Its tunnels turn off: \(listening)."].compactMap { $0 }
        Task {
            if !info.isEmpty, await !confirm("Disconnect from \(t.host)?", info: info.joined(separator: " "), ok: "Disconnect") { return }
            await disconnectNow(key)
        }
    }

    func disconnectNow(_ key: String) async {
        SudoPasswords.forget(key)
        looked[key] = nil
        // Their ports close first, so no client logs in again meanwhile; not through `turnOffNow`, whose
        // releaseIdleServers would end the connection only gently.
        for s in savedServers where ServerRow.key(s.target) == key {
            for t in tunnels.listening(s) {
                tunnels.stop(t, of: s)
                saveTunnel(t, of: s, on: false)
            }
        }
        tunnels.stopTemporaries(server: key)   // Forward Port's
        tunnels.endHeld(key)   // connections kept from before the screen locked, or from before an edit
        // First: an SSH tab ending or the last file tab closing lets releaseIdleServers end it only gently (`-O stop`).
        await Masters.stop(now: true) { ServerRow.key($0) == key }
        // Its SSH tabs' ssh too: a master stopped after a wake or a network change is no longer known, nor reachable by
        // `-O exit` (its socket is gone), and keeps a session that ran on it.
        terminal?.hangUp { ServerRow.key($0) == key }
        for p in panels { p.remoteTabs.filter { ServerRow.key($0.target) == key }.forEach { p.closeRemote($0.id) } }
    }

    /// A server row's click or button. SSH / SFTP go to an open session if there is one; ⌘ opens another
    /// (SFTP: in a new tab), ⌥ SFTP in the other panel. The row itself: any open session, else SSH.
    private func serverAction(_ r: ServerRow, _ action: ServerAction, _ mods: NSEvent.ModifierFlags) {
        let plain = mods.isDisjoint(with: [.command, .option])
        switch action {
        case .row: if let s = r.sessions.first { showSession(s) } else { openServer(r, .ssh) }
        case .ssh: if let s = r.ssh.first, plain { showSession(s) } else { openServer(r, .ssh) }
        case .sftp:
            if let s = r.sftp.first, plain { showSession(s) }
            else { openServer(r, .sftp, newTab: mods.contains(.command), panel: mods.contains(.option) ? other : nil) }
        }
    }

    /// Connects, and keeps the server among the latest (a locked one isn't remembered; see `remember`).
    /// `dir`: SFTP in that folder instead of the saved server's start folder. `root`: SFTP through its sudo.
    func openServer(_ r: ServerRow, _ kind: ServerSession.Kind, newTab: Bool = false, panel: PanelViewController? = nil, dir: String? = nil,
                    root: Bool = false) {
        remember(r.address)
        refreshSidebar()
        if kind == .ssh { return openSSH(r.target) }
        openSFTP(r.target.asRoot(root), dir: dir ?? r.saved?.startDir, title: r.title, newTab: newTab, panel: panel)
    }

    func serverMenu(_ place: Place) -> [NSMenuItem] {
        guard case .server(let r) = place else { return [] }
        let copy: @MainActor () -> Void = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(SSHCommand.line(r.target), forType: .string)
        }
        let recent = (defaults.stringArray(forKey: "recentServers") ?? []).contains { a in
            if case let .sftp(t, _)? = ServerAddress.parse(a) { ServerRow.key(t) == r.key } else { false }
        }
        var items: [NSMenuItem?] = [
            MenuAction.item("Open SSH Session") { [unowned self] in openServer(r, .ssh) },
            MenuAction.item("Open SFTP") { [unowned self] in openServer(r, .sftp) },
            MenuAction.item("Open SFTP in New Tab") { [unowned self] in openServer(r, .sftp, newTab: true) },
            MenuAction.item("Open SFTP in Other Panel") { [unowned self] in openServer(r, .sftp, panel: other) },
            MenuAction.item("Open SFTP as Root") { [unowned self] in openServer(r, .sftp, root: true) },
            r.sessions.isEmpty ? nil : MenuAction.item("Close All Sessions") { [unowned self] in r.sessions.forEach(closeSession) },
            r.sessions.isEmpty && !SFTP.masterTargets.contains { ServerRow.key($0) == r.key } ? nil
                : MenuAction.item("Disconnect") { [unowned self] in disconnect(r.target) },
            r.saved.map { unlocked("Copy SSH Command", $0, "copy the command of", copy) } ?? MenuAction.item("Copy SSH Command", copy),
            MenuAction.item("Copy SSH Key to Server…") { [unowned self] in copyKey(to: r.target) },
            MenuAction.item("Show File History") { [unowned self] in showFileHistory(r.target) },
            MenuAction.item("Forward Port…") { [unowned self] in forwardPort(on: r.target) },
            tunnelsItem(for: r.saved, at: r.target),
            MenuAction.item("Services…") { [unowned self] in showServices(on: r.target) },
            MenuAction.item("Containers…") { [unowned self] in showContainers(on: r.target) },
            .separator(),
            MenuAction.item(r.pinned ? "Unpin" : "Pin") { [unowned self] in
                unpin(r.key)
                if !r.pinned {
                    serverPins.append(r.address)
                    Config.save("server-pins.json", serverPins)
                }
                refreshSidebar()
            },
            recent ? MenuAction.item("Remove from Recents") { [unowned self] in
                defaults.set((defaults.stringArray(forKey: "recentServers") ?? []).filter { a in
                    if case let .sftp(t, _)? = ServerAddress.parse(a) { ServerRow.key(t) != r.key } else { true }
                }, forKey: "recentServers")
                refreshSidebar()
            } : nil,
        ]
        if let s = r.saved {
            items += [.separator(),
                      unlocked(s.prod ? "Unmark Production" : "Mark as Production", s, "change") { [unowned self] in setProd(s, !s.prod) },
                      MenuAction.item("Edit…") { [unowned self] in editServer(s, title: "Edit “\(s.title)”") },
                      MenuAction.item("Duplicate…") { [unowned self] in
                          var copy = s
                          copy.id = UUID()
                          copy.name = s.title + " copy"
                          copy.tunnels = s.tunnels.map { var t = $0; t.on = false; return t }   // their ports are the original's
                          editServer(copy, title: "Duplicate “\(s.title)”")
                      },
                      MenuAction.item("Delete…") { [unowned self] in deleteServer(s) }]
        } else {
            items += saveItems(r.address)
        }
        return [.separator()] + items.compactMap { $0 }
    }

    /// Production: its color in the sidebar and the panel headers; delete, overwrite and move there ask first.
    private func setProd(_ s: SavedServer, _ on: Bool) {
        guard let i = savedServers.firstIndex(where: { $0.id == s.id }) else { return }
        savedServers[i].prod = on
        Config.save("servers.json", savedServers)
        refreshSidebar()
        panels.filter { $0.remote != nil || $0.parked != nil }.forEach { $0.showPath() }   // not an archive's or search's header
    }

    /// A menu item that asks for Touch ID first if the server is locked.
    private func unlocked(_ title: String, _ s: SavedServer, _ action: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        MenuAction.item(title) {
            Task { if await ServerLock.authorize(s, action) { run() } }
        }
    }

    /// A recent address or ~/.ssh/config host: keep it as a saved server (an alias keeps its config settings).
    private func saveItems(_ address: String) -> [NSMenuItem?] {
        let isConfig = configHosts.contains(address)
        return [.separator(),
                SavedServer(address: address).map { s in MenuAction.item("Save…") { [unowned self] in editServer(s, title: "Save “\(address)”") } },
                SavedServer(address: address).map { s in
                    var s = s
                    s.prod = true
                    return MenuAction.item("Save as Production…") { [unowned self] in editServer(s, title: "Save “\(address)” as Production") }
                },
                isConfig ? MenuAction.item("Edit SSH Config") { [unowned self] in editSSHConfig() } : nil]
    }

    private static let sidebarButtonID = NSToolbarItem.Identifier("sidebar")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarButtonID, .flexibleSpace, OpsController.toolbarID, search.item.itemIdentifier]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        if id == search.item.itemIdentifier { return search.item }
        if id == OpsController.toolbarID { return ops.toolbarItem }
        guard id == Self.sidebarButtonID else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
        item.label = "Sidebar"
        item.toolTip = "Show/Hide Sidebar  ⌃⌘S"
        item.isBordered = true
        item.target = self
        item.action = #selector(sidebarButton)
        return item
    }

    @objc private func sidebarButton() { run("view.sidebar") }

    /// What works while the terminal covers the panels; `tab.*` act on its tabs then.
    /// Join Tab…: which tab's panes go beside the current tab's.
    func joinTerminalTab() {
        let tabs = terminal.joinable
        guard terminal.isShown, !tabs.isEmpty else { return NSSound.beep() }
        Picker.show(over: window, placeholder: "Show which tab beside this one?", items: tabs.map { g in
            Picker.Item(title: g.title, subtitle: g.panes.count > 1 ? "\(g.panes.count) panes" : "") { [unowned self] in
                terminal.join(g)
                terminal.current.map { window.makeFirstResponder($0.view) }
            }
        })
    }

    static let terminalCommands: Set<String> = ["view.terminal", "tab.new", "tab.close", "tab.next", "tab.prev", "ssh.new", "ssh.reconnect",
                                                "server.disconnect", "go.connect", "view.sidebar", "term.bigger", "term.smaller",
                                                "cmdline.insert", "cmdline.insertPaths", "term.split.right", "term.split.down", "term.join",
                                                "term.unsplit", "term.pane.left", "term.pane.right", "term.pane.up", "term.pane.down",
                                                "term.resize.left", "term.resize.right", "term.resize.up", "term.resize.down"]

    func toggleTerminal() {
        if terminal.isShown {
            // The active panel follows the shell's folder; the others reload for what ⌘E ↩ or the shell did to theirs (sizes,
            // mtimes; the watchers saw the names). Not both on one panel: a reload right after navigate(to:) supersedes it
            // (`loadGen`), and the panel would stay where it was.
            let cwd = terminal.hide(NSApp.currentEvent)
            for p in panels {
                if p === active, let cwd, cwd != p.path { p.navigate(to: cwd) } else { p.reload() }
            }
            window.makeFirstResponder(active.table)
            updatePrompt()
        } else {
            if let v = terminal.showPassingCtrlO(NSApp.currentEvent) { window.makeFirstResponder(v); return }
            // A server panel: its SSH session (or a new one in this folder), never a local shell.
            guard let r = active.remote else { window.makeFirstResponder(terminal.show(cwd: active.path)); return }
            if let t = terminal.tabs.first(where: { $0.kind == .ssh(r.target.asUser) && $0.isRunning }) { terminal.select(t.id) }
            else { terminal.newSSH(r.target, command: SSHCommand.shell(in: r.dir)) }
            window.makeFirstResponder(terminal.show())
        }
    }

    /// `cd` in the terminal's current tab (its shell told its folder): a local shell takes the active panel along; an
    /// SSH tab, a panel already showing that server — never a new connection.
    private func follow(_ tab: EmbeddedTerminal.Tab) {
        updatePrompt()
        guard let dir = tab.cwd else { return }
        if let t = tab.target {
            guard let p = panels.first(where: { $0.remote.map { ServerRow.key($0.target) } == ServerRow.key(t) }),
                  let r = p.remote, r.dir != dir else { return }
            p.loadRemote(r.target, dir: dir, select: nil) { _ in }   // a folder it can't list: the panel stays, quietly
        } else if active.remote == nil, dir != active.path {
            active.navigate(to: dir)
        }
    }

    // MARK: - Command dispatch

    private func runKey(_ event: NSEvent) -> Bool {
        guard let c = keymap[Shortcut(event: event)] else { return false }
        perform(c)
        return true
    }

    func run(_ id: String) {
        guard let c = commands.first(where: { $0.id == id }) else { return }
        perform(c)
    }

    /// Commands that would act on the local folder hidden behind a server panel (its `path`). Until they learn
    /// servers, they refuse there instead of quietly working on this Mac.
    static let localOnly: Set<String> = ["file.info", "go.tree", "panel.swap", "file.reveal", "file.symlink",
                                         "file.hardlink", "file.split", "file.combine", "git.diff", "file.eject", "file.unmount",
                                         "git.log", "git.blame", "git.stage", "git.unstage", "admin.copy", "admin.move", "admin.mkdir", "admin.delete", "admin.shell",
                                         "git.switch", "git.newBranch", "git.commit", "git.sync", "git.publish", "git.pull", "git.push", "git.fetch", "git.init"]

    /// What runs on a parked server tab (`PanelViewController.parked`): going elsewhere, tabs, panels, the view, the
    /// app's windows; ↩ connects. The rest would act on the local folder behind it.
    static func runsParked(_ id: String) -> Bool {
        parkedRuns.contains(id) || id.hasPrefix("panel.focus")
            || !parkedRefuses.contains(id) && ["go", "tab", "view", "app", "help", "ssh", "server", "tunnel", "term"].contains(String(id.prefix { $0 != "." }))
    }
    static let parkedRuns: Set<String> = ["open", "open.inside", "panel.switch", "panel.add", "panel.close", "admin.rootPanel", "admin.userPanel",
                                          "admin.auditLog", "admin.sudoTouchID", "usermenu.edit", "validators.edit"]
    static let parkedRefuses: Set<String> = ["go.tree", "go.linktarget", "view.terminal", "view.dirsizes", "server.history"]

    /// Commands that put files into the other panel (or suggest it), or compare with it: not into a parked one's local folder.
    static let toOther: Set<String> = ["file.copy", "file.move", "panel.compare", "panel.sync", "panel.swap", "panel.same", "admin.copy",
                                       "admin.move", "file.extract", "file.compress", "file.symlink", "file.hardlink"]

    private func perform(_ c: Command) {
        if !terminal.isShown {
            if let hint = active.parkedHint, !Self.runsParked(c.id) { return active.flash(hint) }
            if let hint = other.parkedHint, Self.toOther.contains(c.id) { return active.flash("The other panel: " + hint) }
        }
        if active.remote != nil, !terminal.isShown, Self.localOnly.contains(c.id) { return active.flash("Not available on a server panel") }
        c.run(self)
        keyBar.commandRan(c.id)
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        run(sender.representedObject as! String)
    }

    /// Commands act on the main window's panels only. While a text field is being edited
    /// (path bar, dialogs) or another window is key (viewer), they're disabled so that keys
    /// like ⌘↑ or ⌫ keep their normal text-editing meaning.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(menuCommand(_:)), let id = item.representedObject as? String else { return true }
        if id == "view.hidden" { item.state = defaults.bool(forKey: "showHidden") ? .on : .off }
        if id == "view.perms" { item.state = defaults.bool(forKey: "showPerms") ? .on : .off }
        if id == "app.update" { item.title = updateOffered.map { "Kermo \($0) Available…" } ?? "Check for Updates…" }
        if id == "app.update.auto" { item.state = defaults.bool(forKey: "updateCheckOff") ? .off : .on }
        if id == "tab.close" {
            let closes = Self.windowToClose(key: NSApp.keyWindow, main: window) != nil
            item.title = closes ? "Close Window" : commands.first { $0.id == id }?.title ?? item.title
            if closes { return true }
        }
        if id == "server.history", Editor.server(of: NSApp.keyWindow) != nil { return true }   // its editor's file
        return NSApp.keyWindow === window && canRun(id)
    }

    /// ⌘W (Close Tab) in a viewer, editor or other document window closes that window, through its delegate, so
    /// the editor still asks about unsaved changes. In the main window, or a sheet / picker over it, it closes a tab.
    static func windowToClose(key: NSWindow?, main: NSWindow?) -> NSWindow? {
        guard let key, key !== main, !(key is NSPanel), key.styleMask.contains(.closable) else { return nil }   // panels: alerts, pickers
        return key
    }

    /// Also the key bar's: a click there makes the window key, so only focus and the terminal matter.
    func canRun(_ id: String) -> Bool {
        if terminal.isShown { return Self.terminalCommands.contains(id) }   // panel commands would act on hidden panels
        return !(window.firstResponder is NSText)
    }

    // MARK: - Window content

    private func makeContent() -> NSView {
        split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        for p in panels { split.addArrangedSubview(p.view) }
        // The terminal (⌃O) covers just the panels, so it needs a plain superview next to them, not a split pane.
        let panelsHost = NSViewController()
        panelsHost.view = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        panelsHost.view.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: panelsHost.view.leadingAnchor), split.trailingAnchor.constraint(equalTo: panelsHost.view.trailingAnchor),
            split.topAnchor.constraint(equalTo: panelsHost.view.topAnchor), split.bottomAnchor.constraint(equalTo: panelsHost.view.bottomAnchor),
        ])
        terminal = EmbeddedTerminal(covering: split)
        terminal.onExit = { [unowned self] in window.makeFirstResponder(active.table) }
        // SSH tabs come back after a restart as disconnected placeholders, in their tabs: no connection without a click.
        if let data = defaults.data(forKey: "terminalGroups"), let saved = try? JSONDecoder().decode([EmbeddedTerminal.SavedGroup].self, from: data) {
            terminal.restore(saved)
        } else if let data = defaults.data(forKey: "sshTabs"), let saved = try? JSONDecoder().decode([SFTPTarget].self, from: data) {
            terminal.restore(saved)   // 1.3's, one session a tab
        }
        terminal.onChange = { [unowned self] in
            defaults.set(try? JSONEncoder().encode(terminal.saved), forKey: "terminalGroups")
            defaults.set(try? JSONEncoder().encode(terminal.saved.flatMap(\.panes)), forKey: "sshTabs")   // for a build before 1.4: one a tab
            refreshSidebar()
            releaseIdleServers()
            updatePrompt()
        }
        terminal.onDirectory = { [unowned self] in follow($0) }

        splitController = NSSplitViewController()
        splitController.splitView.autosaveName = "Sidebar"
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapseFromWindowResize = false   // SidebarRule decides, per panel
        sidebarItem.isCollapsed = !(defaults.object(forKey: "sidebarVisible") as? Bool ?? true)
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(NSSplitViewItem(viewController: panelsHost))
        let main = splitController.view

        let bar = keyBar
        bar.onRun = { [unowned self] in run($0) }
        bar.onMore = { [unowned self] in KeyHelp.show(over: window, commands: commands, layer: $0) }
        bar.canRun = { [unowned self] in canRun($0) }
        bar.terminalShown = { [unowned self] in terminal.isShown }

        promptLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        promptLabel.lineBreakMode = .byTruncatingHead
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        promptLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        cmdField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cmdField.placeholderString = Self.commandHint(root: nil)
        cmdField.isBordered = false
        cmdField.drawsBackground = false
        cmdField.focusRingType = .none
        cmdField.delegate = self
        let cmdBar = NSStackView(views: [promptLabel, cmdField])
        cmdBar.spacing = 6
        cmdBar.setHuggingPriority(.defaultHigh, for: .vertical)   // as tall as its line: the panels take the rest (N21)
        cmdBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 2, right: 8)

        let root = NSView()
        for v in [main, cmdBar, ops.view, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: root.topAnchor),
            cmdBar.topAnchor.constraint(equalTo: main.bottomAnchor),
            ops.view.topAnchor.constraint(equalTo: cmdBar.bottomAnchor),
            bar.topAnchor.constraint(equalTo: ops.view.bottomAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        equalizePanels()
        return root
    }

    /// The window (title bar, command line, key bar) and every part that draws its own colors.
    func applyTheme() {
        let t = Theme.current
        window.appearance = t.appearance
        window.backgroundColor = t.background ?? .windowBackgroundColor
        window.titlebarAppearsTransparent = t.background != nil   // the toolbar shows the background too
        promptLabel.textColor = t.hidden
        cmdField.textColor = t.text
        panels.forEach { $0.applyTheme() }
        sidebar.applyTheme()
        terminal.applyTheme()
    }

    /// The registry's menus (`Command.menu`), in menu bar order; Window follows. F1 lists them too (`KeyHelp.groups`).
    static let menus = ["Kermo", "File", "Edit", "Mark", "Admin", "View", "Go", "Git"]

    func makeMenu() -> NSMenu {
        let main = NSMenu()
        @discardableResult func submenu(_ title: String, _ items: [NSMenuItem], trailing: [NSMenuItem] = []) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            for c in commands where c.menu == title {
                let it = NSMenuItem(title: c.title, action: #selector(menuCommand(_:)), keyEquivalent: c.keys.first?.menuKey ?? "")
                it.keyEquivalentModifierMask = c.keys.first?.flags ?? []
                it.target = self
                it.representedObject = c.id
                menu.addItem(it)
            }
            trailing.forEach(menu.addItem)
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.tag = tag
            return it
        }
        let head: [String: [NSMenuItem]] = [
            "File": [item("Save", #selector(Editor.saveDocument(_:)), "s"),
                     item("Ensure Final Newline", #selector(Editor.toggleFinalNewline(_:)), ""), .separator()],
            // Standard responder-chain items: text fields handle them as text; panels as files.
            "Edit": [
                item("Undo", Selector(("undo:")), "z"),
                item("Redo", Selector(("redo:")), "z", [.command, .shift]),
                .separator(),
                item("Copy", #selector(NSText.copy(_:)), "c"),
                item("Paste", #selector(NSText.paste(_:)), "v"),
                item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
                item("Find…", #selector(NSResponder.performTextFinderAction(_:)), "f", tag: NSTextFinder.Action.showFindInterface.rawValue),
                item("Find Next", #selector(NSResponder.performTextFinderAction(_:)), "g", tag: NSTextFinder.Action.nextMatch.rawValue),
                .separator(),
            ],
        ]
        let tail: [String: [NSMenuItem]] = [
            "Kermo": [.separator(), item("Hide Kermo", #selector(NSApplication.hide(_:)), "h"), item("Quit Kermo", #selector(NSApplication.terminate(_:)), "q")],
            "Go": [.separator(), goTunnelsItem()],
        ]
        for title in Self.menus { submenu(title, head[title] ?? [], trailing: tail[title] ?? []) }
        // AppKit lists the open windows below.
        NSApp.windowsMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item("Main Window", #selector(showMainWindow(_:)), "0"),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        return main
    }

    // MARK: - Command line

    /// One check per folder at a time: on a share that stopped answering, each Tab or tab switch would hold one more thread.
    private static let folderChecks = Coalesced<Bool>()

    /// The command line's placeholder. On a root panel it says whose shell ⌘E runs in: the user's, not root's.
    static func commandHint(root: SFTPTarget?) -> String {
        let user = root.map { t in t.host.lastIndex(of: "@").map { String(t.host[..<$0]) } ?? "your user" }
        return "⌘E: shell command in this folder" + (user.map { " as \($0), not root" } ?? "")
            + " · %f %s %d %D · ↩ run in the shell · ⇧↩ output window · ⌘↩ in Terminal · ↑↓ history"
    }

    /// The sidebar's Git section follows the active panel: its work tree, or none.
    private func updateGitRow() {
        sidebar.showGit(active.git.map { GitRow(status: $0, server: active.remote?.target.host) })
    }

    private func updatePrompt() {
        guard panels.indices.contains(activeIndex) else { return }
        cmdField.isHidden = terminal?.isShown == true   // ⌘E doesn't work under the terminal; the prompt label stays (host:cwd of an SSH tab)
        // A tab up front: its shell's folder (an SSH tab's: its server and what the shell told, OSC 7), not the panel's under it.
        let remote: (host: String, dir: String?)?
        var local = active.path
        if terminal?.isShown == true, let t = terminal.current { remote = t.host.map { ($0, t.cwd) }; local = t.folder ?? local }
        else { remote = (active.remote ?? active.parked).map { ($0.target.host, $0.dir) } }
        let path = remote.map { r in r.dir.map { "\(r.host):\($0)" } ?? r.host } ?? (local as NSString).abbreviatingWithTildeInPath
        promptLabel.stringValue = (remote != nil ? "🌐 " : "") + path + " $"   // ⌘E runs as the user, on a root panel too
        let root = terminal?.isShown == true ? nil : (active.remote ?? active.parked).flatMap { $0.target.sudo ? $0 : nil }
        cmdField.placeholderString = Self.commandHint(root: root?.target)
        sidebar.highlight(sidebarKey)
        updateGitRow()
        window?.title = root.map { "\($0.target.shown):\($0.dir) #" }?.bidiVisible ?? path.bidiVisible   // what the panel's header says
        guard remote == nil else { window?.representedURL = nil; return }
        let dir = active.path   // proxy icon, once the folder is known to be there (asked off the main thread)
        Task {
            let exists = await Self.folderChecks.run(dir) { FileManager.default.fileExists(atPath: dir) }
            if panels.indices.contains(activeIndex), active.remote == nil, terminal?.isShown != true, active.path == dir { window?.representedURL = exists ? URL(fileURLWithPath: dir) : nil }
        }
    }

    func focusCommandLine() {
        historyIndex = history.count   // this host's history may be another length than the one ↑ last walked
        window.makeFirstResponder(cmdField)
    }

    /// ⌃↩ / ⌃⇧↩ (MC): the cursor item's name / the marked items' full paths (quoted as for ⌘E) into the command line —
    /// the ⌘E field, or, while the terminal is up, the shell in its current tab (one on the panel's machine). Focus stays.
    func insertIntoCommandLine(paths: Bool) {
        guard let text = shellContext.expand(paths ? "%S" : "%f"), !text.isEmpty else { return NSSound.beep() }
        if terminal.isShown {
            if !terminal.insert(text + " ", on: active.remote?.target) { NSSound.beep() }
        } else {
            let cur = cmdField.stringValue
            cmdField.stringValue = cur + (cur.isEmpty || cur.hasSuffix(" ") ? "" : " ") + text + " "
        }
    }

    /// ⌘E history is per host — the local one and each server's — so `rm …` typed on a server isn't offered here (R1).
    private var history: [String] {
        get { defaults.stringArray(forKey: Self.historyKey(active.remote?.target)) ?? [] }
        set { defaults.set(newValue, forKey: Self.historyKey(active.remote?.target)) }
    }
    /// "cmdHistory" locally (as before), "cmdHistory.deploy@web:22" on a server.
    nonisolated static func historyKey(_ server: SFTPTarget?) -> String { server.map { "cmdHistory.\($0.host):\($0.port ?? 22)" } ?? "cmdHistory" }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === cmdField else { return false }
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):   // ↩ and ⇧↩; ⌘↩ is a key equivalent (the keyDown monitor), ⌃↩ / ⌥↩ other selectors
            runCommandLine(in: NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .window : .shell)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            guard !history.isEmpty else { return true }
            historyIndex = min(max(historyIndex + (sel == #selector(NSResponder.moveUp(_:)) ? -1 : 1), 0), history.count)
            textView.string = historyIndex < history.count ? history[historyIndex] : ""
            textView.selectedRange = NSRange(location: textView.string.utf16.count, length: 0)
        case #selector(NSResponder.cancelOperation(_:)):
            window.makeFirstResponder(active.table)
        default:
            return false
        }
        return true
    }

    /// ↩ / ⇧↩ / ⌘↩ in the ⌘E field: the line goes to its history and runs where `dest` says; the focus returns to the panel.
    private func runCommandLine(in dest: ShellWhere) {
        let command = cmdField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        if let hint = active.parkedHint { return active.flash(hint) }   // it'd run in the local folder behind it
        var h = history
        h.removeAll { $0 == command }
        h.append(command)
        history = Array(h.suffix(200))
        historyIndex = history.count
        cmdField.stringValue = ""
        window.makeFirstResponder(active.table)
        runShell(command, in: dest)
    }

    func controlTextDidBeginEditing(_ obj: Notification) { historyIndex = history.count }

    // MARK: - Dialogs (sheets on the main window)

    /// `select`: what's selected in `value` (else all of it, or its base name with `selectBaseName`).
    func prompt(_ message: String, value: String, ok: String, info: String = "", selectBaseName: Bool = false, select: NSRange? = nil) async -> String? {
        let alert = NSAlert()
        alert.messageText = message.bidiVisible
        alert.informativeText = info.bidiVisible
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response: NSApplication.ModalResponse = await withCheckedContinuation { cont in
            alert.beginSheetModal(for: window) { cont.resume(returning: $0) }
            if selectBaseName {   // "report.txt" → select "report", like Finder
                let base = (value as NSString).deletingPathExtension
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base.isEmpty ? value : base).utf16.count)
            }
            if let select { field.currentEditor()?.selectedRange = select }
        }
        window.makeFirstResponder(active.table)
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// A root panel's sudo password for `t`'s server: a sheet on the window in front (an editor saving, say), never shown
    /// again or kept anywhere but `SudoPasswords` (and the Keychain, if ticked). `wrong`: sudo refused the one before.
    func askSudoPassword(_ t: SFTPTarget, wrong: Bool) async -> (password: String, save: Bool)? {
        let alert = NSAlert()
        alert.messageText = (wrong ? "Sorry, try again: " : "") + "sudo password on \(t.host)"
        alert.informativeText = "For root there: a root panel, a reload, a restart. It goes to sudo there, through ssh, and nowhere else."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(string: "")
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let save = NSButton(checkboxWithTitle: "Save in Keychain", target: nil, action: nil)
        save.toolTip = "Kept as “Kermo sudo” in the login keychain, apart from the ssh password; gone once sudo refuses it, or with the saved server"
        let stack = NSStackView(views: [field, save])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 52)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        // On a Picker that stays open while it asks (a restart from Services…), else not on a panel that closes then.
        let over: NSWindow = Picker.current.flatMap { $0.isHolding ? $0.window : nil } ?? NSApp.keyWindow.flatMap { $0 is NSPanel ? nil : $0 } ?? window
        let response: NSApplication.ModalResponse = await withCheckedContinuation { cont in
            alert.beginSheetModal(for: over) { cont.resume(returning: $0) }
        }
        return response == .alertFirstButtonReturn ? (field.stringValue, save.state == .on) : nil
    }

    /// A sheet with `buttons` (the last one is Cancel / ⎋) on `sheetWindow` (default: the main one); returns the index pressed.
    /// `default`: the button ↩ answers (else the first). Esc still answers Cancel when ↩ took its key.
    func choose(_ message: String, info: String, _ buttons: [String], default: Int? = nil, on sheetWindow: NSWindow? = nil) async -> Int {
        if let answer = Self.answering { return answer(message, buttons, `default`) }
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }   // asked by a save in another app: the Dock icon bounces
        return await Self.sheet(Self.alert(message, info: info, buttons, default: `default`), on: sheetWindow ?? window)
    }

    /// Tests: answers `choose` instead of a sheet (the message, the buttons, the one ↩ presses).
    static var answering: (@MainActor (String, [String], Int?) -> Int)?

    /// `alert` as a sheet on `window`; the button's index. A Cancel that took ↩ (`alert(default:)`) answers ⎋ too.
    static func sheet(_ alert: NSAlert, on window: NSWindow) async -> Int {
        let esc = alert.buttons.first { $0.title == "Cancel" && $0.keyEquivalent == "\r" }.map { cancel in
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard e.keyCode == 53, e.window === alert.window else { return e }
                cancel.performClick(nil)
                return nil
            }
        }
        defer { esc.map(NSEvent.removeMonitor) }
        let response: NSApplication.ModalResponse = await withCheckedContinuation { cont in
            alert.beginSheetModal(for: window) { cont.resume(returning: $0) }
        }
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func alert(_ message: String, info: String, _ buttons: [String], default: Int? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message.bidiVisible
        alert.informativeText = info.bidiVisible
        alert.alertStyle = .warning
        buttons.forEach { alert.addButton(withTitle: $0) }
        if let d = `default` {   // a button has one key: ↩ moves to it, off the rest
            alert.buttons.forEach { $0.keyEquivalent = $0.title == "Cancel" ? "\u{1b}" : "" }   // a Cancel keeps ⎋
            alert.buttons[d].keyEquivalent = "\r"
        }
        return alert
    }

    func confirm(_ message: String, info: String, ok: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message.bidiVisible
        alert.informativeText = info.bidiVisible
        alert.alertStyle = .warning
        alert.addButton(withTitle: ok).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse = await withCheckedContinuation { cont in
            alert.beginSheetModal(for: window) { cont.resume(returning: $0) }
        }
        return response == .alertFirstButtonReturn
    }

    func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = alert.messageText.bidiVisible
        alert.beginSheetModal(for: window)
    }
}
