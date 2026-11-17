import AppKit
import DFMCore

/// Outside agents — Claude Code started in one of Kermo's terminal tabs — calling Kermo's tools over MCP (`MCP`).
/// There only while Settings ▸ AI allows them: otherwise no socket, no menu item, no variable in a tab, no session.
///
/// - Who gets in: a process of this user that a terminal tab's shell started (its parents, a few up). Not one
///   started elsewhere, not one under tmux — its server isn't the tab's child.
/// - A connection is a chat: its own `AISession`, so its own scope and journal, gone when it hangs up. Every call
///   is `AISession.call` — there is no other way to a tool from here.
/// - Its questions are sheets on the main window, Kermo brought to the front; the agent waits. An agent that hangs
///   up takes its question away.
/// - Window ▸ AI Scope, and the chip in the first panel's status line, say what each agent may do, take it back,
///   show its journal and hang up on it.
@MainActor
final class AIAgents {
    static let key = "aiMCP"
    /// This app's socket while agents are allowed: what a new terminal tab is told (`$KERMO_MCP_SOCKET`).
    private(set) static var socket: String?

    @MainActor
    final class Agent {
        let session: AISession
        /// The terminal tab it was started in, as its title was then.
        let tab: String
        fileprivate(set) var connection: MCP.Connection?
        fileprivate var fd: Int32 = -1
        fileprivate init(_ session: AISession, tab: String) { (self.session, self.tab) = (session, tab) }
        var name: String { connection?.client ?? "Agent" }
    }

    unowned let app: AppDelegate
    private(set) var all: [Agent] = []
    private var listener: MCP.Listener?
    private let item = NSMenuItem(title: "AI Scope", action: nil, keyEquivalent: "")

    /// The switch as it is now (at launch, and when Settings ▸ AI changes it). Off: every agent is hung up on, and
    /// what each was allowed goes with it.
    static func apply(_ app: AppDelegate) {
        if !app.defaults.bool(forKey: key) {
            app.agents?.stop()
            app.agents = nil
        } else if app.agents == nil {
            app.agents = AIAgents(app, at: SFTP.controlDir + "/mcp-\(getpid()).sock")
        }
    }

    /// `admits`: who may connect, and from which tab (tests: their own word for it).
    init?(_ app: AppDelegate, at path: String, admits: (@MainActor (pid_t) -> String?)? = nil) {
        self.app = app
        listener = MCP.Listener(path: path) { [weak self] pid in
            guard admits != nil || Askpass.descends(pid, from: getpid()) else { return nil }
            return DispatchQueue.main.sync { MainActor.assumeIsolated { self?.admit(pid, admits) } }
        }
        guard listener != nil else { return nil }
        Self.socket = path
        item.submenu = LiveMenu(title: item.title) { [unowned self] in menuItems() }
        if let menu = NSApp.windowsMenu { menu.insertItem(item, at: min(menu.items.count, 4)) }   // after Main Window
    }

    func stop() {
        listener?.stop()   // hangs up on each: its thread takes it off the list
        listener = nil
        Self.socket = nil
        item.menu?.removeItem(item)
        all = []
        changed()
    }

    /// The tab whose shell started `pid`, by its title.
    private func tab(of pid: pid_t) -> String? {
        let shells = Dictionary((app.terminal?.tabs ?? []).compactMap { t in t.view.process.map { ($0.shellPid, t.label) } }) { a, _ in a }
        var p = pid
        for _ in 0..<8 {
            if let tab = shells[p] { return tab }
            guard p > 1, let parent = Askpass.parent(of: p) else { return nil }
            p = parent
        }
        return nil
    }

    /// A new connection's server, or nil: not from a tab. The session is made here; the agent joins the list once
    /// it is served, and leaves it when it hangs up.
    private func admit(_ pid: pid_t, _ admits: (@MainActor (pid_t) -> String?)?) -> (@Sendable (Int32) -> Void)? {
        guard listener != nil, let tab = admits.map({ $0(pid) }) ?? self.tab(of: pid) else { return nil }
        let session = AISession(app: app) { [unowned app] c, w in
            if AppDelegate.answering == nil, !NSApp.isActive { NSApp.activate() }   // the user is in the agent's terminal, or in another app
            return await app.confirm(c, on: w)
        }
        let agent = Agent(session, tab: tab)
        return { [weak self] fd in
            let out = NSLock()   // a line whole, whoever writes it
            let c = MCP.Connection(version: Updates.current, write: { line in out.withLock { _ = MCP.write(fd, line) } }) { [weak self] name, args in
                let result = await session.call(name, args)
                await self?.changed()   // what it may do, and how much it did
                return result
            }
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    (agent.connection, agent.fd) = (c, fd)
                    self?.all.append(agent)
                    self?.changed()
                }
            }
            MCP.lines(fd) { c.receive($0) }   // a line past the limit ends it too
            c.close()   // what it asked for stops, a question on screen goes
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.all.removeAll { $0 === agent }
                    self?.changed()
                }
            }
        }
    }

    private func changed() { app.panels.first?.restatus() }

    // MARK: - What the user sees

    /// "Claude Code · web-01 Work, db-01 View" for the status line; nil: no agent.
    var chip: String? {
        guard !all.isEmpty else { return nil }
        return all.map { a in
            let scope = a.session.granted.map(\.short).joined(separator: ", ")
            return a.name + (scope.isEmpty ? "" : " · " + scope)
        }.joined(separator: "; ")
    }

    /// Window ▸ AI Scope, and the chip's click: each agent, what it may do — with Take Away — its journal, Disconnect.
    func menuItems() -> [NSMenuItem] {
        func off(_ title: String) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.isEnabled = false
            return i
        }
        guard !all.isEmpty else { return [off("No agent connected")] }
        var items: [NSMenuItem] = []
        for a in all {
            if !items.isEmpty { items.append(.separator()) }
            items.append(off("\(a.name) — tab “\(a.tab)”".bidiVisible))
            let granted = a.session.granted
            if granted.isEmpty { items.append(off("Nothing allowed yet: it asks first")) }
            for g in granted {
                let row = NSMenuItem(title: g.words.bidiVisible, action: nil, keyEquivalent: "")
                row.submenu = NSMenu()
                row.submenu?.addItem(MenuAction.item("Take Away") { [unowned self] in a.session.takeAway(g.place); changed() })
                items.append(row)
            }
            if granted.count > 1 { items.append(MenuAction.item("Take Away Everything") { [unowned self] in a.session.takeAway(); changed() }) }
            let calls = a.session.journal.count
            let journal = MenuAction.item("Show Journal… (\(calls) call\(calls == 1 ? "" : "s"))") {
                OutputWindow.show(a.session.journalText, errors: "", title: "\(a.name) — journal", status: 0, ok: true)
            }
            journal.isEnabled = calls > 0
            items += [journal, MenuAction.item("Disconnect") { shutdown(a.fd, SHUT_RDWR) }]
        }
        return items
    }

    /// The same menu under the status line's chip.
    func popUp(at view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menuItems().forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
    }
}
