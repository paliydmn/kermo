import AppKit
import DFMCore

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
    var hidden = false                    // run by a panel itself (↩ on a server's file): not in ⇧⌘P or F1
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
        cmd("go.home", "Home", ["cmd+shift+h"], menu: "Go", group: 2) { $0.active.navigate(to: NSHomeDirectory()) },
        cmd("go.root", "Computer Root", ["cmd+shift+/"], menu: "Go", group: 2, short: "Root") { $0.active.navigate(to: "/") },
        cmd("go.path", "Go to Path…", ["cmd+l", "cmd+shift+g"], menu: "Go", group: 2, aliases: "path location") { $0.active.beginPathEditing() },
        cmd("go.jump", "Jump to Folder…", ["cmd+p"], menu: "Go", group: 2, short: "Jump", aliases: "go to folder recent frecency") { $0.showJump() },
        cmd("go.tree", "Folder Tree…", ["f10", "opt+0", "opt+f10", "cmd+shift+t"], menu: "Go", group: 2, short: "Tree", aliases: "folder tree") { app in
            let panel = app.active
            DirTree.show(in: app.window, over: panel.view, at: panel.path, showHidden: app.defaults.bool(forKey: "showHidden")) { panel.navigate(to: $0) }
        },
        cmd("go.connect", "Connect to Server…", ["ctrl+cmd+k"], menu: "Server", group: 1, short: "Connect", aliases: "sftp ssh smb nfs server remote") { $0.showConnect() },
        cmd("ssh.new", "New SSH Session…", ["cmd+k"], menu: "Server", group: 1, short: "SSH", aliases: "ssh shell remote terminal server") { $0.showConnect(ssh: true) },
        cmd("server.new", "New Server…", [], menu: "Server", group: 1, aliases: "ssh sftp server connection bookmark save") {
            $0.editServer(SavedServer(), title: "New Server")
        },
        cmd("server.services", "Services…", [], menu: "Server", group: 2, aliases: "systemd systemctl service status restart journal journalctl log unit") { $0.showServices() },
        cmd("server.containers", "Containers…", [], menu: "Server", group: 2, aliases: "docker podman container logs restart") { $0.showContainers() },
        cmd("tunnel.list", "Tunnels…", [], menu: "Server/Ports & Tunnels", group: 2, aliases: "port forward localhost database -L") { $0.showTunnels() },
        cmd("tunnel.new", "New Tunnel…", [], menu: "Server/Ports & Tunnels", group: 2, aliases: "port forward localhost database -L") { $0.newTunnel() },
        cmd("tunnel.forward", "Forward Port…", [], menu: "Server/Ports & Tunnels", group: 2, aliases: "ports listening ss netstat tunnel localhost -L") { $0.forwardPort() },
        cmd("ssh.copyKey", "Copy SSH Key to Server…", [], menu: "Server", group: 4, short: "Copy SSH Key", aliases: "ssh-copy-id authorized_keys public key login password") { $0.copyKey() },
        cmd("server.disconnect", "Disconnect", [], menu: "Server", group: 5, short: "Disconnect", aliases: "logout close connection ssh Disconnect Server") { app in
            let t = app.terminalActive ? app.terminal.current?.target : app.active.remote?.target
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
            credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        },
        cmd("app.update", "Check for Updates…", [], menu: "Kermo", group: 2, aliases: "update upgrade new version release") { app in
            app.showMainWindow(nil)   // its answer is a sheet there, also when a viewer is in front
            Task { await app.checkForUpdates(byHand: true) }
        },
        cmd("app.update.auto", "Check for Updates Automatically", [], menu: "Kermo/Configuration", group: 5, aliases: "update daily",
            on: { !$0.defaults.bool(forKey: "updateCheckOff") }) { $0.toggleUpdateChecks() },
        cmd("app.installCLI", "Install “fm” Command", [], menu: "Kermo", group: 3) { $0.installCLI() },
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
        cmd("app.palette", "Search…", ["cmd+shift+p", "f9", "opt+9"], menu: "Go", group: 4, aliases: "palette all commands") { $0.search.focus() },

        // Tabs
        // While the keys go to the terminal (⌃O) these act on its tabs.
        cmd("tab.new", "New Tab", ["cmd+t"], menu: "View/Tabs", group: 2) { app in
            if app.terminalActive { app.terminal.newShell(cwd: app.active.path) } else { app.active.newTab() }
        },
        cmd("tab.close", "Close Tab", ["cmd+w"], menu: "View/Tabs", group: 2) { app in
            if let w = AppDelegate.windowToClose(key: NSApp.keyWindow, main: app.window) { w.performClose(nil) }
            else if app.terminalActive { app.terminal.close() } else { app.active.closeTab() }
        },
        cmd("tab.next", "Next Tab", ["ctrl+tab", "cmd+shift+]"], menu: "View/Tabs", group: 2) { app in
            if app.terminalActive { app.terminal.switchTab(by: 1) } else { app.active.switchTab(by: 1) }
        },
        cmd("tab.prev", "Previous Tab", ["ctrl+shift+tab", "cmd+shift+["], menu: "View/Tabs", group: 2) { app in
            if app.terminalActive { app.terminal.switchTab(by: -1) } else { app.active.switchTab(by: -1) }
        },
        // The terminal's panes (as VS Code's split): while it's up.
        cmd("term.split.right", "Split Terminal Right", ["cmd+\\"], menu: "View/Tabs", group: 3, aliases: "pane side by side") { $0.terminal.split(vertical: true) },
        cmd("term.split.down", "Split Terminal Down", ["cmd+shift+\\"], menu: "View/Tabs", group: 3, aliases: "pane above below") { $0.terminal.split(vertical: false) },
        cmd("term.join", "Join Tab…", [], menu: "View/Tabs", group: 3, aliases: "split merge combine pane terminal") { $0.joinTerminalTab() },
        cmd("term.unsplit", "Move Pane to New Tab", [], menu: "View/Tabs", group: 3, aliases: "unsplit pane terminal") { $0.terminal.unsplit() },
        cmd("term.pane.left", "Focus Pane Left", ["cmd+opt+left"], aliases: "terminal split") { $0.terminal.focusPane(by: -1, vertical: true) },
        cmd("term.pane.right", "Focus Pane Right", ["cmd+opt+right"], aliases: "terminal split") { $0.terminal.focusPane(by: 1, vertical: true) },
        cmd("term.pane.up", "Focus Pane Above", ["cmd+opt+up"], aliases: "terminal split") { $0.terminal.focusPane(by: -1, vertical: false) },
        cmd("term.pane.down", "Focus Pane Below", ["cmd+opt+down"], aliases: "terminal split") { $0.terminal.focusPane(by: 1, vertical: false) },
        cmd("term.resize.left", "Move Pane Divider Left", ["ctrl+cmd+left"], aliases: "terminal split resize") { $0.terminal.resizePane(by: -1, vertical: true) },
        cmd("term.resize.right", "Move Pane Divider Right", ["ctrl+cmd+right"], aliases: "terminal split resize") { $0.terminal.resizePane(by: 1, vertical: true) },
        cmd("term.resize.up", "Move Pane Divider Up", ["ctrl+cmd+up"], aliases: "terminal split resize") { $0.terminal.resizePane(by: -1, vertical: false) },
        cmd("term.resize.down", "Move Pane Divider Down", ["ctrl+cmd+down"], aliases: "terminal split resize") { $0.terminal.resizePane(by: 1, vertical: false) },

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
        cmd("view.filterPresets", "Filter Presets…", ["cmd+/"], menu: "View", group: 3, aliases: "filter glob") { $0.showFilterPresets() },
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
        cmd("view.activity", "Activity", ["cmd+opt+j"], menu: "View", group: 1,
            aliases: "copies transfers operations queue progress history retry failed", on: { $0.ops?.activityShown == true }) { $0.ops.toggleActivity() },
        cmd("term.bigger", "Bigger Terminal Text", ["cmd+=", "cmd+shift+="], menu: "View", group: 4, aliases: "font size zoom in larger") { app in
            if app.terminal.isShown { app.terminal.zoom(by: 1) } else { NSSound.beep() }
        },
        cmd("term.smaller", "Smaller Terminal Text", ["cmd+-"], menu: "View", group: 4, aliases: "font size zoom out") { app in
            if app.terminal.isShown { app.terminal.zoom(by: -1) } else { NSSound.beep() }
        },
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
        cmd("panel.sync", "Synchronize Folders…", ["cmd+shift+s"], menu: "Mark", group: 2, short: "Synchronize", aliases: "synchronize mirror folders") { app in
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
        cmd("file.diff", "Compare Files", ["cmd+shift+d"], menu: "Mark", group: 2, short: "Compare", aliases: "compare files Compare Files (diff)") { $0.diffFiles() },   // not ⌘⌥D: macOS takes it (Dock hiding)
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
        cmd("admin.userPanel", "Reopen as User", ["ctrl+shift+cmd+r"], menu: "Server", group: 3, short: "As User", aliases: "root sudo server user Reopen Panel as User") { $0.reopenPanel(asRoot: false) },
        cmd("admin.sudoTouchID", "Enable Touch ID for sudo", [], menu: "File/As Administrator", group: 9, aliases: "touch id fingerprint sudo terminal pam tid password") {
            $0.enableSudoTouchID()
        },
        cmd("admin.auditLog", "Production Log", [], menu: "Server", group: 5, aliases: "audit journal prod history Show Production Log") { $0.showAuditLog() },
        cmd("server.runOn", "Run on Servers…", [], menu: "Server", group: 4, aliases: "ssh command several many all servers parallel pssh") {
            $0.runOnServers()
        },

        // Clipboard
        cmd("edit.copyPath", "Copy Path", ["cmd+shift+c"], menu: "Edit", group: 1, aliases: "path clipboard") { $0.copyToPasteboard($0.active.targetPaths) },
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

    // MARK: - Finder tags

    /// Like Finder: if the first item has the color, it's removed from all; otherwise added to all.
    func toggleTag(_ color: Int) {
        let name = NSWorkspace.shared.fileLabels[color]
        applyTags(active.targetURLs) { tags, first in
            tags.filter { $0.color != color } + (first.contains { $0.color == color } ? [] : [.init(name: name, color: color)])
        }
    }

    func tagsDialog() {
        let urls = active.targetURLs
        guard let first = urls.first else { return NSSound.beep() }
        let colors = NSWorkspace.shared.fileLabels
        Task {
            let current = await Blocking.run(.userInitiated) { FinderTags.read(first.path) }
            guard let text = await prompt("Tags for \(Self.describe(urls)):", value: current.map(\.name).joined(separator: ", "), ok: "Set",
                                          info: "Comma-separated; \(colors.dropFirst().joined(separator: ", ")) get their color. ⌃1…⌃7 toggle colors, ⌃0 removes all.")
            else { return }
            let tags = FinderTags.parse(text, existing: current, colorNames: colors)
            applyTags(urls) { _, _ in tags }
            // Custom (non-color) tags become sidebar rows.
            let custom = tags.map(\.name).filter { !colors.contains($0) }
            let recent = custom + (defaults.stringArray(forKey: "recentTags") ?? []).filter { !custom.contains($0) }
            defaults.set(Array(recent.prefix(10)), forKey: "recentTags")
            refreshSidebar()
        }
    }

    /// `change` gets each item's tags and the first item's (a toggle follows the first, as in Finder).
    func applyTags(_ urls: [URL], _ change: @escaping @Sendable (_ tags: [FinderTags.Tag], _ first: [FinderTags.Tag]) -> [FinderTags.Tag]) {
        guard !urls.isEmpty else { return NSSound.beep() }
        let panel = active
        Task {
            let failed = await Blocking.run(.userInitiated) { Self.setTags(urls, change) }
            if !failed.isEmpty {
                showError(JobErrorMessage("Tags not set on \(failed.count) of \(urls.count):\n" + failed.prefix(10).joined(separator: "\n")))
            }
            panel.reload()   // xattr changes don't trigger the folder watcher
        }
    }

    /// Writes each item's new tags, on past one that refuses: a line for each that did. Off the main thread (a share
    /// that stopped answering).
    nonisolated static func setTags(_ urls: [URL], _ change: ([FinderTags.Tag], [FinderTags.Tag]) -> [FinderTags.Tag]) -> [String] {
        let first = urls.first.map { FinderTags.read($0.path) } ?? []
        return urls.compactMap { u in
            do { try FinderTags.write(u.path, change(FinderTags.read(u.path), first)); return nil }
            catch { return "“\(u.lastPathComponent)”: \(error.localizedDescription)" }
        }
    }

    /// The server panel's folder again as root (its sudo there: `SFTPTarget.sudo`), or as its user. Only ever on purpose:
    /// nothing pasted, dropped or restored opens one as root (a restored root tab is parked: ↩ there connects). A locked server asks as for any connection.
    func reopenPanel(asRoot: Bool) {
        let panel = active
        if let p = panel.parked { return panel.connectParked(p.target.asRoot(asRoot)) }   // a restored tab: connects so
        guard let r = panel.remote else { return panel.flash("Reopen as \(asRoot ? "Root" : "User") is for a server's panel: connect first (⌃⌘K)") }
        guard r.target.sudo != asRoot else { return panel.flash(asRoot ? "This panel is root already — ⌃⇧⌘R reopens it as the user" : "This panel is its user's already — ⌃⌘R reopens it as root") }
        panel.loadRemote(r.target.asRoot(asRoot), dir: r.dir, select: panel.currentName)
    }

    /// Where Enable Touch ID for sudo reads sudo_local and its template (tests: a copy), and what runs its write as root
    /// (tests: a stand-in — the real one asks for the password and writes /etc/pam.d).
    static var pamDir = "/etc/pam.d"
    static var runAsAdmin: (String) async -> Admin.Outcome = Admin.run

    /// File ▸ As Administrator ▸ Enable Touch ID for sudo: pam_tid in /etc/pam.d/sudo_local, after a question and macOS's password.
    func enableSudoTouchID() {
        let dir = Self.pamDir, panel = active
        Task {
            let read = await Blocking.run(.userInitiated) { () -> Result<(String?, String?, Bool), Error> in
                Result {
                    let file = dir + "/sudo_local"
                    var st = stat()
                    let there = lstat(file, &st) == 0, link = there && st.st_mode & S_IFMT == S_IFLNK   // the write refuses a link
                    let current = there && !link ? try String(contentsOfFile: file, encoding: .utf8) : nil
                    return (current, try? String(contentsOfFile: dir + "/sudo_local.template", encoding: .utf8), link)
                }
            }
            guard case .success(let (current, template, link)) = read else {   // there but not readable: never written over
                return panel.flash("Can't read \(dir)/sudo_local", error: true)
            }
            if link { return panel.flash("\(dir)/sudo_local is a symlink, kept by something else: Kermo leaves it alone", error: true) }
            if SudoTouchID.state(current) == .on { return panel.flash("Touch ID for sudo is already on") }
            guard current != nil || template != nil else {
                return panel.flash("No \(dir)/sudo_local.template on this Mac: Touch ID for sudo needs macOS 14 or later", error: true)
            }
            let text = SudoTouchID.enabled(current, template: template ?? ""), command = SudoTouchID.command(writing: text)
            var c = Confirm("Let sudo in Terminal use Touch ID?", action: "Enable")
            (c.chips, c.place, c.runs, c.command) = ([.root], "this Mac", Self.asAdmin, command)
            c.note = "It writes \(SudoTouchID.file), which survives macOS updates."
            guard await confirm(c) == 0 else { return }
            switch await Self.runAsAdmin(command) {
            case .ok:
                let now = await Blocking.run(.userInitiated) { try? String(contentsOfFile: dir + "/sudo_local", encoding: .utf8) }
                if now == text { panel.flash("Touch ID for sudo is on — new Terminal windows use it") }
                else { panel.flash("Touch ID for sudo didn't turn on: \(dir)/sudo_local isn't what Kermo wrote", error: true) }
            case .cancelled: break
            case .failed(let msg): panel.flash("Couldn't turn on Touch ID for sudo: \(msg)", error: true)
            }
        }
    }

    /// Symlinks the bundled `fm` script into /usr/local/bin (asks for a password if that folder is root's).
    func installCLI() {
        guard let script = Bundle.main.path(forResource: "fm", ofType: nil) else {
            return showError(JobErrorMessage("“fm” isn't in the app bundle — build the app with ./build.sh."))
        }
        let link = "/usr/local/bin/fm"
        var st = stat()
        if lstat(link, &st) == 0 && st.st_mode & S_IFMT != S_IFLNK {
            return showError(JobErrorMessage("\(link) already exists and isn't a link — not replacing it."))
        }
        try? FileManager.default.removeItem(atPath: link)   // an older link (e.g. the app moved)
        if (try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: script)) != nil {
            return active.flash("Installed \(link) — try “fm .” in a terminal")
        }
        Task { await runAdmin("Install fm", "mkdir -p /usr/local/bin && ln -sfn \(ShellContext.quote(script)) \(link)") }
    }

    // MARK: - Shell: command line and user menu

    struct UserCommand: Codable {
        var title: String
        var command: String
        var terminal: Bool?
        var server: Bool?   // true: only on a server panel (systemctl), false: only on this Mac, nil: both
    }

    /// The user menu's commands for this panel: a server's, or this Mac's. On a server, an entry without "server" that
    /// calls a tool only this Mac has isn't offered, and the built-in service entries follow the user's own (an older
    /// usermenu.json never got them) unless the file has them.
    static func userCommands(_ all: [UserCommand], onServer: Bool) -> [UserCommand] {
        guard onServer else { return all.filter { $0.server != true } }
        let mine = all.filter { $0.server ?? !macOnly($0.command) }
        return mine + serverCommands.filter { b in !mine.contains { $0.command == b.command || $0.title == b.title } }
    }

    /// I10: on a server panel, put the cursor on a unit (/etc/systemd/system/nginx.service) or type its name in ⌘E.
    static let serverCommands = [
        UserCommand(title: "Service status", command: "systemctl status --no-pager %f", server: true),
        UserCommand(title: "Restart service", command: "sudo systemctl restart %f && systemctl status --no-pager %f", terminal: true, server: true),
        UserCommand(title: "Failed services", command: "systemctl --failed --no-pager", server: true),
        UserCommand(title: "Service log (last 200 lines)", command: "journalctl -u %f -n 200 --no-pager", server: true),
    ]

    private static let macTools = try! NSRegularExpression(pattern:
        #"(?:^|[;&|(`]|\s)(?:xattr|open|mdfind|mdls|pbcopy|pbpaste|osascript|qlmanage|diskutil|launchctl|defaults|say)(?=\s|$|[;&|)])|\btop\s+-o\b"#)
    /// The command calls a tool only this Mac has (xattr, open, mdfind, top -o …).
    static func macOnly(_ command: String) -> Bool {
        macTools.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    func userCommands() -> [UserCommand] {
        do {
            if let cmds = try Config.load("usermenu.json", as: [UserCommand].self) { return cmds }
        } catch {
            showError(JobErrorMessage("usermenu.json: \(error.localizedDescription)"))
            return []
        }
        let examples = [
            UserCommand(title: "Disk usage", command: "du -sh %S"),
            UserCommand(title: "Remove quarantine", command: "xattr -dr com.apple.quarantine %S"),
            UserCommand(title: "Make executable", command: "chmod +x %S"),
            UserCommand(title: "SHA-256", command: "shasum -a 256 %S"),
            UserCommand(title: "Git status", command: "git -C %d status"),
            UserCommand(title: "Git log", command: "git -C %d log --oneline --graph -30"),
            UserCommand(title: "Archive to .tar.gz", command: "tar czf archive-$(date +%%Y%%m%%d-%%H%%M%%S).tar.gz %s"),
            UserCommand(title: "Listening ports", command: "lsof -nP -iTCP -sTCP:LISTEN"),
            UserCommand(title: "Edit as root (vim)", command: "sudo vim %F", terminal: true),
            UserCommand(title: "top by memory", command: "top -o mem", terminal: true),
        ] + Self.serverCommands
        Config.save("usermenu.json", examples)
        return examples
    }

    /// ~/.config/dfilemanager/validators.json: the user's own checks for server files, looked at before the built-in ones.
    /// The first time, an example — not the built-in rules (copied there, they'd never get Kermo's changes to them).
    func editValidators() {
        let path = Self.validatorsPath
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: Config.dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data(Self.validatorsExample.utf8), attributes: [.posixPermissions: 0o600])
        }
        openInEditor(URL(fileURLWithPath: path))
    }

    /// Tests: a file of their own.
    static var validatorsPath = Config.path("validators.json")

    static let validatorsExample = """
        [
          {
            "match": "/etc/caddy/Caddyfile",
            "check": "caddy validate --adapter caddyfile --config %f",
            "reload": "systemctl reload caddy"
          },
          {
            "match": "/etc/prometheus/prometheus.yml",
            "check": "promtool check config %f",
            "reload": "systemctl reload prometheus"
          }
        ]

        """

    /// ~/.config/dfilemanager/audit.jsonl in the viewer (`AuditLog`).
    func showAuditLog() {
        guard FileManager.default.fileExists(atPath: AuditLog.path) else {
            return active.flash("No production log yet: saves, commands, copies, deletes and reloads on a production server go there")
        }
        Viewer.show(URL(fileURLWithPath: AuditLog.path))
    }

    func showUserMenu() {
        let mine = userCommands()
        let items = Self.userCommands(mine, onServer: active.remote != nil).map { c in
            let builtIn = !mine.contains { $0.command == c.command && $0.title == c.title }   // a server entry the file doesn't have
            return Picker.Item(title: c.title, subtitle: c.command,
                               detail: ([c.terminal == true ? "Terminal" : nil, builtIn ? "built in" : nil].compactMap { $0 }).joined(separator: " · "), verb: "Run") { [unowned self] in
                runShell(c.command, in: c.terminal == true ? .terminalApp : .shell)
            }
        } + [Picker.Item(title: "Edit User Menu…", subtitle: "~/.config/dfilemanager/usermenu.json", verb: "Edit") { [unowned self] in run("usermenu.edit") }]
        Picker.show(over: window, placeholder: "Filter commands", hints: [Self.commandLineKeys.last!], items: items)
    }

    /// The active panel's folder and names — a server's, on a server panel (never the local folder hidden behind it).
    var shellContext: ShellContext {
        if let r = active.remote {
            return ShellContext(dir: r.dir, otherDir: other.remote?.target.asUser == r.target.asUser ? other.remote?.dir : nil,
                                cursor: active.remoteCursor?.item.name, targets: active.remoteSelection?.items.map(\.name) ?? [])
        }
        let dir = active.itemsDir
        return ShellContext(dir: dir, otherDir: other.remote == nil && other.parked == nil ? other.path : nil, cursor: active.cursorURL.map { Self.name($0, in: dir) },
                            targets: active.targetURLs.map { Self.name($0, in: dir) })
    }

    /// `url` as named from `dir`: a search hit or a Git change is `sub/x.conf` there — its last component alone named
    /// a file of the same name in `dir` itself, and %s / ⌥F5 acted on that one.
    static func name(_ url: URL, in dir: String) -> String {
        let base = dir.hasSuffix("/") ? dir : dir + "/"
        return url.path.hasPrefix(base) && url.path.count > base.count ? String(url.path.dropFirst(base.count)) : url.lastPathComponent
    }

    /// Where ⌘E / F2 run a command on a local panel: the ⌃O shell (↩, F2 entries), an output window (⇧↩), the terminal
    /// app (⌘↩, `"terminal": true`). On a server panel `.shell` is the output window too (the remote shell's state
    /// can't be seen, so a typed line could land in a program there).
    enum ShellWhere { case shell, window, terminalApp }

    /// ⌘E and the user menu (F2). On a server panel the command runs on the server, in its folder.
    func runShell(_ command: String, in dest: ShellWhere) {
        guard let expanded = shellContext.expand(command) else { return active.flash("%D: the other panel is on another machine") }
        if let r = active.remote {
            let env = SSHAskpass.env
            Task { [self] in
                // R1: rm, mv, chmod, chown, dd, systemctl stop/restart on a production server ask first.
                if SavedServer.isProd(r.target), Shell.isDangerous(expanded) {
                    var c = Confirm("Run this command on \(SavedServer.name(for: r.target))?", on: r.target, action: "Run")
                    c.runs = "In \(r.dir)" + (r.target.sudo ? ", as the server's user — not root." : ".")
                    c.command = dest == .terminalApp ? SSHCommand.shell(in: r.dir, after: expanded) : Shell.remote(expanded, in: r.dir, follow: false)
                    guard await confirm(c) == 0 else { return }
                }
                if dest == .terminalApp {
                    AuditLog.write(r.target.asUser, "command", paths: [r.dir], command: expanded, exit: nil)   // its end is the terminal's; as the user, root panel or not
                    return openSSH(r.target, command: SSHCommand.shell(in: r.dir, after: expanded))
                }
                let login = await Blocking.run { Result { try SFTP.startMaster(r.target, env: env) } }
                if case .failure(let e) = login { return showError(e) }
                Shell.run(expanded, on: r.target, in: r.dir) { [weak self] status in
                    AuditLog.write(r.target.asUser, "command", paths: [r.dir], command: expanded, exit: status)   // ran as the user (ssh)
                    for p in self?.panels ?? [] where p.remote?.target.asUser == r.target.asUser { p.reload() }
                }
            }
            return
        }
        switch dest {
        case .terminalApp:
            guard let app = terminalAppURL() else { return NSSound.beep() }
            Shell.runInTerminal(expanded, in: active.itemsDir, terminalApp: app)
        case .window:
            Shell.run(expanded, in: active.itemsDir) { [weak self] _ in self?.panels.forEach { $0.reload() } }
        case .shell:   // the panels reload when the terminal hides (toggleTerminal): the shell's command ends when it ends
            guard let v = terminal.run(expanded, cwd: active.itemsDir) else {
                return active.flash("A control character in a name — ⇧↩ Output Window runs it", error: true)
            }
            window.makeFirstResponder(v)
        }
    }

    func terminalAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: defaults.string(forKey: "terminalBundleID") ?? "com.apple.Terminal")
    }

    // MARK: - Jump, bookmarks

    private static let star = Symbol.star.image("Favorite")

    /// Bookmarks first, then folders by frecency. Typing an existing path offers to go there directly.
    func showJump() {
        func item(_ p: String, star: Bool) -> Picker.Item {
            Picker.Item(title: Bookmark.title(p), subtitle: (p as NSString).abbreviatingWithTildeInPath, badges: star ? [Self.star] : [], verb: "Go") { [unowned self] in jump(to: p) }
        }
        let items = bookmarks.map { item($0, star: true) }
            + frecency.ranked().filter { !bookmarks.contains($0) && $0 != active.path }.prefix(500).map { item($0, star: false) }
        Picker.show(over: window, placeholder: "Folder", empty: "No bookmarks or recent folders yet", items: items) { it, q in
            // Prefer hits in the folder name itself over hits spread across the path.
            guard let s = Fuzzy.score(q, it.subtitle) else { return nil }
            return s + (Fuzzy.score(q, it.title) != nil ? 500 : 0)
        }
    }

    private func jump(to p: String) {
        if let r = Bookmark.remote(p) { return openBookmark(r) }
        let panel = active
        Task {
            guard let why = await Blocking.run(.userInitiated, { Self.whyNotThere(p) }) else { return panel.navigate(to: p) }
            NSSound.beep()
            panel.flash(why.message, error: true)
            if why.gone { forget([p]) }
        }
    }

    /// Why ⌘P can't go to `p` (nil: it can): a disk that isn't connected keeps its places, a folder that's gone
    /// leaves Favorites and Frequent. Touches the disk: off the main thread.
    nonisolated static func whyNotThere(_ p: String) -> (message: String, gone: Bool)? {
        var isDir: ObjCBool = false
        let short = (p as NSString).abbreviatingWithTildeInPath
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) { return isDir.boolValue ? nil : ("Not a folder: " + short, false) }
        if Frecency.isGone(p) { return ("No such folder: " + short, true) }
        let parts = p.split(separator: "/")
        if parts.count > 1, parts[0] == "Volumes" { return ("“\(parts[1])” isn't connected", false) }
        return ("Can't open \(short)", false)
    }

    /// Those of `paths` that are gone (`Frecency.isGone`, checked off the main thread: a share that stopped
    /// answering) leave Favorites and Frequent.
    func forgetGone(_ paths: [String]) {
        Task {
            let gone = await Blocking.run { paths.filter(Frecency.isGone) }
            forget(gone)
        }
    }

    /// Folders that are gone leave Favorites and Frequent, with what was under them; saved at once, so they don't
    /// come back with the next launch.
    func forget(_ gone: [String]) {
        let left = bookmarks.filter { b in !gone.contains { Frecency.isUnder(b, $0) } }, count = frecency.entries.count
        gone.forEach { frecency.remove(under: $0) }
        guard left.count < bookmarks.count || frecency.entries.count < count else { return }
        bookmarks = left
        Config.save("bookmarks.json", bookmarks)
        Config.save("frecency.json", frecency)
        refreshSidebar()
    }

    /// A Favorite on a server: the server, right in that folder — as its saved server if there's one (key, lock).
    func openBookmark(_ r: (target: SFTPTarget, dir: String), newTab: Bool = false, panel: PanelViewController? = nil) {
        let saved = savedServers.first { ServerRow.key($0.target) == ServerRow.key(r.target) }
        openServer(ServerRow(target: saved?.target ?? r.target, saved: saved, title: saved?.title ?? r.target.host), .sftp,
                   newTab: newTab, panel: panel, dir: r.dir)
    }

    /// ⌘D: this folder — on a server, that server's folder — in Favorites, or out again.
    /// What ⌘D bookmarks for a panel: what its header says.
    func bookmarkEntry(_ panel: PanelViewController) -> String {
        (panel.remote ?? panel.parked).map { Bookmark.entry($0.target, $0.dir) } ?? panel.path
    }

    func toggleBookmark() {
        let p = bookmarkEntry(active)
        if let i = bookmarks.firstIndex(of: p) {
            bookmarks.remove(at: i)
            active.flash("Removed bookmark")
        } else {
            bookmarks.append(p)
            active.flash("Bookmarked — ⌘P Jump to Folder")
        }
        Config.save("bookmarks.json", bookmarks)
        refreshSidebar()
    }

    /// Writes the current bindings to keymap.json (if it doesn't exist yet) and opens it.
    func editKeymap() {
        let path = Config.path("keymap.json")
        if !FileManager.default.fileExists(atPath: path) {
            let all = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0.keys.map(\.spec)) })
            Config.save("keymap.json", all)
        }
        openInEditor(URL(fileURLWithPath: path))
    }

    // MARK: - Implementations

    func swapPanels() {
        if !Self.swap(active, other) { NSSound.beep(); active.flash("⌘U Swap Panels works on folders — not an archive or search results") }
    }

    /// Each panel to where the other is: a server folder too (not the local one hidden behind its tab). False for an
    /// archive or search results.
    static func swap(_ a: PanelViewController, _ b: PanelViewController) -> Bool {
        guard a.archive == nil, b.archive == nil, a.searchTitle == nil, b.searchTitle == nil else { return false }
        let (x, y) = (a.remote, b.remote)
        let (pa, pb) = (a.path, b.path)
        if let y { a.loadRemote(y.target, dir: y.dir, select: nil) } else { a.navigate(to: pb, history: x == nil ? .push : .none) }
        if let x { b.loadRemote(x.target, dir: x.dir, select: nil) } else { b.navigate(to: pa, history: y == nil ? .push : .none) }
        return true
    }

    /// The highlighted theme shows at once; ⎋ goes back to the one in use.
    func showThemes() {
        let was = Theme.current.name
        let use = { [unowned self] (name: String) in   // ponytail: a preview goes to defaults too; a crash mid-preview keeps it
            defaults.set(name, forKey: "theme")
            applyTheme()
        }
        let items = Theme.all.map { t in
            Picker.Item(title: t.name, detail: t.name == was ? "current" : "", verb: "Use", preview: { use(t.name) }) { use(t.name) }
        }
        Picker.show(over: window, placeholder: "Theme", items: items, selected: Theme.all.firstIndex { $0.name == was } ?? 0) { use(was) }
    }


    struct FilterPreset: Codable {
        var title: String
        var filter: String
    }

    func filterPresets() -> [FilterPreset] {
        do {
            if let p = try Config.load("filters.json", as: [FilterPreset].self) { return p }
        } catch {
            showError(JobErrorMessage("filters.json: \(error.localizedDescription)"))
            return []
        }
        let examples = [
            FilterPreset(title: "Logs", filter: "*.log;*.log.*;*.out;*.err"),
            FilterPreset(title: "Configs", filter: "*.conf;*.cfg;*.ini;*.toml;*.yml;*.yaml;*.json;*.plist"),
            FilterPreset(title: "Scripts", filter: "*.sh;*.zsh;*.bash;*.command;*.py"),
            FilterPreset(title: "Images", filter: "re:\\.(jpe?g|png|heic|gif|tiff?|webp)$"),
            FilterPreset(title: "Archives & disk images", filter: "*.zip;*.tar;*.gz;*.tgz;*.xz;*.7z;*.dmg;*.iso;*.pkg"),
            FilterPreset(title: "Launchd jobs", filter: "*.plist"),
        ]
        Config.save("filters.json", examples)
        return examples
    }

    /// Saved presets (filters.json), then recent filters; typing a new one applies it.
    func showFilterPresets() {
        let panel = active
        let saved = filterPresets()
        let recent = (defaults.stringArray(forKey: "recentFilters") ?? []).filter { r in !saved.contains { $0.filter == r } }
        let items = saved.map { p in Picker.Item(title: p.title, subtitle: p.filter, detail: "preset", verb: "Filter") { panel.applyFilter(p.filter) } }
            + recent.map { r in Picker.Item(title: r, detail: "recent", verb: "Filter") { panel.applyFilter(r) } }
            + [Picker.Item(title: "Edit Filter Presets…", subtitle: "~/.config/dfilemanager/filters.json", verb: "Edit") { [unowned self] in run("view.filterPresets.edit") }]
        Picker.show(over: window, placeholder: "Filter or preset", items: items, freeText: { q in
            q.isEmpty ? [] : [Picker.Item(title: "Filter: \(q)", verb: "Filter") { panel.applyFilter(q) }]
        })
    }

    func toggleHidden() {
        let on = !defaults.bool(forKey: "showHidden")
        defaults.set(on, forKey: "showHidden")
        panels.forEach { $0.showHidden = on }
    }

    func togglePerms() {
        let on = !defaults.bool(forKey: "showPerms")
        defaults.set(on, forKey: "showPerms")
        panels.forEach { $0.showPerms = on }
    }

    func toggleGitOnly() {
        active.gitOnly.toggle()
        if active.gitOnly && !active.inGitRepo { active.flash("Not a git work tree — showing everything") }
    }

    func maskDialog(mark: Bool) {
        Task {
            let last = defaults.string(forKey: "lastMask") ?? "*"
            guard let spec = await prompt(mark ? "Mark files matching:" : "Unmark files matching:", value: last, ok: mark ? "Mark" : "Unmark",
                                          info: "Globs separated by “;” (*.log; *.txt) or a regex as re:^v\\d+")
            else { return }
            guard let mask = Mask(spec) else { return showError(JobErrorMessage("Invalid mask “\(spec)”")) }
            defaults.set(spec, forKey: "lastMask")
            active.mark(matching: mask, mark)
        }
    }

    func viewFile() {
        if active.remote != nil { return remoteOpen(.view) }
        if active.archive != nil { return openFromArchive(view: true) }
        guard let url = active.cursorURL, !url.hasDirectoryPath else { return NSSound.beep() }
        Viewer.show(url)
    }

    func editFile() {
        if active.remote != nil { return remoteOpen(.edit) }
        guard let url = active.cursorURL, !url.hasDirectoryPath else { return NSSound.beep() }
        openInEditor(url)
    }

    /// Built-in editor, unless `defaults write com.dmn.dfilemanager editorBundleID <id>` picks an external app.
    func openInEditor(_ url: URL) {
        Config.flush()   // a config file just saved (keymap.json's first one) is there for the editor
        let ws = NSWorkspace.shared
        if let app = defaults.string(forKey: "editorBundleID").flatMap(ws.urlForApplication(withBundleIdentifier:)) {
            ws.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            Editor.open(url)
        }
    }

    // MARK: - Search (⌘F / ⌥F7): results replace the panel listing, ⌫ returns

    /// `name` prefills the name field (toolbar search's "Search … on disk").
    func searchDialog(name prefill: String? = nil) {
        if let hint = active.parkedHint { return active.flash(hint) }   // ⇧⌘P's "on disk" comes here directly
        if let prefill { defaults.set(prefill, forKey: "searchName") }
        let name = NSTextField(string: defaults.string(forKey: "searchName") ?? "")
        name.placeholderString = "name: text, *.glob;*.glob or re:regex — empty = any"
        let text = NSTextField(string: defaults.string(forKey: "searchText") ?? "")
        text.placeholderString = "containing text (optional)"
        let caseBox = NSButton(checkboxWithTitle: "Case-sensitive text", target: nil, action: nil)
        let hiddenBox = NSButton(checkboxWithTitle: "Include hidden files and folders", target: nil, action: nil)
        let tag = NSTextField(string: defaults.string(forKey: "searchTag") ?? "")
        tag.placeholderString = "with Finder tag (optional)"
        let spotBox = NSButton(checkboxWithTitle: "Use Spotlight index (fast, skips what Spotlight doesn't index)", target: nil, action: nil)
        caseBox.state = defaults.bool(forKey: "searchCase") ? .on : .off
        hiddenBox.state = defaults.bool(forKey: "searchHidden") ? .on : .off
        spotBox.state = defaults.bool(forKey: "searchSpotlight") ? .on : .off
        let remote = active.remote
        tag.isHidden = remote != nil   // on a server: find and grep there, no tags or Spotlight
        spotBox.isHidden = remote != nil
        let form = NSStackView(views: [name, text, tag, caseBox, hiddenBox, spotBox])
        form.orientation = .vertical
        form.alignment = .leading
        for f in [name, text, tag] { f.widthAnchor.constraint(equalToConstant: 440).isActive = true }
        form.setFrameSize(form.fittingSize)   // a server's has no tag or Spotlight rows: no empty strip in their place

        let alert = NSAlert()
        alert.messageText = "Search in " + DirSync.place(active.endpoint, active.currentDir)
        alert.addButton(withTitle: "Search")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = form
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [unowned self] r in
            window.makeFirstResponder(active.table)
            guard r == .alertFirstButtonReturn else { return }
            var q = SearchQuery(root: remote?.dir ?? active.path)
            q.name = name.stringValue.trimmingCharacters(in: .whitespaces)
            q.contains = text.stringValue
            q.caseSensitive = caseBox.state == .on
            q.includeHidden = hiddenBox.state == .on
            q.spotlight = spotBox.state == .on
            q.tag = tag.stringValue.trimmingCharacters(in: .whitespaces)
            defaults.set(q.tag, forKey: "searchTag")
            defaults.set(q.name, forKey: "searchName")
            defaults.set(q.contains, forKey: "searchText")
            defaults.set(q.caseSensitive, forKey: "searchCase")
            defaults.set(q.includeHidden, forKey: "searchHidden")
            defaults.set(q.spotlight, forKey: "searchSpotlight")
            if remote != nil { (q.spotlight, q.tag) = (false, "") }
            if q.name.isEmpty && q.contains.isEmpty { q.name = "*" }
            runSearch(q)
        }
    }

    /// Sidebar tag: every file with it under the home folder, via Spotlight.
    func searchTag(_ name: String) {
        // Spotlight and Finder tags are this Mac's: a server panel would run it there, in a folder named like ~.
        guard active.remote == nil else { NSSound.beep(); return active.flash("Finder tags are on this Mac — search them from a local panel") }
        var q = SearchQuery(root: NSHomeDirectory())
        q.tag = name
        q.spotlight = true
        runSearch(q)
    }

    private func runSearch(_ q: SearchQuery) {
        let panel = active
        if let t = panel.remote?.target, ServerLock.needsUnlock(t) {   // unlocked, it no longer needs it: runs below
            Task { if await unlock([.sftp(t)]) { runSearch(q) } }
            return
        }
        var title = q.name.isEmpty ? "*" : q.name
        if !q.contains.isEmpty { title += " containing “\(q.contains)”" }
        if !q.tag.isEmpty { title += " tagged “\(q.tag)”" }
        let server = panel.remote?.target, env = SSHAskpass.env   // a server panel searches there
        let flag = panel.beginSearch(title, in: DirSync.place(server.map(Endpoint.sftp) ?? .local, q.root), root: server == nil ? q.root : nil)
        DispatchQueue.global(qos: .userInitiated).async {
            var batch: [FileItem] = []
            var lastFlush = Date()
            func flush() {
                let items = batch
                batch = []
                lastFlush = Date()
                DispatchQueue.main.async { MainActor.assumeIsolated { panel.addSearchResults(items, from: flag) } }
            }
            func add(_ item: FileItem) {
                batch.append(item)
                if batch.count >= 500 || Date().timeIntervalSince(lastFlush) > 0.25 { flush() }
            }
            var note: String?, failed = false
            if let server {
                do { try FileSearch.runRemote(q, on: server, env: env, cancel: flag, onMatch: add) } catch {
                    if !(error is CancellationError) { (note, failed) = (error.localizedDescription, true) }
                }
            } else {
                let skipped = FileSearch.run(q, isCancelled: { flag.isCancelled }, onMatch: add)
                if skipped > 0 { note = "\(skipped) file\(skipped == 1 ? "" : "s") not downloaded (iCloud / Dropbox): not searched" }
            }
            flush()
            DispatchQueue.main.async { [note, failed] in MainActor.assumeIsolated { panel.finishSearch(flag, note: note, error: failed) } }
        }
    }

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
            s.tunnels = savedServers.first { $0.id == s.id }?.tunnels ?? s.tunnels   // as they are now, not when the sheet opened
            guard s.issue == nil else { return NSSound.beep() }   // its buttons were off
            let old = savedServers.first { $0.id == s.id }
            if let i = savedServers.firstIndex(where: { $0.id == s.id }) { savedServers[i] = s } else { savedServers.append(s) }
            Config.save("servers.json", savedServers)
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
            savedServers.removeAll { $0.id == s.id }
            Config.save("servers.json", savedServers)
            forgetPassword(s)
            unpin(ServerRow.key(s.target))   // else it'd stay as a pinned bare address
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
    func remoteOpen(_ how: RemoteOpen, _ target: SFTPTarget, _ remotePath: String, listed: (Int64, Double)? = nil, in panel: PanelViewController) {
        let name = (remotePath as NSString).lastPathComponent
        let tmp = NSTemporaryDirectory() + "dfm-sftp-" + UUID().uuidString
        mkdir(tmp, 0o700)
        let local = URL(fileURLWithPath: tmp).appendingPathComponent(name)
        let env = SSHAskpass.env
        // F3 on a big log: its tail.
        let last = how == .view ? Viewer.tailLimit(for: name) : nil
        Task {
            let r = await panel.busy("Downloading “\(name)”…") { flag in
                try SFTPClient.session(target, env: env, cancel: flag) { try $0.download(remotePath, to: local.path, last: last) }
            }
            guard case .success(let opened) = r else {
                TempCopies.remove(tmp)
                if case .failure(let e) = r, !(e is CancellationError) { showError(e) }
                return
            }
            switch how {
            case .open:   // another app: its saves go up as F4's do
                FileInfo.quarantine(local.path)
                ServerCopies.add(.init(local, target, remotePath, listed: listed ?? (opened.size, opened.mtime), baseline: opened, preview: false))
                Self.openInApp(local)
            case .view: Viewer.show(local, remote: (target, remotePath, max(0, opened.size - (last ?? opened.size)))) { TempCopies.remove(tmp) }
            case .edit:
                let state = RemoteEdit(baseline: opened)
                let note = Self.rootsOnly(opened, for: target) ? "“\(name)” is root's: saving it needs the panel as root (⌃⌘R)" : nil
                Editor.open(local, remote: SavedServer.title(target, remotePath), server: (target, remotePath, state), note: note, onSaved: { [self] saved in
                    state.save(in: tmp) { await self.upload(saved, to: remotePath, on: target, state) }
                }, onClose: { state.closed(removing: tmp) })
            }
        }
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
        init(baseline: SFTPClient.Attrs) { self.baseline = baseline }

        /// A save goes up after the ones before it. Until it's on the server, and no later save waits, the copy is
        /// marked kept: quitting mid-upload must not leave the only copy of that text to the launch sweep.
        func save(in dir: String, _ send: @escaping @MainActor () async -> Bool) {
            TempCopies.keep(dir)
            saves += 1
            Self.uploading += 1
            let previous = upload, n = saves
            upload = Task {
                defer { Self.uploading -= 1 }
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
    func upload(_ saved: URL, to remotePath: String, on target: SFTPTarget, _ state: RemoteEdit, force: Bool = false, action: String = "save") async -> Bool {
        // One save to a server file at a time, from any editor, copy or revert: two at once each passed the check
        // against the same version, and the last rename won — the other's text gone, unasked. The later one now
        // checks against what the earlier wrote, and asks.
        let key = ServerRow.key(target.asUser) + ":" + remotePath, before = Self.uploads[key]
        let mine = Task { @MainActor in
            _ = await before?.value
            return await uploadNow(saved, to: remotePath, on: target, state, force: force, action: action)
        }
        Self.uploads[key] = mine
        let ok = await mine.value
        if Self.uploads[key] == mine { Self.uploads[key] = nil }
        return ok
    }
    private static var uploads: [String: Task<Bool, Never>] = [:]

    private func uploadNow(_ saved: URL, to remotePath: String, on target: SFTPTarget, _ state: RemoteEdit, force: Bool, action: String) async -> Bool {
        let name = (remotePath as NSString).lastPathComponent   // the copy's own, but not a version's (Revert)
        if state.asks(target) {
            var c = Confirm("Save “\(name)” to \(SavedServer.name(for: target))?", on: target, action: "Save")
            c.note = "This overwrites the file there."
            guard await confirm(c, on: Editor.window(for: saved)) == 0 else {
                return notSaved(saved, to: target, CancellationError())   // the editor may be gone: says where the text is
            }
            state.prodConfirmed = true
        }
        let env = SSHAskpass.env, baseline = state.baseline, history = serverHistory
        let (rules, problem) = ConfigCheck.rules(FileManager.default.contents(atPath: Self.validatorsPath))
        let rule = ConfigCheck.rule(for: remotePath, in: rules)
        // No panel of its own: the one showing that server (else the active one) says it's saving; ⎋ there cancels.
        let panel = panels.first { $0.remote?.target == target } ?? active
        let kept = Self.keptSession(of: target, in: panels)
        let r = await panel.busy("Saving “\(name)” to \(target.host)…") { flag in
            try SFTP.session(target, env: env, cancel: flag, on: kept) { c in
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
            AuditLog.write(target, action, paths: [remotePath], exit: 0)
            state.baseline = attrs
            for p in panels where p.remote?.target.asUser == target.asUser { p.reload() }   // root's or user's: one server
            let notes = [note.map { "no history: \($0)" }, outcome.map { Self.checkNote($0, of: rule) }, Self.reloadNote(rule, outcome, on: target), problem]
                .compactMap { $0 }
            if !notes.isEmpty {
                let said = "Saved “\(name)” to \(target.host) · " + notes.joined(separator: " · ")
                panel.flash(said)
                Editor.flash(saved, said)
            }
            if let (command, old) = reload {   // not waited for: the next save needn't wait for the answer
                Task { await offerReload(command, after: saved, to: remotePath, on: target, old: old, in: panel) }
            }
            return true
        case .failure(let e as SFTPClient.CheckFailed):
            AuditLog.write(target, action, paths: [remotePath], exit: e.status, error: "“\(e.program)” failed. " + (e.now.isEmpty ? "Not saved." : e.now))
            Editor.markUnsaved(saved)
            if let a = e.attrs { state.baseline = a }   // an "after" check: what's there now, put back or not
            let (message, info) = Self.checkFailed(e, name: name, host: target.host, kept: Editor.window(for: saved) == nil ? saved.path : nil)
            _ = await choose(message, info: info, ["OK"], on: Editor.window(for: saved))
            return false
        case .failure(let e as SFTPClient.ChangedOnServer):
            Editor.markUnsaved(saved)
            let keeps = Editor.window(for: saved) == nil ? "in \(saved.path)" : "unsaved here"   // the editor may be gone
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            let when = fmt.string(from: Date(timeIntervalSince1970: e.attrs.mtime))
            let info = "Someone or something wrote it at \(when) (\(ByteCountFormatter.short(e.attrs.size))). "
                + "Overwriting replaces their changes with yours. Compare shows the differences first; Cancel keeps your text \(keeps)."
            var c = Confirm("“\(name)” changed on \(SavedServer.name(for: target)) since you opened it", on: target, action: "Overwrite")
            (c.note, c.others, c.irreversible) = (info, ["Compare"], true)   // ⌘S ↩ never writes over theirs
            while true {   // Compare asks again once the diff is up
                switch await confirm(c, on: Editor.window(for: saved)) {
                case 0:   // over what was shown, not whatever's there by now: another change meanwhile asks again
                    state.baseline = e.attrs
                    return await uploadNow(saved, to: remotePath, on: target, state, force: false, action: action)
                case 1: await diff(DiffSide(path: saved.path, name: "\(name) (yours)"),
                                   DiffSide(path: remotePath, server: target, size: e.attrs.size, mtime: e.attrs.mtime), in: panel)
                default: return false
                }
            }
        case .failure(let e):
            if !(e is CancellationError) { AuditLog.write(target, action, paths: [remotePath], exit: 1, error: e.localizedDescription) }
            return notSaved(saved, to: target, e)
        }
    }

    /// The session a save to `target` goes over: that of a panel showing it, if one does — no ssh start and handshake
    /// of its own, and from a root panel no second sudo (where sudo wants a password, the look and the check before
    /// each new session). The panel's listings wait for it meanwhile; its status line says it's saving. Else nil: a
    /// session of its own.
    static func keptSession(of target: SFTPTarget, in panels: [PanelViewController]) -> KeptSession? {
        panels.first { $0.remote?.target == target && $0.kept?.target == target }?.kept
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
            let side = { (v: ServerHistory.Version) in DiffSide(path: v.path, name: "\(target.host):\(path) @ \(when(v))") }
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
            switch await confirm(q, on: Editor.window(for: saved)) {
            case 0: break ask
            case 1:
                guard let old else { panel.flash("Nothing to compare: the text before this save wasn't kept (over 5 MB, or a new file)"); continue }
                if before == nil { before = Self.textBefore(old, name: name) }
                guard let before else { continue }
                await diff(DiffSide(path: before, name: "\(target.host):\(path) (before this save)"), DiffSide(path: saved.path, name: "\(target.host):\(path)"), in: panel)
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
        if await !ServerLock.authorize(target, "run “\(command)” on") { return .notRun("\(target.host) stays locked") }
        if let ask, let c = Self.prodQuestion(command, on: target, ask) {
            guard await confirm(c, on: askOn) == 0 else { return .notRun("cancelled") }   // ↩ = Cancel
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
                             on: saved.flatMap(Editor.window(for:)))
        case .success(.noProgram(let why)):
            panel.flash("“\(command)” didn't run on \(target.host): \(why)", error: true)
        case .success: break   // needs root, not run: only checks
        case .failure(is CancellationError): break
        case .failure(let e): showError(e)
        }
        return false
    }

    /// What saving a server's `path` does besides writing it, for the unsaved changes' question: its check, the old
    /// version kept, the production log — only what will happen; nil when nothing.
    func saveSays(_ t: SFTPTarget, _ path: String) -> String? {
        let rule = ConfigCheck.rule(for: path, in: ConfigCheck.rules(FileManager.default.contents(atPath: Self.validatorsPath)).rules)
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
        let text = kept.map { "Your text is kept in \($0)." } ?? "Your text stays unsaved here."
        return ("“\(name)” didn't pass “\(e.program)” on \(host)",
                (shown.isEmpty ? "It exited with \(e.status)." : shown) + "\n\n" + (e.now.isEmpty ? "Not saved there: the file on \(host) is as it was." : e.now) + " " + text)
    }

    private func notSaved(_ saved: URL, to target: SFTPTarget, _ e: Error) -> Bool {
        Editor.markUnsaved(saved)
        if let m = Self.notUploaded(saved, host: target.host, e, editorOpen: Editor.window(for: saved) != nil) { showError(JobErrorMessage(m)) }
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
            let now = e.restored ? "was put back as it was" : "may be cut short"
            return "Uploading “\(saved.lastPathComponent)” to \(host) failed: \(e.error.localizedDescription). The file on \(host) \(now); "
                + "your full text is in \(e.partial) there.\(kept)"
        }
        return "Saved locally, but uploading to \(host) failed: \(error.localizedDescription)\(kept)"
    }

    /// One operation over the native client (names go as bytes, no `sftp -b` quoting), then the server's panels reload.
    /// `paths`: what it changes, for the production log.
    /// `then`: once it's done (not after a failure).
    func remoteOp(_ title: String, _ target: SFTPTarget, paths: [String], select: String? = nil, _ op: @escaping @Sendable (SFTPClient) throws -> Void,
                  then: (() -> Void)? = nil) {
        let env = SSHAskpass.env
        Task {
            let r = await active.busy("\(title) on \(target.host)…") { flag in try SFTPClient.session(target, env: env, cancel: flag, op) }
            switch r {
            case .success:
                AuditLog.write(target, title.lowercased(), paths: paths, exit: 0)
                then?()
            case .failure(is CancellationError): break
            case .failure(let e):
                AuditLog.write(target, title.lowercased(), paths: paths, exit: 1, error: e.localizedDescription)
                showError(JobErrorMessage("\(title): \(e.localizedDescription)"))
            }
            for p in panels where p.remote?.target.asUser == target.asUser { p.reload(select: select) }
        }
    }

    private func remoteMkdir() {
        guard let (target, dir, _) = active.remoteSelection ?? active.remote.map({ ($0.target, $0.dir, []) }) else { return }
        Task {
            guard let name = await prompt("New folder on \(target.host):", value: "", ok: "Create", strip: target), !name.isEmpty else { return }
            let path = (dir as NSString).appendingPathComponent(name)
            remoteOp("New folder", target, paths: [path], select: name) { try $0.mkdir(path) }
        }
    }

    /// An empty file there, then F4 on it. Never over an existing one (O_EXCL).
    private func remoteNewFile() {
        guard let r = active.remote else { return }
        let (target, panel) = (r.target, active)
        Task {
            guard let name = await prompt("New file on \(target.host):", value: "", ok: "Create", strip: target),
                  !name.isEmpty else { return }
            let path = name.hasPrefix("/") ? name : (r.dir as NSString).appendingPathComponent(name)
            remoteOp("New file", target, paths: [path], select: (path as NSString).lastPathComponent, { try Self.newServerFile($0, path) }) { [self] in
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
    private func remoteRename() {
        guard let (target, dir, item) = active.remoteCursor else { return NSSound.beep() }
        Task {
            guard let name = await prompt("Rename “\(item.name)” on \(target.host) to:", value: item.name, ok: "Rename",
                                          selectBaseName: true, strip: target),
                  name != item.name, !name.isEmpty else { return }
            let from = (dir as NSString).appendingPathComponent(item.name)
            let to = name.hasPrefix("/") ? name : (dir as NSString).appendingPathComponent(name)
            remoteOp("Rename", target, paths: [from, to], select: (to as NSString).lastPathComponent) { try $0.rename(from, to, replace: false) }
        }
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
    private func remoteDelete() {
        guard let sel = active.remoteSelection else { return NSSound.beep() }
        let items = active.listed(sel.items)
        Task {
            let what = sel.items.count == 1 ? "“\(sel.items[0].name)”" : "\(sel.items.count) items"
            var c = Confirm("Delete \(what) on \(SavedServer.name(for: sel.target)) permanently?", on: sel.target, action: "Delete")
            (c.items, c.note, c.irreversible) = (items, "A server has no Trash. This can't be undone.", true)
            guard await confirm(c) == 0 else { return }
            ops.enqueue(Self.serverDelete(sel.items, in: sel.dir, on: sel.target, env: SSHAskpass.env), title: "Delete \(what) on \(sel.target.host)")
            active.unmarkAll()
        }
    }

    // MARK: - Administrator operations

    /// How an administrator's command runs, over it in a question.
    static let asAdmin = "Runs as root on this Mac; macOS asks for an administrator's password first."

    func runAdmin(_ title: String, _ command: String) async {
        switch await Self.runAsAdmin(command) {
        case .ok: active.flash("\(title): done")
        case .cancelled: break
        case .failed(let msg): showError(JobErrorMessage("\(title) failed: \(msg)"))
        }
        panels.forEach { $0.reload() }
    }

    func adminTransfer(move: Bool) {
        if active.archive != nil { return readOnly() }
        let srcs = active.targetURLs
        guard !srcs.isEmpty else { return NSSound.beep() }
        let verb = move ? "Move" : "Copy"
        Task {
            guard let input = await prompt("\(verb) \(srcs.count == 1 ? "“\(srcs[0].lastPathComponent)”" : "\(srcs.count) items") as administrator to:",
                                           value: ((other.path + "/") as NSString).abbreviatingWithTildeInPath, ok: verb,
                                           info: move ? "Existing items are never overwritten (mv -n)." : "ditto keeps owner, mode, ACLs and xattrs; it asks before replacing what's there.")
            else { return }
            await adminTransfer(srcs.map(\.path), to: resolve(input), move: move)
        }
    }

    /// After the prompt: what F5/F6 would refuse is refused here too, before the password is asked (`AdminCommand.check`,
    /// off the main thread: the destination may be a share); what a copy would replace is asked about first.
    func adminTransfer(_ paths: [String], to dest: String, move: Bool) async {
        let verb = move ? "Move" : "Copy", panel = active
        let (refusal, existing) = await Blocking.run(.userInitiated) { AdminCommand.check(paths, to: dest, move: move) }
        if let refusal { return panel.flash("\(verb) as administrator: \(refusal)", error: true) }
        let command = move ? AdminCommand.move(paths, to: dest) : AdminCommand.copy(paths, to: dest)
        if !move, !existing.isEmpty {
            let what = existing.count == 1 ? "“\(existing[0])”" : "\(existing.count) items"
            var c = Confirm("Replace \(what) in \((dest as NSString).abbreviatingWithTildeInPath) as administrator?", action: "Replace")
            (c.chips, c.place, c.items) = ([.root], "this Mac", existing.map { Confirm.Item(name: $0) })
            (c.runs, c.command) = (Self.asAdmin, command)
            (c.note, c.irreversible) = ("What's there now is replaced. This can't be undone.", true)
            guard await confirm(c) == 0 else { return }
        }
        await runAdmin("\(verb) as administrator", command)
        panel.unmarkAll()
    }

    func adminMkdir() {
        if active.archive != nil { return readOnly() }
        Task {
            guard let name = await prompt("New folder as administrator:", value: "", ok: "Create"), !name.isEmpty else { return }
            await runAdmin("New folder", AdminCommand.mkdir(resolve(name)))
        }
    }

    func adminDelete() {
        let srcs = active.targetURLs
        guard !srcs.isEmpty else { return NSSound.beep() }
        let command = AdminCommand.delete(srcs.map(\.path))
        var c = Confirm("Delete \(Self.describe(srcs)) permanently as administrator?", action: "Delete")
        (c.chips, c.place, c.items) = ([.root], "this Mac", active.listed(srcs))
        (c.runs, c.command) = (Self.asAdmin, command)
        (c.note, c.irreversible) = ("They don't go to the Trash. This can't be undone.", true)
        Task {
            guard await confirm(c) == 0 else { return }
            await runAdmin("Delete as administrator", command)
            active.unmarkAll()
        }
    }

    // MARK: - Archives

    /// Extracts the selection inside an archive into a fresh temp folder.
    private func extractToTemp(_ sel: (index: ArchiveIndex, inner: String, names: [String])) async -> [URL]? {
        let dest = NSTemporaryDirectory() + "dfm-archive-" + UUID().uuidString
        do {
            try await Blocking.run { try sel.index.extract(sel.names, from: sel.inner, to: dest) }
        } catch {
            TempCopies.remove(dest)
            showError(error)
            return nil
        }
        return sel.names.map { URL(fileURLWithPath: dest).appendingPathComponent($0) }
    }

    /// ↩ / F3 on a file inside an archive: extract it to a temp folder, then open or view it.
    func openFromArchive(view: Bool) {
        guard var sel = active.archiveSelection else { return NSSound.beep() }
        sel.names = Array(sel.names.prefix(1))
        Task {
            guard let url = await extractToTemp(sel)?.first else { return }
            if view { Viewer.show(url) { TempCopies.remove(url.deletingLastPathComponent().path) } } else {
                FileInfo.quarantine(url.path)   // the archive's own if it has one, else Kermo's
                // Read-only: edits there would go with the temp folder (a day on), so the app says "locked" and offers
                // Duplicate. After the quarantine: setxattr on a read-only file fails (EACCES).
                var st = stat()
                if Darwin.lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG { chmod(url.path, st.st_mode & 0o7555) }
                Self.openInApp(url)
                active.flash("A temporary copy, read-only — ⌥F9 Extract keeps your changes")
            }
        }
    }

    /// Inside an archive: extract the selection. On an archive file: extract all of it. Default: the other panel.
    func extractDialog() {
        if active.remote != nil { return remoteExtract() }
        let sel = active.archiveSelection
        let file = sel?.index.file ?? active.cursorURL.map(\.path)
        guard let file, sel != nil || ArchiveIndex.isArchive(file) else { return active.flash("Put the cursor on an archive (or go inside one)") }
        let what = sel.map { $0.names.count == 1 ? "“\($0.names[0])”" : "\($0.names.count) items" } ?? "“\((file as NSString).lastPathComponent)”"
        Task {
            guard let input = await prompt("Extract \(what) to:", value: ((other.path + "/") as NSString).abbreviatingWithTildeInPath, ok: "Extract")
            else { return }
            let dest = resolve(input)
            if sel == nil && ArchiveIndex.isTar(file) { return extractWholeTar(file, to: dest) }
            await extract(file, sel, to: dest)
        }
    }

    /// Extract once `dest` is known (all of a zip, 7z…, or a selection inside any archive). Over what's there it
    /// unpacks into a hidden folder first, as a whole tar does: bsdtar removes a file and writes the new one under its
    /// name, so ⎋, a full disk, a bad member or a quit midway would leave one gone and the other cut short. Returns
    /// once it's all done.
    func extract(_ file: String, _ sel: (index: ArchiveIndex, inner: String, names: [String])?, to dest: String) async {
        // What lands at the top of `dest`; bsdtar would silently replace any of it that's there already.
        let (index, clashes) = await Blocking.run { () -> (ArchiveIndex?, [String]) in
            let index = sel?.index ?? (try? ArchiveIndex.read(file))
            let top = sel?.names ?? (index?.list("") ?? []).map(\.name)
            return (index, top.filter { var st = stat(); return Darwin.lstat((dest as NSString).appendingPathComponent($0), &st) == 0 })
        }
        // Not readable as a whole (a damaged member, a format the reader refuses midway): its names aren't known, and
        // bsdtar extracts the rest anyway — over what's there, unasked. Unpacked aside first and asked after, as a tar.
        if index == nil, sel == nil { return extractWholeTar(file, to: dest) }
        let shown = (dest as NSString).abbreviatingWithTildeInPath
        guard let keep = await keepExisting(clashes, in: shown) else { return }
        let staging: String?
        do {
            staging = try await Blocking.run { () throws -> String? in
                try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
                guard !clashes.isEmpty else { return nil }   // nothing there to lose: only what's new can be cut short
                let staging = ArchiveIndex.stagingFolder(in: dest)
                try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: false)
                return staging
            }
        } catch {
            return showError(error)
        }
        let into = staging ?? dest
        let args = index?.extractArguments(sel?.names ?? [], from: sel?.inner ?? "", to: into) ?? ["-x", "-f", file, "-C", into]
        let status = await withCheckedContinuation { done in
            Shell.run("/usr/bin/tar -v " + args.map(ShellContext.quote).joined(separator: " ") + " 2>&1", in: dest,
                      title: "Extract “\((file as NSString).lastPathComponent)” → \(shown)",
                      failed: staging.map { _ in Self.nothingExtracted(shown) }) { done.resume(returning: $0) }
        }
        if let staging { await moveOut(staging, to: dest, keep: status == 0 ? keep : nil) } else { panels.forEach { $0.reload() } }
    }

    /// Under a failed or stopped tar that unpacked into a staging folder: none of it lands.
    static func nothingExtracted(_ dest: String) -> String { "Nothing was extracted — what was in \(dest) is as it was." }

    /// The end of an extract through a staging folder: what's in it moves into `dest` (`keep`: what's there stays),
    /// or with nil (stopped, failed, cancelled) none of it lands there. The window already says what tar said.
    private func moveOut(_ staging: String, to dest: String, keep: Bool?) async {
        let errors = await Blocking.run {
            guard let keep else { ArchiveIndex.discardStaging(staging); return [String]() }
            return ArchiveIndex.moveExtracted(staging, to: dest, keep: keep)
        }
        panels.forEach { $0.reload() }
        if !errors.isEmpty {
            showError(JobErrorMessage(errors.prefix(8).joined(separator: "\n") + (errors.count > 8 ? "\n…" : "")))
        }
    }

    /// All of a tar, without reading it once first just for the names at its top (listing a .tar.gz unpacks all of
    /// it). Into an empty or new folder as it is; else into a hidden folder inside `dest`, and once that's done, what
    /// was there already is asked about, then the rest moves out by rename.
    private func extractWholeTar(_ file: String, to dest: String) {
        Task {
            let staging: String?
            do {
                staging = try await Blocking.run { () throws -> String? in
                    try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
                    guard try !FileManager.default.contentsOfDirectory(atPath: dest).isEmpty else { return nil }
                    let staging = ArchiveIndex.stagingFolder(in: dest)
                    try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: false)
                    return staging
                }
            } catch {
                return showError(error)
            }
            let shown = (dest as NSString).abbreviatingWithTildeInPath
            let args = ["-x", "-f", file, "-C", staging ?? dest]
            Shell.run("/usr/bin/tar -v " + args.map(ShellContext.quote).joined(separator: " ") + " 2>&1", in: dest,
                      title: "Extract “\((file as NSString).lastPathComponent)” → \(shown)",
                      failed: staging.map { _ in Self.nothingExtracted(shown) }) { [self] status in
                guard let staging else { return panels.forEach { $0.reload() } }
                Task {
                    // stopped (⎋) or failed: half an archive doesn't land in `dest`
                    let clashes = await Blocking.run { status == 0 ? ArchiveIndex.clashes(staging, dest) : [] }
                    await self.moveOut(staging, to: dest, keep: status == 0 ? await self.keepExisting(clashes, in: shown) : nil)
                }
            }
        }
    }

    /// Extracting over what's there: whether to keep it (false: overwrite); nil: cancelled. No clashes, no question.
    private func keepExisting(_ clashes: [String], in dest: String) async -> Bool? {
        guard !clashes.isEmpty else { return false }
        let shown = clashes.prefix(8).map { "  \($0)" }.joined(separator: "\n") + (clashes.count > 8 ? "\n  …" : "")
        switch await choose("\(clashes.count == 1 ? "“\(clashes[0])” already exists" : "\(clashes.count) items already exist") in \(dest)",
                            info: shown + "\n\nKeep Existing extracts only what isn't there yet (folders are merged). Overwrite replaces files with the archive's.",
                            ["Keep Existing", "Overwrite", "Cancel"]) {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    /// ↩ on an archive on a server: its table of contents (`tar -tv`, `unzip -l`, run there) in the viewer.
    func remoteArchiveList() {
        guard let (target, dir, item) = active.remoteCursor else { return NSSound.beep() }
        let file = (dir as NSString).appendingPathComponent(item.name), name = (item.name as NSString).lastPathComponent, env = SSHAskpass.env
        Task {
            let r = await active.busy("Listing “\(name)”…") { flag in try SSHCommand.capture(target, RemoteArchive.listCommand(file), env: env, cancel: flag) }
            switch r {
            case .success(let listing): showText(Data(listing.utf8), as: name + ".txt", prefix: "dfm-sftp-")
            case .failure(let e): if !(e is CancellationError) { showError(e) }
            }
        }
    }

    /// An archive on a server unpacks there (tar, unzip): into the other panel's folder when it's on the same
    /// server, else next to it.
    private func remoteExtract() {
        guard let (target, dir, item) = active.remoteCursor, RemoteArchive.isArchive(item.name) else {
            return active.flash("Put the cursor on an archive (tar or zip)")
        }
        let file = (dir as NSString).appendingPathComponent(item.name), panel = active, env = SSHAskpass.env
        let there = other.remote.flatMap { $0.target.isSameServer(as: target) ? $0.dir : nil } ?? (file as NSString).deletingLastPathComponent
        Task { [self] in
            guard let input = await prompt("Extract “\((item.name as NSString).lastPathComponent)” on \(target.host) to:", value: there,
                                           ok: "Extract", strip: target), !input.isEmpty else { return }
            let dest = ((input.hasPrefix("/") ? input : (dir as NSString).appendingPathComponent(input)) as NSString).standardizingPath
            // What lands at the top of `dest` that's there already: tar and unzip -o would replace it.
            let found = await panel.busy("Reading “\((item.name as NSString).lastPathComponent)”…") { flag in
                let top = RemoteArchive.topNames(try SSHCommand.capture(target, RemoteArchive.namesCommand(file), env: env, cancel: flag), of: file)
                // A refused channel or no permission isn't "nothing there": taken as such, tar -x and unzip -o
                // replaced what was there unasked.
                let present = Set(try SFTP.listIfThere(target, dest, env: env, cancel: flag).map(\.name))
                return top.filter(present.contains)
            }
            guard case .success(let clashes) = found else {
                if case .failure(let e) = found, !(e is CancellationError) { showError(e) }
                return
            }
            guard let keep = await keepExisting(clashes, in: DirSync.place(.sftp(target), dest)) else { return }
            let command = RemoteArchive.extractCommand(file, to: dest, keep: keep)
            Shell.run(command, on: target, in: dir,
                      title: "Extract “\((item.name as NSString).lastPathComponent)” → \(dest) on \(target.host)") { [weak self] status in
                AuditLog.write(target.asUser, "extract", paths: [file], to: dest, command: command, exit: status)   // ran as the user (ssh)
                for p in self?.panels ?? [] where p.remote?.target.asUser == target.asUser { p.reload() }
            }
        }
    }

    /// ⌥F5: pack the marked items; the format follows the extension (.zip .tar.gz .tar.xz .7z …).
    func compressDialog() {
        if active.archive != nil { return readOnly() }
        let srcs = active.targetURLs
        guard !srcs.isEmpty else { return NSSound.beep() }
        let base = srcs.count == 1 ? srcs[0].deletingPathExtension().lastPathComponent : (active.path as NSString).lastPathComponent
        let suggestion = (other.path as NSString).appendingPathComponent((base.isEmpty ? "archive" : base) + ".zip")
        Task {
            guard let input = await prompt("Compress \(srcs.count == 1 ? "“\(srcs[0].lastPathComponent)”" : "\(srcs.count) items") into:",
                                           value: (suggestion as NSString).abbreviatingWithTildeInPath, ok: "Compress",
                                           info: "Format from the extension: .zip .tar.gz .tgz .tar.bz2 .tar.xz .7z")
            else { return }
            let archive = resolve(input)
            let taken = await Blocking.run(.userInitiated) { FileManager.default.fileExists(atPath: archive) }   // a share that doesn't answer
            guard !taken else { return showError(JobErrorMessage("“\(input)” already exists.")) }
            let dir = active.itemsDir
            let args = ArchiveIndex.createArguments(archive, names: srcs.map { Self.name($0, in: dir) }, in: dir)
            Shell.run("COPYFILE_DISABLE=1 /usr/bin/tar -v " + args.map(ShellContext.quote).joined(separator: " ") + " 2>&1", in: dir) { _ in self.panels.forEach { $0.reload() } }
            active.unmarkAll()
        }
    }

    // MARK: - Split / combine (big files onto FAT sticks, mail limits…)

    func splitDialog() {
        guard let url = active.cursorURL, !url.hasDirectoryPath else { return NSSound.beep() }
        let name = url.lastPathComponent, dir = url.deletingLastPathComponent().path
        Task {
            guard let size = await prompt("Split “\(name)” into parts of:", value: defaults.string(forKey: "splitSize") ?? "1G", ok: "Split",
                                          info: "Bytes, or with K, M or G (650M, 4G). Parts go next to it: \(name).000, .001, …")
            else { return }
            guard size.range(of: #"^\d+[KkMmGg]?$"#, options: .regularExpression) != nil else {
                return showError(JobErrorMessage("“\(size)” isn't a size like 650M or 4G."))
            }
            // Any part there already, not just .000: split writes over the first ones and leaves the rest, and Combine
            // would join both splits.
            let parts = await Blocking.run(.userInitiated) {
                SplitParts.parts(of: name, in: ((try? DirLister.list(dir)) ?? []).map(\.name))
            }
            guard parts.isEmpty else {
                let shown = parts.prefix(3).map { "“\($0)”" }.joined(separator: ", ") + (parts.count > 3 ? " and \(parts.count - 3) more" : "")
                return showError(JobErrorMessage("\(shown) \(parts.count == 1 ? "is" : "are") there already: combine or remove \(parts.count == 1 ? "it" : "them") first."))
            }
            defaults.set(size, forKey: "splitSize")
            let q = ShellContext.quoteName
            Shell.run("split -d -a 3 -b \(size) -- \(q(name)) \(q(name + ".")) && ls -l \(q(name)).[0-9][0-9][0-9]", in: dir) { [self] _ in
                active.reload(select: name + ".000")
            }
        }
    }

    /// Cursor on any part: joins the whole numbered set back into one file (never overwrites).
    func combineDialog() {
        guard let url = active.cursorURL else { return NSSound.beep() }
        let dir = url.deletingLastPathComponent().path
        Task {
            let items = await Blocking.run(.userInitiated) { (try? DirLister.list(dir)) ?? [] }   // all of them, not just what the filter shows
            guard let seq = SplitParts.sequence(for: url.lastPathComponent, in: items.map(\.name)) else {
                return active.flash("Put the cursor on a part (name.000 / name.001) — and make sure none is missing")
            }
            let sizes = Dictionary(items.map { ($0.name, $0.size) }) { a, _ in a }
            if let odd = SplitParts.misfit(seq.parts, sizes: sizes) {
                let size = { ByteCountFormatter.short(sizes[$0] ?? 0) }
                return showError(JobErrorMessage("“\(odd)” is \(size(odd)), “\(seq.parts[0])” \(size(seq.parts[0])): these look like parts of two different splits. Nothing was combined."))
            }
            guard let target = await prompt("Combine \(seq.parts.count) parts (\(seq.parts.first!) … \(seq.parts.last!)) into:",
                                            value: seq.base, ok: "Combine"), !target.isEmpty else { return }
            let q = ShellContext.quoteName
            Shell.run("set -C; cat \(seq.parts.map(q).joined(separator: " ")) > \(q(target)) && ls -l \(q(target))", in: dir) { [self] _ in
                active.reload(select: (target as NSString).lastPathComponent)
            }
        }
    }

    // MARK: - Links, volumes, comparisons

    /// Link to the cursor item, placed in the other panel by default (MC's Ctrl+X S / L).
    func linkDialog(hard: Bool) {
        guard let target = active.cursorURL else { return NSSound.beep() }
        let suggestion = (other.path as NSString).appendingPathComponent(target.lastPathComponent)
        let kind = hard ? "Hard link" : "Symbolic link"
        Task {
            guard let input = await prompt("\(kind) to “\(target.lastPathComponent)” at:",
                                           value: (suggestion as NSString).abbreviatingWithTildeInPath, ok: "Create",
                                           info: hard ? "Hard links work for files on the same volume." : "Points to \(target.path)")
            else { return }
            let path = resolve(input)
            let ok = hard ? link(target.path, path) == 0 : symlink(target.path, path) == 0
            guard ok else { return showError(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
            registerCreated(kind, [path])
            for p in panels where p.path == (path as NSString).deletingLastPathComponent {
                p.reload(select: (path as NSString).lastPathComponent)
            }
        }
    }

    func goToLinkTarget() {
        guard let url = active.cursorURL else { return NSSound.beep() }
        let panel = active
        Task {
            // Off the main thread: a link on a share that doesn't answer.
            guard let dest = await Blocking.run(.userInitiated, { try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) })
            else { return NSSound.beep() }
            let abs = dest.hasPrefix("/") ? dest : (url.deletingLastPathComponent().path as NSString).appendingPathComponent(dest)
            let target = (abs as NSString).standardizingPath
            panel.navigate(to: (target as NSString).deletingLastPathComponent, select: (target as NSString).lastPathComponent)
        }
    }

    func showVolumes() {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeIsEjectableKey, .volumeLocalizedFormatDescriptionKey]
        Task { [self] in
            // Off the main thread: a stick that stopped answering. A network share keeps to the kernel's figures.
            let rows = await Blocking.run(.userInitiated) { () -> [(path: String, title: String, subtitle: String, eject: Bool)] in
                return SidebarModel.mounts().map { m in
                    let v = m.local ? try? URL(fileURLWithPath: m.path).resourceValues(forKeys: keys) : nil
                    let free = m.local ? v?.volumeAvailableCapacityForImportantUsage.map { ByteCountFormatter.short($0) } ?? "?" : ByteCountFormatter.short(m.free)
                    let total = m.local ? v?.volumeTotalCapacity.map { ByteCountFormatter.short(Int64($0)) } ?? "?" : ByteCountFormatter.short(m.total)
                    return (m.path, v?.volumeName ?? (m.path as NSString).lastPathComponent,
                            "\(m.path) · \(free) free of \(total) · \(v?.volumeLocalizedFormatDescription ?? m.type)", v?.volumeIsEjectable == true || !m.local)
                }
            }
            let items = rows.map { r in
                Picker.Item(title: r.title, subtitle: r.subtitle,
                            actions: r.eject ? [.init(key: Shortcut("cmd+opt+e")!, label: "Eject") { [unowned self] in ejectVolume(r.path) }] : [],
                            verb: "Open") { [unowned self] in active.navigate(to: r.path) }
            } + SidebarModel.locations([], disks).compactMap { v in
                v.disk.map { d in Picker.Item(title: d.name, subtitle: v.tip, detail: "not mounted", verb: "Mount") { [unowned self] in mountVolume(d) { [unowned self] in active.navigate(to: $0) } } }
            }
            Picker.show(over: window, placeholder: "Volume", items: items)
        }
    }

    /// Eject: the disk goes. Unmount: the volume only — its disk stays, and Locations has it in gray, with Mount (so
    /// only for a disk's volume Kermo can mount again: not a disk image's, a share's or this Mac's own).
    func ejectVolume(_ path: String? = nil, unmount: Bool = false) {
        let url = URL(fileURLWithPath: path ?? active.path)
        Task {   // the volume is asked off the main thread: a dead share may never answer
            let found = await Blocking.run { () -> (vol: URL, name: String)? in
                let rv = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsEjectableKey, .volumeNameKey])
                guard let vol = rv?.volume, vol.path != "/", rv?.volumeIsEjectable == true || vol.path.hasPrefix("/Volumes/") else { return nil }
                return (vol, rv?.volumeName ?? vol.lastPathComponent)
            }
            guard let (vol, name) = found else { return active.flash("This folder isn't on an ejectable volume") }
            if unmount, !disks.contains(where: { $0.mountPath == vol.path }) {
                return active.flash("“\(name)” couldn't be mounted again from here: Eject it instead")
            }
            guard volumeBusy.insert(vol.path).inserted else { return active.flash("“\(name)”: one thing at a time") }
            refreshSidebar()
            // Don't leave panels sitting on it (their watchers use O_EVTONLY, which doesn't block unmount).
            for p in panels where p.parked == nil && (p.path == vol.path || p.path.hasPrefix(vol.path + "/")) { p.navigate(to: NSHomeDirectory()) }   // a parked one shows nothing of it
            active.flash((unmount ? "Unmounting" : "Ejecting") + " “\(name)”…")
            var error: Error?
            if unmount {
                do { try await FileManager.default.unmountVolume(at: vol, options: [.withoutUI]) } catch let e { error = e }   // the alert is ours
            } else {
                let device = await diskWatch?.device(of: vol.path)
                error = await Blocking.run { () -> Error? in
                    do { try NSWorkspace.shared.unmountAndEjectDevice(at: vol); return nil } catch { return error }
                }
                // An APFS stick: that unmounted it and "ejected" its container; the stick itself is still there.
                if error == nil, let device, let why = await diskWatch?.eject(device) { error = JobErrorMessage(why) }
            }
            if let error {
                // Who holds it: what macOS says doesn't name them. The spinner stays meanwhile (up to lsof's 3 s).
                let path = vol.path, names = await Blocking.run { Disks.holders(of: path) }
                volumeBusy.remove(vol.path)
                refreshSidebar()
                showError(JobErrorMessage("Couldn't \(unmount ? "unmount" : "eject") “\(name)”: \(Disks.inUse(by: names) ?? error.localizedDescription)"))
            } else {
                volumeBusy.remove(vol.path)
                refreshSidebar()
                active.flash("“\(name)” " + (unmount ? "unmounted" : "ejected"))
            }
        }
    }

    /// DiskArbitration mounts it where macOS would. `then`: where it went, to open it (its row clicked, ↩ in Volumes…);
    /// the Mount button only mounts.
    func mountVolume(_ disk: Disk, then open: ((String) -> Void)? = nil) {
        guard let diskWatch, volumeBusy.insert(disk.bsd).inserted else { return }
        refreshSidebar()
        Task {
            let r = await diskWatch.mount(disk.bsd)
            volumeBusy.remove(disk.bsd)
            refreshSidebar()
            switch r {
            case .success(let path):
                reloadVolumes()
                if let open { open(path) } else { active.flash("“\(disk.name)” mounted") }
            case .failure(let e): showError(JobErrorMessage("Couldn't mount “\(disk.name)”: \(e.text)"))
            }
        }
    }

    /// Recursive, also with a server (listed over SFTP: whole seconds): a folder on both sides is marked where it
    /// holds something newer or missing. Search results and archives: what's listed, one level.
    func compareFolders() {
        let (a, b) = (active, other)
        let tolerance = [a, b].filter { $0.remote == nil }.map(\.mtimeTolerance).max() ?? 1
        func show(_ l: Set<String>, _ r: Set<String>, note: String = "") {
            let (x, y) = (a.setMarks(l), b.setMarks(r)), unseen = l.count + r.count - x - y
            a.flash((l.isEmpty && r.isEmpty ? "Folders match (names, sizes, dates)"
                     : "Marked newer/missing: \(x) here, \(y) there — F5 copies them across") + note
                    + (unseen > 0 ? " · \(unseen) more not shown (filter, hidden files)" : ""))
        }
        guard [a, b].allSatisfy({ $0.archive == nil && $0.searchTitle == nil }) else {
            let (l, r) = DirCompare.differences(left: a.listedItems, right: b.listedItems, tolerance: tolerance)
            return show(l, r)
        }
        let (l, r, sides, hidden) = (a.currentDir, b.currentDir, (a.endpoint, b.endpoint), a.showHidden)
        Task {
            guard await unlock([sides.0, sides.1]) else { return }
            let found = await a.busy("Comparing with \(DirSync.place(sides.1, r))…") { flag in
                let (x, y) = (DirSync.lister(sides.0, env: SSHAskpass.env, cancel: flag), DirSync.lister(sides.1, env: SSHAskpass.env, cancel: flag))
                defer { x.close(); y.close() }
                return DirSync.compare(left: l, right: r, includeHidden: hidden, isCancelled: { flag.isCancelled },
                                       list: x.list, listRight: y.list, tolerance: tolerance)
            }
            // ⎋, or a panel went elsewhere meanwhile.
            guard case .success(let plan) = found, a.currentDir == l, b.currentDir == r, a.endpoint == sides.0, b.endpoint == sides.1 else { return }
            let m = DirCompare.marks(plan)
            show(m.left, m.right, note: m.unreadable > 0 ? " · \(m.unreadable) not compared (unreadable, or names differing only in case)" : "")
        }
    }

    /// A file Compare Files diffs: this Mac's, or a server's as its panel listed it (the size and date pick a preview's copy).
    struct DiffSide: Sendable {
        var path: String
        var server: SFTPTarget? = nil
        var size: Int64 = 0, mtime: Double = 0
        var look = false   // a link (its own size says nothing), or a size not known: the server is asked first
        var name: String? = nil   // what the diff calls it, if not its path ("host:/path" on a server)
        var label: String { name ?? server.map { "\($0.host):\(path)" } ?? path }
    }

    /// A panel's marked files (or the cursor's), and its cursor's: on a server, as its listing has them.
    private func diffSides(_ p: PanelViewController) -> (marked: [DiffSide], cursor: DiffSide?) {
        guard let r = p.remote else {
            let file = { (u: URL) in u.hasDirectoryPath ? nil : DiffSide(path: u.path) }
            return (p.targetURLs.compactMap(file), p.cursorURL.flatMap(file))
        }
        let side = { (it: FileItem) in
            it.kind == .file || it.kind == .link && !it.linkDir
                ? DiffSide(path: (r.dir as NSString).appendingPathComponent(it.name), server: r.target, size: it.size, mtime: it.mtime, look: it.kind == .link)
                : nil
        }
        return (p.remoteSelection?.items.compactMap(side) ?? [], p.remoteCursor.flatMap { side($0.item) })
    }

    /// Two marked files, or the cursor file vs. the same name (or the cursor) in the other panel — on this Mac or a
    /// server, whose files are fetched as a preview's (⌃Q) are. Shown as `diff -u`, with "host:/path" for a server's
    /// file; `defaults write com.dmn.dfilemanager diffCommand 'code --diff %1 %2'` gets the copies instead.
    func diffFiles() {
        let (panel, mine, theirs) = (active, diffSides(active), diffSides(other))
        // The other panel's folder only when that's what it shows: not the local one behind a server tab.
        let same = mine.cursor.flatMap { c -> DiffSide? in
            let name = (c.path as NSString).lastPathComponent
            if let r = other.remote { return DiffSide(path: (r.dir as NSString).appendingPathComponent(name), server: r.target, look: true) }
            return other.plainFolder.map { DiffSide(path: ($0 as NSString).appendingPathComponent(name)) }
        }
        let env = SSHAskpass.env
        Task {
            var stopped = false
            let pair = await Self.diffPair(marked: mine.marked, cursor: mine.cursor, sameName: same, otherCursor: theirs.cursor) { s in
                guard let t = s.server else {
                    return await Blocking.run(.userInitiated) { FileManager.default.fileExists(atPath: s.path) } ? s : nil   // a share that doesn't answer
                }
                guard await unlock([.sftp(t)]) else { stopped = true; return nil }
                let r = await panel.busy("Looking for “\((s.path as NSString).lastPathComponent)” on \(t.host)…") { flag in
                    try SFTPClient.session(t, env: env, cancel: flag) { try $0.stat(s.path) }
                }
                if case .failure(let e) = r, e is CancellationError { stopped = true }
                guard case .success(let a) = r, a.kind == .file else { return nil }
                return DiffSide(path: s.path, server: t, size: a.size, mtime: a.mtime)
            }
            guard !stopped else { return }
            guard let (a, b) = pair else { return panel.flash("Mark two files, or put the cursor on a file in each panel") }
            await diff(a, b, in: panel)
        }
    }

    /// `a` against `b`: a server's file through its local copy (`localCopy`).
    func diff(_ a: DiffSide, _ b: DiffSide, in panel: PanelViewController) async {
        guard await unlock([a, b].compactMap { $0.server.map(Endpoint.sftp) }) else { return }
        guard let la = await localCopy(a, in: panel), let lb = await localCopy(b, in: panel) else { return }
        let (qa, qb) = (ShellContext.quote(la), ShellContext.quote(lb))
        if let tool = defaults.string(forKey: "diffCommand") {
            Shell.spawn(Self.fillDiff(tool, qa, qb), in: panel.path)
        } else {
            let named = a.server != nil || b.server != nil || a.name != nil || b.name != nil
            Shell.run(Self.diffCommand(la, lb, labels: named ? (a.label, b.label) : nil), in: panel.path, diff: true,
                      title: named ? "diff \(a.label) ↔ \(b.label)" : nil)   // not the copies' temp paths
        }
    }

    /// An output window's title for git's diff: what it's of, not git's options and full paths.
    static func gitDiffTitle(_ paths: [String]) -> String {
        "git diff " + (paths.count == 1 ? (paths[0] as NSString).lastPathComponent.bidiVisible : "\(paths.count) files")
    }

    /// `diff -u`; `labels` in place of the paths (a server file's "host:/path", not its copy's temp path).
    nonisolated static func diffCommand(_ a: String, _ b: String, labels: (String, String)?) -> String {
        let q = ShellContext.quote
        return "diff -u " + (labels.map { "--label \(q($0.0)) --label \(q($0.1)) " } ?? "") + "\(q(a)) \(q(b))"
    }

    /// This Mac's file as it is; a server's, its preview copy for that size and date, else downloaded as a preview's
    /// is (`ServerCopies.download`, up to `previewLimit`). nil, once said why: too big, not a file, failed, ⎋.
    func localCopy(_ s: DiffSide, in panel: PanelViewController) async -> String? {
        guard let t = s.server else { return s.path }
        if !s.look, let url = ServerCopies.preview(of: t, s.path, size: s.size, mtime: s.mtime) { return url.path }
        let name = (s.path as NSString).lastPathComponent, limit = PanelViewController.previewLimit, env = SSHAskpass.env
        let tooBig = "“\(name)” is too big to compare (over \(limit >> 20) MB)"
        guard s.look || s.size <= limit else { panel.flash(tooBig); return nil }
        let r = await panel.busy("Downloading “\(name)”…") { flag in try ServerCopies.download(t, s.path, look: s.look, limit: limit, env: env, cancel: flag) }
        switch r {
        case .success(let got?):
            ServerCopies.add(.init(got.url, t, s.path, listed: s.look ? (got.attrs.size, got.attrs.mtime) : (s.size, s.mtime), baseline: got.attrs, preview: true))
            return got.url.path
        case .success(nil): panel.flash(tooBig + " or not a file")
        case .failure(let e) where !(e is CancellationError): panel.flash("Can't download “\(name)”: \(e.localizedDescription)", error: true)
        case .failure: break
        }
        return nil
    }

    /// Which two files Compare Files diffs: two marked; else the cursor's and the same name in the other panel's
    /// folder, if it's there (`find`: as it is there, or nil); else the cursor's and the other panel's cursor's. Files
    /// only (no folders, no ".."); nil: nothing to diff. `find` is asked about the same name only when it comes to that.
    static func diffPair<S: Sendable>(marked: [S], cursor: S?, sameName: S?, otherCursor: S?, find: (S) async -> S?) async -> (S, S)? {
        if marked.count == 2 { return (marked[0], marked[1]) }
        guard let a = cursor else { return nil }
        if let same = sameName, let found = await find(same) { return (a, found) }
        return otherCursor.map { (a, $0) }
    }

    /// `%1` and `%2` filled in one pass: a first path holding "%2" mustn't get the second pasted into its quotes.
    nonisolated static func fillDiff(_ tool: String, _ a: String, _ b: String) -> String {
        tool.components(separatedBy: "%1").map { $0.replacingOccurrences(of: "%2", with: b) }.joined(separator: a)
    }

    /// Marked items (or the cursor item) against HEAD in the diff window; a folder shows every change inside it,
    /// an untracked file shows whole as added. Untracked folders are skipped: there's nothing to diff them against.
    func gitDiff() {
        let targets = active.gitTargets.filter { $0.code != "??" || !$0.url.hasDirectoryPath }, panel = active, dir = active.path
        Task {
            // `git config` (up to 30 s) and the walk up to .git: off the main thread, ⎋ stops waiting.
            let r = await panel.busy("Git Diff…") { _ in   // `git config` only when there's something to diff
                let repo = GitStatus.repoRoot(dir) != nil
                return (trusted: repo && !targets.isEmpty && GitStatus.trustedRoot(dir) != nil, repo: repo)
            }
            guard case .success(let found) = r else { return }
            guard !targets.isEmpty, found.trusted else {
                return panel.flash(!found.repo ? "Not a git work tree"
                                   : !GitStatus.available ? "Git needs the Command Line Tools (xcode-select --install)"
                                   : targets.isEmpty ? "Nothing to diff here" : "Git Diff didn't run (this repo's config can run commands)")
            }
            let untracked = targets.filter { $0.code == "??" }.map(\.url.path)
            let tracked = targets.filter { $0.code != "??" }.map(\.url.path)
            Shell.run(GitStatus.diffCommand(tracked: tracked, untracked: untracked), in: dir, diff: true, title: Self.gitDiffTitle(tracked + untracked))
        }
    }

    /// The cursor file's `git log --follow -p` (or `git blame`) in the viewer.
    func gitHistory(blame: Bool) {
        guard let url = active.cursorURL, !url.hasDirectoryPath else { return NSSound.beep() }
        let what = blame ? "blame" : "log", name = url.lastPathComponent, panel = active
        Task {
            let r = await panel.busy("git \(what) “\(name)”…") { _ in GitStatus.history(url.path, blame: blame) }
            guard case .success(let found) = r else { return }   // ⎋
            guard let data = found, !data.isEmpty else {
                return panel.flash(found == nil ? "Git \(what) didn't run (not a git work tree or not committed, git failed, or this repo's config can run commands)"
                                                : "“\(name)” has no commits", error: found == nil)
            }
            showText(data, as: "\(name) — git \(what)", prefix: "dfm-git-")
        }
    }

    /// Text that isn't a file of its own (a server archive's listing, git log) in the viewer: a temp file named
    /// `name`, gone with the window. `prefix` is one of `TempCopies.prefixes`, so a leftover goes at the next launch.
    private func showText(_ data: Data, as name: String, prefix: String) {
        let tmp = NSTemporaryDirectory() + prefix + UUID().uuidString
        mkdir(tmp, 0o700)
        let url = URL(fileURLWithPath: tmp).appendingPathComponent(name)
        do { try data.write(to: url) } catch { TempCopies.remove(tmp); return showError(error) }
        Viewer.show(url) { TempCopies.remove(tmp) }
    }

    /// Marked files (or the cursor's) into the index, or out of it (`undo`); the git column follows.
    func gitStage(undo: Bool) {
        let paths = active.targetURLs.map(\.path), dir = active.path, panel = active
        guard !paths.isEmpty else { return NSSound.beep() }
        Task {
            let ok = await Blocking.run(.userInitiated) { GitStatus.stage(paths, in: dir, undo: undo) }
            if !ok { panel.flash("Git \(undo ? "unstage" : "stage") didn't run (not a git work tree, an ignored file, or this repo's config can run commands)", error: true) }
            panel.reload()
        }
    }

    // MARK: - Quick View (⌃Q)

    func toggleQuickView() {
        quickViewOn.toggle()
        other.setQuickView(quickViewOn)
        if quickViewOn { showQuickView() }
    }

    /// Quick View next door, on the active panel's cursor item, on the tab chosen.
    func showQuickView() { other.preview(active.peek(fetch: PanelViewController.quickTab == .preview)) }

    /// ⌘I: Quick View next door, on its Info tab (R-48) — a file here or on a server.
    func showInfo() {
        PanelViewController.quickTab = .info
        if quickViewOn { showQuickView() } else { toggleQuickView() }
    }

    func openTerminal() {
        if let r = active.remote { return openSSH(r.target, command: SSHCommand.shell(in: r.dir)) }
        guard let app = terminalAppURL() else { return NSSound.beep() }
        NSWorkspace.shared.open([URL(fileURLWithPath: active.path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func copyToPasteboard(_ lines: [String]) {
        guard !lines.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func pasteFiles(move: Bool) {
        guard active.archive == nil else { return readOnly() }
        guard let items = TransferItems(NSPasteboard.general) else { return NSSound.beep() }
        enqueueTransfer(items.paths, from: items.from, to: active.currentDir, on: active.endpoint, name: nil, move: move)
    }

    // MARK: - Dialog-driven operations

    func transferDialog(move: Bool) {
        if active.archive != nil { return move ? readOnly() : extractDialog() }
        if active.remote != nil || other.remote != nil { return transferAcrossDialog(move: move) }
        let srcs = active.targetURLs
        guard !srcs.isEmpty else { return NSSound.beep() }
        let what = srcs.count == 1 ? "“\(srcs[0].lastPathComponent)”" : "\(srcs.count) items"
        let verb = move ? "Move" : "Copy"
        let suggestion = other.path == "/" ? "/" : other.path + "/"
        let panel = active   // the one the items were marked in, whichever is active once the destination answers
        let items = panel.listed(srcs)
        Task {
            guard let input = await prompt("\(verb) \(what) to:", value: (suggestion as NSString).abbreviatingWithTildeInPath, ok: verb, items: items)
            else { return }
            let dest = resolve(input), intoDir = input.hasSuffix("/") || srcs.count > 1
            // Off the main thread, saying so (⎋ stops waiting): the destination may be a share that doesn't answer.
            let found = await panel.busy("Checking “\((dest as NSString).abbreviatingWithTildeInPath)”…") { _ -> Bool in
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: dest, isDirectory: &isDir)
                guard (exists && isDir.boolValue) || intoDir else { return false }
                // The item itself in another case (Foo → foo on a disk that ignores case): a rename, not a move into it.
                if !intoDir && Self.isRespelling(srcs[0].path, dest) { return false }
                if !exists { try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true) }
                return true
            }
            if case .failure(let error) = found { return error is CancellationError ? () : showError(error) }
            if case .success(true) = found {
                enqueueTransfer(srcs.map(\.path), to: dest, name: nil, move: move)
            } else {
                // Single item to a non-directory path: copy/move with a new name.
                enqueueTransfer(srcs.map(\.path), to: (dest as NSString).deletingLastPathComponent,
                                name: (dest as NSString).lastPathComponent, move: move)
            }
            panel.unmarkAll()
        }
    }

    /// `dest` is `src` itself, written in another case (F-04): the same file system object, a name equal but for case.
    nonisolated static func isRespelling(_ src: String, _ dest: String) -> Bool {
        var a = stat(), b = stat()
        return src != dest && src.caseInsensitiveCompare(dest) == .orderedSame
            && lstat(src, &a) == 0 && lstat(dest, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    /// F5/F6 when either panel (or both) is on a server. The same rules as between local folders: an existing
    /// folder, a path ending in "/" or several items go into it (made if missing); else the one item takes the
    /// new name. The path is on the other panel's side.
    private func transferAcrossDialog(move: Bool) {
        guard let items = active.transferItems else { return NSSound.beep() }
        guard other.archive == nil, other.searchTitle == nil else { return active.flash("Open a folder in the other panel first") }
        let side = other.endpoint, base = other.currentDir
        let verb = move ? "Move" : "Copy"
        let what = items.paths.count == 1 ? "“\((items.paths[0] as NSString).lastPathComponent)”" : "\(items.paths.count) items"
        var host = "", there: SFTPTarget?
        if case .sftp(let t) = side { (host, there) = (" \(t.host)", t) }
        let suggestion = base == "/" ? "/" : base + "/"
        let listed = active.remoteSelection.map { active.listed($0.items) } ?? active.listed(active.targetURLs)
        Task {
            guard let input = await prompt("\(verb) \(what) to\(host):", value: side == .local ? (suggestion as NSString).abbreviatingWithTildeInPath : suggestion,
                                           ok: verb, strip: there, items: listed), !input.isEmpty else { return }
            var dest = side == .local ? (input as NSString).expandingTildeInPath : input
            if !dest.hasPrefix("/") { dest = (base as NSString).appendingPathComponent(dest) }
            while dest.count > 1 && dest.hasSuffix("/") { dest.removeLast() }
            let intoDir = input.hasSuffix("/") || items.paths.count > 1 || dest == base
            let env = SSHAskpass.env
            let found = await active.busy("Checking “\(dest)”…") { [dest] flag -> (dir: String, name: String?) in
                let parent = (dest as NSString).deletingLastPathComponent, last = (dest as NSString).lastPathComponent
                switch side {
                case .local:
                    var isDir: ObjCBool = false
                    guard intoDir || (FileManager.default.fileExists(atPath: dest, isDirectory: &isDir) && isDir.boolValue) else { return (parent, last) }
                    try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
                case .sftp(let t):
                    let isDir = try SFTPClient.session(t, env: env, cancel: flag) { c in
                        let isDir = try c.isFolder(dest)
                        if intoDir || isDir { try c.makeDirectories(dest) }
                        return isDir
                    }
                    guard intoDir || isDir else { return (parent, last) }
                }
                return (dest, nil)
            }
            switch found {
            case .failure(is CancellationError): break
            case .failure(let e): showError(e)
            case .success(let d):
                enqueueTransfer(items.paths, from: items.from, to: d.dir, on: side, name: d.name, move: move)
                active.unmarkAll()
            }
        }
    }

    /// Queues a copy / move of `sources` (on `from`) into `dir` (on `side`); `name` renames a single item.
    /// Every paste, drop and F5/F6 lands here: a locked server (either end) asks first, as a connection would, and
    /// one tagged production where files change (`changed`) asks to go ahead, naming it.
    func enqueueTransfer(_ sources: [String], from: Endpoint = .local, to dir: String, on side: Endpoint = .local, name: String?, move: Bool,
                         prodAsked: Bool = false) {
        let locked = [from, side].compactMap { e -> SFTPTarget? in
            if case .sftp(let t) = e, ServerLock.needsUnlock(t) { t } else { nil }
        }
        let what = sources.count == 1 ? (name ?? (sources[0] as NSString).lastPathComponent) : "\(sources.count) items"
        let place = DirSync.place(side, dir)
        let title = "\(move ? "Move" : "Copy") \(what) → \(place)"
        let prod = prodAsked ? [] : Self.changed(from: from, to: side, move: move).filter(SavedServer.isProd)
        if !locked.isEmpty || !prod.isEmpty {
            Task {
                for t in locked where await !ServerLock.authorize(t) { return active.flash("\(t.host) stays locked") }
                let landing = side == .local ? [] : sources.map { (dir as NSString).appendingPathComponent(name ?? ($0 as NSString).lastPathComponent) }
                let unchecked = Self.uncheckedNote(landing, rules: ConfigCheck.rules(FileManager.default.contents(atPath: Self.validatorsPath)).rules)
                if !prod.isEmpty, await confirm(Self.prodTransfer("\(move ? "Move" : "Copy") \(sources.count == 1 ? "“\(what)”" : what) to \(place)?", sources, to: prod, move: move,
                                                                   unchecked: unchecked)) != 0 { return }
                enqueueTransfer(sources, from: from, to: dir, on: side, name: name, move: move, prodAsked: true)
            }
            return
        }
        ops.enqueue(FileJob(move ? .move : .copy, sources: sources, from: from, to: side, destDir: dir, targetName: name, sshEnv: SSHAskpass.env),
                    title: title)
    }

    /// Retry Failed in the Activity list: what `e` left out (`only`: these), again into the folders it was going
    /// into — as F5/F6 would, so a locked server asks for Touch ID and a production one asks to go ahead, once for
    /// all of them. One job per destination folder; one server's go one after another.
    func retryFailed(_ e: ActivityEntry, _ only: [FileJob.Failure]?) {
        let failures = (only ?? e.failed).filter { $0.dst != nil }
        guard !failures.isEmpty else { return NSSound.beep() }
        let move = e.kind == .move
        Task {
            guard await unlock([e.from, e.to]) else { return }
            let prod = Self.changed(from: e.from, to: e.to, move: move).filter(SavedServer.isProd)
            if !prod.isEmpty {
                let unchecked = Self.uncheckedNote(e.to == .local ? [] : failures.compactMap(\.dst),
                                                   rules: ConfigCheck.rules(FileManager.default.contents(atPath: Self.validatorsPath)).rules)
                let what = failures.count == 1 ? "“\((failures[0].src as NSString).lastPathComponent)”" : "\(failures.count) items"
                var c = Self.prodTransfer("Retry \(move ? "moving" : "copying") \(what)?", failures.map(\.src), to: prod, move: move, unchecked: unchecked)
                c.action = "Retry"
                guard await confirm(c) == 0 else { return }
            }
            for g in ActivityEntry.retryGroups(failures) {
                enqueueTransfer(g.sources, from: e.from, to: g.dir, on: e.to, name: g.name, move: move, prodAsked: true)
            }
            if only == nil { ops.history.change(e.id) { $0.retried = true } }
            ops.changed()
        }
    }

    /// The question before a copy or move changes production servers (`prod`): the items, the servers' strip, what
    /// may follow there. ↩ is Cancel (production).
    static func prodTransfer(_ title: String, _ sources: [String], to prod: [SFTPTarget], move: Bool, unchecked: String) -> Confirm {
        var c = Confirm(title, action: move ? "Move" : "Copy")
        c.on(prod)
        c.items = sources.map { Confirm.Item(name: ($0 as NSString).lastPathComponent) }
        c.note = "Files there may be overwritten" + (move ? " or removed." : ".") + (unchecked.isEmpty ? "" : " " + unchecked.trimmingCharacters(in: .newlines))
        return c
    }

    /// Show in the Activity list: `dir` in the active panel with `select` picked; a server's opens like its Favorite.
    func showItem(on side: Endpoint, in dir: String, select: String?) {
        showPanels()
        switch side {
        case .local:
            guard FileManager.default.fileExists(atPath: dir) else { return active.flash("No such folder: \(dir)", error: true) }
            active.navigate(to: dir, select: select)
            window.makeFirstResponder(active.table)
        case .sftp(let t):
            openBookmark((t, dir))
        }
    }

    /// Touch ID first for each locked server among `ends`, as listing one of its folders asks; false (and said so)
    /// if one stays locked. For what walks a whole tree there: compare, sync, search.
    func unlock(_ ends: [Endpoint]) async -> Bool {
        for case .sftp(let t) in ends where ServerLock.needsUnlock(t) {
            guard await ServerLock.authorize(t) else { active.flash("\(t.host) stays locked"); return false }
        }
        return true
    }

    /// Synchronize's jobs, once each locked server is unlocked — and okayed where they change a production server or
    /// delete on one (no Trash there), like F5 and F8 there. False if nothing was queued.
    func enqueueSync(_ jobs: [(job: FileJob, label: String)]) async -> Bool {
        func server(_ e: Endpoint) -> SFTPTarget? { if case .sftp(let t) = e { t } else { nil } }
        let changed = jobs.compactMap { server($0.job.to) }   // a delete's `to` is its server too
        let deleted = jobs.filter { $0.job.kind == .delete }.reduce(0) { $0 + $1.job.sources.count }
        let prod = changed.filter(SavedServer.isProd)
        guard await unlock(jobs.flatMap { [$0.job.from, $0.job.to] }) else { return false }
        if !prod.isEmpty || deleted > 0 {
            let hosts = Set(changed.map(\.host)).sorted().joined(separator: ", ")
            var c = Confirm("Synchronize with \(hosts)?", action: "Synchronize")
            c.on(prod)
            c.note = deleted > 0
                ? "\(deleted) item\(deleted == 1 ? "" : "s") only there \(deleted == 1 ? "is" : "are") deleted — a server has no Trash. This can't be undone."
                : "Files there may be overwritten."
            c.irreversible = deleted > 0
            guard await confirm(c) == 0 else { return false }
        }
        for (job, label) in jobs {
            syncJobs.add(job)   // the production log says "sync"
            ops.enqueue(job, title: label)
        }
        return true
    }

    /// Files a copy or move puts where a save is checked before it takes the file's place (sudoers, sshd_config …): they
    /// go in as they are — said in the production question. ponytail: the items it names, not what's inside a folder.
    nonisolated static func uncheckedNote(_ paths: [String], rules: [ConfigCheck]) -> String {
        let hit = paths.filter { ConfigCheck.rule(for: $0, in: rules).map { $0.check != nil && !$0.after } == true }
        guard let first = hit.first else { return "" }
        let what = hit.count == 1 ? "“\((first as NSString).lastPathComponent)” isn't" : "\(hit.count) of them aren't"
        return "\n\n\(what) checked: a copy goes in as it is. Open it with F4 and save it to have it checked."
    }

    /// The servers where a copy or move changes files: where it goes, and for a move where it comes from too.
    nonisolated static func changed(from: Endpoint, to: Endpoint, move: Bool) -> [SFTPTarget] {
        (move ? [from, to] : [to]).compactMap { if case .sftp(let t) = $0 { t } else { nil } }
    }

    private func readOnly() {
        active.flash(active.remote != nil ? "Not available on SFTP" : "Archives are read-only here — F5 Extract")
    }

    /// chmod / chown of the marked items (or the cursor's) as "644 me:staff": a part left as shown stays as each
    /// item has it (blank where they differ). Never through a symlink locally; on a server, ids are its own numbers.
    func attributesDialog() {
        if active.archive != nil { return readOnly() }
        let items = active.selectedItems, r = active.remote, paths = active.targetURLs.map(\.path)
        guard !items.isEmpty, r != nil || paths.count == items.count else { return NSSound.beep() }
        func common(_ f: (FileItem) -> UInt32) -> UInt32? { items.allSatisfy { f($0) == f(items[0]) } ? f(items[0]) : nil }
        func id(_ f: (FileItem) -> UInt32, user: Bool) -> String {
            guard let n = common(f), n != FileItem.unknown else { return "" }
            return r != nil ? String(n) : PanelViewController.idName(n, user: user)
        }
        let owner = id(\.uid, user: true), group = id(\.gid, user: false)
        // The owner keeps its colon ("1000:", ":20"): a number alone is a mode.
        let shown = [common { $0.mode & 0o7777 }.map { String(format: "%03o", $0) } ?? "", owner.isEmpty && group.isEmpty ? "" : owner + ":" + group]
            .filter { !$0.isEmpty }.joined(separator: " ")
        Task {
            let what = (items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items") + (r.map { " on \($0.target.host)" } ?? "")
            guard let text = await prompt("Permissions and owner of \(what):", value: shown, ok: "Apply",
                                          info: "Octal mode, then owner:group" + (r != nil ? " — the server's numbers (uid:gid)." : " (names or numbers)."),
                                          strip: r?.target),
                  text != shown else { return }
            let typed = Perms.parse(text), before = Perms.parse(shown)
            guard let ids = Perms.ids(typed.owner == before.owner ? "" : typed.owner, names: r == nil) else {
                return showError(JobErrorMessage(r != nil ? "On a server, give the owner and group as numbers (uid:gid)" : "No such user or group: “\(typed.owner)”"))
            }
            let mode = typed.mode == before.mode ? nil : typed.mode
            guard mode != nil || ids.uid != nil || ids.gid != nil else { return }
            // The owner was replaced by a lone number: a uid ("1000") would read as a mode and lock everyone out.
            if let mode, typed.owner.isEmpty, !before.owner.isEmpty {   // ↩ = Cancel: most likely a uid meant
                var c = Confirm("Set mode \(String(format: "%03o", mode)) (\(Perms.string(mode))) on \(what)?", on: r?.target, action: "Set Mode")
                (c.note, c.returnCancels) = ("To change the owner instead, keep its colon: “\(text.trimmingCharacters(in: .whitespaces)):”.", true)
                guard await confirm(c) == 0 else { return }
            }
            if let r {
                let each = items.map { ((r.dir as NSString).appendingPathComponent($0.name), $0) }
                return remoteOp("Permissions", r.target, paths: each.map(\.0)) { c in
                    for (path, it) in each {
                        let owner = ids.uid == nil && ids.gid == nil ? nil : (uid: ids.uid ?? it.uid, gid: ids.gid ?? it.gid)   // unknown: left as is
                        try c.setAttrs(path, mtime: nil, mode: mode, owner: owner)
                    }
                }
            }
            let errors = await Blocking.run { Perms.apply(paths, mode: mode, uid: ids.uid, gid: ids.gid) }
            active.reload()
            if !errors.isEmpty { showError(JobErrorMessage("Permissions and owner:\n" + errors.joined(separator: "\n"))) }
        }
    }

    func renameDialog() {
        if active.remote != nil { return remoteRename() }
        guard let url = active.cursorURL else { return NSSound.beep() }
        let old = url.lastPathComponent
        Task {
            guard let name = await prompt("Rename “\(old)” to:", value: old, ok: "Rename", selectBaseName: true),
                  name != old else { return }
            guard !name.contains("/") else { return showError(JobErrorMessage("A name can't contain “/”")) }
            let dst = url.deletingLastPathComponent().appendingPathComponent(name).path
            let failure = await Blocking.run(.userInitiated) { () -> Error? in   // off the main thread: a share that doesn't answer
                // Allow case-only renames (same inode on a case-insensitive volume).
                var a = stat(), b = stat()
                if lstat(dst, &b) == 0, lstat(url.path, &a) == 0, a.st_ino != b.st_ino { return JobErrorMessage("“\(name)” already exists.") }
                return rename(url.path, dst) == 0 ? nil : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if let failure { return showError(failure) }
            registerMoves("Rename", [(from: url.path, to: dst)])
            forgetGone([url.path])   // not after a case-only rename
            active.reload(select: name)
        }
    }

    /// A copy next to each marked item (or the cursor's): one under a typed name ("x.conf.bak", `.bak` selected, so ↩
    /// takes it), several with a typed suffix. A name that's taken is an error, never replaced; folders go whole.
    /// On a server it's that server's copy (`copy-data`, where it has it) — on a production one the name asked is the
    /// question, and the production log has its line.
    func copyAsDialog() {
        if active.archive != nil { return readOnly() }
        let r = active.remote
        let paths = r.map { r in (active.remoteSelection?.items ?? []).map { (r.dir as NSString).appendingPathComponent($0.name) } } ?? active.targetURLs.map(\.path)
        guard !paths.isEmpty else { return NSSound.beep() }
        let one = (paths[0] as NSString).lastPathComponent, host = r.map { " on \($0.target.host)" } ?? ""
        Task {
            if let r { guard await unlock([.sftp(r.target)]) else { return } }   // once, not per item
            let value = paths.count == 1 ? one + ".bak" : ".bak"
            guard let typed = await prompt(paths.count == 1 ? "Copy “\(one)”\(host) here as:" : "Copy \(paths.count) items\(host) here with the suffix:",
                                           value: value, ok: "Copy", select: paths.count == 1 ? NSRange(location: one.utf16.count, length: 4) : nil,
                                           strip: r?.target),
                  !typed.isEmpty else { return }
            guard !typed.contains("/") else { return showError(JobErrorMessage("A name can't contain “/”")) }
            let copies = Self.copiesAs(paths, typed)
            if paths.count == 1, copies[0].to == paths[0] { return }
            // A config a save would check goes in as it is: said, on a production server, as F5 says it.
            if let r, SavedServer.isProd(r.target),
               case let unchecked = Self.uncheckedNote(copies.map(\.to), rules: ConfigCheck.rules(FileManager.default.contents(atPath: Self.validatorsPath)).rules),
               !unchecked.isEmpty {
                var c = Confirm("Copy to \(SavedServer.name(for: r.target))?", on: r.target, action: "Copy")
                c.note = unchecked.trimmingCharacters(in: .newlines)
                guard await confirm(c) == 0 else { return }
            }
            let to = copies.map(\.to), taken: [String]
            if let r {
                let env = SSHAskpass.env
                switch await active.busy("Copy as on \(r.target.host)…", { flag in
                    try SFTPClient.session(r.target, env: env, cancel: flag) { Self.taken(to, on: $0) }
                }) {
                case .success(let t): taken = t
                case .failure(is CancellationError): return
                case .failure(let e): return showError(e)
                }
            } else {
                taken = await Blocking.run { Self.taken(to, on: nil) }   // off the main thread: a share that doesn't answer
            }
            if !taken.isEmpty {
                let names = taken.map { "“\(($0 as NSString).lastPathComponent)”" }.joined(separator: ", ")
                return showError(JobErrorMessage("\(names) already \(taken.count == 1 ? "exists" : "exist") — nothing copied."))
            }
            for (from, to) in copies {
                let (dir, name) = ((to as NSString).deletingLastPathComponent, (to as NSString).lastPathComponent)
                if let r {
                    enqueueTransfer([from], from: .sftp(r.target), to: dir, on: .sftp(r.target), name: name, move: false, prodAsked: true)
                } else {
                    ops.enqueue(FileJob(.copy, sources: [from], destDir: dir, targetName: name), title: "Copy “\((from as NSString).lastPathComponent)” as “\(name)”")
                }
            }
            active.unmarkAll()
        }
    }

    /// Those of `paths` already there (a link too), on the server `c` or here.
    nonisolated static func taken(_ paths: [String], on c: SFTPClient?) -> [String] {
        guard let c else { return paths.filter { var st = stat(); return lstat($0, &st) == 0 } }
        return zip(paths, c.lstat(paths)).compactMap { path, there in if case .success(_?) = there { path } else { nil } }
    }

    /// Where each copy goes: next to it, under `typed` (one) or with `typed` after its name (several).
    nonisolated static func copiesAs(_ paths: [String], _ typed: String) -> [(from: String, to: String)] {
        paths.map { p in
            let dir = (p as NSString).deletingLastPathComponent
            return (p, (dir as NSString).appendingPathComponent(paths.count == 1 ? typed : (p as NSString).lastPathComponent + typed))
        }
    }

    func mkdirDialog() {
        if active.remote != nil { return remoteMkdir() }
        if active.archive != nil { return readOnly() }
        Task {
            guard let name = await prompt("New folder (a/b/c creates nested folders):", value: "", ok: "Create"),
                  !name.isEmpty else { return }
            let path = resolve(name)
            // Off the main thread (a share that doesn't answer). Undo removes the outermost folder this call
            // creates ("a" for a/b/c if "a" was new).
            let made = await Blocking.run { () -> Result<String, Error> in
                let fm = FileManager.default
                guard !fm.fileExists(atPath: path) else { return .failure(JobErrorMessage("“\(name)” already exists.")) }
                var created = path
                while case let parent = (created as NSString).deletingLastPathComponent,
                      parent != created, !fm.fileExists(atPath: parent) { created = parent }
                return Result { try fm.createDirectory(atPath: path, withIntermediateDirectories: true); return created }
            }
            switch made {
            case .success(let created):
                registerCreated("New Folder", [created])
                active.reload(select: name.split(separator: "/").first.map(String.init))
            case .failure(let error): showError(error)
            }
        }
    }

    func newFileDialog() {
        if active.remote != nil { return remoteNewFile() }
        if active.archive != nil { return readOnly() }
        Task {
            guard let name = await prompt("New file:", value: "", ok: "Create"), !name.isEmpty else { return }
            let path = resolve(name)
            let error = await Blocking.run { () -> String? in   // off the main thread, as New Folder
                FileManager.default.fileExists(atPath: path) ? "“\(name)” already exists."
                    : FileManager.default.createFile(atPath: path, contents: nil) ? nil : "Couldn't create “\(name)”."
            }
            if let error { return showError(JobErrorMessage(error)) }
            registerCreated("New File", [path])
            active.reload(select: (path as NSString).lastPathComponent)
            openInEditor(URL(fileURLWithPath: path))
        }
    }

    func trash() {
        if active.remote != nil { return remoteDelete() }
        if active.path == NSHomeDirectory() + "/.Trash" || active.path.contains("/.Trashes/") { return putBack() }   // like Finder
        let srcs = active.targetURLs
        guard !srcs.isEmpty else { return NSSound.beep() }
        ops.enqueue(FileJob(.trash, sources: srcs.map(\.path)), title: "Trash \(Self.describe(srcs))")
        active.unmarkAll()
    }

    func deletePermanently() {
        if active.remote != nil { return remoteDelete() }
        let srcs = active.targetURLs
        guard !srcs.isEmpty else { return NSSound.beep() }
        var c = Confirm("Delete \(Self.describe(srcs)) permanently?", action: "Delete")
        (c.items, c.note, c.irreversible) = (active.listed(srcs), "They don't go to the Trash. This can't be undone.", true)
        Task {
            guard await confirm(c) == 0 else { return }
            ops.enqueue(FileJob(.delete, sources: srcs.map(\.path)), title: "Delete \(Self.describe(srcs))")
            active.unmarkAll()
        }
    }

    func multiRename() {
        let items = active.targetItems
        guard !items.isEmpty else { return NSSound.beep() }
        let dir = active.itemsDir
        MultiRename.show(on: window, dir: dir, items: items) { [unowned self] done in
            registerMoves("Rename \(done.count) Items", done)
            active.unmarkAll()
            active.reload(select: (done.first?.to as NSString?)?.lastPathComponent)
        }
    }

    // MARK: - Put Back (⌘⌫ / F8 inside the Trash)

    /// Path in the Trash → where it came from, for what Kermo trashed (Finder keeps its own record in the
    /// Trash's private .DS_Store). Entries are dropped once the item is gone from the Trash — only on ENOENT,
    /// so a missing Full Disk Access grant (EPERM) doesn't wipe the record.
    /// Read, changed and saved on `trashLogQueue`: each entry is an lstat (a Trash on a share that doesn't answer
    /// never returns), and one queue keeps the changes in order — none lost to another read at the same time.
    nonisolated private static func changeTrashLog<T>(_ change: (inout [String: TrashEntry]) -> T) -> T {
        let (loaded, problem) = Config.loadKeeping("trash.json", as: [String: TrashEntry].self)
        if let problem { Task { @MainActor in (NSApp.delegate as? AppDelegate)?.active.flash(problem, error: true) } }   // read off launch: said now
        let saved = loaded ?? [:]
        var log = saved.filter { var s = stat(); return lstat($0.key, &s) == 0 || errno != ENOENT }
        let result = change(&log)
        if log != saved { Config.save("trash.json", log) }
        return result
    }
    nonisolated private static let trashLogQueue = DispatchQueue(label: "trash.json", qos: .utility)

    func recordTrash(_ pairs: [(from: String, to: String)]) {
        guard !pairs.isEmpty else { return }
        Self.trashLogQueue.async { Self.changeTrashLog { log in for p in pairs { log[p.to] = TrashEntry(origin: p.from, at: p.to) } } }
    }

    /// Keeps the log in step with undo/redo: an item leaving the Trash loses its entry (so a later item Finder
    /// trashes under the same name isn't put back there), one moved into the Trash gets one.
    nonisolated static func trashLog(_ log: [String: TrashEntry], after pairs: [(from: String, to: String)]) -> [String: TrashEntry] {
        var log = log
        for p in pairs {
            log[p.from] = nil
            if p.to.hasPrefix(NSHomeDirectory() + "/.Trash/") || p.to.contains("/.Trashes/") { log[p.to] = TrashEntry(origin: p.from, at: p.to) }
        }
        return log
    }

    func putBack() {
        let urls = active.targetURLs
        Task {
            let log = await withCheckedContinuation { c in Self.trashLogQueue.async { c.resume(returning: Self.changeTrashLog { $0 }) } }
            let logged = urls.compactMap { u in log[u.path].map { (from: u.path, entry: $0) } }
            guard !logged.isEmpty else { return active.flash("Only what Kermo moved to the Trash can be put back here — use Finder for the rest") }
            // off the main thread: a share that stopped answering
            let (pairs, others, moved) = await Blocking.run(.userInitiated) { () -> ([(from: String, to: String)], [String], Result<Void, Error>) in
                // Only the item Kermo put there (F-12): one Finder trashed later under a name that came free isn't moved
                // to where the old one was.
                let (pairs, others) = TrashEntry.same(logged)
                for p in pairs { try? FileManager.default.createDirectory(atPath: (p.to as NSString).deletingLastPathComponent, withIntermediateDirectories: true) }
                return (pairs, others, Result { try BatchRename.run(pairs) })   // never overwrites
            }
            if !others.isEmpty {
                showError(JobErrorMessage("Not put back — the Trash holds another item under this name now:\n" + others.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n")))
            }
            guard !pairs.isEmpty else { return }
            if case .failure(let error) = moved { return showError(JobErrorMessage("Put Back: \(error.localizedDescription)")) }
            registerMoves("Put Back", pairs)
            Self.trashLogQueue.async { Self.changeTrashLog { log in for p in pairs { log[p.from] = nil } } }
            if pairs.count + others.count < urls.count { active.flash("Put back \(pairs.count) of \(urls.count) — the rest weren't trashed by Kermo") }
            active.unmarkAll()
            panels.forEach { $0.reload() }
        }
    }

    // MARK: - Undo / redo (Edit menu, ⌘Z / ⌘⇧Z) through the window's NSUndoManager

    /// Registers an undo that moves every `to` back to `from`; running it registers the reverse (redo).
    func registerMoves(_ title: String, _ pairs: [(from: String, to: String)]) {
        guard !pairs.isEmpty else { return }
        registerMoves(title, MoveRecord(done: (pairs, [])))
    }

    /// The same for what `record` says was moved: an undo/redo's renames and its move jobs across volumes — what
    /// those actually moved (and where: Keep Both) is read when it runs. The record is the target: filled in, or
    /// taken back, once the undo/redo that registered it has done its disk work (`fill`).
    private func registerMoves(_ title: String, _ record: MoveRecord) {
        guard let um = window.undoManager else { return }
        um.registerUndo(withTarget: record) { [self, record] _ in   // kept by the handler: the undo manager doesn't keep its target
            MainActor.assumeIsolated {
                performMoves(title) {   // run after the undo/redo work before it: the record is filled in by then
                    record.done.flatMap { Self.moved($0.renames, $0.jobs) }?.map { (from: $0.to, to: $0.from) }
                }
            }
        }
        um.setActionName(title)
    }

    /// An undo's or redo's own undo/redo, registered at once — after an await it would land on the undo stack, not
    /// the redo one — and filled in by `fill` once its disk work is done.
    private func registerPendingMoves(_ title: String) -> MoveRecord {
        let record = MoveRecord(done: nil)
        registerMoves(title, record)
        return record
    }

    /// What the undo/redo moved; nothing: its own undo/redo is taken back.
    private func fill(_ record: MoveRecord, _ renames: [(from: String, to: String)], _ jobs: [FileJob]) {
        if renames.isEmpty && jobs.isEmpty { window.undoManager?.removeAllActions(withTarget: record) } else { record.done = (renames, jobs) }
    }

    /// Undo/redo disk work off the main thread (thousands of items on a share), one after another as asked: an undo
    /// of a rename, then of the move before it, must find the item where the first put it.
    private func afterUndoWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = undoWork
        undoWork = Task { await previous?.value; await work() }
    }

    /// What a move undo/redo did: its renames plus what its jobs moved (a skipped item: nothing, Keep Both: under
    /// the new name) — never what it was meant to move. nil while a job hasn't finished.
    nonisolated static func moved(_ renames: [(from: String, to: String)], _ jobs: [FileJob]) -> [(from: String, to: String)]? {
        for j in jobs {
            let s = j.progress.state
            if s == .queued ? !j.isCancelled : s == .scanning || s == .running { return nil }
        }
        return renames + jobs.flatMap { $0.results.map { (from: $0.src, to: $0.dst) } }
    }

    /// Undo of something created = move it to the Trash (redo = put it back). Only the items made then (F-12): one
    /// renamed in Finder since, with another in its place, leaves that other one where it is.
    func registerCreated(_ title: String, _ paths: [String]) {
        guard !paths.isEmpty, let um = window.undoManager else { return }
        let made = Made()
        Task { made.inodes = await Blocking.run(.utility) { paths.map(TrashEntry.inode) } }   // read off the main thread, once
        um.registerUndo(withTarget: self) { app in
            MainActor.assumeIsolated {
                let record = app.registerPendingMoves(title)
                let inodes = made.inodes
                app.afterUndoWork {
                    let r = await Blocking.run(.userInitiated) { () -> (trashed: [(from: String, to: String)], errors: [String]) in
                        let (same, others) = TrashEntry.same(inodes.map { zip(paths, $0).map { (from: $0, entry: TrashEntry(origin: "", ino: $1)) } }
                                                             ?? paths.map { (from: $0, entry: TrashEntry(origin: "", ino: nil)) })
                        let r = Self.trash(same.map(\.from))
                        return (r.trashed, r.errors + others.map { "“\(($0 as NSString).lastPathComponent)”: another item has this name now — left as it is" })
                    }
                    let (trashed, errors) = (r.trashed, r.errors)
                    app.fill(record, trashed, [])
                    app.recordTrash(trashed)
                    app.panels.forEach { $0.reload() }
                    // A volume without a Trash (SMB, some sticks) refuses: say so, the copy is still there.
                    if !errors.isEmpty { app.showError(JobErrorMessage("Can't undo \(title.lowercased()):\n" + errors.joined(separator: "\n"))) }
                }
            }
        }
        um.setActionName(title)
    }

    /// What an undoable creation made, by inode: nil until read.
    @MainActor private final class Made { var inodes: [UInt64?]? }

    /// Moves each path to the Trash: where each one went, and a line for each that couldn't go.
    nonisolated static func trash(_ paths: [String]) -> (trashed: [(from: String, to: String)], errors: [String]) {
        var trashed: [(from: String, to: String)] = [], errors: [String] = []
        for p in paths {
            var out: NSURL?
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &out)
                if let t = out?.path { trashed.append((from: p, to: t)) }
            } catch {
                errors.append("“\((p as NSString).lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        return (trashed, errors)
    }

    /// Undo/redo of a move: renames where rename(2) works, a move job for what has to cross volumes (Mac ↔ a
    /// stick: EXDEV) — one per folder it goes back to, plus one per item that comes back under another name.
    nonisolated static func splitMoves(_ pairs: [(from: String, to: String)], sameVolume: (String, String) -> Bool = FileJob.sameVolume)
        -> (renames: [(from: String, to: String)], jobs: [FileJob]) {
        var renames: [(from: String, to: String)] = [], jobs: [FileJob] = [], keepName: [String: [String]] = [:]
        for p in pairs {
            let dir = (p.to as NSString).deletingLastPathComponent, name = (p.to as NSString).lastPathComponent
            if sameVolume(p.from, dir) {
                renames.append(p)
            } else if (p.from as NSString).lastPathComponent == name {
                keepName[dir, default: []].append(p.from)
            } else {
                jobs.append(FileJob(.move, sources: [p.from], destDir: dir, targetName: name))
            }
        }
        return (renames, jobs + keepName.sorted { $0.key < $1.key }.map { FileJob(.move, sources: $0.value, destDir: $0.key) })
    }

    private func updateTrashLog(after pairs: [(from: String, to: String)]) {
        Self.trashLogQueue.async { Self.changeTrashLog { $0 = Self.trashLog($0, after: pairs) } }
    }

    /// Never overwrites: BatchRename refuses if a target exists now (e.g. a new file took the old name); a move
    /// job across volumes asks first. Its redo is registered right away; what the jobs move is read when it runs.
    /// `pairs` is asked once the undo/redo work before it is done; nil: a move job of it is still running.
    private func performMoves(_ title: String, _ pairs: @escaping @MainActor () -> [(from: String, to: String)]?) {
        let record = registerPendingMoves(title)
        afterUndoWork { [self] in
            guard let pairs = pairs() else {
                fill(record, [], [])
                return showError(JobErrorMessage("Can't undo or redo \(title.lowercased()) while its move between volumes is still running"))
            }
            do {
                let (renames, jobs) = try await Blocking.run(.userInitiated) {
                    let (renames, jobs) = Self.splitMoves(pairs)
                    try BatchRename.run(renames)
                    return (renames, jobs)
                }
                for job in jobs {
                    replayJobs.append(job)
                    ops.enqueue(job, title: "\(title) \(Self.describe(job.sources.map { URL(fileURLWithPath: $0) }))")
                }
                fill(record, renames, jobs)
                updateTrashLog(after: renames)   // the jobs': once they've run (jobFinished)
            } catch {
                fill(record, [], [])
                showError(JobErrorMessage("Can't undo \(title.lowercased()): \(error.localizedDescription)"))
            }
            panels.forEach { $0.reload() }
        }
    }

    func jobFinished(_ job: FileJob) {
        AuditLog.write(job, sync: syncJobs.contains(job))
        reloadVolumes()   // Locations' free space
        syncJobs.remove(job)
        // Local panels follow the disk (FSEvents); a server panel has to ask again.
        for p in panels {
            if let r = p.remote, [job.from, job.to].contains(where: { if case .sftp(let t) = $0 { t.asUser == r.target.asUser } else { false } }) { p.reload() }
        }
        if job.from == .local, job.kind != .copy { forgetGone(job.sources) }   // F6, F8, Trash
        let pairs = job.results.map { (from: $0.src, to: $0.dst) }   // empty for a server: no undo there
        // An undo/redo's own job: performMoves registered what comes next already.
        if let i = replayJobs.firstIndex(where: { $0 === job }) { replayJobs.remove(at: i); return updateTrashLog(after: pairs) }
        switch job.kind {
        case .move: registerMoves("Move", pairs)
        case .trash:
            registerMoves("Move to Trash", pairs)   // undo = put back
            recordTrash(pairs)
        case .copy: registerCreated("Copy", pairs.map(\.to))
        case .delete: break
        }
    }

    private static func describe(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
    }

    /// Absolute path from user input: expands "~", resolves relative to the active panel.
    func resolve(_ input: String) -> String {
        let p = (input as NSString).expandingTildeInPath
        let abs = p.hasPrefix("/") ? p : (active.path as NSString).appendingPathComponent(p)
        return (abs as NSString).standardizingPath
    }
}

/// What an undo/redo moved (`registerMoves`): nil until its disk work is done.
@MainActor final class MoveRecord {
    var done: (renames: [(from: String, to: String)], jobs: [FileJob])?
    init(done: (renames: [(from: String, to: String)], jobs: [FileJob])?) { self.done = done }
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
