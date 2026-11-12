import AppKit
import CryptoKit
import DFMCore

/// F4 built-in editor for config files and scripts: plain text, undo, find & replace (⌘F), ⌘S saves, reloads when the
/// file changes on disk. One document: a tab of the editor window (`EditorHost`), its text kept as a draft till it's
/// saved — or a tool's file in a window of its own. The document is one text however many views show it (`DocView`:
/// the editor window's two panes): one storage, one Undo, one draft, one save.
/// Saving asks before overwriting a change made on disk meanwhile; it writes a temp file and renames it over
/// the original, keeping mode, owner, ACL, xattrs, flags and creation date — or rewrites a hard-linked file or
/// someone else's in place. A UTF-8 BOM and CRLF line ends are kept, new lines included.
@MainActor
final class Editor: NSObject, NSTextViewDelegate, NSMenuItemValidation {
    private static var open: [Editor] = []
    /// Names of the files whose unsaved changes quitting would lose: a tool's, and the editor window's while drafts are
    /// off. With drafts on, Quit writes them and asks only about one that couldn't be (`AppDelegate.finishQuit`).
    static var unsaved: [String] { open.filter { $0.changed && !$0.keepsDrafts }.map(\.name) }
    /// The save didn't reach where the file really lives (a server): still unsaved, so closing asks.
    static func markUnsaved(_ url: URL) { open.first { $0.url == url }.map { $0.dirty = true; $0.unsent = true; $0.showState(); $0.host?.changed($0) } }
    /// Its copy's text reached the server: not ↑ any more — still ● if it was typed on since.
    static func markSent(_ url: URL) {
        guard let e = open.first(where: { $0.url == url }), e.unsent else { return }
        e.unsent = false
        e.dirty = e.changed
        e.showState()
        e.host?.changed(e)
    }
    /// The window of the editor whose file `url` is now.
    static func window(for url: URL) -> NSWindow? { open.first { $0.url == url }?.window }
    /// Save As… of the editor whose server copy `url` is (its file is gone from the server).
    static func saveAs(copy url: URL) { open.first { $0.url == url }.map { e in Task { await e.saveAs() } } }
    /// Where a question about `url`'s save goes — a server copy's upload that went on after Save As made it a local
    /// file asks there too — its tab shown first (`revealed`). nil: no editor has it (closed).
    static func asking(about url: URL) -> NSWindow? { open.first { $0.url == url || $0.formerCopy == url }?.revealed() }
    /// The editor of that file already open, if any: a server's by its server, user or root, and path; this Mac's by
    /// its path. One file, one tab.
    private static func opened(_ url: URL, _ server: (target: SFTPTarget, path: String, state: AppDelegate.RemoteEdit)?) -> Editor? {
        if let server { return editing(server.target, server.path) }
        return open.first { $0.url?.standardizedFileURL.path == url.standardizedFileURL.path }
    }
    /// The editor window's document of this Mac's file at `path` — a server file's by its local copy too (a save's
    /// question has that). Not a tool's: that one is its own window's.
    static func document(at path: String) -> Editor? { opened(URL(fileURLWithPath: path), nil).flatMap { $0.host?.tabbed == true ? $0 : nil } }
    /// Still a tab of the editor window (a Compare that waited on a download mustn't bring a closed one back).
    static func isTab(_ e: Editor) -> Bool { open.contains { $0 === e } && e.host?.tabbed == true }
    /// The server's file the shown tab of an editor window edits (Server File History… there).
    static func server(of window: NSWindow?) -> (target: SFTPTarget, path: String)? {
        EditorHost.shown(in: window)?.server.map { ($0.target, $0.path) }
    }
    /// Its own key, on its key bar and F1 over it; Save, Find and the rest are the menu bar's.
    static func keys(of window: NSWindow?) -> [AppDelegate.KeyRow]? {
        EditorHost.shown(in: window).map { e in
            [AppDelegate.KeyRow(section: "Editor", title: e.host.tabbed ? "Back to Panels" : "Close", key: "⎋") { e.escape() }]
                + (e.host.tabbed ? [("Send to Terminal", "cmdline.insert", false), ("Execute in Terminal", "cmdline.insertPaths", true)] : []).compactMap { t, id, run in
                    app()?.commands.first { $0.id == id }?.keys.first.map { k in   // the panels' ⌃↩ / ⌃⇧↩ (`editorTerminalKeys`)
                        AppDelegate.KeyRow(section: "Editor", title: t, key: k.display) { app()?.editorToTerminal(run: run) }
                    }
                }
                + (e.host.comparison?.paused == false ? [("Next Change", "⌥⌘↓", 1), ("Previous Change", "⌥⌘↑", -1)].map { t, k, d in   // `term.pane.down` / `.up` there
                    AppDelegate.KeyRow(section: "Editor", title: t, key: k) { app()?.compareStep(d) }
                } + [("Copy Change to Left", "⌥⇧⌘←", true), ("Copy Change to Right", "⌥⇧⌘→", false)].map { t, k, left in
                    AppDelegate.KeyRow(section: "Editor", title: t, key: k) { e.host.copyChange(toLeft: left) }
                } : [])
        }
    }
    /// The open editor of that server's file, if any.
    static func editing(_ t: SFTPTarget, _ path: String) -> Editor? { open.first { $0.server?.target == t && $0.server?.path == path } }
    /// The same, its user's or root's (a root panel's rename of a file a user's tab has open): the tab that follows it.
    static func tab(onServer t: SFTPTarget, _ path: String) -> Editor? {
        open.first { $0.server.map { ServerRow.key($0.target.asUser) == ServerRow.key(t.asUser) && $0.path == path } == true }
    }
    /// The root write behind Save as Administrator (tests swap it: the real one shows the password dialog).
    static var runAsAdmin: (String) async -> Admin.Outcome = Admin.run
    /// Tests: the app a rename on a server goes through (there's no app delegate there).
    static var app: () -> AppDelegate? = { NSApp.delegate as? AppDelegate }
    /// Stays the same through Save As and launches: its draft's.
    let id: UUID
    /// The window it shows in: the editor window's tab, or a tool's own.
    var host: EditorHost!
    var window: NSWindow? { host?.window }
    /// Its text, however many views show it.
    let storage = NSTextStorage()
    /// Where it shows: a view per pane of the editor window it's in (a tool's window: one). Never empty.
    private(set) var views: [DocView] = []
    /// The view that had the keys last: what the caret, Go to Line, the line commands and the session's caret go by.
    var current: DocView!
    /// The current view's text, and its text with the status line and key bar under it (a tool's Problems and Test
    /// beside): what its tab shows.
    var textView: EditorTextView { current.text }
    var frame: DocFrame { current.frame }
    private var ruler: LineNumberRuler { current.ruler }
    /// Its own: tabs in one window would share the window's, and a reload's reset would empty every tab's.
    private let undo = UndoManager()
    /// Changes only on Save As. nil: an Untitled document (⌘N), on no disk until its Save picks where.
    private(set) var url: URL?
    /// An Untitled's N: one past the highest Untitled open when it was made.
    private let number: Int?
    /// An Untitled's name given on its tab ("deploy.yaml"): its language, and what Save As offers. No file of it.
    private(set) var givenName: String?
    /// The file's name — a server's file's by its path there (its local copy keeps the name it was opened by); an
    /// Untitled's given one, else "Untitled N".
    var name: String {
        if let snapshot { return snapshot.title }
        if let server { return (server.path as NSString).lastPathComponent }
        return url?.lastPathComponent ?? givenName ?? "Untitled \(number ?? 1)"
    }
    /// "host:/path" of a server's file edited through its local copy: the title, not the copy's temp folder.
    private var remote: String?
    var server: (target: SFTPTarget, path: String, state: AppDelegate.RemoteEdit)? {   // its saves go up with `state`
        didSet { if (server == nil) != (oldValue == nil) { showState() } }
    }
    /// A server's file's PROD / ROOT / LOCKED: its tab's, and the window's while it shows.
    var chips: [Chip] = [] { didSet { host?.update(self) } }
    /// The server file's copy this edited before Save As made it a local file: an upload of it still going finds this
    /// tab for its questions. It goes when the tab closes (`onClose`), after its last upload.
    private var formerCopy: URL?
    private(set) var language: Syntax.Language?
    /// View ▸ Indentation's pick; else Tab follows the text's indent (`indent`), read once per text it replaced.
    private var indentPick: LineEdit.Indent?
    /// nil: not read yet; .some(nil): nothing indented then (read again on the next ↩ or Tab).
    private var detected: LineEdit.Indent??
    private var highlightGen = 0
    /// The tokens the text wears now and its length then; and what's been edited since (from where, and how far
    /// from the end): the next tint paints only that and where tokens changed. nil: paint it all once it shows.
    private var tinted: (tokens: [(range: NSRange, token: Syntax.Token)], length: Int)?
    private var editedSince: (from: Int, tail: Int)?
    private var encoding: String.Encoding
    /// Read as UTF-8 with bytes that aren't UTF-8 shown as U+FFFD: saving writes U+FFFD in their place.
    private var lossy = false
    /// The file starts with a UTF-8 BOM / ends every line with CRLF (the text view has plain \n): saving writes them back.
    private var bom = false, crlf = false
    /// Saving ends the text with a newline (crontab ignores a last line without one). On for config files
    /// (see `isConfig`) unless the `editorFinalNewline` setting says always or never; File ▸ toggles it per document.
    var finalNewline: Bool { didSet { host?.update(self); host?.changed(self) } }
    static var finalNewlineSetting: () -> Bool? = { UserDefaults.standard.object(forKey: "editorFinalNewline") as? Bool }
    /// Tests: runs between checking the file and opening it for an in-place rewrite (off the main thread). This
    /// document's own: tests run side by side, and a save no longer holds the main thread while it writes.
    var willRewriteInPlace: @Sendable (String) -> Void = { _ in }
    /// Tests: writes the text into what a save opened — its temp file, or the file itself in place (to fail it midway).
    var writeText: @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    /// Tests: runs with the temp file's path right before it's renamed over the file (to fail the rename); a rename of
    /// its file, with the new path, between the look there and the rename.
    var willRename: @Sendable (String) -> Void = { _ in }
    /// A tool's file: Kermo reads it where it is, so Save As… is off.
    private var fixedPlace = false
    /// A lossy or Windows-1251 file was asked about before its first save.
    private var encodingAsked = false
    /// The file as we last loaded or saved it; a save over anything else asks first.
    private var stamp: Stamp?
    private var digest: Data?
    /// The on-disk version the user was already asked about (sheets give the key back, which would ask again).
    private(set) var noticed: Stamp?
    private var dirty = false { didSet { if dirty != oldValue { showState() } } }
    private var unsent = false   // saved here, but not where it lives (a server): the same bytes still count as a change
    private(set) var saving = false   // a save's disk work is under way (the text can't be edited meanwhile), or a rename's
    /// Has changes its file doesn't (a dot on its tab and the window's close button).
    var isEdited: Bool { dirty }

    /// Called after each successful save (remote files use it to upload the copy back).
    var onSaved: (@MainActor (URL) -> Void)?
    /// Called once its tab closes (or the file couldn't be opened) — not when the editor window only hides.
    var onClose: (@MainActor () -> Void)?
    /// Called as the text changes (a tool's Problems check it).
    var edited: (@MainActor () -> Void)?

    /// Reads the file off the main thread (up to 32 MB, or a share that doesn't answer), then opens it in a tab of the
    /// editor window. `note`: said in its status line once it's open (`flash`).
    static func open(_ url: URL, remote: String? = nil, server: (target: SFTPTarget, path: String, state: AppDelegate.RemoteEdit)? = nil,
                     note: String? = nil, onSaved: (@MainActor (URL) -> Void)? = nil, onClose: (@MainActor () -> Void)? = nil) {
        if let existing = opened(url, server) { onClose?(); existing.revealed(); return }
        Task {
            let loaded = await Blocking.run(.userInitiated) { Result { try load(url) } }
            // Opened meanwhile (↩ twice during a slow read or download): one tab per file, the other copy goes.
            if let existing = opened(url, server) { onClose?(); existing.revealed(); return }
            do {
                let e = try Editor(url, remote: remote, loaded: loaded.get())
                e.onSaved = onSaved
                e.onClose = onClose
                e.server = server
                if let t = server?.target { e.chips = Chip.of(t) }
                open.append(e)
                EditorHost.tabs.add(e)
                if let note { e.flash(note) }
            } catch {
                onClose?()
                let a = NSAlert(error: error)
                a.messageText = a.messageText.bidiVisible
                if let w = NSApp.mainWindow ?? NSApp.keyWindow { a.beginSheetModal(for: w) { _ in } } else { _ = AppDelegate.modal(a) }   // no editor to put it on yet
            }
        }
    }

