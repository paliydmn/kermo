import AppKit
import CryptoKit
import DFMCore

/// F4 built-in editor for config files and scripts: plain text, undo, find & replace (⌘F),
/// ⌘S saves, Esc closes (asks about unsaved changes), reloads when the file changes on disk.
/// Saving asks before overwriting a change made on disk meanwhile; it writes a temp file and renames it over
/// the original, keeping mode, owner, ACL, xattrs, flags and creation date — or rewrites a hard-linked file or
/// someone else's in place. A UTF-8 BOM and CRLF line ends are kept, new lines included.
@MainActor
final class Editor: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    private static var open: [Editor] = []
    /// Names of the files with unsaved changes (asked about at quit).
    static var unsaved: [String] { open.filter(\.changed).map(\.url.lastPathComponent) }
    /// The save didn't reach where the file really lives (a server): still unsaved, so closing asks.
    static func markUnsaved(_ url: URL) { open.first { $0.url == url }.map { $0.dirty = true; $0.unsent = true } }
    static func window(for url: URL) -> NSWindow? { open.first { $0.url == url }?.window }
    /// The server's file an editor window edits through its local copy (Server File History… there).
    static func server(of window: NSWindow?) -> (target: SFTPTarget, path: String)? {
        open.first { $0.window === window && window != nil }?.server.map { ($0.target, $0.path) }
    }
    /// The open editor of that server's file, if any.
    static func editing(_ t: SFTPTarget, _ path: String) -> Editor? { open.first { $0.server?.target == t && $0.server?.path == path } }
    /// The root write behind Save as Administrator (tests swap it: the real one shows the password dialog).
    static var runAsAdmin: (String) async -> Admin.Outcome = Admin.run
    /// Changes only on Save As.
    private(set) var url: URL
    /// "host:/path" of a server's file edited through its local copy: the title, not the copy's temp folder.
    private var remote: String?
    var server: (target: SFTPTarget, path: String, state: AppDelegate.RemoteEdit)?   // its saves go up with `state`
    let textView = EditorTextView(usingTextLayoutManager: false)   // TextKit 1: the line-number ruler needs it
    private var ruler: LineNumberRuler!
    private var language: Syntax.Language?
    private var highlightGen = 0
    /// The tokens the text wears now and its length then; and what's been edited since (from where, and how far
    /// from the end): the next tint paints only that and where tokens changed.
    private var tinted: (tokens: [(range: NSRange, token: Syntax.Token)], length: Int)?
    private var editedSince: (from: Int, tail: Int)?
    private var encoding: String.Encoding
    /// Read as UTF-8 with bytes that aren't UTF-8 shown as U+FFFD: saving writes U+FFFD in their place.
    private var lossy = false
    /// The file starts with a UTF-8 BOM / ends every line with CRLF (the text view has plain \n): saving writes them back.
    private var bom = false, crlf = false
    /// Saving ends the text with a newline (crontab ignores a last line without one). On for config files
    /// (see `isConfig`) unless the `editorFinalNewline` setting says always or never; File ▸ toggles it per window.
    var finalNewline: Bool
    static var finalNewlineSetting: () -> Bool? = { UserDefaults.standard.object(forKey: "editorFinalNewline") as? Bool }
    /// Tests: runs between checking the file and opening it for an in-place rewrite (off the main thread). This
    /// window's own: tests run side by side, and a save no longer holds the main thread while it writes.
    var willRewriteInPlace: @Sendable (String) -> Void = { _ in }
    /// Tests: writes the text into the file an in-place save opened (to fail it midway).
    var rewriteInPlace: @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    /// A lossy or Windows-1251 file was asked about before its first save.
    private var encodingAsked = false
    /// The file as we last loaded or saved it; a save over anything else asks first.
    private var stamp: Stamp?
    private var digest: SHA256.Digest?
    /// The on-disk version the user was already asked about (sheets give the key back, which would ask again).
    private(set) var noticed: Stamp?
    private var dirty = false { didSet { window?.isDocumentEdited = dirty } }
    private var unsent = false   // saved here, but not where it lives (a server): the same bytes still count as a change
    private(set) var saving = false   // a save's disk work is under way (the text can't be edited meanwhile)

    /// Called after each successful save (remote files use it to upload the copy back).
    private var onSaved: (@MainActor (URL) -> Void)?
    /// Called once the window closes (or the file couldn't be opened).
    var onClose: (@MainActor () -> Void)?

    /// Reads the file off the main thread (up to 32 MB, or a share that doesn't answer), then opens the window.
    /// `note`: said in its subtitle once it's open (`flash`).
    static func open(_ url: URL, remote: String? = nil, server: (target: SFTPTarget, path: String, state: AppDelegate.RemoteEdit)? = nil,
                     note: String? = nil, onSaved: (@MainActor (URL) -> Void)? = nil, onClose: (@MainActor () -> Void)? = nil) {
        if let existing = open.first(where: { $0.url == url }) { return existing.window!.makeKeyAndOrderFront(nil) }
        Task {
            let loaded = await Blocking.run(.userInitiated) { Result { try load(url) } }
            // Opened meanwhile (↩ twice during a slow read): one window per file.
            if let existing = open.first(where: { $0.url == url }) { return existing.window!.makeKeyAndOrderFront(nil) }
            do {
                let e = try Editor(url, remote: remote, loaded: loaded.get())
                e.onSaved = onSaved
                e.onClose = onClose
                e.server = server
                open.append(e)
                e.showWindow(nil)
                if let note { e.flash(note) }
            } catch {
                onClose?()
                let a = NSAlert(error: error)
                a.messageText = a.messageText.bidiVisible
                a.runModal()
            }
        }
    }

    convenience init(_ url: URL, remote: String? = nil) throws {
        try self.init(url, remote: remote, loaded: Self.load(url))
    }

    private init(_ url: URL, remote: String?, loaded: Loaded) {
        let (text, encoding, lossy, bom, crlf, stamp, digest) = loaded
        self.url = url
        self.remote = remote
        self.encoding = encoding
        self.lossy = lossy
        self.bom = bom
        self.crlf = crlf
        // A server copy goes by its path there ("host:/etc/x"), not the temp folder's.
        finalNewline = Self.finalNewlineSetting()
            ?? Self.isConfig(remote.flatMap { r in r.range(of: ":/").map { String(r[r.index(after: $0.lowerBound)...]) } } ?? url.path)
        self.stamp = stamp
        self.digest = digest
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        retitle()
        w.delegate = self

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        w.contentView = scroll
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        // Lays out what's on screen, not the whole text first: typing at the top of a 30 MB log stays quick.
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        // Config files and scripts must stay byte-exact: no smart quotes, dashes or autocorrect.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.string = text
        textView.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(storageEdited), name: NSTextStorage.didProcessEditingNotification,
                                               object: textView.textStorage)
        scroll.documentView = textView
        ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        language = Syntax.language(forFileName: url.lastPathComponent, firstLine: String(text.prefix(200).split(separator: "\n").first ?? ""))
        highlight(after: 0)
        w.center()
        w.setFrameAutosaveName("Editor")
        w.makeFirstResponder(textView)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func retitle() {
        window?.title = (remote ?? url.lastPathComponent).bidiVisible
        window?.subtitle = (remote == nil ? (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath + " · " : "")
            + "\(encodingName) · ⌘S save · ⌘F find/replace · Esc close"
        window?.representedURL = remote == nil ? url : nil
    }

    /// A revert put `data` on the server, which now has `attrs`: shown here, and the next save checks against that —
    /// unless this editor has changes of its own, which stay (their save then asks: the server's file changed).
    /// False if not shown.
    func reverted(to data: Data, attrs: SFTPClient.Attrs) async -> Bool {
        guard !changed, let server else { return false }
        let url = url
        guard await Blocking.run(.userInitiated, { (try? data.write(to: url)) != nil }) else { return false }
        server.state.baseline = attrs
        return await reload()
    }

    /// Says something in place of the subtitle for a few seconds (a server save's "no history: …"): the panels'
    /// status line is behind this window.
    static func flash(_ url: URL, _ text: String) { open.first { $0.url == url }?.flash(text) }
    func flash(_ text: String) {
        window?.subtitle = text.bidiVisible
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in MainActor.assumeIsolated { self?.retitle() } }
    }

    private var encodingName: String { encoding == .utf8 ? lossy ? "UTF-8 (damaged)" : "UTF-8" : "Windows-1251" }

    typealias Loaded = (String, String.Encoding, lossy: Bool, bom: Bool, crlf: Bool, Stamp?, SHA256.Digest)

    /// crontab, the per-user crontabs cron reads (named after the user), dotfiles, anything under /etc,
    /// and *.conf / .cfg / .ini / .yml / .toml and the like.
    static func isConfig(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let p = path.hasPrefix("/private/") ? String(path.dropFirst(8)) : path
        if name.hasPrefix(".") || name.hasPrefix("crontab")
            || ["/etc/", "/var/spool/cron/", "/var/at/tabs/", "/usr/lib/cron/tabs/"].contains(where: p.hasPrefix) { return true }
        return Syntax.language(forFileName: name).map { [.ini, .conf, .yaml].contains($0) } ?? false
    }

    /// Every line ends in CRLF (a file with mixed line ends is left as it is, and so is one with CR CR LF, which the
    /// text view couldn't tell from a pasted CRLF).
    nonisolated private static func isCRLF(_ data: Data) -> Bool {
        var prev2: UInt8 = 0, prev: UInt8 = 0, lines = 0
        for b in data {
            if b == 0x0A { if prev != 0x0D || prev2 == 0x0D { return false }; lines += 1 }
            (prev2, prev) = (prev, b)
        }
        return lines > 0
    }

    /// UTF-8; UTF-8 with a few damaged bytes (lossy, see `TextFormat.mostlyUTF8`); else Windows-1251.
    nonisolated private static func load(_ url: URL) throws -> Loaded {
        let stamp = Stamp(url.resolvingSymlinksInPath().path)   // before reading: a change in between shows as a conflict
        if let what = FileInfo.notRegular(url.path) { throw JobErrorMessage("“\(url.lastPathComponent)” is \(what) — not a file to edit.") }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? Int, size > 32 << 20 {
            throw JobErrorMessage("“\(url.lastPathComponent)” is larger than 32 MB — use the viewer (F3).")
        }
        let data = try Data(contentsOf: url)
        if TextFormat.looksBinary(data) {
            throw JobErrorMessage("“\(url.lastPathComponent)” looks like a binary file — use the viewer (F3).")
        }
        let digest = SHA256.hash(data: data)
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        let body = bom ? data.dropFirst(3) : data
        let crlf = isCRLF(data)
        func lf(_ s: String) -> String { crlf ? s.replacingOccurrences(of: "\r\n", with: "\n") : s }
        if let s = String(data: body, encoding: .utf8) { return (lf(s), .utf8, false, bom, crlf, stamp, digest) }
        if TextFormat.mostlyUTF8(body) { return (lf(String(decoding: body, as: UTF8.self)), .utf8, true, bom, crlf, stamp, digest) }
        if let s = String(data: data, encoding: .windowsCP1251) { return (lf(s), .windowsCP1251, false, false, crlf, stamp, digest) }
        throw JobErrorMessage("Can't decode “\(url.lastPathComponent)” as text.")
    }

    /// Which file is at a path and its size and mtime (through symlinks).
    struct Stamp: Equatable, Sendable {
        let dev: dev_t, ino: ino_t, size: off_t, sec: Int, nsec: Int
        init?(_ path: String) {
            var s = stat()
            guard stat(path, &s) == 0 else { return nil }
            (dev, ino, size, sec, nsec) = (s.st_dev, s.st_ino, s.st_size, s.st_mtimespec.tv_sec, s.st_mtimespec.tv_nsec)
        }
    }

    /// What's on disk at `path` if someone else replaced or wrote it since `stamp` / `digest` (another file, size,
    /// mtime or bytes); nil if it's still ours. A deleted file isn't a conflict — saving just recreates it.
    /// Reads the file: off the main thread.
    nonisolated private static func changed(_ path: String, from stamp: Stamp?, _ digest: SHA256.Digest?) -> Stamp? {
        guard let now = Stamp(path) else { return nil }
        return now != stamp || (try? Data(contentsOf: URL(fileURLWithPath: path))).map(SHA256.hash) != digest ? now : nil
    }

    private func saved(_ stamp: Stamp?, _ digest: SHA256.Digest) {
        dirty = false
        unsent = false
        if lossy { lossy = false; retitle() }   // the damaged bytes are U+FFFD now: clean UTF-8
        self.stamp = stamp
        self.digest = digest
    }

    func textDidChange(_ notification: Notification) {
        dirty = true
        highlight(after: 0.3)
    }

    @objc private func storageEdited(_ n: Notification) {
        guard let s = n.object as? NSTextStorage, s.editedMask.contains(.editedCharacters) else { return }
        let r = s.editedRange, tail = s.length - NSMaxRange(r)
        editedSince = (min(editedSince?.from ?? r.location, r.location), min(editedSince?.tail ?? tail, tail))
    }

    /// Re-tints the text in the background once typing pauses (what changed only); skips texts over 2 MB.
    private func highlight(after delay: TimeInterval) {
        guard let lang = language else { return }
        highlightGen += 1
        let gen = highlightGen
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.highlightGen else { return }
                let text = self.textView.string
                guard text.utf16.count <= 2 << 20 else { return }
                Task {
                    let tokens = await Task.detached(priority: .userInitiated) { Syntax.tokens(text, lang) }.value
                    guard gen == self.highlightGen, let storage = self.textView.textStorage, storage.string == text else { return }
                    let len = storage.length, e = self.editedSince ?? (len, 0)
                    if let t = self.tinted {
                        let edited = NSRange(location: e.from, length: max(0, len - e.tail - e.from))
                        if let r = SyntaxColors.changed(t.tokens, tokens, edited: edited, delta: len - t.length, length: len) {
                            SyntaxColors.apply(tokens, to: storage, in: r)
                        }
                    } else {
                        SyntaxColors.apply(tokens, to: storage)
                    }
                    (self.tinted, self.editedSince) = ((tokens, len), nil)
                }
            }
        }
    }

    // MARK: - Saving

    @objc func saveDocument(_ sender: Any?) { Task { await save() } }
    @objc func toggleFinalNewline(_ sender: Any?) { finalNewline.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleFinalNewline(_:)) { item.state = finalNewline ? .on : .off }
        return true
    }

    /// What saving writes: the text in its encoding, with the final newline if that's on, CRLF line ends and the BOM
    /// if the file had them.
    private var fileText: String {
        var text = textView.string
        if finalNewline, let last = text.last, !last.isNewline { text += "\n" }
        // A pasted CRLF stays one line end.
        return crlf ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") : text
    }

    /// Writes all of `data` to `fd`, makes it reach the disk itself (plain fsync where F_FULLFSYNC isn't supported) and closes it.
    /// From the start over what's there, and only then cut to length: a file written into in place is never shorter
    /// than the old text or the new one, even if the write stops midway (a full disk, a crash).
    nonisolated private static func write(_ data: Data, to fd: Int32,
                                          writing: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) throws {
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try writing(h, data)
        if ftruncate(fd, off_t(data.count)) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        try h.close()
    }

    /// Temp files of saves a crash left in `dir` (between their making and the rename), once a day old by name and
    /// date: a running save's is newer. One named before names said when (an older version's): its date alone.
    nonisolated private static func sweepSaves(in dir: String) {
        let cutoff = Date().timeIntervalSince1970 - 86_400
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix(".dfm-save-") {
            let made = name.dropFirst(".dfm-save-".count).split(separator: "-", maxSplits: 1).first.flatMap { Double($0) } ?? 0
            let path = (dir as NSString).appendingPathComponent(name)
            var st = stat()
            guard made < cutoff, lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, Double(st.st_mtimespec.tv_sec) < cutoff else { continue }
            lchflags(path, 0)   // a locked original's uchg came along
            unlink(path)
        }
    }

    /// Writes the text unless the file changed on disk meanwhile — then asks Overwrite / Reload / Cancel and returns false.
    /// `then` runs if a save that first asks about the encoding goes through after all (closing does).
    /// The disk work runs off the main thread (⌘S on a share that stopped answering hung the app); the text can't be
    /// edited until it's done, and a second ⌘S meanwhile does nothing.
    @discardableResult
    func save(force: Bool = false, then: (@MainActor () -> Void)? = nil) async -> Bool {
        guard !saving else { return false }
        guard let text = fileText.data(using: encoding) else {
            alert("Can't save as \(encodingName)", "The text contains characters this encoding can't store.")
            return false
        }
        let data = bom ? Data([0xEF, 0xBB, 0xBF]) + text : text
        if !force, !encodingAsked, lossy || encoding != .utf8 {
            askEncoding(then: then)
            return false
        }
        saving = true
        textView.isEditable = false
        defer {
            saving = false
            textView.isEditable = true
        }
        let path = realPath, name = url.lastPathComponent, base = force ? nil : (stamp, digest), hook = willRewriteInPlace, rewrite = rewriteInPlace
        switch await Blocking.run(.userInitiated, { Self.write(data, to: path, name: name, unlessChangedFrom: base, hook: hook, rewrite: rewrite) }) {
        case .changed(let now):
            askOverwrite(now)
            return false
        case .failed(let why, let protected):
            if protected { offerAdminSave(data, reason: why, force: force) } else { alert("Couldn't save “\(name)”", why) }
            return false
        case .written(let stamp, let digest):
            saved(stamp, digest)
            onSaved?(url)
            return true
        }
    }

    enum Written: Sendable {
        case written(Stamp?, SHA256.Digest)
        case changed(Stamp)   // someone else wrote it meanwhile: nothing was
        case failed(String, protected: Bool)   // `protected`: the file or its folder isn't ours to write (admin save)
    }

    /// The write behind `save`, off the main thread: checks the file is still the one opened (unless `base` is nil:
    /// Overwrite), writes it, and says what's on disk then.
    nonisolated private static func write(_ data: Data, to path: String, name: String,
                                          unlessChangedFrom base: (stamp: Stamp?, digest: SHA256.Digest?)?,
                                          hook: (String) -> Void, rewrite: (FileHandle, Data) throws -> Void) -> Written {
        if let base, let now = changed(path, from: base.stamp, base.digest) { return .changed(now) }
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        var st = stat()
        let exists = stat(path, &st) == 0
        do {
            // A rename would split a hard-linked file's links, and make someone else's file ours: those are rewritten in place.
            if fm.isWritableFile(atPath: dir), !exists || st.st_nlink == 1 && st.st_uid == geteuid() {
                sweepSaves(in: dir)
                let tmp = (dir as NSString).appendingPathComponent(".dfm-save-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)")
                // 0600 until the original's mode is copied on: a secret is never briefly world-readable.
                do { try Self.write(data, to: Darwin.open(tmp, O_WRONLY | O_CREAT | O_EXCL, exists ? 0o600 : 0o666)) } catch { unlink(tmp); throw error }
                if exists {
                    // Mode, owner, ACL, xattrs, flags from the original (STAT also copies times, so reset them after),
                    // then its creation date, which copyfile doesn't carry.
                    _ = copyfile(path, tmp, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR | COPYFILE_STAT))
                    utimes(tmp, nil)
                    var crtime = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_CRTIME),
                                          volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
                    setattrlist(tmp, &crtime, &st.st_birthtimespec, MemoryLayout<timespec>.size, 0)
                }
                guard rename(tmp, path) == 0 else {
                    let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    chflags(tmp, 0)   // a locked original's uchg came along, and would keep the temp file
                    unlink(tmp)
                    throw err
                }
            } else {
                // Not through a symlink, and only the file just checked: in a shared folder its owner could swap it
                // for a link to one of ours meanwhile. Never emptied first: written over, then cut to length.
                hook(path)
                let fd = Darwin.open(path, O_WRONLY | O_NOFOLLOW)
                var now = stat()
                if fd >= 0, fstat(fd, &now) != 0 || now.st_dev != st.st_dev || now.st_ino != st.st_ino {
                    Darwin.close(fd)
                    throw JobErrorMessage("“\(name)” was replaced while saving — nothing was written.")
                }
                try Self.write(data, to: fd, writing: rewrite)
            }
        } catch {
            let fm = FileManager.default
            return .failed(error.localizedDescription, protected: !fm.isWritableFile(atPath: path) || !fm.isWritableFile(atPath: dir))
        }
        return .written(Stamp(path), SHA256.hash(data: data))
    }

    /// The same question a server file asks when it changed there (see `upload` in Commands), plus Save As.
    private func askOverwrite(_ now: Stamp?) {
        noticed = now
        guard let app = NSApp.delegate as? AppDelegate else { return }
        let size = ByteCountFormatter.string(fromByteCount: noticed?.size ?? 0, countStyle: .file)
        Task {
            switch await app.choose("“\(url.lastPathComponent)” changed on disk since you opened it",
                                    info: "Something else wrote it (\(size) now). Overwriting replaces those changes with yours. "
                                        + "Reload drops your edits and shows the file as it is now. Save As keeps both. "
                                        + "Cancel keeps your text unsaved here.",
                                    ["Overwrite", "Reload", "Save As…", "Cancel"], default: 3, on: window) {   // ↩: Cancel
            case 0: await save(force: true)
            case 1: await reload()
            case 2:
                let panel = NSSavePanel()
                panel.directoryURL = TempCopies.holds(url)   // a server copy's folder goes when the editor closes
                    ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first : url.deletingLastPathComponent()
                panel.nameFieldStringValue = url.lastPathComponent
                if await panel.beginSheetModal(for: window!) == .OK, let dest = panel.url { await saveAs(dest) }
            default: break
            }
        }
    }

    /// Saving would change bytes the user can't see (damaged UTF-8 becomes U+FFFD) or write Windows-1251, which is
    /// wrong if the file is really UTF-8: asked before the first save until answered Save.
    private func askEncoding(then: (@MainActor () -> Void)?) {
        let a = NSAlert()
        a.messageText = "Save “\(url.lastPathComponent.bidiVisible)” as \(lossy ? "UTF-8" : "Windows-1251")?"
        a.informativeText = lossy
            ? "Some bytes in it aren't valid UTF-8; they show as \u{FFFD} and saving writes \u{FFFD} in their place."
            : "It isn't valid UTF-8, so it was read as Windows-1251 and saving writes Windows-1251. "
                + "If it is really UTF-8, what you typed won't read back right in it."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window!) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            encodingAsked = true
            Task { if await self.save() { then?() } }
        }
    }

    /// Writes the text to `dest`, and from then on the editor edits that file (a server copy stops uploading).
    @discardableResult
    func saveAs(_ dest: URL) async -> Bool {
        url = dest
        onSaved = nil
        remote = nil
        server = nil   // else a revert from that file's server history would find this window and write over `dest`
        noticed = nil
        retitle()
        return await save(force: true)
    }

    /// What saving writes: the symlink's target, so a linked dotfile stays a link instead of being replaced by a copy.
    private var realPath: String { url.resolvingSymlinksInPath().path }

    /// Writes the text over the target as root, in place — so the file keeps its owner, mode and hard links (what you
    /// want for /etc/hosts and friends). See `AdminCommand.writeContents`.
    private func offerAdminSave(_ data: Data, reason: String, force: Bool) {
        let a = NSAlert()
        a.messageText = "“\(url.lastPathComponent.bidiVisible)” is protected"
        a.informativeText = reason + "\nSave it with administrator rights?"
        a.addButton(withTitle: "Save as Administrator")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window!) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            Task { _ = await self.adminSave(data, force: force) }
        }
    }

    /// The file may have changed while the sheet was up: checks again before asking for the password, and root checks
    /// it once more right before writing (a change while the password was asked asks the same way).
    func adminSave(_ data: Data, force: Bool) async -> Bool {
        let path = realPath, stamp = stamp, digest = digest
        let seen = await Blocking.run(.userInitiated) { (changed: force ? nil : Self.changed(path, from: stamp, digest), now: Stamp(path)) }
        if let now = seen.changed {
            askOverwrite(now)
            return false
        }
        let hash = SHA256.hash(data: data)
        let sha256 = hash.map { String(format: "%02x", $0) }.joined()
        let onDisk = seen.now.map { "\($0.ino):\($0.size):\($0.sec).\(String(format: "%09d", $0.nsec))" }
        func command(_ source: AdminCommand.Source) -> String {
            AdminCommand.writeContents(source, sha256: sha256, to: path, stamp: onDisk, length: data.count)
        }
        // In the command when it fits: nothing of the user's to change while macOS asks for the password. Not UTF-8
        // (Windows-1251) or a NUL can't go through argv; those and long texts go through a temp file root checks by hash.
        let cmd: String, tmp: String?
        if let c = String(data: data, encoding: .utf8).flatMap({ $0.contains("\0") ? nil : command(.text($0)) }), c.utf8.count <= AdminCommand.argvLimit {
            (cmd, tmp) = (c, nil)
        } else {
            let t = NSTemporaryDirectory() + "dfm-admin-save-" + UUID().uuidString   // swept a day later (TempCopies)
            guard (try? Self.write(data, to: Darwin.open(t, O_WRONLY | O_CREAT | O_EXCL, 0o600))) != nil else { unlink(t); return false }   // a root file's text: ours only
            (cmd, tmp) = (command(.file(t)), t)
        }
        defer { if let tmp { unlink(tmp) } }
        switch await Self.runAsAdmin(cmd) {
        case .ok:
            saved(await Blocking.run(.userInitiated) { Stamp(path) }, hash)
            return true
        case .cancelled: return false
        case .failed(let msg) where msg.contains(AdminCommand.changedOnDisk):
            askOverwrite(await Blocking.run(.userInitiated) { Stamp(path) })
            return false
        case .failed(let msg):
            alert("Couldn't save as administrator", msg)
            return false
        }
    }

    private func alert(_ message: String, _ info: String) {
        let a = NSAlert()
        a.messageText = message.bidiVisible
        a.informativeText = info.bidiVisible
        a.beginSheetModal(for: window!)
    }

    // MARK: - Window lifecycle

    /// Someone else changed the file: reload if we have nothing to lose, otherwise ask (once per version).
    /// Keep Mine leaves the baseline alone, so the next ⌘S still asks before overwriting.
    /// The stat and the reload read off the main thread (a share that doesn't answer would freeze the app).
    /// One look per file at a time: a file on a share that stopped answering mustn't take a thread per window switch.
    private static let stamps = Coalesced<Stamp?>()

    func windowDidBecomeKey(_ notification: Notification) {
        let url = url
        Task {
            guard let now = await Self.stamps.run(url.path, .userInitiated, { Stamp(url.resolvingSymlinksInPath().path) }), url == self.url, window?.isVisible == true,
                  now != stamp, now != noticed else { return }
            guard dirty else {
                let loaded = await Blocking.run(.userInitiated) { Result { try Self.load(url) } }
                if url == self.url, !dirty { apply(loaded, onDisk: now) }   // not after a Save As or typing meanwhile
                return
            }
            askReload(now)
        }
    }

    private func askReload(_ now: Stamp) {
        noticed = now
        let a = NSAlert()
        a.messageText = "“\(url.lastPathComponent.bidiVisible)” changed on disk"
        a.informativeText = "Reload it and lose your unsaved changes, or keep editing your version?"
        a.addButton(withTitle: "Keep Mine")
        a.addButton(withTitle: "Reload")
        a.beginSheetModal(for: window!) { [weak self] r in
            if r == .alertSecondButtonReturn { Task { await self?.reload() } }
        }
    }

    /// Fails (and says why) when the file is gone, too big, binary or not text any more; the text stays as it was.
    /// Reads off the main thread (a share that stopped answering).
    @discardableResult func reload() async -> Bool {
        let url = url
        let (loaded, now) = await Blocking.run(.userInitiated) { (Result { try Self.load(url) }, Stamp(url.resolvingSymlinksInPath().path)) }
        return url == self.url && apply(loaded, onDisk: now)
    }

    /// `onDisk`: what's there now, for a failure.
    @discardableResult private func apply(_ loaded: Result<Loaded, Error>, onDisk: Stamp?) -> Bool {
        let text: String, enc: String.Encoding, lossy: Bool, stamp: Stamp?, digest: SHA256.Digest
        do { (text, enc, lossy, bom, crlf, stamp, digest) = try loaded.get() } catch {
            noticed = onDisk   // say it once per version, not on every focus
            alert("Couldn't reload “\(url.lastPathComponent)”", error.localizedDescription)
            return false
        }
        if enc != encoding || lossy != self.lossy { encodingAsked = false }   // read differently now: ask again
        encoding = enc
        self.lossy = lossy
        retitle()
        self.stamp = stamp
        self.digest = digest
        let sel = textView.selectedRange()
        textView.string = text
        ruler.invalidate()
        highlight(after: 0)
        textView.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        dirty = false
        return true
    }

    /// Unsaved, and saving would write other bytes than are there: typing and undoing it all isn't a change.
    var changed: Bool {
        guard dirty else { return false }
        guard !unsent, let text = fileText.data(using: encoding) else { return true }
        return SHA256.hash(data: bom ? Data([0xEF, 0xBB, 0xBF]) + text : text) != digest
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard changed else { return true }
        let a = NSAlert()
        a.messageText = "Save changes to “\(url.lastPathComponent.bidiVisible)”?"
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Don't Save")
        a.beginSheetModal(for: sender) { [weak self] r in
            guard let self else { return }
            if r == .alertFirstButtonReturn { Task { if await self.save(then: { sender.close() }) { sender.close() } } }
            if r == .alertThirdButtonReturn { dirty = false; sender.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
        onClose?()
        onClose = nil
    }
}

/// Esc closes the editor (NSTextView would otherwise show word completions).
final class EditorTextView: NSTextView {
    override func cancelOperation(_ sender: Any?) { window?.performClose(nil) }
}
