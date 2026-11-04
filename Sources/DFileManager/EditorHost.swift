import AppKit
import DFMCore

/// The window an editor's documents show in. The editor window (`tabs`): a tab per document, kept between launches with
/// their drafts (`DraftStore`, `editor.noindex`), and closing it only hides it. Or a tool's file alone in a window of its
/// own, which closes as it always did.
@MainActor
final class EditorHost: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    /// The editor window, made at first use (one for now).
    static var tabs: EditorHost {
        if let shared { return shared }
        let h = EditorHost(tabbed: true)
        shared = h
        return h
    }
    static var shared: EditorHost?   // tests start afresh
    /// The document an editor window shows now.
    static func shown(in window: NSWindow?) -> Editor? { window.flatMap { $0.windowController as? EditorHost }?.active }

    let tabbed: Bool
    private(set) var docs: [Editor] = []
    private(set) var active: Editor?
    private let strip = NSStackView(), body = NSView(), off = NSTextField(labelWithString: "")
    private let finalNewlineSwitch = NSSegmentedControl(labels: ["Final Newline"], trackingMode: .selectAny, target: nil, action: #selector(Editor.toggleFinalNewline(_:)))

    private init(tabbed: Bool) {
        self.tabbed = tabbed
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isRestorable = false   // the text never goes into the window's saved state on disk
        super.init(window: w)
        let content = NSView(frame: NSRect(origin: .zero, size: w.contentRect(forFrameRect: w.frame).size))
        let row: CGFloat = tabbed ? 30 : 0
        body.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - row)
        body.autoresizingMask = [.width, .height]
        content.addSubview(body)
        if tabbed { content.addSubview(tabRow(NSRect(x: 0, y: content.bounds.height - row, width: content.bounds.width, height: row))) }
        w.contentView = content
        finalNewlineSwitch.toolTip = "Saving ends the file with a newline (File ▸ Ensure Final Newline)"
        let bar = NSToolbar(identifier: "Editor " + UUID().uuidString)   // its own: same-named toolbars share their items
        bar.delegate = self
        bar.displayMode = .iconOnly
        w.toolbar = bar
        w.toolbarStyle = .unified
        w.delegate = self
        w.center()
        w.setFrameAutosaveName(tabbed ? "Editor" : "Tool Editor")   // two kinds of window, two places
        if tabbed {
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkpoint() }   // another app in front: what's typed is kept now
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A tool's file (or a test's): alone in its own window, not shown yet.
    @discardableResult convenience init(single e: Editor) {
        self.init(tabbed: false)
        add(e, show: false)
    }

    // MARK: Tabs

    /// A document in a tab of its own after the others, shown: the window comes up with it, the text in focus.
    func add(_ e: Editor, show: Bool = true) {
        e.host = self
        docs.append(e)
        select(e)
        if show { reveal(e) }
        changed()
    }

    func select(_ e: Editor) {
        guard e !== active || e.frame.superview == nil else { return }
        let leaving = active
        leaving?.frame.removeFromSuperview()
        active = e
        e.frame.frame = body.bounds
        e.frame.autoresizingMask = [.width, .height]
        body.addSubview(e.frame)   // the document's view controller joins the responder chain: ⌘S, Find… reach it
        window?.makeFirstResponder(e.focus)
        update(e)
        if let i = docs.firstIndex(where: { $0 === e }), strip.arrangedSubviews.indices.contains(i) { strip.arrangedSubviews[i].scrollToVisible(strip.arrangedSubviews[i].bounds) }
        if window?.isKeyWindow == true { e.shown() }
        if leaving != nil { checkpoint() }   // what was typed there, kept as it's left
    }

    /// Next / Previous Tab (⌃Tab, ⌃⇧Tab), round.
    func switchTab(by step: Int) {
        guard let a = active, let i = docs.firstIndex(where: { $0 === a }), docs.count > 1 else { return }
        select(docs[(i + step + docs.count) % docs.count])
    }

    /// Move Tab Left / Right.
    func moveTab(by step: Int) {
        guard let a = active, let i = docs.firstIndex(where: { $0 === a }), docs.indices.contains(i + step) else { return }
        docs.swapAt(i, i + step)
        showTabs()
        changed()
    }

    /// All Tabs…: every tab by name and place, filtered as typed.
    func allTabs() {
        guard let w = window else { return }
        Picker.show(over: w, placeholder: "Filter tabs", header: "\(docs.count) tab\(docs.count == 1 ? "" : "s")",
                    items: docs.map { e in Picker.Item(title: e.name, subtitle: e.heading.subtitle, badges: e.chips.map(\.image), id: e.id.uuidString) { [weak self] in self?.select(e) } },
                    select: active?.id.uuidString)
    }

    /// Show Editor: the window as it was; with no tabs, a new Untitled in it.
    func showEditor() {
        if let a = active { reveal(a) } else { Editor.untitled() }
    }

    /// The window in front with `e`'s tab chosen — before a question about it: a sheet on a window out of sight waits
    /// unseen (and the save behind it with it). A question up already over another tab: this one's asks after it, by name.
    @discardableResult func reveal(_ e: Editor) -> NSWindow {
        let w = window!
        if w.attachedSheet == nil, docs.contains(where: { $0 === e }) { select(e) }
        if w.isMiniaturized { w.deminiaturize(nil) }
        if !w.isKeyWindow || !w.isVisible { w.makeKeyAndOrderFront(nil) }
        w.listInWindowsMenu()
        if let note = notes.popLast() { e.flash(note) }
        return w
    }

    /// Close Tab (`Editor.closeAsking` asked first): gone once the session without it is written — Don't Save's draft
    /// with it. A failed write keeps the tab, its status line says why. A tool's window closes.
    func close(_ e: Editor) {
        guard tabbed, drafts != nil else { return remove(e) }
        Task {
            if let why = await commit(without: e) { return e.flash("Not closed: the editor's session couldn't be saved (\(why))") }
            remove(e)
        }
    }

    /// Without asking or writing anything (a tab that's closed, a test's cleanup).
    func remove(_ e: Editor) {
        guard let i = docs.firstIndex(where: { $0 === e }) else { return }
        docs.remove(at: i)
        e.frame.removeFromSuperview()
        e.closed()
        guard tabbed else { window?.close(); return }
        if e === active {
            active = nil
            if docs.isEmpty { window?.close() } else { select(docs[min(i, docs.count - 1)]) }   // its last tab: the window goes
        }
        showTabs()
        window?.isDocumentEdited = docs.contains(where: \.isEdited)
        changed()
    }

    /// ⎋ outside the find bar: back to the panels — an unchanged tab closes, a changed one stays as a draft, and the window
    /// hides. A tool's window closes, asking about changes.
    func escape(_ e: Editor) {
        guard tabbed else { e.closeAsking(); return }
        if e.isEdited { return hide() }
        Task {
            if drafts != nil, let why = await commit(without: e) { return e.flash("Not closed: the editor's session couldn't be saved (\(why))") }
            remove(e)
            if window?.isVisible == true { hide() }   // its last tab took the window with it
        }
    }

    /// Close Editor Window (⇧⌘W) and the window's close button: every tab's draft on the disk itself first, then the
    /// window goes — its documents stay (Show Editor, F4, ⌘N bring it back). Nothing's asked; a write that fails keeps
    /// the window, and says why. No document's `onClose` runs: that's for closing its tab.
    func hide() {
        guard drafts != nil else { window?.close(); return }   // drafts off: nothing's lost, the documents stay; Quit asks
        Task {
            if let why = await commit(durable: true, windowOpen: false) { return active?.flash("The window stays: the drafts couldn't be saved (\(why))") }
            window?.close()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if tabbed { hide() } else { docs.first?.closeAsking() }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) { active?.shown() }

    /// A tool's window closed: its document with it. The editor window only hides — its tabs stay.
    func windowWillClose(_ notification: Notification) {
        guard !tabbed else { return }
        let gone = docs
        (docs, active) = ([], nil)
        gone.forEach { $0.closed() }
    }

    /// Its tab, and the window's title, chips, toolbar and edited dot if it's the one shown.
    func update(_ e: Editor) {
        showTabs()
        window?.isDocumentEdited = docs.contains(where: \.isEdited)   // any tab: the close button's dot
        guard e === active, let w = window else { return }
        (w.title, w.subtitle) = e.heading
        w.representedURL = e.representedURL
        w.showChips(e.chips)
        finalNewlineSwitch.setSelected(e.finalNewline, forSegment: 0)
        let history = w.toolbar?.items.contains { $0.itemIdentifier == Self.historyID } == true
        if history != (e.server != nil), let bar = w.toolbar {   // a server's file has its history
            if history { bar.removeItem(at: bar.items.count - 1) } else { bar.insertItem(withItemIdentifier: Self.historyID, at: bar.items.count) }
        }
        w.listInWindowsMenu()   // a new title put the plain one back there
    }

    private func tabRow(_ r: NSRect) -> NSView {
        let row = NSView(frame: r)
        row.autoresizingMask = [.width, .minYMargin]
        let buttons: CGFloat = 54
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: r.width - buttons, height: r.height))
        scroll.autoresizingMask = [.width]
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false   // past ~118 pt a tab: they scroll, not squeeze (All Tabs… lists them)
        strip.orientation = .horizontal
        strip.spacing = 2
        strip.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        strip.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = strip
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            strip.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            strip.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
        ])
        row.addSubview(scroll)
        off.attributedStringValue = Chip.plain("Drafts off")
        off.toolTip = "Drafts aren't kept: closing and quitting ask to save"
        off.isHidden = true
        off.sizeToFit()
        off.frame.origin = NSPoint(x: r.width - buttons - off.frame.width - 6, y: (r.height - off.frame.height) / 2)
        off.autoresizingMask = [.minXMargin]
        row.addSubview(off)
        for (i, (symbol, tip, action)) in [(Symbol.plus, "New Editor Document  ⌘N", #selector(newTab)), (.collapse, "All Tabs…", #selector(listTabs))].enumerated() {
            let b = NSButton(image: symbol.image(tip), target: self, action: action)
            b.isBordered = false
            b.refusesFirstResponder = true
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = tip
            b.frame = NSRect(x: r.width - buttons + CGFloat(i) * 26, y: 3, width: 24, height: r.height - 6)
            b.autoresizingMask = [.minXMargin]
            row.addSubview(b)
        }
        let rule = NSBox(frame: NSRect(x: 0, y: 0, width: r.width, height: 1))
        rule.boxType = .separator
        rule.autoresizingMask = [.width]
        row.addSubview(rule)
        return row
    }

    @objc private func newTab() { Editor.untitled() }
    @objc private func listTabs() { allTabs() }
    @objc private func tabClicked(_ b: NSButton) {
        guard docs.indices.contains(b.tag) else { return }
        select(docs[b.tag])
        docs[b.tag].connect()   // a click: a parked server tab opens
    }
    @objc private func closeTabClicked(_ b: NSButton) { if docs.indices.contains(b.tag) { docs[b.tag].closeAsking() } }

    /// The tab buttons: a mark before each name (● changed, ↑ not uploaded, ! its draft not saved), its server's chips;
    /// a name two tabs share says where each is.
    private func showTabs() {
        guard tabbed else { return }
        off.isHidden = draftsOff == nil
        strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let names = docs.map(\.name)
        for (i, e) in docs.enumerated() {
            let lead = NSMutableAttributedString()
            if let m = e.mark { lead.append(m) }
            if let c = Chip.text(e.chips) { if lead.length > 0 { lead.append(NSAttributedString(string: " ")) }; lead.append(c) }
            let b = PanelViewController.tabButton(tabTitle(e, among: names).bidiVisible, lead: lead.length > 0 ? lead : nil, tint: Chip.tint(e.chips), tip: e.tip, index: i,
                                                  current: e === active, target: self, action: #selector(tabClicked(_:)), close: #selector(closeTabClicked(_:)),
                                                  italic: e.cover != nil)
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 118).isActive = true
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
            strip.addArrangedSubview(b)
        }
    }

    /// Its name; one another tab has too, with its server or folder after it ("nginx.conf — web-01").
    func tabTitle(_ e: Editor, among names: [String]? = nil) -> String {
        (names ?? docs.map(\.name)).filter { $0 == e.name }.count > 1 ? e.name + " — " + e.whereShort : e.name
    }

    // MARK: Toolbar: what there is to switch for the file shown

    private static let newlineID = NSToolbarItem.Identifier("finalNewline"), historyID = NSToolbarItem.Identifier("history")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.newlineID] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.newlineID, Self.historyID] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == Self.newlineID {
            (item.view, item.label) = (finalNewlineSwitch, "Final Newline")   // to the shown document, by the responder chain
        } else {
            let b = NSButton(title: "Server File History…", target: self, action: #selector(showHistory))
            b.bezelStyle = .toolbar
            (item.view, item.label) = (b, "Server File History")
        }
        return item
    }

    /// Server ▸ File History…, for the shown tab's file.
    @objc private func showHistory() { (NSApp.delegate as? AppDelegate)?.run("server.history") }

    // MARK: Drafts

    /// A server file's Save and closing (`AppDelegate.remoteEditing`): its server, path there, state, and the folder of
    /// its local copy.
    typealias OnServer = (SFTPTarget, String, AppDelegate.RemoteEdit, String) -> (onSaved: @MainActor (URL) -> Void, onClose: @MainActor () -> Void)

    /// Launch: the editor's session as it was — its tabs in order (a server's parked: nothing connects), their drafts, the
    /// shown one, the window if it was up. Another Kermo keeping the drafts, or a newer one's: none kept this time, and
    /// the window says so; one that couldn't be read is moved aside, said once, and the editor starts empty.
    static func restore(_ dir: String, onServer: OnServer) {
        let h = tabs
        let opened: (store: DraftStore, session: EditorSession, damaged: String?)
        do { opened = try DraftStore.open(dir) } catch {
            h.draftsOff = switch error {
                case DraftStore.Failure.locked: "another Kermo keeps them"
                case DraftStore.Failure.newer: "saved by a newer Kermo"
                default: why(error)
            }
            return h.showTabs()
        }
        h.drafts = opened.store
        if let damaged = opened.damaged {
            let a = NSAlert(), buttons = ["OK", "Show in Finder"]
            a.messageText = "Kermo couldn't read the editor's session"
            a.informativeText = "Its drafts are kept in \((damaged as NSString).abbreviatingWithTildeInPath). The editor starts empty."
            buttons.forEach { a.addButton(withTitle: $0) }
            if (AppDelegate.answering.map { $0(a.messageText, buttons, 0) } ?? AppDelegate.modal(a)) == 1 {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: damaged)])
            }
        }
        for d in opened.session.docs {
            let e = Editor(restoring: d, onServer: onServer)
            e.host = h
            h.docs.append(e)
            Task { await e.restore(d, from: opened.store) }   // each on its own: a slow file or share holds up no other tab
        }
        if let e = h.docs.first(where: { $0.id == opened.session.active }) ?? h.docs.first { h.select(e) }
        h.showTabs()
        if opened.session.windowOpen, let a = h.active { h.reveal(a) }
    }

    /// A restored tab that can't come back (its file is gone): closed, and said in the window.
    func drop(_ e: Editor, saying note: String) {
        remove(e)
        if window?.isVisible == true, let a = active { a.flash(note) } else { notes.append(note) }
    }

    /// Where the tabs' drafts go; nil: none kept (`draftsOff` says why, or a test's window).
    private(set) var drafts: DraftStore?
    /// Why drafts aren't kept this time (another Kermo keeps them, a newer one wrote them): closing and quitting ask.
    private(set) var draftsOff: String?
    /// Said once the window shows (a restored tab that couldn't come back).
    private var notes: [String] = []
    private var due: (since: Date, item: DispatchWorkItem)?, retry: DispatchWorkItem?
    private var lastDurable = Date.distantPast, submitted = 0, applied = 0

    /// A text or a tab changed: a commit once typing pauses, and while it goes on at most `most` after the first change
    /// since the last commit — later for a big text (it's written whole each time). `now`: right away (a Save).
    func changed(_ e: Editor? = nil, now: Bool = false) {
        guard tabbed, drafts != nil else { return }
        if now { return checkpoint() }
        let (pause, most) = DraftStore.delay(forBytes: e?.textView.textStorage?.length ?? 0)
        let since = due?.since ?? Date()
        due?.item.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkpoint() } }
        due = (since, item)
        DispatchQueue.main.asyncAfter(deadline: .now() + min(pause, max(0, most - Date().timeIntervalSince(since))), execute: item)
    }

    /// A commit now, not waited for.
    func checkpoint() { if tabbed, drafts != nil { Task { await commit() } } }

    /// Writes the session — the tabs in order, the shown one, the window's state — with the texts changed since the last
    /// commit, and says why if it couldn't. The texts are taken here on the main thread; the store writes them in its
    /// own queue, one commit after another, a newer one never under an older. `durable`: on the disk itself (hiding the
    /// window, quitting), and no more than every 30 s otherwise. `without`: a tab closing — kept until this is written.
    @discardableResult func commit(durable: Bool = false, windowOpen: Bool? = nil, without: Editor? = nil) async -> String? {
        guard let store = drafts else { return nil }
        due?.item.cancel()
        due = nil
        let durable = durable || Date().timeIntervalSince(lastDurable) >= 30
        if durable { lastDurable = Date() }
        var s = EditorSession(), texts: [UUID: String] = [:], sent: [(Editor, Int)] = []
        s.windowOpen = windowOpen ?? (window?.isVisible == true)
        s.active = (active === without ? nil : active)?.id
        for e in docs where e !== without {
            guard let d = e.sessionDoc else { continue }
            s.docs.append(d)
            if !d.dirty { e.sent = -1 }   // its revision goes: once it changes again, the whole text
            else if e.sent != e.edits, let text = e.draftText { (texts[e.id], e.sent) = (text, e.edits) }
            sent.append((e, e.sent))
        }
        store.submit(s, texts: texts, durable: durable)
        submitted += 1
        let ticket = submitted
        var why: String?
        do { try await store.flush() } catch { why = Self.why(error) }
        guard ticket > applied else { return why }   // a newer commit's answer came first: it says what's on disk
        applied = ticket
        let now = Date(), marks = docs.map { $0.mark?.string }
        for (e, gen) in sent {
            if why == nil { (e.onDisk, e.draftFailed, e.draftSaved) = (gen, nil, gen >= 0 ? now : nil) }
            else if e.onDisk != gen { e.draftFailed = why }
            e.sayState()
        }
        retry?.cancel()
        if why != nil {   // again at the next change, and at least every 30 s
            let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkpoint() } }
            retry = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
        }
        if docs.map({ $0.mark?.string }) != marks { showTabs() }   // a "!" came or went: not every few seconds while typing
        return why
    }

    /// "the disk is full": why a draft wasn't written, as a status line says it.
    static func why(_ error: Error) -> String {
        let ns = error as NSError, posix = ns.domain == NSPOSIXErrorDomain ? ns : ns.userInfo[NSUnderlyingErrorKey] as? NSError
        switch posix.map({ Int32($0.code) }) {
        case ENOSPC?, EDQUOT?: return "the disk is full"
        case EROFS?: return "the disk is read-only"
        case EACCES?, EPERM?: return "no permission to write there"
        default: return ns.localizedDescription
        }
    }
}