    /// `url` with `side` beside its text (a tool's Problems and Test), in a window of its own, at once: `text` for a file
    /// not on disk yet, which its first save writes — over nothing that appeared there meanwhile without asking. Already
    /// open so: that window.
    static func open(_ url: URL, text: String?, beside side: NSView, onSaved: @escaping @MainActor (URL) -> Void) throws -> Editor {
        if let e = open.first(where: { $0.url == url }) {
            e.revealed()
            return e
        }
        let loaded = try text.map { t -> Loaded in (t, .utf8, false, false, false, nil, sha(Data(t.utf8))) } ?? load(url)
        let e = Editor(url, remote: nil, loaded: loaded, side: side)
        e.onSaved = onSaved
        e.fixedPlace = true
        open.append(e)
        EditorHost(single: e).showWindow(nil)
        e.window?.listInWindowsMenu()
        return e
    }

    /// New Editor Document (⌘N): an empty “Untitled N” — N one past the highest open — in UTF-8 with LF, in a new tab,
    /// the text in focus. Nothing of it is in a file until its Save picks where; its draft is kept meanwhile.
    @discardableResult
    static func untitled() -> Editor {
        let e = Editor(nil, number: (open.compactMap { $0.url == nil ? $0.number : nil }.max() ?? 0) + 1, remote: nil, loaded: ("", .utf8, false, false, false, nil, sha(Data())))
        open.append(e)
        EditorHost.tabs.add(e)
        return e
    }

    /// A read-only copy to compare with (`EditorHost.compare` places it): `loaded` as a file was read, `file` its name
    /// for its colors. Not a document: no file, draft, save, rename or session, and no lookup finds it.
    static func snapshot(_ loaded: Loaded, file: String?, title: String, place: String, source: AppDelegate.DiffSide? = nil,
                         from: (target: SFTPTarget?, path: String)? = nil) -> Editor {
        let e = Editor(nil, remote: nil, loaded: loaded)
        e.snapshot = (title, place, source)
        e.snapshotFrom = from ?? source.map { ($0.server, $0.path) }
        e.language = file.flatMap { Syntax.language(forFileName: $0, firstLine: String(loaded.0.prefix(200).split(separator: "\n").first ?? "")) }
        e.editable(false)
        open.append(e)   // Wrap, text size and Show Invisibles reach it; with no file and no server, nothing else does
        return e
    }

    /// A read-only copy (`snapshot`): what its tab and title say, and the file Edit turns it into (nil: not a file —
    /// a kept version, the clipboard, or a file whose document is the other side).
    private(set) var snapshot: (title: String, place: String, source: AppDelegate.DiffSide?)?
    /// A read-only copy's file — its server's (nil: this Mac's) and path there — whatever it is a version of: where
    /// Send / Execute in Terminal go from it. nil: not a file's (the clipboard).
    private(set) var snapshotFrom: (target: SFTPTarget?, path: String)?

    /// Edit, in a read-only copy of a file: that file's document now, in its place — read again as F4 reads it, a
    /// server's with all of F4's rules — and its comparison goes on. Open in another tab already: that tab takes its place.
    func edit() {
        guard let copy = snapshot, let s = copy.source else { return NSSound.beep() }
        if let other = s.server.flatMap({ Self.editing($0, s.path) }) ?? (s.server == nil ? Self.opened(URL(fileURLWithPath: s.path), nil) : nil) {
            guard other.host?.tabbed == true else { other.revealed(); return flash("“\(other.name)” is open in a tool's editor: edit it there") }
            return host.replace(self, with: other)
        }
        snapshot = nil
        finalNewline = Self.finalNewlineSetting() ?? Self.isConfig(s.path)
        lastSelection = (textView.selectedRange().location, frame.scroll.contentView.bounds.origin.y)
        if let t = s.server {
            remote = SavedServer.title(t, s.path)
            server = (t, s.path, AppDelegate.RemoteEdit(baseline: .nothing))   // the download sets what the saves check against
            chips = Chip.of(t)
            cover = .parked
            connect()
        } else {
            let u = URL(fileURLWithPath: s.path)
            url = u
            cover = .loading
            Task {
                switch await Blocking.run(.userInitiated, { Result { try Self.load(u) } }) {
                case .success(let l): fill(l.0, stamp: l.5, digest: l.6, apply: l)
                case .failure(let error):   // gone or changed into something else meanwhile: still the copy it was
                    (url, snapshot, cover) = (nil, copy, nil)
                    flash(error.localizedDescription)
                    if host.comparison?.shows(self) != true { host.remove(self) }   // its comparison ended meanwhile: a copy goes with it
                }
            }
        }
        host.changed(self)   // a document now: in the session
    }

    /// In a window of its own, not shown (tests).
    convenience init(_ url: URL, remote: String? = nil) throws {
        try self.init(url, remote: remote, loaded: Self.load(url))
        EditorHost(single: self)
    }

