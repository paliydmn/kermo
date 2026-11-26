import AppKit
import DFMCore

extension AppDelegate {
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

    /// F2: your commands — on a server's file, first the actions tools in use there offer on it (§11).
    func showUserMenu() {
        guard let (t, dir, it) = active.remoteCursor else { return showUserMenu(tools: []) }
        let panel = active
        Task {
            let found = await contextItems(for: (dir as NSString).appendingPathComponent(it.name), on: t.asUser, in: panel)
            guard active === panel else { return }   // another panel meanwhile: its menu would be another one
            showUserMenu(tools: found ?? [])   // locked or ⎋: your commands still
        }
    }

    private func showUserMenu(tools: [Picker.Item]) {
        let mine = userCommands()
        let items = tools + Self.userCommands(mine, onServer: active.remote != nil).map { c in
            let builtIn = !mine.contains { $0.command == c.command && $0.title == c.title }   // a server entry the file doesn't have
            return Picker.Item(title: c.title, subtitle: c.command,
                               detail: ([c.terminal == true ? "Terminal" : nil, builtIn ? "built in" : nil].compactMap { $0 }).joined(separator: " · "), verb: "Run") { [unowned self] in
                runShell(c.command, in: c.terminal == true ? .terminalApp : .shell)
            }
        } + [Picker.Item(title: "Edit User Menu…", subtitle: "~/.config/dfilemanager/usermenu.json", verb: "Edit") { [unowned self] in run("usermenu.edit") }]
        Picker.show(over: window, placeholder: "Filter commands", hints: [Self.commandLineKeys.last!], items: items)
    }

    /// The active panel's folder and names — a server's, on a server panel (never the local folder hidden behind it).
    var shellContext: ShellContext { AIContext(active: aiPanel(active), other: aiPanel(other)).shell }

    /// What the user has in front of them (`AIContext`): the panels, the editor window's document while it shows, the
    /// terminal's tab while the drawer is open.
    var aiContext: AIContext {
        var c = AIContext(active: aiPanel(active), other: aiPanel(other))
        if let h = EditorHost.shared, h.window?.isVisible == true, let e = h.active {
            let text = e.textView.string as NSString, sel = e.textView.selectedRange()
            let line = { (at: Int) in text.substring(to: at).reduce(1) { $1.isNewline ? $0 + 1 : $0 } }
            c.editor = .init(server: e.origin, path: e.server?.path ?? e.url?.path ?? e.snapshotFrom?.path, unsaved: e.changed,
                             selection: sel.length > 0 ? (line(sel.location)...line(NSMaxRange(sel) - 1), text.substring(with: sel)) : nil)
        }
        if terminal?.isShown == true, let t = terminal.current {
            c.terminal = .init(server: t.origin(ran: t.view.marks.last?.text).server, command: t.view.marks.last?.text, selection: t.view.getSelection().flatMap { $0.isEmpty ? nil : $0 })
        }
        return c
    }

    /// A panel as `AIContext` has it. A parked one (`folder` nil) is the local folder behind it, as ⌘E always had it —
    /// what runs a command says "not connected" before it gets here.
    private func aiPanel(_ p: PanelViewController) -> AIContext.Panel {
        let folder = p.remote.map { AIContext.Folder(server: $0.target, dir: $0.dir) } ?? (p.parked == nil ? AIContext.Folder(server: nil, dir: p.path) : nil)
        if let l = p.list {   // its server's login folder; %f the cursor's row, %s the marked ones (a service, a container)
            let place = l.source is PlaceSource
            return .init(server: l.source.target.asUser, dir: ".", cursor: place ? nil : l.cursor?.title, targets: place ? [] : l.targets.map(\.title),
                         list: l.source.title, folder: folder)
        }
        if let r = p.remote {
            return .init(server: r.target, dir: r.dir, cursor: p.remoteCursor?.item.name, targets: p.remoteSelection?.items.map(\.name) ?? [], folder: folder)
        }
        let dir = p.itemsDir
        return .init(dir: dir, cursor: p.cursorURL.map { Self.name($0, in: dir) }, targets: p.targetURLs.map { Self.name($0, in: dir) }, folder: folder,
                     parked: p.parked.map { .init(server: $0.target, dir: $0.dir) })
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
        let context = shellContext
        guard let expanded = context.expand(command) else {
            return active.flash(other.list != nil ? "%D: the other panel shows a list, not a folder" : "%D: the other panel is on another machine")
        }
        // A list of a server's: on that server, in its login folder (".": where its shell starts).
        if let target = context.server {
            let env = SSHAskpass.env, r = (target: target, dir: context.dir), panel = active
            Task { [self] in
                // R1: rm, mv, chmod, chown, dd, systemctl stop/restart on a production server ask first.
                let passed = await gate([r.target], to: "run “\(String(expanded.prefix(60)).bidiVisible)” on") {
                    guard SavedServer.isProd(r.target), Shell.isDangerous(expanded) else { return nil }
                    var c = Confirm("Run this command on \(SavedServer.name(for: r.target))?", on: r.target, action: "Run")
                    c.runs = (r.dir == "." ? "In its login folder" : "In \(r.dir)") + (r.target.sudo ? ", as the server's user — not root." : ".")
                    c.command = dest == .terminalApp ? SSHCommand.shell(in: r.dir, after: expanded) : Shell.remote(expanded, in: r.dir, follow: false)
                    return c
                }
                if case .locked(let t) = passed { return panel.flash("\(t.host) stays locked") }
                guard passed == .pass else { return }
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
}
