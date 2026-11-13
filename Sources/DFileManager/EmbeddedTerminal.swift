import AppKit
import DFMCore
import os
import SwiftTerm

/// ⌃O (MC's subshell): a terminal workspace in a drawer under the panels (Р6) — or over all of their room (⌃⇧O,
/// `isFull`) — with tabs: local login shells and SSH sessions (system OpenSSH, one PTY and one `ssh` process per
/// session). A tab holds up to four of them side by side (`Group`, VS Code's split); `Tab` is one session, a pane. For
/// the current pane when it's a local shell: the active panel follows its `cd`, and goes to its folder when it hides;
/// showing it again `cd`s it to the panel's.
@MainActor
final class EmbeddedTerminal: NSObject, LocalProcessTerminalViewDelegate, NSSplitViewDelegate {
    enum Kind: Equatable { case shell, ssh(SFTPTarget) }

    @MainActor
    final class Tab {
        let id = UUID()
        let kind: Kind
        let view: DropTerminalView
        var title = ""            // set by the remote / local shell (OSC 0/2)
        var exitStatus: Int32?    // set when the process's end was told (raw wait status; -1 = never started, `bySignal`)
        var reconnect: NSButton?
        var command: String?      // SSH: what to run instead of a login shell, once
        var cwd: String?          // the folder its shell last told (OSC 7); SSH: on the server
        /// What happened in it while it wasn't shown (a tab behind another, a pane under a zoom): until it shows again.
        var news: News?
        enum News { case output, bell }
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
            // The folder a server's shell tells (OSC 7) is never taken for one of this Mac's. Paths never reach SwiftTerm's
            // own opening (which would read them as this Mac's): `TerminalLink` routes them, an SSH tab's to its server.
            view.resolvesLinksAgainstShellDirectory = kind == .shell
            // Lines pasted by a right-click into a production server, or as root, ask first.
            if case .ssh(let t) = kind {
                view.pasteRisk = {
                    let chips = Chip.of(t, root: t.host.hasPrefix("root@")).filter { $0 != .locked }
                    return chips.isEmpty ? nil : (chips, SavedServer.name(for: t))
                }
            }
        }

