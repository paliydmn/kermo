import AppKit
import DFMCore

extension AppDelegate {
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
                performMoves(title, back: record)
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
        afterUndoWork { made.inodes = await Blocking.run(.userInitiated) { paths.map(TrashEntry.inode) } }   // off the main thread, before any undo
        um.registerUndo(withTarget: self) { app in
            MainActor.assumeIsolated {
                let record = app.registerPendingMoves(title)
                app.afterUndoWork {
                    let inodes = made.inodes   // read by now: the work before this one
                    let r = await Blocking.run(.userInitiated) { () -> (trashed: [(from: String, to: String)], errors: [String], inodes: [String: UInt64]) in
                        let (same, others) = TrashEntry.same(inodes.map { zip(paths, $0).map { (from: $0, entry: TrashEntry(origin: "", ino: $1)) } }
                                                             ?? paths.map { (from: $0, entry: TrashEntry(origin: "", ino: nil)) })
                        let r = Self.trash(same.map(\.from))
                        return (r.trashed, r.errors + others.map { "“\(($0 as NSString).lastPathComponent)”: another item has this name now — left as it is" },
                                Self.trashInodes(r.trashed.map(\.to)))
                    }
                    let (trashed, errors) = (r.trashed, r.errors)
                    app.fill(record, trashed, [])
                    record.inodes = r.inodes
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
    /// What `source` moved goes back; read once the undo/redo work before it is done (nil: a move job of it is still
    /// running). Out of a Trash only the items it put there: one Finder trashed since under the name stays (В19).
    private func performMoves(_ title: String, back source: MoveRecord) {
        let record = registerPendingMoves(title)
        afterUndoWork { [self] in
            guard let pairs = source.done.flatMap({ Self.moved($0.renames, $0.jobs) })?.map({ (from: $0.to, to: $0.from) }) else {
                fill(record, [], [])
                return showError(JobErrorMessage("Can't undo or redo \(title.lowercased()) while its move between volumes is still running"))
            }
            let inodes = source.inodes
            do {
                let (renames, jobs, others, moved) = try await Blocking.run(.userInitiated) {
                    let (same, others) = TrashEntry.same(pairs.map { (from: $0.from, entry: TrashEntry(origin: $0.to, ino: inodes[$0.from])) })
                    let (renames, jobs) = Self.splitMoves(same)
                    try BatchRename.run(renames)
                    return (renames, jobs, others, Self.trashInodes(renames.map(\.to)))
                }
                for job in jobs {
                    replayJobs.append(job)
                    ops.enqueue(job, title: "\(title) \(Self.describe(job.sources.map { URL(fileURLWithPath: $0) }))")
                }
                fill(record, renames, jobs)
                record.inodes = moved
                if !others.isEmpty {
                    showError(JobErrorMessage("Left in the Trash — another item has this name there now:\n"
                        + others.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n")))
                }
                updateTrashLog(after: renames)   // the jobs': once they've run (jobFinished)
                // ⌘Z of a rename: its tab goes back with it, and the tabs inside a renamed folder.
                // ponytail: not held while renaming, as ⇧F6 holds it — a ⌘S in that instant makes the old name again.
                await Editor.renamed(renames)
            } catch {
                fill(record, [], [])
                showError(JobErrorMessage("Can't undo \(title.lowercased()): \(error.localizedDescription)"))
            }
            panels.forEach { $0.reload() }
        }
    }

    func jobFinished(_ job: FileJob) {
        AuditLog.write(job, sync: syncJobs.contains(job), by: aiJobs.contains(job) ? "ai" : nil)
        aiJobs.remove(job)
        reloadVolumes()   // Locations' free space
        syncJobs.remove(job)
        // Local panels follow the disk (FSEvents); a server panel has to ask again.
        for p in panels {
            if let r = p.remote, [job.from, job.to].contains(where: { if case .sftp(let t) = $0 { t.asUser == r.target.asUser } else { false } }) { p.reload() }
        }
        if job.from == .local, job.kind != .copy { forgetGone(job.sources) }   // F6, F8, Trash
        let pairs = job.results.map { (from: $0.src, to: $0.dst) }   // empty for a server: no undo there
        if job.kind == .move, job.from == .local, job.to == .local, let dir = job.destDir {   // F6: its tabs follow
            // A Replace, a merge or a move cut short leaves no pair: where each source would be, if it moved.
            // ponytail: at the job's end — a ⌘S meanwhile writes an item already moved at its old path; follow per item if that shows.
            let done = Set(pairs.map(\.from)), rest = job.sources.filter { !done.contains($0) }
            Task { await Editor.renamed(pairs + rest.map { ($0, (dir as NSString).appendingPathComponent(($0 as NSString).lastPathComponent)) }, checked: true) }
        }
        // An undo/redo's own job: performMoves registered what comes next already.
        if let i = replayJobs.firstIndex(where: { $0 === job }) { replayJobs.remove(at: i); return updateTrashLog(after: pairs) }
        switch job.kind {
        case .move: registerMoves("Move", pairs)
        case .trash:
            registerTrashed(pairs)
            recordTrash(pairs)
        case .copy: registerCreated("Copy", pairs.map(\.to))
        case .delete: break
        }
    }

    /// Undo of Move to Trash = put back: only the items moved there, by inode — read as the next undo work, so an undo
    /// waits for it.
    func registerTrashed(_ pairs: [(from: String, to: String)]) {
        guard !pairs.isEmpty else { return }
        let record = MoveRecord(done: (pairs, []))
        registerMoves("Move to Trash", record)
        afterUndoWork { record.inodes = await Blocking.run(.userInitiated) { Self.trashInodes(pairs.map(\.to)) } }
    }

    static func describe(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
    }

    /// Absolute path from user input: expands "~", resolves relative to `dir`, else to the active panel.
    func resolve(_ input: String, from dir: String? = nil) -> String {
        let p = (input as NSString).expandingTildeInPath
        let abs = p.hasPrefix("/") ? p : ((dir ?? active.path) as NSString).appendingPathComponent(p)
        return (abs as NSString).standardizingPath
    }
}

/// What an undo/redo moved (`registerMoves`): nil until its disk work is done.
@MainActor final class MoveRecord {
    var done: (renames: [(from: String, to: String)], jobs: [FileJob])?
    /// What it moved into a Trash, by inode at the path there (`trashInodes`).
    var inodes: [String: UInt64] = [:]
    init(done: (renames: [(from: String, to: String)], jobs: [FileJob])?) { self.done = done }
}
