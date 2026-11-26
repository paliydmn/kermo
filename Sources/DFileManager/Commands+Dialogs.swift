import AppKit
import DFMCore

extension AppDelegate {
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
        // Asked first: a locked server's, and one not learned yet — it may be a production server under another name.
        let locked = [from, side].compactMap { e -> SFTPTarget? in
            if case .sftp(let t) = e, ServerLock.needsUnlock(t) || !ServerLock.isLearned(t) { t } else { nil }
        }
        let what = sources.count == 1 ? (name ?? (sources[0] as NSString).lastPathComponent) : "\(sources.count) items"
        let place = DirSync.place(side, dir)
        let title = "\(move ? "Move" : "Copy") \(what) → \(place)"
        let prod = prodAsked ? [] : Self.changed(from: from, to: side, move: move).filter(SavedServer.isProd)
        if !locked.isEmpty || !prod.isEmpty {
            Task {
                let landing = side == .local ? [] : sources.map { (dir as NSString).appendingPathComponent(name ?? ($0 as NSString).lastPathComponent) }
                let unchecked = Self.uncheckedNote(landing, rules: ConfigCheck.rules(FileManager.default.contents(atPath: Self.validatorsPath)).rules)
                let passed = await gate(locked) {
                    let prod = prodAsked ? [] : Self.changed(from: from, to: side, move: move).filter(SavedServer.isProd)   // learned by now
                    return prod.isEmpty ? nil : Self.prodTransfer("\(move ? "Move" : "Copy") \(sources.count == 1 ? "“\(what)”" : what) to \(place)?", sources, to: prod, move: move,
                                                                  unchecked: unchecked)
                }
                if case .locked(let t) = passed { return active.flash("\(t.host) stays locked") }
                guard passed == .pass else { return }
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
            let unchecked = Self.uncheckedNote(e.to == .local ? [] : failures.compactMap(\.dst),
                                               rules: ConfigCheck.rules(FileManager.default.contents(atPath: Self.validatorsPath)).rules)
            guard await gate([], question: {
                let prod = Self.changed(from: e.from, to: e.to, move: move).filter(SavedServer.isProd)
                guard !prod.isEmpty else { return nil }
                let what = failures.count == 1 ? "“\((failures[0].src as NSString).lastPathComponent)”" : "\(failures.count) items"
                var c = Self.prodTransfer("Retry \(move ? "moving" : "copying") \(what)?", failures.map(\.src), to: prod, move: move, unchecked: unchecked)
                c.action = "Retry"
                return c
            }) == .pass else { return }
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

    /// Touch ID first for each locked server among `ends` (`action`: what for, in the system's prompt), as listing
    /// one of its folders asks; false (and said so) if one stays locked. The gate without a question: what walks a
    /// whole tree there (compare, sync, search) and what changes a file on it.
    func unlock(_ ends: [Endpoint], to action: String = "connect to") async -> Bool {
        if case .locked(let t) = await gate(ends.compactMap { if case .sftp(let t) = $0 { t } else { nil } }, to: action) {
            active.flash("\(t.host) stays locked")
            return false
        }
        return true
    }

    /// Synchronize's jobs, once each locked server is unlocked — and okayed where they change a production server or
    /// delete on one (no Trash there), like F5 and F8 there. False if nothing was queued.
    func enqueueSync(_ jobs: [(job: FileJob, label: String)]) async -> Bool {
        func server(_ e: Endpoint) -> SFTPTarget? { if case .sftp(let t) = e { t } else { nil } }
        let changed = jobs.compactMap { server($0.job.to) }   // a delete's `to` is its server too
        let deleted = jobs.filter { $0.job.kind == .delete }.reduce(0) { $0 + $1.job.sources.count }
        guard await unlock(jobs.flatMap { [$0.job.from, $0.job.to] }) else { return false }
        guard await gate([], question: {
            let prod = changed.filter(SavedServer.isProd)   // learned by the lock above
            guard !prod.isEmpty || deleted > 0 else { return nil }
            let hosts = Set(changed.map(\.host)).sorted().joined(separator: ", ")
            var c = Confirm("Synchronize with \(hosts)?", action: "Synchronize")
            c.on(prod)
            c.note = deleted > 0
                ? "\(deleted) item\(deleted == 1 ? "" : "s") only there \(deleted == 1 ? "is" : "are") deleted — a server has no Trash. This can't be undone."
                : "Files there may be overwritten."
            c.irreversible = deleted > 0
            return c
        }) == .pass else { return false }
        for (job, label) in jobs {
            syncJobs.add(job)   // the production log says "sync"
            ops.enqueue(job, title: label)
        }
        return true
    }

    /// Files a copy or move puts where a save is checked before it takes the file's place (sudoers, sshd_config …): they
    /// go in as they are — said in the production question. ponytail: the items it names, not what's inside a folder;
    /// and not a tool's checks (§11) — dpl's runs once the file is in place, which a copy doesn't claim.
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

    func readOnly() {
        active.flash(active.remote != nil ? "Not available on SFTP" : "Archives are read-only here — F5 Extract")
    }

    /// chmod / chown of the marked items (or the cursor's) as "644 me:staff": a part left as shown stays as each
    /// item has it (blank where they differ). Never through a symlink (`SFTPClient.setPermissions` on a server, where ids
    /// are its own numbers).
    func attributesDialog() {
        if active.archive != nil { return readOnly() }
        let items = active.selectedItems, r = active.remote, paths = active.targetURLs.map(\.path)
        guard !items.isEmpty, r != nil || paths.count == items.count else { return NSSound.beep() }
        func common(_ f: (FileItem) -> UInt32) -> UInt32? { items.allSatisfy { f($0) == f(items[0]) } ? f(items[0]) : nil }
        func id(_ f: (FileItem) -> UInt32, user: Bool) -> String {
            guard let n = common(f), n != FileItem.unknown else { return "" }
            return r != nil ? String(n) : PanelViewController.idName(n, user: user)
        }
        let owner = id(\.uid, user: true), group = id(\.gid, user: false), panel = active
        // The owner keeps its colon ("1000:", ":20"): a number alone is a mode.
        let shown = [common { $0.mode & 0o7777 }.map { String(format: "%03o", $0) } ?? "", owner.isEmpty && group.isEmpty ? "" : owner + ":" + group]
            .filter { !$0.isEmpty }.joined(separator: " ")
        Task {
            if let r { guard await unlock([.sftp(r.target)], to: "change permissions on") else { return } }
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
            let linksKeep = r == nil ? nil : Self.linksKeepMode(items, mode: mode)
            if let linksKeep, items.allSatisfy({ $0.kind == .link }), ids.uid == nil, ids.gid == nil { return panel.flash(linksKeep) }
            if let r {
                let each = items.map { ((r.dir as NSString).appendingPathComponent($0.name), $0) }, root = r.target.sudo || ServerLock.logsInAsRoot(r.target)
                let done = await remoteOp("Permissions", r.target, paths: each.map(\.0)) { c in
                    try c.setPermissions(each, mode: mode, uid: ids.uid, gid: ids.gid, root: root)
                }
                if done, let linksKeep { panel.flash(linksKeep) }
                return
            }
            let errors = await Blocking.run { Perms.apply(paths, mode: mode, uid: ids.uid, gid: ids.gid) }
            active.reload()
            if !errors.isEmpty { showError(JobErrorMessage("Permissions and owner:\n" + errors.joined(separator: "\n"))) }
        }
    }

    /// A mode change on a server leaves its symbolic links as they are (`SFTPClient.setPermissions`): said, not silent.
    nonisolated static func linksKeepMode(_ items: [FileItem], mode: UInt32?) -> String? {
        let links = items.filter { $0.kind == .link }
        guard mode != nil, let first = links.first else { return nil }
        let which = links.count == 1 ? "“\(first.name)” keeps its mode" : "\(links.count) links keep their mode"
        return "\(which): a symbolic link on a server has none of its own — change the item it points to."
    }

    func renameDialog() {
        if let e = textEditor { return e.host.beginRename(e) }   // ⇧F6 in an editor: its tab's file (`editorTitles`)
        if active.remote != nil { return remoteRename() }
        guard let url = active.cursorURL else { return NSSound.beep() }
        let old = url.lastPathComponent
        Task {
            guard let name = await prompt("Rename “\(old)” to:", value: old, ok: "Rename", selectBaseName: true),
                  name != old, !name.isEmpty else { return }
            let dst = url.deletingLastPathComponent().appendingPathComponent(name).path
            if let why = Editor.renameRefused(url.path, to: dst) { return showError(JobErrorMessage(why)) }   // its tab saving, or `dst` open
            // Off the main thread: a share that doesn't answer. Its tab can't save meanwhile (the old name again).
            let rename = { await Blocking.run(.userInitiated) { Result { try Self.rename(url.path, to: name) } } }
            let tab = Editor.following(url.path)
            let done = if let tab { await tab.renaming(rename) } else { await rename() }
            if case .failure(let e) = done { return showError(e) }
            registerMoves("Rename", [(from: url.path, to: dst)])
            forgetGone([url.path])   // not after a case-only rename
            active.reload(select: name)
            await Editor.renamed(url.path, to: dst)   // its tab follows: ⌘S doesn't make the old name again
        }
    }

    /// Why `name` isn't one to give a file, if it isn't (a rename on this Mac or a server, an Untitled's).
    nonisolated static func badName(_ name: String) -> String? {
        if name.contains("/") { return "A name can't contain “/”" }
        if name.contains("\0") { return "A name can't contain a NUL character" }
        return name == "." || name == ".." ? "“\(name)” isn't a name a file can have" : nil
    }

    /// The panel's ⇧F6 and an editor tab's on this Mac: the item at `path` (a link itself, not where it points) is
    /// `name` in its folder now — never over anything there: `RENAME_EXCL`, so an item appearing meanwhile stays and
    /// nothing is renamed. Only the item itself by another case (a disk that ignores case) is renamed plainly. Off the
    /// main thread; the new path. `willRename`: tests, between the look and the rename.
    nonisolated static func rename(_ path: String, to name: String, willRename: (String) -> Void = { _ in }) throws -> String {
        if let why = badName(name) { throw JobErrorMessage(why) }
        let dir = (path as NSString).deletingLastPathComponent, dst = (dir as NSString).appendingPathComponent(name)
        var a = stat(), b = stat()
        guard lstat(path, &a) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        // The item itself under `dst` — only its case changes, on a disk that ignores case (not a hard link of another name).
        let caseOnly = pathconf(dir, _PC_CASE_SENSITIVE) == 0 && name.caseInsensitiveCompare((path as NSString).lastPathComponent) == .orderedSame
        func itself() -> Bool { caseOnly && lstat(dst, &b) == 0 && (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino) }
        if lstat(dst, &b) == 0, !itself() { throw JobErrorMessage("“\(name)” already exists — nothing was renamed.") }
        willRename(dst)
        if renamex_np(path, dst, UInt32(RENAME_EXCL)) == 0 { return dst }
        var err = errno
        // Taken: by the item itself in another case, else by one that appeared meanwhile. A disk that can't rename only
        // where nothing is: looked at once more, then renamed. ponytail: an item appearing in that instant is replaced,
        // as a save there (D-180).
        if err == EEXIST && !itself() || (err == ENOTSUP || err == EINVAL) && lstat(dst, &b) == 0 && !itself() {
            throw JobErrorMessage("“\(name)” appeared there meanwhile — nothing was renamed.")
        }
        if err == EEXIST || err == ENOTSUP || err == EINVAL {
            if Darwin.rename(path, dst) == 0 { return dst }
            err = errno
        }
        if err == EACCES || err == EPERM {
            throw JobErrorMessage("No permission to rename “\((path as NSString).lastPathComponent)” in “\((dir as NSString).lastPathComponent)”.")
        }
        throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
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
}