        var target: SFTPTarget? { if case .ssh(let t) = kind { t } else { nil } }
        var host: String? { target?.host }
        var isRunning: Bool { exitStatus == nil && view.process?.running == true }
        /// The shell itself has the terminal (not ssh, vim, mysql, sudo's password prompt…): only then may a typed
        /// `cd` go in.
        var isAtPrompt: Bool { EmbeddedTerminal.atPrompt(view.process) && (host != nil || started == nil || foreground == started) }
        /// The program a local tab's shell was started as ("zsh"): one it `exec`ed (`exec ssh host`) has its pid, not
        /// its name — never at the prompt for a typed `cd` or ⌘E ↩.
        var started: String?
        /// What closing the tab would end: an SSH connection, or a program still running in a local shell.
        var busyWith: String? {
            guard isRunning else { return nil }
            if let host { return "The connection to “\(host)”" }
            guard !isAtPrompt else { return nil }
            return foreground.map { "“\($0)” in a shell" } ?? "A program in a shell"
        }
        /// What has a local tab's terminal now: its shell, a program it runs, what the shell `exec`ed; nil: unknown.
        var foreground: String? {
            guard host == nil, let p = view.process, isRunning else { return nil }
            var name = [UInt8](repeating: 0, count: 256)
            let pg = tcgetpgrp(p.childfd)
            return pg > 0 && proc_name(pg, &name, 256) > 0 ? String(decoding: name.prefix { $0 != 0 }, as: UTF8.self) : nil
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
        /// ⇧⌘↩: the pane over the whole tab; `stand` holds its place in the split meanwhile.
        var zoomed: Tab?
        let stand = NSView()
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
    private(set) var drawer: DrawerSplit?
    /// ⌃⇧O: the terminal takes the panels' room too, as ⌃O did before the drawer.
    var isFull: Bool { drawer?.bottomOnly ?? false }
    /// Where the drawer's height is kept, as dragged (the app's `terminalDrawerHeight`; tests' none).
    private let heightKey: String?
    var onCommand: ((String) -> Void)?
    var onHide: (() -> Void)?
    /// A command's key, as the keymap has it: the buttons' tooltips.
    var keyFor: ((String) -> String?)?
    /// «⋯»'s menu: View ▸ Terminal Pane's items.
    var moreMenu: (() -> NSMenu)?
    private let maximize = NSButton(title: "", target: nil, action: nil)
    private let rowSpace = NSView()   // with one shell and no tabs shown: the buttons at the row's right end still
    var onExit: (() -> Void)?          // last tab closed: panels come back
    var onChange: (() -> Void)?        // tabs / states changed (sidebar, saved session)
    var onDirectory: ((Tab) -> Void)?  // the current tab's shell told its folder (`cwd`)
    /// A link ⌘-clicked in a tab's text (not an OSC 8 one) and the click's keys: the app opens it (`openLink`).
    var onLink: ((Tab, TerminalLinkRequest, NSEvent.ModifierFlags) -> Void)?
    /// ⌘+ / ⌘−, every tab; kept in `terminalFontSize` (clamped to 9…36; 13 if unset).
    private(set) var fontSize: CGFloat = (UserDefaults.standard.object(forKey: "terminalFontSize") as? Double).map { min(max($0, 9), 36) } ?? 13
    private var hiddenAt = -TimeInterval.infinity   // uptime; ⌃O ⌃O

    var isShown: Bool { drawer?.showsBottom ?? false }
    private var group: Group? { groups.indices.contains(index) ? groups[index] : nil }
    /// The current tab's focused pane: what keys, ⌃↩, ⌘R and the like act on.
    var current: Tab? { group?.pane }
    var hasFocus: Bool { isShown && (container.window?.firstResponder as? NSView)?.isDescendant(of: container) == true }

    /// `heightKey`: the defaults key the drawer's height is kept in (the app's; tests' none).
    init(covering host: NSView, heightKey: String? = nil) {
        self.host = host
        self.heightKey = heightKey
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
        rowSpace.setContentHuggingPriority(.init(1), for: .horizontal)
        topRow.addArrangedSubview(rowSpace)
        for (symbol, label, id) in [(Symbol.more, "Terminal", "term.more"), (.splitRight, "Split Terminal Right", "term.split.right"),
                                    (.maximize, "Maximize Terminal", "view.terminalFull"), (.collapse, "Hide Terminal", "view.terminal")] {
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
        // A click in another pane focuses it (the click makes its view first responder itself).
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let self, let g = group, let i = paneIndex(under: e, in: g), i != g.focused else { return e }
            g.focused = i
            render()
            return e
        }
    }

    func paneIndex(under e: NSEvent, in g: Group) -> Int? {
        g.panes.firstIndex { t in
            e.window === t.view.window && !t.view.isHiddenOrHasHiddenAncestor && t.view.bounds.contains(t.view.convert(e.locationInWindow, from: nil))
        }
    }

    /// The panels and the terminal (hidden) into a `DrawerSplit`, in the panels' place.
    private func wrap() {
        guard drawer == nil, let sup = host.superview else { return }
        let frame = host.frame
        host.removeFromSuperview()
        host.translatesAutoresizingMaskIntoConstraints = true
        container.translatesAutoresizingMaskIntoConstraints = true
        let d = DrawerSplit(top: host, bottom: container, frame: frame)
        d.autoresizingMask = [.width, .height]
        if let heightKey, let h = UserDefaults.standard.object(forKey: heightKey) as? Double { d.height = h }
        d.onDragged = { [heightKey] h in if let heightKey { UserDefaults.standard.set(Double(h), forKey: heightKey) } }
        sup.addSubview(d)
        drawer = d
    }

    private func attach() { wrap() }

    /// ⌃⇧O: the terminal over the panels' room too, or back into its drawer.
    func setFull(_ on: Bool) {
        guard isShown, on != isFull, let drawer else { return }
        drawer.bottomOnly = on
        drawer.layoutSubtreeIfNeeded()   // the panes at their new size now, not at the next pass (none comes without a window)
        maximize.image = (on ? Symbol.restore : Symbol.maximize).image(on ? "Restore Terminal" : "Maximize Terminal")
        render()
    }

    @objc private func rowButton(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if id == "term.more" {   // under the button
            _ = moreMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
            return
        }
        id == "view.terminal" ? onHide?() : onCommand?(id)
    }

    // MARK: - Showing

    /// ⌃O on a local panel: shows a live local shell (the current one, any other, else a new one in `cwd`) —
    /// never an SSH tab, even a restored or disconnected one. Returns the view to focus.
    func show(cwd: String) -> NSView {
        let shells = tabs.filter { $0.kind == .shell && $0.isRunning }
        if let t = shells.first(where: { $0 === current }) ?? shells.first {
            reveal(t)
            if t.isAtPrompt, t.shellCwd != Self.real(cwd), let line = ShellContext.typedCd(cwd) { t.view.type(line) }
        } else {
            newShell(cwd: cwd)
        }
        return show()
    }

    /// Shows the workspace on the tab the caller picked: in its drawer, or over the panels while `isFull`.
    func show() -> NSView {
        attach()
        drawer?.showsBottom = true
        drawer?.layoutSubtreeIfNeeded()
        render()
        return current!.view
    }

    /// Hides the workspace; returns the current shell's folder (nil for SSH tabs). `e`: the event that hid it — only a
    /// pressed ⌃O arms ⌃O ⌃O, not a command that hides the terminal on its way.
    func hide(_ e: NSEvent? = nil) -> String? {
        let cwd = current.flatMap { $0.kind == .shell ? $0.shellCwd : nil }
        drawer?.showsBottom = false
        drawer?.bottomOnly = false
        drawer?.layoutSubtreeIfNeeded()
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
        t.view.type(line)
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
            t.view.type((t.shellCwd != Self.real(cwd) ? cd : "\u{15}") + line + "\r")
        } else {
            // Typed ahead: the pty holds it until the shell reads — the first prompt is unknowable (the child is the foreground
            // group from forkpty on, .zshrc still running). A .zshrc that flushes input loses it: a known limit.
            newShell(cwd: cwd)
            current!.view.type(line + "\r")
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
        if let z = groups[gi].zoomed, z !== t { unzoom(groups[gi]) }   // keys never go to a pane out of sight
        index = gi
        groups[gi].focused = groups[gi].panes.firstIndex { $0 === t }!
    }

    // MARK: - Split

    /// ⌘\\ / ⌘⇧\\ (VS Code's Split Terminal): a new pane after the current one — beside it or under it; a tab that has
    /// several already keeps its way. An SSH pane: another session on that server, over its shared connection (no new
    /// login), in the folder its shell told (OSC 7), else home; a local one: a shell in the same folder.
    func split(vertical: Bool) {
        guard isShown, let g = group, let t = current, g.panes.count < Self.maxPanes else { return NSSound.beep() }
        unzoom(g)
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
        unzoom(g)
        g.focused += d
        focus()
    }

    /// ⌃⌘ arrows: the current pane's divider moves that way by a twentieth of the tab — its right (lower) one, the last
    /// pane's left (upper) one. Never closer than `minPane` to another divider.
    func resizePane(by d: Int, vertical: Bool) {
        guard isShown, let g = group, g.panes.count > 1, g.vertical == vertical else { return NSSound.beep() }
        if g.zoomed != nil {
            unzoom(g)
            focus()
        }
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
        unzoom(g)
        unzoom(other)
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
        unzoom(g)
        g.panes.remove(at: g.focused)
        g.focused = max(g.focused - 1, 0)
        arrange(g)
        let n = Group([t])
        groups.insert(n, at: index + 1)
        index += 1
        install(n)
        focus()
    }

    /// ⇧⌘↩ (iTerm2's, tmux's zoom): the current pane over its whole tab; again — back as it was. The split stays as it is
    /// meanwhile — a stand-in of the pane's size holds its place —, so the other panes keep their sizes: no reflow, no
    /// SIGWINCH for their programs. The zoomed pane grows (its marks go if its width changes, as with any width). What
    /// changes the panes (a split, ⌥⌘ / ⌃⌘ arrows, Join, a pane closed, going to another pane) puts it back first. The
    /// pane moves straight from one superview to the other, never out of the window (its program isn't told it lost focus).
    func zoom() {
        guard isShown, let g = group, g.zoomed != nil || g.panes.count > 1 else { return beep() }
        if g.zoomed != nil { unzoom(g) } else {
            let t = g.pane, i = g.split.arrangedSubviews.firstIndex(of: t.box)!
            g.stand.frame = t.box.frame
            pin(t.box)
            g.split.insertArrangedSubview(g.stand, at: i)
            g.zoomed = t
        }
        focus()
    }

    /// The zoomed pane back into its place in the split, shown (its tab may be behind another).
    private func unzoom(_ g: Group) {
        guard let t = g.zoomed, let i = g.split.arrangedSubviews.firstIndex(of: g.stand) else { return }
        g.zoomed = nil
        t.box.isHidden = false
        t.box.translatesAutoresizingMaskIntoConstraints = true
        t.box.frame = g.stand.frame
        g.split.insertArrangedSubview(t.box, at: i)
        g.stand.removeFromSuperview()
        render()
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

    func splitView(_ s: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { equalizing ? p : p + Self.minPane }
    func splitView(_ s: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { equalizing ? p : p - Self.minPane }

    private func makeView() -> DropTerminalView {
        let t = DropTerminalView(frame: host.bounds)
        t.processDelegate = self
        t.onLink = { [unowned self, unowned t] r, f in
            guard let onLink, let tab = tabs.first(where: { $0.view === t }) else { return TerminalGate.refused() }
            onLink(tab, r, f)
        }
        t.onOutput = { [weak self, unowned t] in self?.tabs.first { $0.view === t }.map { self?.tell($0, .output) } }
        t.onBell = { [weak self, unowned t] in
            guard let self else { return }
            guard let tab = tabs.first(where: { $0.view === t }), !shows(tab) else { return beep() }
            tell(tab, .bell)
        }
        t.font = Self.font(size: fontSize)
        t.changeScrollback(10_000)   // ponytail: fixed; a `terminalScrollback` key if someone asks
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
        tab.view.say("\u{1b}[?2004l")   // a dropped session's bracketed paste isn't the new one's (`takesText`)
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
                    tab.view.say("\(t.host) stays locked\r\n")
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
        tab.view.say("Logging in to \(t.host)…\r\n")
        Task {
            let r = await Blocking.run { Result { try SFTP.startMaster(t, env: SSHAskpass.env) } }
            if case .failure(let e) = r { tab.view.say(e.localizedDescription.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n") }
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

    /// Starts the tab's process. SwiftTerm reaps it and tells `processTerminated` (also when it reads the pty's end
    /// first), or `processFailedToStart`. It ignores a start until it has told the last process's end — so a tab starts
    /// again only after `exitStatus` is set (`reconnect`).
    func launch(_ tab: Tab, _ executable: String, _ args: [String], execName: String? = nil, cwd: String?) {
        assert(tab.view.process.map { !$0.running && !$0.windingDown } ?? true, "started while its last process is there")
        tab.started = (executable as NSString).lastPathComponent
        TunnelListener.forking {   // a tunnel's socket half made now would go with the shell, its port held while it runs
            tab.view.startProcess(executable: executable, args: args, environment: Self.environment, execName: execName, currentDirectory: cwd)
        }
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

    /// × on a tab of several panes: one question for all that would end, then each goes as `close` does. False: not
    /// closed now — asked (the answer closes it), or nothing to close.
    @discardableResult
    func close(group g: Group) -> Bool {
        guard g.panes.count > 1 else { return close(g.panes[0].id) }
        let busy = g.panes.compactMap(\.busyWith)
        let end: @MainActor () -> Void = { [unowned self] in
            for t in g.panes {
                if hangUp(t) { closing.append(t) }
                remove(t)
            }
        }
        guard busy.isEmpty else {
            ask(Self.closeQuestion(g.panes, busy: busy), then: end)
            return false
        }
        end()
        return true
    }

    /// "Close 3 sessions?": PROD / ROOT as one pane's question has it (↩ is Cancel there); two panes on one server, one line.
    static func closeQuestion(_ panes: [Tab], busy: [String]) -> Confirm {
        var c = Confirm("Close \(panes.count) sessions?", action: "Close")
        let place = panes.first { tint($0) != nil } ?? panes[0]
        (c.chips, c.place) = (chips(place), place.target.map(SavedServer.name(for:)) ?? "")
        let what = busy.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        (c.items, c.note) = (what.map { Confirm.Item(name: $0) }, "Anything running in them ends.")
        return c
    }

    /// ⌘W / × on a pane (or a tab of one): a finished session closes at once; a live one asks first (a sheet on the
    /// window: false then, the answer closes it). Then SIGHUP, and SIGKILL to the whole process group if it's still
    /// there after 2 s.
    @discardableResult
    func close(_ id: UUID? = nil, confirm: Bool = true) -> Bool {
        guard let tab = id.map({ i in tabs.first { $0.id == i } }) ?? current else { return false }
        let end: @MainActor () -> Void = { [unowned self] in
            if hangUp(tab) { closing.append(tab) }
            remove(tab)
        }
        if confirm, let what = tab.busyWith {
            var c = Confirm(tab.host != nil ? "Close the SSH session to \(SavedServer.name(for: tab.target!))?" : "Close the shell?", action: "Close")
            (c.chips, c.place) = (Self.chips(tab), tab.target.map(SavedServer.name(for:)) ?? "")
            (c.items, c.note) = ([Confirm.Item(name: what)], "Anything running in it ends.")
            ask(c, then: end)
            return false
        }
        end()
        return true
    }

    /// The question before tabs close: a sheet on the window; `then` on Close (once, whatever happened meanwhile).
    private func ask(_ c: Confirm, then: @escaping @MainActor () -> Void) {
        Task {
            let r = if let answer = AppDelegate.answering { answer(c.title, c.buttons, nil) }
                else if let w = host.window { await AppDelegate.sheet(c.alert(), on: w) } else { AppDelegate.modal(c.alert()) }
            if r == 0 { then() }
        }
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
                if tab.view.process?.shellPid == pid { killpg(pid, SIGKILL) }   // forkpty made it a session (group) leader
                self?.closing.removeAll { $0 === tab && !tab.isRunning }
            }
        }
        return true
    }

    /// The pane goes; the focus to the one taking its place (the one before it, for the last). Its tab goes with its last pane.
    private func remove(_ tab: Tab) {
        guard let gi = groups.firstIndex(where: { $0.panes.contains { $0 === tab } }) else { return }
        let g = groups[gi]
        unzoom(g)
        let pi = g.panes.firstIndex { $0 === tab }!
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
            drawer?.showsBottom = false
            drawer?.bottomOnly = false
            drawer?.layoutSubtreeIfNeeded()
            onChange?()
            onExit?()
        } else {
            focus()
        }
    }

    /// Reconnects the current SSH tab (or the one given) once its `ssh`'s end was told — not while it logs in or runs.
    func reconnect(_ id: UUID? = nil) {
        guard let tab = id.map({ i in tabs.first { $0.id == i } }) ?? current, tab.host != nil, tab.exitStatus != nil else { return NSSound.beep() }
        tab.view.say("\r\n")
        start(tab, cwd: nil)
        render()
    }

    /// Previous / Next Mark (⌘↑ / ⌘↓ in the terminal): a beep where there's none.
    func goToMark(by d: Int) { if !(isShown && current?.view.goToMark(by: d) == true) { NSSound.beep() } }

    /// Copy Output of Last Command (⇧⌘A in the terminal): nothing printed — a beep, the clipboard as it was.
    func copyOutput() {
        guard isShown, let v = current?.view, let text = v.output() else { return NSSound.beep() }
        v.pasteboard.clearContents()
        v.pasteboard.setString(text, forType: .string)
    }

    /// ⌘K clears the tab, as in Terminal (not while a full-screen program — vim, less, mc — has it: theirs would shift). ↩ / ⎋ in a disconnected SSH tab reconnect / close it (its PTY is gone, so the
    /// keys would go nowhere). Any other key without ⌘ is on its way to the program: the view's marks see it (`typed`).
    func handleKey(_ e: NSEvent) -> Bool {
        guard isShown, let t = current else { return false }
        if Shortcut(event: e) == Shortcut("cmd+k") {
            if t.view.terminalInputStateSnapshot()?.isAlternateBuffer == true { return true }
            // The scrollback and every line above the cursor's go; the cursor's line (the prompt) moves to the top.
            let c = t.view.terminalStateSnapshot().cursor
            t.view.say("\u{1b}[3J" + (c.row > 0 ? "\u{1b}[\(c.row)S" : "") + "\u{1b}[1;\(c.col + 1)H")
            t.view.dropMarks()
            return true
        }
        if t.host != nil, !t.isRunning, !t.view.findBarHasKeys,   // ↩ and ⎋ in the find bar are the bar's
           e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, [36, 76, 53].contains(e.keyCode) {
            if e.keyCode == 53 { close(t.id) } else { reconnect() }
            return true
        }
        if !e.modifierFlags.contains(.command) { t.view.typed(e) }
        return false
    }

    private func render() {
        for t in tabs {   // what shows has no news; what doesn't is watched for its first output
            if shows(t) { t.news = nil }
            t.view.watch(!shows(t) && t.news == nil)
        }
        tabBar.isHidden = groups.count < 2 && group?.panes.count == 1 && current?.kind == .shell
        rowSpace.isHidden = !tabBar.isHidden
        for b in topRow.arrangedSubviews.compactMap({ $0 as? NSButton }) {   // the row's buttons say their keys
            guard let id = b.identifier?.rawValue else { continue }
            let what = id == "view.terminal" ? "Hide Terminal" : id == "view.terminalFull" ? (isFull ? "Restore Terminal" : "Maximize Terminal")
                : id == "term.more" ? "Terminal: Open in Editor, Marks, Copy Output, Zoom" : "Split Terminal Right"
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
            g.split.isHidden = i != index || g.zoomed != nil
            g.zoomed?.box.isHidden = i != index
            for (j, t) in g.panes.enumerated() { header(t, index: j, focused: j == g.focused, shown: g.panes.count > 1 && g.zoomed == nil) }
        }
        if isShown, let g = group, g.needsEqualSizes { equalize(g) }
        onChange?()
    }

    /// Its tab is the current one and it isn't under another pane's zoom: what happens in it shows as it happens.
    func shows(_ t: Tab) -> Bool { group.map { g in g.panes.contains { $0 === t } && (g.zoomed == nil || g.zoomed === t) } ?? false }

    /// Output or a bell in a pane that isn't shown: its tab says so (`news`) until it shows.
    private func tell(_ t: Tab, _ n: Tab.News) {
        guard tabs.contains(where: { $0 === t }), !shows(t), t.news != .bell, t.news != n else { return }
        t.news = n
        render()
    }
    /// A bell in a shown pane: the system's sound. Tests: their own.
    var beep: @MainActor () -> Void = { NSSound.beep() }

    /// What happened while it wasn't shown (output: an ellipsis, not the state's dot; a bell), an SSH pane's state (on while ssh runs, off once it
    /// ended) and its server's chips — root for a root login.
    private static func lead(_ t: Tab) -> NSAttributedString? {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let news: NSAttributedString? = switch t.news {
        case .output: Symbol.news.text(Palette.accent, font: font, label: "new output")
        case .bell: Symbol.bell.text(Palette.warn, font: font, label: "rang")
        case nil: nil
        }
        guard t.host != nil else { return news }
        let s = NSMutableAttributedString(attributedString: news.map { n in let m = NSMutableAttributedString(attributedString: n); m.append(NSAttributedString(string: " ")); return m } ?? NSAttributedString())
        s.append(t.isRunning ? StateMark.on.text("connected", font: font) : StateMark.off.text("disconnected", font: font))
        if let c = Chip.text(chips(t)) { s.append(NSAttributedString(string: " ")); s.append(c) }
        return s
    }
    static func chips(_ t: Tab) -> [Chip] { t.target.map { Chip.of($0, root: $0.host.hasPrefix("root@")) } ?? [] }
    private static func tip(_ t: Tab) -> String {
        (t.host.map { h in t.isRunning ? "ssh \(h)" : "ssh \(h) — disconnected" } ?? "Shell") + (t.news == .bell ? " — rang" : t.news == .output ? " — new output" : "")
    }
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
        let why = status == -1 ? "Not connected" : status == Self.bySignal ? "ssh ended by a signal" : SSHCommand.describe(status: status)
        tab.view.say("\r\n\u{1b}[2m[\(h): \(why)] ↩ Reconnect   ⎋ Close\u{1b}[0m\r\n")
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
                && t.shellCwd == Self.real(dir)
        else { return }
        t.cwd = dir
        render()   // a local tab is named after its folder; a pane's header shows it
        if t === current, isShown { onDirectory?(t) }
    }

    /// The folder as the kernel names it (a shell's `shellCwd`): /tmp is /private/tmp, a symlinked folder its target.
    nonisolated static func real(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    /// Where the active panel goes as the terminal hides: the shell's folder, unless it's the panel's own written
    /// another way — the panel would lose its cursor and its path as typed for nothing.
    nonisolated static func follow(_ cwd: String?, from path: String) -> String? {
        guard let cwd, cwd != real(path) else { return nil }
        return cwd
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

    /// An exit status SwiftTerm doesn't tell: the process was killed (its exit code is nil then).
    static let bySignal: Int32 = -2

    /// The process is reaped and its last output shown; SwiftTerm takes a new start from now on (Reconnect, as soon as
    /// `exitStatus` says so).
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let tab = (tabs + closing).first(where: { $0.view === source }) else { return }
        finished(tab, status: exitCode.map { $0 << 8 } ?? Self.bySignal)   // the tab's raw wait status
    }

    /// fork or the pty's writer failed (SwiftTerm has said so in the tab): an SSH tab offers Reconnect; a shell's tab
    /// stays, saying why, and closes without asking.
    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        guard let tab = tabs.first(where: { $0.view === source }) else { return }
        guard tab.host != nil else { tab.exitStatus = -1; return }
        finished(tab, status: -1)
    }

    /// The tab's process ended. `exit` in a shell closes its tab (the next ⌃O starts a fresh shell); an SSH tab stays,
    /// disconnected.
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
    /// Where several lines pasted by a right-click ask first (`pasteQuestion`): a production server, a root@ login — its
    /// chips and name; nil: nowhere. A shell there that runs each line as it comes, without bracketed paste, would run
    /// them all.
    var pasteRisk: () -> (chips: [Chip], place: String)? = { nil }
    /// The question (tests answer it): the text — the lines that run, as they run —, where, the window; true pastes.
    /// ↩ is Cancel.
    static var pasteQuestion: @MainActor (String, (chips: [Chip], place: String), NSWindow?) async -> Bool = { text, risk, window in
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).count
        var c = Confirm("Paste \(lines) lines into \(risk.place)?", action: "Paste")
        (c.chips, c.place, c.command, c.returnCancels) = (risk.chips, risk.place, text, true)
        c.note = "Its shell runs each line as it arrives."
        guard let window else { return AppDelegate.modal(c.alert()) == 0 }
        return await AppDelegate.sheet(c.alert(), on: window) == 0
    }
    private var upMonitor: Any?   // a selection being dragged: copied once the button is up
    var pasteboard = NSPasteboard.general   // tests: their own

    // PuTTY's mouse. A selection goes to the clipboard as it's made (`terminalCopyOnSelect`); a right-click pastes
    // (`terminalRightClickPaste`) — in a program that reads the mouse itself (mc, htop, vim's mouse=a), ⇧-right-click.
    static func on(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// The mouse's left button is down now (a drag under way). Tests: not the real mouse, which someone may be pressing.
    static var leftButtonDown = { NSEvent.pressedMouseButtons & 1 != 0 }

    // A find's match is a selection too (SwiftTerm's find bar, ⌘F, ⌘G): it never goes to the clipboard. Decided as the
    // selection changes (`selectionChanged`), not after a hop to the main queue: these flags are gone by then.
    private var finding = false, saying = false
    /// Kermo's own words in the tab (a session's end, "Logging in…", ⌘K's clear): a program's output to the selection —
    /// one they move up (the scrollback full) isn't copied again: it may be a find's match.
    func say(_ text: String) { quietly { feed(text: text) } }
    override func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {   // SwiftTerm says why in the tab
        quietly { super.processFailedToStart(source, error: error) }
    }
    private func quietly(_ body: () -> Void) {
        let was = saying
        saying = true
        defer { saying = was }   // one inside another (a failed start's `ended`)
        body()
    }
    override func performTextFinderAction(_ sender: Any?) {
        finding = true
        defer { finding = false }
        super.performTextFinderAction(sender)
    }
    override func performFindPanelAction(_ sender: Any?) {
        finding = true
        defer { finding = false }
        super.performFindPanelAction(sender)
    }

    /// SwiftTerm's find bar while it's up. Its type is SwiftTerm's own; it's the view's one `NSVisualEffectView`.
    var findBar: NSView? { subviews.first { $0 is NSVisualEffectView && !$0.isHidden } }
    /// The find bar's field has the keys: ↩, ⇧↩ and ⎋ are its, and each letter finds.
    var findBarHasKeys: Bool { findBar.map { (window?.firstResponder as? NSView)?.isDescendant(of: $0) == true } ?? false }
    private func inFindBar(_ e: NSEvent) -> Bool { findBar?.frame.contains(convert(e.locationInWindow, from: nil)) == true }

    /// The find bar drives the selection: typed into, or clicked (its arrows, its switches). ponytail: a VoiceOver press
    /// on its arrows while the text has the keys isn't a click: that match is copied.
    private var findBarDrives: Bool {
        guard findBar != nil else { return false }
        if findBarHasKeys { return true }
        guard let e = NSApp?.currentEvent, e.window === window, e.type == .leftMouseDown || e.type == .leftMouseUp else { return false }
        return inFindBar(e)
    }

    /// Called with the terminal's lock held: the copy (`getSelection` takes the lock) waits for the main queue. Off the
    /// main thread it's the program's output dropping or moving the selection: nothing to copy.
    nonisolated override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            guard Self.on("terminalCopyOnSelect"), !finding, !saying, !findBarDrives else { return }
            guard Self.leftButtonDown() else {   // ⌘A, or made at once
                return DispatchQueue.main.async { MainActor.assumeIsolated { self.copySelection() } }
            }
            guard upMonitor == nil else { return }   // dragging: once, when it ends — not on every move
            upMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] e in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.dragEnded() } }   // after the view's own mouseUp
                return e
            }
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

    // MARK: Marks (task 21)

    /// A ↩ typed outside a full-screen program marks the line it was typed on (Terminal.app's rule; nothing goes to the
    /// shell, nothing is set up there): ⌘↑ / ⌘↓ go from mark to mark, Copy Output takes what a command printed. A row is
    /// SwiftTerm's absolute one, which holds as the scrollback is cut. What renumbers rows drops the marks — ⌘K, `clear`,
    /// RIS (fewer rows held), ⌃L (those under the cursor), a width change, a lower drawer cutting a full scrollback —:
    /// a mark is only a place to go, never someone else's line.
    struct Mark: Equatable {
        let row: Int
        /// The row as it stood at the look after the mark (the shell may redraw it on ↩: a transient prompt): checked as
        /// the mark is used — a `clear` and more output than there was between two looks leave the numbers as they were.
        var text: String?
    }
    private(set) var marks: [Mark] = []
    /// The last look's rows held (the scrollback and the screen) and columns: fewer rows, other columns — renumbered.
    private var seen: (held: Int, cols: Int)?
    /// Its shell has turned bracketed paste on (zsh, bash 5.1+, fish do it at the prompt only, off while a command
    /// runs): from then on a ↩ without it isn't a command's — one pressed into `make`'s output, `read`, a password.
    private var promptSaysSo = false
    /// The mark ⌘↑ / ⌘↓ went to, and the top row in view then. Scrolled since, or typed: from the view or the last again.
    private var at: (row: Int, top: Int)?

    /// ⌘K: the scrollback is gone (and with it the anchor's row).
    func dropMarks() { (marks, at, anchor) = ([], nil, nil) }

    /// A new size may renumber the rows (a width's reflow, a lower drawer cutting a full scrollback): the marks are
    /// looked at as the rows stand just before it — out of a live resize SwiftTerm resizes in here.
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size, !marks.isEmpty { _ = look() }
        super.setFrameSize(newSize)
    }

