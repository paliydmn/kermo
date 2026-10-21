import AppKit
import DFMCore
import SwiftTerm

/// ⌃O (MC's subshell): a terminal workspace that covers the panels, with tabs — local login shells and
/// SSH sessions (system OpenSSH, one PTY and one `ssh` process per tab). For the current tab when it's a
/// local shell: toggling back moves the active panel to its folder; showing it again `cd`s it to the panel's.
@MainActor
final class EmbeddedTerminal: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    enum Kind: Equatable { case shell, ssh(SFTPTarget) }

    @MainActor
    final class Tab {
        let id = UUID()
        let kind: Kind
        let view: DropTerminalView
        var title = ""            // set by the remote / local shell (OSC 0/2)
        var exitStatus: Int32?    // set when the process ended (raw wait status; -1 = never started)
        var reconnect: NSButton?
        var command: String?      // SSH: what to run instead of a login shell, once
        var cwd: String?          // the folder its shell last told (OSC 7); SSH: on the server
        init(kind: Kind, view: DropTerminalView) {
            self.kind = kind
            self.view = view
            view.acceptsLocalPaths = kind == .shell
            // Lines pasted by a right-click into a production server, or as root, ask first.
            if case .ssh(let t) = kind {
                view.pasteRisk = { SavedServer.isProd(t) ? "\(SavedServer.name(for: t)) (production)" : t.host.hasPrefix("root@") ? t.host : nil }
            }
        }

        var target: SFTPTarget? { if case .ssh(let t) = kind { t } else { nil } }
        var host: String? { target?.host }
        var isRunning: Bool { exitStatus == nil && view.process?.running == true }
        /// The shell itself has the terminal (not ssh, vim, mysql, sudo's password prompt…): only then may a typed
        /// `cd` go in.
        var isAtPrompt: Bool { EmbeddedTerminal.atPrompt(view.process) }
        /// What closing the tab would end: an SSH connection, or a program still running in a local shell.
        var busyWith: String? {
            guard isRunning, let p = view.process else { return nil }
            if let host { return "The connection to “\(host)”" }
            guard !isAtPrompt else { return nil }
            var name = [UInt8](repeating: 0, count: 256)
            let pg = tcgetpgrp(p.childfd)
            return pg > 0 && proc_name(pg, &name, 256) > 0 ? "“\(String(decoding: name.prefix { $0 != 0 }, as: UTF8.self))” in a shell" : "A program in a shell"
        }
        /// The shell's working directory, read from the kernel (works whatever the shell prints).
        var shellCwd: String? {
            guard let pid = view.process?.shellPid, pid > 0 else { return nil }
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
            return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        /// Where its shell is: what it told (OSC 7), else — a local shell — the kernel's word. An SSH tab's `ssh` runs
        /// here, so only what the server's shell told counts.
        var folder: String? { cwd ?? (host == nil ? shellCwd : nil) }
        /// A local tab is named by its shell (OSC 0/2), else after its folder; an SSH tab after its server.
        var label: String {
            switch kind {
            case .shell: !title.isEmpty ? title : folder.map(EmbeddedTerminal.folderName) ?? "Shell"
            case .ssh(let t): title.isEmpty ? "SSH · \(t.host)" : "SSH · \(t.host) · \(title)"
            }
        }
    }

    /// "/Users/me/src/a b" → "a b", the home folder → "~", "/" → "/".
    nonisolated static func folderName(_ path: String) -> String { ((path as NSString).abbreviatingWithTildeInPath as NSString).lastPathComponent }

    private(set) var tabs: [Tab] = []
    private var index = 0
    private var closing: [Tab] = []   // killed, waiting for the process to go
    private let container = NSStackView()
    private let tabBar = NSStackView()
    private let content = NSView()
    private unowned let host: NSView   // the panels; the terminal sits exactly over them
    var onExit: (() -> Void)?          // last tab closed: panels come back
    var onChange: (() -> Void)?        // tabs / states changed (sidebar, saved session)
    var onDirectory: ((Tab) -> Void)?  // the current tab's shell told its folder (`cwd`)
    /// ⌘+ / ⌘−, every tab; kept in `terminalFontSize` (clamped to 9…36; 13 if unset).
    private(set) var fontSize: CGFloat = (UserDefaults.standard.object(forKey: "terminalFontSize") as? Double).map { min(max($0, 9), 36) } ?? 13
    private var hiddenAt = -TimeInterval.infinity   // uptime; ⌃O ⌃O

    var isShown: Bool { container.superview != nil && !container.isHidden }
    var current: Tab? { tabs.indices.contains(index) ? tabs[index] : nil }
    var hasFocus: Bool { isShown && (container.window?.firstResponder as? NSView)?.isDescendant(of: container) == true }

    init(covering host: NSView) {
        self.host = host
        super.init()
        container.orientation = .vertical
        container.spacing = 2
        container.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 0, right: 0)
        container.isHidden = true
        tabBar.distribution = .fillEqually
        tabBar.spacing = 2
        container.addArrangedSubview(tabBar)
        container.addArrangedSubview(content)
        tabBar.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -12).isActive = true
        content.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    private func attach() {
        guard container.superview == nil else { return }
        container.translatesAutoresizingMaskIntoConstraints = false
        host.superview!.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: host.topAnchor),
            container.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }

    // MARK: - Showing

    /// ⌃O on a local panel: shows a live local shell (the current one, any other, else a new one in `cwd`) —
    /// never an SSH tab, even a restored or disconnected one. Returns the view to focus.
    func show(cwd: String) -> NSView {
        let shells = tabs.filter { $0.kind == .shell && $0.isRunning }
        if let t = shells.first(where: { $0 === current }) ?? shells.first {
            index = tabs.firstIndex { $0 === t }!
            if t.isAtPrompt, t.shellCwd != cwd, let line = ShellContext.typedCd(cwd) { t.view.send(txt: line) }
        } else {
            newShell(cwd: cwd)
        }
        return show()
    }

    /// Shows the workspace on the tab the caller picked.
    func show() -> NSView {
        attach()
        host.isHidden = true
        container.isHidden = false
        render()
        return current!.view
    }

    /// Hides the workspace; returns the current shell's folder (nil for SSH tabs). `e`: the event that hid it — only a
    /// pressed ⌃O arms ⌃O ⌃O, not a command that hides the terminal on its way.
    func hide(_ e: NSEvent? = nil) -> String? {
        let cwd = current.flatMap { $0.kind == .shell ? $0.shellCwd : nil }
        container.isHidden = true
        host.isHidden = false
        hiddenAt = Self.pressedCtrlO(e) ? e!.timestamp : -.infinity
        return cwd
    }

    /// ⌃O ⌃O (within 0.4 s): the first one hid the terminal as always; the second brings the same tab back and goes to
    /// the program in it (nano's Write Out, bash's operate-and-get-next). Nil for any other key, a held ⌃O's repeats
    /// (else they'd run a half-typed line: zsh's ^O is accept-line-and-down-history) or later.
    func showPassingCtrlO(_ e: NSEvent?) -> NSView? {
        guard let e, Self.pressedCtrlO(e), (0..<0.4).contains(e.timestamp - hiddenAt), let t = current, t.isRunning else { return nil }
        let v = show()
        t.view.send([0x0f])
        return v
    }

    private static func pressedCtrlO(_ e: NSEvent?) -> Bool {
        guard let e, e.type == .keyDown, !e.isARepeat else { return false }
        return Shortcut(event: e) == Shortcut("ctrl+o")
    }

    /// Sidebar click while the terminal is up: the current shell goes there. False on an SSH tab or while a
    /// program runs in the shell.
    func cd(_ path: String) -> Bool {
        guard let t = current, t.kind == .shell, t.isAtPrompt, let line = ShellContext.typedCd(path) else { return false }
        t.view.send(txt: line)
        return true
    }

    /// ⌘E ↩ on a local panel (MC's subshell): types `line` into a local shell at its prompt — the current tab's, else any,
    /// else a new one started in `cwd` — after a ` cd` when the shell is elsewhere, and shows the terminal. A program
    /// holding the terminal (vim, sudo's password prompt, cat) never gets the line: a new tab instead. Returns the view
    /// to focus; nil when the line or the folder can't be typed (`isTypeable`).
    func run(_ line: String, cwd: String) -> NSView? {
        guard ShellContext.isTypeable(line), let cd = ShellContext.typedCd(cwd) else { return nil }
        let shells = tabs.filter { $0.kind == .shell && $0.isRunning && $0.isAtPrompt }
        if let t = shells.first(where: { $0 === current }) ?? shells.first {
            index = tabs.firstIndex { $0 === t }!
            // ^U first (typedCd carries its own): a half-typed line would otherwise take the command as its tail.
            t.view.send(txt: (t.shellCwd != cwd ? cd : "\u{15}") + line + "\r")
        } else {
            // Typed ahead: the pty holds it until the shell reads — the first prompt is unknowable (the child is the foreground
            // group from forkpty on, .zshrc still running). A .zshrc that flushes input loses it: a known limit.
            newShell(cwd: cwd)
            current!.view.send(txt: line + "\r")
        }
        return show()
    }

    /// ⌃↩ / ⌃⇧↩ while the terminal is up: types `text` into the current tab. Only into one on the panel's machine
    /// (`target`: the panel's server, nil for this Mac — after ⌃⇥ to another tab a local name would go to a server's
    /// shell), and only text the line editor passes on whole (`isTypeable`). What runs in the tab isn't checked: a
    /// name into vim's `:e ` is wanted too.
    func insert(_ text: String, on target: SFTPTarget?) -> Bool {
        guard let t = current, t.isRunning, t.target == target?.asUser, ShellContext.isTypeable(text) else { return false }
        t.view.send(txt: text)
        return true
    }

    // MARK: - Tabs

    @discardableResult
    func newShell(cwd: String) -> NSView { add(Tab(kind: .shell, view: makeView()), cwd: cwd) }

    /// `command`: run on the server instead of a plain login shell, the first time only (a reconnect gets a shell).
    @discardableResult
    func newSSH(_ target: SFTPTarget, command: String? = nil) -> NSView {
        let tab = Tab(kind: .ssh(target.asUser), view: makeView())   // from a root panel too: a shell there is the user's
        tab.command = command
        return add(tab, cwd: nil)
    }

    /// After a restart: SSH tabs come back disconnected; ↩ / Reconnect connects them.
    func restore(_ targets: [SFTPTarget]) {
        for t in targets {
            let tab = Tab(kind: .ssh(t), view: makeView())
            tabs.append(tab)
            pin(tab.view)
            ended(tab, status: -1)
        }
        index = 0
    }

    private func add(_ tab: Tab, cwd: String?) -> NSView {
        tabs.insert(tab, at: tabs.isEmpty ? 0 : index + 1)
        index = tabs.firstIndex { $0 === tab }!
        pin(tab.view)
        start(tab, cwd: cwd)
        focus()
        return tab.view
    }

    private func makeView() -> DropTerminalView {
        let t = DropTerminalView(frame: host.bounds)
        t.processDelegate = self
        t.font = Self.font(size: fontSize)
        t.getTerminal().changeHistorySize(10_000)   // ponytail: fixed; a `terminalScrollback` key if someone asks
        t.optionAsMetaKey = UserDefaults.standard.object(forKey: "terminalOptionIsMeta") as? Bool ?? true   // false: ⌥ types the layout's @ | [ ]
        paint(t)
        return t
    }

    /// `terminalFont` (a name: "MesloLGS NF" for p10k / starship icons), else SF Mono.
    static func font(size: CGFloat) -> NSFont {
        UserDefaults.standard.string(forKey: "terminalFont").flatMap { NSFont(name: $0, size: size) } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Brighter than SwiftTerm's Terminal.app set, for dark backgrounds: blue `ls` folders and red errors stay
    /// readable (≥ 4.5:1 on every terminal background, `Theme.terminal`).
    static let palette: [SwiftTerm.Color] = [0x000000, 0xFF6B6B, 0x7EE787, 0xF2CC60, 0x6CB6FF, 0xD2A8FF, 0x76E3EA, 0xD0D0D0,
                                             0x8B8B8B, 0xFF8E8E, 0xA6F0AE, 0xFFE08A, 0x9CCEFF, 0xE4C7FF, 0xA5F0F5, 0xFFFFFF]
        .map { SwiftTerm.Color(red: UInt16($0 >> 16 & 255) * 257, green: UInt16($0 >> 8 & 255) * 257, blue: UInt16($0 & 255) * 257) }

    /// View ▸ Theme… also recolors the open tabs.
    func applyTheme() { tabs.forEach { paint($0.view) } }

    private func paint(_ t: DropTerminalView) {
        let (fg, bg) = Theme.current.terminal
        t.nativeForegroundColor = fg
        t.nativeBackgroundColor = bg
        t.layer?.backgroundColor = bg.cgColor   // SwiftTerm sets the layer's only at init
        t.installColors(Self.palette)           // after fg / bg: the 256-color cube is built between them
    }

    func zoom(by step: CGFloat) {
        fontSize = min(max(fontSize + step, 9), 36)
        UserDefaults.standard.set(Double(fontSize), forKey: "terminalFontSize")
        tabs.forEach { $0.view.font = Self.font(size: fontSize) }
    }

    private func pin(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: content.topAnchor), v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor), v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    nonisolated static let loginShell = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"

    /// What a shell expects of its terminal, from the GUI's environment: the user's locale (LANG, LC_*), the agent
    /// socket and PATH (ProxyCommand needs it), TMPDIR, SHELL. Not SwiftTerm's list: it forces LANG=en_US.UTF-8 (first
    /// in the list, so it wins), sends a made-up LC_TYPE and drops the rest.
    nonisolated static func environment(_ env: [String: String]) -> [String] {
        let keep: Set = ["LANG", "HOME", "USER", "LOGNAME", "PATH", "SSH_AUTH_SOCK", "TMPDIR", "SHELL", "DISPLAY"]
        var e = env.filter { k, _ in keep.contains(k) || k.hasPrefix("LC_") && k != "LC_TYPE" }
        e["LANG"] = e["LANG"] ?? "en_US.UTF-8"   // a GUI app usually has none; vi & co. need some UTF-8 locale
        e["SHELL"] = e["SHELL"] ?? loginShell
        e["TMPDIR"] = e["TMPDIR"] ?? NSTemporaryDirectory()
        e["TERM"] = "xterm-256color"
        e["COLORTERM"] = "truecolor"
        e["TERM_PROGRAM"] = "Kermo"
        e["COLORFGBG"] = "15;0"   // light on dark (Theme.terminal, whatever the theme): vim & co. pick dark colours
        return e.map { "\($0)=\($1)" }.sorted()
    }
    private static let environment = environment(ProcessInfo.processInfo.environment)

    private func start(_ tab: Tab, cwd: String?) {
        tab.exitStatus = nil
        tab.cwd = nil
        tab.reconnect?.removeFromSuperview()
        tab.reconnect = nil
        switch tab.kind {
        case .shell:
            let shell = Self.loginShell
            launch(tab, shell, [], execName: "-" + (shell as NSString).lastPathComponent,   // leading "-" = login shell
                   cwd: cwd)
        case .ssh(let t):
            // New, reconnect, restored: a locked server asks first (ServerLock); learned meanwhile, for production's marks.
            guard ServerLock.needsUnlock(t) else {
                Task { await ServerLock.learn([t]) }
                return login(tab, ServerLock.locking(t))   // learned already, if it's a locked server's
            }
            Task {
                guard await ServerLock.authorize(t) else {
                    tab.view.feed(text: "🔒 \(t.host) stays locked\r\n")
                    return ended(tab, status: -1)
                }
                if tabs.contains(where: { $0 === tab }) { login(tab, ServerLock.locking(t)) }
            }
        }
        onChange?()
    }

    /// Prompts (password, passphrase, host key) come up in the tab itself: no SSH_ASKPASS here. But a saved
    /// password logs in first, in the background through askpass; ssh then rides on that connection.
    private func login(_ tab: Tab, _ t: SFTPTarget) {
        guard SFTP.hasPassword(t) else { return startSSH(tab, t) }
        tab.view.feed(text: "Logging in to \(t.host)…\r\n")
        Task {
            let r = await Blocking.run { Result { try SFTP.startMaster(t, env: SSHAskpass.env) } }
            if case .failure(let e) = r { tab.view.feed(text: e.localizedDescription.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n") }
            if tabs.contains(where: { $0 === tab }) { startSSH(tab, t) }   // failed: ssh asks in the tab
        }
    }

    /// One login per server at a time (`SFTP.beginLogin`): an SFTP panel logging in now is waited for, then this ssh
    /// rides its connection; one that starts while this tab asks for a password waits until this connection is shared.
    private func startSSH(_ tab: Tab, _ t: SFTPTarget) {
        Task {
            let login = await Blocking.run { SFTP.beginLogin(t, cancel: nil) }
            guard tabs.contains(where: { $0 === tab }) else { login?.end(); return }
            SFTP.noteMaster(t)   // ControlMaster=auto: this ssh may become the shared connection
            launch(tab, "/usr/bin/ssh", SSHCommand.arguments(t, command: tab.command), cwd: NSHomeDirectory())
            tab.command = nil
            onChange?()
            let pid = tab.view.process?.shellPid ?? 0
            Task.detached {   // its login: until the connection is shared, or the ssh is gone
                var tries = 0
                while tries < 240, pid > 0, kill(pid, 0) == 0, !SFTP.isConnected(t) {
                    tries += 1
                    try? await Task.sleep(for: .milliseconds(500))
                }
                login?.end()
            }
        }
    }

    /// Starts the tab's process and watches for its end itself: SwiftTerm drops the exit when it reads the pty's
    /// end first (`exit`, a dropped connection). Whoever reaps the process first has its status; `finished` once.
    func launch(_ tab: Tab, _ executable: String, _ args: [String], execName: String? = nil, cwd: String?) {
        TunnelListener.forking {   // a tunnel's socket half made now would go with the shell, its port held while it runs
            tab.view.startProcess(executable: executable, args: args, environment: Self.environment, execName: execName, currentDirectory: cwd)
        }
        guard let p = tab.view.process, p.running, p.shellPid > 0 else { return }
        let pid = p.shellPid
        // Each process's watch lives (its handler holds it) until that process is gone and reaped, whatever became of
        // the tab: closed, or started again after the pty ended but before the old process did.
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler { [weak self, weak tab] in
            MainActor.assumeIsolated {
                watch.cancel()
                // -1 (ECHILD): SwiftTerm's own watch reaped it, and has already told processTerminated.
                var status: Int32 = 0
                guard waitpid(pid, &status, WNOHANG) == pid, let self, let tab, tab.view.process?.shellPid == pid else { return }
                self.finished(tab, status: status)
            }
        }
        watch.activate()
    }

    func select(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        index = i
        focus()
    }

    func switchTab(by delta: Int) {
        guard tabs.count > 1 else { return }
        index = (index + delta + tabs.count) % tabs.count
        focus()
    }

    /// ⌘W / ×: a finished tab closes at once; a live SSH session asks first. Then SIGHUP, and SIGKILL to the
    /// whole process group if it's still there after 2 s. False if the user kept it.
    @discardableResult
    func close(_ id: UUID? = nil, confirm: Bool = true) -> Bool {
        guard let tab = id.map({ i in tabs.first { $0.id == i } }) ?? current else { return false }
        if confirm, let what = tab.busyWith {
            let a = NSAlert()
            a.messageText = tab.host != nil ? "Close active SSH session?" : "Close the shell?"
            a.informativeText = "\(what) and anything running in it will end."
            a.addButton(withTitle: "Close")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return false }
        }
        if hangUp(tab) { closing.append(tab) }
        remove(tab)
        return true
    }

    /// Ends the running SSH tabs `match` picks (Disconnect); they stay, to reconnect.
    func hangUp(where match: (SFTPTarget) -> Bool) {
        for tab in tabs where tab.target.map(match) == true { hangUp(tab) }
    }

    /// SIGHUP, and SIGKILL to the whole process group if it's still there after 2 s. False if nothing ran.
    @discardableResult
    private func hangUp(_ tab: Tab) -> Bool {
        guard tab.isRunning, let pid = tab.view.process?.shellPid, pid > 0 else { return false }
        kill(pid, SIGHUP)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                if tab.isRunning { killpg(pid, SIGKILL) }   // forkpty made it a session (group) leader
                self?.closing.removeAll { $0 === tab && !tab.isRunning }
            }
        }
        return true
    }

    private func remove(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.view.removeFromSuperview()
        tabs.remove(at: i)
        if i < index || index >= tabs.count { index = max(index - 1, 0) }
        if tabs.isEmpty {
            container.isHidden = true
            host.isHidden = false
            onChange?()
            onExit?()
        } else {
            focus()
        }
    }

    /// Reconnects the current SSH tab (or the one given) if its `ssh` has ended.
    func reconnect(_ id: UUID? = nil) {
        guard let tab = id.map({ i in tabs.first { $0.id == i } }) ?? current, tab.host != nil, !tab.isRunning else { return NSSound.beep() }
        tab.view.feed(text: "\r\n")
        start(tab, cwd: nil)
        render()
    }

    /// ⌘K clears the tab, as in Terminal (not while a full-screen program — vim, less, mc — has it: theirs would shift). ↩ / ⎋ in a disconnected SSH tab reconnect / close it (its PTY is gone, so the
    /// keys would go nowhere).
    func handleKey(_ e: NSEvent) -> Bool {
        guard isShown, let t = current else { return false }
        if Shortcut(event: e) == Shortcut("cmd+k") {
            if t.view.getTerminal().isCurrentBufferAlternate { return true }
            // The scrollback and every line above the cursor's go; the cursor's line (the prompt) moves to the top.
            let (x, y) = t.view.getTerminal().getCursorLocation()
            t.view.feed(text: "\u{1b}[3J" + (y > 0 ? "\u{1b}[\(y)S" : "") + "\u{1b}[1;\(x + 1)H")
            return true
        }
        guard t.host != nil, !t.isRunning,
              e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch e.keyCode {
        case 36, 76: reconnect()
        case 53: close(t.id)
        default: return false
        }
        return true
    }

    private func render() {
        tabBar.isHidden = tabs.count < 2 && current?.kind == .shell
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, t) in tabs.enumerated() {
            let dot = t.host == nil ? "" : t.isRunning ? "● " : "○ "
            let tip = t.host.map { h in t.isRunning ? "ssh \(h)" : "ssh \(h) — disconnected" } ?? "Shell"
            tabBar.addArrangedSubview(PanelViewController.tabButton(dot + t.label, tip: tip, index: i, current: i == index,
                                                                    target: self, action: #selector(tabClicked(_:)), close: #selector(closeClicked(_:))))
        }
        for (i, t) in tabs.enumerated() { t.view.isHidden = i != index }
        onChange?()
    }

    /// After the current tab changed.
    private func focus() {
        render()
        if isShown, let v = current?.view { v.window?.makeFirstResponder(v) }
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard tabs.indices.contains(sender.tag) else { return }
        index = sender.tag
        focus()
    }

    @objc private func closeClicked(_ sender: NSButton) {
        if tabs.indices.contains(sender.tag) { close(tabs[sender.tag].id) }
    }

    @objc private func reconnectClicked(_ sender: NSButton) {
        tabs.first { $0.reconnect === sender }.map { reconnect($0.id) }
    }

    nonisolated static func atPrompt(_ p: LocalProcess?) -> Bool {
        guard let p, p.running, p.childfd >= 0 else { return false }
        return tcgetpgrp(p.childfd) == p.shellPid
    }

    /// An SSH tab stays after `ssh` ends: it says why and offers Reconnect.
    private func ended(_ tab: Tab, status: Int32) {
        tab.exitStatus = status
        guard let h = tab.host else { return }
        let why = status == -1 ? "Not connected" : SSHCommand.describe(status: status)
        tab.view.feed(text: "\r\n\u{1b}[2m[\(h): \(why)] ↩ reconnect · ⎋ close\u{1b}[0m\r\n")
        let b = NSButton(title: "Reconnect", target: self, action: #selector(reconnectClicked(_:)))
        b.bezelStyle = .rounded
        b.keyEquivalent = ""
        b.translatesAutoresizingMaskIntoConstraints = false
        tab.view.addSubview(b)
        NSLayoutConstraint.activate([
            b.trailingAnchor.constraint(equalTo: tab.view.trailingAnchor, constant: -24),
            b.bottomAnchor.constraint(equalTo: tab.view.bottomAnchor, constant: -12),
        ])
        tab.reconnect = b
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    /// OSC 7 (`cd` in a shell that reports it: fish, Terminal's zsh setup, a remote one set up for it). The bytes are the
    /// same whoever prints them, so a local tab's counts only while the shell has the terminal and only for the folder
    /// it's in (the kernel's word): not what an `ssh` run in it, a `printf`, a `cat` or a `tail -f` says. An SSH tab's
    /// can't be checked (the remote shell's state isn't ours to see): a folder the server can't list moves nothing.
    /// Told to the app only while the terminal is up: hidden, the panels are the user's.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let t = tabs.first(where: { $0.view === source }), let dir = directory.flatMap(Self.osc7Path), dir != t.cwd,
              t.host != nil || t.isAtPrompt
                && t.shellCwd.map({ cwd in realpath(dir, nil).map { p in defer { free(p) }; return String(cString: p) } == cwd }) == true
        else { return }
        t.cwd = dir
        if t.host == nil { render() }   // the tab is named after its folder
        if t === current, isShown { onDirectory?(t) }
    }

    /// "file://host/some%20dir" → "/some dir".
    nonisolated static func osc7Path(_ url: String) -> String? {
        guard let u = URL(string: url), u.isFileURL, !u.path.isEmpty else { return nil }
        return u.path
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let t = tabs.first(where: { $0.view === source }), t.title != title else { return }
        t.title = title
        render()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let tab = (self.tabs + self.closing).first(where: { $0.view === source }) else { return }
                self.finished(tab, status: exitCode ?? 0)
            }
        }
    }

    /// The tab's process ended (told by SwiftTerm or by `launch`'s watch; the second word is dropped). `exit` in a
    /// shell closes its tab (the next ⌃O starts a fresh shell); an SSH tab stays, disconnected.
    private func finished(_ tab: Tab, status: Int32) {
        guard tab.exitStatus == nil else { return }
        tab.exitStatus = status
        closing.removeAll { $0 === tab }
        guard tabs.contains(where: { $0 === tab }) else { return }
        if tab.host == nil { return remove(tab) }
        ended(tab, status: status)
        render()
    }
}

