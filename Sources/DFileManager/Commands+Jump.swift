import AppKit
import DFMCore

extension AppDelegate {
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
        let path = Self.keymapPath
        if !FileManager.default.fileExists(atPath: path) {
            let all = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0.keys.map(\.spec)) })
            Config.save("keymap.json", all, in: Self.keymapDir)
            Config.flush()   // written before the editor opens it
        }
        openInEditor(URL(fileURLWithPath: path))
    }
}
