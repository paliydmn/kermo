import AppKit
import DFMCore

/// Every user action is a named command: bound to keys, shown in menus and the F-key bar.
/// One table here = one place to look up or rebind anything (keymap.json later reads the same ids).
struct Command {
    let id: String
    let title: String
    var keys: [Shortcut]
    let menu: String?                     // menu to list it in; nil = keyboard only
    var short: String                     // key bar label; "" = title
    let aliases: String                   // extra words the search matches ("zip" → Compress)
    let run: @MainActor (AppDelegate) -> Void
}

private func cmd(_ id: String, _ title: String, _ keys: [String], menu: String? = nil,
                 short: String = "", aliases: String = "", _ run: @escaping @MainActor (AppDelegate) -> Void) -> Command {
    let parsed = keys.map { spec in
        guard let s = Shortcut(spec) else { preconditionFailure("bad shortcut spec \(spec) for \(id)") }
        return s
    }
    return Command(id: id, title: title, keys: parsed, menu: menu, short: short, aliases: aliases, run: run)
}

extension AppDelegate {
    func makeCommands() -> [Command] { [
        // Navigation
        cmd("panel.switch", "Next Panel", ["tab"]) { $0.focusNext() },
        cmd("open", "Open", ["return", "kpenter"]) { $0.active.openCursor(intoPackage: false) },
        cmd("open.inside", "Open Inside", ["cmd+down"], menu: "Go", short: "Open inside") { $0.active.openCursor(intoPackage: true) },
        cmd("go.up", "Enclosing Folder", ["cmd+up", "backspace"], menu: "Go", short: "Up") { $0.active.goUp() },
        cmd("go.back", "Back", ["cmd+["], menu: "Go") { $0.active.goBack() },
        cmd("go.forward", "Forward", ["cmd+]"], menu: "Go") { $0.active.goForward() },
        cmd("go.home", "Home", ["cmd+shift+h"], menu: "Go", short: "Home") { $0.active.navigate(to: NSHomeDirectory()) },
        cmd("go.root", "Computer Root", ["cmd+shift+/"], menu: "Go", short: "Root") { $0.active.navigate(to: "/") },
        cmd("go.path", "Go to Path…", ["cmd+l", "cmd+shift+g"], menu: "Go", short: "Go to path", aliases: "path location") { $0.active.beginPathEditing() },
        cmd("go.jump", "Jump to Folder…", ["cmd+p"], menu: "Go", short: "Jump", aliases: "go to folder recent frecency") { $0.showJump() },
        cmd("go.tree", "Folder Tree…", ["f10", "opt+0", "opt+f10", "cmd+shift+t"], menu: "Go", short: "Tree", aliases: "folder tree") { app in
            let panel = app.active
            DirTree.show(in: app.window, over: panel.view, at: panel.path, showHidden: app.defaults.bool(forKey: "showHidden")) { panel.navigate(to: $0) }
        },
        cmd("go.connect", "Connect to Server…", ["ctrl+cmd+k"], menu: "Go", short: "Connect", aliases: "sftp ssh smb nfs server remote") { $0.showConnect() },
        cmd("ssh.new", "New SSH Session…", ["cmd+k"], menu: "Go", short: "SSH", aliases: "ssh shell remote terminal server") { $0.showConnect(ssh: true) },
        cmd("server.new", "New Server…", [], menu: "Go", short: "New server", aliases: "ssh sftp server connection bookmark save") {
            $0.editServer(SavedServer(), title: "New Server")
        },
        cmd("ssh.config", "Edit SSH Config", [], menu: "Go", short: "SSH config", aliases: "ssh config hosts ~/.ssh/config") { $0.editSSHConfig() },
        cmd("ssh.reconnect", "Reconnect SSH Session", [], menu: "Go", short: "Reconnect", aliases: "ssh") { app in
            if app.terminal.isShown { app.terminal.reconnect() } else { NSSound.beep() }
        },
        cmd("server.disconnect", "Disconnect Server", [], menu: "Go", short: "Disconnect", aliases: "logout close connection ssh") { app in
            let t = app.terminal.isShown ? app.terminal.current?.target : app.active.remote?.target
            if let t { app.disconnect(t) } else { NSSound.beep() }
        },
        cmd("remote.open", "Open Remote File", []) { $0.remoteOpen(.open) },
        cmd("remote.archive", "List Remote Archive", []) { $0.remoteArchiveList() },
        cmd("go.bookmark", "Bookmark This Folder", ["cmd+d"], menu: "Go", short: "Bookmark", aliases: "favorite star pin") { $0.toggleBookmark() },
        cmd("go.linktarget", "Go to Link Target", ["cmd+j"], menu: "Go", short: "Link target") { $0.goToLinkTarget() },
        cmd("go.volumes", "Volumes…", ["cmd+shift+v", "opt+f1"], menu: "Go", short: "Volumes", aliases: "disks drives mounts") { $0.showVolumes() },
        cmd("app.about", "About Kermo", [], menu: "Kermo", short: "About", aliases: "info version help") { _ in
            // Name, icon, version (build) and copyright come from Info.plist (build.sh); only the description is ours.
            let credits = NSMutableAttributedString(string: "A fast 2–4 panel file manager for macOS, built with Swift and AppKit.\n\n",
                                                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
            credits.append(NSAttributedString(string: "github.com/paliydmn/kermo", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://github.com/paliydmn/kermo")!]))
            credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        },
        cmd("help.keys", "Keyboard Shortcuts", ["f1", "opt+1"], menu: "Kermo", short: "Keys", aliases: "help shortcuts cheat sheet") {
            KeyHelp.show(over: $0.window, commands: $0.commands)
        },
        cmd("app.palette", "Search…", ["cmd+shift+p", "f9", "opt+9"], menu: "Go", short: "Commands", aliases: "palette all commands") { $0.search.focus() },

        // Tabs
        // While the terminal is up (⌃O) these act on its tabs.
        cmd("tab.new", "New Tab", ["cmd+t"], menu: "View", short: "New tab") { app in
            if app.terminal.isShown { app.terminal.newShell(cwd: app.active.path) } else { app.active.newTab() }
        },
        cmd("tab.close", "Close Tab", ["cmd+w"], menu: "View", short: "Close tab") { app in
            if let w = AppDelegate.windowToClose(key: NSApp.keyWindow, main: app.window) { w.performClose(nil) }
            else if app.terminal.isShown { app.terminal.close() } else { app.active.closeTab() }
        },
        cmd("tab.next", "Next Tab", ["ctrl+tab", "cmd+shift+]"], menu: "View", short: "Next tab") { app in
            if app.terminal.isShown { app.terminal.switchTab(by: 1) } else { app.active.switchTab(by: 1) }
        },
        cmd("tab.prev", "Previous Tab", ["ctrl+shift+tab", "cmd+shift+["], menu: "View", short: "Prev tab") { app in
            if app.terminal.isShown { app.terminal.switchTab(by: -1) } else { app.active.switchTab(by: -1) }
        },

        // Panels & view
        cmd("panel.swap", "Swap Panels", ["cmd+u"], menu: "View", short: "Swap", aliases: "swap panels") { $0.swapPanels() },
        cmd("panel.add", "Add Panel", ["cmd+opt+n"], menu: "View", short: "Add panel", aliases: "panels split") { $0.addPanel() },
        cmd("panel.close", "Close Panel", ["cmd+opt+w"], menu: "View", short: "Close panel") { $0.closePanel() },
    ] + (1...4).map { n in
        cmd("panel.focus\(n)", "Go to Panel \(n)", ["cmd+\(n)"], menu: "View", short: "Panel \(n)") { $0.focusPanel(n - 1) }
    } + [
        cmd("panel.same", "Same Folder in Other Panel", ["opt+="], menu: "View", short: "Same folder") { app in
            if let r = app.active.remote { app.other.loadRemote(r.target, dir: r.dir, select: nil) } else { app.other.navigate(to: app.active.path) }
        },
        cmd("view.sidebar", "Show/Hide Sidebar", ["ctrl+cmd+s"], menu: "View", short: "Sidebar", aliases: "places favorites") { $0.toggleSidebar() },
        cmd("view.sidebarFocus", "Focus Sidebar", ["ctrl+shift+s"], menu: "View", aliases: "places keyboard") { $0.focusSidebar() },
        cmd("view.hidden", "Show Hidden Files", ["cmd+shift+."], menu: "View", short: "Hidden", aliases: "dotfiles show hidden files") { $0.toggleHidden() },
        cmd("view.perms", "Show Permissions & Owner", [], menu: "View", short: "Perms", aliases: "mode rwx owner group columns") {
            $0.togglePerms()
        },
        cmd("view.gitOnly", "Show Only Git Changes", ["ctrl+g"], menu: "View", short: "Git only", aliases: "git status dirty edited filter source control") {
            $0.toggleGitOnly()
        },
        cmd("git.changes", "Git Changes", ["ctrl+shift+g"], menu: "View", short: "Git changes", aliases: "git status dirty edited source control list") {
            $0.active.showGitChanges()
        },
        cmd("view.refresh", "Refresh", ["cmd+r"], menu: "View", short: "Refresh") { $0.active.reload() },
        cmd("view.theme", "Theme…", [], menu: "View", aliases: "colors dark midnight commander solarized") { $0.showThemes() },
        cmd("view.filter", "Quick Filter", ["/"], menu: "View", short: "Filter", aliases: "filter glob regex") { $0.active.beginFilter() },
        cmd("view.filterPresets", "Filter Presets…", ["cmd+/"], menu: "View", short: "Filter presets", aliases: "filter glob") { $0.showFilterPresets() },
        cmd("view.filterPresets.edit", "Edit Filter Presets…", [], menu: "Kermo") {
            _ = $0.filterPresets()   // writes the example file on first use
            $0.openInEditor(URL(fileURLWithPath: Config.path("filters.json")))
        },
        cmd("view.quickview", "Quick View Panel", ["ctrl+q"], menu: "View", short: "Preview", aliases: "quick view") { $0.toggleQuickView() },
        cmd("view.terminal", "Terminal (hide panels)", ["ctrl+o"], menu: "View", short: "Terminal", aliases: "shell console") { $0.toggleTerminal() },
        cmd("term.bigger", "Bigger Terminal Text", ["cmd+=", "cmd+shift+="], menu: "View", aliases: "font size zoom in larger") { app in
            if app.terminal.isShown { app.terminal.zoom(by: 1) } else { NSSound.beep() }
        },
        cmd("term.smaller", "Smaller Terminal Text", ["cmd+-"], menu: "View", aliases: "font size zoom out") { app in
            if app.terminal.isShown { app.terminal.zoom(by: -1) } else { NSSound.beep() }
        },
        cmd("view.dirsizes", "Calculate Folder Sizes", ["opt+space"], menu: "View", short: "Sizes", aliases: "folder size disk usage du") { $0.active.computeAllDirSizes() },

        // Marking (MC style: cursor ≠ marked set)
        cmd("mark.toggle", "Mark / Unmark", ["space"], menu: "Mark", short: "Mark") { $0.active.toggleMark(move: 1) },
        cmd("mark.down", "Mark and Move Down", ["shift+down"], short: "Mark ↓") { $0.active.toggleMark(move: 1) },
        cmd("mark.up", "Mark and Move Up", ["shift+up"], short: "Mark ↑") { $0.active.toggleMark(move: -1) },
        cmd("mark.all", "Mark All", ["cmd+a"], menu: "Mark", short: "Mark all") { $0.active.markAll() },
        cmd("mark.none", "Unmark All", ["cmd+shift+a"], menu: "Mark", short: "Unmark all", aliases: "deselect") { $0.active.unmarkAll() },
        cmd("mark.invert", "Invert Marks", ["shift+8", "kpstar"], menu: "Mark", short: "Invert", aliases: "invert selection marks") { $0.active.invertMarks() },
        cmd("panel.compare", "Compare Folders (mark differences)", ["shift+f2"], menu: "Mark", short: "Compare", aliases: "compare folders difference") { $0.compareFolders() },
        cmd("panel.sync", "Synchronize Folders…", ["cmd+shift+s"], menu: "File", short: "Sync", aliases: "synchronize mirror folders") { app in
            guard app.active.archive == nil, app.other.archive == nil, app.active.searchTitle == nil, app.other.searchTitle == nil
            else { return app.active.flash("Synchronize works between two folders") }
            let (l, r) = app.panels.firstIndex { $0 === app.active }! < app.panels.firstIndex { $0 === app.other }! ? (app.active, app.other) : (app.other, app.active)
            let (ld, rd, sides) = (l.currentDir, r.currentDir, (l.endpoint, r.endpoint))
            Task { if await app.unlock([sides.0, sides.1]) { SyncWindow.show(left: ld, right: rd, sides: sides) { await app.enqueueSync($0) } } }
        },
    ] + SidebarModel.tagColors.enumerated().map { i, color in
        cmd("tag.\(i + 1)", "Tag \(NSWorkspace.shared.fileLabels[color])", ["ctrl+\(i + 1)"], menu: "Mark",
            short: NSWorkspace.shared.fileLabels[color]) { $0.toggleTag(color) }
    } + [
        cmd("tag.clear", "Remove All Tags", ["ctrl+0"], menu: "Mark", short: "No tags") { $0.applyTags($0.active.targetURLs) { _, _ in [] } },
        cmd("tag.edit", "Tags…", ["ctrl+t"], menu: "Mark", short: "Tags", aliases: "finder tag label color") { $0.tagsDialog() },
        cmd("mark.mask", "Mark by Mask…", ["shift+=", "kpplus"], menu: "Mark", short: "Mark mask", aliases: "select glob pattern") { $0.maskDialog(mark: true) },
        cmd("mark.unmask", "Unmark by Mask…", ["-", "kpminus"], menu: "Mark", short: "Unmark mask") { $0.maskDialog(mark: false) },

        // File operations
        cmd("file.view", "View", ["f3", "opt+3"], menu: "File", short: "View", aliases: "viewer read log") { $0.viewFile() },
        cmd("archive.open", "Open from Archive", []) { $0.openFromArchive(view: false) },
        cmd("file.compress", "Compress…", ["opt+f5"], menu: "File", short: "Compress", aliases: "zip tar archive pack") { $0.compressDialog() },
        cmd("file.extract", "Extract…", ["opt+f9"], menu: "File", short: "Extract", aliases: "unzip untar unpack archive") { $0.extractDialog() },
        cmd("file.edit", "Edit", ["f4", "opt+4"], menu: "File", short: "Edit", aliases: "editor") { $0.editFile() },
        cmd("file.copy", "Copy To…", ["f5", "opt+5"], menu: "File", short: "Copy") { $0.transferDialog(move: false) },
        cmd("file.move", "Move To…", ["f6", "opt+6"], menu: "File", short: "Move") { $0.transferDialog(move: true) },
        cmd("file.rename", "Rename…", ["shift+f6", "shift+opt+6"], menu: "File", short: "Rename") { $0.renameDialog() },
        cmd("file.multirename", "Multi-Rename…", ["cmd+shift+m"], menu: "File", short: "Rename many", aliases: "batch multi rename") { $0.multiRename() },   // ⌘M minimizes
        cmd("file.mkdir", "New Folder…", ["f7", "opt+7", "cmd+shift+n"], menu: "File", short: "MkDir", aliases: "mkdir new folder directory") { $0.mkdirDialog() },
        cmd("file.new", "New File…", ["shift+f4", "shift+opt+4"], menu: "File", short: "New file") { $0.newFileDialog() },
        cmd("file.trash", "Move to Trash", ["f8", "opt+8", "cmd+backspace", "delete"], menu: "File", short: "Trash", aliases: "delete remove") { $0.trash() },
        cmd("file.putback", "Put Back", [], menu: "File", aliases: "restore undelete trash") { $0.putBack() },
        cmd("file.delete", "Delete Permanently…", ["shift+f8", "shift+opt+8", "cmd+opt+backspace", "shift+delete"], menu: "File", short: "Delete", aliases: "remove rm permanently") {
            $0.deletePermanently()
        },
        cmd("file.quicklook", "Quick Look", ["cmd+y"], menu: "File", short: "Quick Look", aliases: "preview") { $0.active.toggleQuickLook() },
        cmd("search", "Search Files…", ["opt+f7", "cmd+f"], menu: "File", short: "Find", aliases: "search files content spotlight") { $0.searchDialog() },
        cmd("file.reveal", "Reveal in Finder", ["cmd+shift+r"], menu: "File", short: "Reveal", aliases: "show in finder") {
            NSWorkspace.shared.activateFileViewerSelecting($0.active.targetURLs)
        },
        cmd("file.terminal", "Open in Terminal", ["cmd+opt+t"], menu: "File", short: "Terminal here", aliases: "shell console") { $0.openTerminal() },
        cmd("file.symlink", "Create Symbolic Link…", ["cmd+opt+l"], menu: "File", short: "Symlink", aliases: "link ln") { $0.linkDialog(hard: false) },
        cmd("file.hardlink", "Create Hard Link…", [], menu: "File") { $0.linkDialog(hard: true) },
        cmd("file.attrs", "Permissions & Owner…", ["cmd+opt+a"], menu: "File", short: "Attributes", aliases: "chmod chown chgrp mode rwx owner group permissions") {
            $0.attributesDialog()
        },
        cmd("file.split", "Split File…", [], menu: "File", aliases: "chunks parts") { $0.splitDialog() },
        cmd("file.combine", "Combine Parts…", [], menu: "File", aliases: "join merge chunks") { $0.combineDialog() },
        cmd("file.diff", "Compare Files (diff)", ["cmd+shift+d"], menu: "File", short: "Diff", aliases: "compare files") { $0.diffFiles() },   // not ⌘⌥D: macOS takes it (Dock hiding)
        cmd("server.history", "Server File History…", [], menu: "File", aliases: "versions revert previous backup undo save sftp") { $0.serverFileHistory() },
        cmd("git.diff", "Git Diff", ["ctrl+d"], menu: "File", short: "Git diff", aliases: "git difference changes against head") { $0.gitDiff() },
        cmd("git.log", "Git Log of File", ["ctrl+l"], menu: "File", short: "Git log", aliases: "git history commits follow patch") { $0.gitHistory(blame: false) },
        cmd("git.blame", "Git Blame", ["ctrl+shift+l"], menu: "File", short: "Git blame", aliases: "git annotate who changed lines") { $0.gitHistory(blame: true) },
        cmd("git.stage", "Git Stage", ["ctrl+shift+a"], menu: "File", short: "Stage", aliases: "git add index") { $0.gitStage(undo: false) },
        cmd("git.unstage", "Git Unstage", ["ctrl+shift+u"], menu: "File", short: "Unstage", aliases: "git reset restore staged index") { $0.gitStage(undo: true) },
        cmd("file.eject", "Eject Volume", ["cmd+opt+e"], menu: "File", short: "Eject", aliases: "unmount disk") { $0.ejectVolume() },
        cmd("file.info", "Get Info", ["cmd+i"], menu: "File", short: "Info", aliases: "get info permissions chmod chown owner hash checksum xattr quarantine") {
            guard let url = $0.active.infoURL else { return $0.active.flash("Get Info is for this Mac's files — on a server, ⌘⌥A sets permissions and owner") }
            InfoWindow.show(url)
        },

        // Shell
        cmd("usermenu", "User Menu…", ["f2", "opt+2"], menu: "File", short: "Menu", aliases: "user menu") { $0.showUserMenu() },
        cmd("cmdline.focus", "Command Line", ["cmd+e"], menu: "Go", short: "Cmd line", aliases: "command line shell") { $0.focusCommandLine() },
        cmd("cmdline.insert", "Insert Name into Command Line", ["ctrl+return"], short: "Insert name") { $0.insertIntoCommandLine(paths: false) },
        cmd("cmdline.insertPaths", "Insert Paths into Command Line", ["ctrl+shift+return"], short: "Insert paths", aliases: "marked full paths") {
            $0.insertIntoCommandLine(paths: true)
        },

        // Administrator (password prompt per action)
        cmd("admin.copy", "Copy as Administrator…", [], menu: "Admin", aliases: "root sudo") { $0.adminTransfer(move: false) },
        cmd("admin.move", "Move as Administrator…", [], menu: "Admin", aliases: "root sudo") { $0.adminTransfer(move: true) },
        cmd("admin.mkdir", "New Folder as Administrator…", [], menu: "Admin", aliases: "root sudo") { $0.adminMkdir() },
        cmd("admin.delete", "Delete as Administrator…", [], menu: "Admin", aliases: "root sudo rm") { $0.adminDelete() },
        cmd("admin.shell", "Root Shell Here (Terminal)", [], menu: "Admin", aliases: "root sudo") { $0.runShell("sudo -s", in: .terminalApp) },
        cmd("admin.rootPanel", "Reopen Panel as Root", [], menu: "Admin", aliases: "root sudo server etc") { $0.reopenPanel(asRoot: true) },
        cmd("admin.userPanel", "Reopen Panel as User", [], menu: "Admin", aliases: "root sudo server user") { $0.reopenPanel(asRoot: false) },

        // Clipboard
        cmd("edit.copyPath", "Copy Path", ["cmd+shift+c"], menu: "Edit", short: "Copy path", aliases: "path clipboard") { $0.copyToPasteboard($0.active.targetURLs.map(\.path)) },
        cmd("edit.copyName", "Copy Name", ["cmd+opt+c"], menu: "Edit", short: "Copy name", aliases: "clipboard") {
            $0.copyToPasteboard($0.active.targetURLs.map(\.lastPathComponent))
        },
        cmd("edit.pasteMove", "Move Here", ["cmd+opt+v"], menu: "Edit", short: "Move here") { $0.pasteFiles(move: true) },

        // Configuration (~/.config/dfilemanager)
        cmd("app.keymap", "Edit Keymap…", [], menu: "Kermo", aliases: "shortcuts keys rebind") { $0.editKeymap() },
        cmd("app.config", "Open Config Folder", [], menu: "Kermo") {
            try? FileManager.default.createDirectory(atPath: Config.dir, withIntermediateDirectories: true)
            $0.active.navigate(to: Config.dir)
        },
        cmd("usermenu.edit", "Edit User Menu…", [], menu: "Kermo") {
            _ = $0.userCommands()   // writes the example file on first use
            $0.openInEditor(URL(fileURLWithPath: Config.path("usermenu.json")))
        },
        cmd("app.reload", "Reload Config", [], menu: "Kermo") { $0.applyConfig(reportProblems: true) },
        cmd("app.installCLI", "Install “fm” Command", [], menu: "Kermo") { $0.installCLI() },
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
    /// nothing pasted, dropped or restored opens one as root. A locked server asks as for any connection.
    func reopenPanel(asRoot: Bool) {
        let panel = active
        guard let r = panel.remote else { return panel.flash("Reopen Panel as \(asRoot ? "Root" : "User") is for a server's panel: connect first (⌃⌘K)") }
        guard r.target.sudo != asRoot else { return panel.flash(asRoot ? "This panel is root already" : "This panel is its user's already") }
        panel.loadRemote(r.target.asRoot(asRoot), dir: r.dir, select: panel.currentName)
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

    func showUserMenu() {
        let mine = userCommands()
        let items = Self.userCommands(mine, onServer: active.remote != nil).map { c in
            let builtIn = !mine.contains { $0.command == c.command && $0.title == c.title }   // a server entry the file doesn't have
            return Picker.Item(title: c.title, subtitle: c.command,
                               detail: ([c.terminal == true ? "Terminal" : nil, builtIn ? "built in" : nil].compactMap { $0 }).joined(separator: " · ")) { [unowned self] in
                runShell(c.command, in: c.terminal == true ? .terminalApp : .shell)
            }
        }
        Picker.show(over: window, placeholder: "User menu — %f %s %d %D expand · edit in ~/.config/dfilemanager/usermenu.json", items: items)
    }

    /// The active panel's folder and names — a server's, on a server panel (never the local folder hidden behind it).
    var shellContext: ShellContext {
        if let r = active.remote {
            return ShellContext(dir: r.dir, otherDir: other.remote?.target.asUser == r.target.asUser ? other.remote?.dir : nil,
                                cursor: active.remoteCursor?.item.name, targets: active.remoteSelection?.items.map(\.name) ?? [])
        }
        return ShellContext(dir: active.path, otherDir: other.remote == nil ? other.path : nil, cursor: active.cursorURL?.lastPathComponent,
                            targets: active.targetURLs.map(\.lastPathComponent))
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
                if SavedServer.isProd(r.target), Shell.isDangerous(expanded),
                   await !confirm("Run “\(expanded)” on \(r.target.host) (production)?", info: "In \(r.dir).", ok: "Run") { return }
                if dest == .terminalApp { return openSSH(r.target, command: SSHCommand.shell(in: r.dir, after: expanded)) }
                let login = await Blocking.run { Result { try SFTP.startMaster(r.target, env: env) } }
                if case .failure(let e) = login { return showError(e) }
                Shell.run(expanded, on: r.target, in: r.dir) { [weak self] _ in
                    for p in self?.panels ?? [] where p.remote?.target.asUser == r.target.asUser { p.reload() }
                }
            }
            return
        }
        switch dest {
        case .terminalApp:
            guard let app = terminalAppURL() else { return NSSound.beep() }
            Shell.runInTerminal(expanded, in: active.path, terminalApp: app)
        case .window:
            Shell.run(expanded, in: active.path) { [weak self] _ in self?.panels.forEach { $0.reload() } }
        case .shell:   // the panels reload when the terminal hides (toggleTerminal): the shell's command ends when it ends
            guard let v = terminal.run(expanded, cwd: active.path) else {
                return active.flash("A control character in a name: ⇧↩ runs it in an output window", error: true)
            }
            window.makeFirstResponder(v)
        }
    }

    func terminalAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: defaults.string(forKey: "terminalBundleID") ?? "com.apple.Terminal")
    }

    // MARK: - Jump, bookmarks

    /// Bookmarks first, then folders by frecency. Typing an existing path offers to go there directly.
    func showJump() {
        func item(_ p: String, star: Bool) -> Picker.Item {
            let title = (star ? "★ " : "") + Bookmark.title(p)
            return Picker.Item(title: title, subtitle: (p as NSString).abbreviatingWithTildeInPath) { [unowned self] in jump(to: p) }
        }
        let items = bookmarks.map { item($0, star: true) }
            + frecency.ranked().filter { !bookmarks.contains($0) && $0 != active.path }.prefix(500).map { item($0, star: false) }
        Picker.show(over: window, placeholder: "Jump to folder (fuzzy; bookmarks ★ first)…", items: items) { it, q in
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
    func toggleBookmark() {
        let p = active.remote.map { Bookmark.entry($0.target, $0.dir) } ?? active.path
        if let i = bookmarks.firstIndex(of: p) {
            bookmarks.remove(at: i)
            active.flash("☆ Removed bookmark")
        } else {
            bookmarks.append(p)
            active.flash("★ Bookmarked — ⌘P to jump")
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
        if !Self.swap(active, other) { NSSound.beep(); active.flash("⌘U swaps folders — not an archive or search results") }
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
            Picker.Item(title: t.name, detail: t.name == was ? "✓" : "", preview: { use(t.name) }) { use(t.name) }
        }
        Picker.show(over: window, placeholder: "Theme…", items: items, selected: Theme.all.firstIndex { $0.name == was } ?? 0) { use(was) }
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
        let items = saved.map { p in Picker.Item(title: p.title, subtitle: p.filter, detail: "preset") { panel.applyFilter(p.filter) } }
            + recent.map { r in Picker.Item(title: r, detail: "recent") { panel.applyFilter(r) } }
        Picker.show(over: window, placeholder: "Filter presets — edit in ~/.config/dfilemanager/filters.json", items: items, freeText: { q in
            q.isEmpty ? nil : Picker.Item(title: "Filter: \(q)", detail: "↩") { panel.applyFilter(q) }
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
        let flag = panel.beginSearch(title, in: DirSync.place(server.map(Endpoint.sftp) ?? .local, q.root))
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
        let items = [Picker.Item(title: "＋ New Server…", subtitle: "user, port, key, password, lock") { [unowned self] in
                editServer(SavedServer(), title: "New Server", connect: kind)
            }]
            + savedServers.map { s in
                Picker.Item(title: (s.locked ? "🔒 " : "") + s.title, subtitle: ServerRow.address(s.target), detail: "✎ ⌘E   " + label,
                            edit: { [unowned self] in editServer(s, title: "Edit “\(s.title)”") }) { [unowned self] in
                    openServer(ServerRow(target: s.target, saved: s, title: s.title), kind)
                }
            }
            + hosts.map { h in
                let detail = (h.user.map { "\($0)@" } ?? "") + (h.hostName ?? h.alias) + (h.port.map { ":\($0)" } ?? "")
                return Picker.Item(title: h.alias, subtitle: "~/.ssh/config · " + detail, detail: label) { go(h.alias) }
            }
            + recents.map { r in Picker.Item(title: r, subtitle: "recent", detail: key(r) == nil ? "mount" : label) { go(r) } }
            + [Picker.Item(title: "Edit SSH Config…", subtitle: "~/.ssh/config") { [unowned self] in editSSHConfig() }]
        Picker.show(over: window, placeholder: ssh ? "SSH to: a server, user@host, ssh://host:port — ⌘E edits yours"
                                                   : "SFTP to: a server, user@host:/path, sftp://…, smb://server/share, nfs://… — ⌘E edits yours",
                    items: items, freeText: { q in
            q.isEmpty ? nil : Picker.Item(title: (ssh ? "SSH to" : "Connect to") + " “\(q)”", detail: "↩") { go(q) }
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
    func remember(_ input: String) {
        if case let .sftp(t, _)? = ServerAddress.parse(input), ServerLock.server(for: t) != nil { return }
        var recents = defaults.stringArray(forKey: "recentServers") ?? []
        recents.removeAll { $0 == input }
        recents.insert(input, at: 0)
        defaults.set(Array(recents.prefix(30)), forKey: "recentServers")   // the sidebar finds 5 different servers in them
    }

    /// A new SSH tab in the terminal workspace (shown if hidden). A path in the address is ignored.
    func openSSH(_ input: String) {
        guard case let .sftp(target, _)? = ServerAddress.parse(input) else { return NSSound.beep() }
        remember(input)
        openSSH(target)
    }

    func openSSH(_ target: SFTPTarget, command: String? = nil) {
        let view = terminal.newSSH(target, command: command)
        window.makeFirstResponder(terminal.isShown ? view : terminal.show())
    }

    /// A server's files in a panel, from `dir` (nil: the login folder). Remembering it is the caller's business.
    func openSFTP(_ t: SFTPTarget, dir: String?, title: String, newTab: Bool = false, panel: PanelViewController? = nil) {
        if terminal.isShown { toggleTerminal() }
        let panel = panel ?? active
        Task {   // a locked one asks before the new tab, not after (loadRemote would leave it behind)
            if newTab {
                guard await ServerLock.authorize(t) else { return panel.flash("🔒 \(title) stays locked") }
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

    /// The saved password is never shown, only replaced or forgotten (see `storePassword`); so is a root panel's sudo
    /// password saved there ("Save in Keychain" in its sheet), which can only be forgotten here.
    private func showServerSheet(_ server: SavedServer, title: String, connect: ServerSession.Kind,
                                 problem: String = "", password: String = "", forget: Bool = false, forgetSudo: Bool = false) {
        let saved = savedServers.contains { $0.id == server.id }
        let hasPassword = !server.host.isEmpty && SSHPasswords.has(server.target)
        let hasSudo = !server.host.isEmpty && SSHPasswords.has(server.target, sudo: true)
        let fields: [(String, String, String)] = [
            ("Name", server.name, "shown in the sidebar; empty = the address"),
            ("Host", server.host, "address or ~/.ssh/config host"),
            ("User", server.user ?? "", "empty = ssh's default"),
            ("Port", server.port.map(String.init) ?? "", "22"),
            ("Key file", server.identityFile ?? "", "empty = ssh's own (agent, ~/.ssh/config)"),
            ("Password", password, hasPassword ? "saved in Keychain — type to replace" : "empty = ask each time; saved in Keychain"),
            ("Start folder", server.startDir ?? "", "for SFTP; empty = the login folder"),
        ]
        let inputs = fields.map { label, value, hint in
            let f = label == "Password" ? NSSecureTextField(string: value) : NSTextField(string: value)
            f.placeholderString = hint
            f.widthAnchor.constraint(equalToConstant: 300).isActive = true
            return f
        }
        // Key file: typed, or Choose… in ~/.ssh (hidden, and a pain to type).
        let keyField = inputs[4], choose = NSButton(title: "Choose…", target: nil, action: nil)
        keyField.constraints.forEach { if $0.firstAttribute == .width { $0.constant = 300 - choose.fittingSize.width - 6 } }
        let keyRow = NSStackView(views: [keyField, choose])
        keyRow.spacing = 6
        let chooser = MenuAction.attach(to: choose) {
            let open = NSOpenPanel()
            open.showsHiddenFiles = true
            open.directoryURL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".ssh"))
            open.message = "The private key (not the .pub one)"
            if open.runModal() == .OK, let url = open.url { keyField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath }
        }
        let lock = NSButton(checkboxWithTitle: "Lock with Touch ID or the Mac password", target: nil, action: nil)
        lock.toolTip = "Asked before connecting, editing, duplicating or deleting; once per 5 minutes, again after the screen locks"
        lock.state = server.locked ? .on : .off
        let forgetBox = NSButton(checkboxWithTitle: "Forget the saved password", target: nil, action: nil)
        forgetBox.state = forget ? .on : .off
        let forgetSudoBox = NSButton(checkboxWithTitle: "Forget the saved sudo password", target: nil, action: nil)
        forgetSudoBox.toolTip = "The one a root panel saved in the Keychain (“Kermo sudo”); the next root panel asks again"
        forgetSudoBox.state = forgetSudo ? .on : .off
        let extra: [[NSView]] = (hasPassword ? [[NSGridCell.emptyContentView, forgetBox]] : [])
            + (hasSudo ? [[NSGridCell.emptyContentView, forgetSudoBox]] : []) + [[NSGridCell.emptyContentView, lock]]
        let grid = NSGridView(views: zip(fields, inputs).map { [NSTextField(labelWithString: $0.0 + ":"), $1 === keyField ? keyRow : $1] } + extra)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 400, height: CGFloat(fields.count + extra.count) * 30)

        let alert = NSAlert()
        alert.messageText = title.bidiVisible
        alert.informativeText = problem
        if !problem.isEmpty { alert.alertStyle = .warning }
        for b in saved ? ["Save", "Cancel", "Delete…"] : ["Save & Connect", "Save", "Cancel"] {
            alert.addButton(withTitle: b).hasDestructiveAction = b == "Delete…"
        }
        alert.accessoryView = grid
        alert.window.initialFirstResponder = inputs[server.host.isEmpty ? 1 : 0]
        alert.beginSheetModal(for: window) { [unowned self] r in
            _ = chooser
            window.makeFirstResponder(active.table)
            if saved && r == .alertThirdButtonReturn { return deleteServer(server) }
            let connecting = !saved && r == .alertFirstButtonReturn
            guard r == .alertFirstButtonReturn || connecting || (!saved && r == .alertSecondButtonReturn) else { return }
            let v = inputs.map { $0.stringValue.trimmingCharacters(in: .whitespaces) }
            var s = server
            s.name = v[0]
            s.host = v[1]
            s.user = v[2].isEmpty ? nil : v[2]
            s.port = v[3].isEmpty ? nil : Int(v[3]) ?? 0   // 0: not a port, the check says so
            s.identityFile = v[4].isEmpty ? nil : v[4]
            let password = inputs[5].stringValue   // as typed: spaces count
            s.startDir = v[6].isEmpty ? nil : v[6]
            s.locked = lock.state == .on
            let forget = hasPassword && forgetBox.state == .on, forgetSudo = hasSudo && forgetSudoBox.state == .on
            if let p = s.problem {   // after this sheet is gone
                return DispatchQueue.main.async {
                    self.showServerSheet(s, title: title, connect: connect, problem: p, password: password, forget: forget, forgetSudo: forgetSudo)
                }
            }
            let old = savedServers.first { $0.id == s.id }
            if let i = savedServers.firstIndex(where: { $0.id == s.id }) { savedServers[i] = s } else { savedServers.append(s) }
            Config.save("servers.json", savedServers)
            let status = storePassword(old: old, new: s, typed: password, forget: forget, forgetSudo: forgetSudo)
            if status != errSecSuccess {
                showError(JobErrorMessage("Couldn't save the password in the Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")"))
            }
            refreshSidebar()
            if connecting { openServer(ServerRow(target: s.target, saved: s, title: s.title), connect) }
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
            let info = "Its saved passwords too. Open sessions stay open.", history = historyToDelete(with: s)
            let answer = history == nil ? await confirm("Delete “\(s.title)”?", info: info, ok: "Delete") ? 0 : 2
                : await choose("Delete “\(s.title)”?", info: info + " Its file history — the versions its saves kept on this Mac — can go too.",
                               ["Delete", "Delete with File History", "Cancel"])
            guard answer < 2 else { return }
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
            if let s = ServerLock.server(for: t), await !ServerLock.authorize(s, "see the file history on") { return }
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
        if terminal.isShown { toggleTerminal() }   // SFTP lives in the panels
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

    /// Downloads the cursor file to a temp folder, then opens / views / edits it.
    /// Editing uploads the file back after every save — one upload at a time, and never over changes someone
    /// made on the server meanwhile without asking.
    func remoteOpen(_ how: RemoteOpen) {
        guard let (target, dir, item) = active.remoteCursor, item.kind != .dir else { return NSSound.beep() }
        let remotePath = (dir as NSString).appendingPathComponent(item.name)
        let tmp = NSTemporaryDirectory() + "dfm-sftp-" + UUID().uuidString
        mkdir(tmp, 0o700)
        let local = URL(fileURLWithPath: tmp).appendingPathComponent((item.name as NSString).lastPathComponent)   // a search hit's is a path
        let panel = active, env = SSHAskpass.env
        // F3 on a big log: its tail.
        let last = how == .view ? Viewer.tailLimit(for: item.name) : nil
        Task {
            let r = await panel.busy("Downloading “\(item.name)”…") { flag in
                try SFTPClient.session(target, env: env, cancel: flag) { try $0.download(remotePath, to: local.path, last: last) }
            }
            guard case .success(let opened) = r else {
                TempCopies.remove(tmp)
                if case .failure(let e) = r, !(e is CancellationError) { showError(e) }
                return
            }
            switch how {
            case .open:   // another app: its saves go up as F4's do
                ServerCopies.add(.init(local, target, remotePath, listed: (item.size, item.mtime), baseline: opened, preview: false))
                NSWorkspace.shared.open(local)
            case .view: Viewer.show(local, remote: (target, remotePath, max(0, opened.size - (last ?? opened.size)))) { TempCopies.remove(tmp) }
            case .edit:
                let state = RemoteEdit(baseline: opened)
                Editor.open(local, remote: SavedServer.title(target, remotePath), server: (target, remotePath, state), onSaved: { [self] saved in
                    state.save(in: tmp) { await self.upload(saved, to: remotePath, on: target, state) }
                }, onClose: { state.closed(removing: tmp) })
            }
        }
    }

    @MainActor final class RemoteEdit {
        var baseline: SFTPClient.Attrs
        /// The latest save's upload (after the ones before it): false if that text didn't reach the server.
        var upload: Task<Bool, Never>?
        private var saves = 0
        /// Overwriting the file on a production server was okayed: later saves of this editor don't ask.
        var prodConfirmed = false
        /// What the save says first: “h” is a production server — until okayed once; "" elsewhere.
        func prodNote(_ t: SFTPTarget) -> String { prodConfirmed ? "" : SavedServer.prodNote([t]) }
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
    func upload(_ saved: URL, to remotePath: String, on target: SFTPTarget, _ state: RemoteEdit, force: Bool = false) async -> Bool {
        let name = (remotePath as NSString).lastPathComponent   // the copy's own, but not a version's (Revert)
        let note = state.prodNote(target)
        if !note.isEmpty {
            guard await choose("Save “\(name)” to \(target.host)?", info: note + "This overwrites the file there.",
                               ["Save", "Cancel"], on: Editor.window(for: saved)) == 0 else {
                return notSaved(saved, to: target, CancellationError())   // the editor may be gone: says where the text is
            }
            state.prodConfirmed = true
        }
        let env = SSHAskpass.env, baseline = state.baseline, history = serverHistory
        // No panel of its own: the one showing that server (else the active one) says it's saving; ⎋ there cancels.
        let panel = panels.first { $0.remote?.target == target } ?? active
        let r = await panel.busy("Saving “\(name)” to \(target.host)…") { flag in
            let c = try SFTPClient(target, env: env, cancel: flag)
            defer { c.close() }
            var note: String?
            let keep: ((SFTPClient.Attrs, Data?) -> Void)? = history.map { h in { note = h.keep($1, $0, of: target, remotePath) } }
            let attrs = try c.upload(saved.path, to: remotePath, baseline: baseline, force: force, cancel: flag, replaced: keep)
            return (attrs, note)
        }
        switch r {
        case .success(let (attrs, note)):
            state.baseline = attrs
            for p in panels where p.remote?.target.asUser == target.asUser { p.reload() }   // root's or user's: one server
            if let note {
                let said = "Saved “\(name)” to \(target.host) · no history: \(note)"
                panel.flash(said)
                Editor.flash(saved, said)
            }
            return true
        case .failure(let e as SFTPClient.ChangedOnServer):
            Editor.markUnsaved(saved)
            let keeps = Editor.window(for: saved) == nil ? "in \(saved.path)" : "unsaved here"   // the editor may be gone
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            let when = fmt.string(from: Date(timeIntervalSince1970: e.attrs.mtime))
            let info = "Someone or something wrote it at \(when) (\(ByteCountFormatter.string(fromByteCount: e.attrs.size, countStyle: .file))). "
                + "Overwriting replaces their changes with yours. Compare shows the differences first; Cancel keeps your text \(keeps)."
            while true {   // Compare asks again once the diff is up
                switch await choose("“\(name)” changed on \(target.host) since you opened it", info: info, ["Overwrite", "Compare", "Cancel"],
                                    default: 2, on: Editor.window(for: saved)) {   // ⌘S ↩ never writes over theirs
                case 0: return await upload(saved, to: remotePath, on: target, state, force: true)
                case 1: await diff(DiffSide(path: saved.path, name: "\(name) (yours)"),
                                   DiffSide(path: remotePath, server: target, size: e.attrs.size, mtime: e.attrs.mtime), in: panel)
                default: return false
                }
            }
        case .failure(let e):
            return notSaved(saved, to: target, e)
        }
    }

    /// Server File History…: the versions saves replaced (`ServerHistory`) of the server file in the key editor, or under
    /// a server panel's cursor, newest first. ↩ / F3 views one; ⌘⇧D diffs it with the server's file now, ⌘D with the
    /// version before it; ⌘R puts it
    /// back there through the same save as ⌘S — production asks, a change made there since the list opened asks too,
    /// and the version it replaces goes into the history.
    func serverFileHistory() {
        let editor = Editor.server(of: NSApp.keyWindow)
        let file = editor ?? active.remoteCursor.flatMap { c in
            c.item.kind == .file || c.item.kind == .link && !c.item.linkDir ? (c.target, (c.dir as NSString).appendingPathComponent(c.item.name)) : nil
        }
        guard let (target, path) = file else { return active.flash("Server File History is for a server's file: put the cursor on one, or ask in its editor") }
        let over: NSWindow = editor != nil ? NSApp.keyWindow! : window
        let name = (path as NSString).lastPathComponent, env = SSHAskpass.env
        let panel = panels.first { $0.remote?.target == target } ?? active
        Task {
            if let s = ServerLock.server(for: target), await !ServerLock.authorize(s, "see the file history on") { return }
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
                let diff: @MainActor () -> Void = { [unowned self] in
                    let there = DiffSide(path: path, server: target, size: now?.size ?? 0, mtime: now?.mtime ?? 0, look: now == nil)
                    Task { await self.diff(side(v), there, in: panel) }
                }
                let diffBefore: @MainActor () -> Void = { [unowned self] in   // newest first: the one before is next
                    guard versions.indices.contains(i + 1) else { return panel.flash("That's the oldest version kept: nothing before it to compare") }
                    Task { await self.diff(side(versions[i + 1]), side(v), in: panel) }
                }
                let revert: @MainActor () -> Void = { [unowned self] in
                    let state = RemoteEdit(baseline: now ?? .nothing)
                    Task {
                        guard await upload(url, to: path, on: target, state) else { return }
                        panel.flash("“\(name)” on \(target.host) is back to its version of \(when)")
                        // Its editor shows that now, unless it has changes of its own.
                        if let e = Editor.editing(target, path), let data = await Blocking.run(.userInitiated, { try? Data(contentsOf: url) }) {
                            _ = await e.reverted(to: data, attrs: state.baseline)
                        }
                    }
                }
                return Picker.Item(title: when, subtitle: ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file),
                                   keys: [Shortcut("f3")!: view, Shortcut("cmd+shift+d")!: diff, Shortcut("cmd+d")!: diffBefore, Shortcut("cmd+r")!: revert],
                                   run: view)
            }
            Picker.show(over: over, placeholder: "“\(name)” on \(target.host): ↩ F3 view · ⌘⇧D diff with the server's · ⌘D with the one before · ⌘R revert to it",
                        items: items)
        }
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
        return "Saved locally, but uploading to \(host) failed: \(error.localizedDescription)\(kept)"
    }

    /// One operation over the native client (names go as bytes, no `sftp -b` quoting), then the server's panels reload.
    private func remoteOp(_ title: String, _ target: SFTPTarget, select: String? = nil, _ op: @escaping @Sendable (SFTPClient) throws -> Void) {
        let env = SSHAskpass.env
        Task {
            let r = await active.busy("\(title) on \(target.host)…") { flag in try SFTPClient.session(target, env: env, cancel: flag, op) }
            if case .failure(let e) = r, !(e is CancellationError) { showError(JobErrorMessage("\(title): \(e.localizedDescription)")) }
            for p in panels where p.remote?.target.asUser == target.asUser { p.reload(select: select) }
        }
    }

    private func remoteMkdir() {
        guard let (target, dir, _) = active.remoteSelection ?? active.remote.map({ ($0.target, $0.dir, []) }) else { return }
        Task {
            guard let name = await prompt("New folder on \(target.host):", value: "", ok: "Create"), !name.isEmpty else { return }
            let path = (dir as NSString).appendingPathComponent(name)
            remoteOp("New folder", target, select: name) { try $0.mkdir(path) }
        }
    }

    /// Never over an existing item (sftp's `rename` is posix-rename, which silently replaced it); `Foo` → `foo` works.
    private func remoteRename() {
        guard let (target, dir, item) = active.remoteCursor else { return NSSound.beep() }
        Task {
            guard let name = await prompt("Rename “\(item.name)” on \(target.host) to:", value: item.name, ok: "Rename",
                                          info: SavedServer.prodNote([target]), selectBaseName: true),
                  name != item.name, !name.isEmpty else { return }
            let from = (dir as NSString).appendingPathComponent(item.name)
            let to = name.hasPrefix("/") ? name : (dir as NSString).appendingPathComponent(name)
            remoteOp("Rename", target, select: (to as NSString).lastPathComponent) { try $0.rename(from, to, replace: false) }
        }
    }

    /// There's no Trash on a server: always asks, then deletes recursively.
    private func remoteDelete() {
        guard let sel = active.remoteSelection else { return NSSound.beep() }
        Task {
            let what = sel.items.count == 1 ? "“\(sel.items[0].name)”" : "\(sel.items.count) items"
            guard await confirm("Delete \(what) on \(sel.target.host)?",
                                info: SavedServer.prodNote([sel.target]) + "Files on a server can't be moved to the Trash. This can't be undone.",
                                ok: "Delete") else { return }
            let paths = sel.items.map { (sel.dir as NSString).appendingPathComponent($0.name) }
            ops.enqueue(FileJob(.delete, sources: paths, from: .sftp(sel.target), to: .sftp(sel.target), destDir: nil, sshEnv: SSHAskpass.env),
                        title: "Delete \(what) on \(sel.target.host)")
            active.unmarkAll()
        }
    }

    // MARK: - Administrator operations

    func runAdmin(_ title: String, _ command: String) async {
        switch await Admin.run(command) {
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
                                           info: move ? "Existing items are never overwritten (mv -n)." : "ditto keeps owner, mode, ACLs and xattrs; existing files are replaced.")
            else { return }
            let dest = resolve(input)
            let paths = srcs.map(\.path)
            await runAdmin("\(verb) as administrator", move ? AdminCommand.move(paths, to: dest) : AdminCommand.copy(paths, to: dest))
            active.unmarkAll()
        }
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
        Task {
            guard await confirm("Delete \(Self.describe(srcs)) permanently as administrator?",
                                info: srcs.prefix(5).map(\.path).joined(separator: "\n") + "\n\nThis runs rm -rf as root and can't be undone.",
                                ok: "Delete") else { return }
            await runAdmin("Delete as administrator", AdminCommand.delete(srcs.map(\.path)))
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
            if view { Viewer.show(url) { TempCopies.remove(url.deletingLastPathComponent().path) } } else { NSWorkspace.shared.open(url) }
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
            // What lands at the top of `dest`; bsdtar would silently replace any of it that's there already.
            let (index, clashes) = await Blocking.run { () -> (ArchiveIndex?, [String]) in
                let index = sel?.index ?? (try? ArchiveIndex.read(file))
                let top = sel?.names ?? (index?.list("") ?? []).map(\.name)
                return (index, top.filter { var st = stat(); return Darwin.lstat((dest as NSString).appendingPathComponent($0), &st) == 0 })
            }
            guard let keep = await keepExisting(clashes, in: (dest as NSString).abbreviatingWithTildeInPath) else { return }
            do { try await Blocking.run { try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true) } } catch {
                return showError(error)
            }
            var args = index?.extractArguments(sel?.names ?? [], from: sel?.inner ?? "", to: dest) ?? ["-x", "-f", file, "-C", dest]
            if keep { args.insert("-k", at: 1) }
            Shell.run("/usr/bin/tar -v " + args.map(ShellContext.quote).joined(separator: " ") + " 2>&1", in: dest) { _ in self.panels.forEach { $0.reload() } }
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
                                           ok: "Extract", info: SavedServer.prodNote([target])), !input.isEmpty else { return }
            let dest = ((input.hasPrefix("/") ? input : (dir as NSString).appendingPathComponent(input)) as NSString).standardizingPath
            // What lands at the top of `dest` that's there already: tar and unzip -o would replace it.
            let found = await panel.busy("Reading “\((item.name as NSString).lastPathComponent)”…") { flag in
                let top = RemoteArchive.topNames(try SSHCommand.capture(target, RemoteArchive.namesCommand(file), env: env, cancel: flag), of: file)
                let present = Set(((try? SFTP.list(target, dest, env: env, cancel: flag)) ?? []).map(\.name))   // no folder yet: nothing
                return top.filter(present.contains)
            }
            guard case .success(let clashes) = found else {
                if case .failure(let e) = found, !(e is CancellationError) { showError(e) }
                return
            }
            guard let keep = await keepExisting(clashes, in: DirSync.place(.sftp(target), dest)) else { return }
            Shell.run(RemoteArchive.extractCommand(file, to: dest, keep: keep), on: target, in: dir,
                      title: "Extract “\((item.name as NSString).lastPathComponent)” → \(dest) on \(target.host)") { [weak self] _ in
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
            let args = ArchiveIndex.createArguments(archive, names: srcs.map(\.lastPathComponent), in: active.path)
            Shell.run("COPYFILE_DISABLE=1 /usr/bin/tar -v " + args.map(ShellContext.quote).joined(separator: " ") + " 2>&1", in: active.path) { _ in self.panels.forEach { $0.reload() } }
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
            guard !FileManager.default.fileExists(atPath: url.path + ".000") else {
                return showError(JobErrorMessage("“\(name).000” already exists."))
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
        let names = ((try? DirLister.list(dir)) ?? []).map(\.name)   // all of them, not just what the filter shows
        guard let seq = SplitParts.sequence(for: url.lastPathComponent, in: names) else {
            return active.flash("Put the cursor on a part (name.000 / name.001) — and make sure none is missing")
        }
        Task {
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
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeIsEjectableKey, .volumeLocalizedFormatDescriptionKey]
        Task { [self] in
            // Off the main thread: a stick that stopped answering. A network share keeps to the kernel's figures.
            let rows = await Blocking.run(.userInitiated) { () -> [(path: String, title: String, subtitle: String, eject: Bool)] in
                let fmt = ByteCountFormatter()
                return SidebarModel.mounts().map { m in
                    let v = m.local ? try? URL(fileURLWithPath: m.path).resourceValues(forKeys: keys) : nil
                    let free = m.local ? v?.volumeAvailableCapacity.map { fmt.string(fromByteCount: Int64($0)) } ?? "?" : fmt.string(fromByteCount: m.free)
                    let total = m.local ? v?.volumeTotalCapacity.map { fmt.string(fromByteCount: Int64($0)) } ?? "?" : fmt.string(fromByteCount: m.total)
                    return (m.path, v?.volumeName ?? (m.path as NSString).lastPathComponent,
                            "\(m.path) · \(free) free of \(total) · \(v?.volumeLocalizedFormatDescription ?? m.type)", v?.volumeIsEjectable == true || !m.local)
                }
            }
            let items = rows.map { r in
                Picker.Item(title: r.title, subtitle: r.subtitle, detail: r.eject ? "⏏ ⌘⌥E" : "") { [unowned self] in active.navigate(to: r.path) }
            }
            Picker.show(over: window, placeholder: "Volumes…", items: items)
        }
    }

    func ejectVolume(_ path: String? = nil) {
        let url = URL(fileURLWithPath: path ?? active.path)
        Task {   // the volume is asked off the main thread: a dead share may never answer
            let found = await Blocking.run { () -> (vol: URL, name: String)? in
                let rv = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsEjectableKey, .volumeNameKey])
                guard let vol = rv?.volume, vol.path != "/", rv?.volumeIsEjectable == true || vol.path.hasPrefix("/Volumes/") else { return nil }
                return (vol, rv?.volumeName ?? vol.lastPathComponent)
            }
            guard let (vol, name) = found else { return active.flash("This folder isn't on an ejectable volume") }
            // Don't leave panels sitting on it (their watchers use O_EVTONLY, which doesn't block unmount).
            for p in panels where p.path == vol.path || p.path.hasPrefix(vol.path + "/") { p.navigate(to: NSHomeDirectory()) }
            active.flash("Ejecting “\(name)”…")
            let error = await Blocking.run { () -> String? in
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: vol); return nil } catch { return error.localizedDescription }
            }
            if let error { showError(JobErrorMessage("Couldn't eject “\(name)”: \(error)")) } else { active.flash("“\(name)” ejected") }
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
            Shell.run(GitStatus.diffCommand(tracked: tracked, untracked: untracked), in: dir, diff: true)
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
        if quickViewOn { other.preview(active.previewURL()) }
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
        Task {
            guard let input = await prompt("\(verb) \(what) to:", value: (suggestion as NSString).abbreviatingWithTildeInPath, ok: verb)
            else { return }
            let dest = resolve(input), intoDir = input.hasSuffix("/") || srcs.count > 1
            // Off the main thread, saying so (⎋ stops waiting): the destination may be a share that doesn't answer.
            let found = await panel.busy("Checking “\((dest as NSString).abbreviatingWithTildeInPath)”…") { _ -> Bool in
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: dest, isDirectory: &isDir)
                guard (exists && isDir.boolValue) || intoDir else { return false }
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

    /// F5/F6 when either panel (or both) is on a server. The same rules as between local folders: an existing
    /// folder, a path ending in "/" or several items go into it (made if missing); else the one item takes the
    /// new name. The path is on the other panel's side.
    private func transferAcrossDialog(move: Bool) {
        guard let items = active.transferItems else { return NSSound.beep() }
        guard other.archive == nil, other.searchTitle == nil else { return active.flash("Open a folder in the other panel first") }
        let side = other.endpoint, base = other.currentDir
        let verb = move ? "Move" : "Copy"
        let what = items.paths.count == 1 ? "“\((items.paths[0] as NSString).lastPathComponent)”" : "\(items.paths.count) items"
        var host = ""
        if case .sftp(let t) = side { host = " \(t.host)" }
        let suggestion = base == "/" ? "/" : base + "/"
        Task {
            guard let input = await prompt("\(verb) \(what) to\(host):", value: side == .local ? (suggestion as NSString).abbreviatingWithTildeInPath : suggestion,
                                           ok: verb), !input.isEmpty else { return }
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
        let prod = prodAsked ? "" : SavedServer.prodNote(Self.changed(from: from, to: side, move: move))
        if !locked.isEmpty || !prod.isEmpty {
            Task {
                for t in locked where await !ServerLock.authorize(t) { return active.flash("🔒 \(t.host) stays locked") }
                if !prod.isEmpty, await !confirm(title + "?", info: prod + "Files there may be overwritten" + (move ? " or removed." : "."),
                                                  ok: move ? "Move" : "Copy") { return }
                enqueueTransfer(sources, from: from, to: dir, on: side, name: name, move: move, prodAsked: true)
            }
            return
        }
        ops.enqueue(FileJob(move ? .move : .copy, sources: sources, from: from, to: side, destDir: dir, targetName: name, sshEnv: SSHAskpass.env),
                    title: title)
    }

    /// Touch ID first for each locked server among `ends`, as listing one of its folders asks; false (and said so)
    /// if one stays locked. For what walks a whole tree there: compare, sync, search.
    func unlock(_ ends: [Endpoint]) async -> Bool {
        for case .sftp(let t) in ends where ServerLock.needsUnlock(t) {
            guard await ServerLock.authorize(t) else { active.flash("🔒 \(t.host) stays locked"); return false }
        }
        return true
    }

    /// Synchronize's jobs, once each locked server is unlocked — and okayed where they change a production server or
    /// delete on one (no Trash there), like F5 and F8 there. False if nothing was queued.
    func enqueueSync(_ jobs: [(job: FileJob, label: String)]) async -> Bool {
        func server(_ e: Endpoint) -> SFTPTarget? { if case .sftp(let t) = e { t } else { nil } }
        let changed = jobs.compactMap { server($0.job.to) }   // a delete's `to` is its server too
        let deleted = jobs.filter { $0.job.kind == .delete }.reduce(0) { $0 + $1.job.sources.count }
        let prod = SavedServer.prodNote(changed)
        guard await unlock(jobs.flatMap { [$0.job.from, $0.job.to] }) else { return false }
        if !prod.isEmpty || deleted > 0 {
            let hosts = Set(changed.map(\.host)).sorted().joined(separator: ", ")
            guard await confirm("Synchronize with \(hosts)?", info: prod + (deleted > 0
                ? "\(deleted) item\(deleted == 1 ? "" : "s") only there \(deleted == 1 ? "is" : "are") deleted — a server has no Trash. This can't be undone."
                : "Files there may be overwritten."), ok: "Synchronize") else { return false }
        }
        for (job, label) in jobs { ops.enqueue(job, title: label) }
        return true
    }

    /// The servers where a copy or move changes files: where it goes, and for a move where it comes from too.
    nonisolated static func changed(from: Endpoint, to: Endpoint, move: Bool) -> [SFTPTarget] {
        (move ? [from, to] : [to]).compactMap { if case .sftp(let t) = $0 { t } else { nil } }
    }

    private func readOnly() {
        active.flash(active.remote != nil ? "Not available on SFTP" : "Archives are read-only here — F5 extracts")
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
                                          info: (r.map { SavedServer.prodNote([$0.target]) } ?? "")
                                            + "Octal mode, then owner:group" + (r != nil ? " — the server's numbers (uid:gid)." : " (names or numbers).")),
                  text != shown else { return }
            let typed = Perms.parse(text), before = Perms.parse(shown)
            guard let ids = Perms.ids(typed.owner == before.owner ? "" : typed.owner, names: r == nil) else {
                return showError(JobErrorMessage(r != nil ? "On a server, give the owner and group as numbers (uid:gid)" : "No such user or group: “\(typed.owner)”"))
            }
            let mode = typed.mode == before.mode ? nil : typed.mode
            guard mode != nil || ids.uid != nil || ids.gid != nil else { return }
            // The owner was replaced by a lone number: a uid ("1000") would read as a mode and lock everyone out.
            if let mode, typed.owner.isEmpty, !before.owner.isEmpty,
               await !confirm("Set mode \(String(format: "%03o", mode)) (\(Perms.string(mode))) on \(what)?",
                              info: "To change the owner instead, keep its colon: “\(text.trimmingCharacters(in: .whitespaces)):”.", ok: "Set Mode") { return }
            if let r {
                let each = items.map { ((r.dir as NSString).appendingPathComponent($0.name), $0) }
                return remoteOp("Permissions", r.target) { c in
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
        if active.archive != nil || active.remote != nil { return readOnly() }
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
        Task {
            guard await confirm("Delete \(Self.describe(srcs)) permanently?", info: "This can't be undone.", ok: "Delete")
            else { return }
            ops.enqueue(FileJob(.delete, sources: srcs.map(\.path)), title: "Delete \(Self.describe(srcs))")
            active.unmarkAll()
        }
    }

    func multiRename() {
        let items = active.targetItems
        guard !items.isEmpty else { return NSSound.beep() }
        let dir = active.path
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
    nonisolated private static func changeTrashLog<T>(_ change: (inout [String: String]) -> T) -> T {
        let saved = (try? Config.load("trash.json", as: [String: String].self)) ?? [:]
        var log = saved.filter { var s = stat(); return lstat($0.key, &s) == 0 || errno != ENOENT }
        let result = change(&log)
        if log != saved { Config.save("trash.json", log) }
        return result
    }
    nonisolated private static let trashLogQueue = DispatchQueue(label: "trash.json", qos: .utility)

    func recordTrash(_ pairs: [(from: String, to: String)]) {
        guard !pairs.isEmpty else { return }
        Self.trashLogQueue.async { Self.changeTrashLog { log in for p in pairs { log[p.to] = p.from } } }
    }

    /// Keeps the log in step with undo/redo: an item leaving the Trash loses its entry (so a later item Finder
    /// trashes under the same name isn't put back there), one moved into the Trash gets one.
    nonisolated static func trashLog(_ log: [String: String], after pairs: [(from: String, to: String)]) -> [String: String] {
        var log = log
        for p in pairs {
            log[p.from] = nil
            if p.to.hasPrefix(NSHomeDirectory() + "/.Trash/") || p.to.contains("/.Trashes/") { log[p.to] = p.from }
        }
        return log
    }

    func putBack() {
        let urls = active.targetURLs
        Task {
            let log = await withCheckedContinuation { c in Self.trashLogQueue.async { c.resume(returning: Self.changeTrashLog { $0 }) } }
            let pairs = urls.compactMap { u in log[u.path].map { (from: u.path, to: $0) } }
            guard !pairs.isEmpty else { return active.flash("Only what Kermo moved to the Trash can be put back here — use Finder for the rest") }
            let moved = await Blocking.run(.userInitiated) { () -> Result<Void, Error> in   // off the main thread: a share that stopped answering
                for p in pairs { try? FileManager.default.createDirectory(atPath: (p.to as NSString).deletingLastPathComponent, withIntermediateDirectories: true) }
                return Result { try BatchRename.run(pairs) }   // never overwrites
            }
            if case .failure(let error) = moved { return showError(JobErrorMessage("Put Back: \(error.localizedDescription)")) }
            registerMoves("Put Back", pairs)
            Self.trashLogQueue.async { Self.changeTrashLog { log in for p in pairs { log[p.from] = nil } } }
            if pairs.count < urls.count { active.flash("Put back \(pairs.count) of \(urls.count) — the rest weren't trashed by Kermo") }
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

    /// Undo of something created = move it to the Trash (redo = put it back).
    func registerCreated(_ title: String, _ paths: [String]) {
        guard !paths.isEmpty, let um = window.undoManager else { return }
        um.registerUndo(withTarget: self) { app in
            MainActor.assumeIsolated {
                let record = app.registerPendingMoves(title)
                app.afterUndoWork {
                    let r = await Blocking.run(.userInitiated) { Self.trash(paths) }
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
