import AppKit
import DFMCore

extension AppDelegate {
    // MARK: - Servers: SSH tabs (⌘K), SFTP panels (⌃⌘K) and smb/nfs/afp mounts

    /// ⌃⌘K: SFTP (or a smb/nfs mount) in the active panel; `ssh` (⌘K): an SSH tab in the terminal.
    func showConnect(ssh: Bool = false) {
        Task { await ServerLock.learn(again: true) }   // ~/.ssh/config may have changed
        let kind: ServerSession.Kind = ssh ? .ssh : .sftp
        let label = ssh ? "SSH" : "SFTP"
        func key(_ address: String) -> String? {
            if case let .sftp(t, _)? = ServerAddress.parse(address) { ServerRow.key(t) } else { nil }
        }
        let savedKeys = Set(savedServers.map { ServerRow.key($0.target) })
        let hosts = SSHConfig.hosts().filter { !savedKeys.contains(ServerRow.key(SFTPTarget(host: $0.alias))) }
        var listed = savedKeys.union(hosts.map { ServerRow.key(SFTPTarget(host: $0.alias)) })
        let recents = (defaults.stringArray(forKey: "recentServers") ?? []).filter { a in
            guard let k = key(a) else { return !ssh }   // smb / nfs: SFTP's picker only
            return listed.insert(k).inserted
        }
        let go: @MainActor (String) -> Void = { [unowned self] in ssh ? openSSH($0) : connect($0) }
        let items = [Picker.Item(title: "New Server…", subtitle: "user, port, key, password, lock", badges: [Symbol.add.image("New")], verb: "New Server") { [unowned self] in
                editServer(SavedServer(), title: "New Server", connect: kind)
            }]
            + savedServers.map { s in
                Picker.Item(title: s.title, subtitle: ServerRow.address(s.target), badges: s.chips.map(\.image), detail: label,
                            actions: [.init(key: Shortcut("cmd+e")!, label: "Edit") { [unowned self] in editServer(s, title: "Edit Server") }],
                            verb: "Connect") { [unowned self] in
                    openServer(ServerRow(target: s.target, saved: s, title: s.title), kind)
                }
            }
            + hosts.map { h in
                let detail = (h.user.map { "\($0)@" } ?? "") + (h.hostName ?? h.alias) + (h.port.map { ":\($0)" } ?? "")
                return Picker.Item(title: h.alias, subtitle: "~/.ssh/config · " + detail, detail: label, verb: "Connect") { go(h.alias) }
            }
            + recents.map { r in Picker.Item(title: r, subtitle: "recent", detail: key(r) == nil ? "mount" : label, verb: key(r) == nil ? "Mount" : "Connect") { go(r) } }
            + [Picker.Item(title: "Edit SSH Config…", subtitle: "~/.ssh/config", verb: "Edit") { [unowned self] in editSSHConfig() }]
        Picker.show(over: window, placeholder: ssh ? "Server, user@host or ssh://host:port" : "Server, user@host:/path, sftp://, smb:// or nfs://",
                    scope: (ssh ? "SSH" : "SFTP", []), items: items, freeText: { q in
            q.isEmpty ? [] : [Picker.Item(title: (ssh ? "SSH to" : "Connect to") + " “\(q)”", verb: "Connect") { go(q) }]
        })
    }