/// A tab's view that takes files dropped on it (from Finder or a panel) and types their quoted paths into the shell,
/// as Terminal does. Only a local tab's: this Mac's paths mean nothing to a server's shell.
final class DropTerminalView: LocalProcessTerminalView {
    var acceptsLocalPaths = true
    /// Where several lines pasted by a right-click ask first (`pasteQuestion`): "web1 (production)", "root@web1"; nil:
    /// nowhere. A shell there that runs each line as it comes, without bracketed paste, would run them all.
    var pasteRisk: () -> String? = { nil }
    /// The question (tests answer it): the text, where, the window; true pastes. ↩ is Cancel.
    static var pasteQuestion: @MainActor (String, String, NSWindow?) async -> Bool = { text, place, window in
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).count
        let a = AppDelegate.alert("Paste \(lines) lines into \(place)?", info: "Its shell runs each line as it arrives.", ["Paste", "Cancel"], default: 1)
        guard let window else { return a.runModal() == .alertFirstButtonReturn }
        return await AppDelegate.sheet(a, on: window) == 0
    }
    private var upMonitor: Any?   // a selection being dragged: copied once the button is up
    var pasteboard = NSPasteboard.general   // tests: their own

    // PuTTY's mouse. A selection goes to the clipboard as it's made (`terminalCopyOnSelect`); a right-click pastes
    // (`terminalRightClickPaste`) — in a program that reads the mouse itself (mc, htop, vim's mouse=a), ⇧-right-click.
    static func on(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// The mouse's left button is down now (a drag under way). Tests: not the real mouse, which someone may be pressing.
    static var leftButtonDown = { NSEvent.pressedMouseButtons & 1 != 0 }

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        guard Self.on("terminalCopyOnSelect") else { return }
        guard Self.leftButtonDown() else { return copySelection() }   // ⌘A, or made at once
        guard upMonitor == nil else { return }   // dragging: once, when it ends — not on every move
        upMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] e in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.dragEnded() } }   // after the view's own mouseUp
            return e
        }
    }

    private func dragEnded() {
        upMonitor.map(NSEvent.removeMonitor)
        upMonitor = nil
        copySelection()
    }

    /// The selection into the clipboard; nothing selected (a click cleared it): the clipboard stays.
    func copySelection() {
        guard let text = getSelection(), !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// A plain right-click is the program's when it reads the mouse itself; ⇧ pastes there anyway.
    nonisolated static func rightClickPastes(shift: Bool, programReadsMouse: Bool) -> Bool { shift || !programReadsMouse }

    /// Several lines into a shell that runs each as it comes (no bracketed paste), where that's risky: ask.
    nonisolated static func pasteAsks(_ text: String, bracketed: Bool, risky: Bool) -> Bool { risky && !bracketed && text.contains { $0 == "\n" || $0 == "\r" } }

    override func rightMouseDown(with event: NSEvent) {
        guard Self.on("terminalRightClickPaste"),
              Self.rightClickPastes(shift: event.modifierFlags.contains(.shift), programReadsMouse: allowMouseReporting && getTerminal().mouseMode != .off)
        else { return super.rightMouseDown(with: event) }
        window?.makeFirstResponder(self)
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return NSSound.beep() }
        let risk = pasteRisk(), ask = Self.pasteAsks(text, bracketed: getTerminal().bracketedPasteMode, risky: risk != nil)
        Task {
            if ask, let risk, await !Self.pasteQuestion(text, risk, window) { return }
            paste(self)   // as ⌘V: bracketed when the shell asked for it
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { acceptsLocalPaths ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { drop(sender.draggingPasteboard) }

    /// Types the pasteboard's files; false (and a beep) on an SSH tab, without files, or for a path the line editor
    /// would act on (`isTypeable`).
    @discardableResult
    func drop(_ pb: NSPasteboard) -> Bool {
        guard acceptsLocalPaths, let line = Self.typed(from: pb) else { NSSound.beep(); return false }
        send(txt: line)
        return true
    }

    /// "'/tmp/a b' /tmp/c " for the pasteboard's file URLs.
    static func typed(from pb: NSPasteboard) -> String? {
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return nil }
        let line = urls.map { ShellContext.quote($0.path) }.joined(separator: " ") + " "
        return ShellContext.isTypeable(line) ? line : nil
    }
}