    private init(_ url: URL?, number: Int? = nil, id: UUID = UUID(), remote: String?, loaded: Loaded, side: NSView? = nil) {
        let (text, encoding, lossy, bom, crlf, stamp, digest) = loaded
        self.id = id
        self.url = url
        self.number = number
        self.remote = remote
        self.encoding = encoding
        self.lossy = lossy
        self.bom = bom
        self.crlf = crlf
        // A server copy goes by its path there ("host:/etc/x"), not the temp folder's. An Untitled has nothing to judge by.
        finalNewline = Self.finalNewlineSetting()
            ?? url.map { u in Self.isConfig(remote.flatMap { r in r.range(of: ":/").map { String(r[r.index(after: $0.lowerBound)...]) } } ?? u.path) } ?? false
        self.stamp = stamp
        self.digest = digest
        super.init()
        current = DocView(self, side: side)
        views = [current]
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = text
        NotificationCenter.default.addObserver(self, selector: #selector(storageEdited), name: NSTextStorage.didProcessEditingNotification, object: storage)
        language = url.flatMap { Syntax.language(forFileName: $0.lastPathComponent, firstLine: String(text.prefix(200).split(separator: "\n").first ?? "")) }
        applyFont()
        applyView()
        showState()   // tinted once it shows (`shown`): twenty tabs restored aren't twenty tints at once
    }

    /// What the window says while its tab shows: the file's name and where it is ("web-01 · /etc/nginx"). A locked
    /// server's draft: its name and server only, till it's unlocked.
    var heading: (title: String, subtitle: String) {
        if let snapshot { return (snapshot.title.bidiVisible, ["Read-only", snapshot.place].filter { !$0.isEmpty }.joined(separator: " · ")) }
        let (host, path): (String?, String) = if let server { (SavedServer.name(for: server.target), server.path) }
            else if let r = remote, let c = r.range(of: ":/") { (String(r[..<c.lowerBound]), String(r[r.index(after: c.lowerBound)...])) }   // "host:/path"
            else { (nil, url?.path ?? "") }
        if cover == .locked || cover == .loading && server != nil { return (name.bidiVisible, host ?? "") }   // locked, or not known yet
        return (url == nil ? name : (path as NSString).lastPathComponent.bidiVisible, DocFrame.place((path as NSString).deletingLastPathComponent, host: host))
    }
    /// The window's proxy icon: this Mac's file, not a server copy's temp file.
    var representedURL: URL? { remote == nil && cover == nil ? url : nil }
    /// Its tab's tooltip: the whole path, its server's name before a server's.
    var tip: String {
        let h = heading
        return h.subtitle.isEmpty ? h.title : h.subtitle + " · " + h.title
    }
    /// What tells it from a tab of the same name: its server, else its folder's name.
    var whereShort: String {
        if let snapshot { return snapshot.place }
        if let server { return SavedServer.name(for: server.target) }
        return (url.map { (($0.path as NSString).deletingLastPathComponent as NSString).lastPathComponent }) ?? ""
    }

    /// A revert put `data` on the server, which now has `attrs`: shown here, and the next save checks against that —
    /// unless this editor has changes of its own, which stay (their save then asks: the server's file changed).
    /// False if not shown — a parked tab has no copy: it shows the server's file once it's opened.
    func reverted(to data: Data, attrs: SFTPClient.Attrs) async -> Bool {
        guard !changed, cover == nil, let server, let url else { return false }
        guard await Blocking.run(.userInitiated, { (try? data.write(to: url)) != nil }) else { return false }
        server.state.baseline = attrs
        return await reload()
    }

    /// Says something in its status line for a few seconds (a server save's "no history: …"): the panels' status line
    /// is behind this window.
    static func flash(_ url: URL, _ text: String) { open.first { $0.url == url || $0.formerCopy == url }?.flash(text) }
    func flash(_ text: String) { views.forEach { $0.frame.flash(text) } }

    /// Its tab, shown in the window, before a question about it: out of the Dock, key, in front — a sheet on a window
    /// out of sight waits unseen (and the save behind it with it).
    @discardableResult func revealed() -> NSWindow { host.reveal(self) }

    /// What saving writes besides the text: two files of the same text may still differ in these (Compare says so).
    var format: (encoding: String.Encoding, bom: Bool, crlf: Bool) { (encoding, bom, crlf) }

    private var encodingName: String { encoding == .utf8 ? lossy ? "UTF-8 (damaged)" : "UTF-8" : "Windows-1251" }

    typealias Loaded = (String, String.Encoding, lossy: Bool, bom: Bool, crlf: Bool, Stamp?, Data)

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

    /// A file's SHA-256, as a save compares it and the session keeps it.
    nonisolated static func sha(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// UTF-8; UTF-8 with a few damaged bytes (lossy, see `TextFormat.mostlyUTF8`); else Windows-1251.
    nonisolated static func load(_ url: URL) throws -> Loaded {
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
        let digest = sha(data)
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        let body = bom ? data.dropFirst(3) : data
        let crlf = isCRLF(data)
        func lf(_ s: String) -> String { crlf ? s.replacingOccurrences(of: "\r\n", with: "\n") : s }
        if let s = String(data: body, encoding: .utf8) { return (lf(s), .utf8, false, bom, crlf, stamp, digest) }
        if TextFormat.mostlyUTF8(body) { return (lf(String(decoding: body, as: UTF8.self)), .utf8, true, bom, crlf, stamp, digest) }
        if let s = String(data: data, encoding: .windowsCP1251) { return (lf(s), .windowsCP1251, false, false, crlf, stamp, digest) }
        throw JobErrorMessage("Can't decode “\(url.lastPathComponent)” as text.")
    }

    /// Which file is at a path and its size and mtime (through symlinks); and its permissions, which a change of only
    /// them doesn't count as (a file deleted meanwhile comes back with them).
    struct Stamp: Equatable, Sendable {
        let dev: dev_t, ino: ino_t, size: off_t, sec: Int, nsec: Int, mode: mode_t
        init(dev: dev_t, ino: ino_t, size: off_t, sec: Int, nsec: Int, mode: mode_t) { (self.dev, self.ino, self.size, self.sec, self.nsec, self.mode) = (dev, ino, size, sec, nsec, mode) }
        init?(_ path: String) {
            var s = stat()
            guard stat(path, &s) == 0 else { return nil }
            (dev, ino, size, sec, nsec, mode) = (s.st_dev, s.st_ino, s.st_size, s.st_mtimespec.tv_sec, s.st_mtimespec.tv_nsec, s.st_mode & 0o777)
        }
        static func == (a: Stamp, b: Stamp) -> Bool { (a.dev, a.ino, a.size, a.sec, a.nsec) == (b.dev, b.ino, b.size, b.sec, b.nsec) }
    }

    /// What's on disk at `path` if someone else replaced or wrote it since `stamp` / `digest` (another file, size,
    /// mtime or bytes); nil if it's still ours. A deleted file isn't a conflict — saving just recreates it.
    /// Reads the file: off the main thread.
    nonisolated private static func changed(_ path: String, from stamp: Stamp?, _ digest: Data?) -> Stamp? {
        guard let now = Stamp(path) else { return nil }
        return now != stamp || (try? Data(contentsOf: URL(fileURLWithPath: path))).map(sha) != digest ? now : nil
    }

    private func saved(_ stamp: Stamp?, _ digest: Data) {
        unsent = false   // first: `dirty`'s change redraws the tab, its ↑ must be gone by then
        dirty = false
        if lossy { lossy = false; showState() }   // the damaged bytes are U+FFFD now: clean UTF-8
        self.stamp = stamp
        self.digest = digest
        notice = nil
        host?.changed(self, now: true)   // a crash right after: the draft goes, it's in the file
    }

    func textDidChange(_ notification: Notification) {
        dirty = true
        highlight(after: 0.3)
        edited?()
        host?.changed(self)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    @objc private func storageEdited(_ n: Notification) {
        guard let s = n.object as? NSTextStorage, s.editedMask.contains(.editedCharacters) else { return }
        edits += 1   // typed, pasted, reloaded: the draft's text is behind
        let r = s.editedRange, tail = s.length - NSMaxRange(r)
        editedSince = (min(editedSince?.from ?? r.location, r.location), min(editedSince?.tail ?? tail, tail))
    }

    /// Re-tints the text in the background once typing pauses (what changed only); skips texts over 2 MB, and a tab
    /// that doesn't show (all of it once it does).
    private func highlight(after delay: TimeInterval) {
        guard let lang = language else { return }
        guard onScreen else { tinted = nil; return }
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
    @objc func saveDocumentAs(_ sender: Any?) { Task { await saveAs() } }
    @objc func toggleFinalNewline(_ sender: Any?) { finalNewline.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if snapshot != nil, [#selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(toggleFinalNewline(_:))].contains(item.action) { return false }
        if item.action == #selector(toggleFinalNewline(_:)) { item.state = finalNewline ? .on : .off }
        if item.action == #selector(saveDocumentAs(_:)) { return canSaveAs && window?.attachedSheet == nil }   // a second ⇧⌘S: no second panel
        return true
    }

    /// Not a tool's file, nor while a save runs.
    private var canSaveAs: Bool { !fixedPlace && !saving && cover == nil && snapshot == nil }

    /// What saving writes of `text`: in its encoding, with the final newline if that's on, CRLF line ends and the BOM
    /// if the file had them; nil if the encoding can't hold it.
    private func fileData(of text: String) -> Data? {
        var text = text
        if finalNewline, let last = text.last, !last.isNewline { text += "\n" }
        // A pasted CRLF stays one line end.
        if crlf { text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") }
        return text.data(using: encoding).map { bom ? Data([0xEF, 0xBB, 0xBF]) + $0 : $0 }
    }

    /// Writes all of `data` to `fd`, makes it reach the disk itself (plain fsync where F_FULLFSYNC isn't supported) and closes it.
    /// From the start over what's there, and only then cut to length: a file written into in place is never shorter
    /// than the old text or the new one, even if the write stops midway (a full disk, a crash).
    nonisolated private static func write(_ data: Data, to fd: Int32, writing: (FileHandle, Data) throws -> Void) throws {
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try writing(h, data)
        if ftruncate(fd, off_t(data.count)) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Not on the disk (EIO): it never takes the original's place. A file system that can't sync like that: plain
        // fsync, or as it is where it can't sync at all.
        let unsupported: Set<Int32> = [ENOTSUP, ENOTTY, EINVAL, ENOSYS]
        if fcntl(fd, F_FULLFSYNC) != 0, !unsupported.contains(errno) || fsync(fd) != 0 && !unsupported.contains(errno) {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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
        if snapshot != nil { NSSound.beep(); return false }   // a read-only copy: nowhere to write it
        if cover != nil { connect(); return false }   // a parked or locked tab: opened, or unlocked, first
        host?.changed(self, now: true)   // a crash during the save: the draft has what was typed till now
        guard let url, let path = realPath else { return await saveAs() }   // an Untitled: where to, first
        // A server draft back from the last launch has no local copy yet: its folder now, ours only.
        if server != nil { mkdir(url.deletingLastPathComponent().path, 0o700) }
        guard !saving, let data = fileData(asking: !force, retry: { [weak self] in if await self?.save() == true { then?() } }) else { return false }
        saving = true
        editable(false)
        defer {
            saving = false
            editable(true)
        }
        let name = url.lastPathComponent, base = force ? nil : (stamp, digest), hook = willRewriteInPlace, text = writeText, renaming = willRename
        let mode = stamp?.mode ?? (server != nil ? 0o600 : 0o666)   // deleted meanwhile: it comes back as it was, not wider
        switch await Blocking.run(.userInitiated, { Self.write(data, to: path, name: name, unlessChangedFrom: base, newMode: mode, hook: hook, writing: text, willRename: renaming) }) {
        case .changed(let now):
            askOverwrite(now)
            return false
        case .failed(let why, let protected):
            if protected { offerAdminSave(data, reason: why, force: force) } else { alert("Couldn't save “\(name)”", why) }
            return false
        case .written(let stamp, let digest, let note):
            saved(stamp, digest)
            onSaved?(url)
            if let note { flash(note) }
            return true
        }
    }

    enum Written: Sendable {
        case written(Stamp?, Data, note: String? = nil)   // `note`: said after (written in place without a copy)
        case changed(Stamp)   // someone else wrote it meanwhile: nothing was
        case failed(String, protected: Bool)   // `protected`: the file or its folder isn't ours to write (admin save)
    }

    /// The write behind `save`, off the main thread: checks the file is still the one opened (unless `base` is nil:
    /// Overwrite), writes it, and says what's on disk then. `newMode`: a file that isn't there yet gets it (less the
    /// umask). `inPlace` false (Save As): never written into — the file is either as it was or ours whole.
    nonisolated private static func write(_ data: Data, to path: String, name: String,
                                          unlessChangedFrom base: (stamp: Stamp?, digest: Data?)?, newMode: mode_t = 0o666, inPlace: Bool = true,
                                          hook: (String) -> Void, writing: (FileHandle, Data) throws -> Void, willRename: (String) -> Void) -> Written {
        if let base, let now = changed(path, from: base.stamp, base.digest) { return .changed(now) }
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        var st = stat(), entry = stat(), note: String?
        // Nothing there now (not even a link): a file that appears there meanwhile isn't replaced.
        let exists = stat(path, &st) == 0, vacant = lstat(path, &entry) != 0
        do {
            // A rename would split a hard-linked file's links, and make someone else's file ours: a save rewrites those in place.
            if !inPlace || fm.isWritableFile(atPath: dir) && (!exists || st.st_nlink == 1 && st.st_uid == geteuid()) {
                sweepSaves(in: dir)
                let tmp = (dir as NSString).appendingPathComponent(".dfm-save-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)")
                // 0600 until the original's mode is copied on: a secret is never briefly world-readable.
                do { try Self.write(data, to: Darwin.open(tmp, O_WRONLY | O_CREAT | O_EXCL, exists ? 0o600 : newMode), writing: writing) } catch { unlink(tmp); throw error }
                if exists {
                    // Mode, owner, ACL, xattrs, flags from the original (STAT also copies times, so reset them after),
                    // then its creation date, which copyfile doesn't carry.
                    _ = copyfile(path, tmp, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR | COPYFILE_STAT))
                    utimes(tmp, nil)
                    var crtime = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_CRTIME),
                                          volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
                    setattrlist(tmp, &crtime, &st.st_birthtimespec, MemoryLayout<timespec>.size, 0)
                }
                willRename(tmp)
                var failed = vacant ? renamex_np(tmp, path, UInt32(RENAME_EXCL)) != 0 : Darwin.rename(tmp, path) != 0
                if failed, vacant, errno == ENOTSUP || errno == EINVAL {   // a disk that can't rename only where nothing is
                    // ponytail: looked at once more, then renamed — a file appearing in between is replaced; link() + unlink
                    // would close that where hard links work (not FAT, not every share).
                    failed = lstat(path, &entry) == 0 ? { errno = EEXIST; return true }() : Darwin.rename(tmp, path) != 0
                }
                if failed {
                    let err: Error = vacant && errno == EEXIST ? JobErrorMessage("“\(name)” appeared there meanwhile — nothing was written.")
                        : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    chflags(tmp, 0)   // a locked original's uchg came along, and would keep the temp file
                    unlink(tmp)
                    throw err
                }
                FileInfo.syncFolder(dir)   // else after a power cut the folder may name the old file again
            } else {
                // Not through a symlink, and only the file just checked: in a shared folder its owner could swap it
                // for a link to one of ours meanwhile. Its old text kept first (`rewriteInPlace`).
                hook(path)
                let fd = Darwin.open(path, O_RDWR | O_NOFOLLOW)
                var now = stat()
                if fd >= 0, fstat(fd, &now) != 0 || now.st_dev != st.st_dev || now.st_ino != st.st_ino {
                    Darwin.close(fd)
                    throw JobErrorMessage("“\(name)” was replaced while saving — nothing was written.")
                }
                // Read whole first: not a FIFO swapped in (it would never end), nor a file grown past what the editor opens.
                if fd >= 0, now.st_mode & S_IFMT != S_IFREG || now.st_size > 32 << 20 {
                    Darwin.close(fd)
                    throw JobErrorMessage("“\(name)” isn't a text file of up to 32 MB any more — nothing was written.")
                }
                note = try Self.rewriteInPlace(data, fd, path: path, writing: writing)
            }
        } catch {
            let fm = FileManager.default
            return .failed(error.localizedDescription, protected: !fm.isWritableFile(atPath: path) || !fm.isWritableFile(atPath: dir))
        }
        return .written(Stamp(path), sha(data), note: note)
    }

    /// Where an in-place save keeps the text a file had until its new one is whole: ours only, out of Spotlight and
    /// Time Machine. A crash midway leaves the copy here; the next launch names it (`cutShortSaves`).
    nonisolated static var keptDir: String { Config.path("saves.noindex") }

    /// Writes `data` into the file `fd` is open on (read and write) — a hard-linked file, someone else's: its links and
    /// owner stay. Its old text goes first into a copy of ours, on the disk itself; then the new text over it, cut to
    /// length. A failure on the way puts the old text back and says whether it could; the copy goes once the file is
    /// whole again. Returns why there was no copy (written anyway), or nil. A full disk writes nothing: the write and
    /// its put-back could stop midway there too.
    nonisolated static func rewriteInPlace(_ data: Data, _ fd: Int32, path: String, writing: (FileHandle, Data) throws -> Void,
                                           keep: (Data, String) throws -> String = keepCopy) throws -> String? {
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        let old = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        var kept: String?, uncopied: String?
        do { kept = try keep(old, path) } catch where [ENOSPC, EDQUOT].contains(EditorHost.posix(error)) {
            throw JobErrorMessage("No room to keep a copy of its old text first (the disk is full), so nothing was written. Free some space, or use Save As… to another disk.")
        } catch { uncopied = error.localizedDescription }
        do {
            lseek(fd, 0, SEEK_SET)
            try write(data, to: dup(fd), writing: writing)   // never emptied first: written over, then cut to length
        } catch {
            lseek(fd, 0, SEEK_SET)   // the old text back the same way, its sync as strict
            let back = (try? write(old, to: dup(fd), writing: { try $0.write(contentsOf: $1) })) != nil
            if back, let kept { unlink(kept) }
            let said = back ? "The file is as it was before this save."
                : "The file may be cut short. " + (kept.map { "Its text before this save is kept in \(($0 as NSString).abbreviatingWithTildeInPath)." } ?? "Its text before this save couldn't be kept.")
            throw JobErrorMessage(error.localizedDescription + ". " + said)
        }
        if let kept { unlink(kept) }
        return uncopied.map { "Saved in place without a copy of its old text first (\($0))" }
    }

    /// `old` (the text of the file at `original`) in a new file of `keptDir`, on the disk itself, the folder too: its
    /// path. Named by the time and the file's name — no text in it; the file's own path in an attribute, for the launch's
    /// message.
    nonisolated static func keepCopy(_ old: Data, of original: String) throws -> String {
        let dir = keptDir
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = URL(fileURLWithPath: dir), v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? url.setResourceValues(v)
        let f = DateFormatter()
        (f.locale, f.dateFormat) = (Locale(identifier: "en_US_POSIX"), "yyyy-MM-dd_HH-mm-ss")   // fixed width: `cutShortSaves` reads past it
        let name = String(decoding: (original as NSString).lastPathComponent.utf8.prefix(200), as: UTF8.self)
        let path = dir + "/" + f.string(from: Date()) + "-" + UUID().uuidString.prefix(8) + "-" + name
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do { try write(old, to: fd, writing: { try $0.write(contentsOf: $1) }) } catch {
            unlink(path)
            throw error
        }
        _ = original.withCString { setxattr(path, keptFrom, $0, strlen($0), 0, XATTR_NOFOLLOW) }
        FileInfo.syncFolder(dir)   // else after a power cut the copy may not be there
        return path
    }
    nonisolated private static let keptFrom = "com.kermo.original"

    /// A copy's file: the path its attribute says, else the name after "<time>-<id>-".
    nonisolated static func keptOriginal(_ copy: String) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = getxattr(copy, keptFrom, &buf, buf.count - 1, 0, XATTR_NOFOLLOW)
        return n > 0 ? String(cString: buf) : String((copy as NSString).lastPathComponent.dropFirst(29))
    }

    /// Copies of old texts an in-place save cut short left (a crash, the power, a put-back that failed), a minute old
    /// or more: a save running now in another Kermo has a newer one.
    static func cutShortSaves() -> [String] {
        let fm = FileManager.default, dir = keptDir
        return ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().filter { name in
            guard !name.hasPrefix("."), name.count > 29, let a = try? fm.attributesOfItem(atPath: dir + "/" + name) else { return false }   // not Finder's .DS_Store
            return a[.type] as? FileAttributeType == .typeRegular && (a[.modificationDate] as? Date).map { $0 < Date().addingTimeInterval(-60) } ?? false
        }.map { dir + "/" + $0 }
    }

    /// The same question a server file asks when it changed there (see `upload` in Commands), plus Save As.
    private func askOverwrite(_ now: Stamp?) {
        noticed = now
        guard let app = NSApp.delegate as? AppDelegate else { return }
        var c = Confirm("“\(name)” changed on disk since you opened it", action: "Overwrite")
        c.note = "Something else wrote it" + (now.map { ": " + Self.when($0) } ?? "") + ". Overwriting replaces those changes with yours. "
            + "Reload drops your edits and shows the file as it is now. " + (fixedPlace ? "" : "Save As keeps both. ") + "Cancel keeps your text unsaved here."
        (c.others, c.irreversible) = (fixedPlace ? ["Reload"] : ["Reload", "Save As…"], true)   // ↩: Cancel
        Task {
            switch await app.confirm(c, on: revealed()) {
            case 0: await save(force: true)
            case 1: await reload()
            case 2 where !fixedPlace: await saveAs()
            default: break
            }
        }
    }

    /// "Today 13:33, 2 KB now": when it was written, as the panel says dates, and its size.
    static func when(_ s: Stamp) -> String {
        DateColumn().text(Date(timeIntervalSince1970: TimeInterval(s.sec))) + ", \(ByteCountFormatter.short(Int64(s.size))) now"
    }

    /// The bytes saving writes: the text in its encoding, the BOM if the file had one. nil when the encoding can't store
    /// the text (said so), or when this first asks about the encoding — `retry` runs once that's answered Save. Not
    /// `asking`: Overwrite, after a save that asked.
    private func fileData(asking: Bool = true, retry: @escaping @MainActor () async -> Void) -> Data? {
        guard let data = fileData(of: textView.string) else {
            alert("Can't save as \(encodingName)", "The text contains characters this encoding can't store.")
            return nil
        }
        if asking, !encodingAsked, lossy || encoding != .utf8 {
            askEncoding(then: retry)
            return nil
        }
        return data
    }

    /// Saving would change bytes the user can't see (damaged UTF-8 becomes U+FFFD) or write Windows-1251, which is
    /// wrong if the file is really UTF-8: asked before the first save (Save As too) until answered Save.
    private func askEncoding(then retry: @escaping @MainActor () async -> Void) {
        let a = NSAlert()
        a.messageText = "Save “\(name.bidiVisible)” as \(lossy ? "UTF-8" : "Windows-1251")?"
        a.informativeText = lossy
            ? "Some bytes in it aren't valid UTF-8; they show as \u{FFFD} and saving writes \u{FFFD} in their place."
            : "It isn't valid UTF-8, so it was read as Windows-1251 and saving writes Windows-1251. "
                + "If it is really UTF-8, what you typed won't read back right in it."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: revealed()) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            encodingAsked = true
            Task { await retry() }
        }
    }

    /// File ▸ Save As… (and the conflict's Save As…, an Untitled's Save): where to, in the save panel — a server file's
    /// copy from Downloads (its own folder goes when the editor closes), a file from its folder, an Untitled from the
    /// active panel's folder on this Mac (else Documents) — then `saveAs(_:)`.
    @discardableResult
    func saveAs() async -> Bool {
        guard canSaveAs else { return false }
        let panel = NSSavePanel(), fm = FileManager.default
        panel.directoryURL = if let url { TempCopies.holds(url) ? fm.urls(for: .downloadsDirectory, in: .userDomainMask).first : url.deletingLastPathComponent() }
            else { (NSApp.delegate as? AppDelegate)?.activePanel.flatMap(\.localFolder) ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first }
        panel.nameFieldStringValue = name
        guard await panel.beginSheetModal(for: revealed()) == .OK, let dest = panel.url else { return false }
        return await saveAs(dest)
    }

    /// Writes the text to `dest` — a new file, or the one the save panel asked to replace — and only once it's there
    /// does this editor edit `dest`: a failure, or Cancel on a question, leaves it as it was (a server's file still
    /// saves there, checked against the same version). `dest` is this file: a plain Save. Open in another editor
    /// window: nothing is written, that window comes forward and says why — one file, one window.
    @discardableResult
    func saveAs(_ dest: URL) async -> Bool {
        guard !saving else { return false }
        // What the panel saw there, off the main thread: the one file it asked about replacing, as it was then, or
        // nothing. A file that appears, changes or is swapped for a link meanwhile isn't written over.
        let seen = await Blocking.run(.userInitiated) { () -> (stamp: Stamp?, digest: Data?) in
            let path = dest.resolvingSymlinksInPath().path, stamp = Stamp(path)
            // Not a FIFO's or a device's bytes (one waits for good, one never ends): Save As refuses those anyway.
            return (stamp, stamp == nil || FileInfo.notRegular(path) != nil ? nil : (try? Data(contentsOf: URL(fileURLWithPath: path))).map(Self.sha))
        }
        return await saveAs(dest, base: seen)
    }

    private func saveAs(_ dest: URL, base: (stamp: Stamp?, digest: Data?)) async -> Bool {
        guard !saving, snapshot == nil else { return false }
        // This file (a plain Save) or another editor window's (nothing written), through links — every time, the
        // encoding question's Save too (F4 on it meanwhile). Off the main thread: a share that stopped answering.
        let others = Self.open.filter { $0 !== self }, urls = others.map(\.url), mine = url
        let (own, other) = await Blocking.run(.userInitiated) { () -> (Bool, Int?) in
            func real(_ u: URL?) -> String? { u?.resolvingSymlinksInPath().path }
            let d = real(dest)
            return (real(mine) == d, urls.firstIndex { real($0) == d })
        }
        if own { return await save() }
        if let other {
            others[other].alert("“\(others[other].name)” is open in this window",
                                "Save As from “\(name)” wrote nothing: one file is edited in one window. Save your text here, or close this window first.")
            return false
        }
        guard !saving, let data = fileData(retry: { [weak self] in _ = await self?.saveAs(dest, base: base) }) else { return false }
        saving = true
        editable(false)
        defer {
            saving = false
            editable(true)
        }
        // The new file's mode, no wider than where the text came from: a server's file's mode there (unknown: owner
        // only), this Mac's file's (read with the write, off the main thread); an Untitled's, the umask's.
        let serverMode = server.map { mode_t(($0.state.baseline.mode ?? 0o600) & 0o777) }, text = writeText, renaming = willRename
        let written = await Blocking.run(.userInitiated) { () -> Written in
            var st = stat()
            let mode = serverMode ?? mine.map { stat($0.resolvingSymlinksInPath().path, &st) == 0 ? st.st_mode & 0o777 : 0o600 } ?? 0o666
            return Self.writeAs(data, to: dest.path, base: base, mode: mode, writing: text, willRename: renaming)
        }
        let name = dest.lastPathComponent
        switch written {
        case .changed:
            alert("“\(name)” " + (base.stamp == nil ? "appeared there meanwhile" : "changed after you chose to replace it"), "Nothing was written. Save As again to replace it.")
            return false
        case .failed(let why, _):
            alert("Couldn't save “\(name)”", why)
            return false
        case .written(let stamp, let digest, _):
            if server != nil { formerCopy = url }
            url = dest
            (remote, onSaved, noticed, givenName) = (nil, nil, nil, nil)
            server = nil   // else a revert from that file's server history would find this window and write over `dest`
            chips = []
            saved(stamp, digest)
            showState()
            if language == nil {   // an Untitled saved as a script, say
                language = Syntax.language(forFileName: name, firstLine: String(textView.string.prefix(200).split(separator: "\n").first ?? ""))
                highlight(after: 0)
            }
            return true
        }
    }

    /// Save As's write, off the main thread. Through a symlink into its target, as a save — but not to a link to
    /// nothing, nor over a folder or another user's file. Never in place: `dest` is the file it was, or ours whole.
    nonisolated private static func writeAs(_ data: Data, to dest: String, base: (stamp: Stamp?, digest: Data?), mode: mode_t,
                                            writing: (FileHandle, Data) throws -> Void, willRename: (String) -> Void) -> Written {
        let name = (dest as NSString).lastPathComponent
        var st = stat()
        if lstat(dest, &st) == 0, st.st_mode & S_IFMT == S_IFLNK, stat(dest, &st) != 0 {
            let to = (try? FileManager.default.destinationOfSymbolicLink(atPath: dest)).map { " (\($0))" } ?? ""
            return .failed("“\(name)” is a link to a file that isn't there\(to). Nothing was written: pick another name.", protected: false)
        }
        let path = URL(fileURLWithPath: dest).resolvingSymlinksInPath().path
        if stat(path, &st) == 0 {
            if let what = FileInfo.notRegular(path) { return .failed("“\(name)” is \(what), not a file to replace. Nothing was written.", protected: false) }
            if st.st_uid != geteuid() { return .failed("“\(name)” is another user's file. Nothing was written: Save As replaces only files of yours.", protected: false) }
        }
        return write(data, to: path, name: name, unlessChangedFrom: base, newMode: mode, inPlace: false,
                     hook: { _ in }, writing: writing, willRename: willRename)
    }

    /// What saving writes: the symlink's target, so a linked dotfile stays a link instead of being replaced by a copy.
    private var realPath: String? { url?.resolvingSymlinksInPath().path }

    /// Writes the text over the target as root, in place — so the file keeps its owner, mode and hard links (what you
    /// want for /etc/hosts and friends). See `AdminCommand.writeContents`.
    private func offerAdminSave(_ data: Data, reason: String, force: Bool) {
        var c = Confirm("Save “\(name)” as administrator?", action: "Save as Administrator")
        (c.chips, c.place, c.runs) = ([.root], "this Mac", AppDelegate.asAdmin)
        c.note = reason + " It's written in place, keeping its owner and mode."
        Task {
            guard await AppDelegate.sheet(c.alert(), on: revealed()) == 0 else { return }
            _ = await adminSave(data, force: force)
        }
    }

    /// The file may have changed while the sheet was up: checks again before asking for the password, and root checks
    /// it once more right before writing (a change while the password was asked asks the same way).
    func adminSave(_ data: Data, force: Bool) async -> Bool {
        guard let path = realPath else { return false }
        let stamp = stamp, digest = digest
        let seen = await Blocking.run(.userInitiated) { (changed: force ? nil : Self.changed(path, from: stamp, digest), now: Stamp(path)) }
        if let now = seen.changed {
            askOverwrite(now)
            return false
        }
        let hash = Self.sha(data)
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
            guard (try? Self.write(data, to: Darwin.open(t, O_WRONLY | O_CREAT | O_EXCL, 0o600), writing: { try $0.write(contentsOf: $1) })) != nil else { unlink(t); return false }   // a root file's text: ours only
            (cmd, tmp) = (command(.file(t)), t)
        }
        defer { if let tmp { unlink(tmp) } }
        // The text stays editable while macOS asks for the password, but the window's coming back mustn't take our
        // own write for someone else's (`windowDidBecomeKey`), nor a second ⌘S start another.
        saving = true
        defer { saving = false }
        switch await Self.runAsAdmin(cmd) {
        case .ok:
            saved(await Blocking.run(.userInitiated) { Stamp(path) }, hash)
            dirty = true   // what was typed while the password was asked isn't what was written: still unsaved
            dirty = changed
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
        a.beginSheetModal(for: revealed())
    }

    // MARK: - Window lifecycle

    /// Someone else changed the file: reload if we have nothing to lose, otherwise ask (once per version).
    /// Keep Mine leaves the baseline alone, so the next ⌘S still asks before overwriting.
    /// The stat and the reload read off the main thread (a share that doesn't answer would freeze the app).
    /// One look per file at a time: a file on a share that stopped answering mustn't take a thread per window switch.
    private static let stamps = Coalesced<Stamp?>()

    /// Its tab shows in the key window (made key, or chosen there): its keys, its tint, and a look at its file.
    func shown() {
        views.forEach { $0.frame.showKeys() }   // the menu's keys work by the key window
        if tinted == nil { highlight(after: 0) }
        sayPosition()
        guard let url else { return }   // an Untitled: no file to have changed
        Task {
            guard cover == nil, let now = await Self.stamps.run(url.path, .userInitiated, { Stamp(url.resolvingSymlinksInPath().path) }), url == self.url,
                  host.shows(self), window?.isVisible == true,
                  now != stamp, now != noticed, !saving else { return }
            guard dirty else {
                let loaded = await Blocking.run(.userInitiated) { Result { try Self.load(url) } }
                if url == self.url, !dirty { apply(loaded, onDisk: now) }   // not after a Save As or typing meanwhile
                return
            }
            askReload(now)
        }
    }

    /// Keep Mine is the safe one — nothing is lost, and the next ⌘S asks before writing over theirs: ↩ and ⎋; Reload ⌘↩.
    private func askReload(_ now: Stamp) {
        noticed = now
        var c = Confirm("“\(name)” changed on disk", action: "Reload")
        (c.cancel, c.irreversible) = ("Keep Mine", true)
        c.note = "Something else wrote it: \(Self.when(now)). Reload it and lose your unsaved changes, or keep editing your version?"
        Task {
            guard await AppDelegate.sheet(c.alert(), on: revealed()) == 0 else { return }
            await reload()
        }
    }

    /// Fails (and says why) when the file is gone, too big, binary or not text any more; the text stays as it was.
    /// Reads off the main thread (a share that stopped answering).
    @discardableResult func reload() async -> Bool {
        guard let url else { return false }
        let (loaded, now) = await Blocking.run(.userInitiated) { (Result { try Self.load(url) }, Stamp(url.resolvingSymlinksInPath().path)) }
        return url == self.url && apply(loaded, onDisk: now)
    }

    /// `onDisk`: what's there now, for a failure.
    @discardableResult private func apply(_ loaded: Result<Loaded, Error>, onDisk: Stamp?) -> Bool {
        let text: String, enc: String.Encoding, lossy: Bool, stamp: Stamp?, digest: Data
        do { (text, enc, lossy, bom, crlf, stamp, digest) = try loaded.get() } catch {
            noticed = onDisk   // say it once per version, not on every focus
            alert("Couldn't reload “\(name)”", error.localizedDescription)
            return false
        }
        if enc != encoding || lossy != self.lossy { encodingAsked = false }   // read differently now: ask again
        encoding = enc
        self.lossy = lossy
        showState()
        self.stamp = stamp
        self.digest = digest
        let sel = textView.selectedRange()
        textView.string = text
        detected = nil
        undo.removeAllActions()   // the old text's edits: ⌘Z would apply them to the new one; other tabs keep theirs
        notice = nil
        host?.changed(self)   // its draft goes: the file's text is what it shows
        views.forEach { $0.ruler.invalidate() }
        highlight(after: 0)
        textView.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        dirty = false
        edited?()   // read anew: what checks the text looks again
        return true
    }

    /// Unsaved, and saving would write other bytes than are there: typing and undoing it all isn't a change.
    var changed: Bool {
        guard dirty else { return false }
        if case .unreadable? = cover { return false }   // its draft is in damaged/, not the session: closing loses nothing
        guard cover == nil else { return true }   // its text isn't in the view (locked, being read): the draft is the change
        guard !unsent, let data = fileData(of: textView.string) else { return true }
        return Self.sha(data) != digest
    }

    /// Close Tab (⌘W): a changed one asks first — "Save changes to “nginx.conf” on web-01?", its strip, what Save does
    /// there besides (`AppDelegate.saveSays`); Save, Don't Save (⌘D), Cancel, one under another, as macOS stacks three;
    /// on production ↩ is Cancel. True if it asked nothing. A failed or cancelled Save keeps it. Its tab in `pane` while
    /// the other pane shows it too: only that view goes, nothing asked (`EditorHost.closeClone`).
    @discardableResult func closeAsking(in pane: EditorHost.Pane? = nil) -> Bool {
        if host.closeClone(self, in: pane) { return true }
        guard changed else { host.close(self); return true }
        askToClose { _ in }
        return false
    }

    /// The same, waited for (Close Other Tabs asks one tab after another): true once it goes — false if it stays
    /// (Cancel, a Save that didn't go through or asks about the encoding first).
    func closeAsked(in pane: EditorHost.Pane? = nil) async -> Bool {
        if host.closeClone(self, in: pane) { return true }
        guard changed else { host.close(self); return true }
        return await withCheckedContinuation { c in askToClose { c.resume(returning: $0) } }
    }

    /// The question, up before this returns; `done`: whether the tab goes.
    private func askToClose(_ done: @escaping @MainActor (Bool) -> Void) {
        AppDelegate.sheet(unsavedQuestion().alert(), on: revealed()) { [weak self] r in
            guard let self, r == 0 || r == 1 else { return done(false) }
            if r == 1 { host.close(self); return done(true) }   // Don't Save: its draft goes with the tab
            Task {
                let saved = await self.save(then: { self.host.close(self) })
                if saved { self.host.close(self) }
                done(saved)
            }
        }
    }

    func unsavedQuestion() -> Confirm {
        var c = Confirm("Save changes to “\(name)”" + (server.map { " on \(SavedServer.name(for: $0.target.asUser))" } ?? "") + "?",
                        on: server?.target, action: url == nil ? "Save…" : "Save")
        c.others = ["Don't Save"]
        let says = server.flatMap { (NSApp.delegate as? AppDelegate)?.saveSays($0.target, $0.path) }
        let note = [says, keepsDrafts ? "Don't Save discards them, the draft too." : nil].compactMap { $0 }.joined(separator: " ")
        c.note = note.isEmpty ? nil : note
        return c
    }

    /// ⎋ outside the find bar (`EditorHost.escape`).
    func escape() { host.escape(self) }

    /// Closed now, unasked (a test's cleanup).
    func close() { host.remove(self) }

    /// Its tab closed: gone from the lookups; a server copy's folder goes after its last upload (`onClose`).
    func closed() {
        Self.open.removeAll { $0 === self }
        onClose?()
        onClose = nil
    }

    // MARK: - Draft

    /// The text's changes so far; `sent`: those in a commit (-1: its revision went, the next one carries the text);
    /// `onDisk`: those a commit wrote.
    var edits = 0, sent = -1, onDisk = -1
    /// Why its last draft wasn't written (a "!" on its tab); when the last one was.
    var draftFailed: String?, draftSaved: Date?
    /// Its file's path as Copy Path gives it — a server's "web-01:/etc/x", as its title says it; nil for an Untitled,
    /// and for a locked server's draft till it's unlocked.
    var copyablePath: String? {
        if cover == .locked || cover == .loading && server != nil { return nil }
        if let server { return SavedServer.title(server.target, server.path) }
        return remote ?? url?.path
    }
    /// Copy Path (⇧⌘C in an editor, its tab's menu).
    func copyPath(to pasteboard: NSPasteboard = .general) {
        guard let p = copyablePath else { return NSSound.beep() }
        pasteboard.clearContents()
        pasteboard.setString(p, forType: .string)
    }
    /// Where Send / Execute in Terminal's text goes: its file's server (nil: this Mac), the folder a new tab starts in
    /// (nil: the caller's pick — an Untitled's, the clipboard's), the file for the production log. A read-only copy:
    /// where it was read from. nil: a server file's old copy whose server isn't known.
    var terminalPlace: (target: SFTPTarget?, folder: String?, path: String?)? {
        func dir(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
        if snapshot != nil { return snapshotFrom.map { ($0.target, dir($0.path), $0.path) } ?? (nil, nil, nil) }
        if let server { return (server.target, dir(server.path), server.path) }
        if remote != nil { return nil }
        return (nil, url.map { dir($0.path) }, url?.path)
    }

    /// Reveal in Panel has a place to go: this Mac's file, a server's (not an older "host:/path" copy's).
    var revealable: Bool { copyablePath != nil && (server != nil || remote == nil) }

    /// What ⇧⌘T brings back of it: as the session keeps it, with its text if it has changes (a Don't Save's, an
    /// Untitled's) — a locked server's draft read now, before its closing drops it. Kept in memory only.
    var reopenable: (doc: EditorSession.Doc, text: String?)? {
        guard let d = sessionDoc else { return nil }
        return (d, d.dirty ? draftText ?? lockedDraft.flatMap { try? $0.read() } : nil)
    }

    /// A tab of the editor window with drafts on: its changes are written as a draft, and Quit waits for that.
    var keepsDrafts: Bool { host?.tabbed == true && host.drafts != nil }

    /// Instead of the text: a server's file not opened yet (no connection without a click), a locked server's draft not
    /// shown till it's unlocked, one that couldn't be read, or one being read.
    enum Cover: Equatable { case parked, locked, unreadable(String?), loading }
    var cover: Cover? { didSet { showCover(); host?.update(self) } }
    /// A locked server's draft: where its text is (a revision, or memory: ⇧⌘T), read once it's unlocked.
    private var lockedDraft: (read: @Sendable () throws -> String?, doc: EditorSession.Doc)?
    /// What has the keys in its tab: the text, or the cover (↩ its button).
    var focus: NSView { frame.cover ?? textView }

    /// ⎋ over its cover (a parked tab): back to the panels too. Not from a tool's Problems or Test fields.
    func cancelOperation(_ sender: Any?) { if cover != nil { escape() } }

    /// The text a draft keeps; nil while it isn't there (a cover).
    var draftText: String? { cover == nil ? textView.string : nil }

    /// What the session keeps of it — nil for a draft that couldn't be read (its file stays in `damaged/`). Changed (or
    /// still uploading: a crash mid-upload mustn't leave the text only in a temp copy), it gets a revision.
    var sessionDoc: EditorSession.Doc? {
        if case .unreadable = cover { return nil }
        if snapshot != nil { return nil }   // a read-only copy: gone with its comparison, never back from a launch or ⇧⌘T
        var d = EditorSession.Doc(id: id, kind: server != nil ? .server : url == nil ? .untitled : .local)
        d.format.encoding = encoding.rawValue
        (d.format.lossy, d.format.bom, d.format.crlf, d.format.encodingAsked, d.format.finalNewline) = (lossy, bom, crlf, encodingAsked, finalNewline)
        if let server {
            d.server = .init(server.target, root: server.target.sudo, path: server.path)
            d.baseline = .init(attrs: server.state.baseline)
        } else if let url {
            d.path = url.path
            d.baseline = .init(stamp: stamp.map { .init(dev: $0.dev, ino: $0.ino, size: $0.size, sec: $0.sec, nsec: $0.nsec, mode: $0.mode) }, digest: digest)
        } else {
            (d.number, d.name) = (number, givenName)
        }
        let uploading = (server?.state.sending ?? 0) > 0
        d.unsent = unsent || uploading
        d.dirty = (dirty || uploading) && !(cover == nil && url == nil && textView.string.isEmpty)   // an emptied Untitled isn't a draft
        let sel = textView.selectedRange()
        (d.selection, d.scroll) = ([sel.location, sel.length], Double(frame.scroll.contentView.bounds.origin.y))
        return d
    }

    /// Back from the last launch: its tab at once, its text as it's read (`restore(from:)`).
    /// `draft`: it has a text to read (the store's revision; ⇧⌘T's, in memory).
    convenience init(restoring d: EditorSession.Doc, draft: Bool? = nil, onServer: EditorHost.OnServer) {
        let url: URL? = switch d.kind {
            case .untitled: nil
            case .local: d.path.map { URL(fileURLWithPath: $0) }
            // The copy a Save makes: its folder only then (`save`).
            case .server: URL(fileURLWithPath: NSTemporaryDirectory() + "dfm-sftp-" + UUID().uuidString).appendingPathComponent(((d.server?.path ?? "file") as NSString).lastPathComponent)
        }
        let target = d.server.map { $0.target.asRoot($0.root) }, f = d.format
        let stamp = d.baseline?.stamp.map { s -> Stamp in Stamp(dev: s.dev, ino: s.ino, size: s.size, sec: s.sec, nsec: s.nsec, mode: s.mode ?? 0o600) }
        let loaded: Loaded = ("", String.Encoding(rawValue: f.encoding), f.lossy, f.bom, f.crlf, stamp, d.baseline?.digest ?? Self.sha(Data()))
        self.init(url, number: d.number, id: d.id, remote: d.server.map { SavedServer.title($0.target, $0.path) }, loaded: loaded)
        (encodingAsked, finalNewline, dirty, unsent) = (d.format.encodingAsked, d.format.finalNewline, d.dirty, d.unsent)
        if url == nil, let n = d.name { givenName = n; relanguage() }
        lastSelection = d.selection.flatMap { $0.first }.map { ($0, CGFloat(d.scroll ?? 0)) }
        if let target, let s = d.server, let url {
            let state = AppDelegate.RemoteEdit(baseline: d.baseline?.attrs ?? .nothing)
            state.unlockFirst = true   // no connection made for it this launch: its first save asks a locked server's Touch ID
            server = (target, s.path, state)
            chips = Chip.of(target)
            (onSaved, onClose) = onServer(target, s.path, state, url.deletingLastPathComponent().path)
        }
        cover = d.kind == .untitled && !(draft ?? (d.revision != nil)) ? nil : .loading
        showCover()   // in an initializer `didSet` doesn't run
        showState()
        Self.open.append(self)
    }

    /// The text of a restored tab, read off the main thread (contract §6): a draft's from its revision, an unchanged
    /// file's from the file. A local file changed or gone since its draft says so (Compare · Reload · Save As…); one
    /// whose draft is what's in it now is just open. An unchanged file gone: its tab goes, and says why. A server's file
    /// parks (nothing connects); a locked server's draft waits for Unlock.
    func restore(_ d: EditorSession.Doc, from store: DraftStore) async {
        await restore(d, draft: d.revision != nil) { try store.text(of: d) }
    }

    /// A tab ⇧⌘T brings back, as a restored one: `text` its changes' (in memory), else its file as it is now — a
    /// server's parked.
    func reopen(_ d: EditorSession.Doc, text: String?) async {
        reopened = text != nil
        await restore(d, draft: text != nil) { text }
    }
    /// Its text came back by ⇧⌘T: it isn't in the store (its closing dropped it), so the next commit writes it whole.
    private var reopened = false

    private func restore(_ d: EditorSession.Doc, draft hasDraft: Bool, text read: @escaping @Sendable () throws -> String?) async {
        if d.kind == .untitled, !hasDraft { return }   // an empty one
        if server != nil, !hasDraft { return cover = .parked }
        if let server {
            await ServerLock.learn([server.target])   // a locked server's, however its address is written
            if ServerLock.needsUnlock(server.target) { lockedDraft = (read, d); return cover = .locked }
        }
        let path = url?.resolvingSymlinksInPath().path, kind = d.kind
        let (draft, disk, stampNow) = await Blocking.run(.userInitiated) { () -> (Result<String?, Error>, Data?, Stamp?) in
            let draft = Result { try read() }
            guard kind == .local, let path else { return (draft, nil, nil) }
            let stamp = Stamp(path)
            return (draft, stamp == nil || FileInfo.notRegular(path) != nil ? nil : try? Data(contentsOf: URL(fileURLWithPath: path)), stamp)
        }
        guard case .success(let text) = draft else {
            if case .failure(DraftStore.Failure.damaged(let moved)) = draft { return cover = .unreadable(moved) }
            return cover = .unreadable(nil)
        }
        guard let text else {   // an unchanged file: as it is now
            guard let url else { return }
            switch await Blocking.run(.userInitiated, { Result { try Self.load(url) } }) {
            case .success(let loaded): return fill(loaded.0, stamp: loaded.5, digest: loaded.6, apply: loaded)
            case .failure(let error):
                let place = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                let gone = (error as NSError).code == NSFileReadNoSuchFileError || (error as NSError).code == NSFileNoSuchFileError
                return host.drop(self, saying: gone ? "\(name) is gone from \(place): its tab wasn't restored"
                                                    : "\(name) in \(place) couldn't be read (\(error.localizedDescription)): its tab wasn't restored")
            }
        }
        guard kind == .local, let url else { return fill(text) }
        if let disk, fileData(of: text) == disk { return fill(text, clean: true, stamp: stampNow, digest: Self.sha(disk)) }   // saved, then a crash
        if let disk, Self.sha(disk) == digest { return fill(text, stamp: stampNow) }   // the same bytes, its volume mounted anew: a new stamp
        fill(text)
        let place = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        if disk == nil, stampNow == nil {
            notice = ("\(name) is no longer in \(place) — Save puts it back", [("Save As…", { [weak self] in Task { await self?.saveAs() } })])
        } else {
            noticed = stampNow   // asked here, not again on the next look
            notice = ("\(name) changed on disk since your draft", [("Compare", { [weak self] in self?.compareWithDisk() }),
                                                                    ("Reload", { [weak self] in Task { await self?.reload() } }),
                                                                    ("Save As…", { [weak self] in Task { await self?.saveAs() } })])
        }
    }

    /// The restored text in, as the draft has it (nothing to write again), the cover off.
    private func fill(_ text: String, clean: Bool = false, stamp: Stamp?? = nil, digest: Data? = nil, apply loaded: Loaded? = nil) {
        if let loaded { (encoding, lossy, bom, crlf) = (loaded.1, loaded.lossy, loaded.bom, loaded.crlf) }
        textView.string = text
        (detected, tinted) = (nil, nil)   // a tint of the empty text it had while read (shown meanwhile): all of it again
        if let stamp { self.stamp = stamp }
        if let digest { self.digest = digest }
        if clean || loaded != nil { (dirty, unsent) = (false, false) }
        undo.removeAllActions()
        (sent, onDisk) = reopened ? (-1, -1) : (edits, edits)
        if reopened { reopened = false; host?.changed(self) }
        cover = nil
        if url != nil, language == nil { language = Syntax.language(forFileName: name, firstLine: String(text.prefix(200).split(separator: "\n").first ?? "")) }
        if let d = lastSelection {   // x as it is: the line numbers sit over the clip view, the text inset from them (x < 0)
            let clip = frame.scroll.contentView
            textView.setSelectedRange(NSRange(location: min(d.0, (text as NSString).length), length: 0))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: d.1))
        }
        if host.shows(self), window?.isKeyWindow == true { shown() }
    }
    /// Where its caret and scroll were (restored).
    var lastSelection: (Int, CGFloat)?

    /// A parked server tab opened (a click on its tab, ↩, F4 on its file), a locked one's draft unlocked: never by
    /// itself, never at launch.
    func connect() {
        guard let server else { return }
        switch cover {
        case .parked?:
            guard let app = NSApp.delegate as? AppDelegate else { return }
            cover = .loading
            Task {
                guard await ServerLock.authorize(server.target, "open a file on") else { return cover = .parked }
                if await !app.remoteOpen(into: self, server.target, server.path) { cover = .parked }
            }
        case .locked?:
            Task {
                guard let (read, d) = lockedDraft, await ServerLock.authorize(server.target, "see a draft on") else { return }
                lockedDraft = nil
                cover = .loading
                await restore(d, draft: true, text: read)
            }
        default: break
        }
    }

    /// A parked tab's file, downloaded (`remoteOpen(into:)`): edited here now.
    func opened(_ local: URL, _ loaded: Loaded, state: AppDelegate.RemoteEdit, onSaved: @escaping @MainActor (URL) -> Void, onClose: @escaping @MainActor () -> Void) {
        url = local
        if let s = server { server = (s.target, s.path, state) }
        (self.onSaved, self.onClose) = (onSaved, onClose)
        fill(loaded.0, stamp: loaded.5, digest: loaded.6, apply: loaded)
    }

    // MARK: - Rename

    /// Why its tab's file can't be renamed now (said in its status line); nil: it can.
    var renameRefusal: String? {
        if snapshot != nil { return "Not renamed: a read-only copy to compare with" }
        if fixedPlace { return "Not renamed: Kermo reads a tool's file where it is" }
        if remote != nil, server == nil { return "Not renamed: this is a copy of a server's file" }   // an older "host:/path" copy
        if let s = server, saving || s.state.sending > 0 { return "Not renamed: an upload to \(SavedServer.name(for: s.target)) is still going" }
        if saving { return "Not renamed: it's being saved" }
        if cover == .loading, server == nil { return "Not renamed: it's still being read" }   // a server's download after a rename is dropped (`remoteOpen(into:)`)
        if case .unreadable? = cover { return "Not renamed: its draft couldn't be read" }
        return nil
    }

    /// A panel's rename of `path` on this Mac to `dst`, for the tabs: not while that file's tab saves (the save would
    /// make the old name again), nor onto a file a tab has open (one file, one tab).
    static func renameRefused(_ path: String, to dst: String) -> String? {
        let tab = following(path)
        if let tab, let why = tab.renameRefusal { return why }
        if let other = following(dst), other !== tab { return "“\(other.name)” is open in the editor — nothing was renamed." }
        return nil
    }

    /// The editor of this Mac's file at `path` that follows its renames (not a tool's: Kermo reads that one where it is).
    static func following(_ path: String) -> Editor? {
        open.first { !$0.fixedPlace && $0.server == nil && $0.url?.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path }
    }

    /// A file renamed on this Mac (its tab, a panel's ⇧F6): its tab follows.
    static func renamed(_ path: String, to dst: String) async { await following(path)?.moved(to: URL(fileURLWithPath: dst)) }

    /// Rename… of its tab (a double-click, ⇧F6): an Untitled's name; its file on this Mac or on its server — never over
    /// anything there. Nothing of it changes unless the file's renamed.
    func rename(to name: String) async {
        guard !name.isEmpty, name != self.name else { return }
        if let why = renameRefusal { return flash(why) }
        if let why = AppDelegate.badName(name) { return flash("Not renamed: " + why) }
        if let server {
            guard let app = Self.app() else { return }
            let (t, from) = (server.target, server.path)
            let to = ((from as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
            // Before production's question (`renameOnServer` looks again after it).
            if let other = Self.tab(onServer: t, to), other !== self { return flash("“\(name)” is open in another tab — nothing was renamed") }
            if SavedServer.isProd(t) {   // the field has no strip: the question has, ↩ Cancel
                var c = Confirm("Rename “\(self.name)” to “\(name)” on \(SavedServer.name(for: t.asUser))?", on: t, action: "Rename")
                c.note = "In \((from as NSString).deletingLastPathComponent)."
                guard await app.confirm(c, on: revealed()) == 0 else { return }
            }
            let panel = app.panels.first { $0.remote?.target == t } ?? app.active
            await app.renameOnServer(t, from, to: to, in: panel, on: revealed()) { [weak self] in self?.flash($0) }
            return
        }
        guard let url else {
            givenName = name
            relanguage()
            showState()
            return host?.changed(self, now: true) ?? ()
        }
        let path = url.path, dst = url.deletingLastPathComponent().appendingPathComponent(name).path, hook = willRename
        if let why = Self.renameRefused(path, to: dst) { return flash(why) }
        let done = await renaming { await Blocking.run(.userInitiated) { Result { try AppDelegate.rename(path, to: name, willRename: hook) } } }   // a share that doesn't answer
        switch done {
        case .failure(let e): alert("Couldn't rename “\(self.name)”", e.localizedDescription)
        case .success(let dst):
            await moved(to: URL(fileURLWithPath: dst))
            Self.app()?.showRenamed(from: path, to: dst)
        }
    }

    /// While its file is renamed: ⌘S does nothing (it would make the old name again). A server tab's text may come in
    /// meanwhile (its download): editable once it's done.
    func renaming<T>(_ work: () async -> T) async -> T {
        saving = true
        defer {
            saving = false
            editable(cover == nil)
        }
        return await work()
    }

    /// Its file is `new` on this Mac now: the tab, title and language follow, and the session names it at once — a
    /// draft goes with it.
    func moved(to new: URL) async {
        url = new
        relanguage()
        showState()
        await host?.commit(durable: true)
    }

    /// Its file is at `path` on its server now: its saves go there — the same state and copy folder (the old `onClose`
    /// would remove that) — and the session names it at once.
    func moved(onServer path: String) async {
        guard let s = server, let url, let host else { return }
        server = (s.target, path, s.state)
        remote = SavedServer.title(s.target, path)
        (onSaved, onClose) = host.onServer(s.target, path, s.state, url.deletingLastPathComponent().path)
        relanguage()
        showState()
        await host.commit(durable: true)
    }

    /// Its language by its name now (renamed, an Untitled named): colors, comment mark and Tab's indent follow; Final
    /// Newline stays as it is.
    private func relanguage() {
        language = Syntax.language(forFileName: name, firstLine: String(textView.string.prefix(200).split(separator: "\n").first ?? ""))
        highlightGen += 1   // a tint in the old language under way: dropped
        tinted = nil
        if language == nil, let s = textView.textStorage, s.length > 0 { SyntaxColors.apply([], to: s) } else { highlight(after: 0) }
        sayPosition()
    }

    /// Compare's copies of texts for a program (`diffCommand`) or `diff -u`: removed at quit (the launch sweep takes one a crash left).
    static var comparisons: [String] = []

    /// The draft's bytes against the file's now, as saving would write them (its encoding, CRLF, BOM): a diff of the
    /// text alone would differ on every line of a CRLF file. Through a 0600 file of ours, gone with the diff's temp files.
    func compareWithDisk() {
        guard let url, let app = Self.app() else { return }
        if app.builtInCompare {   // built in: this document itself against the file as it is now
            Task { await app.compare(.file(.init(path: url.path, name: "\(name) (on disk)", now: true)), .doc(self)) }
            return
        }
        guard let data = fileData(of: textView.string) else { return }
        let tmp = NSTemporaryDirectory() + "dfm-text-draft-" + UUID().uuidString   // diff reads it after it starts: gone at quit
        guard mkdir(tmp, 0o700) == 0, FileManager.default.createFile(atPath: tmp + "/" + name, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        Self.comparisons.append(tmp)
        Task { await app.diff(AppDelegate.DiffSide(path: tmp + "/" + name, name: "\(name) (your draft)"), AppDelegate.DiffSide(path: url.path), in: app.active) }
    }

    /// The cover over its text in every view, with what it says and its button (↩).
    private func showCover() {
        editable(cover == nil && !saving)
        views.forEach { $0.frame.cover = coverView() }
        if host?.active === self { window?.makeFirstResponder(focus) }
        sayPosition()
    }

    private func coverView() -> NSView? {
        let place = server.map { SavedServer.name(for: $0.target) } ?? ""
        return switch cover {
            case nil: nil
            case .loading?: Banner(cover: "Reading “\(name)”…", [])
            case .parked?: Banner(cover: "Not connected to \(place)", [("Open", { [weak self] in self?.connect() })])
            case .locked?: Banner(cover: "\(place) is locked", [("Unlock to see this draft", { [weak self] in self?.connect() })])
            case .unreadable(let moved)?: Banner(cover: "This draft couldn't be read" + (moved.map { " · kept in \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""),
                                                 moved.map { m in [("Show in Finder", { @MainActor in NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m)]) })] } ?? [])
        }
    }

    /// A line over its text in every view (a restored draft whose file changed or went), with its buttons.
    private var notice: (text: String, actions: [(String, @MainActor () -> Void)])? {
        didSet {
            views.forEach { $0.frame.banner = notice.map { Banner($0.text, $0.actions) } }
            host?.comparison?.levelTops()   // compared: the other side's rows level with these again
        }
    }

    /// Typing on or off in every view (a save, a rename, a cover).
    private func editable(_ on: Bool) { views.forEach { $0.text.isEditable = on && snapshot == nil } }

    /// The mark before its tab's name: ● changed, ↑ saved here but not on its server, ! its draft not written, a lock a read-only copy.
    var mark: NSAttributedString? {
        if snapshot != nil {   // a read-only copy: a lock
            let lock = NSTextAttachment()
            lock.image = Symbol.lock.image("Read-only", color: .secondaryLabelColor, size: NSFont.smallSystemFontSize - 1)
            return NSAttributedString(attachment: lock)
        }
        let m: (String, NSColor)? = draftFailed != nil && dirty ? ("!", .systemRed) : unsent ? ("↑", .systemOrange) : dirty ? ("●", .secondaryLabelColor) : nil
        return m.map { NSAttributedString(string: $0.0, attributes: [.foregroundColor: $0.1, .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)]) }
    }

    /// Its state in words, as the status line and the tab's tooltip say it.
    var stateWords: String {
        if let failed = draftFailed, dirty { return "Draft not saved: \(failed) · Save As… keeps the text" }
        guard dirty || unsent else { return "" }
        var words = [unsent ? server.map { "Not uploaded to \(SavedServer.name(for: $0.target)) · ⌘S tries again" } ?? "Unsaved changes" : "Unsaved changes"]
        if let off = host?.draftsOff { words.append("Drafts off: \(off) · closing asks to save") }
        else if let at = draftSaved, onDisk == edits, host?.tabbed == true { words.append("Draft saved " + Self.clock.string(from: at)) }
        return words.joined(separator: " · ")
    }
    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    /// The status line (its encoding, what's saved and where), its tab, and the window's title while it shows.
    func showState() {
        sayState()
        host?.update(self)
    }
    /// The status line alone (after each draft written: the tabs once for all).
    func sayState() {
        let said = [encodingName, stateWords].filter { !$0.isEmpty }.joined(separator: " · ")
        views.forEach { $0.frame.text = said }
    }
}

/// ⎋ outside the find bar: back to the panels (`Editor.escape`) — NSTextView would otherwise show word completions.
/// In the find bar it closes the bar. Under its text: the caret's line and a bracket with its pair; with Show
/// Invisibles a mark on each tab (the layout manager's own marks spaces only).
final class EditorTextView: NSTextView {
    override func cancelOperation(_ sender: Any?) {
        if enclosingScrollView?.isFindBarVisible == true {
            let hide = NSMenuItem()
            hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
            return performTextFinderAction(hide)
        }
        (delegate as? Editor)?.escape()
    }

    /// A bracket by the caret and its pair (`Editor.markBrackets`).
    var brackets: [NSRange] = [] { didSet { relight() } }
    var tabMarks = false { didSet { needsDisplay = true } }
    /// Its side of a comparison (`Comparison`): its colors and blank space, under the caret's line.
    weak var compared: Comparison.Side? { didSet { needsDisplay = true } }
    /// Where they were last drawn: what to redraw when they move.
    private var lit: [NSRect] = []

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
        relight()
    }

    private func relight() {
        let now = lights()
        for r in lit + [now.line].compactMap({ $0 }) + now.brackets { setNeedsDisplay(r) }
    }

    /// The caret's line (none while there's a selection) and the brackets' boxes, in the view.
    private func lights() -> (line: NSRect?, brackets: [NSRect]) {
        guard let lm = layoutManager, let tc = textContainer, let s = textStorage else { return (nil, []) }
        let o = textContainerOrigin, sel = selectedRange()
        var line: NSRect?
        if sel.length == 0 {
            var r = sel.location >= s.length && (s.length == 0 || s.mutableString.character(at: s.length - 1) == 10) ? lm.extraLineFragmentRect
                : lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: min(sel.location, s.length - 1)), effectiveRange: nil)
            (r.origin.x, r.size.width, r.origin.y) = (0, bounds.width, r.origin.y + o.y)
            line = r
        }
        let boxes = brackets.filter { NSMaxRange($0) <= s.length }.map {
            lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: $0, actualCharacterRange: nil), in: tc).offsetBy(dx: o.x, dy: o.y)
        }
        return (line, boxes)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        compared?.draw(in: self, rect)
        let now = lights()
        lit = [now.line].compactMap { $0 } + now.brackets
        if let line = now.line, line.intersects(rect) {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            line.fill(using: .sourceOver)
        }
        NSColor.systemYellow.withAlphaComponent(0.35).setFill()
        for b in now.brackets where b.intersects(rect) { b.fill(using: .sourceOver) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard tabMarks, let lm = layoutManager, let tc = textContainer, let s = textStorage?.mutableString else { return }
        let o = textContainerOrigin
        let chars = lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -o.x, dy: -o.y), in: tc), actualGlyphRange: nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor]
        var i = chars.location
        while i < NSMaxRange(chars) {
            let r = s.range(of: "\t", options: .literal, range: NSRange(location: i, length: NSMaxRange(chars) - i))
            guard r.location != NSNotFound else { break }
            let box = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
            ("→" as NSString).draw(at: NSPoint(x: box.minX + o.x, y: box.minY + o.y), withAttributes: attrs)
            i = NSMaxRange(r)
        }
    }
}

