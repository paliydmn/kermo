import AppKit
import DFMCore

// Quick Open (⌘P in the editor window): its tabs, the files the editor opened lately, and the files under the shown
// document's repository (else its folder) — one fuzzy list; ↩ opens as F4 does.

extension AppDelegate {
    /// The folder walk's bounds: Picker shows at once with the tabs and Recent; the folder's files come in after.
    static var quickOpenLimit = (files: 20_000, seconds: 1.0)

    func quickOpen() {
        guard let h = editorKey, let w = h.window else { return NSSound.beep() }
        var rows: [Picker.Item] = [], seen = Set<String>()
        for e in h.docs where e.snapshot == nil {
            if let k = Self.recentKey(e) { seen.insert(k) }
            rows.append(Picker.Item(title: e.name, subtitle: e.heading.subtitle, badges: e.chips.map(\.image), detail: "open", verb: "Show",
                                    id: "tab:" + e.id.uuidString, group: "Tabs") { [weak h] in h?.select(e) })
        }
        for r in editorRecent.entries where seen.insert(Self.recentKey(r)).inserted {
            let dir = (r.path as NSString).deletingLastPathComponent
            let t = r.server.map { $0.asRoot(r.root) }
            rows.append(Picker.Item(title: (r.path as NSString).lastPathComponent,
                                    subtitle: t.map { "\(SavedServer.name(for: $0)) · \(dir)" } ?? (dir as NSString).abbreviatingWithTildeInPath,
                                    badges: t.map { Chip.of($0).map(\.image) } ?? [], id: "recent:" + Self.recentKey(r), group: "Recent") { [unowned self] in
                open(r)
            })
        }
        let place = h.active?.terminalPlace
        let start = place?.target == nil ? place?.folder ?? panels.first { $0 === active && $0.plainFolder != nil }?.plainFolder : nil   // this Mac only
        let flag = CancelFlag()
        let rank = { (it: Picker.Item, q: String) -> Int? in
            guard let s = Fuzzy.score(q, it.subtitle + "/" + it.title) else { return nil }
            return s + (Fuzzy.score(q, it.title) != nil ? 500 : 0) + (it.group == "Tabs" ? 300_000 : it.group == "Recent" ? 200_000 : 0)   // groups stay whole
        }
        let p = Picker.show(over: w, placeholder: "Open a file by name", empty: "No tabs or recent files yet", items: rows, rank: rank,
                            onClose: { _, _ in flag.cancel() })
        guard let start else { return }
        Task { [unowned self] in
            let root = await Blocking.run(.userInitiated) { Self.projectRoot(of: start) }
            let shown = (root as NSString).abbreviatingWithTildeInPath, limit = Self.quickOpenLimit
            let (files, whole) = await Blocking.run(.userInitiated) { Self.files(under: root, limit: limit, cancel: flag) }
            guard Picker.current === p, !flag.isCancelled else { return }
            let more = files.compactMap { rel -> Picker.Item? in
                let path = (root as NSString).appendingPathComponent(rel)
                guard seen.insert(Self.recentKey(RecentFiles.Entry(path: path))).inserted else { return nil }
                return Picker.Item(title: (rel as NSString).lastPathComponent, subtitle: ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath,
                                   id: "file:" + path, group: "In " + shown) { Editor.open(URL(fileURLWithPath: path)) }
            }
            p.replace(rows + more)
            p.say(NSAttributedString(string: "\(shown): " + (whole ? "\(files.count) file\(files.count == 1 ? "" : "s")" : "the first \(files.count) files"),
                                     attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]))
        }
    }

    /// A Recent row: as F4 opens it — a server's after its lock, with F4's rules (one file, one tab).
    private func open(_ r: RecentFiles.Entry) {
        guard let user = r.server else { return Editor.open(URL(fileURLWithPath: r.path)) }
        let t = user.asRoot(r.root)
        Task {
            guard await ServerLock.authorize(t) else { return active.flash("\(t.host) stays locked") }
            remoteOpen(.edit, t, r.path, in: panels.first { $0.remote?.target == t } ?? active)
        }
    }

    /// The editor opened `e`'s file (F4, Quick Open, ⇧⌘T, Edit in a copy): first in Recent. Not an Untitled's, a
    /// copy's or a tool's; not a locked server's (where it's been is nobody's business, as Connect's recents).
    func rememberRecent(_ e: Editor) {
        guard e.snapshot == nil, e.host?.tabbed == true else { return }
        let entry: RecentFiles.Entry
        if let s = e.server {
            guard ServerLock.server(for: s.target) == nil else { return }
            entry = RecentFiles.Entry(path: s.path, server: s.target.asUser, root: s.target.sudo)
        } else if let u = e.url {
            entry = RecentFiles.Entry(path: u.path)
        } else { return }
        editorRecent.visit(entry)
        Config.save("editor-recent.json", editorRecent)
    }

    /// One file, one row: this Mac's by its path, a server's by its server and path.
    static func recentKey(_ r: RecentFiles.Entry) -> String { r.server.map { ServerRow.key($0) + ":" + r.path } ?? r.path }
    static func recentKey(_ e: Editor) -> String? {
        if let s = e.server { return recentKey(RecentFiles.Entry(path: s.path, server: s.target.asUser)) }
        return e.url.map { recentKey(RecentFiles.Entry(path: $0.path)) }
    }

    /// The repository `dir` is in (a `.git` there or above, below the home folder), else `dir` itself.
    nonisolated static func projectRoot(of dir: String) -> String {
        let home = NSHomeDirectory()
        var d = dir
        while d != "/", d != home, d.hasPrefix("/") {
            if FileManager.default.fileExists(atPath: d + "/.git") { return d }
            d = (d as NSString).deletingLastPathComponent
        }
        return dir
    }

    /// Files under `root` by their path there — only read, not hidden, not into .git, node_modules or a package, nor
    /// through a link or onto another volume (`FileSearch`); `limit.files` of them, for `limit.seconds` at most. `whole`:
    /// all of them.
    nonisolated static func files(under root: String, limit: (files: Int, seconds: Double), cancel: CancelFlag) -> (files: [String], whole: Bool) {
        var q = SearchQuery(root: root)
        q.skipFolder = { $0 == "node_modules" || ["app", "bundle", "framework", "photoslibrary", "xcarchive", "pkg"].contains(($0 as NSString).pathExtension) }
        let end = Date().addingTimeInterval(limit.seconds)
        var out: [String] = [], cut = false
        FileSearch.run(q, isCancelled: {
            if out.count >= limit.files || Date() > end { cut = true }
            return cut || cancel.isCancelled
        }) { if $0.kind == .file { out.append($0.name) } }
        return (Array(out.prefix(limit.files)), !cut)
    }
}
