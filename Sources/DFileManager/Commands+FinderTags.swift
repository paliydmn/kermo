import AppKit
import DFMCore

extension AppDelegate {
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
        if let place = panel.list?.source as? PlaceSource {   // its files, from the start folder
            return openServer(ServerRow(target: place.target, saved: savedServer(at: place.target), title: place.server.title), .sftp, panel: panel, root: asRoot)
        }
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
}