/// One view of a document: its text over the document's storage, with its own layout, caret, scroll, find bar, line
/// numbers and status line. Its controller's place in the responder chain takes ⌘S, Save As… and Final Newline to the
/// document, whichever view has the keys.
@MainActor
final class DocView: NSViewController, NSMenuItemValidation {
    unowned let doc: Editor
    let frame: DocFrame, text: EditorTextView, ruler: LineNumberRuler
    /// The pane it shows in (a tool's window has one); nil: not placed yet, or put by till its document shows again.
    weak var pane: EditorHost.Pane?

    init(_ doc: Editor, side: NSView? = nil) {
        self.doc = doc
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        frame = DocFrame(scroll, size: NSSize(width: 900, height: 640), side: side)
        // TextKit 1 by hand — the line-number ruler needs it — over the document's storage, which another view may share.
        let layout = NSLayoutManager(), box = NSTextContainer(size: NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude))
        layout.allowsNonContiguousLayout = true   // lays out what's on screen, not the whole text first: typing at the top of a 30 MB log stays quick
        layout.addTextContainer(box)
        doc.storage.addLayoutManager(layout)
        text = EditorTextView(frame: NSRect(origin: .zero, size: scroll.contentSize), textContainer: box)
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        box.widthTracksTextView = true
        text.isRichText = false
        text.allowsUndo = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.textContainerInset = NSSize(width: 4, height: 4)
        // Config files and scripts must stay byte-exact: no smart quotes, dashes or autocorrect.
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.delegate = doc   // its Undo is the document's (`undoManager(for:)`)
        scroll.documentView = text
        ruler = LineNumberRuler(textView: text)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        super.init(nibName: nil, bundle: nil)
        view = frame
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func saveDocument(_ sender: Any?) { doc.saveDocument(sender) }
    @objc func saveDocumentAs(_ sender: Any?) { doc.saveDocumentAs(sender) }
    @objc func toggleFinalNewline(_ sender: Any?) { doc.toggleFinalNewline(sender) }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { doc.validateMenuItem(item) }
    override func cancelOperation(_ sender: Any?) { doc.cancelOperation(sender) }
}