    /// A key without ⌘ on its way to the program (the app's key monitor has it before the view; SwiftTerm hands keys to
    /// the process itself, past its delegate): ⌘↑ goes from the last command again; a ↩ that runs — not one the find bar
    /// or an input method takes, nor ⌃↩ (the app's) — marks its line while the cursor is still on it.
    func typed(_ e: NSEvent) {
        at = nil
        if e.keyCode == 36 || e.keyCode == 76, !e.modifierFlags.contains(.control), !hasMarkedText(), !findBarHasKeys { markReturn() }
    }

    /// Kermo's own text into the program (a typed `cd`, ⌘E ↩'s line, Execute in Terminal's): marked as a ↩ typed would be.
    func type(_ bytes: [UInt8]) {
        if Self.returns(bytes[...]) { markReturn() }
        send(bytes)
    }
    func type(_ text: String) { type(Array(text.utf8)) }

    /// A ↩ that runs: one outside a bracketed paste (a pasted line waits in the line editor for its ↩).
    nonisolated static func returns(_ data: ArraySlice<UInt8>) -> Bool {
        let end: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]   // ESC[201~: a paste goes in one piece
        return (data.ranges(of: end).last.map { data[$0.upperBound...] } ?? data).contains(0x0D)
    }

    /// The normal screen now (absolute rows: the first held, the cursor's, the live screen's top), its marks checked
    /// against it; nil before the view has a terminal. Not under the terminal's lock (it takes it).
    private func look() -> (top: Int, cursor: Int, live: Int, alt: Bool, bracketed: Bool)? {
        guard let s = terminalContentSnapshot(region: .rows(0..<0), buffer: .normal) else { return nil }
        let held = s.liveTopRow + s.dimensions.rows, top = s.capturedRange.lowerBound
        if let seen, held < seen.held || s.dimensions.cols != seen.cols { dropMarks() }
        seen = (held, s.dimensions.cols)
        marks.removeAll { $0.row < top || $0.row > s.cursorRow }
        for i in marks.indices where marks[i].text == nil { marks[i].text = rowText(marks[i].row) }
        if s.inputState.bracketedPasteMode { promptSaysSo = true }
        return (top, s.cursorRow, s.liveTopRow, s.inputState.isAlternateBuffer, s.inputState.bracketedPasteMode)
    }

    private func rowText(_ row: Int) -> String? { terminalContentSnapshot(region: .rows(row..<row + 1), buffer: .normal)?.rows.first?.text }

    /// The mark is still on its line; one that isn't goes.
    private func holds(_ m: Mark) -> Bool {
        guard let t = m.text, rowText(m.row) != t else { return true }
        marks.removeAll { $0 == m }
        return false
    }

    /// The nearest mark that holds before `row` (`d` −1) or after it (1).
    private func mark(from row: Int, _ d: Int) -> Mark? {
        while let m = d < 0 ? marks.last(where: { $0.row < row }) : marks.first(where: { $0.row > row }) {
            if holds(m) { return m }
        }
        return nil
    }

    /// ↩ on its way to the program: a mark on the first row of the cursor's line (a long command wraps), one per row —
    /// not in a full-screen program, nor where the shell says it isn't at its prompt (`promptSaysSo`).
    private func markReturn() {
        guard let now = look(), !now.alt, now.bracketed || !promptSaysSo,
              let s = terminalContentSnapshot(region: .rows(max(now.top, now.cursor - 50)..<now.cursor + 1), buffer: .normal),
              var i = s.rows.indices.last else { return }
        while i > 0, s.rows[i].isWrapped { i -= 1 }
        let row = s.rows[i].absoluteRow
        marks.removeAll { $0.row >= row }
        marks.append(Mark(row: row))
    }

    /// ⌘↑ (`d` −1) / ⌘↓ (1): the mark before or after the one gone to last — from the live screen ⌘↑ is the last
    /// command's; scrolled by hand, from the top row in view. That row goes to the top (as far as it scrolls) and a bar
    /// shows it a moment. A shell's OSC 133 prompts count where there's no mark (above the first: a width change dropped
    /// them). ⌘↓ after the last: the live screen. False: nowhere to go (a full-screen program has the tab).
    func goToMark(by d: Int) -> Bool {
        guard let now = look(), !now.alt else { return false }
        let view = now.top + terminalStateSnapshot().viewportRow
        let from = at.flatMap { $0.top == view ? $0.row : nil } ?? (view != now.live ? view : d < 0 ? now.cursor + 1 : nil)
        var row = from.flatMap { mark(from: $0, d)?.row }
        if from != nil, let p = (d < 0 ? previousSemanticPromptRow() : nextSemanticPromptRow()).map({ $0 + now.top }), p < marks.first?.row ?? .max,
           d < 0 ? row == nil : p < row ?? .max { row = p }
        guard let row else {
            guard d > 0, at != nil || view != now.live else { return false }
            scrollTo(row: now.live - now.top)
            at = nil
            return true
        }
        scrollTo(row: row - now.top)
        let top = now.top + terminalStateSnapshot().viewportRow
        at = (row, top)
        showMark(row - top)
        return true
    }

    private(set) weak var markBar: NSView?
    /// A bar left of the `n`th row in view for a moment: where ⌘↑ / ⌘↓ went, scrolled there or not.
    private func showMark(_ n: Int) {
        markBar?.removeFromSuperview()
        let h = caretFrame.height > 0 ? caretFrame.height : bounds.height / CGFloat(max(terminalStateSnapshot().dimensions.rows, 1))
        let bar = NSView(frame: NSRect(x: 0, y: bounds.height - CGFloat(n + 1) * h, width: 3, height: h))   // as SwiftTerm puts its caret: rows from the top, y up
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        bar.layer?.cornerRadius = 1.5
        addSubview(bar)
        markBar = bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; bar.animator().alphaValue = 0 },
                                                 completionHandler: { MainActor.assumeIsolated { bar.removeFromSuperview() } })
        }
    }

    /// What a command printed: the one ⌘↑ / ⌘↓ went to (while it's still in view), else the last that printed anything
    /// — its rows after the command's own up to the next mark, or to the cursor's (the prompt). Nil: nothing printed, or
    /// a full-screen program has the tab.
    func output() -> String? {
        guard let now = look(), !now.alt else { return nil }
        let view = now.top + terminalStateSnapshot().viewportRow
        if let at, at.top == view {
            guard let m = marks.first(where: { $0.row == at.row }), holds(m) else { return nil }
            return output(of: m, cursor: now.cursor)
        }
        var row = now.cursor + 1
        while let m = mark(from: row, -1) {
            if let o = output(of: m, cursor: now.cursor) { return o }
            row = m.row
        }
        return nil
    }

    private func output(of m: Mark, cursor: Int) -> String? {
        let end = mark(from: m.row, 1)?.row ?? cursor
        guard end > m.row, let s = terminalContentSnapshot(region: .rows(m.row..<end), buffer: .normal) else { return nil }
        let text = Self.text(s.rows.dropFirst().drop(while: \.isWrapped)).text   // not the command's own line
        return text.isEmpty ? nil : text
    }

    /// Open in Editor's text: the selection; else every row held — the scrollback and the screen, a full-screen
    /// program's screen only —, and the line of the row at the top of the view.
    func contents() -> (text: String, line: Int)? {
        if let s = getSelection(), !s.isEmpty { return (s, 0) }
        guard let s = terminalContentSnapshot(region: .all) else { return nil }
        return Self.text(s.rows, row: s.capturedRange.lowerBound + terminalStateSnapshot().viewportRow)
    }

    /// Rows as text: a wrapped row goes on with its line; a line without spaces at its end, no blank lines at the end.
    /// `line`: the line `row` is on.
    nonisolated static func text(_ rows: some Collection<TerminalContentRowSnapshot>, row: Int? = nil) -> (text: String, line: Int) {
        var lines: [String] = [], line = 0
        for r in rows {
            if r.isWrapped, !lines.isEmpty { lines[lines.count - 1] += r.text } else { lines.append(r.text) }
            if r.absoluteRow == row { line = lines.count - 1 }
        }
        lines = lines.map { String($0[..<($0.lastIndex { $0 != " " }.map($0.index(after:)) ?? $0.startIndex)]) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return (lines.joined(separator: "\n"), min(line, max(lines.count - 1, 0)))
    }

    /// A plain right-click is the program's when it reads the mouse itself (SwiftTerm reports it); ⇧ pastes there anyway.
    nonisolated static func rightClickPastes(shift: Bool, programReadsMouse: Bool) -> Bool { shift || !programReadsMouse }

    /// Several lines into a shell that runs each as it comes (no bracketed paste), where that's risky: ask.
    nonisolated static func pasteAsks(_ text: String, bracketed: Bool, risky: Bool) -> Bool { risky && !bracketed && text.contains { $0 == "\n" || $0 == "\r" } }

    override func rightMouseDown(with event: NSEvent) {
        guard Self.on("terminalRightClickPaste"),
              Self.rightClickPastes(shift: event.modifierFlags.contains(.shift), programReadsMouse: allowMouseReporting && currentMouseMode != .off)
        else { return super.rightMouseDown(with: event) }
        window?.makeFirstResponder(self)
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return NSSound.beep() }
        let risk = pasteRisk(), ask = Self.pasteAsks(text, bracketed: terminalInputStateSnapshot()?.bracketedPasteMode ?? false, risky: risk != nil)
        Task {
            if ask, let risk, await !Self.pasteQuestion(text, risk, window) { return }
            paste(self)   // as ⌘V: bracketed when the shell asked for it
        }
    }

    // MARK: Anchor (task 21 PR 4)

    /// Where the last plain click was — an absolute row (as a mark's), the click's x, the row's text then: a ⇧-click
    /// with nothing selected selects from there, scrolled away meanwhile or not (Terminal.app's). Gone where the marks go
    /// (rows renumbered, ⌘K), and once its row reads otherwise: never someone else's line.
    private(set) var anchor: (row: Int, x: CGFloat, text: String?)?

    override func mouseDown(with event: NSEvent) {
        commandPress = event.modifierFlags.contains(.command)
        let keys = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let h = caretFrame.height   // a row's: SwiftTerm sizes the caret to a cell (wider on a wide character, never taller)
        guard event.clickCount == 1, keys.isEmpty || keys == .shift, h > 0,
              !(allowMouseReporting && currentMouseMode != .off), let now = look(), !now.alt
        else { return terminals { super.mouseDown(with: event) } }
        let top = now.top + terminalStateSnapshot().viewportRow   // the row at the view's top
        let p = convert(event.locationInWindow, from: nil), row = top + max(Int((bounds.height - p.y) / h), 0)
        guard keys == .shift else {
            anchor = (row, p.x, rowText(row))
            return super.mouseDown(with: event)
        }
        guard !selectionActive, let a = anchor, a.row >= now.top, rowText(a.row) == a.text else { return super.mouseDown(with: event) }
        // A press at the anchor — off the view if it's scrolled away: SwiftTerm takes that point for the row above or
        // below — and a release here: one selection, copied once, as it ends.
        let n = CGFloat(a.row - top)
        let at = NSPoint(x: a.x, y: bounds.height - (n + (n < 0 ? -0.5 : 0.5)) * h)   // its Int() rounds towards 0
        func mouse(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: convert(p, to: nil), modifierFlags: [], timestamp: event.timestamp, windowNumber: event.windowNumber,
                               context: nil, eventNumber: event.eventNumber, clickCount: 1, pressure: 0)!
        }
        quietly {
            super.mouseDown(with: mouse(.leftMouseDown, at))
            super.mouseUp(with: mouse(.leftMouseUp, p))
        }
        if Self.on("terminalCopyOnSelect") { copySelection() }
    }

    /// A link ⌘-clicked in the text (never an OSC 8 one) and the click's keys: the tab's to open; nil: none opens.
    var onLink: ((TerminalLinkRequest, NSEvent.ModifierFlags) -> Void)?
    /// The last click's keys as it ended (SwiftTerm's request doesn't carry them).
    private(set) var clickFlags: NSEvent.ModifierFlags = []
    override func mouseUp(with event: NSEvent) {
        clickFlags = event.modifierFlags
        defer { commandPress = false }
        guard !commandPress, event.modifierFlags.contains(.command) else { return terminals { super.mouseUp(with: event) } }
        // ⌘ came after the press: the click is as it began — a program's gets its release, no link opens.
        super.mouseUp(with: NSEvent.mouseEvent(with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags.subtracting(.command),
                                               timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                               eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) ?? event)
    }
    override func mouseDragged(with event: NSEvent) { terminals { super.mouseDragged(with: event) } }

    /// The press held ⌘: the click is the terminal's (a link), never a program's that reads the mouse — SwiftTerm would
    /// give it the press and keep the release for the link. Decided at the press, for the whole click.
    private var commandPress = false
    private func terminals(_ body: () -> Void) {
        guard commandPress, allowMouseReporting else { return body() }
        allowMouseReporting = false
        defer { allowMouseReporting = true }
        body()
    }

    // MARK: Activity (task 21 PR 5)

    /// Its program's first output while its tab isn't shown (`watch`), told once on the main queue; a bell (BEL). Kermo's
    /// own words (`say`) aren't its program's: they never reach the process's output handler.
    var onOutput: (() -> Void)?
    var onBell: (() -> Void)?
    /// Armed while the tab doesn't show: the parse thread's one check per batch, and one hop to the main queue per arming.
    /// After a size change its shell redraws its prompt (SIGWINCH) — a drawer dragged, ⌘+: not news. ponytail: half a
    /// second; a server's redraw later than that over a slow link still marks the tab.
    private let armed = OSAllocatedUnfairLock(initialState: (on: false, quietUntil: UInt64(0)))
    func watch(_ on: Bool) { armed.withLock { $0.on = on } }
    func resized() { armed.withLock { $0.quietUntil = DispatchTime.now().uptimeNanoseconds + 500_000_000 } }
    private func watchOutput() {
        nonisolated(unsafe) weak var me = self   // read on the main queue only
        setProcessOutputHandler { [armed] in
            guard armed.withLock({ s in
                guard s.on, DispatchTime.now().uptimeNanoseconds >= s.quietUntil else { return false }
                s.on = false
                return true
            }) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { me?.onOutput?() } }
        }
    }

    private lazy var gate = TerminalGate(self)   // `terminalDelegate` is weak: the view keeps it

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        terminalDelegate = gate
        watchOutput()
        // A path or an address in the text is a link while ⌘ is down (underlined under the mouse); without ⌘ nothing is
        // looked up as the mouse moves. An OSC 8 link's hidden target: the gate refuses it. A click on an OSC 133 prompt
        // doesn't move the cursor.
        linkReporting = .none
        linkHighlightMode = .hoverWithModifier
        semanticPromptClickBehavior = .disabled
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

