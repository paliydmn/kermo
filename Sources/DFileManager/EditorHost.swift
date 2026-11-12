import AppKit
import DFMCore

/// The window an editor's documents show in. The editor window (`tabs`): a tab per document, kept between launches with
/// their drafts (`DraftStore`, `editor.noindex`), and closing it only hides it — split in two panes if asked (⌘\), each
/// with its tabs; a document in both is one document, two views of it. Or a tool's file alone in a window of its own,
/// which closes as it always did.
@MainActor
final class EditorHost: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate, NSSplitViewDelegate {
    /// The editor window, made at first use (one for now).
    static var tabs: EditorHost {
        if let shared { return shared }
        let h = EditorHost(tabbed: true)
        shared = h
        return h
    }
    static var shared: EditorHost?   // tests start afresh
    /// The document an editor window shows now: its active pane's.
    static func shown(in window: NSWindow?) -> Editor? { window.flatMap { $0.windowController as? EditorHost }?.active }

    /// A pane of the window: its tabs in order, the one it shows, its strip.
    @MainActor final class Pane {
        var docs: [Editor] = []
        var active: Editor?
        let strip = NSStackView(), body = NSView(), box = NSView(), off = NSTextField(labelWithString: "")
        let row = TabRow()
    }

    let tabbed: Bool
    /// One, or two side by side or one above the other (`split.isVertical`).
    private(set) var panes: [Pane] = []
    /// The pane the keys go to: the window's title, toolbar and chips are its tab's.
    private(set) var pane: Pane!
    private let split = NSSplitView()
    /// Every document once, in its panes' order.
    var docs: [Editor] {
        var seen = Set<ObjectIdentifier>()
        return panes.flatMap(\.docs).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
    /// The active pane's tab shown.
    var active: Editor? { pane?.active }
    private let finalNewlineSwitch = NSSegmentedControl(labels: ["Final Newline"], trackingMode: .selectAny, target: nil, action: #selector(Editor.toggleFinalNewline(_:)))

    private init(tabbed: Bool) {
        self.tabbed = tabbed
        let w = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isRestorable = false   // the text never goes into the window's saved state on disk
        super.init(window: w)
        let content = NSView(frame: NSRect(origin: .zero, size: w.contentRect(forFrameRect: w.frame).size))
        split.frame = content.bounds
        split.autoresizingMask = [.width, .height]
        (split.isVertical, split.dividerStyle, split.delegate) = (true, .thin, self)
        content.addSubview(split)
        w.contentView = content
        pane = addPane()
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

    // MARK: Panes

    @discardableResult private func addPane() -> Pane {
        let p = Pane(), size = split.bounds.size, row: CGFloat = tabbed ? 30 : 0
        p.box.frame = NSRect(origin: .zero, size: size)
        p.body.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - row)
        p.body.autoresizingMask = [.width, .height]
        p.box.addSubview(p.body)
        if tabbed { p.box.addSubview(tabRow(p, NSRect(x: 0, y: size.height - row, width: size.width, height: row))) }
        panes.append(p)
        split.addSubview(p.box)
        return p
    }

    /// The pane `e` shows in: the active one if it's there.
    func place(of e: Editor) -> Pane? { pane.docs.contains { $0 === e } ? pane : panes.first { $0.docs.contains { $0 === e } } }
    /// Shown in a pane, whichever.
    func shows(_ e: Editor) -> Bool { panes.contains { $0.active === e } }

    /// The pane besides `p` — made beside it (`vertical`) or under it if there's one only, half the window each.
    private func other(than p: Pane, vertical: Bool? = nil) -> Pane {
        if let q = panes.first(where: { $0 !== p }) { return q }
        split.isVertical = vertical ?? split.isVertical
        let q = addPane()
        split.adjustSubviews()
        split.setPosition((split.isVertical ? split.bounds.width : split.bounds.height) / 2, ofDividerAt: 0)
        minimumSize()
        return q
    }

    /// Two panes side by side are each at least `minPane` wide (D-201): the window can't be made narrower.
    private func minimumSize() {
        window?.contentMinSize.width = panes.count > 1 && split.isVertical ? 2 * Self.minPane + split.dividerThickness : 0
    }

    /// An emptied pane goes: the other has the window.
    private func removePane(_ p: Pane) {
        guard panes.count > 1 else { return }
        panes.removeAll { $0 === p }
        p.box.removeFromSuperview()
        split.adjustSubviews()
        minimumSize()
        if pane === p { activate(panes[0]) }
    }

    /// `p` gets the keys: its tab's text in focus, the window's title, toolbar and chips its tab's.
    private func activate(_ p: Pane) {
        pane = p
        guard let e = p.active else { return showTabs() }
        e.current = e.view(in: p)
        window?.makeFirstResponder(e.focus)
        update(e)
        if window?.isKeyWindow == true { e.shown() }
    }

    /// The keys moved (a click in a pane's text, its find bar, its cover): that pane is the active one, its tab's view
    /// the current one.
    fileprivate func keysMoved() {
        var v = window?.firstResponder as? NSView
        if let t = v as? NSText, t.isFieldEditor { v = t.delegate as? NSView }   // a field's: the field
        guard let v, let p = panes.first(where: { v.isDescendant(of: $0.body) }), let e = p.active, let shown = e.views.first(where: { $0.pane === p }) else { return }
        e.current = shown
        guard p !== pane else { return }
        pane = p
        update(e)
        if window?.isKeyWindow == true { e.shown() }
    }

    /// Split Editor Right / Down (⌘\, ⇧⌘\): the tab shown, cloned into a second pane beside or under this one, as VS
    /// Code splits; with two already, the keys go to the other.
    func split(vertical: Bool) {
        guard tabbed, let e = active else { return NSSound.beep() }
        if panes.count > 1 { return activate(other(than: pane)) }
        clone(e, vertical: vertical)
    }

    /// Clone to Other Pane: `e` shows there too, at `at` (else after its tabs) — the same document, a view of its own;
    /// there already: chosen.
    func clone(_ e: Editor, from p: Pane? = nil, at: Int? = nil, vertical: Bool? = nil) {
        guard tabbed, let p = p ?? place(of: e) else { return }
        let q = other(than: p, vertical: vertical)
        if !q.docs.contains(where: { $0 === e }) { q.docs.insert(e, at: min(at ?? q.docs.count, q.docs.count)) }
        select(e, in: q)
        changed()
    }

    /// Move to Other Pane: `e`'s tab goes there, at `at` (else after its tabs), with its view — caret, scroll, find
    /// bar; there already (a clone): the two are one tab there. A window's only tab stays.
    func move(_ e: Editor, from p: Pane? = nil, at: Int? = nil) {
        guard tabbed, let p = p ?? place(of: e) else { return }
        guard panes.count > 1 || p.docs.count > 1 else { return NSSound.beep() }
        let q = other(than: p)
        if q.docs.contains(where: { $0 === e }) {
            detach(e, from: p)
        } else {
            let v = e.view(in: p)
            detach(e, from: p, keep: true)
            v.pane = q
            q.docs.insert(e, at: min(at ?? q.docs.count, q.docs.count))
        }
        select(e, in: q)
        changed()
    }

    /// Join Panes: the second pane's tabs after the first's — a clone's two are one tab — and one pane again.
    func joinPanes() {
        guard panes.count > 1 else { return NSSound.beep() }
        let (p, q, shown) = (panes[0], panes[1], active)
        for e in q.docs {
            if p.docs.contains(where: { $0 === e }) { e.dropView(in: q); continue }
            e.views.first { $0.pane === q }.map { $0.frame.removeFromSuperview(); $0.pane = p }
            p.docs.append(e)
        }
        q.docs = []
        removePane(q)
        if let shown { select(shown, in: p) }
        changed()
    }

    /// ⌥⌘← → between panes side by side, ↑ ↓ between panes one above the other.
    func focusPane(by d: Int, vertical: Bool) {
        guard panes.count > 1, split.isVertical == vertical, let i = panes.firstIndex(where: { $0 === pane }), panes.indices.contains(i + d) else { return NSSound.beep() }
        activate(panes[i + d])
    }

    /// ⌃⌘ arrows: the divider that way by a twentieth of the window, never closer than `minPane` to its edge.
    func resizePane(by d: Int, vertical: Bool) {
        guard panes.count > 1, split.isVertical == vertical else { return NSSound.beep() }
        let size = vertical ? split.bounds.width : split.bounds.height, at = vertical ? panes[0].box.frame.maxX : panes[0].box.frame.maxY
        split.setPosition(min(max(at + CGFloat(d) * size / 20, Self.minPane), size - Self.minPane), ofDividerAt: 0)
    }

    private static let minPane: CGFloat = 160
    func splitView(_ s: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { p + Self.minPane }
    func splitView(_ s: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { p - Self.minPane }

    /// The first pane's share of the window, as the session keeps it.
    private var share: Double {
        let whole = split.isVertical ? split.bounds.width : split.bounds.height
        return whole > 0 ? Double((split.isVertical ? panes[0].box.frame.width : panes[0].box.frame.height) / whole) : 0.5
    }

    // MARK: Compare

    /// The two views compared now (`Comparison`); nil: none.
    private(set) var comparison: Comparison?

    /// Compare `old` with `new` side by side: a document already in a pane stays there — `new`'s first, the one typed
    /// in — and the other side goes to the other pane, made beside if there's one (panes one above the other are put
    /// side by side). A document in that pane already is chosen there; one in this pane only is shown there too (a
    /// view of the same document). `snapshots`: read-only copies made for it, new tabs, closed when it ends. The keys
    /// go to the document.
    func compare(old a: Editor, new b: Editor, snapshots: [Editor] = []) {
        guard tabbed, a !== b else { return }
        stopComparing()
        if panes.count > 1, !split.isVertical {
            split.isVertical = true
            split.adjustSubviews()
            split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
            minimumSize()
        }
        let (qb, qa): (Pane, Pane)
        if let p = place(of: b) { (qb, qa) = (p, place(of: a).flatMap { $0 === p ? nil : $0 } ?? other(than: p, vertical: true)) }
        else if let p = place(of: a) { (qa, qb) = (p, other(than: p, vertical: true)) }
        else { (qa, qb) = (pane, other(than: pane, vertical: true)) }
        for (e, p) in [(a, qa), (b, qb)] where !p.docs.contains(where: { $0 === e }) {
            e.host = self
            p.docs.append(e)
        }
        show(a, in: qa)
        show(b, in: qb)
        comparison = Comparison(old: a.view(in: qa), new: b.view(in: qb), snapshots: snapshots, host: self)
        let keys = b.snapshot == nil || a.snapshot != nil ? b : a
        activate(keys === b ? qb : qa)
        comparison?.start()
        reveal(keys)
        if window?.isKeyWindow == true { [a, b].forEach { $0.shown() } }   // the pane without the keys: its colors too
        changed()
    }

    /// Stop Comparing, and its end by a side closed or moved, Join Panes: plain views again, its copies closed.
    func stopComparing() {
        guard let c = comparison else { return }
        comparison = nil
        c.stop()
    }

    /// A read-only copy's tab given to `doc` (Edit, its file open in another tab already): the comparison goes on with it.
    func replace(_ copy: Editor, with doc: Editor) {
        guard let p = place(of: copy), let i = p.docs.firstIndex(where: { $0 === copy }) else { return }
        if !p.docs.contains(where: { $0 === doc }) { p.docs.insert(doc, at: i + 1) }
        comparison?.replace(copy, with: doc, in: p)
        select(doc, in: p)
        remove(copy)
        comparison?.start()
    }

    /// Compare With… (⇧⌘D in the editor window): the shown tab against the other pane's shown tab (first), another tab,
    /// its file as saved now (on disk, or its server's), or the clipboard's text as it is then.
    func compareWith() {
        guard let w = window, let e = active, e.snapshot == nil else { return NSSound.beep() }
        let there = panes.first { $0 !== pane }?.active
        var tabs = docs.filter { $0 !== e && $0.snapshot == nil && !($0.url == nil && $0.server == nil && $0.storage.length == 0) }
        if let t = there, let i = tabs.firstIndex(where: { $0 === t }) { tabs.insert(tabs.remove(at: i), at: 0) }
        var items = tabs.map { t in
            Picker.Item(title: t.name, subtitle: t === there ? "The other pane" : t.heading.subtitle, badges: t.chips.map(\.image)) { [weak self] in self?.compare(old: t, new: e) }
        }
        if let s = e.server {
            items.append(Picker.Item(title: "Saved Version", subtitle: "\(SavedServer.name(for: s.target)), now") {
                Task { await Editor.app()?.compare(.file(.init(path: s.path, server: s.target, look: true, now: true)), .doc(e)) }
            })
        } else if let url = e.url {
            items.append(Picker.Item(title: "Saved Version", subtitle: "On disk, now") {
                Task { await Editor.app()?.compare(.file(.init(path: url.path, now: true)), .doc(e)) }
            })
        }
        if let clip = NSPasteboard.general.string(forType: .string) {
            let lines = clip.split(separator: "\n", omittingEmptySubsequences: false).count - (clip.hasSuffix("\n") ? 1 : 0)
            items.append(Picker.Item(title: "Clipboard", subtitle: lines == 1 ? "1 line" : "\(lines) lines") { [weak self] in self?.compareClipboard(with: e) })
        }
        guard !items.isEmpty else { return e.flash("Nothing to compare “\(e.name)” with: no other tab, saved version or text on the clipboard") }
        Picker.show(over: w, placeholder: "Compare “\(e.name)” with…", header: "Compare With", items: items)
    }

    /// The clipboard's text as it is now, a read-only copy against `e` — in memory only.
    func compareClipboard(with e: Editor) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return NSSound.beep() }
        let at = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        let copy = Editor.snapshot((text, .utf8, false, false, false, nil, Editor.sha(Data())), file: e.url?.lastPathComponent ?? e.server.map { ($0.path as NSString).lastPathComponent },
                                   title: "Clipboard \(at)", place: "the clipboard at \(at)")
        compare(old: copy, new: e, snapshots: [copy])
    }

    // MARK: Tabs

    /// A document in a tab of its own after the active pane's others, shown: the window comes up with it, the text in focus.
    func add(_ e: Editor, show: Bool = true) {
        e.host = self
        pane.docs.append(e)
        select(e, in: pane)
        if show { reveal(e) }
        changed()
    }

    /// `e`'s tab chosen in `p` (else where it is), and that pane active.
    func select(_ e: Editor, in p: Pane? = nil) {
        guard let p = p ?? place(of: e) else { return }
        guard p !== pane || e !== p.active || e.view(in: p).frame.superview == nil else { return }
        show(e, in: p)
        activate(p)
    }

    /// `e`'s view in `p`'s body — the pane's tab shown; the keys stay where they are.
    private func show(_ e: Editor, in p: Pane) {
        let v = e.view(in: p), leaving = p.active
        guard e !== leaving || v.frame.superview == nil else { return }
        if let leaving, leaving !== e { leaving.views.first { $0.pane === p }?.frame.removeFromSuperview() }
        p.active = e
        v.frame.frame = p.body.bounds
        v.frame.autoresizingMask = [.width, .height]
        p.body.addSubview(v.frame)   // its view controller joins the responder chain: ⌘S, Find… reach the document
        if let i = p.docs.firstIndex(where: { $0 === e }), p.strip.arrangedSubviews.indices.contains(i) { p.strip.arrangedSubviews[i].scrollToVisible(p.strip.arrangedSubviews[i].bounds) }
        if leaving != nil, leaving !== e { checkpoint() }   // what was typed there, kept as it's left
    }

    /// `e`'s tab out of `p` — its view with it unless it moves along (`keep`) — the one beside it shown there; an emptied
    /// pane goes.
    private func detach(_ e: Editor, from p: Pane, keep: Bool = false) {
        guard let i = p.docs.firstIndex(where: { $0 === e }) else { return }
        p.docs.remove(at: i)
        e.views.first { $0.pane === p }?.frame.removeFromSuperview()
        if !keep { e.dropView(in: p) }   // never its last: a closed document keeps it
        if p.active === e {
            p.active = nil
            if !p.docs.isEmpty {
                let next = p.docs[min(i, p.docs.count - 1)]
                if p === pane { select(next, in: p) } else { show(next, in: p); if window?.isKeyWindow == true { next.shown() } }
            }
        }
        if p.docs.isEmpty { removePane(p) }
        showTabs()
    }

    /// `e`'s tab in `p` (else the active pane's, else where it is) closes by itself while `e` shows in the other pane
    /// too: nothing's asked, nothing goes to ⇧⌘T — the document stays there.
    func closeClone(_ e: Editor, in p: Pane? = nil) -> Bool {
        let holding = panes.filter { $0.docs.contains { $0 === e } }
        guard holding.count > 1 else { return false }
        detach(e, from: p ?? place(of: e) ?? holding[0])
        changed()
        return true
    }

    /// Next / Previous Tab (⌃Tab, ⌃⇧Tab), round, in the active pane.
    func switchTab(by step: Int) {
        let docs = pane.docs
        guard let a = active, let i = docs.firstIndex(where: { $0 === a }), docs.count > 1 else { return }
        select(docs[(i + step + docs.count) % docs.count], in: pane)
    }

    /// Move Tab Left / Right, in the active pane.
    func moveTab(by step: Int) {
        guard let a = active, let i = pane.docs.firstIndex(where: { $0 === a }) else { return }
        moveTab(from: i, to: i + step)
    }

    /// A tab to another place in its pane's strip (Move Tab, a drag): the session keeps the order.
    func moveTab(from i: Int, to j: Int, in p: Pane? = nil) {
        let p = p ?? pane!
        guard i != j, p.docs.indices.contains(i), p.docs.indices.contains(j) else { return }
        p.docs.insert(p.docs.remove(at: i), at: j)
        showTabs()
        changed()
    }

    /// Close Other Tabs / Close Tabs to the Right of `e` in its pane: one after another, a changed one asking as ⌘W does —
    /// its Cancel (or a Save that didn't go through) keeps it and the rest; one the other pane shows too just goes. `e`
    /// is shown after. The other pane's tabs stay.
    func closeOthers(than e: Editor, in p: Pane? = nil) {
        guard let p = p ?? place(of: e) else { return }
        close(p.docs.filter { $0 !== e }, in: p, then: e)
    }
    func closeRight(of e: Editor, in p: Pane? = nil) {
        guard let p = p ?? place(of: e), let i = p.docs.firstIndex(where: { $0 === e }) else { return }
        close(Array(p.docs[(i + 1)...]), in: p, then: e)
    }
    private func close(_ tabs: [Editor], in p: Pane, then e: Editor) {
        Task {
            for t in tabs where p.docs.contains(where: { $0 === t }) { guard await t.closeAsked(in: p) else { return } }
            if p.docs.contains(where: { $0 === e }) { select(e, in: p) }
        }
    }

    /// All Tabs…: every document by name and place, filtered as typed.
    func allTabs() {
        guard let w = window else { return }
        let docs = docs
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
        if w.attachedSheet == nil, place(of: e) != nil { select(e) }
        if w.isMiniaturized { w.deminiaturize(nil) }
        if !w.isKeyWindow || !w.isVisible { w.makeKeyAndOrderFront(nil) }
        w.listInWindowsMenu()
        if let note = notes.popLast() { e.flash(note) }
        return w
    }

    /// Close Tab of a document's last view (`Editor.closeAsking` asked first): gone once the session without it is
    /// written — Don't Save's draft with it. A failed write keeps the tab, its status line says why. A tool's window closes.
    func close(_ e: Editor) {
        let back = e.reopenable   // before the commit drops its draft
        guard tabbed, drafts != nil else { return remove(e, back) }
        Task {
            if let why = await commit(closing: e) { return e.flash("Not closed: the editor's session couldn't be saved (\(why))") }
            remove(e, back)
        }
    }

    /// Without asking or writing anything (a tab that's closed, a test's cleanup), from every pane. `back`: what ⇧⌘T
    /// brings back of it.
    func remove(_ e: Editor, _ back: (doc: EditorSession.Doc, text: String?)? = nil) {
        closing.remove(ObjectIdentifier(e))
        guard let p = place(of: e), let i = p.docs.firstIndex(where: { $0 === e }) else { return }
        if tabbed, let back {
            closedTabs.append((back.doc, back.text, i, panes.firstIndex { $0 === p } ?? 0))
            // Twenty, and their texts 64 MB at most all told: the oldest go first.
            while closedTabs.count > 20 || closedTabs.reduce(0, { $0 + ($1.text?.utf8.count ?? 0) }) > 64 << 20 { closedTabs.removeFirst() }
        }
        for q in panes where q.docs.contains(where: { $0 === e }) { detach(e, from: q) }
        e.closed()
        guard tabbed else { window?.close(); return }
        if docs.isEmpty { window?.close() }   // its last tab: the window goes
        window?.isDocumentEdited = docs.contains(where: \.isEdited)
        changed()
    }

    /// ⎋ outside the find bar: back to the panels — an unchanged tab closes (a clone's view only), a changed one stays
    /// as a draft, and the window hides. A tool's window closes, asking about changes.
    func escape(_ e: Editor) {
        guard tabbed else { e.closeAsking(); return }
        if e.isEdited || closeClone(e) { return hide() }
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

    func windowDidBecomeKey(_ notification: Notification) { docs.filter(shows).forEach { $0.shown() } }

    /// A tool's window closed: its document with it. The editor window only hides — its tabs stay.
    func windowWillClose(_ notification: Notification) {
        guard !tabbed else { return }
        let gone = docs
        (pane.docs, pane.active) = ([], nil)
        gone.forEach { $0.closed() }
    }

    /// Its tabs, and the window's title, chips, toolbar and edited dot if it's the one shown.
    func update(_ e: Editor) {
        showTabs()
        window?.isDocumentEdited = docs.contains(where: \.isEdited)   // any tab: the close button's dot
        guard e === active, let w = window else { return }
        (w.title, w.subtitle) = e.heading
        w.representedURL = e.representedURL
        w.showChips(e.chips)
        finalNewlineSwitch.setSelected(e.finalNewline, forSegment: 0)
        finalNewlineSwitch.isEnabled = e.snapshot == nil
        let history = w.toolbar?.items.contains { $0.itemIdentifier == Self.historyID } == true
        if history != (e.server != nil), let bar = w.toolbar {   // a server's file has its history
            if history { bar.removeItem(at: bar.items.count - 1) } else { bar.insertItem(withItemIdentifier: Self.historyID, at: bar.items.count) }
        }
        w.listInWindowsMenu()   // a new title put the plain one back there
    }

    private func tabRow(_ p: Pane, _ r: NSRect) -> NSView {
        let (row, strip, off) = (p.row, p.strip, p.off)
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
        for (i, (symbol, tip, action)) in [(Symbol.plus, "New Editor Document  ⌘N", #selector(newTab(_:))), (.collapse, "All Tabs…", #selector(listTabs))].enumerated() {
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

    /// A new Untitled in the pane of the row clicked (its +, a double-click past its tabs).
    @objc private func newTab(_ b: NSView) { newTab(in: b.superview) }
    func newTab(in row: NSView?) {
        if let p = panes.first(where: { $0.row === row }) { pane = p }
        Editor.untitled()
    }
    @objc private func listTabs() { allTabs() }
    /// A tab chosen without the mouse (VoiceOver's press): a parked server tab opens.
    @objc func tabClicked(_ b: NSButton) {
        guard let p = (b as? EditorTab)?.pane, p.docs.indices.contains(b.tag) else { return }
        select(p.docs[b.tag], in: p)
        p.docs[b.tag].connect()
    }
    /// A tab pressed (`EditorTab`): chosen now; a parked one opens on the release unless it was dragged.
    func tabPressed(_ i: Int, in p: Pane) { if p.docs.indices.contains(i) { select(p.docs[i], in: p) } }
    @objc private func closeTabClicked(_ b: NSButton) {
        guard let p = (b.superview as? EditorTab)?.pane, p.docs.indices.contains(b.tag) else { return }
        p.docs[b.tag].closeAsking(in: p)
    }

    /// A tab dragged to `point` (in the window) along its strip: it moves once the pointer is past a neighbour's middle —
    /// the strip is made anew then, not at every move. Its index now.
    func drag(_ i: Int, in p: Pane, to point: NSPoint) -> Int {
        let tabs = p.strip.arrangedSubviews, x = p.strip.convert(point, from: nil).x
        guard tabs.count == p.docs.count, p.docs.indices.contains(i) else { return i }
        let j = tabs.indices.filter { $0 != i && tabs[$0].frame.midX < x }.count
        moveTab(from: i, to: j, in: p)
        p.strip.layoutSubtreeIfNeeded()
        return j
    }

    /// The other pane, if `point` (in the window) is over it.
    func pane(at point: NSPoint, besides p: Pane) -> Pane? {
        panes.first { $0 !== p && $0.box.bounds.contains($0.box.convert(point, from: nil)) }
    }

    /// A tab let go over the other pane: there — on its strip where it's let go, on its text after its tabs — it moves,
    /// with ⌥ a clone goes.
    func dropped(_ e: Editor, from p: Pane, at point: NSPoint, clone: Bool) {
        guard let q = pane(at: point, besides: p) else { return }
        let onStrip = q.row.bounds.contains(q.row.convert(point, from: nil)), x = q.strip.convert(point, from: nil).x
        let at = onStrip ? q.strip.arrangedSubviews.filter { $0.frame.midX < x }.count : nil
        if clone { self.clone(e, from: p, at: at) } else { move(e, from: p, at: at) }
    }

    /// The mouse on the strip besides a click and a drag (`EditorTab`, `TabRow`): the middle button closes a tab as ⌘W
    /// does, a double-click past the tabs opens a new Untitled.
    func middleClicked(_ i: Int, in p: Pane) { if p.docs.indices.contains(i) { p.docs[i].closeAsking(in: p) } }

    /// A tab's menu, made as it opens (right click, ⌃-click, VoiceOver's Show Menu).
    func tabMenu(for e: Editor, in p: Pane? = nil) -> [NSMenuItem] {
        guard let p = p ?? place(of: e) else { return [] }
        let i = p.docs.firstIndex { $0 === e } ?? p.docs.count
        let items: [(String, Bool, @MainActor () -> Void)] = [
            ("Close Tab", true, { e.closeAsking(in: p) }),
            ("Close Other Tabs", p.docs.count > 1, { [weak self] in self?.closeOthers(than: e, in: p) }),
            ("Close Tabs to the Right", i < p.docs.count - 1, { [weak self] in self?.closeRight(of: e, in: p) }),
            ("", false, {}),
            ("Move to Other Pane", panes.count > 1 || p.docs.count > 1, { [weak self] in self?.move(e, from: p) }),
            ("Clone to Other Pane", true, { [weak self] in self?.clone(e, from: p) }),
            ("", false, {}),
            ("Rename…", true, { [weak self] in self?.beginRename(e, in: p) }),
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

    /// The tab buttons of each pane: a mark before each name (● changed, ↑ not uploaded, ! its draft not saved), its
    /// server's chips; a name two documents share says where each is. The line under a pane's tab shown is half-tone in
    /// the pane the keys aren't in.
    private func showTabs() {
        guard tabbed else { return }
        defer { comparison?.check() }   // a tab chosen, moved or closed: paused, on again, or over
        let names = docs.map(\.name)
        for p in panes {
            p.off.isHidden = draftsOff == nil
            p.strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (i, e) in p.docs.enumerated() {
                let lead = NSMutableAttributedString()
                if let m = e.mark { lead.append(m) }
                if let c = Chip.text(e.chips) { if lead.length > 0 { lead.append(NSAttributedString(string: " ")) }; lead.append(c) }
                let tint = p === pane ? Chip.tint(e.chips) : (Chip.tint(e.chips) ?? Palette.accent).withAlphaComponent(0.35)
                let tab = EditorTab(host: self, pane: p)
                let b = PanelViewController.tabButton(tabTitle(e, among: names).bidiVisible, lead: lead.length > 0 ? lead : nil, tint: tint, tip: e.tip, index: i,
                                                      current: e === p.active, target: self, action: #selector(tabClicked(_:)), close: #selector(closeTabClicked(_:)),
                                                      italic: e.cover != nil, button: tab)
                let menu = LiveMenu(title: e.name) { [weak self, weak e, weak p] in e.flatMap { e in p.flatMap { self?.tabMenu(for: e, in: $0) } } ?? [] }
                menu.autoenablesItems = false
                b.menu = menu
                b.widthAnchor.constraint(greaterThanOrEqualToConstant: min(260, max(118, b.intrinsicContentSize.width + 12))).isActive = true   // the × clear of a bold name
                b.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
                p.strip.addArrangedSubview(b)
            }
        }
    }

    /// Its name; one another document has too, with its server or folder after it ("nginx.conf — web-01").
    func tabTitle(_ e: Editor, among names: [String]? = nil) -> String {
        (names ?? docs.map(\.name)).filter { $0 == e.name }.count > 1 && !e.whereShort.isEmpty ? e.name + " — " + e.whereShort : e.name   // Untitleds named alike: no place to say
    }

    // MARK: Rename on the tab

    /// The name field over a tab being renamed, and its document.
    private var renaming: (e: Editor, field: NSTextField)?

    /// Rename… (a double-click on its tab, its menu, ⇧F6): a field over its tab in `p` (else where it is), the name's
    /// base selected as Finder does — a locked server's after Touch ID. ↩ renames; ⎋ or a click elsewhere leaves it as it was.
    func beginRename(_ e: Editor, in p: Pane? = nil) {
        if let why = e.renameRefusal { return e.flash(why) }
        guard tabbed, renaming == nil else { return }
        guard let s = e.server, e.cover == .locked || ServerLock.needsUnlock(s.target) else { return showRenameField(e, p) }
        Task {
            guard await ServerLock.authorize(s.target, "rename a file on") else { return }
            guard place(of: e) != nil else { return }   // closed during Touch ID
            if e.cover == .locked { e.connect() }   // its draft shows too: unlocked now, nothing asked again (a parked one stays)
            showRenameField(e, p)
        }
    }

    private func showRenameField(_ e: Editor, _ p: Pane?) {
        guard renaming == nil, let p = p.flatMap({ p in p.docs.contains { $0 === e } ? p : nil }) ?? place(of: e) else { return }   // closed during Touch ID
        select(e, in: p)
        guard let i = p.docs.firstIndex(where: { $0 === e }), p.strip.arrangedSubviews.indices.contains(i) else { return }
        let tab = p.strip.arrangedSubviews[i], row = p.row, r = row.convert(tab.bounds, from: tab)
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
    /// only, gone at Quit — and where it was: its pane and place there.
    private var closedTabs: [(doc: EditorSession.Doc, text: String?, at: Int, pane: Int)] = []

    /// ⇧⌘T: the tab closed last, back where it was with its caret — in its pane, or the active one if that's gone; this
    /// Mac's file as it is now, a server's parked (nothing connects), a Don't Save's text as it was. Its file open
    /// meanwhile: that tab is chosen. None: a beep.
    func reopenClosed() {
        guard let c = closedTabs.popLast() else { return NSSound.beep() }
        if let open = c.doc.server.flatMap({ Editor.editing($0.target.asRoot($0.root), $0.path) }) ?? c.doc.path.flatMap(Editor.following) {
            open.revealed()
            if c.text != nil { open.flash("Open already: the text it was closed with isn't brought back") }
            return
        }
        let e = Editor(restoring: c.doc, draft: c.text != nil, onServer: onServer), p = panes.indices.contains(c.pane) ? panes[c.pane] : pane!
        e.host = self
        p.docs.insert(e, at: min(c.at, p.docs.count))
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
        var made: [UUID: Editor] = [:]
        for d in opened.session.docs where made[d.id] == nil {
            let e = Editor(restoring: d, onServer: onServer)
            e.host = h
            made[d.id] = e
            Task { await e.restore(d, from: opened.store) }   // each on its own: a slow file or share holds up no other tab
        }
        h.arrange(opened.session.docs.compactMap { made[$0.id] }, opened.session.panes, active: opened.session.active.flatMap { made[$0] })
        if opened.session.windowOpen, let a = h.active { h.reveal(a) }
    }

    /// The restored tabs into their panes as the session has them — a document in both is one, shown twice — and
    /// what each shows; a tab no pane names goes to the first (a session an older Kermo wrote: all of them).
    private func arrange(_ docs: [Editor], _ s: EditorSession.Panes?, active: Editor?) {
        let byID = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var lists = (s?.tabs ?? []).prefix(2).map { ids in
            var seen = Set<UUID>()
            return ids.filter { seen.insert($0).inserted }.compactMap { byID[$0] }
        }
        if lists.isEmpty { lists = [[]] }
        let placed = Set(lists.joined().map(\.id))
        lists[0] += docs.filter { !placed.contains($0.id) }
        let kept = lists.indices.filter { !lists[$0].isEmpty }   // the session's pane of each, for what it shows
        pane.docs = kept.first.map { lists[$0] } ?? []
        if kept.count > 1, let s {
            let q = other(than: pane, vertical: s.vertical)
            q.docs = lists[kept[1]]
            let whole = split.isVertical ? split.bounds.width : split.bounds.height
            split.setPosition(min(max(CGFloat(s.split) * whole, Self.minPane), whole - Self.minPane), ofDividerAt: 0)
        }
        for (p, i) in zip(panes, kept) {
            let id = s.map { $0.shown.indices.contains(i) ? $0.shown[i] : nil } ?? active?.id
            if let e = p.docs.first(where: { $0.id == id }) ?? p.docs.first { show(e, in: p) }
        }
        activate(s.flatMap { kept.firstIndex(of: $0.focused) }.map { panes[$0] } ?? pane)
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
        let kept = docs.filter { !closing.contains(ObjectIdentifier($0)) && $0.snapshot == nil }   // a Compare's read-only copies: never kept
        s.active = active.flatMap { a in kept.contains { $0 === a } ? a.id : nil }
        if panes.count > 1 {
            let ids = Set(kept.map(\.id))
            s.panes = .init(tabs: panes.map { $0.docs.map(\.id).filter(ids.contains) }, shown: panes.map { $0.active.flatMap { ids.contains($0.id) ? $0.id : nil } },
                            vertical: split.isVertical, split: share, focused: panes.firstIndex { $0 === pane } ?? 0)
        }
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

/// The editor's window: where the keys go makes a pane the active one — its text, its find bar or its cover.
private final class EditorWindow: NSWindow {
    override func makeFirstResponder(_ r: NSResponder?) -> Bool {
        guard super.makeFirstResponder(r) else { return false }
        (windowController as? EditorHost)?.keysMoved()
        return true
    }
}

/// The editor window's row of tabs: a double-click past them opens a new Untitled.
final class TabRow: NSView {
    weak var scroll: NSScrollView?
    override func mouseDown(with e: NSEvent) { if e.clickCount == 2 { (window?.windowController as? EditorHost)?.newTab(in: self) } }
    /// Clicks past the tabs (the strip's background, its scroll view) are the row's; the wheel still scrolls the tabs.
    override func hitTest(_ p: NSPoint) -> NSView? {
        let v = super.hitTest(p)
        return v is NSClipView || v is NSScrollView || v is NSStackView ? self : v
    }
    override func scrollWheel(with e: NSEvent) { scroll?.scrollWheel(with: e) }
}

/// A tab of the editor window: chosen on the press (a parked one opens), dragged along its strip — or onto the other
/// pane, which it moves to (with ⌥ a clone goes) — renamed by a double-click; the middle button closes it.
final class EditorTab: NSButton {
    private weak var host: EditorHost?
    private(set) weak var pane: EditorHost.Pane?
    convenience init(host: EditorHost, pane: EditorHost.Pane) {
        self.init(frame: .zero)
        (self.host, self.pane) = (host, pane)
    }

    override func mouseDown(with e: NSEvent) {
        guard let host, let pane, let window, pane.docs.indices.contains(tag) else { return super.mouseDown(with: e) }
        if e.clickCount == 2 { return host.beginRename(pane.docs[tag], in: pane) }   // the first click chose it
        var at = tag, dragged = false, last = e
        let doc = pane.docs[tag]
        host.tabPressed(tag, in: pane)   // the strip is made anew: this button leaves it
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            last = next
            guard next.type == .leftMouseDragged else { break }
            let p = next.locationInWindow
            dragged = dragged || abs(p.x - e.locationInWindow.x) > 4 || abs(p.y - e.locationInWindow.y) > 4
            if dragged, host.pane(at: p, besides: pane) == nil { at = host.drag(at, in: pane, to: p) }   // over the other pane: it goes there on the release
        }
        if dragged {
            let point = last.locationInWindow
            if at != tag, host.pane(at: point, besides: pane) != nil { host.moveTab(from: at, to: tag, in: pane) }   // gone across: its strip as it was
            host.dropped(doc, from: pane, at: point, clone: last.modifierFlags.contains(.option))
        }
        else { doc.connect() }   // a click: a parked server tab opens (no Touch ID mid-drag)
    }

    override func otherMouseDown(with e: NSEvent) { if e.buttonNumber != 2 { super.otherMouseDown(with: e) } }
    override func otherMouseUp(with e: NSEvent) {
        guard e.buttonNumber == 2, let host, let pane, bounds.contains(convert(e.locationInWindow, from: nil)) else { return super.otherMouseUp(with: e) }
        host.middleClicked(tag, in: pane)
    }
}
