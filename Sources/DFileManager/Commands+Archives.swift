import AppKit
import DFMCore

extension AppDelegate {
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
            if view { Viewer.show(url) { TempCopies.remove(url.deletingLastPathComponent().path) } } else {
                FileInfo.quarantine(url.path)   // the archive's own if it has one, else Kermo's
                // Read-only: edits there would go with the temp folder (a day on), so the app says "locked" and offers
                // Duplicate. After the quarantine: setxattr on a read-only file fails (EACCES).
                var st = stat()
                if Darwin.lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG { chmod(url.path, st.st_mode & 0o7555) }
                Self.openInApp(url)
                active.flash("A temporary copy, read-only — ⌥F9 Extract keeps your changes")
            }
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
            if sel == nil && ArchiveIndex.isTar(file) { return extractWholeTar(file, to: dest) }
            await extract(file, sel, to: dest)
        }
    }

    /// Extract once `dest` is known (all of a zip, 7z…, or a selection inside any archive). Over what's there it
    /// unpacks into a hidden folder first, as a whole tar does: bsdtar removes a file and writes the new one under its
    /// name, so ⎋, a full disk, a bad member or a quit midway would leave one gone and the other cut short. Returns
    /// once it's all done.
    func extract(_ file: String, _ sel: (index: ArchiveIndex, inner: String, names: [String])?, to dest: String) async {
        // What lands at the top of `dest`; bsdtar would silently replace any of it that's there already.
        let (index, clashes) = await Blocking.run { () -> (ArchiveIndex?, [String]) in
            let index = sel?.index ?? (try? ArchiveIndex.read(file))
            let top = sel?.names ?? (index?.list("") ?? []).map(\.name)
            return (index, top.filter { var st = stat(); return Darwin.lstat((dest as NSString).appendingPathComponent($0), &st) == 0 })
        }
        // Not readable as a whole (a damaged member, a format the reader refuses midway): its names aren't known, and
        // bsdtar extracts the rest anyway — over what's there, unasked. Unpacked aside first and asked after, as a tar.
        if index == nil, sel == nil { return extractWholeTar(file, to: dest) }
        let shown = (dest as NSString).abbreviatingWithTildeInPath
        guard let keep = await keepExisting(clashes, in: shown) else { return }
        let staging: String?
        do {
            staging = try await Blocking.run { () throws -> String? in
                try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
                guard !clashes.isEmpty else { return nil }   // nothing there to lose: only what's new can be cut short
                let staging = ArchiveIndex.stagingFolder(in: dest)
                try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: false)
                return staging
            }
        } catch {
            return showError(error)
        }
        let into = staging ?? dest
        let args = index?.extractArguments(sel?.names ?? [], from: sel?.inner ?? "", to: into) ?? ["-x", "-f", file, "-C", into]
        let status = await withCheckedContinuation { done in
            Shell.run("/usr/bin/tar -v " + args.map(ShellContext.quote).joined(separator: " ") + " 2>&1", in: dest,
                      title: "Extract “\((file as NSString).lastPathComponent)” → \(shown)",
                      failed: staging.map { _ in Self.nothingExtracted(shown) }) { done.resume(returning: $0) }
        }
        if let staging { await moveOut(staging, to: dest, keep: status == 0 ? keep : nil) } else { panels.forEach { $0.reload() } }
    }

    /// Under a failed or stopped tar that unpacked into a staging folder: none of it lands.
    static func nothingExtracted(_ dest: String) -> String { "Nothing was extracted — what was in \(dest) is as it was." }

    /// The end of an extract through a staging folder: what's in it moves into `dest` (`keep`: what's there stays),
    /// or with nil (stopped, failed, cancelled) none of it lands there. The window already says what tar said.
    private func moveOut(_ staging: String, to dest: String, keep: Bool?) async {
        let errors = await Blocking.run {
            guard let keep else { ArchiveIndex.discardStaging(staging); return [String]() }
            return ArchiveIndex.moveExtracted(staging, to: dest, keep: keep)
        }
        panels.forEach { $0.reload() }
        if !errors.isEmpty {
            showError(JobErrorMessage(errors.prefix(8).joined(separator: "\n") + (errors.count > 8 ? "\n…" : "")))
        }
    }

    /// All of a tar, without reading it once first just for the names at its top (listing a .tar.gz unpacks all of
    /// it). Into an empty or new folder as it is; else into a hidden folder inside `dest`, and once that's done, what
    /// was there already is asked about, then the rest moves out by rename.
    private func extractWholeTar(_ file: String, to dest: String) {
        Task {
            let staging: String?
            do {
                staging = try await Blocking.run { () throws -> String? in
                    try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
                    guard try !FileManager.default.contentsOfDirectory(atPath: dest).isEmpty else { return nil }
                    let staging = ArchiveIndex.stagingFolder(in: dest)
                    try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: false)
                    return staging
                }
            } catch {
                return showError(error)
            }
            let shown = (dest as NSString).abbreviatingWithTildeInPath
            let args = ["-x", "-f", file, "-C", staging ?? dest]
            Shell.run("/usr/bin/tar -v " + args.map(ShellContext.quote).joined(separator: " ") + " 2>&1", in: dest,
                      title: "Extract “\((file as NSString).lastPathComponent)” → \(shown)",
                      failed: staging.map { _ in Self.nothingExtracted(shown) }) { [self] status in
                guard let staging else { return panels.forEach { $0.reload() } }
                Task {
                    // stopped (⎋) or failed: half an archive doesn't land in `dest`
                    let clashes = await Blocking.run { status == 0 ? ArchiveIndex.clashes(staging, dest) : [] }
                    await self.moveOut(staging, to: dest, keep: status == 0 ? await self.keepExisting(clashes, in: shown) : nil)
                }
            }
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
            guard await unlock([.sftp(target)], to: "extract an archive on") else { return }
            guard let input = await prompt("Extract “\((item.name as NSString).lastPathComponent)” on \(target.host) to:", value: there,
                                           ok: "Extract", strip: target), !input.isEmpty else { return }
            let dest = ((input.hasPrefix("/") ? input : (dir as NSString).appendingPathComponent(input)) as NSString).standardizingPath
            // What lands at the top of `dest` that's there already: tar and unzip -o would replace it.
            let found = await panel.busy("Reading “\((item.name as NSString).lastPathComponent)”…") { flag in
                let top = RemoteArchive.topNames(try SSHCommand.capture(target, RemoteArchive.namesCommand(file), env: env, cancel: flag), of: file)
                // A refused channel or no permission isn't "nothing there": taken as such, tar -x and unzip -o
                // replaced what was there unasked.
                let present = Set(try SFTP.listIfThere(target, dest, env: env, cancel: flag).map(\.name))
                return top.filter(present.contains)
            }
            guard case .success(let clashes) = found else {
                if case .failure(let e) = found, !(e is CancellationError) { showError(e) }
                return
            }
            guard let keep = await keepExisting(clashes, in: DirSync.place(.sftp(target), dest)) else { return }
            let command = RemoteArchive.extractCommand(file, to: dest, keep: keep)
            Shell.run(command, on: target, in: dir,
                      title: "Extract “\((item.name as NSString).lastPathComponent)” → \(dest) on \(target.host)") { [weak self] status in
                AuditLog.write(target.asUser, "extract", paths: [file], to: dest, command: command, exit: status)   // ran as the user (ssh)
                for p in self?.panels ?? [] where p.remote?.target.asUser == target.asUser { p.reload() }
            }
        }
    }

    /// ⌥F5: pack the marked items; the format follows the extension (.zip .tar.gz .tar.xz .7z …). tar packs into a
    /// hidden file beside the archive, which becomes it only when tar exits 0 (`ArchiveIndex.publish`).
    func compressDialog() {
        // The items, their folder and the panel now: once the questions are answered the panel may be elsewhere.
        let panel = active
        if panel.archive != nil { return readOnly() }
        let srcs = panel.targetURLs, dir = panel.itemsDir, here = panel.path
        guard !srcs.isEmpty else { return NSSound.beep() }
        let base = srcs.count == 1 ? srcs[0].deletingPathExtension().lastPathComponent : (here as NSString).lastPathComponent
        let suggestion = (other.path as NSString).appendingPathComponent((base.isEmpty ? "archive" : base) + ".zip")
        Task {
            guard let input = await prompt("Compress \(srcs.count == 1 ? "“\(srcs[0].lastPathComponent)”" : "\(srcs.count) items") into:",
                                           value: (suggestion as NSString).abbreviatingWithTildeInPath, ok: "Compress",
                                           info: "Format from the extension: .zip .tar.gz .tgz .tar.bz2 .tar.xz .7z")
            else { return }
            let archive = resolve(input, from: here), tmp = ArchiveIndex.packingPath(for: archive)
            let taken = await Blocking.run(.userInitiated) {   // a share that doesn't answer
                Editor.sweepSaves(in: (archive as NSString).deletingLastPathComponent, prefix: ".dfm-pack-")
                return FileManager.default.fileExists(atPath: archive)
            }
            guard !taken else { return showError(JobErrorMessage("“\(input)” already exists.")) }
            let args = ArchiveIndex.createArguments(tmp, names: srcs.map { Self.name($0, in: dir) }, in: dir)
            Shell.run("COPYFILE_DISABLE=1 /usr/bin/tar -v " + args.map(ShellContext.quote).joined(separator: " ") + " 2>&1", in: dir,
                      title: "Compress into \((archive as NSString).abbreviatingWithTildeInPath)",
                      failed: "Nothing was kept: “\((archive as NSString).lastPathComponent)” wasn't made.") { status in
                Task {
                    let failure = await Blocking.run(.userInitiated) { () -> String? in
                        do { try ArchiveIndex.publish(tmp, as: archive, exit: status); return nil } catch { return error.localizedDescription }
                    }
                    if let failure { self.showError(JobErrorMessage(failure)) }
                    self.panels.forEach { $0.reload() }
                }
            }
            panel.unmarkAll()
        }
    }
}
