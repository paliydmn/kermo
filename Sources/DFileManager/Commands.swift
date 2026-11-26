import AppKit
import DFMCore

/// Every way to support Kermo is on one README section: a new one needs no release.
private let supportPage = URL(string: "https://github.com/paliydmn/kermo#support-kermo")!

/// Every user action is a named command: bound to keys, shown in menus and the F-key bar.
/// One table here = one place to look up or rebind anything (keymap.json later reads the same ids).
struct Command {
    let id: String
    let title: String
    var keys: [Shortcut]
    let menu: String?                     // its menu, "File/As Administrator" in a submenu; nil = keyboard only
    var group = 0                         // a menu's items by group, a separator between groups (`AppDelegate.menuItems`)
    var short: String                     // key bar label; "" = title
    let aliases: String                   // extra words the search matches ("zip" → Compress), and its old title
    var hidden = false                    // run by a panel itself (↩ on a server's file) or a Settings button: not in ⇧⌘P or F1
    var on: (@MainActor (AppDelegate) -> Bool)? = nil   // a switch: its menu item's ✓
    let run: @MainActor (AppDelegate) -> Void

    /// Its menu in the menu bar: "File" for "File/As Administrator".
    var topMenu: String? { menu.map { String($0.prefix { $0 != "/" }) } }
}

private func cmd(_ id: String, _ title: String, _ keys: [String], menu: String? = nil, group: Int = 0, short: String = "", aliases: String = "",
                 hidden: Bool = false, on: (@MainActor (AppDelegate) -> Bool)? = nil, _ run: @escaping @MainActor (AppDelegate) -> Void) -> Command {
    let parsed = keys.map { spec in
        guard let s = Shortcut(spec) else { preconditionFailure("bad shortcut spec \(spec) for \(id)") }
        return s
    }
    return Command(id: id, title: title, keys: parsed, menu: menu, group: group, short: short, aliases: aliases, hidden: hidden, on: on, run: run)
}

