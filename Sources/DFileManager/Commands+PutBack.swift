import AppKit
import DFMCore

extension AppDelegate {
    // MARK: - Put Back (⌘⌫ / F8 inside the Trash)

    /// Path in the Trash → where it came from, for what Kermo trashed (Finder keeps its own record in the
    /// Trash's private .DS_Store). Entries are dropped once the item is gone from the Trash — only on ENOENT,
    /// so a missing Full Disk Access grant (EPERM) doesn't wipe the record.
    /// Read, changed and saved on `trashLogQueue`: each entry is an lstat (a Trash on a share that doesn't answer
    /// never returns), and one queue keeps the changes in order — none lost to another read at the same time.
    nonisolated static func changeTrashLog<T>(_ change: (inout [String: TrashEntry]) -> T) -> T {
        let (loaded, problem) = Config.loadKeeping("trash.json", as: [String: TrashEntry].self)
        if let problem { Task { @MainActor in (NSApp.delegate as? AppDelegate)?.active.flash(problem, error: true) } }   // read off launch: said now
        let saved = loaded ?? [:]
        var log = saved.filter { var s = stat(); return lstat($0.key, &s) == 0 || errno != ENOENT }
        let result = change(&log)
        if log != saved { Config.save("trash.json", log) }
        return result
    }
    nonisolated static let trashLogQueue = DispatchQueue(label: "trash.json", qos: .utility)

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
            if isInTrash(p.to) { log[p.to] = TrashEntry(origin: p.from, at: p.to) }
        }
        return log
    }

    nonisolated static func isInTrash(_ path: String) -> Bool { path.hasPrefix(NSHomeDirectory() + "/.Trash/") || path.contains("/.Trashes/") }

    /// Which items are in a Trash now, by inode at their path there: an undo takes back only those (В19). Looks at the
    /// disk: off the main thread.
    nonisolated static func trashInodes(_ paths: [String]) -> [String: UInt64] {
        Dictionary(paths.filter(isInTrash).compactMap { p in TrashEntry.inode(p).map { (p, $0) } }, uniquingKeysWith: { a, _ in a })
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
}