// MARK: - Views

extension Editor {
    /// A view of it shows in a window: its pane's tab shown, or a tool's window.
    var onScreen: Bool { views.contains { $0.frame.window != nil } }

    /// Its view in `pane`, made if there's none: its first, not placed yet, goes there; else a new one over the same
    /// text — the caret where the current one's is, the cover, line, state and settings as the others have them.
    func view(in pane: EditorHost.Pane) -> DocView {
        if let v = views.first(where: { $0.pane === pane }) { return v }
        if let v = views.first(where: { $0.pane == nil }) { v.pane = pane; return v }
        let v = DocView(self), was = current!
        v.pane = pane
        views.append(v)
        applyFont(only: v)
        applyView(only: v)
        v.text.isEditable = was.text.isEditable
        v.frame.cover = coverView()
        v.frame.banner = notice.map { Banner($0.text, $0.actions) }
        v.text.setSelectedRange(was.text.selectedRange())
        sayState()
        sayPosition(v)
        return v
    }

    /// Its view in `pane` gone, with its layout (a clone's closed, a Join's); its last is put by, for the pane it shows
    /// in next.
    func dropView(in pane: EditorHost.Pane) {
        guard let i = views.firstIndex(where: { $0.pane === pane }) else { return }
        let v = views[i]
        v.frame.removeFromSuperview()
        guard views.count > 1 else { v.pane = nil; return }
        views.remove(at: i)
        v.text.layoutManager.map(storage.removeLayoutManager)
        if current === v { current = views[0] }
    }
}

