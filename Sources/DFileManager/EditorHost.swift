import AppKit
import DFMCore

/// The window an editor's documents show in. The editor window (`tabs`): a tab per document, kept between launches with
/// their drafts (`DraftStore`, `editor.noindex`), and closing it only hides it. Or a tool's file alone in a window of its
/// own, which closes as it always did.
@MainActor
final class EditorHost: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate {
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
    private let strip = NSStackView(), body = NSView(), off = NSTextField(labelWithString: ""), row = TabRow()
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
        guard let a = active, let i = docs.firstIndex(where: { $0 === a }) else { return }
        moveTab(from: i, to: i + step)
    }

    /// A tab to another place in the strip (Move Tab, a drag): the session keeps the order.
    func moveTab(from i: Int, to j: Int) {
        guard i != j, docs.indices.contains(i), docs.indices.contains(j) else { return }
        docs.insert(docs.remove(at: i), at: j)
        showTabs()
        changed()
    }

    /// Close Other Tabs / Close Tabs to the Right of `e`: one after another, a changed one asking as ⌘W does — its
    /// Cancel (or a Save that didn't go through) keeps it and the rest. `e` is shown after.
    func closeOthers(than e: Editor) { close(docs.filter { $0 !== e }, then: e) }
    func closeRight(of e: Editor) { if let i = docs.firstIndex(where: { $0 === e }) { close(Array(docs[(i + 1)...]), then: e) } }
    private func close(_ tabs: [Editor], then e: Editor) {
        Task {
            for t in tabs where docs.contains(where: { $0 === t }) { guard await t.closeAsked() else { return } }
            if docs.contains(where: { $0 === e }) { select(e) }
        }
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
        let back = e.reopenable   // before the commit drops its draft
        guard tabbed, drafts != nil else { return remove(e, back) }
        Task {
            if let why = await commit(closing: e) { return e.flash("Not closed: the editor's session couldn't be saved (\(why))") }
            remove(e, back)
        }
    }

    /// Without asking or writing anything (a tab that's closed, a test's cleanup). `back`: what ⇧⌘T brings back of it.
    func remove(_ e: Editor, _ back: (doc: EditorSession.Doc, text: String?)? = nil) {
        closing.remove(ObjectIdentifier(e))
        guard let i = docs.firstIndex(where: { $0 === e }) else { return }
        if tabbed, let back { closedTabs = Array((closedTabs + [(back.doc, back.text, i)]).suffix(20)) }
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
        let back = e.reopenable
        Task {
            if drafts != nil, let why = await commit(closing: e) { return e.flash("Not closed: the editor's session couldn't be saved (\(why))") }
            remove(e, back)
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
        row.frame = r
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
        row.scroll = scroll
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
    @objc func tabClicked(_ b: NSButton) {
        guard docs.indices.contains(b.tag) else { return }
        select(docs[b.tag])
        docs[b.tag].connect()   // a click: a parked server tab opens
    }
    @objc private func closeTabClicked(_ b: NSButton) { if docs.indices.contains(b.tag) { docs[b.tag].closeAsking() } }

    /// A tab dragged to `p` (in the window): it moves once the pointer is past a neighbour's middle — the strip is made
    /// anew then, not at every move. Its index now.
    func drag(_ i: Int, to p: NSPoint) -> Int {
        let tabs = strip.arrangedSubviews, x = strip.convert(p, from: nil).x
        guard tabs.count == docs.count, docs.indices.contains(i) else { return i }
        let j = tabs.indices.filter { $0 != i && tabs[$0].frame.midX < x }.count
        moveTab(from: i, to: j)
        strip.layoutSubtreeIfNeeded()
        return j
    }

    /// The mouse on the strip besides a click and a drag (`EditorTab`, `TabRow`): the middle button closes a tab as ⌘W
    /// does, a double-click past the tabs opens a new Untitled.
    func middleClicked(_ i: Int) { if docs.indices.contains(i) { docs[i].closeAsking() } }
    func doubleClickedPastTabs() { Editor.untitled() }

    /// A tab's menu, made as it opens (right click, ⌃-click, VoiceOver's Show Menu).
    func tabMenu(for e: Editor) -> [NSMenuItem] {
        let i = docs.firstIndex { $0 === e } ?? docs.count
        let items: [(String, Bool, @MainActor () -> Void)] = [
            ("Close Tab", true, { e.closeAsking() }),
            ("Close Other Tabs", docs.count > 1, { [weak self] in self?.closeOthers(than: e) }),
            ("Close Tabs to the Right", i < docs.count - 1, { [weak self] in self?.closeRight(of: e) }),
            ("", false, {}),
            ("Rename…", true, { [weak self] in self?.beginRename(e) }),
            ("Copy Path", e.copyablePath != nil, { e.copyPath() }),
            ("Reveal in Panel", e.revealable, { Editor.app()?.revealInPanel(e) }),
        ]
        return items.map { title, on, run in
            guard !title.isEmpty else { return .separator() }
            let it = MenuAction.item(title, run)
            it.isEnabled = on
            return it
        }
    }

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
                                                  italic: e.cover != nil, button: EditorTab(host: self))
            let menu = LiveMenu(title: e.name) { [weak self, weak e] in e.flatMap { self?.tabMenu(for: $0) } ?? [] }
            menu.autoenablesItems = false
            b.menu = menu
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: min(260, max(118, b.intrinsicContentSize.width + 12))).isActive = true   // the × clear of a bold name
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
            strip.addArrangedSubview(b)
        }
    }

    /// Its name; one another tab has too, with its server or folder after it ("nginx.conf — web-01").
    func tabTitle(_ e: Editor, among names: [String]? = nil) -> String {
        (names ?? docs.map(\.name)).filter { $0 == e.name }.count > 1 && !e.whereShort.isEmpty ? e.name + " — " + e.whereShort : e.name   // Untitleds named alike: no place to say
    }

    // MARK: Rename on the tab

    /// The name field over a tab being renamed, and its document.
    private var renaming: (e: Editor, field: NSTextField)?

    /// Rename… (a double-click on its tab, its menu, ⇧F6): a field over its tab, the name's base selected as Finder does —
    /// a locked server's after Touch ID. ↩ renames; ⎋ or a click elsewhere leaves it as it was.
    func beginRename(_ e: Editor) {
        if let why = e.renameRefusal { return e.flash(why) }
        guard tabbed, renaming == nil else { return }
        guard let s = e.server, e.cover == .locked || ServerLock.needsUnlock(s.target) else { return showRenameField(e) }
        Task {
            guard await ServerLock.authorize(s.target, "rename a file on") else { return }
            e.connect()   // its draft shows too: unlocked now, nothing asked again
            showRenameField(e)
        }
    }

    private func showRenameField(_ e: Editor) {
        select(e)
        guard renaming == nil, let i = docs.firstIndex(where: { $0 === e }), strip.arrangedSubviews.indices.contains(i) else { return }
        let tab = strip.arrangedSubviews[i], r = row.convert(tab.bounds, from: tab)
        let field = NSTextField(string: e.name)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.delegate = self
        let width = min(max(r.width, min(300, field.intrinsicContentSize.width + 24)), row.bounds.width)   // the tab's at least, ~300 at most
        field.frame = NSRect(x: max(0, min(r.minX, row.bounds.width - width)), y: r.midY - 11, width: width, height: 22)
        row.addSubview(field)
        renaming = (e, field)
        window?.makeFirstResponder(field)
        let base = (e.name as NSString).deletingPathExtension   // "nginx.conf": "nginx", as Finder selects it
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base.isEmpty ? e.name : base).utf16.count)
    }

    /// The field over the tab being renamed (tests).
    var renameField: NSTextField? { renaming?.field }

    /// The field gone, the text in focus again; `name`: ↩'s, renamed to.
    func endRename(_ name: String?) {
        guard let (e, field) = renaming else { return }
        renaming = nil
        if active === e { window?.makeFirstResponder(e.focus) }
        field.removeFromSuperview()
        if let name { Task { await e.rename(to: name) } }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === renaming?.field else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): endRename((control as? NSTextField)?.stringValue)
        case #selector(NSResponder.cancelOperation(_:)): endRename(nil)
        default: return false
        }
        return true
    }

    /// A click elsewhere, Tab: as it was — only ↩ renames (on a server, production's too, a stray click changes nothing).
    func controlTextDidEndEditing(_ n: Notification) { if n.object as? NSTextField === renaming?.field { endRename(nil) } }

    // MARK: Reopen

    /// Tabs closed, the last one last (⇧⌘T): each as the session kept it, its changes' text if it had any — in memory
    /// only, gone at Quit — and where it was.
    private var closedTabs: [(doc: EditorSession.Doc, text: String?, at: Int)] = []

    /// ⇧⌘T: the tab closed last, back where it was with its caret — this Mac's file as it is now, a server's parked
    /// (nothing connects), a Don't Save's text as it was. Its file open meanwhile: that tab is chosen. None: a beep.
    func reopenClosed() {
        guard let c = closedTabs.popLast() else { return NSSound.beep() }
        let open = c.doc.server.flatMap { s in Editor.editing(s.target.asRoot(s.root), s.path) }
            ?? c.doc.path.flatMap { p in docs.first { $0.server == nil && $0.url?.standardizedFileURL.path == URL(fileURLWithPath: p).standardizedFileURL.path } }
        if let open { reveal(open); return }
        let e = Editor(restoring: c.doc, draft: c.text != nil, onServer: onServer)
        e.host = self
        docs.insert(e, at: min(c.at, docs.count))
        reveal(e)
        changed()
        Task { await e.reopen(c.doc, text: c.text) }
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
    /// The launch's (`remoteEditing`; tests' own): a renamed server file's, and one ⇧⌘T brings back.
    private(set) var onServer: OnServer = { t, path, state, dir in
        guard let app = Editor.app() else { return ({ _ in }, {}) }
        return app.remoteEditing(t, path, state, in: dir)
    }

    /// Launch: the editor's session as it was — its tabs in order (a server's parked: nothing connects), their drafts, the
    /// shown one, the window if it was up. Another Kermo keeping the drafts, or a newer one's: none kept this time, and
    /// the window says so; one that couldn't be read is moved aside, said once, and the editor starts empty.
    static func restore(_ dir: String, onServer: @escaping OnServer) {
        let h = tabs
        h.onServer = onServer
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
    /// Tabs being closed: no commit names them again (a Don't Save mustn't come back by a commit that overtook its own).
    private var closing: Set<ObjectIdentifier> = []

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
    /// window, quitting), and no more than every 30 s otherwise. `closing`: a tab that goes once this is written — left
    /// out of every commit from now on, and back in if this one fails.
    @discardableResult func commit(durable: Bool = false, windowOpen: Bool? = nil, closing gone: Editor? = nil) async -> String? {
        guard let store = drafts else { return nil }
        if let gone { closing.insert(ObjectIdentifier(gone)) }
        due?.item.cancel()
        due = nil
        let durable = durable || Date().timeIntervalSince(lastDurable) >= 30
        if durable { lastDurable = Date() }
        var s = EditorSession(), texts: [UUID: String] = [:], sent: [(Editor, Int)] = []
        s.windowOpen = windowOpen ?? (window?.isVisible == true)
        let kept = docs.filter { !closing.contains(ObjectIdentifier($0)) }
        s.active = active.flatMap { a in kept.contains { $0 === a } ? a.id : nil }
        for e in kept {
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
        if why != nil, let gone {   // not closed: named again, its whole text with it (a commit that went meanwhile left it out)
            closing.remove(ObjectIdentifier(gone))
            gone.sent = -1
            checkpoint()
        }
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
        switch posix(error) {
        case ENOSPC?, EDQUOT?: return "the disk is full"
        case EROFS?: return "the disk is read-only"
        case EACCES?, EPERM?: return "no permission to write there"
        default: return error.localizedDescription
        }
    }

    /// The errno an error is, or wraps (Foundation's file errors carry it underneath).
    nonisolated static func posix(_ error: Error) -> Int32? {
        let ns = error as NSError
        return (ns.domain == NSPOSIXErrorDomain ? ns : ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { Int32($0.code) }
    }
}

/// The editor window's row of tabs: a double-click past them opens a new Untitled.
private final class TabRow: NSView {
    weak var scroll: NSScrollView?
    override func mouseDown(with e: NSEvent) { if e.clickCount == 2 { (window?.windowController as? EditorHost)?.doubleClickedPastTabs() } }
    /// Clicks past the tabs (the strip's background, its scroll view) are the row's; the wheel still scrolls the tabs.
    override func hitTest(_ p: NSPoint) -> NSView? {
        let v = super.hitTest(p)
        return v is NSClipView || v is NSScrollView || v is NSStackView ? self : v
    }
    override func scrollWheel(with e: NSEvent) { scroll?.scrollWheel(with: e) }
}

/// A tab of the editor window: chosen on the press (a parked one opens), dragged along the strip, renamed by a
/// double-click; the middle button closes it.
private final class EditorTab: NSButton {
    private weak var host: EditorHost?
    convenience init(host: EditorHost) {
        self.init(frame: .zero)
        self.host = host
    }

    override func mouseDown(with e: NSEvent) {
        guard let host, let window, host.docs.indices.contains(tag) else { return super.mouseDown(with: e) }
        if e.clickCount == 2 { return host.beginRename(host.docs[tag]) }   // the first click chose it
        var at = tag, dragged = false
        host.tabClicked(self)   // the strip is made anew: this button leaves it
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            dragged = dragged || abs(next.locationInWindow.x - e.locationInWindow.x) > 4
            if dragged { at = host.drag(at, to: next.locationInWindow) }
        }
    }

    override func otherMouseDown(with e: NSEvent) { if e.buttonNumber != 2 { super.otherMouseDown(with: e) } }
    override func otherMouseUp(with e: NSEvent) {
        guard e.buttonNumber == 2, let host, bounds.contains(convert(e.locationInWindow, from: nil)) else { return super.otherMouseUp(with: e) }
        host.middleClicked(tag)
    }
}
