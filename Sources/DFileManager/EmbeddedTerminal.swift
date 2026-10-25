import AppKit
import DFMCore
import SwiftTerm

/// ⌃O (MC's subshell): a terminal workspace in a drawer under the panels (Р6) — or over all of their room (⌃⇧O,
/// `isFull`) — with tabs: local login shells and SSH sessions (system OpenSSH, one PTY and one `ssh` process per
/// session). A tab holds up to four of them side by side (`Group`, VS Code's split); `Tab` is one session, a pane. For
/// the current pane when it's a local shell: the active panel follows its `cd`, and goes to its folder when it hides;
/// showing it again `cd`s it to the panel's.
@MainActor
final class EmbeddedTerminal: NSObject, @preconcurrency LocalProcessTerminalViewDelegate, NSSplitViewDelegate {
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
        let box = NSStackView()   // the pane: its header (while the tab has several) over the view
        let header = NSView()
        init(kind: Kind, view: DropTerminalView) {
            self.kind = kind
            self.view = view
            box.orientation = .vertical
            box.alignment = .width
            box.distribution = .fill   // the header at its height, the view the rest
            box.spacing = 0
            box.addArrangedSubview(header)
            box.addArrangedSubview(view)
            for v in [header, view] { v.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true }   // `.width` alone sizes them to each other
            header.isHidden = true
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

    /// One tab's panes, side by side or one above another (⌘\\ / ⌘⇧\\): the first split picks the way, later ones
    /// follow it. One way only, as VS Code's.
    @MainActor
    final class Group {
        var panes: [Tab]
        var focused = 0             // the pane keys go to
        var vertical = true         // side by side (NSSplitView's word); false: one above another
        var needsEqualSizes = true  // restored or just split: equal sizes once it's laid out
        let split = PaneSplitView()
        init(_ panes: [Tab]) { self.panes = panes }
        var pane: Tab { panes[min(focused, panes.count - 1)] }
        var title: String { panes.map(\.label).joined(separator: " │ ") }
    }
    nonisolated static let maxPanes = 4   // as many as file panels; past that a 13" screen has no room
    private static let minPane: CGFloat = 120

    /// What comes back after a restart: each tab's SSH sessions, disconnected, and its way. Local shells don't.
    struct SavedGroup: Codable, Equatable {
        var vertical: Bool
        var panes: [SFTPTarget]
    }
    var saved: [SavedGroup] {
        groups.compactMap { g in
            let p = g.panes.compactMap(\.target)
            return p.isEmpty ? nil : SavedGroup(vertical: g.vertical, panes: p)
        }
    }

    /// "/Users/me/src/a b" → "a b", the home folder → "~", "/" → "/".
    nonisolated static func folderName(_ path: String) -> String { ((path as NSString).abbreviatingWithTildeInPath as NSString).lastPathComponent }

    private(set) var groups: [Group] = []
    /// Every session, tab by tab, pane by pane.
    var tabs: [Tab] { groups.flatMap(\.panes) }
    private var index = 0   // the current group
    private var closing: [Tab] = []   // killed, waiting for the process to go
    private let container = NSStackView()
    let tabBar = NSStackView()   // internal: tests read it
    /// The tabs and, at their right end, Split, Maximize and Hide: each a command (`onCommand`), Hide `onHide`.
    private let topRow = NSStackView()
    private let content = NSView()
    private unowned let host: NSView   // the panels; the drawer goes under them
    /// The panels on top, the terminal under them; with `isFull` the terminal alone. Made around the panels when they
    /// have a superview (at once in the app).
    let drawer = NSSplitView()
    /// ⌃⇧O: the terminal takes the panels' room too, as ⌃O did before the drawer.
    private(set) var isFull = false
    /// The drawer's height as last dragged; after a restart, as the split saved it (`autosave`, AppKit's own key).
    private var drawerHeight: CGFloat?
    private let autosave: String?
    static let minDrawer: CGFloat = 80, minPanels: CGFloat = 120
    var onCommand: ((String) -> Void)?
    var onHide: (() -> Void)?
    /// A command's key, as the keymap has it: the buttons' tooltips.
    var keyFor: ((String) -> String?)?
    private let maximize = NSButton(title: "", target: nil, action: nil)
    var onExit: (() -> Void)?          // last tab closed: panels come back
    var onChange: (() -> Void)?        // tabs / states changed (sidebar, saved session)
    var onDirectory: ((Tab) -> Void)?  // the current tab's shell told its folder (`cwd`)
    /// ⌘+ / ⌘−, every tab; kept in `terminalFontSize` (clamped to 9…36; 13 if unset).
    private(set) var fontSize: CGFloat = (UserDefaults.standard.object(forKey: "terminalFontSize") as? Double).map { min(max($0, 9), 36) } ?? 13
    private var hiddenAt = -TimeInterval.infinity   // uptime; ⌃O ⌃O

    var isShown: Bool { container.superview != nil && !container.isHidden }
    private var group: Group? { groups.indices.contains(index) ? groups[index] : nil }
    /// The current tab's focused pane: what keys, ⌃↩, ⌘R and the like act on.
    var current: Tab? { group?.pane }
    var hasFocus: Bool { isShown && (container.window?.firstResponder as? NSView)?.isDescendant(of: container) == true }

    /// `autosave`: the drawer's height is kept under this name (the app's; tests' none).
    init(covering host: NSView, autosave: String? = nil) {
        self.host = host
        self.autosave = autosave
        super.init()
        container.orientation = .vertical
        container.spacing = 2
        container.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 0, right: 0)
        container.distribution = .fill   // the tabs at their height, the panes the rest of the drawer
        content.setContentHuggingPriority(.init(1), for: .vertical)
        topRow.setContentHuggingPriority(.defaultHigh, for: .vertical)
        container.isHidden = true
        tabBar.distribution = .fillEqually
        tabBar.spacing = 2
        topRow.spacing = 6
        topRow.addArrangedSubview(tabBar)
        for (symbol, label, id) in [(Symbol.splitRight, "Split Terminal Right", "term.split.right"), (.maximize, "Maximize Terminal", "view.terminalFull"),
                                    (.collapse, "Hide Terminal", "view.terminal")] {
            let b = symbol == .maximize ? maximize : NSButton(title: "", target: nil, action: nil)
            b.image = symbol.image(label)
            b.isBordered = false
            b.refusesFirstResponder = true
            b.identifier = .init(id)
            b.target = self
            b.action = #selector(rowButton(_:))
            b.setContentHuggingPriority(.required, for: .horizontal)
            topRow.addArrangedSubview(b)
        }
        container.addArrangedSubview(topRow)
        container.addArrangedSubview(content)
        topRow.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -12).isActive = true
        content.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        wrap()
        // SwiftTerm's scrollWheel and mouseDown aren't open: the pane under the mouse sees these first.
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseUp]) { [weak self] e in
            guard let self else { return e }
            if e.type == .leftMouseUp { tabs.forEach { $0.view.mouseReleased() }; return e }
            guard let g = group, let i = paneIndex(under: e, in: g) else { return e }
            let v = g.panes[i].view
            if e.type == .scrollWheel { return v.wheel(e) ? nil : e }
            if i != g.focused { g.focused = i; render() }   // the click makes its view first responder itself
            v.shiftDown(e)
            return e
        }
    }

    func paneIndex(under e: NSEvent, in g: Group) -> Int? {
        g.panes.firstIndex { t in
            e.window === t.view.window && !t.view.isHiddenOrHasHiddenAncestor && t.view.bounds.contains(t.view.convert(e.locationInWindow, from: nil))
        }
    }

    /// The panels into the drawer's split, the terminal (hidden) under them, in the panels' place.
    private func wrap() {
        guard container.superview == nil, let sup = host.superview else { return }
        drawer.isVertical = false
        drawer.dividerStyle = .thin
        drawer.delegate = self
        drawer.frame = host.frame
        drawer.autoresizingMask = [.width, .height]
        sup.addSubview(drawer, positioned: .above, relativeTo: host)
        host.removeFromSuperview()
        host.translatesAutoresizingMaskIntoConstraints = true
        container.translatesAutoresizingMaskIntoConstraints = true
        drawer.addSubview(host)
        drawer.addSubview(container)
        if let autosave {
            drawer.autosaveName = autosave   // brings back the frames it saved: the drawer's height, unless it was full then
            if !host.isHidden, container.frame.height >= Self.minDrawer { drawerHeight = container.frame.height }
        }
        host.isHidden = false
        container.isHidden = true
    }

    private func attach() { wrap() }

    /// The drawer at its height — as last dragged, else 40 % of the room — between its least and the panels' least.
    private func layoutDrawer() {
        let total = drawer.bounds.height, line = drawer.dividerThickness
        let h = min(max(drawerHeight ?? total * 0.4, Self.minDrawer), total - Self.minPanels - line)
        drawer.adjustSubviews()
        guard total > 0, h >= Self.minDrawer else { return }
        drawer.setPosition(total - h - line, ofDividerAt: 0)
        drawer.layoutSubtreeIfNeeded()   // the panes at their new size now, not at the next pass (none comes without a window)
    }

    /// ⌃⇧O: the terminal over the panels' room too, or back into its drawer.
    func setFull(_ on: Bool) {
        guard isShown, on != isFull else { return }
        isFull = on
        host.isHidden = on
        on ? drawer.adjustSubviews() : layoutDrawer()
        drawer.layoutSubtreeIfNeeded()
        maximize.image = (on ? Symbol.restore : Symbol.maximize).image(on ? "Restore Terminal" : "Maximize Terminal")
        render()
    }

    @objc private func rowButton(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        id == "view.terminal" ? onHide?() : onCommand?(id)
    }

    // MARK: - Showing

    /// ⌃O on a local panel: shows a live local shell (the current one, any other, else a new one in `cwd`) —
    /// never an SSH tab, even a restored or disconnected one. Returns the view to focus.
    func show(cwd: String) -> NSView {
        let shells = tabs.filter { $0.kind == .shell && $0.isRunning }
        if let t = shells.first(where: { $0 === current }) ?? shells.first {
            reveal(t)
            if t.isAtPrompt, t.shellCwd != cwd, let line = ShellContext.typedCd(cwd) { t.view.send(txt: line) }
        } else {
            newShell(cwd: cwd)
        }
        return show()
    }

    /// Shows the workspace on the tab the caller picked: in its drawer, or over the panels while `isFull`.
    func show() -> NSView {
        attach()
        let opening = container.isHidden
        container.isHidden = false
        host.isHidden = isFull
        if opening && !isFull { layoutDrawer() }
        render()
        return current!.view
    }

    /// Hides the workspace; returns the current shell's folder (nil for SSH tabs). `e`: the event that hid it — only a
    /// pressed ⌃O arms ⌃O ⌃O, not a command that hides the terminal on its way.
    func hide(_ e: NSEvent? = nil) -> String? {
        let cwd = current.flatMap { $0.kind == .shell ? $0.shellCwd : nil }
        container.isHidden = true
        host.isHidden = false
        isFull = false
        drawer.adjustSubviews()
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
            reveal(t)
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

    /// After a restart: SSH tabs come back disconnected, in their tabs; ↩ / Reconnect connects each.
    func restore(_ saved: [SavedGroup]) {
        for s in saved where !s.panes.isEmpty {
            let g = Group(s.panes.prefix(Self.maxPanes).map { Tab(kind: .ssh($0), view: makeView()) })
            g.vertical = s.vertical
            groups.append(g)
            install(g)
            g.panes.forEach { ended($0, status: -1) }
        }
        index = 0
    }

    /// Each in a tab of its own (what 1.3 and earlier saved: `sshTabs`).
    func restore(_ targets: [SFTPTarget]) { restore(targets.map { SavedGroup(vertical: true, panes: [$0]) }) }

    private func add(_ tab: Tab, cwd: String?) -> NSView {
        let g = Group([tab])
        groups.insert(g, at: groups.isEmpty ? 0 : index + 1)
        index = groups.firstIndex { $0 === g }!
        install(g)
        start(tab, cwd: cwd)
        focus()
        return tab.view
    }

    /// Makes `t` the current tab's focused pane.
    private func reveal(_ t: Tab) {
        guard let gi = groups.firstIndex(where: { $0.panes.contains { $0 === t } }) else { return }
        index = gi
        groups[gi].focused = groups[gi].panes.firstIndex { $0 === t }!
    }

    // MARK: - Split

    /// ⌘\\ / ⌘⇧\\ (VS Code's Split Terminal): a new pane after the current one — beside it or under it; a tab that has
    /// several already keeps its way. An SSH pane: another session on that server, over its shared connection (no new
    /// login), in the folder its shell told (OSC 7), else home; a local one: a shell in the same folder.
    func split(vertical: Bool) {
        guard isShown, let g = group, let t = current, g.panes.count < Self.maxPanes else { return NSSound.beep() }
        if g.panes.count == 1 { g.vertical = vertical }
        let new = Tab(kind: t.kind, view: makeView())
        if t.host != nil { new.command = t.cwd.map { SSHCommand.shell(in: $0) } }
        g.panes.insert(new, at: g.focused + 1)
        g.focused += 1
        arrange(g)
        start(new, cwd: t.host == nil ? t.folder ?? NSHomeDirectory() : nil)
        focus()
    }

    /// ⌥⌘← → in a tab side by side, ↑ ↓ in one above another: the pane before or after.
    func focusPane(by d: Int, vertical: Bool) {
        guard isShown, let g = group, g.panes.count > 1, g.vertical == vertical, g.panes.indices.contains(g.focused + d) else { return NSSound.beep() }
        g.focused += d
        focus()
    }

    /// ⌃⌘ arrows: the current pane's divider moves that way by a twentieth of the tab — its right (lower) one, the last
    /// pane's left (upper) one. Never closer than `minPane` to another divider.
    func resizePane(by d: Int, vertical: Bool) {
        guard isShown, let g = group, g.panes.count > 1, g.vertical == vertical else { return NSSound.beep() }
        let s = g.split, i = min(g.focused, g.panes.count - 2)
        let (a, b) = (g.panes[i].box.frame, g.panes[i + 1].box.frame)
        let lo = (vertical ? a.minX : a.minY) + Self.minPane, hi = (vertical ? b.maxX : b.maxY) - Self.minPane - s.dividerThickness
        let step = (vertical ? s.bounds.width : s.bounds.height) / 20
        s.setPosition(min(max((vertical ? a.maxX : a.maxY) + CGFloat(d) * step, lo), hi), ofDividerAt: i)
    }

    /// The tabs Join Tab… offers: all but the current one, while there's room for their panes.
    var joinable: [Group] {
        guard let g = group else { return [] }
        return groups.filter { $0 !== g && $0.panes.count + g.panes.count <= Self.maxPanes }
    }

    /// Join Tab…: another tab's panes go after the current tab's (up to `maxPanes`), the first of them focused; that tab goes.
    func join(_ other: Group) {
        guard let g = group, joinable.contains(where: { $0 === other }) else { return NSSound.beep() }
        other.split.removeFromSuperview()
        groups.removeAll { $0 === other }
        index = groups.firstIndex { $0 === g }!
        g.focused = g.panes.count
        g.panes += other.panes
        arrange(g)
        focus()
    }

    /// Move Pane to New Tab (VS Code's Unsplit): the current pane alone, in a tab after this one.
    func unsplit() {
        guard isShown, let g = group, g.panes.count > 1, let t = current else { return NSSound.beep() }
        g.panes.remove(at: g.focused)
        g.focused = max(g.focused - 1, 0)
        arrange(g)
        let n = Group([t])
        groups.insert(n, at: index + 1)
        index += 1
        install(n)
        focus()
    }

    /// The group's panes into its split view, in order, its way; equal sizes once it's laid out.
    private func arrange(_ g: Group) {
        g.split.isVertical = g.vertical
        for v in g.split.arrangedSubviews where !g.panes.contains(where: { $0.box === v }) { v.removeFromSuperview() }
        for (i, t) in g.panes.enumerated() where g.split.arrangedSubviews.firstIndex(of: t.box) != i {
            t.box.removeFromSuperview()
            g.split.insertArrangedSubview(t.box, at: i)
        }
        g.needsEqualSizes = true
    }

    private func install(_ g: Group) {
        g.split.dividerStyle = .thin
        g.split.delegate = self
        g.split.onDoubleClick = { [weak self, weak g] in g.map { self?.equalize($0) } }
        pin(g.split)
        arrange(g)
    }

    /// A double-click on a divider, a split, a restored tab shown: every pane the same size.
    private func equalize(_ g: Group) {
        let s = g.split, n = CGFloat(g.panes.count)
        guard n > 1 else { return }
        container.layoutSubtreeIfNeeded()
        let total = s.isVertical ? s.bounds.width : s.bounds.height
        guard total > 0 else { return }
        g.needsEqualSizes = false
        let each = (total - s.dividerThickness * (n - 1)) / n
        equalizing = true   // the panes just added are still empty: `minPane` would hold the dividers where they are
        defer { equalizing = false }
        for i in 0..<g.panes.count - 1 { s.setPosition(each * CGFloat(i + 1) + s.dividerThickness * CGFloat(i), ofDividerAt: i) }
    }
    private var equalizing = false

    func splitView(_ s: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        s === drawer ? Self.minPanels : equalizing ? p : p + Self.minPane
    }
    func splitView(_ s: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        s === drawer ? s.bounds.height - Self.minDrawer - s.dividerThickness : equalizing ? p : p - Self.minPane
    }
    /// A taller or shorter window: the panels give or take, the drawer keeps its height.
    func splitView(_ s: NSSplitView, shouldAdjustSizeOfSubview v: NSView) -> Bool { s !== drawer || v === host || host.isHidden }
    func splitView(_ s: NSSplitView, shouldHideDividerAt i: Int) -> Bool { s === drawer && (container.isHidden || host.isHidden) }
    func splitViewDidResizeSubviews(_ n: Notification) {
        guard n.object as? NSSplitView === drawer, !container.isHidden, !host.isHidden, container.frame.height >= Self.minDrawer else { return }
        drawerHeight = container.frame.height   // dragged, or set: kept for the next ⌃O
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
                    tab.view.feed(text: "\(t.host) stays locked\r\n")
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
            render()   // its tab was drawn before ssh ran: off till the next redraw (D-104)
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

    /// A session's sidebar row: its tab, that pane focused.
    func select(_ id: UUID) {
        guard let t = tabs.first(where: { $0.id == id }) else { return }
        reveal(t)
        focus()
    }

    func switchTab(by delta: Int) {
        guard groups.count > 1 else { return }
        index = (index + delta + groups.count) % groups.count
        focus()
    }

    /// × on a tab of several panes: one question for all that would end, then each goes as `close` does.
    @discardableResult
    func close(group g: Group) -> Bool {
        guard g.panes.count > 1 else { return close(g.panes[0].id) }
        let busy = g.panes.compactMap(\.busyWith)
        if !busy.isEmpty {
            let a = NSAlert()
            a.messageText = "Close \(g.panes.count) sessions?"
            a.informativeText = busy.joined(separator: "\n") + "\nand anything running in them will end."
            a.addButton(withTitle: "Close")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return false }
        }
        for t in g.panes {
            if hangUp(t) { closing.append(t) }
            remove(t)
        }
        return true
    }

    /// ⌘W / × on a pane (or a tab of one): a finished session closes at once; a live SSH session asks first. Then SIGHUP, and SIGKILL to the
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

    /// The pane goes; the focus to the one taking its place (the one before it, for the last). Its tab goes with its last pane.
    private func remove(_ tab: Tab) {
        guard let gi = groups.firstIndex(where: { $0.panes.contains { $0 === tab } }) else { return }
        let g = groups[gi], pi = g.panes.firstIndex { $0 === tab }!
        g.panes.remove(at: pi)
        if pi < g.focused || g.focused >= g.panes.count { g.focused = max(g.focused - 1, 0) }
        if g.panes.isEmpty {
            g.split.removeFromSuperview()
            groups.remove(at: gi)
            if gi < index || index >= groups.count { index = max(index - 1, 0) }
        } else {
            arrange(g)
        }
        if groups.isEmpty {
            container.isHidden = true
            host.isHidden = false
            isFull = false
            drawer.adjustSubviews()
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
        tabBar.isHidden = groups.count < 2 && group?.panes.count == 1 && current?.kind == .shell
        for b in topRow.arrangedSubviews.compactMap({ $0 as? NSButton }) {   // the row's buttons say their keys
            guard let id = b.identifier?.rawValue else { continue }
            let what = id == "view.terminal" ? "Hide Terminal" : id == "view.terminalFull" ? (isFull ? "Restore Terminal" : "Maximize Terminal") : "Split Terminal Right"
            b.toolTip = what + (keyFor?(id).map { "  " + $0 } ?? "")
            b.setAccessibilityLabel(what)
        }
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, g) in groups.enumerated() {
            let b = PanelViewController.tabButton(g.panes.map { (Self.lead($0), $0.label) }, tint: g.panes.count == 1 ? Self.tint(g.pane) : nil,
                                                  tip: g.panes.map(Self.tip).joined(separator: "\n"), index: i, current: i == index,
                                                  target: self, action: #selector(tabClicked(_:)), close: #selector(closeClicked(_:)))
            if i != index {
                b.menu = NSMenu()
                b.menu!.addItem(withTitle: "Join with Current Tab", action: #selector(joinClicked(_:)), keyEquivalent: "").tag = i
                b.menu!.items.forEach { $0.target = self }
            }
            tabBar.addArrangedSubview(b)
        }
        for (i, g) in groups.enumerated() {
            g.split.isHidden = i != index
            for (j, t) in g.panes.enumerated() { header(t, index: j, focused: j == g.focused, shown: g.panes.count > 1) }
        }
        if isShown, let g = group, g.needsEqualSizes { equalize(g) }
        onChange?()
    }

    /// An SSH pane's state (on while ssh runs, off once it ended) and its server's chips — root for a root login.
    private static func lead(_ t: Tab) -> NSAttributedString? {
        guard t.host != nil else { return nil }
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let s = NSMutableAttributedString(attributedString: t.isRunning ? StateMark.on.text("connected", font: font) : StateMark.off.text("disconnected", font: font))
        if let c = Chip.text(chips(t)) { s.append(NSAttributedString(string: " ")); s.append(c) }
        return s
    }
    private static func chips(_ t: Tab) -> [Chip] { t.target.map { Chip.of($0, root: $0.host.hasPrefix("root@")) } ?? [] }
    private static func tip(_ t: Tab) -> String { t.host.map { h in t.isRunning ? "ssh \(h)" : "ssh \(h) — disconnected" } ?? "Shell" }
    /// A production server's pane underlined in purple, a root login's in orange — as a panel's line.
    private static func tint(_ t: Tab) -> NSColor? { Chip.tint(chips(t)) }

    /// A pane's header while its tab has several: which server, which folder, whether keys go there (bold, the line).
    private func header(_ t: Tab, index j: Int, focused: Bool, shown: Bool) {
        t.header.subviews.forEach { $0.removeFromSuperview() }
        t.header.isHidden = !shown
        guard shown else { return }
        var title = t.label
        if t.host != nil, let dir = t.cwd, !title.contains(EmbeddedTerminal.folderName(dir)) { title += " · " + EmbeddedTerminal.folderName(dir) }
        let b = PanelViewController.tabButton(title, lead: Self.lead(t), tint: Self.tint(t), tip: Self.tip(t), index: j, current: focused,
                                              target: self, action: #selector(paneClicked(_:)), close: #selector(paneCloseClicked(_:)), closeTip: "Close Pane  ⌘W")
        b.menu = NSMenu()
        for (title, action) in [("Move Pane to New Tab", #selector(unsplitClicked(_:))), ("Close Pane", #selector(paneCloseClicked(_:)))] {
            let item = b.menu!.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = j
        }
        b.translatesAutoresizingMaskIntoConstraints = false
        t.header.addSubview(b)
        NSLayoutConstraint.activate([
            b.leadingAnchor.constraint(equalTo: t.header.leadingAnchor, constant: 4), b.trailingAnchor.constraint(equalTo: t.header.trailingAnchor, constant: -4),
            b.topAnchor.constraint(equalTo: t.header.topAnchor, constant: 2), b.bottomAnchor.constraint(equalTo: t.header.bottomAnchor, constant: -2),
        ])
    }

    /// After the current tab changed.
    private func focus() {
        render()
        if isShown, let v = current?.view { v.window?.makeFirstResponder(v) }
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard groups.indices.contains(sender.tag) else { return }
        index = sender.tag
        focus()
    }

    @objc private func closeClicked(_ sender: NSButton) {
        if groups.indices.contains(sender.tag) { close(group: groups[sender.tag]) }
    }

    @objc private func joinClicked(_ sender: NSMenuItem) {
        if groups.indices.contains(sender.tag) { join(groups[sender.tag]) }
    }

    // A header's: the current tab's panes (only its headers show).
    @objc private func paneClicked(_ sender: NSButton) {
        guard let g = group, g.panes.indices.contains(sender.tag) else { return }
        g.focused = sender.tag
        focus()
    }

    @objc private func paneCloseClicked(_ sender: Any) {   // the ×, or the header's menu
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? -1
        if let g = group, g.panes.indices.contains(tag) { close(g.panes[tag].id) }
    }

    @objc private func unsplitClicked(_ sender: NSMenuItem) {
        guard let g = group, g.panes.indices.contains(sender.tag) else { return }
        g.focused = sender.tag
        unsplit()
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
        tab.view.feed(text: "\r\n\u{1b}[2m[\(h): \(why)] ↩ Reconnect   ⎋ Close\u{1b}[0m\r\n")
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
        render()   // a local tab is named after its folder; a pane's header shows it
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

/// A tab's panes; a double-click on a divider makes them the same size.
final class PaneSplitView: NSSplitView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with e: NSEvent) { e.clickCount == 2 ? onDoubleClick?() : super.mouseDown(with: e) }
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

    /// OSC 52 (Claude Code's, tmux's, vim's copy): the program's text into the clipboard, a server's too. SwiftTerm
    /// drops it on the Mac. A read (`?`) would hand the clipboard to the program: never answered. Nor does a tab you
    /// aren't looking at write it.
    func osc52(_ data: ArraySlice<UInt8>) {
        guard !isHiddenOrHasHiddenAncestor, let semi = data.firstIndex(of: UInt8(ascii: ";")), data[(semi + 1)...].first != UInt8(ascii: "?"),
              let bytes = Data(base64Encoded: Data(data[(semi + 1)...]), options: .ignoreUnknownCharacters),
              let text = String(data: bytes, encoding: .utf8), !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var wheelRest: CGFloat = 0   // a trackpad's fractions of a line, till they make one
    /// The wheel in a program that reads the mouse (Claude Code, htop, vim's mouse=a) is its wheel, as in Terminal.app:
    /// SwiftTerm only scrolls its own scrollback, and a full-screen program has none. False: SwiftTerm's.
    func wheel(_ e: NSEvent) -> Bool {
        let t = getTerminal()
        guard allowMouseReporting, t.mouseMode != .off else { return false }
        wheelRest += e.deltaY
        let n = Int(wheelRest)
        wheelRest -= CGFloat(n)
        guard n != 0, bounds.width > 0, bounds.height > 0 else { return true }
        // ponytail: the cell from the view's size (SwiftTerm's cell size isn't public); off by the scroller's width at most
        let p = convert(e.locationInWindow, from: nil)
        let col = min(t.cols - 1, max(0, Int(p.x / bounds.width * CGFloat(t.cols))))
        let row = min(t.rows - 1, max(0, Int((bounds.height - p.y) / bounds.height * CGFloat(t.rows))))
        let f = e.modifierFlags
        let flags = t.encodeButton(button: n > 0 ? 4 : 5, release: false, shift: f.contains(.shift), meta: f.contains(.option), control: f.contains(.control))
        for _ in 0..<abs(n) { t.sendEvent(buttonFlags: flags, x: col, y: row) }
        return true
    }

    private var shiftSelecting = false
    /// ⇧-drag (xterm's) or ⌥-drag (iTerm's) in a program that reads the mouse selects here instead: the program gets no
    /// mouse till the button is up. Its next redraw clears the selection, so it's copied then (`mouseReleased`).
    func shiftDown(_ e: NSEvent) {
        guard !e.modifierFlags.isDisjoint(with: [.shift, .option]), allowMouseReporting, getTerminal().mouseMode != .off else { return }
        allowMouseReporting = false
        shiftSelecting = true
    }

    func mouseReleased() {
        guard shiftSelecting else { return }
        shiftSelecting = false
        copySelection()
        DispatchQueue.main.async { MainActor.assumeIsolated { self.allowMouseReporting = true } }   // after SwiftTerm's mouseUp: no release without a press
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        getTerminal().registerOscHandler(code: 52) { [weak self] d in MainActor.assumeIsolated { self?.osc52(d) } }
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