// MARK: - Typing and moving around

extension Editor {
    /// Every editor's text size, wrap and invisibles, kept across launches (⌘= / ⌘−, ⌥Z, View ▸ Show Invisibles).
    static var fontSize: CGFloat { CGFloat(min(max(UserDefaults.standard.object(forKey: "editorFontSize") as? Double ?? 12, 8), 36)) }
    static var wraps: Bool { UserDefaults.standard.object(forKey: "editorWrap") as? Bool ?? true }
    static var invisibles: Bool { UserDefaults.standard.bool(forKey: "editorInvisibles") }

    static func zoom(by step: CGFloat) {
        let size = min(max(fontSize + step, 8), 36)   // 0: as Settings set it
        if step != 0, size == fontSize { return NSSound.beep() }
        UserDefaults.standard.set(Double(size), forKey: "editorFontSize")
        open.forEach { $0.applyFont() }
        EditorHost.shared?.comparison?.regap()   // its blank space is so many lines' height
    }
    static func toggleWrap() { UserDefaults.standard.set(!wraps, forKey: "editorWrap"); open.forEach { $0.applyView() }; EditorHost.shared?.comparison?.regap() }
    static func toggleInvisibles() { UserDefaults.standard.set(!invisibles, forKey: "editorInvisibles"); open.forEach { $0.applyView() } }