/// The view's `terminalDelegate`, in front of SwiftTerm's own (the view itself, `LocalProcessTerminalView`). Text from
/// a program — a server's too — isn't trusted: it never reads the clipboard (OSC 52 `?`, kitty's OSC 5522), writes it
/// only from the tab in front, and a link's hidden target (OSC 8: "https://docs…" over a `file:` app) never opens. The
/// rest goes on to the view, each call by name: a call left out would get the protocol's default, not the view's.
@MainActor
final class TerminalGate: TerminalViewDelegate {
    private unowned let view: DropTerminalView
    init(_ view: DropTerminalView) { self.view = view }
    /// A link refused (tests: count them).
    static var refused: @MainActor () -> Void = { NSSound.beep() }

    func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        guard !request.isExplicit, let open = view.onLink else { return Self.refused() }
        open(request, view.clickFlags)
    }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { Self.refused() }

    func clipboardRead(source: TerminalView) -> Data? { nil }
    /// OSC 52 (Claude Code's, tmux's, vim's copy): the program's text into the clipboard, a server's too — from the tab
    /// in front only (not a hidden one, nor one closed and winding down).
    func clipboardCopy(source: TerminalView, content: Data) {
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor, let text = String(data: content, encoding: .utf8), !text.isEmpty else { return }
        view.pasteboard.clearContents()
        view.pasteboard.setString(text, forType: .string)
    }
    // kitty's clipboard: none (and so DEC mode 5522 isn't offered). nil and .unsupported would mean SwiftTerm's own.
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { [] }
    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { .denied }
    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .denied }
    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        view.resized()
        view.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) { view.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { view.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { view.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) { view.scrolled(source: source, position: position) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { view.rangeChanged(source: source, startY: startY, endY: endY) }
    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) { view.programStatusChanged(source: source, records: records) }
    func bell(source: TerminalView) {
        if let b = view.onBell { b() } else { view.bell(source: source) }
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { view.iTermContent(source: source, content: content) }
}

/// The panels over the terminal's drawer, a line between them to drag (Р6): either can be alone — the panels while the
/// terminal is hidden, the terminal over all the room (⌃⇧O). Laid out by hand: a split view kept drawing a hidden
/// pane's divider, and its autosave kept the collapsed size.
@MainActor
final class DrawerSplit: NSView {
    let top: NSView, bottom: NSView
    private let handle = DrawerHandle()
    /// The drawer's height, as last dragged; nil: 40 % of the room.
    var height: CGFloat? { didSet { needsLayout = true } }
    var showsBottom = false { didSet { if showsBottom != oldValue { needsLayout = true } } }
    var bottomOnly = false { didSet { if bottomOnly != oldValue { needsLayout = true } } }
    /// A drag ended at this height.
    var onDragged: ((CGFloat) -> Void)?
    static let minBottom: CGFloat = 80, minTop: CGFloat = 120

    init(top: NSView, bottom: NSView, frame: NSRect) {
        self.top = top
        self.bottom = bottom
        super.init(frame: frame)
        for v in [top, bottom, handle] { addSubview(v) }   // the handle over both: it reaches 2 pt into each
        handle.onDrag = { [unowned self] y, done in
            height = y   // AppKit's y goes up from the bottom: the drawer's height
            layoutSubtreeIfNeeded()
            if done, let h = height { onDragged?(shownHeight(h)) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The drawer's height as laid out: between its least and the panels' least.
    func shownHeight(_ h: CGFloat? = nil) -> CGFloat {
        min(max(h ?? height ?? bounds.height * 0.4, Self.minBottom), max(bounds.height - Self.minTop - 1, Self.minBottom))
    }

    override func layout() {
        super.layout()
        let b = bounds
        top.isHidden = showsBottom && bottomOnly
        bottom.isHidden = !showsBottom
        handle.isHidden = !showsBottom || bottomOnly
        if !showsBottom { top.frame = b }
        else if bottomOnly { bottom.frame = b }
        else {
            let h = shownHeight()
            bottom.frame = NSRect(x: 0, y: 0, width: b.width, height: h)
            handle.frame = NSRect(x: 0, y: h - 2, width: b.width, height: 5)   // easy to grab; draws 1 pt
            top.frame = NSRect(x: 0, y: h + 1, width: b.width, height: b.height - h - 1)
        }
    }
}

/// The line over the drawer: a 1 pt separator in a 5 pt strip that takes the drag, with the up-down cursor.
@MainActor
final class DrawerHandle: NSView {
    var onDrag: ((_ y: CGFloat, _ done: Bool) -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 2, width: bounds.width, height: 1).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) { drag(event, done: false) }
    override func mouseUp(with event: NSEvent) { drag(event, done: true) }
    private func drag(_ e: NSEvent, done: Bool) {
        guard let s = superview else { return }
        onDrag?(s.convert(e.locationInWindow, from: nil).y, done)
    }
}