extension AppDelegate {
    func makeCommands() -> [Command] { [
        // Navigation
        cmd("panel.switch", "Next Panel", ["tab"]) { $0.focusNext() },
        cmd("open", "Open", ["return", "kpenter"]) { $0.active.openCursor(intoPackage: false) },
        cmd("go.back", "Back", ["cmd+["], menu: "Go", group: 1) { $0.active.goBack() },
        cmd("go.forward", "Forward", ["cmd+]"], menu: "Go", group: 1) { $0.active.goForward() },
        cmd("go.up", "Enclosing Folder", ["cmd+up", "backspace"], menu: "Go", group: 1) { $0.active.goUp() },
        cmd("open.inside", "Open Inside", ["cmd+down"], menu: "Go", group: 1) { $0.active.openCursor(intoPackage: true) },
        cmd("open.other", "Open in Other Panel", ["cmd+return"], menu: "Go", group: 1, aliases: "other side folder there") { $0.openInOtherPanel() },
        // A list's own: its keys (F1 for its rows), another list of its server by name — keys only, inside a list.
        cmd("list.keys", "Keys of This List", ["shift+/"], aliases: "help list keys ?") { $0.showListKeys() },
        cmd("list.go", "Go to List…", ["shift+;"], aliases: "services containers ports tunnels overview :") { $0.goToList() },
        cmd("go.home", "Home", ["cmd+shift+h"], menu: "Go", group: 2) { $0.active.navigate(to: NSHomeDirectory()) },
        cmd("go.root", "Computer Root", ["cmd+shift+up"], menu: "Go", group: 2, short: "Root") { $0.active.navigate(to: "/") },
        cmd("go.path", "Go to Path…", ["cmd+l", "cmd+shift+g"], menu: "Go", group: 2, aliases: "path location") { app in
            if let e = app.textEditor { e.goToLine() } else { app.active.beginPathEditing() }   // an editor's: Go to Line… (`editorTitles`)
        },
        cmd("go.jump", "Jump to Folder…", ["cmd+p"], menu: "Go", group: 2, short: "Jump", aliases: "go to folder recent frecency") { app in
            if app.editorKey != nil { app.quickOpen() } else { app.showJump() }   // the editor window's ⌘P: Quick Open… (`editorTitles`)
        },
        cmd("go.tree", "Folder Tree…", ["f10", "opt+0", "opt+f10", "cmd+shift+t"], menu: "Go", group: 2, short: "Tree", aliases: "folder tree") { app in
            if let h = app.editorKey { return h.reopenClosed() }   // the editor window's ⇧⌘T: Reopen Closed Tab (`editorTitles`)
            let panel = app.active
            DirTree.show(in: app.window, over: panel.view, at: panel.path, showHidden: app.defaults.bool(forKey: "showHidden")) { panel.navigate(to: $0) }
        },
        cmd("go.connect", "Connect to Server…", ["ctrl+cmd+k"], menu: "Server", group: 1, short: "Connect", aliases: "sftp ssh smb nfs server remote") { $0.showConnect() },
        cmd("ssh.new", "New SSH Session…", ["cmd+k"], menu: "Server", group: 1, short: "SSH", aliases: "ssh shell remote terminal server") { $0.showConnect(ssh: true) },
        cmd("server.new", "New Server…", [], menu: "Server", group: 1, aliases: "ssh sftp server connection bookmark save") {
            $0.editServer(SavedServer(), title: "New Server")
        },
        cmd("server.overview", "Overview", ["cmd+shift+o"], menu: "Server", group: 2, aliases: "server place home root what runs services containers ports tunnels") { $0.showOverview() },
        cmd("server.services", "Services…", [], menu: "Server", group: 2, aliases: "systemd systemctl service status restart journal journalctl log unit") { $0.showServices() },
        cmd("server.containers", "Containers…", [], menu: "Server", group: 2, aliases: "docker podman container logs restart") { $0.showContainers() },
        cmd("tunnel.list", "Tunnels…", [], menu: "Server/Ports & Tunnels", group: 2, aliases: "port forward localhost database -L") { $0.showTunnels() },
        cmd("tunnel.new", "New Tunnel…", [], menu: "Server/Ports & Tunnels", group: 2, aliases: "port forward localhost database -L") { $0.newTunnel() },
        cmd("tunnel.forward", "Forward Port…", [], menu: "Server/Ports & Tunnels", group: 2, aliases: "ports listening ss netstat tunnel localhost -L") { $0.forwardPort() },
        cmd("ssh.copyKey", "Copy SSH Key to Server…", [], menu: "Server", group: 4, short: "Copy SSH Key", aliases: "ssh-copy-id authorized_keys public key login password") { $0.copyKey() },
        cmd("server.disconnect", "Disconnect", [], menu: "Server", group: 5, short: "Disconnect", aliases: "logout close connection ssh Disconnect Server") { app in
            let t = app.terminalActive ? app.terminal.current?.target : app.active.remote?.target ?? app.active.list?.source.target
            if let t { app.disconnect(t) } else { NSSound.beep() }
        },
        cmd("ssh.reconnect", "Reconnect SSH Session", [], menu: "Server", group: 5, short: "Reconnect", aliases: "ssh") { app in
            if app.terminal.isShown { app.terminal.reconnect() } else { NSSound.beep() }
        },
        cmd("ssh.config", "Edit SSH Config…", [], menu: "Server", group: 5, aliases: "ssh config hosts ~/.ssh/config") { $0.editSSHConfig() },
        cmd("remote.open", "Open Remote File", [], hidden: true) { $0.remoteOpen(.open) },
        cmd("remote.archive", "List Remote Archive", [], hidden: true) { $0.remoteArchiveList() },
        cmd("go.bookmark", "Bookmark This Folder", ["cmd+d"], menu: "Go", group: 3, short: "Bookmark", aliases: "favorite star pin",
            on: { app in app.activePanel.map { app.bookmarks.contains(app.bookmarkEntry($0)) } == true }) { $0.toggleBookmark() },
        cmd("go.linktarget", "Go to Link Target", ["cmd+j"], menu: "Go", group: 2, short: "Link Target") { $0.goToLinkTarget() },
        cmd("go.volumes", "Volumes…", ["cmd+shift+v", "opt+f1"], menu: "Go", group: 2, aliases: "disks drives mounts") { $0.showVolumes() },
        cmd("app.about", "About Kermo", [], menu: "Kermo", group: 1, short: "About", aliases: "info version help") { _ in
            // Name, icon, version (build) and copyright come from Info.plist (build.sh); only the description is ours.
            let credits = NSMutableAttributedString(string: "A fast 2–4 panel file manager for macOS, built with Swift and AppKit.\n\n",
                                                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
            credits.append(NSAttributedString(string: "github.com/paliydmn/kermo", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://github.com/paliydmn/kermo")!]))
            credits.append(NSAttributedString(string: "\nSupport Kermo", attributes: [.font: NSFont.systemFont(ofSize: 11), .link: supportPage]))
            credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        },
        cmd("app.settings", "Settings…", ["cmd+,"], menu: "Kermo", group: 2, aliases: "preferences options defaults configuration") { SettingsWindow.show($0) },
        cmd("app.update", "Check for Updates…", [], menu: "Kermo", group: 2, aliases: "update upgrade new version release") { app in
            app.showMainWindow(nil)   // its answer is a sheet there, also when a viewer is in front
            Task { await app.checkForUpdates(byHand: true) }
        },
        cmd("app.support", "Support Kermo…", [], menu: "Kermo", group: 2, aliases: "donate sponsor ko-fi") { _ in NSWorkspace.shared.open(supportPage) },
        cmd("app.update.auto", "Check for Updates Automatically", [], menu: "Kermo/Configuration", group: 5, aliases: "update daily",
            on: { !$0.defaults.bool(forKey: "updateCheckOff") }) { $0.toggleUpdateChecks() },
        cmd("app.installCLI", "Install “kermo” Command", [], menu: "Kermo", group: 3) { $0.installCLI() },
        cmd("help.keys", "Keyboard Shortcuts", ["f1", "opt+1"], menu: "Help", group: 1, short: "Shortcuts", aliases: "help shortcuts cheat sheet") { app in
            if let w = AppDelegate.windowToClose(key: NSApp.keyWindow, main: app.window), let menu = NSApp.mainMenu {   // a viewer's, an editor's
                return KeyHelp.show(over: w, commands: [], fixed: app.keySections(over: w, menu: menu))
            }
            KeyHelp.show(over: app.window, commands: app.commands, fields: KeyHelp.fieldKeys)
        },
        cmd("help.docs", "Kermo Documentation", [], menu: "Help", group: 2, aliases: "help manual readme guide docs") { _ in
            NSWorkspace.shared.open(URL(string: "https://github.com/paliydmn/kermo#readme")!)
        },
        cmd("help.issue", "Report an Issue…", [], menu: "Help", group: 2, aliases: "bug feedback github issues") { _ in
            NSWorkspace.shared.open(URL(string: "https://github.com/paliydmn/kermo/issues/new")!)
        },
        cmd("app.palette", "Search…", ["cmd+shift+p", "f9", "opt+9"], menu: "Go", group: 4, aliases: "palette all commands") { $0.palette() },

        // Tabs
        // In the editor window these act on its tabs; while the keys go to the terminal (⌃O), on its tabs.
        cmd("tab.new", "New Tab", ["cmd+t"], menu: "View/Tabs", group: 2) { app in
            if app.editorKey != nil { Editor.untitled() } else if app.terminalActive { app.terminal.newShell(cwd: app.active.path) } else { app.active.newTab() }
        },
        cmd("tab.close", "Close Tab", ["cmd+w"], menu: "View/Tabs", group: 2) { app in
            if let h = app.editorKey { h.active?.closeAsking() }
            else if let w = AppDelegate.windowToClose(key: NSApp.keyWindow, main: app.window) { w.performClose(nil) }
            else if app.terminalActive { app.terminal.close() } else { app.active.closeTab() }
        },
        cmd("tab.next", "Next Tab", ["ctrl+tab", "cmd+shift+]"], menu: "View/Tabs", group: 2) { app in
            if let h = app.editorKey { h.switchTab(by: 1) } else if app.terminalActive { app.terminal.switchTab(by: 1) } else { app.active.switchTab(by: 1) }
        },
        cmd("tab.prev", "Previous Tab", ["ctrl+shift+tab", "cmd+shift+["], menu: "View/Tabs", group: 2) { app in
            if let h = app.editorKey { h.switchTab(by: -1) } else if app.terminalActive { app.terminal.switchTab(by: -1) } else { app.active.switchTab(by: -1) }
        },
        // The editor window's own: no keys of their own but Close Editor Window's.
        cmd("editor.tab.left", "Move Tab Left", [], menu: "View/Tabs", group: 2, aliases: "editor reorder") { $0.editorKey?.moveTab(by: -1) },
        cmd("editor.tab.right", "Move Tab Right", [], menu: "View/Tabs", group: 2, aliases: "editor reorder") { $0.editorKey?.moveTab(by: 1) },
        cmd("editor.tabs", "All Tabs…", [], menu: "View/Tabs", group: 2, aliases: "editor list documents") { $0.editorKey?.allTabs() },
        cmd("editor.closeOthers", "Close Other Tabs", [], menu: "View/Tabs", group: 2, aliases: "editor close all but") { app in
            if let h = app.editorKey, let a = h.active { h.closeOthers(than: a) }
        },
        cmd("editor.closeRight", "Close Tabs to the Right", [], menu: "View/Tabs", group: 2, aliases: "editor close") { app in
            if let h = app.editorKey, let a = h.active { h.closeRight(of: a) }
        },
        // The editor window's two panes: ⌘\ and ⇧⌘\ split it (`editorTitles`), these move a tab across or join them.
        cmd("editor.moveToPane", "Move to Other Pane", [], menu: "View/Tabs", group: 2, aliases: "editor split pane move") { app in
            if let h = app.editorKey, let a = h.active { h.move(a) }
        },
        cmd("editor.cloneToPane", "Clone to Other Pane", [], menu: "View/Tabs", group: 2, aliases: "editor split pane clone copy two views") { app in
            if let h = app.editorKey, let a = h.active { h.clone(a) }
        },
        cmd("editor.joinPanes", "Join Panes", [], menu: "View/Tabs", group: 2, aliases: "editor unsplit merge panes") { $0.editorKey?.joinPanes() },
        // Compare in the editor window (`Comparison`): ⇧⌘D there is Compare With… (`editorTitles`), ⌥⌘↓ ⌥⌘↑ go from
        // change to change while it compares (`term.pane.down`, `term.pane.up`); these have no keys of their own but Copy Change's.
        cmd("editor.compare.with", "Compare With…", [], menu: "View/Compare", group: 3, aliases: "editor diff compare tab clipboard saved version") { $0.editorKey?.compareWith() },
        cmd("editor.compare.next", "Next Change", [], menu: "View/Compare", group: 4, aliases: "editor diff compare difference") { $0.compareStep(1) },
        cmd("editor.compare.prev", "Previous Change", [], menu: "View/Compare", group: 4, aliases: "editor diff compare difference") { $0.compareStep(-1) },
        // The editor window's line or selection into the terminal: typed, or typed and run (⌃↩ / ⌃⇧↩ there,
        // `editorTerminalKeys`).
        cmd("editor.send", "Send to Terminal", [], menu: "Edit", group: 9, aliases: "editor terminal type insert line selection shell") { $0.editorToTerminal(run: false) },
        cmd("editor.execute", "Execute in Terminal", [], menu: "Edit", group: 9, aliases: "editor terminal run line selection shell command") { $0.editorToTerminal(run: true) },
        // The caret's change from the other side, into the left pane's or the right one's (a document's).
        cmd("editor.compare.copyLeft", "Copy Change to Left", ["cmd+opt+shift+left"], menu: "View/Compare", group: 5, aliases: "editor diff compare merge take apply hunk") {
            $0.editorKey?.copyChange(toLeft: true)
        },
        cmd("editor.compare.copyRight", "Copy Change to Right", ["cmd+opt+shift+right"], menu: "View/Compare", group: 5, aliases: "editor diff compare merge take apply hunk") {
            $0.editorKey?.copyChange(toLeft: false)
        },
        cmd("editor.compare.stop", "Stop Comparing", [], menu: "View/Compare", group: 6, aliases: "editor diff compare end close") { $0.editorKey?.stopComparing() },
        // The terminal's panes (as VS Code's split): while it's up. In the editor window, its own (`editorTitles`).
        cmd("term.split.right", "Split Terminal Right", ["cmd+\\"], menu: "View/Tabs", group: 3, aliases: "pane side by side") { app in
            if let h = app.editorKey { h.split(vertical: true) } else { app.terminal.split(vertical: true) }
        },
        cmd("term.split.down", "Split Terminal Down", ["cmd+shift+\\"], menu: "View/Tabs", group: 3, aliases: "pane above below") { app in
            if let h = app.editorKey { h.split(vertical: false) } else { app.terminal.split(vertical: false) }
        },
        cmd("term.join", "Join Tab…", [], menu: "View/Tabs", group: 3, aliases: "split merge combine pane terminal") { $0.joinTerminalTab() },
        cmd("term.unsplit", "Move Pane to New Tab", [], menu: "View/Tabs", group: 3, aliases: "unsplit pane terminal") { $0.terminal.unsplit() },
        cmd("term.pane.left", "Focus Pane Left", ["cmd+opt+left"], aliases: "terminal split") { app in if let h = app.editorKey { h.focusPane(by: -1, vertical: true) } else { app.terminal.focusPane(by: -1, vertical: true) } },
        cmd("term.pane.right", "Focus Pane Right", ["cmd+opt+right"], aliases: "terminal split") { app in if let h = app.editorKey { h.focusPane(by: 1, vertical: true) } else { app.terminal.focusPane(by: 1, vertical: true) } },
        cmd("term.pane.up", "Focus Pane Above", ["cmd+opt+up"], aliases: "terminal split") { app in
            if let h = app.editorKey { if h.comparison?.paused == false { app.compareStep(-1) } else { h.focusPane(by: -1, vertical: false) } } else { app.terminal.focusPane(by: -1, vertical: false) }
        },
        cmd("term.pane.down", "Focus Pane Below", ["cmd+opt+down"], aliases: "terminal split") { app in   // comparing: the panes are side by side, ↓ ↑ free
            if let h = app.editorKey { if h.comparison?.paused == false { app.compareStep(1) } else { h.focusPane(by: 1, vertical: false) } } else { app.terminal.focusPane(by: 1, vertical: false) }
        },
        cmd("term.resize.left", "Move Pane Divider Left", ["ctrl+cmd+left"], aliases: "terminal split resize") { app in if let h = app.editorKey { h.resizePane(by: -1, vertical: true) } else { app.terminal.resizePane(by: -1, vertical: true) } },
        cmd("term.resize.right", "Move Pane Divider Right", ["ctrl+cmd+right"], aliases: "terminal split resize") { app in if let h = app.editorKey { h.resizePane(by: 1, vertical: true) } else { app.terminal.resizePane(by: 1, vertical: true) } },
        cmd("term.resize.up", "Move Pane Divider Up", ["ctrl+cmd+up"], aliases: "terminal split resize") { app in if let h = app.editorKey { h.resizePane(by: -1, vertical: false) } else { app.terminal.resizePane(by: -1, vertical: false) } },
        cmd("term.resize.down", "Move Pane Divider Down", ["ctrl+cmd+down"], aliases: "terminal split resize") { app in if let h = app.editorKey { h.resizePane(by: 1, vertical: false) } else { app.terminal.resizePane(by: 1, vertical: false) } },

        // Panels & view
        cmd("panel.swap", "Swap Panels", ["cmd+u"], menu: "View/Panels", group: 2, short: "Swap", aliases: "swap panels") { $0.swapPanels() },
        cmd("panel.add", "Add Panel", ["cmd+opt+n"], menu: "View/Panels", group: 2, aliases: "panels split") { $0.addPanel() },
        cmd("panel.close", "Close Panel", ["cmd+opt+w"], menu: "View/Panels", group: 2) { $0.closePanel() },
    ] + (1...4).map { n in
        cmd("panel.focus\(n)", "Go to Panel \(n)", ["cmd+\(n)"], menu: "View/Panels", group: 3, short: "Panel \(n)") { $0.focusPanel(n - 1) }
    } + [
        cmd("panel.same", "Same Folder in Other Panel", ["opt+="], menu: "View/Panels", group: 2, short: "Same Folder") { app in
            if let r = app.active.remote { app.other.loadRemote(r.target, dir: r.dir, select: nil) } else { app.other.navigate(to: app.active.path) }
        },
        cmd("view.sidebar", "Sidebar", ["ctrl+cmd+s"], menu: "View", group: 1, short: "Sidebar", aliases: "places favorites Show/Hide Sidebar",
            on: { $0.sidebarShown }) { $0.toggleSidebar() },
        cmd("ai.chat", "AI Chat", ["ctrl+cmd+i"], menu: "View", group: 1, short: "AI", aliases: "ai assistant chat ask claude model llm Show AI Chat",
            on: { $0.aiChatShown }) { $0.toggleAIChat() },
        cmd("ai.add", "Add to Chat", ["cmd+shift+i"], menu: "View", group: 1, short: "To Chat", aliases: "ai selection selected attach context ask chip") { $0.addToChat() },
        cmd("view.sidebarFocus", "Focus Sidebar", ["ctrl+shift+s"], menu: "View/Panels", group: 3, aliases: "places keyboard") { $0.focusSidebar() },
        cmd("view.hidden", "Hidden Files", ["cmd+shift+."], menu: "View", group: 3, short: "Hidden Files", aliases: "dotfiles show hidden files Show Hidden Files",
            on: { $0.defaults.bool(forKey: "showHidden") }) { $0.toggleHidden() },
        cmd("view.perms", "Permissions & Owner", [], menu: "View", group: 3, short: "Permissions", aliases: "mode rwx owner group columns Show Permissions & Owner",
            on: { $0.defaults.bool(forKey: "showPerms") }) {
            $0.togglePerms()
        },
        cmd("view.refresh", "Refresh", ["cmd+r"], menu: "View", group: 5) { $0.active.reload() },
        cmd("view.theme", "Theme…", [], menu: "View", group: 4, aliases: "colors dark midnight commander solarized") { $0.showThemes() },
        cmd("view.filter", "Quick Filter", ["/"], menu: "View", group: 3, short: "Filter", aliases: "filter glob regex") { $0.active.beginFilter() },
        cmd("view.filterPresets", "Filter Presets…", ["cmd+/"], menu: "View", group: 3, aliases: "filter glob") { app in
            if let e = app.textEditor { e.toggleComment() } else { app.showFilterPresets() }
        },
        cmd("view.filterPresets.edit", "Edit Filter Presets…", [], menu: "Kermo/Configuration", group: 3) {
            _ = $0.filterPresets()   // writes the example file on first use
            $0.openInEditor(URL(fileURLWithPath: Config.path("filters.json")))
        },
        cmd("view.quickview", "Quick View", ["ctrl+q"], menu: "View", group: 1, short: "Quick View", aliases: "quick view Quick View Panel", on: { $0.quickViewOn }) { $0.toggleQuickView() },
        cmd("view.terminal", "Terminal", ["ctrl+o"], menu: "View", group: 1, short: "Terminal", aliases: "shell console drawer Show/Hide Terminal", on: { $0.terminal?.isShown == true }) { $0.toggleTerminal() },
        cmd("view.terminalFull", "Maximize Terminal", ["ctrl+shift+o"], menu: "View", group: 1, short: "Maximize", aliases: "shell console full hide panels",
            on: { $0.terminal?.isFull == true }) {
            $0.toggleTerminalFull()
        },
        // The terminal's current pane (task 21), «⋯» in its top row too. ⌘↑ ⌘↓ ⇧⌘A there are their keys (`terminalBranches`).
        cmd("term.editor", "Open in Editor", ["cmd+opt+o"], menu: "View/Terminal Pane", group: 1, aliases: "terminal output scrollback history copy text") {
            $0.terminalToEditor(output: false)
        },
        cmd("term.output.editor", "Open Output in Editor", [], menu: "View/Terminal Pane", group: 1, aliases: "terminal last command result") {
            $0.terminalToEditor(output: true)
        },
        cmd("term.output.copy", "Copy Output of Last Command", [], menu: "View/Terminal Pane", group: 1, short: "Copy Output", aliases: "terminal last command result clipboard") {
            $0.terminal.copyOutput()
        },
        cmd("term.output.chat", "Add Command and Output to Chat", [], menu: "View/Terminal Pane", group: 1, aliases: "ai terminal last command result attach ask") {
            $0.addCommandToChat()
        },
        cmd("term.output.explain", "Explain Last Command", [], menu: "View/Terminal Pane", group: 1, aliases: "ai why failed error terminal command result ask") {
            $0.explainLastCommand()
        },
        cmd("term.mark.prev", "Previous Mark", [], menu: "View/Terminal Pane", group: 2, short: "Prev Mark", aliases: "terminal command prompt jump scroll") { $0.terminal.goToMark(by: -1) },
        cmd("term.mark.next", "Next Mark", [], menu: "View/Terminal Pane", group: 2, aliases: "terminal command prompt jump scroll") { $0.terminal.goToMark(by: 1) },
        cmd("term.zoom", "Zoom Pane", ["cmd+shift+return"], menu: "View/Terminal Pane", group: 3, short: "Zoom", aliases: "terminal split maximize pane whole tab") { $0.terminal.zoom() },
        cmd("view.activity", "Activity", ["cmd+opt+j"], menu: "View", group: 1,
            aliases: "copies transfers operations queue progress history retry failed", on: { $0.ops?.activityShown == true }) { $0.ops.toggleActivity() },
        cmd("term.bigger", "Bigger Terminal Text", ["cmd+=", "cmd+shift+="], menu: "View", group: 4, aliases: "font size zoom in larger") { app in
            if app.textEditor != nil { Editor.zoom(by: 1) } else if app.terminal.isShown { app.terminal.zoom(by: 1) } else { NSSound.beep() }
        },
        cmd("term.smaller", "Smaller Terminal Text", ["cmd+-"], menu: "View", group: 4, aliases: "font size zoom out") { app in
            if app.textEditor != nil { Editor.zoom(by: -1) } else if app.terminal.isShown { app.terminal.zoom(by: -1) } else { NSSound.beep() }
        },
        // The editor's text (its window's or a tool's): `text.*` work only while one is key (`textEditor`).
        cmd("text.wrap", "Wrap Lines", ["opt+z"], menu: "View", group: 6, aliases: "word wrap long lines editor", on: { _ in Editor.wraps }) { _ in Editor.toggleWrap() },
        cmd("text.invisibles", "Show Invisibles", [], menu: "View", group: 6, aliases: "whitespace tabs spaces editor", on: { _ in Editor.invisibles }) { _ in
            Editor.toggleInvisibles()
        },
        // The editor's row under its toolbar (`MoreTools`): no key, ⌥⌘T is macOS's Show Toolbar.
        cmd("text.moreTools", "Show More Tools", [], menu: "View", group: 6, aliases: "editor toolbar buttons second row icons") { $0.textEditor?.host.toggleMoreTools() },
        cmd("text.indent.tabs", "Tabs", [], menu: "View/Indentation", group: 6, aliases: "indent with tabs editor",
            on: { $0.textEditor?.indent == .tabs }) { $0.textEditor?.pickIndent(.tabs) },
        cmd("text.indent.2", "2 Spaces", [], menu: "View/Indentation", group: 6, aliases: "indent with spaces editor",
            on: { $0.textEditor?.indent == .spaces(2) }) { $0.textEditor?.pickIndent(.spaces(2)) },
        cmd("text.indent.4", "4 Spaces", [], menu: "View/Indentation", group: 6, aliases: "indent with spaces editor",
            on: { $0.textEditor?.indent == .spaces(4) }) { $0.textEditor?.pickIndent(.spaces(4)) },
        cmd("view.dirsizes", "Calculate Folder Sizes", ["opt+space"], menu: "View", group: 3, short: "Folder Sizes", aliases: "folder size disk usage du") { $0.active.computeAllDirSizes() },
        cmd("view.sort.name", "Name", [], menu: "View/Sort By", group: 3, aliases: "order Sort by Name", on: { $0.activePanel?.sortKey == .name }) { $0.active.sort(by: .name) },
        cmd("view.sort.size", "Size", [], menu: "View/Sort By", group: 3, aliases: "order biggest Sort by Size", on: { $0.activePanel?.sortKey == .size }) { $0.active.sort(by: .size) },
        cmd("view.sort.mtime", "Modified", [], menu: "View/Sort By", group: 3, aliases: "order date time newest Sort by Modified", on: { $0.activePanel?.sortKey == .mtime }) { $0.active.sort(by: .mtime) },
        cmd("view.sort.reverse", "Reverse", [], menu: "View/Sort By", group: 4, aliases: "order descending ascending Reverse Sort Order",
            on: { $0.activePanel.map { $0.ascending != ($0.sortKey == .name) } == true }) { $0.active.reverseSort() },
        cmd("panel.menu", "Show Context Menu", ["shift+f10", "menu"], short: "Menu", aliases: "right click actions") { $0.active.showContextMenu() },

        // Marking (MC style: cursor ≠ marked set)
        cmd("mark.toggle", "Mark / Unmark", ["space"], menu: "Mark", group: 1, short: "Mark") { $0.active.toggleMark(move: 1) },
        cmd("mark.down", "Mark and Move Down", ["shift+down"], short: "Mark ↓") { $0.active.toggleMark(move: 1) },
        cmd("mark.up", "Mark and Move Up", ["shift+up"], short: "Mark ↑") { $0.active.toggleMark(move: -1) },
        cmd("mark.all", "Mark All", ["cmd+a"], menu: "Mark", group: 1) { $0.active.markAll() },
        cmd("mark.none", "Unmark All", ["cmd+shift+a"], menu: "Mark", group: 1, aliases: "deselect") { $0.active.unmarkAll() },
        cmd("mark.invert", "Invert Marks", ["shift+8", "kpstar"], menu: "Mark", group: 1, short: "Invert", aliases: "invert selection marks") { $0.active.invertMarks() },
        cmd("panel.compare", "Mark Differences", ["shift+f2"], menu: "Mark", group: 2, short: "Differences", aliases: "compare folders difference Compare Folders (mark differences)") { $0.compareFolders() },
        cmd("panel.sync", "Synchronize Folders…", ["cmd+opt+s"], menu: "Mark", group: 2, short: "Synchronize", aliases: "synchronize mirror folders") { app in
            guard app.active.archive == nil, app.other.archive == nil, app.active.searchTitle == nil, app.other.searchTitle == nil
            else { return app.active.flash("Synchronize works between two folders") }
            let (l, r) = app.panels.firstIndex { $0 === app.active }! < app.panels.firstIndex { $0 === app.other }! ? (app.active, app.other) : (app.other, app.active)
            let (ld, rd, sides) = (l.currentDir, r.currentDir, (l.endpoint, r.endpoint))
            Task { if await app.unlock([sides.0, sides.1]) { SyncWindow.show(left: ld, right: rd, sides: sides) { await app.enqueueSync($0) } } }
        },
    ] + SidebarModel.tagColors.enumerated().map { i, color in
        cmd("tag.\(i + 1)", "Tag \(NSWorkspace.shared.fileLabels[color])", ["ctrl+\(i + 1)"], menu: "Mark/Tags", group: 3,
            short: NSWorkspace.shared.fileLabels[color]) { $0.toggleTag(color) }
    } + [
        cmd("tag.clear", "Remove All Tags", ["ctrl+0"], menu: "Mark/Tags", group: 4, short: "Remove Tags") { $0.applyTags($0.active.targetURLs) { _, _ in [] } },
        cmd("tag.edit", "Tags…", ["ctrl+t"], menu: "Mark/Tags", group: 4, short: "Tags", aliases: "finder tag label color") { $0.tagsDialog() },
        cmd("mark.mask", "Mark by Mask…", ["shift+=", "kpplus"], menu: "Mark", group: 1, aliases: "select glob pattern") { $0.maskDialog(mark: true) },
        cmd("mark.unmask", "Unmark by Mask…", ["-", "kpminus"], menu: "Mark", group: 1) { $0.maskDialog(mark: false) },

        // File operations
        cmd("file.view", "View", ["f3", "opt+3"], menu: "File", group: 1, aliases: "viewer read log") { $0.viewFile() },
        cmd("archive.open", "Open from Archive", [], hidden: true) { $0.openFromArchive(view: false) },
        cmd("file.compress", "Compress…", ["opt+f5"], menu: "File", group: 5, aliases: "zip tar archive pack") { $0.compressDialog() },
        cmd("file.extract", "Extract…", ["opt+f9"], menu: "File", group: 5, aliases: "unzip untar unpack archive") { $0.extractDialog() },
        cmd("file.edit", "Edit", ["f4", "opt+4"], menu: "File", group: 1, aliases: "editor") { $0.editFile() },
        // In the built-in editor whatever F4 opens with; nothing on disk till its Save (Shift+F4 New File… makes one).
        cmd("editor.new", "New Editor Document", ["cmd+n"], menu: "File", group: 0, aliases: "untitled new text document notepad scratch") { _ in Editor.untitled() },
        cmd("editor.show", "Show Editor", ["cmd+shift+e"], menu: "File", group: 0, aliases: "editor tabs drafts notepad") { _ in EditorHost.tabs.showEditor() },
        // Hides it, its tabs kept as drafts (Show Editor brings it back).
        cmd("editor.close", "Close Editor Window", ["cmd+shift+w"], menu: "File", group: 0, aliases: "hide editor") { $0.editorKey?.hide() },
        cmd("file.copy", "Copy To…", ["f5", "opt+5"], menu: "File", group: 2, short: "Copy") { $0.transferDialog(move: false) },
        cmd("file.move", "Move To…", ["f6", "opt+6"], menu: "File", group: 2, short: "Move") { $0.transferDialog(move: true) },
        cmd("file.rename", "Rename…", ["shift+f6", "shift+opt+6"], menu: "File", group: 2) { $0.renameDialog() },
        cmd("file.copyAs", "Copy Here As…", ["shift+f5", "shift+opt+5"], menu: "File", group: 2, aliases: "duplicate backup bak") { $0.copyAsDialog() },
        cmd("file.multirename", "Multi-Rename…", ["cmd+shift+m"], menu: "File", group: 2, aliases: "batch multi rename") { $0.multiRename() },   // ⌘M minimizes
        cmd("file.mkdir", "New Folder…", ["f7", "opt+7", "cmd+shift+n"], menu: "File", group: 3, aliases: "mkdir new folder directory") { $0.mkdirDialog() },
        cmd("file.new", "New File…", ["shift+f4", "shift+opt+4"], menu: "File", group: 3) { $0.newFileDialog() },
        cmd("file.trash", "Move to Trash", ["f8", "opt+8", "cmd+backspace", "delete"], menu: "File", group: 4, short: "Trash", aliases: "delete remove") { $0.trash() },
        cmd("file.putback", "Put Back", [], menu: "File", group: 4, aliases: "restore undelete trash") { $0.putBack() },
        cmd("file.delete", "Delete Permanently…", ["shift+f8", "shift+opt+8", "cmd+opt+backspace", "shift+delete"], menu: "File", group: 4, short: "Delete", aliases: "remove rm permanently") {
            $0.deletePermanently()
        },
        cmd("file.quicklook", "Quick Look", ["cmd+y"], menu: "File", group: 1, aliases: "preview") { $0.active.toggleQuickLook() },
        cmd("search", "Search Files…", ["opt+f7", "cmd+f"], menu: "Go", group: 4, aliases: "search files content spotlight") { $0.searchDialog() },
        cmd("file.reveal", "Reveal in Finder", ["cmd+shift+r"], menu: "File", group: 6, short: "Reveal", aliases: "show in finder") {
            NSWorkspace.shared.activateFileViewerSelecting($0.active.targetURLs)
        },
        cmd("file.terminal", "Open in Terminal", ["cmd+opt+t"], menu: "File", group: 6, aliases: "shell console") { $0.openTerminal() },
        cmd("file.symlink", "Create Symbolic Link…", ["cmd+opt+l"], menu: "File/Links", group: 3, short: "Symbolic Link", aliases: "link ln") { $0.linkDialog(hard: false) },
        cmd("file.hardlink", "Create Hard Link…", [], menu: "File/Links", group: 3) { $0.linkDialog(hard: true) },
        cmd("file.attrs", "Permissions & Owner…", ["cmd+opt+a"], menu: "File", group: 1, short: "Permissions", aliases: "chmod chown chgrp mode rwx owner group permissions") {
            $0.attributesDialog()
        },
        cmd("file.split", "Split File…", [], menu: "File/Split & Combine", group: 5, aliases: "chunks parts") { $0.splitDialog() },
        cmd("file.combine", "Combine Parts…", [], menu: "File/Split & Combine", group: 5, aliases: "join merge chunks") { $0.combineDialog() },
        cmd("file.diff", "Compare Files", ["cmd+shift+d"], menu: "Mark", group: 2, short: "Compare", aliases: "compare files Compare Files (diff)") { app in
            if let h = app.editorKey { h.compareWith() } else { app.diffFiles() }
        },   // not ⌘⌥D: macOS takes it (Dock hiding)
        cmd("server.history", "File History…", [], menu: "Server", group: 4, aliases: "versions revert previous backup undo save sftp Server File History…") { $0.serverFileHistory() },
        cmd("file.eject", "Eject Volume", ["cmd+opt+e"], menu: "File", group: 7, short: "Eject", aliases: "unmount disk") { $0.ejectVolume() },
        cmd("file.unmount", "Unmount Volume", [], menu: "File", group: 7, short: "Unmount", aliases: "disk eject") { $0.ejectVolume(unmount: true) },
        cmd("file.info", "Get Info", ["cmd+i"], menu: "File", group: 1, short: "Info", aliases: "get info permissions chmod chown owner hash checksum xattr quarantine") {
            $0.showInfo()
        },

        // Git: the work tree of the active panel (the sidebar's Git section)
        cmd("git.switch", "Switch Branch…", ["ctrl+b"], menu: "Git", group: 1, short: "Branch", aliases: "git checkout branch tag create new") { $0.showBranches() },
        cmd("git.newBranch", "New Branch…", [], menu: "Git", group: 1, aliases: "git checkout create branch") { $0.newBranch(from: nil) },
        cmd("git.commit", "Commit…", ["ctrl+shift+c"], menu: "Git", group: 1, aliases: "git commit amend message") { $0.showCommit() },
        cmd("git.sync", "Sync", [], menu: "Git", group: 2, aliases: "git pull push synchronize remote origin") { $0.gitSync() },
        cmd("git.publish", "Publish Branch", [], menu: "Git", group: 2, short: "Publish", aliases: "git push upstream origin remote") { $0.gitPublish() },
        cmd("git.pull", "Pull", [], menu: "Git", group: 2, aliases: "git pull fast-forward remote origin") { $0.gitPull() },
        cmd("git.push", "Push", [], menu: "Git", group: 2, aliases: "git push remote origin") { $0.gitPush() },
        cmd("git.fetch", "Fetch", [], menu: "Git", group: 2, aliases: "git fetch prune remote origin") { $0.gitFetch() },
        cmd("git.changes", "Changes", ["ctrl+shift+g"], menu: "Git", group: 3, short: "Git Changes", aliases: "git status dirty edited source control list Git Changes") {
            $0.active.showGitChanges()
        },
        cmd("view.gitOnly", "Show Only Changes", ["ctrl+g"], menu: "Git", group: 3, short: "Git Only", aliases: "git status dirty edited filter source control Show Only Git Changes",
            on: { $0.activePanel?.gitOnly == true }) {
            $0.toggleGitOnly()
        },
        cmd("git.diff", "Diff", ["ctrl+d"], menu: "Git", group: 3, short: "Git Diff", aliases: "git difference changes against head Git Diff") { $0.gitDiff() },
        cmd("git.log", "Log of File", ["ctrl+l"], menu: "Git", group: 3, short: "Git Log", aliases: "git history commits follow patch Git Log of File") { $0.gitHistory(blame: false) },
        cmd("git.blame", "Blame", ["ctrl+shift+l"], menu: "Git", group: 3, short: "Git Blame", aliases: "git annotate who changed lines Git Blame") { $0.gitHistory(blame: true) },
        cmd("git.stage", "Stage", ["ctrl+shift+a"], menu: "Git", group: 3, short: "Stage", aliases: "git add index Git Stage") { $0.gitStage(undo: false) },
        cmd("git.unstage", "Unstage", ["ctrl+shift+u"], menu: "Git", group: 3, short: "Unstage", aliases: "git reset restore staged index Git Unstage") { $0.gitStage(undo: true) },
        cmd("git.root", "Go to Repository Root", [], menu: "Git", group: 4, short: "Repository Root", aliases: "git top level work tree") { $0.gitRootFolder() },
        cmd("git.copyBranch", "Copy Branch Name", [], menu: "Git", group: 4, aliases: "git branch clipboard") { $0.gitCopyBranch() },
        cmd("git.init", "Initialize Repository…", [], menu: "Git", group: 4, aliases: "git init new repository create Initialize Git Repository…") { $0.gitInit() },

        // Shell
        cmd("usermenu", "User Menu…", ["f2", "opt+2"], menu: "File", group: 6, aliases: "user menu") { $0.showUserMenu() },
        cmd("cmdline.focus", "Command Line", ["cmd+e"], menu: "Go", group: 4, aliases: "command line shell") { $0.focusCommandLine() },
        cmd("cmdline.insert", "Insert Name into Command Line", ["ctrl+return"], short: "Insert Name") { $0.insertIntoCommandLine(paths: false) },
        cmd("cmdline.insertPaths", "Insert Paths into Command Line", ["ctrl+shift+return"], short: "Insert Paths", aliases: "marked full paths") {
            $0.insertIntoCommandLine(paths: true)
        },

        // Administrator (password prompt per action)
        cmd("admin.copy", "Copy as Administrator…", [], menu: "File/As Administrator", group: 8, aliases: "root sudo") { $0.adminTransfer(move: false) },
        cmd("admin.move", "Move as Administrator…", [], menu: "File/As Administrator", group: 8, aliases: "root sudo") { $0.adminTransfer(move: true) },
        cmd("admin.mkdir", "New Folder as Administrator…", [], menu: "File/As Administrator", group: 8, aliases: "root sudo") { $0.adminMkdir() },
        cmd("admin.delete", "Delete as Administrator…", [], menu: "File/As Administrator", group: 8, aliases: "root sudo rm") { $0.adminDelete() },
        cmd("admin.shell", "Root Shell in Terminal", [], menu: "File/As Administrator", group: 9, aliases: "root sudo Root Shell Here (Terminal)") { $0.runShell("sudo -s", in: .terminalApp) },
        cmd("admin.rootPanel", "Reopen as Root", ["ctrl+cmd+r"], menu: "Server", group: 3, short: "As Root", aliases: "root sudo server etc Reopen Panel as Root") { $0.reopenPanel(asRoot: true) },
        cmd("app.tools", "Tools", ["ctrl+cmd+t"], menu: "Window", group: 1, aliases: "tools window server page firewall ufw fail2ban server info Open Tools Window") { app in
            ToolsWindow.show(app, server: app.terminalActive ? app.terminal.current?.target : app.active.remote?.target ?? app.active.list?.source.target)
        },
        // Settings ▸ Monitor's buttons
        cmd("monitor.notificationSettings", "Notification Settings for Kermo", [], hidden: true) { _ in ToolMonitor.notificationSettings() },
        cmd("monitor.test", "Send a Test Alert", [], hidden: true) { $0.tools.monitor.test() },
        cmd("ai.test", "Test the AI Provider", [], hidden: true) { AISettings.test($0.defaults) },
        cmd("monitor.keepAwake", "Keep This Mac Awake on Power", [], hidden: true, on: { $0.tools.monitor.keepAwake }) { $0.tools.monitor.keepAwake.toggle() },
        cmd("monitor.slowOnBattery", "Watch Less Often on Battery", [], hidden: true, on: { $0.tools.monitor.slowOnBattery }) { $0.tools.monitor.slowOnBattery.toggle() },
        cmd("monitor.openAtLogin", "Open Kermo at Login", [], hidden: true, on: { _ in ToolMonitor.loginItem.status() == .enabled }) { $0.tools.monitor.openAtLogin() },
        cmd("app.monitor", "Monitor", ["ctrl+cmd+m"], menu: "Window", group: 1, aliases: "watched servers alerts menu bar Open Monitor") {
            $0.tools.monitor.open($0.tools.monitor.watched.first?.target)
        },
        cmd("admin.userPanel", "Reopen as User", ["ctrl+shift+cmd+r"], menu: "Server", group: 3, short: "As User", aliases: "root sudo server user Reopen Panel as User") { $0.reopenPanel(asRoot: false) },
        cmd("admin.sudoTouchID", "Enable Touch ID for sudo", [], menu: "File/As Administrator", group: 9, aliases: "touch id fingerprint sudo terminal pam tid password") {
            $0.enableSudoTouchID()
        },
        cmd("admin.auditLog", "Production Log", [], menu: "Server", group: 5, aliases: "audit journal prod history Show Production Log") { $0.showAuditLog() },
        cmd("server.watch", "Watch Server…", [], menu: "Server", group: 4, aliases: "monitor watch background system cpu memory disk alerts Stop Watching") { app in
            app.watchActiveServer()
        },
        cmd("server.runOn", "Run on Servers…", [], menu: "Server", group: 4, aliases: "ssh command several many all servers parallel pssh") {
            $0.runOnServers()
        },

        // Clipboard
        cmd("edit.copyPath", "Copy Path", ["cmd+shift+c"], menu: "Edit", group: 1, aliases: "path clipboard") { app in
            if let e = app.textEditor { e.copyPath() } else { app.copyToPasteboard(app.active.targetPaths) }   // an editor's: its file's (`editorTitles`)
        },
        cmd("text.line.up", "Move Line Up", ["opt+up"], menu: "Edit/Lines", group: 3, aliases: "editor swap") { $0.textEditor?.moveLines(up: true) },
        cmd("text.line.down", "Move Line Down", ["opt+down"], menu: "Edit/Lines", group: 3, aliases: "editor swap") { $0.textEditor?.moveLines(up: false) },
        cmd("text.line.duplicate", "Duplicate Line", ["shift+opt+down"], menu: "Edit/Lines", group: 3, aliases: "editor copy line") { $0.textEditor?.duplicateLines(up: false) },
        cmd("text.line.duplicateUp", "Duplicate Line Up", ["shift+opt+up"], menu: "Edit/Lines", group: 3, aliases: "editor copy line") { $0.textEditor?.duplicateLines(up: true) },
        cmd("text.line.delete", "Delete Line", ["cmd+shift+k"], menu: "Edit/Lines", group: 3, aliases: "editor remove line") { $0.textEditor?.deleteLines() },
        cmd("edit.copyName", "Copy Name", ["cmd+opt+c"], menu: "Edit", group: 1, aliases: "clipboard") {
            $0.copyToPasteboard($0.active.targetPaths.map { ($0 as NSString).lastPathComponent })
        },
        cmd("edit.pasteMove", "Move Here", ["cmd+opt+v"], menu: "Edit", group: 1) { $0.pasteFiles(move: true) },

        // Configuration (~/.config/dfilemanager)
        cmd("app.keymap", "Edit Keymap…", [], menu: "Kermo/Configuration", group: 3, aliases: "shortcuts keys rebind") { $0.editKeymap() },
        cmd("app.config", "Open Config Folder", [], menu: "Kermo/Configuration", group: 4) {
            try? FileManager.default.createDirectory(atPath: Config.dir, withIntermediateDirectories: true)
            $0.active.navigate(to: Config.dir)
        },
        cmd("validators.edit", "Edit Validators…", [], menu: "Kermo/Configuration", group: 3, aliases: "check config server reload") { $0.editValidators() },
        cmd("usermenu.edit", "Edit User Menu…", [], menu: "Kermo/Configuration", group: 3) {
            _ = $0.userCommands()   // writes the example file on first use
            $0.openInEditor(URL(fileURLWithPath: Config.path("usermenu.json")))
        },
        cmd("app.reload", "Reload Config", [], menu: "Kermo/Configuration", group: 4) { $0.applyConfig(reportProblems: true) },
    ] }
}

struct JobErrorMessage: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A trash.json entry: where an item Kermo moved to the Trash came from, and which item it is (its inode, which the
/// move into the Trash keeps). Put Back then never takes another item that has that name in the Trash now (F-12).
/// Entries an older version wrote are the path alone: those go by name, as before. ponytail: an older Kermo can't
/// read the new form (its trash.json then starts empty, copied aside).
struct TrashEntry: Codable, Equatable {
    var origin: String
    var ino: UInt64?

    init(origin: String, ino: UInt64?) { (self.origin, self.ino) = (origin, ino) }
    init(origin: String, at trashed: String) { self.init(origin: origin, ino: Self.inode(trashed)) }
    init(from decoder: Decoder) throws {
        if let path = try? decoder.singleValueContainer().decode(String.self) { self.init(origin: path, ino: nil); return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(origin: try c.decode(String.self, forKey: .origin), ino: try c.decodeIfPresent(UInt64.self, forKey: .ino))
    }

    static func inode(_ path: String) -> UInt64? {
        var st = stat()
        return lstat(path, &st) == 0 ? UInt64(st.st_ino) : nil
    }

    /// The items still the ones recorded (or recorded without an inode, or gone: the move then says so), each to
    /// where it came from (`origin`); and the paths where another item is now. Looks at the disk: off the main thread.
    static func same(_ items: [(from: String, entry: TrashEntry)]) -> (pairs: [(from: String, to: String)], others: [String]) {
        var pairs: [(from: String, to: String)] = [], others: [String] = []
        for (path, e) in items {
            if let ino = e.ino, let now = inode(path), now != ino { others.append(path) } else { pairs.append((path, e.origin)) }
        }
        return (pairs, others)
    }
}