    /// Its text at `fontSize`, a tab `LineEdit.tabWidth` columns wide, the line numbers to match; `only`: a new view's
    /// typing and numbers (the storage has them).
    fileprivate func applyFont(only: DocView? = nil) {
        let font = NSFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular), p = NSMutableParagraphStyle()
        p.tabStops = []
        p.defaultTabInterval = CGFloat(LineEdit.tabWidth) * ("0" as NSString).size(withAttributes: [.font: font]).width
        for v in only.map({ [$0] }) ?? views {
            v.text.defaultParagraphStyle = p
            v.text.typingAttributes[.font] = font
            v.text.typingAttributes[.paragraphStyle] = p
            v.ruler.fontSize = Self.fontSize * 10 / 12
        }
        if only == nil, text.length > 0 { storage.addAttributes([.font: font, .paragraphStyle: p], range: NSRange(location: 0, length: text.length)) }
    }

    fileprivate func applyView(only: DocView? = nil) {
        for v in only.map({ [$0] }) ?? views {
            v.text.setWraps(Self.wraps)
            v.text.layoutManager?.showsInvisibleCharacters = Self.invisibles
            v.text.tabMarks = Self.invisibles
        }
    }

    /// Its text as the text view keeps it: no copy (`string` copies all of it).
    private var text: NSMutableString { storage.mutableString }

    /// What Tab puts in: View ▸ Indentation's pick, else the text's way, else its language's (`LineEdit.indent(for:)`).
    var indent: LineEdit.Indent {
        if let indentPick { return indentPick }
        if detected == nil { detected = LineEdit.detect(text.substring(to: min(text.length, 200_000))) }
        return LineEdit.indent(for: language, detected: detected ?? nil)
    }

    func pickIndent(_ i: LineEdit.Indent) {
        guard i != .tabs || language != .yaml else { return NSSound.beep() }   // YAML takes no tab
        indentPick = i
        sayPosition()
    }

    /// "Ln 12, Col 5 · 3 lines, 120 selected · Spaces: 4", right of each view's status line. Col counts columns, a tab
    /// to the next stop.
    func sayPosition() { views.forEach(sayPosition) }
    func sayPosition(_ v: DocView) {
        let compare = host?.comparison?.words(for: v)
        guard cover == nil else { v.frame.position = compare ?? ""; return }
        let sel = v.text.selectedRange(), starts = v.ruler.starts
        let line = LineNumberRuler.line(of: sel.location, in: starts), n = sel.location - starts[line]
        let col = n > 10_000 ? n : LineEdit.column(text.substring(with: NSRange(location: starts[line], length: n)))   // ponytail: a longer line's start counts characters
        var words = ["Ln \(line + 1), Col \(col + 1)"]
        if sel.length > 0 {
            let lines = LineNumberRuler.line(of: NSMaxRange(sel) - 1, in: starts) - line + 1
            words.append((lines > 1 ? "\(lines) lines, " : "") + "\(sel.length) selected")
        }
        words.append(indent == .tabs ? "Tabs" : "Spaces: \(indent.width)")
        v.frame.position = ([compare].compactMap { $0 } + words).joined(separator: " · ")
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // A tab not shown (twenty restored at launch): `shown` says it.
        guard let v = views.first(where: { $0.text === notification.object as? NSTextView }), v.frame.window != nil else { return }
        if let c = host?.comparison { c.caretMoved(v) }   // says the position too
        sayPosition(v)
        markBrackets(v)
    }

    /// The bracket just before the caret (else just after it) and its pair, lit.
    private func markBrackets(_ v: DocView) {
        let sel = v.text.selectedRange(), text = text
        let at = sel.length > 0 ? nil : [sel.location - 1, sel.location].lazy.compactMap { i in LineEdit.matchingBracket(text, at: i).map { (i, $0) } }.first
        v.text.brackets = at.map { [NSRange(location: $0.0, length: 1), NSRange(location: $0.1, length: 1)] } ?? []
    }

    /// ↩ keeps the line's indent (one more after an opening bracket, or ":" in YAML and Python), Tab puts in the
    /// indent (spaces to the next stop) or indents the lines selected, ⇧Tab takes one off.
    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard view.isEditable, !view.hasMarkedText() else { return false }
        let r = view.selectedRange()
        if detected == .some(nil), selector != #selector(NSResponder.insertBacktab(_:)) { detected = nil }   // indented since?
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let (s, caret) = LineEdit.newline(text, over: r, unit: indent.unit, colon: language == .yaml || language == .python)
            view.insertText(s, replacementRange: r)
            view.setSelectedRange(NSRange(location: r.location + caret, length: 0))
        case #selector(NSResponder.insertTab(_:)):
            if text.range(of: "\n", options: .literal, range: r).location != NSNotFound { change(LineEdit.indent(text, r, unit: indent.unit), named: "Indent"); return true }
            guard case .spaces(let n) = indent else { return false }   // a tab, as typed
            let start = text.lineRange(for: NSRange(location: r.location, length: 0)).location
            let col = LineEdit.column(text.substring(with: NSRange(location: start, length: min(r.location - start, 10_000))))
            view.insertText(String(repeating: " ", count: n - col % n), replacementRange: r)
        case #selector(NSResponder.insertBacktab(_:)):
            change(LineEdit.outdent(text, r, width: indent.width), named: "Outdent")
        default:
            return false
        }
        return true
    }

    // The line commands act on the first selection's lines: lines between two ⌘-drag selections aren't touched.
    func moveLines(up: Bool) { change(LineEdit.move(text, textView.selectedRange(), up: up), named: up ? "Move Line Up" : "Move Line Down") }
    func duplicateLines(up: Bool) { change(LineEdit.duplicate(text, textView.selectedRange(), up: up), named: "Duplicate Line") }
    func deleteLines() { change(LineEdit.delete(text, textView.selectedRange()), named: "Delete Line") }

    /// ⌘/ by its language (`LineEdit.comment`): JSON, or a file of an extension Kermo doesn't know, beeps.
    func toggleComment() {
        guard let c = LineEdit.comment(language, fileName: name) else { return NSSound.beep() }
        let sel = textView.selectedRange()
        change(c.close.map { LineEdit.toggleComment(text, sel, open: c.open, close: $0) } ?? LineEdit.toggleComment(text, sel, token: c.open), named: "Toggle Comment")
    }

    /// A line command's change as one Undo step, through the text view: its draft, colors and line numbers follow.
    /// Only while the text has the keys: ⇧⌘K typed in the find bar deletes no line behind it.
    private func change(_ e: LineEdit.Edit?, named: String) {
        guard let e, textView.isEditable, window?.firstResponder === textView else { return NSSound.beep() }
        guard apply(e.text, over: e.range, in: current, named: named) else { return }
        let sel = NSIntersectionRange(e.select, NSRange(location: 0, length: text.length))   // never past the end
        textView.setSelectedRange(sel.location == e.select.location ? sel : NSRange(location: min(e.select.location, text.length), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// `text` over `range` as one Undo step named so, through `v`'s text view — with the keys or not (Copy Change from the
    /// other side): its draft, colors and line numbers follow as after typing. False: the view said no.
    @discardableResult
    func apply(_ text: String, over range: NSRange, in v: DocView, named: String) -> Bool {
        let tv = v.text
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: range, replacementString: text) else { return false }
        let plain: [NSAttributedString.Key: Any] = [.font: tv.font as Any, .paragraphStyle: tv.defaultParagraphStyle as Any, .foregroundColor: NSColor.textColor]
        tv.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: plain))
        tv.didChangeText()
        undo.setActionName(named)
        return true
    }

    /// ⌘L: asks for a line ("120", or "120:8" for its 8th column) and goes there.
    func goToLine() {
        guard let window, cover == nil else { return NSSound.beep() }
        let here = LineNumberRuler.line(of: textView.selectedRange().location, in: ruler.starts) + 1
        window.ask("Go to Line", info: "1–\(ruler.starts.count), or line:column", placeholder: "\(here)", ok: "Go") { [weak self] in self?.go(to: $0) }
    }

    /// "120" or "120:8": that line's start (or its column 8, as the status line's Col counts), shown with a flash; out of
    /// range goes to the nearest.
    func go(to spec: String) {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let first = parts.first, let wanted = first else { return NSSound.beep() }
        let starts = ruler.starts, start = starts[min(max(wanted, 1), starts.count) - 1]
        var r = text.lineRange(for: NSRange(location: start, length: 0))
        if r.length > 0, text.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
        let col = parts.count > 1 ? LineEdit.offset(ofColumn: max((parts[1] ?? 1) - 1, 0), in: text.substring(with: r)) : 0
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: start + col, length: 0))
        textView.scrollRangeToVisible(r)
        if r.length > 0 { textView.showFindIndicator(for: r) }
    }
}

extension NSTextView {
    /// Long lines wrap at the view's edge, or run on to the right over a horizontal scroller.
    func setWraps(_ on: Bool) {
        guard let scroll = enclosingScrollView, let tc = textContainer else { return }
        scroll.hasHorizontalScroller = !on
        isHorizontallyResizable = !on
        tc.widthTracksTextView = on
        tc.containerSize = NSSize(width: on ? scroll.contentSize.width : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        if on { frame.size.width = scroll.contentSize.width }
    }
}
