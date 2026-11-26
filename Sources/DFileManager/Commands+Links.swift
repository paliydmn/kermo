import AppKit
import DFMCore

extension AppDelegate {
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
        var now = false   // the file as it is there now, even with its document open (that's the other side)
        var origin: (target: SFTPTarget?, path: String)? = nil   // a copy's (a kept version, "yours", a draft): the file it's of
        var label: String { name ?? server.map { "\($0.host):\(path)" } ?? path }
        /// Its tab in the built-in Compare: the file's name, and what it is if the caller said ("nginx.conf @ 14:03").
        var title: String { ((name ?? path) as NSString).lastPathComponent + (name == nil ? server.map { " (\($0.host))" } ?? "" : "") }
        /// Under its tab's title: where it is.
        @MainActor var place: String {
            if server == nil, path.hasPrefix(AppDelegate.historyRoot + "/") { return "a version kept on this Mac" }
            return DocFrame.place((path as NSString).deletingLastPathComponent, host: server.map { SavedServer.name(for: $0) })
        }
    }

    /// A side of the built-in Compare: an open document as it is, live; or a file read as it is now — a read-only copy.
    enum CompareSide { case doc(Editor), file(DiffSide) }

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

    /// Next / Previous Change of the editor window's comparison, from the side with the keys.
    func compareStep(_ d: Int) {
        guard let h = editorKey, let c = h.comparison else { return NSSound.beep() }
        c.step(d, from: h.active?.current)
    }

    /// `a` (old) against `b` (new) — the one way every Compare of files goes: `diffCommand`'s program with their copies
    /// if it's set; else the built-in Compare (a file open in the editor as its document, unless the side wants it as
    /// it is `now`); `plain`, or a file that isn't text: `diff -u` in an output window (a question that stays up while
    /// it shows — Reload…?, a copy's "already there" — asks for that). A server's file goes through its local copy
    /// (`localCopy`).
    func diff(_ a: DiffSide, _ b: DiffSide, in panel: PanelViewController, plain: Bool = false) async {
        if !plain, builtInCompare {
            guard a.now || b.now || a.path != b.path || a.server != b.server else { return panel.flash("Both sides are the same file") }
            func side(_ d: DiffSide) -> CompareSide {
                guard !d.now, let e = d.server.map({ Editor.editing($0, d.path) }) ?? Editor.document(at: d.path), e.host?.tabbed == true else { return .file(d) }
                return .doc(e)
            }
            return await compare(side(a), side(b), in: panel)
        }
        guard await unlock([a, b].compactMap { $0.server.map(Endpoint.sftp) }) else { return }
        guard let la = await localCopy(a, in: panel), let lb = await localCopy(b, in: panel) else { return }
        let (qa, qb) = (ShellContext.quote(la), ShellContext.quote(lb))
        if let tool = defaults.string(forKey: "diffCommand") {
            Self.runDiff(Self.fillDiff(tool, qa, qb), panel.path, true, nil)
        } else {
            let named = a.server != nil || b.server != nil || a.name != nil || b.name != nil
            Self.runDiff(Self.diffCommand(la, lb, labels: named ? (a.label, b.label) : nil), panel.path, false,
                         named ? "diff \(a.label) ↔ \(b.label)" : nil)   // not the copies' temp paths
        }
    }

    /// No `diffCommand`: files are compared in the editor (`compare`), not by a program of the user's.
    var builtInCompare: Bool { defaults.string(forKey: "diffCommand") == nil }

    /// A Compare of files outside the editor: `diffCommand`'s program (`external`), or `diff -u` in an output window
    /// under `title` (tests: nothing runs, they keep the command).
    static var runDiff: @MainActor (_ command: String, _ dir: String, _ external: Bool, _ title: String?) -> Void = { command, dir, external, title in
        if external { Shell.spawn(command, in: dir) } else { Shell.run(command, in: dir, diff: true, title: title) }
    }

    /// The built-in Compare of `a` (old) and `b` (new) in the editor window (`EditorHost.compare`): a file read now as a
    /// read-only copy — a server's downloaded as a preview's is, after its lock. Two files of which one isn't text
    /// (binary, over 32 MB): `diff -u`, as before; a document against such a file: why not, said.
    func compare(_ a: CompareSide, _ b: CompareSide, in panel: PanelViewController? = nil) async {
        let panel = panel ?? active
        var files: [DiffSide] = []
        for case .file(let d) in [a, b] { files.append(d) }
        guard await unlock(files.compactMap { $0.server.map(Endpoint.sftp) }) else { return }
        var made: [Editor] = []
        func editor(_ s: CompareSide) async -> Editor? {
            guard case .file(let d) = s else { if case .doc(let e) = s { return e }; return nil }
            guard let path = await localCopy(d, in: panel) else { return nil }
            switch await Blocking.run(.userInitiated, { Result { try Editor.load(URL(fileURLWithPath: path)) } }) {
            case .success(let loaded):
                let e = Editor.snapshot(loaded, file: (d.path as NSString).lastPathComponent, title: d.title, place: d.place,
                                        source: d.now || d.name != nil ? nil : d,   // a real file, not its document's other side: Edit
                                        from: d.origin ?? (d.server != nil || d.name == nil ? (d.server, d.path) : nil))
                made.append(e)
                return e
            case .failure(let error):
                if case .file(let x) = a, case .file(let y) = b { await diff(x, y, in: panel, plain: true) }   // as Compare Files always did
                else { panel.flash(error.localizedDescription, error: true) }
                return nil
            }
        }
        guard let ea = await editor(a) else { return }
        guard let eb = await editor(b) else { return made.forEach { $0.closed() } }   // in no tab yet: out of the lookups only
        // A document closed while a copy downloaded isn't brought back; one file on both sides is nothing to compare.
        guard [ea, eb].allSatisfy({ $0.snapshot != nil || Editor.isTab($0) }) else { return made.forEach { $0.closed() } }
        guard ea !== eb else { return panel.flash("Both sides are the same file") }   // two spellings of one path (/tmp, /private/tmp)
        EditorHost.tabs.compare(old: ea, new: eb, snapshots: made)
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
    func showText(_ data: Data, as name: String, prefix: String) {
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
}
