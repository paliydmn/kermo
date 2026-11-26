import AppKit
import DFMCore

extension AppDelegate {
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

    /// Built-in editor, unless `defaults write com.dmn.dfilemanager editorBundleID <id>` picks an external app (which
    /// isn't told the `line`).
    func openInEditor(_ url: URL, line: String? = nil) {
        Config.flush()   // a config file just saved (keymap.json's first one) is there for the editor
        let ws = NSWorkspace.shared
        if let app = defaults.string(forKey: "editorBundleID").flatMap(ws.urlForApplication(withBundleIdentifier:)) {
            ws.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            Editor.open(url, line: line)
        }
    }
}