    /// Opens ~/.ssh/config in the editor; made first if missing, owner-only (ssh refuses a config others can write).
    func editSSHConfig() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh"), path = dir + "/config"
        if !FileManager.default.fileExists(atPath: path) {
            if !FileManager.default.fileExists(atPath: dir) { mkdir(dir, 0o700) }
            FileManager.default.createFile(atPath: path, contents: Data("# Host myserver\n#     HostName 203.0.113.10\n#     User me\n#     Port 22\n".utf8),
                                           attributes: [.posixPermissions: 0o600])
        }
        openInEditor(URL(fileURLWithPath: path))
    }

    /// Not a locked server's: neither a refused attempt nor where it's been is anyone's business (a pin keeps its place).
    /// Once its address is learned, so an alias of a locked server isn't remembered either (D-081).
    func remember(_ input: String) {
        let before = Self.remembering
        Self.remembering = Task {
            await before?.value   // in the order asked, whichever address is learned first
            if case let .sftp(t, _)? = ServerAddress.parse(input) {
                await ServerLock.learn([t])
                if ServerLock.server(for: t) != nil { return }
            }
            var recents = defaults.stringArray(forKey: "recentServers") ?? []
            recents.removeAll { $0 == input }
            recents.insert(input, at: 0)
            defaults.set(Array(recents.prefix(30)), forKey: "recentServers")   // the sidebar finds 5 different servers in them
            refreshSidebar()
        }
    }

    static var remembering: Task<Void, Never>?

    /// A new SSH tab in the terminal workspace (shown if hidden). A path in the address is ignored.
    func openSSH(_ input: String) {
        guard case let .sftp(target, _)? = ServerAddress.parse(input) else { return NSSound.beep() }
        remember(input)
        openSSH(target)
    }

    func openSSH(_ target: SFTPTarget, command: String? = nil) {
        let view = terminal.newSSH(target, command: command)
        window.makeFirstResponder(terminal.isShown ? view : terminal.show())   // opens the drawer if it was closed
    }

    /// A server's files in a panel, from `dir` (nil: the login folder). Remembering it is the caller's business.
    func openSFTP(_ t: SFTPTarget, dir: String?, title: String, newTab: Bool = false, panel: PanelViewController? = nil) {
        showPanels()
        let panel = panel ?? active
        Task {   // a locked one asks before the new tab, not after (loadRemote would leave it behind)
            if newTab {
                guard await ServerLock.authorize(t) else { return panel.flash("\(title) stays locked") }
                panel.newTab()
            }
            panel.loadRemote(t, dir: dir, select: nil)
        }
    }

    /// The New / Edit / Duplicate / Save sheet; a locked server (or one at its address) asks for Touch ID first,
    /// whichever way it was opened. A server ssh can't take comes back with the reason and what was typed.
    /// A server not saved yet gets Save & Connect (`connect`: which kind) besides Save; a saved one Delete….
    func editServer(_ server: SavedServer, title: String, connect: ServerSession.Kind = .ssh) {
        Task {
            if Config.changedOutside("servers.json") { _ = reloadServers() }   // edited by hand: the sheet and Touch ID go by the file
            let server = savedServers.first { $0.id == server.id } ?? server
            guard await ServerLock.authorize(server, "edit") else { return }
            showServerSheet(server, title: title, connect: connect)
        }
    }

    /// `ServerForm` in a sheet. A server not saved yet: Save & Connect (⌘↩; `connect`: which kind), Save (↩), Cancel; a
    /// saved one: Save, Delete…, Cancel. Save waits until ssh could take what's typed (`SavedServer.issue`, said under
    /// its field). A root panel's sudo password saved there ("Save in Keychain" in its sheet) can only be forgotten here.
    private func showServerSheet(_ server: SavedServer, title: String, connect: ServerSession.Kind) {
        let saved = savedServers.contains { $0.id == server.id }
        let form = ServerForm(server, hasPassword: !server.host.isEmpty && SSHPasswords.has(server.target),
                              hasSudo: !server.host.isEmpty && SSHPasswords.has(server.target, sudo: true))
        let alert = NSAlert()
        alert.messageText = title.bidiVisible
        for b in saved ? ["Save", "Delete…", "Cancel"] : ["Save & Connect", "Save", "Cancel"] {
            alert.addButton(withTitle: b).hasDestructiveAction = b == "Delete…"
        }
        let saves = saved ? [alert.buttons[0]] : [alert.buttons[0], alert.buttons[1]]
        var below = [form.grid as NSView]
        if !saved {   // ↩ Save, as Edit's; ⌘↩ Save & Connect (not ⌃↩: a text field's context menu, D-107)
            alert.buttons[1].keyEquivalent = "\r"
            alert.buttons[0].identifier = Confirm.commandReturn
            let font = NSFont.systemFont(ofSize: 11), s = NSMutableAttributedString()
            let word = { (w: String) in NSAttributedString(string: " " + w, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]) }
            s.append(KeyCap.text("↩", font: font)); s.append(word("Save  ·  "))
            s.append(KeyCap.text("⌘↩", font: font)); s.append(word("Save & Connect"))
            below.append(NSTextField(labelWithAttributedString: s))
        }
        let stack = NSStackView(views: below)
        (stack.orientation, stack.alignment, stack.spacing) = (.vertical, .leading, 10)
        let fit = { stack.setFrameSize(stack.fittingSize) }
        fit()
        alert.accessoryView = stack
        form.onChange = { [weak alert] in
            fit()
            alert?.layout()
            for b in saves { b.isEnabled = form.typed.issue == nil }
        }
        for b in saves { b.isEnabled = form.typed.issue == nil }
        alert.window.initialFirstResponder = server.host.isEmpty ? form.host : form.name
        alert.window.autorecalculatesKeyViewLoop = true   // Tab: the groups' order
        Task {
            let r = await AppDelegate.sheet(alert, on: window)
            window.makeFirstResponder(active.table)
            if saved && r == 1 { return deleteServer(server) }
            let connecting = !saved && r == 0
            guard r == 0 || (!saved && r == 1) else { return }
            var s = form.typed
            guard s.issue == nil else { return NSSound.beep() }   // its buttons were off
            var old: SavedServer?, stale = false
            guard editServers({ all in   // the sheet's fields; its tunnels as they are now, not when the sheet opened
                guard let i = all.firstIndex(where: { $0.id == s.id }) else { return all.append(s) }
                var then = all[i]
                then.tunnels = server.tunnels
                guard then == server else { stale = true; return }   // changed by hand while the sheet was open: not written over
                (old, s.tunnels, all[i]) = (all[i], all[i].tunnels, s)
            }), !stale else {
                if stale { showError(JobErrorMessage("“\(server.title)” changed in servers.json while you edited it: nothing saved. Edit it again.")) }
                return
            }
            let status = storePassword(old: old, new: s, typed: form.newPassword, forget: form.forget?.state == .on, forgetSudo: form.forgetSudo?.state == .on)
            if status != errSecSuccess {
                showError(JobErrorMessage("Couldn't save the password in the Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")"))
            }
            refreshSidebar()
            if old?.prod != s.prod { prodChanged() }
            if connecting { openServer(ServerRow(target: s.target, saved: s, title: s.title), connect) }
            _ = form
        }
    }

    /// A password never follows an address change: Edit could otherwise hand it to whatever server was typed in.
    /// Typed: saved for the (new) address. Forget: removed — only where it was (a moved server's new address may hold
    /// another one's). Nothing typed: whatever that address has stays. `forgetSudo`: the sudo password saved where it was
    /// goes, from memory too.
    @discardableResult
    func storePassword(old: SavedServer?, new s: SavedServer, typed: String, forget: Bool, forgetSudo: Bool = false) -> OSStatus {
        let moved = old.map { !SSHPasswords.sameKey($0.target, s.target) } ?? false
        if forgetSudo {
            let at = (old ?? s).target
            SSHPasswords.set(nil, for: at, sudo: true)
            SudoPasswords.forget(SudoPasswords.key(at))
        }
        if let old, moved { forgetPassword(old) }
        if !typed.isEmpty { return SSHPasswords.set(typed, for: s.target) }
        return forget && !moved ? SSHPasswords.set(nil, for: s.target) : errSecSuccess
    }

    func deleteServer(_ s: SavedServer) {
        Task {
            guard await ServerLock.authorize(s, "delete") else { return }
            let listening = tunnels.listening(s).isEmpty ? "" : " Its tunnels turn off: \(tunnels.described(server: ServerRow.key(s.target)))."
            let info = "Its saved passwords too. Open sessions stay open." + listening, history = historyToDelete(with: s)
            var c = Confirm("Delete the saved server “\(s.title)”?", action: "Delete")
            (c.chips, c.place, c.irreversible) = (s.chips, s.title, true)
            c.note = info + (history == nil ? "" : " Its file history — the versions its saves kept on this Mac — can go too.")
            c.others = history == nil ? [] : ["Delete with File History"]
            let answer = await confirm(c)
            guard answer < c.buttons.count - 1 else { return }
            guard editServers({ $0.removeAll { $0.id == s.id } }) else { return }   // still in the file: its password and history stay
            forgetPassword(s)
            unpin(ServerRow.key(s.target))   // else it'd stay as a pinned bare address
            tools.unpinFromMenuBar(s)
            tools.monitor.forget(s.id)   // its watching's history: nothing shows it now
            refreshSidebar()
            if answer == 1, let history { do { try FileManager.default.removeItem(atPath: history) } catch { showError(error) } }
        }
    }

    /// The server's file history folder, if it has one that no other saved server at its address keeps using.
    func historyToDelete(with s: SavedServer) -> String? {
        let h = ServerHistory(root: Self.historyRoot), dir = h.folder(s.target)
        guard !savedServers.contains(where: { $0.id != s.id && h.folder($0.target) == dir }) else { return nil }
        return FileManager.default.fileExists(atPath: dir) ? dir : nil
    }

    /// Show File History (a server's sidebar menu): its folder of versions (`ServerHistory`) in the active panel, to
    /// browse, view, compare or delete (F8) like any other.
    func showFileHistory(_ t: SFTPTarget) {
        Task {
            if await !ServerLock.authorize(t, "see the file history on") { return }
            let dir = ServerHistory(root: Self.historyRoot).folder(t)
            guard FileManager.default.fileExists(atPath: dir) else { return active.flash("No file history for \(t.host) yet: each save of one of its files keeps the version it replaces") }
            active.navigate(to: dir)
        }
    }

    func unpin(_ key: String) {
        serverPins.removeAll { a in
            if case let .sftp(t, _)? = ServerAddress.parse(a) { ServerRow.key(t) == key } else { true }
        }
        Config.save("server-pins.json", serverPins)
    }

    /// Keeps a password another saved server still logs in with. Its sudo password (root panels) goes with it.
    private func forgetPassword(_ s: SavedServer) {
        guard !savedServers.contains(where: { SSHPasswords.sameKey($0.target, s.target) }) else { return }
        SSHPasswords.set(nil, for: s.target)
        SSHPasswords.set(nil, for: s.target, sudo: true)
    }

    func connect(_ input: String, newTab: Bool = false, panel: PanelViewController? = nil) {
        guard let address = ServerAddress.parse(input) else { return NSSound.beep() }
        remember(input)
        refreshSidebar()
        showPanels()   // SFTP lives in the panels
        let active = panel ?? self.active
        switch address {
        case let .sftp(target, path):
            if newTab { active.newTab() }
            active.loadRemote(target, dir: path, select: nil)
        case .mount(let url):
            active.flash("Mounting \(url.host ?? url.absoluteString)…")
            let panel = active
            NetworkMount.mount(url) { [unowned self] result in
                switch result {
                case .success(let point): panel.navigate(to: point)
                case .failure(let error): showError(error)
                }
            }
        }
    }

    enum RemoteOpen { case open, view, edit }

    /// ↩ on a server's file or an archive's: its copy in its own app, quarantined first. Replaced in tests: nothing opens.
    static var openInApp: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Downloads the cursor file to a temp folder, then opens / views / edits it.
    /// Editing uploads the file back after every save — one upload at a time, and never over changes someone
    /// made on the server meanwhile without asking.
    func remoteOpen(_ how: RemoteOpen) {
        guard let (target, dir, item) = active.remoteCursor, item.kind != .dir else { return NSSound.beep() }
        remoteOpen(how, target, (dir as NSString).appendingPathComponent(item.name), listed: (item.size, item.mtime), in: active)
    }

    /// The same for a server's file by its path (⌘E on a service: its unit file). `listed`: its size and time as a
    /// panel listed it (another app's saves check against them); none, as downloaded.
    /// `line`: the editor goes to it ("42", "42:5"); `then`: its tab, once it's there — nil if it couldn't be (`Editor.open`).
    func remoteOpen(_ how: RemoteOpen, _ target: SFTPTarget, _ remotePath: String, listed: (Int64, Double)? = nil, line: String? = nil,
                    in panel: PanelViewController, then: (@MainActor (Editor?) -> Void)? = nil) {
        if how == .edit, let e = Editor.editing(target, remotePath) {   // one file, one tab: no second copy (a parked one opens)
            e.revealed()
            e.connect(goingTo: line)
            then?(e)
            return
        }
        let name = (remotePath as NSString).lastPathComponent
        let tmp = NSTemporaryDirectory() + "dfm-sftp-" + UUID().uuidString
        mkdir(tmp, 0o700)
        let local = URL(fileURLWithPath: tmp).appendingPathComponent(name)
        let env = SSHAskpass.env
        // F3 on a big log: its tail.
        let last = how == .view ? Viewer.tailLimit(for: name) : nil
        Task {
            let r = await panel.busy("Downloading “\(name)”…") { flag in
                try SFTPClient.session(target, env: env, cancel: flag) {   // the editor reads 32 MB at most: no more comes
                    try $0.download(remotePath, to: local.path, last: last, max: how == .edit ? Editor.sizeLimit : nil)
                }
            }
            guard case .success(let opened) = r else {
                TempCopies.remove(tmp)
                then?(nil)
                if case .failure(let e) = r, !(e is CancellationError) {   // F4 on a big one: as the editor says it
                    showError(e is SFTPClient.TooBig ? JobErrorMessage("“\(name)” is larger than 32 MB — use the viewer (F3).") : e)
                }
                return
            }
            switch how {
            case .open:   // another app: its saves go up as F4's do
                FileInfo.quarantine(local.path)
                ServerCopies.add(.init(local, target, remotePath, listed: listed ?? (opened.size, opened.mtime), baseline: opened, preview: false))
                Self.openInApp(local)
            case .view: Viewer.show(local, remote: (target, remotePath, max(0, opened.size - (last ?? opened.size)))) { TempCopies.remove(tmp) }
            case .edit:   // opened meanwhile: that tab (`Editor.open`), this copy goes
                let state = RemoteEdit(baseline: opened)
                let note = Self.rootsOnly(opened, for: target) ? "“\(name)” is root's: saving it needs the panel as root (⌃⌘R)" : nil
                let (onSaved, onClose) = remoteEditing(target, remotePath, state, in: tmp)
                Editor.open(local, remote: SavedServer.title(target, remotePath), server: (target, remotePath, state), note: note, line: line,
                            onSaved: onSaved, onClose: onClose, then: then)
            }
        }
    }

    /// A parked editor tab's server file (restored from the last launch), downloaded into it — after `ServerLock`, as a
    /// panel's would be. False if it couldn't be (said).
    func remoteOpen(into e: Editor, _ target: SFTPTarget, _ remotePath: String) async -> Bool {
        let tmp = NSTemporaryDirectory() + "dfm-sftp-" + UUID().uuidString, env = SSHAskpass.env
        mkdir(tmp, 0o700)
        let local = URL(fileURLWithPath: tmp).appendingPathComponent((remotePath as NSString).lastPathComponent)
        let panel = panels.first { $0.remote?.target == target } ?? active
        let r = await panel.busy("Downloading “\(local.lastPathComponent)”…") { flag in
            try SFTPClient.session(target, env: env, cancel: flag) { try $0.download(remotePath, to: local.path, max: Editor.sizeLimit) }
        }
        var loaded: Result<Editor.Loaded, Error> = .failure(CancellationError())
        if case .success = r { loaded = await Blocking.run(.userInitiated) { Result { try Editor.load(local) } } }
        guard case .success(let attrs) = r, case .success(let text) = loaded else {
            TempCopies.remove(tmp)
            if case .failure(let error) = r, !(error is CancellationError) { e.flash(error.localizedDescription) }
            if case .success = r, case .failure(let error) = loaded { e.flash(error.localizedDescription) }
            return false
        }
        guard Editor.editing(target, remotePath) === e else { TempCopies.remove(tmp); return false }   // its tab closed meanwhile
        let state = RemoteEdit(baseline: attrs), (onSaved, onClose) = remoteEditing(target, remotePath, state, in: tmp)
        e.opened(local, text, state: state, onSaved: onSaved, onClose: onClose)
        return true
    }

    /// What a server file's editor does on Save and when its tab closes (F4's, a restored draft's): the copy in `tmp`
    /// goes up after the saves before it; the folder goes after the last upload. A restored draft's copy is made by its
    /// first Save.
    func remoteEditing(_ target: SFTPTarget, _ remotePath: String, _ state: RemoteEdit, in tmp: String) -> (onSaved: @MainActor (URL) -> Void, onClose: @MainActor () -> Void) {
        ({ [self] saved in
            state.save(in: tmp) {
                if state.unlockFirst {
                    guard await ServerLock.authorize(target, "save a file to") else { return self.notSaved(saved, to: target, CancellationError()) }
                    state.unlockFirst = false
                }
                return await self.upload(saved, to: remotePath, on: target, state)
            }
        }, { state.closed(removing: tmp) })
    }

    /// A server file only root may write — root's, no write bit for group or others — opened by another user: one
    /// named in the address (an alias's user is ~/.ssh/config's, maybe root: then nothing is said).
    static func rootsOnly(_ a: SFTPClient.Attrs, for t: SFTPTarget) -> Bool {
        !t.sudo && a.uid == 0 && (a.mode ?? 0) & 0o022 == 0 && t.host.contains("@") && !t.host.hasPrefix("root@")
    }

    @MainActor final class RemoteEdit {
        var baseline: SFTPClient.Attrs
        /// The latest save's upload (after the ones before it): false if that text didn't reach the server.
        var upload: Task<Bool, Never>?
        private var saves = 0
        /// Overwriting the file on a production server was okayed: later saves of this editor don't ask.
        var prodConfirmed = false
        /// The save asks first: a production server's, until okayed once.
        @MainActor func asks(_ t: SFTPTarget) -> Bool { !prodConfirmed && SavedServer.isProd(t) }
        /// Saves of all editors not yet through (running or waiting): quitting stops them.
        static private(set) var uploading = 0
        /// This one's: its draft keeps the text meanwhile (a crash mid-upload leaves it ↑, not in a temp copy only).
        private(set) var sending = 0
        /// A draft back from the last launch: no connection made for it yet, so its first save asks to unlock a locked server.
        var unlockFirst = false
        init(baseline: SFTPClient.Attrs) { self.baseline = baseline }

        /// A save goes up after the ones before it. Until it's on the server, and no later save waits, the copy is
        /// marked kept: quitting mid-upload must not leave the only copy of that text to the launch sweep.
        func save(in dir: String, _ send: @escaping @MainActor () async -> Bool) {
            TempCopies.keep(dir)
            saves += 1
            Self.uploading += 1
            sending += 1
            let previous = upload, n = saves
            upload = Task {
                defer { Self.uploading -= 1; sending -= 1 }
                _ = await previous?.value
                let ok = await send()
                if ok && saves == n { TempCopies.unkeep(dir) }
                return ok
            }
        }

        /// The editor closed: the local copy goes once the last save is on the server — never while it uploads, and
        /// not if it failed (then the copy is the only one of that text: marked kept, the launch sweep leaves it).
        @discardableResult
        func closed(removing dir: String) -> Task<Void, Never> {
            Task { [upload] in if await upload?.value ?? true { TempCopies.remove(dir) } else { TempCopies.keep(dir) } }
        }
    }

    /// Where saves to a server keep the versions they replace (tests: a folder of their own).
    static var historyRoot = Config.path("history.noindex")
    /// nil once `defaults write com.dmn.dfilemanager serverHistory -bool false`.
    var serverHistory: ServerHistory? { defaults.object(forKey: "serverHistory") as? Bool ?? true ? ServerHistory(root: Self.historyRoot) : nil }

    /// Every save of a server file (F4's ⌘S, another app's, Revert) goes here. The version it replaces goes into the
    /// file history; if it can't, the save goes on and the status line says why.
    /// `told`: the assistant's save (`write_file`) — what went wrong, or wasn't done after, is told in words, never
    /// asked in a sheet nobody is at; the production log says it was its.
    func upload(_ saved: URL, to remotePath: String, on target: SFTPTarget, _ state: RemoteEdit, force: Bool = false, action: String = "save",
                told: (@MainActor (String) -> Void)? = nil) async -> Bool {
        // One save to a server file at a time, from any editor, copy or revert: two at once each passed the check
        // against the same version, and the last rename won — the other's text gone, unasked. The later one now
        // checks against what the earlier wrote, and asks.
        let key = ServerRow.key(target.asUser) + ":" + remotePath, before = Self.uploads[key]
        let assistant = told != nil
        let mine = Task { @MainActor in
            _ = await before?.value
            // Stopped while the save before it was at its question: the assistant's doesn't go in after.
            if assistant, Task.isCancelled { told?("Stopped. Nothing was written."); return false }
            return await uploadNow(saved, to: remotePath, on: target, state, force: force, action: action, told: told)
        }
        Self.uploads[key] = mine
        let ok = await withTaskCancellationHandler { await mine.value } onCancel: { if assistant { mine.cancel() } }
        if Self.uploads[key] == mine { Self.uploads[key] = nil }
        return ok
    }
    private static var uploads: [String: Task<Bool, Never>] = [:]

    private func uploadNow(_ saved: URL, to remotePath: String, on target: SFTPTarget, _ state: RemoteEdit, force: Bool, action: String,
                           told: (@MainActor (String) -> Void)? = nil) async -> Bool {
        let name = (remotePath as NSString).lastPathComponent   // the copy's own, but not a version's (Revert)
        let by = told == nil ? nil : "ai"
        /// The assistant's: said, and the save is over — the file there as it was.
        func tell(_ what: String) -> Bool { told?(what); return false }
        if state.asks(target) {
            var c = Confirm("Save “\(name)” to \(SavedServer.name(for: target))?", on: target, action: "Save")
            c.note = "This overwrites the file there."
            let editing = Editor.window(for: saved) != nil   // an editor's save: not a Revert, not another app's
            if editing { c.others = ["Show Changes"] }
            switch await confirm(c, on: Editor.asking(about: saved)) {
            case 0: break
            case 1 where editing:   // this save doesn't happen (nothing written); the file there now beside the text: ⌘S asks again
                _ = notSaved(saved, to: target, CancellationError())
                let panel = panels.first { $0.remote?.target == target } ?? active
                Task { await diff(Self.serverNow(remotePath, on: target), DiffSide(path: saved.path, name: "\(name) (yours)", origin: (target, remotePath)), in: panel) }
                return false
            default: return notSaved(saved, to: target, CancellationError())   // the editor may be gone: says where the text is
            }
            state.prodConfirmed = true
        }
        let env = SSHAskpass.env, baseline = state.baseline, history = serverHistory
        // No panel of its own: the one showing that server (else the active one) says it's saving; ⎋ there cancels.
        let panel = panels.first { $0.remote?.target == target } ?? active
        // A tool's folder there (`{base}`), if this may be its file.
        guard await tools.near(remotePath, on: target, in: panel) != nil, told == nil || !Task.isCancelled else {
            return told != nil ? tell("Stopped. Nothing was written.") : notSaved(saved, to: target, CancellationError())
        }
        let (rule, problem) = checkRule(for: remotePath, on: target)
        // A session of its own, not the panel's: that one closes when the panel leaves the server, or after a wake or a
        // network change — mid-save, a file written into (SELinux, another owner's) would be left cut. A root save
        // costs its own sudo then: where sudo wants a password, not in the Keychain and past its 5 minutes, it is asked again.
        let r = await panel.busy("Saving “\(name)” to \(target.host)…") { flag in
            try SFTP.session(target, env: env, cancel: flag, on: nil) { c in
                var note: String?, old: Data?
                // The text it replaces: for the history, and for Compare before a reload.
                let keep: ((SFTPClient.Attrs, Data?) -> Void)? = history == nil && rule?.reload == nil ? nil : { a, data in
                    old = data
                    note = history?.keep(data, a, of: target, remotePath)
                }
                let checking = "Checking “\(name)” on \(target.host) (\(ConfigCheck.program(rule?.check ?? "")))…"   // ⎋ stops nothing then
                let (attrs, outcome) = try c.save(saved.path, to: remotePath, baseline: baseline, force: force, cancel: flag, rule: rule, env: env,
                                                  replaced: keep, checking: { Task { @MainActor in panel.busy(flag, says: checking) } })
                let reload = rule?.reload(after: outcome, on: target, old: old) { try? Data(contentsOf: saved) }
                c.sweepPartials()   // the first save in a folder a session: two waits more
                return (attrs, note, outcome, reload.map { ($0, old) })
            }
        }
        switch r {
        case .success(let (attrs, note, outcome, reload)):
            AuditLog.write(target, action, paths: [remotePath], exit: 0, by: by)
            Editor.markSent(saved)   // a question's Overwrite, or an earlier save that failed: on the server now
            state.baseline = attrs
            for p in panels where p.remote?.target.asUser == target.asUser { p.reload() }   // root's or user's: one server
            let notes = [note.map { "no history: \($0)" }, outcome.map { Self.checkNote($0, of: rule) }, Self.reloadNote(rule, outcome, on: target), problem]
                .compactMap { $0 }
            if !notes.isEmpty { told?(notes.joined(separator: " · ")) }
            if !notes.isEmpty {
                let said = "Saved “\(name)” to \(target.host) · " + notes.joined(separator: " · ")
                panel.flash(said)
                Editor.flash(saved, said)
            }
            if let (command, _) = reload, let told { told("Its service wasn't reloaded — that is the user's to do: \(command)") } else
            if let (command, old) = reload {   // not waited for: the next save needn't wait for the answer
                Task { await offerReload(command, after: saved, to: remotePath, on: target, old: old, in: panel) }
            }
            return true
        case .failure(let e as SFTPClient.CheckFailed):
            AuditLog.write(target, action, paths: [remotePath], exit: e.status, error: "“\(e.program)” failed. " + (e.now.isEmpty ? "Not saved." : e.now), by: by)
            Editor.markUnsaved(saved)
            if let a = e.attrs { state.baseline = a }   // an "after" check: what's there now, put back or not
            let (message, info) = Self.checkFailed(e, name: name, host: target.host, kept: Editor.window(for: saved) == nil ? saved.path : nil)
            if told != nil { return tell(message + "\n" + Self.checkFailed(e, name: name, host: target.host, kept: "").info) }
            let why = explains   // ✨: the check's whole output and, while it's open, the text that didn't pass. ↩ stays OK.
            if await choose(message, info: info, why ? ["OK", "Explain"] : ["OK"], on: Editor.asking(about: saved)) == 1 {
                explain([Self.checkFailure(e, name: name, path: remotePath, on: target)] + [Editor.document(at: saved.path).map(AIPanel.document)].compactMap { $0 })
            }
            return false
        case .failure(is SFTPClient.ChangedOnServer) where told != nil:
            return tell("“\(name)” changed on the server, or appeared there, after Kermo looked. Nothing was written.")
        case .failure(is SFTPClient.GoneFromServer) where told != nil:
            return tell("“\(name)” is gone from the server: deleted or renamed after Kermo looked. Nothing was written.")
        case .failure(let e as SFTPClient.ChangedOnServer):
            Editor.markUnsaved(saved)   // ↑ while it asks (and Compare runs): closing its tab asks first
            let keeps = Editor.window(for: saved) == nil ? "in \(saved.path)" : "unsaved here"   // the editor may be gone
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            let when = fmt.string(from: Date(timeIntervalSince1970: e.attrs.mtime))
            let info = "Someone or something wrote it at \(when) (\(ByteCountFormatter.short(e.attrs.size))). "
                + "Overwriting replaces their changes with yours. Compare shows the differences first; Cancel keeps your text \(keeps)."
            var c = Confirm("“\(name)” changed on \(SavedServer.name(for: target)) since you opened it", on: target, action: "Overwrite")
            (c.note, c.others, c.irreversible) = (info, ["Compare"], true)   // ⌘S ↩ never writes over theirs
            while true {   // Compare asks again once the diff is up
                switch await confirm(c, on: Editor.asking(about: saved)) {
                case 0:   // over what was shown, not whatever's there by now: another change meanwhile asks again
                    state.baseline = e.attrs
                    return await uploadNow(saved, to: remotePath, on: target, state, force: false, action: action)
                case 1:
                    let yours = DiffSide(path: saved.path, name: "\(name) (yours)", origin: (target, remotePath))
                    var there = Self.serverNow(remotePath, on: target)
                    (there.size, there.mtime, there.look) = (e.attrs.size, e.attrs.mtime, false)   // as the question says it is: its preview copy if there's one
                    if Editor.window(for: saved) != nil, builtInCompare {   // side by side, live: like Show Changes
                        Task { await diff(there, yours, in: panel) }
                        return false
                    }
                    await diff(yours, there, in: panel, plain: true)   // the question stays up meanwhile
                default: return false
                }
            }
        case .failure(is SFTPClient.GoneFromServer):   // deleted or renamed there: not made again unasked
            Editor.markUnsaved(saved)
            let here = Editor.window(for: saved) != nil
            var c = Confirm("“\(name)” is gone from \(SavedServer.name(for: target)) since you opened it", on: target, action: "Save")
            c.note = "It was deleted or renamed there. Save makes it again as \(remotePath)" + (here ? "; Save As… keeps your text in a file on this Mac" : "")
                + "; Cancel keeps your text " + (here ? "unsaved here." : "in \(saved.path).")
            (c.others, c.returnCancels) = (here ? ["Save As…"] : [], true)   // ↩: Cancel; Save isn't red: it destroys nothing
            switch await confirm(c, on: Editor.asking(about: saved)) {
            case 0:
                state.baseline = .nothing   // a file that appears there meanwhile still asks
                return await uploadNow(saved, to: remotePath, on: target, state, force: false, action: action)
            case 1 where here: Editor.saveAs(copy: saved)
            default: break
            }
            return false
        case .failure(let e):
            if !(e is CancellationError) { AuditLog.write(target, action, paths: [remotePath], exit: 1, error: e.localizedDescription, by: by) }
            if told != nil { return tell(e is CancellationError ? "It was stopped on its way: whether \(remotePath) was written isn't known. Read it to see." : "Not written: \(e.localizedDescription)") }
            return notSaved(saved, to: target, e)
        }
    }

    /// A server's file as it is there now, never its open document: the other side of a Compare before a save.
    static func serverNow(_ path: String, on target: SFTPTarget) -> DiffSide {
        DiffSide(path: path, server: target, look: true, name: "\(target.host):\(path) (now)", now: true)
    }

    /// Server ▸ File History…: the versions saves replaced (`ServerHistory`) of the server file in the key editor, or under
    /// a server panel's cursor, newest first. ↩ / F3 views one; ⌘⇧D diffs it with the server's file now, ⌘D with the
    /// version before it; ⌘R puts it
    /// back there through the same save as ⌘S — production asks, a change made there since the list opened asks too,
    /// and the version it replaces goes into the history.
    func serverFileHistory() {
        let editor = Editor.server(of: NSApp.keyWindow)
        let file = editor ?? active.remoteCursor.flatMap { c in
            c.item.kind == .file || c.item.kind == .link && !c.item.linkDir ? (c.target, (c.dir as NSString).appendingPathComponent(c.item.name)) : nil
        }
        guard let (target, path) = file else { return active.flash("File History is for a server's file: put the cursor on one, or ask in its editor") }
        let over: NSWindow = editor != nil ? NSApp.keyWindow! : window
        let name = (path as NSString).lastPathComponent, env = SSHAskpass.env
        let panel = panels.first { $0.remote?.target == target } ?? active
        Task {
            if await !ServerLock.authorize(target, "see the file history on") { return }
            let versions = ServerHistory(root: Self.historyRoot).versions(of: target, path)
            guard !versions.isEmpty else { return panel.flash("No versions of “\(name)” from \(target.host) yet: each save keeps the one it replaces") }
            // What Revert checks against: a change made there after this asks first.
            let r = await panel.busy("Looking at “\(name)” on \(target.host)…") { flag in try SFTPClient.session(target, env: env, cancel: flag) { try $0.stat(path) } }
            if case .failure(let e) = r, e is CancellationError { return }
            let now = try? r.get()   // not there (any more): Revert puts it back, diff says why it can't
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let when = { (v: ServerHistory.Version) in fmt.string(from: v.date) + (v.n > 1 ? " (\(v.n))" : "") }
            let side = { (v: ServerHistory.Version) in DiffSide(path: v.path, name: "\(target.host):\(path) @ \(when(v))", origin: (target, path)) }
            let items = versions.enumerated().map { i, v in
                let url = URL(fileURLWithPath: v.path), when = when(v)
                let view: @MainActor () -> Void = { Viewer.show(url) }
                let diff: @MainActor () -> Void = { [self] in
                    let there = DiffSide(path: path, server: target, size: now?.size ?? 0, mtime: now?.mtime ?? 0, look: now == nil)
                    Task { await self.diff(side(v), there, in: panel) }
                }
                let diffBefore: @MainActor () -> Void = { [self] in   // newest first: the one before is next
                    guard versions.indices.contains(i + 1) else { return panel.flash("That's the oldest version kept: nothing before it to compare") }
                    Task { await self.diff(side(versions[i + 1]), side(v), in: panel) }
                }
                let revert: @MainActor () -> Void = { [self] in
                    let state = RemoteEdit(baseline: now ?? .nothing)
                    Task {
                        // Read first: the save keeps a version too, and the history's limit may take this one then.
                        let data = await Blocking.run(.userInitiated) { try? Data(contentsOf: url) }
                        guard await upload(url, to: path, on: target, state, action: "revert") else { return }
                        panel.flash("“\(name)” on \(target.host) is back to its version of \(when)")
                        // Its editor shows that now, unless it has changes of its own.
                        if let e = Editor.editing(target, path), let data {
                            _ = await e.reverted(to: data, attrs: state.baseline)
                        }
                    }
                }
                return Picker.Item(title: when, subtitle: ByteCountFormatter.short(v.size),
                                   actions: [.init(key: Shortcut("f3")!, label: "", run: view),   // as ↩
                                             .init(key: Shortcut("cmd+shift+d")!, label: "Diff with Server", run: diff),
                                             .init(key: Shortcut("cmd+d")!, label: "Diff with Previous", run: diffBefore),
                                             .init(key: Shortcut("cmd+r")!, label: "Revert", run: revert)],
                                   verb: "View", run: view)
            }
            Picker.show(over: over, placeholder: "Filter versions", scope: ("\(SavedServer.name(for: target)) › \(name)", Chip.of(target)),
                        header: "\(versions.count) version\(versions.count == 1 ? "" : "s") kept on this Mac", items: items)
        }
    }

    /// "Reload …?" once a save passed its check (`ConfigCheck.reload`): Compare shows the save's change first (the text
    /// it replaced against the one saved); on a production server the question says so and ↩ answers Cancel. The reload
    /// runs as the check did: as root through sudo on a root panel. Its output shows only if it fails.
    func offerReload(_ command: String, after saved: URL, to path: String, on target: SFTPTarget, old: Data?, in panel: PanelViewController) async {
        let name = (path as NSString).lastPathComponent, q = Self.reloadQuestion(command, name: name, on: target)
        var before: String?
        ask: while true {
            switch await confirm(q, on: Editor.asking(about: saved)) {
            case 0: break ask
            case 1:
                guard let old else { panel.flash("Nothing to compare: the text before this save wasn't kept (over 5 MB, or a new file)"); continue }
                if before == nil { before = Self.textBefore(old, name: name) }
                guard let before else { continue }
                await diff(DiffSide(path: before, name: "\(target.host):\(path) (before this save)"), DiffSide(path: saved.path, name: "\(target.host):\(path)"),
                           in: panel, plain: true)   // the question stays up: it can't be asked again later
            default: return
            }
        }
        await reload(command, after: saved, to: path, on: target, in: panel)
    }

    /// Runs the reload the question was about; its output shows only if it fails.
    func reload(_ command: String, after saved: URL, to path: String, on target: SFTPTarget, in panel: PanelViewController) async {
        await runThere(command, on: target, action: "reload", paths: [path], busy: "Reloading on \(target.host)…",
                       done: "Reloaded on \(target.host): \(command)", saved: saved, in: panel)
    }

    /// A command that changes something on a server — a reload, a restart — run as a save's check is (`ConfigCheck.run`):
    /// on a root target as root, through its sudo (`sudo -n`, else the password it takes: kept, Keychain or asked, on
    /// stdin), else as the user. `ask`: on a production server it asks first, ↩ = Cancel (a reload's own question asked
    /// already). A line in the production log; the status line (and `saved`'s editor) says it went; a failure shows its
    /// output. ⎋ stops the wait, not what was sent. True: it ran, exit 0.
    @discardableResult
    func runThere(_ command: String, on target: SFTPTarget, action: String, paths: [String] = [], busy: String, done: String,
                  ask: (message: String, button: String)? = nil, saved: URL? = nil, in panel: PanelViewController) async -> Bool {
        await sayRan(ranThere(command, on: target, action: action, paths: paths, busy: busy, ask: ask, in: panel),
                     command, on: target, done: done, saved: saved, in: panel)
    }

    /// What `ranThere` came to. `notRun`: a locked server stayed locked, or the production question's Cancel.
    enum RanThere { case notRun(String), ran(Result<ConfigCheck.Outcome, Error>) }

    /// `runThere` but for saying how it went: the lock, the production question (on `askOn`, default the main
    /// window), the run and its production log line. `running`: once it's asked and about to run.
    func ranThere(_ command: String, on target: SFTPTarget, action: String, paths: [String] = [], busy: String,
                  ask: (message: String, button: String)? = nil, askOn: NSWindow? = nil, in panel: PanelViewController,
                  running: (@MainActor () -> Void)? = nil) async -> RanThere {
        // A locked server's Touch ID again if its time ran out since it was looked at (a Picker can stay open).
        switch await gate([target], to: "run “\(command)” on", on: askOn, question: { ask.flatMap { Self.prodQuestion(command, on: target, $0) } }) {   // ↩ = Cancel
        case .locked: return .notRun("\(target.host) stays locked")
        case .cancelled: return .notRun("cancelled")
        case .pass: break
        }
        let env = SSHAskpass.env
        running?()
        let r = await panel.busy(busy) { flag in try ConfigCheck.run(command, on: target, env: env, cancel: flag) }
        let log = { (exit: Int32?, error: String?) in AuditLog.write(target, action, paths: paths, command: command, exit: exit, error: error) }
        switch r {
        case .success(.passed): log(0, nil)
        case .success(.failed(let status, let output)): log(status, output)
        case .success(.noProgram(let why)): log(127, why)
        case .success: break
        case .failure(is CancellationError): log(nil, "cancelled, may have run")   // ⎋ stops the wait, not what was sent
        case .failure(let e): log(1, e.localizedDescription)
        }
        return .ran(r)
    }

    /// How `ranThere` went, in the status line (and `saved`'s editor), or a failure's output. True: it ran, exit 0.
    func sayRan(_ ran: RanThere, _ command: String, on target: SFTPTarget, done: String, saved: URL? = nil, in panel: PanelViewController) async -> Bool {
        guard case .ran(let r) = ran else { return false }
        switch r {
        case .success(.passed):
            panel.flash(done)
            if let saved { Editor.flash(saved, done) }
            return true
        case .success(.failed(let status, let output)):
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = await choose("“\(command)” failed on \(target.host)", info: text.isEmpty ? "It exited with \(status)." : String(text.suffix(4000)), ["OK"],
                             on: saved.flatMap(Editor.asking(about:)))
        case .success(.noProgram(let why)):
            panel.flash("“\(command)” didn't run on \(target.host): \(why)", error: true)
        case .success: break   // needs root, not run: only checks
        case .failure(is CancellationError): break
        case .failure(let e): showError(e)
        }
        return false
    }

    /// The check a save of `path` on `t`'s server gets: your validators.json's rule, then Kermo's built-in one, then a
    /// tool's in use there (§11), its folder as known now; and what's wrong with validators.json.
    /// ponytail: the unsaved-changes question (`saveSays`) doesn't look for a tool's folder first — the save does.
    func checkRule(for path: String, on t: SFTPTarget) -> (rule: ConfigCheck?, problem: String?) {
        let (rules, problem) = ConfigCheck.rules(FileManager.default.contents(atPath: Self.validatorsPath), tools: [tools.check(for: path, on: t)].compactMap { $0 })
        return (ConfigCheck.rule(for: path, in: rules), problem)
    }

    /// What saving a server's `path` does besides writing it, for the unsaved changes' question: its check, the old
    /// version kept, the production log — only what will happen; nil when nothing.
    func saveSays(_ t: SFTPTarget, _ path: String) -> String? {
        let rule = checkRule(for: path, on: t).rule
        let does = [rule?.check.map { "checks it with \(ConfigCheck.program($0))" + (rule?.after == true ? " once it's there (the old text goes back if that fails)" : " first") },
                    serverHistory == nil ? nil : "keeps the old version on this Mac", SavedServer.isProd(t) ? "goes into the production log" : nil].compactMap { $0 }
        guard !does.isEmpty else { return nil }
        return "Saving " + (does.count == 1 ? does[0] : does.dropLast().joined(separator: ", ") + " and " + does.last!) + "."
    }

    /// What `runThere` asks on a production server (nil elsewhere: it just runs): the command, where and as whom.
    static func prodQuestion(_ command: String, on target: SFTPTarget, _ ask: (message: String, button: String)) -> Confirm? {
        guard SavedServer.isProd(target) else { return nil }
        var c = Confirm(ask.message, on: target, action: ask.button)
        (c.runs, c.command) = (runs(on: target), command)
        return c
    }

    /// How a command on `target` runs, over it in a question.
    static func runs(on target: SFTPTarget) -> String {
        "Runs on \(SavedServer.name(for: target.asUser))" + (target.sudo ? " as root, through the server's sudo." : ".")
    }

    /// The reload question: what runs, where, as whom; on a production server ↩ is Cancel (elsewhere ↩ is Reload and
    /// ⎋ Cancel, as any alert has them); sshd moving to another port says what that does.
    static func reloadQuestion(_ command: String, name: String, on target: SFTPTarget) -> Confirm {
        var c = Confirm("Reload after saving “\(name)”?", on: target, action: "Reload")
        (c.others, c.runs, c.command) = (["Compare"], runs(on: target), command)
        if command == ConfigCheck.sshdSocketReload {
            c.note = "Port or ListenAddress changed. Where systemd listens for sshd (ssh.socket, Ubuntu 22.10 and later) this reloads "
                + "systemd and restarts ssh.socket: this connection stays, new ones go to the new port."
        }
        return c
    }

    /// The text a save replaced, in a temp copy of its own (owner-only; swept with the server copies), for Compare.
    static func textBefore(_ data: Data, name: String) -> String? {
        let dir = NSTemporaryDirectory() + "dfm-sftp-" + UUID().uuidString
        guard (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        let file = (dir as NSString).appendingPathComponent(name)
        return FileManager.default.createFile(atPath: file, contents: data, attributes: [.posixPermissions: 0o600]) ? file : nil
    }

    /// A reload this save would have offered as root, on a user's panel (the built-in ones reload services): said instead.
    static func reloadNote(_ rule: ConfigCheck?, _ outcome: ConfigCheck.Outcome?, on target: SFTPTarget) -> String? {
        guard let rule, rule.reload(after: outcome, on: target, old: nil, new: { nil }) == nil,
              rule.reload(after: outcome, on: target.asRoot(), old: nil, new: { nil }) != nil else { return nil }
        return "reload needs root — ⌃⌘R opens the panel as root"
    }

    /// What the status line says of a save's check: passed, no program there, or root only on a user's panel.
    static func checkNote(_ outcome: ConfigCheck.Outcome, of rule: ConfigCheck?) -> String {
        switch outcome {
        case .passed, .failed: "checked: \(ConfigCheck.program(rule?.check ?? ""))"   // a failed one never gets here
        case .noProgram(let why): "no check for this file (\(why))"
        case .needsRoot: "check needs root — ⌃⌘R opens the panel as root"
        case .notRun(let why): "unchecked: \(why)"
        }
    }

    /// The dialog for a save whose check failed: what the check said (its last lines), and where things are.
    /// `kept`: the editor is gone, the text is only in that file.
    static func checkFailed(_ e: SFTPClient.CheckFailed, name: String, host: String, kept: String?) -> (message: String, info: String) {
        let lines = e.output.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = (lines.count > 30 ? ["…"] + lines.suffix(30) : lines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // "": nobody's text to keep (the assistant's write).
        let text = kept.map { $0.isEmpty ? "" : "Your text is kept in \($0)." } ?? "Your text stays unsaved here."
        return ("“\(name)” didn't pass “\(e.program)” on \(host)",
                (shown.isEmpty ? "It exited with \(e.status)." : shown) + "\n\n" + (e.now.isEmpty ? "Not saved there: the file on \(host) is as it was." : e.now) + " " + text)
    }

    /// ✨ Explain of a save's check that failed: what it ran and its whole output, from the server it ran on.
    static func checkFailure(_ e: SFTPClient.CheckFailed, name: String, path: String, on target: SFTPTarget) -> AIPanel.Context {
        AIPanel.failure("“\(e.program)” on \(name)", on: target, "“\(e.rule.check ?? e.program)” checked \(path) as it was being saved, and failed "
                        + "(exit \(e.status)):\n\(e.output)" + (e.now.isEmpty ? "" : "\n\(e.now)"))
    }

    private func notSaved(_ saved: URL, to target: SFTPTarget, _ e: Error) -> Bool {
        Editor.markUnsaved(saved)
        if let m = Self.notUploaded(saved, host: target.host, e, editorOpen: Editor.window(for: saved) != nil) { showError(JobErrorMessage(m), on: Editor.asking(about: saved)) }
        return false
    }

    /// What to say when a save didn't reach the server: nil for a cancel the editor still shows (unsaved there).
    /// With the editor closed, the text is only in the temp copy, so it says where.
    static func notUploaded(_ saved: URL, host: String, _ error: Error, editorOpen: Bool) -> String? {
        let kept = editorOpen ? "" : " Your text is kept in \(saved.path)."
        if error is CancellationError {
            return editorOpen ? nil : "“\(saved.lastPathComponent)” wasn't saved to \(host).\(kept)"
        }
        if let e = error as? ConfigCheck.NotRun {   // checked before it takes the file's place: nothing changed there
            return "“\(saved.lastPathComponent)” wasn't saved to \(host): its check didn't run. \(e.message)\(kept)"
        }
        if let e = error as? SFTPClient.InPlaceFailed {
            let now = e.restored ? "was put back as it was" : "may be cut short" + (e.old.map { " — its old text is in \($0)" } ?? "")
            return "Uploading “\(saved.lastPathComponent)” to \(host) failed: \(e.error.localizedDescription). The file on \(host) \(now); "
                + "your full text is in \(e.partial) there.\(kept)"
        }
        return "Saved locally, but uploading to \(host) failed: \(error.localizedDescription)\(kept)"
    }

    /// One operation over the native client (names go as bytes, no `sftp -b` quoting), then the server's panels reload.
    /// `paths`: what it changes, for the production log. `panel` says it's under way (⎋ there cancels; default the active
    /// one), a failure is said on `sheet` (an editor's; default the main window). True once it's done.
    @discardableResult
    func remoteOp(_ title: String, _ target: SFTPTarget, paths: [String], select: String? = nil, in panel: PanelViewController? = nil,
                  on sheet: NSWindow? = nil, _ op: @escaping @Sendable (SFTPClient) throws -> Void) async -> Bool {
        let env = SSHAskpass.env
        let r = await (panel ?? active).busy("\(title) on \(target.host)…") { flag in try SFTPClient.session(target, env: env, cancel: flag, op) }
        switch r {
        case .success:
            AuditLog.write(target, title.lowercased(), paths: paths, exit: 0)
        case .failure(is CancellationError): AuditLog.write(target, title.lowercased(), paths: paths, exit: nil, error: "cancelled, may have been done")   // ⎋ stops the wait
        case .failure(let e):
            AuditLog.write(target, title.lowercased(), paths: paths, exit: 1, error: e.localizedDescription)
            showError(JobErrorMessage("\(title): \(e.localizedDescription)"), on: sheet)
        }
        for p in panels where p.remote?.target.asUser == target.asUser { p.reload(select: select) }
        if case .success = r { return true }
        return false
    }

    func remoteMkdir() {
        guard let (target, dir, _) = active.remoteSelection ?? active.remote.map({ ($0.target, $0.dir, []) }) else { return }
        Task {
            guard await unlock([.sftp(target)], to: "make a folder on") else { return }
            guard let name = await prompt("New folder on \(target.host):", value: "", ok: "Create", strip: target), !name.isEmpty else { return }
            let path = (dir as NSString).appendingPathComponent(name)
            await remoteOp("New folder", target, paths: [path], select: name) { try $0.mkdir(path) }
        }
    }

    /// An empty file there, then F4 on it. Never over an existing one (O_EXCL).
    func remoteNewFile() {
        guard let r = active.remote else { return }
        let (target, panel) = (r.target, active)
        Task {
            guard await unlock([.sftp(target)], to: "make a file on") else { return }
            guard let name = await prompt("New file on \(target.host):", value: "", ok: "Create", strip: target),
                  !name.isEmpty else { return }
            let path = name.hasPrefix("/") ? name : (r.dir as NSString).appendingPathComponent(name)
            if await remoteOp("New file", target, paths: [path], select: (path as NSString).lastPathComponent, { try Self.newServerFile($0, path) }) {
                remoteOpen(.edit, target, path, in: panel)
            }
        }
    }

    /// Created with O_EXCL (an existing file is an error, never emptied), `rw-r--r--` as `touch` makes it. Looked for
    /// first only to say so plainly: SFTP v3 answers O_EXCL's "exists" with a bare "Failure".
    nonisolated static func newServerFile(_ c: SFTPClient, _ path: String) throws {
        if try c.lstat(path) != nil { throw JobErrorMessage("“\((path as NSString).lastPathComponent)” already exists.") }
        _ = try c.openWrite(path, exclusive: true).finish(mtime: nil, mode: 0o644)
    }

    /// Never over an existing item (sftp's `rename` is posix-rename, which silently replaced it); `Foo` → `foo` works.
    func remoteRename() {
        guard let (target, dir, item) = active.remoteCursor else { return NSSound.beep() }
        let panel = active
        Task {
            guard let name = await prompt("Rename “\(item.name)” on \(target.host) to:", value: item.name, ok: "Rename",
                                          selectBaseName: true, strip: target),
                  name != item.name, !name.isEmpty else { return }
            let from = (dir as NSString).appendingPathComponent(item.name)
            let to = name.hasPrefix("/") ? name : (dir as NSString).appendingPathComponent(name)
            await renameOnServer(target, from, to: to, in: panel) { panel.flash($0, error: true) }
        }
    }

    /// A server's file renamed — the panel's ⇧F6, an editor tab's: never over anything there (`replace: false`), and the
    /// production log has its line. Its tab follows; not while it uploads (that upload would make the old name again),
    /// nor onto a file a tab has open. `say`: a refusal, where it was asked.
    @discardableResult
    func renameOnServer(_ t: SFTPTarget, _ from: String, to: String, in panel: PanelViewController, on sheet: NSWindow? = nil,
                        say: (String) -> Void) async -> Bool {
        guard await unlock([.sftp(t)]) else { return false }   // first: an upload a ⌘S starts meanwhile is refused below
        let tab = Editor.editing(t, from) ?? Editor.tab(onServer: t, from), name = (to as NSString).lastPathComponent   // the asking tab's first
        if let why = tab?.renameRefusal { say(why); return false }
        if let other = Editor.tab(onServer: t, to), other !== tab { say("“\(name)” is open in the editor — nothing was renamed"); return false }
        let op = { await self.remoteOp("Rename", t, paths: [from, to], select: name, in: panel, on: sheet) { try $0.rename(from, to, replace: false) } }
        guard let tab else { return await op() }
        guard await tab.renaming(op) else { return false }
        if Editor.tab(onServer: t, from) === tab { await tab.moved(onServer: to) }   // still open
        return true
    }

    /// Reveal in Panel (an editor tab's menu): its file under the cursor of a panel in the main window — a server's in the
    /// panel showing that server, else the active one connects to it as the sidebar would (a locked one asks first).
    func revealInPanel(_ e: Editor) {
        if let s = e.server { showInPanel((s.path as NSString).deletingLastPathComponent, select: (s.path as NSString).lastPathComponent, on: s.target) }
        else if e.revealable, let url = e.url { showInPanel(url.deletingLastPathComponent().path, select: url.lastPathComponent, on: nil) }
        else { NSSound.beep() }
    }

    /// `dir` in a panel of the main window, `select` under the cursor: a server's in the panel showing that server, else
    /// the active one connects to it as the sidebar would (a locked one asks first).
    func showInPanel(_ dir: String, select: String?, on server: SFTPTarget?) {
        bringBack(window)
        showPanels()
        let panel = server.flatMap { t in panels.first { $0.remote?.target == t } } ?? active
        window.makeFirstResponder(panel.table)
        if let server { panel.loadRemote(server, dir: dir, select: select) } else { panel.navigate(to: dir, select: select) }
    }

    /// A file renamed from its editor tab on this Mac: the panels showing its folder have it under the cursor, and the old
    /// name leaves Favorites and Frequent.
    func showRenamed(from path: String, to dst: String) {
        let dir = URL(fileURLWithPath: dst).deletingLastPathComponent().standardizedFileURL.path
        for p in panels where p.localFolder?.standardizedFileURL.path == dir { p.reload(select: (dst as NSString).lastPathComponent) }
        forgetGone([path])
    }

    /// The items as the panel listed them: one that's another thing by now (a file swapped by `mv`, a folder in its
    /// place — a server panel isn't watched, its listing can be hours old) is skipped, not deleted: there's no Trash.
    static func serverDelete(_ items: [FileItem], in dir: String, on target: SFTPTarget, env: [String: String]) -> FileJob {
        let paths = items.map { (dir as NSString).appendingPathComponent($0.name) }
        let job = FileJob(.delete, sources: paths, from: .sftp(target), to: .sftp(target), destDir: nil, sshEnv: env)
        job.expected = Dictionary(zip(paths, items.map { Optional($0) }), uniquingKeysWith: { a, _ in a })
        (job.expectedFrom, job.foldersByKind) = ("it was listed", true)
        return job
    }

    /// There's no Trash on a server: always asks, then deletes recursively.
    func remoteDelete() {
        guard let sel = active.remoteSelection else { return NSSound.beep() }
        let items = active.listed(sel.items)
        Task {
            guard await unlock([.sftp(sel.target)], to: "delete files on") else { return }
            let what = sel.items.count == 1 ? "“\(sel.items[0].name)”" : "\(sel.items.count) items"
            var c = Confirm("Delete \(what) on \(SavedServer.name(for: sel.target)) permanently?", on: sel.target, action: "Delete")
            (c.items, c.note, c.irreversible) = (items, "A server has no Trash. This can't be undone.", true)
            guard await confirm(c) == 0 else { return }
            ops.enqueue(Self.serverDelete(sel.items, in: sel.dir, on: sel.target, env: SSHAskpass.env), title: "Delete \(what) on \(sel.target.host)")
            active.unmarkAll()
        }
    }
}
