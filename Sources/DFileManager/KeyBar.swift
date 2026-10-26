import AppKit
import DFMCore

/// One key in the bar: what to press, what it does, which command it runs (nil = a hint, not clickable).
struct KeySlot: Equatable {
    let key: String
    let label: String
    let id: String?
}

/// Command registry → key bar layers, one per modifier combination (holding ⌘ shows every ⌘ key).
enum KeyBarModel {
    /// Layer menu order; any other combination in use follows.
    static let order: [NSEvent.ModifierFlags] = [[], .shift, .option, .command, .control, [.command, .shift], [.command, .option], [.control, .command]]

    /// "⌃⌥⇧⌘" order, like Shortcut.display; "" for no modifiers.
    static func symbol(_ m: NSEvent.ModifierFlags) -> String {
        (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
    }

    static func fNumber(_ key: String) -> Int? { key.first == "f" ? Int(key.dropFirst()) : nil }

    /// A command's words on the bar: its `short`, else its menu title without "…" and what's said in brackets.
    static func label(_ c: Command) -> String {
        guard c.short.isEmpty else { return c.short }
        let t = c.title.replacingOccurrences(of: "…", with: "")
        return (t.range(of: " (").map { String(t[..<$0.lowerBound]) } ?? t)
    }

    /// Unmodified keys other than F-keys (↩ ⌫ Space Tab /) stay out — they're on the F1 sheet.
    /// ⌥+digit duplicates of F-keys (⌥5 = F5, ⇧⌥6 = ⇧F6, ⌥0 = F10) collapse into one hint slot naming the digits there.
    /// One slot per command per layer (its first key there). F-keys first by number, then registry order.
    /// `server`: the active panel is a server's, where F8 deletes (after a question): no Trash there. `archive`: it's
    /// inside an archive, where F5 extracts.
    /// `terminal`: the terminal's own commands, its panes' too; with no F-keys there, each one's first key shows at rest,
    /// and ⌃O goes back to the panels. Else the panes' keys stay out: the bar is the panels'.
    static func layers(_ commands: [Command], server: Bool = false, archive: Bool = false, terminal: Bool = false) -> [(mods: NSEvent.ModifierFlags, slots: [KeySlot])] {
        var slots: [UInt: [(f: Int, slot: KeySlot)]] = [:]
        var hinted: [UInt: [Int]] = [:]   // per layer: the F-key numbers its ⌥ digits stand for
        func label(_ c: Command) -> String {
            server && c.id == "file.trash" ? "Delete…" : archive && c.id == "file.copy" ? "Extract" : terminal && c.id == "view.terminal" ? "Hide Terminal" : Self.label(c)
        }
        for c in commands where terminal || !c.id.hasPrefix("term.pane.") && !c.id.hasPrefix("term.resize.") {
            for k in c.keys {
                let m = k.flags, f = fNumber(k.name)
                if m.isEmpty && f == nil { continue }
                if m.contains(.option), let d = Int(k.name),
                   c.keys.contains(where: { $0.flags == m.subtracting(.option) && fNumber($0.name) == (d == 0 ? 10 : d) }) {
                    hinted[m.rawValue, default: []].append(d == 0 ? 10 : d)
                    continue
                }
                if slots[m.rawValue]?.contains(where: { $0.slot.id == c.id }) == true { continue }
                slots[m.rawValue, default: []].append((f ?? 99, KeySlot(key: k.display, label: label(c), id: c.id)))
            }
        }
        if terminal, slots[0] == nil {
            slots[0] = commands.compactMap { c in c.keys.first.map { (99, KeySlot(key: $0.display, label: label(c), id: c.id)) } }
        }
        let used = Set(slots.keys).union(hinted.keys).map { NSEvent.ModifierFlags(rawValue: $0) }   // ⇧⌥: hints only
        let mods = [[]] + order.dropFirst().filter { used.contains($0) } + used.filter { !order.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        return mods.map { m in
            var s = (slots[m.rawValue] ?? []).enumerated().sorted { ($0.element.f, $0.offset) < ($1.element.f, $1.offset) }.map(\.element.slot)
            if let f = hinted[m.rawValue]?.sorted() {
                let (key, fs) = f.count == 10 ? ("1…0", "1…F10") : (f.map { "\($0 % 10)" }.joined(separator: " "), f.map(String.init).joined(separator: " "))
                s.append(KeySlot(key: symbol(m) + key, label: "= \(symbol(m.subtracting(.option)))F" + fs, id: nil))
            }
            return (m, s)
        }
    }

    /// Where F5 and F6 go, in their slots ("Copy → web-01") when it isn't plain: a server (by its name, production's
    /// said in its color), or with 3–4 panels a folder (its name). nil with two panels on this Mac.
    struct Target: Equatable {
        let name: String
        var prod = false
        var text: String { "→ " + name }
    }
    static func target(server: (name: String, prod: Bool)?, folder: String, panels: Int) -> Target? {
        if let server { return Target(name: server.name.bidiVisible, prod: server.prod) }
        return panels > 2 ? Target(name: folder == "/" ? "/" : (folder as NSString).lastPathComponent.bidiVisible) : nil
    }
    static let targeted: Set<String> = ["file.copy", "file.move"]

    /// Mouse users' file actions (F3–F8): the last to go under "+N" on a narrow window.
    static let core: Set<String> = ["file.view", "file.edit", "file.copy", "file.move", "file.mkdir", "file.trash"]

    /// What fits in `capacity` slots: all of them, or capacity−1 plus a "+N" count.
    /// Slots not in `keep` go first, then kept ones, each from the end; shown ones stay in order.
    static func fit(_ slots: [KeySlot], capacity: Int, keep: Set<String> = core) -> (shown: [KeySlot], more: Int) {
        guard slots.count > capacity, capacity > 0 else { return (slots, 0) }
        let kept = slots.indices.filter { slots[$0].id.map(keep.contains) == true }
        let spare = slots.indices.filter { !kept.contains($0) }
        let shown = Set((kept + spare).prefix(capacity - 1))
        return (slots.indices.filter(shown.contains).map { slots[$0] }, slots.count - shown.count)
    }

    /// What VoiceOver says for a slot: "F5, Copy to web-01".
    static func spoken(_ s: KeySlot, target: Target? = nil) -> String {
        [s.key, s.label + (target.map { " to \($0.name)" + ($0.prod ? ", a production server" : "") } ?? "")].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The keys of what has the focus, along the bottom: the panels' F1–F10, holding a modifier for a moment shows its
/// layer; the terminal's keys; or a list of its own — the command line's, a Picker's, a window's. Click a slot = press
/// its key. ⇧ ⌥ ⌘ ⌃ on the left light up while held; a click keeps that layer shown until ⎋, a second click or the
/// next command.
@MainActor
final class KeyBarView: NSView {
    var onRun: ((String) -> Void)?
    /// "+N" of the registry's layers (the F1 sheet on that layer); a list's opens a menu of the rest.
    var onMore: ((NSEvent.ModifierFlags) -> Void)?
    var canRun: (String) -> Bool = { _ in true }
    var terminalShown: () -> Bool = { false }
    /// Shown in place of the registry's layers, every slot enabled, no modifier chips: its owner lists what works.
    var list: [KeySlot]? { didSet { if list != oldValue { render() } } }
    /// The active panel is a server's (F8: Delete…, in red).
    var server = false {
        didSet { if server != oldValue { reload(commands) } }
    }
    /// The active panel is inside an archive (F5: Extract).
    var archive = false {
        didSet { if archive != oldValue { reload(commands) } }
    }
    /// Said after F5's and F6's labels (`KeyBarModel.target`).
    var target: KeyBarModel.Target? { didSet { if target != oldValue { render() } } }
    /// The slots that go under "+N" last (`KeyBarModel.fit`).
    var keep = KeyBarModel.core

    private var commands: [Command] = []
    private var layers: [(mods: NSEvent.ModifierFlags, slots: [KeySlot])] = []
    private var terminalLayers: [(mods: NSEvent.ModifierFlags, slots: [KeySlot])] = []
    private var held: NSEvent.ModifierFlags = []
    private(set) var pinned: NSEvent.ModifierFlags = []
    private var holdTask: Task<Void, Never>?
    private let chips: [ModChip]
    private let chipRow = NSStackView()
    private let row = NSStackView()
    /// What the layer or list has, each slot's button made once per render: `place` picks what fits the width.
    private var slots: [KeySlot] = []
    private var buttons: [SlotButton] = []
    private var placedWidth: CGFloat = -1
    private let spacer = NSView()
    private let separator = NSBox()

    /// `chips`: the modifier chips, for the registry's layers (the main window). A Picker's or a window's bar has none.
    init(chips: Bool = true) {
        self.chips = chips ? [(NSEvent.ModifierFlags.shift, "Shift"), (.option, "Option"), (.command, "Command"), (.control, "Control")].map(ModChip.init) : []
        super.init(frame: .zero)
        for c in self.chips {
            c.target = self
            c.action = #selector(chipClicked(_:))
            chipRow.addArrangedSubview(c)
        }
        chipRow.spacing = 2
        chipRow.setHuggingPriority(.required, for: .horizontal)
        chipRow.isHidden = !chips
        row.spacing = 2
        row.distribution = chips ? .fillProportionally : .fill   // the main window's spread over its width; others as wide as their words
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        row.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = separator
        line.boxType = .separator
        let stack = NSStackView(views: [chipRow, line, row])
        stack.spacing = 6
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 4, right: 6)
        stack.setHuggingPriority(.defaultHigh, for: .vertical)   // as tall as its keys: the panels above take the rest
        stack.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 16).isActive = true
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload(_ commands: [Command]) {
        self.commands = commands
        layers = KeyBarModel.layers(commands, server: server, archive: archive)
        terminalLayers = KeyBarModel.layers(AppDelegate.terminalCommands.compactMap { id in commands.first { $0.id == id } }, terminal: true)
        render()
    }

    /// The layer showing: a pinned one, else what's held.
    var mods: NSEvent.ModifierFlags { pinned.isEmpty ? held : pinned }

    /// From a .flagsChanged monitor. Showing waits `keyBarHoldDelay` (0.12 s) so ⌘C doesn't flicker the bar;
    /// release, or switching combination while a layer is up, is immediate.
    func modifiersChanged(_ m: NSEvent.ModifierFlags) {
        holdTask?.cancel()
        guard !m.isEmpty, held.isEmpty else {
            if held != m { held = m; render() }
            return
        }
        let delay = UserDefaults.standard.object(forKey: "keyBarHoldDelay") as? Double ?? 0.12
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            held = m
            render()
        }
    }

    /// App lost focus: back to F-keys, drop a pinned layer.
    func reset() {
        holdTask?.cancel()
        held = []
        pinned = []
        render()
    }

    func unpin() -> Bool {
        guard !pinned.isEmpty else { return false }
        pinned = []
        render()
        return true
    }

    /// A command ran (key, click or menu): light up its slot, release a pinned layer.
    func commandRan(_ id: String) {
        _ = unpin()
        guard let b = row.arrangedSubviews.first(where: { $0.identifier?.rawValue == id }) as? NSButton else { return }
        b.highlight(true)
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            b.highlight(false)
        }
    }

    override func layout() {
        super.layout()
        if bounds.width != placedWidth {
            placedWidth = bounds.width
            Task { place() }   // not while AppKit is laying out
        }
    }

    func render() {
        let mods = mods
        for c in chips {
            c.held = pinned.isEmpty && held.contains(c.flag)
            c.pinned = pinned.contains(c.flag)
        }
        chipRow.isHidden = list != nil || chips.isEmpty
        separator.isHidden = chipRow.isHidden
        slots = list ?? (terminalShown() ? terminalLayers : layers).first { $0.mods == mods }?.slots ?? []
        buttons = slots.map(slotButton)
        place()
    }

    /// As many slots as fit the width, the rest under "+N" (`KeyBarModel.fit`: `keep` stays longest).
    private func place() {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !slots.isEmpty else {
            let l = NSTextField(labelWithString: "No \(KeyBarModel.symbol(mods)) keys")
            l.textColor = .secondaryLabelColor
            return row.addArrangedSubview(l)
        }
        let room = bounds.width - 12 - (chipRow.isHidden ? 0 : chipRow.fittingSize.width + 7 + 6)
        let widths = buttons.map { $0.fittingSize.width }
        var (shown, more) = (slots, 0)
        for capacity in stride(from: slots.count, through: 1, by: -1) {
            (shown, more) = KeyBarModel.fit(slots, capacity: capacity, keep: keep)
            let width = shown.compactMap { s in slots.firstIndex(of: s).map { widths[$0] } }.reduce(0, +) + (more > 0 ? 40 : 0)
            if width + CGFloat(shown.count + (more > 0 ? 1 : 0)) * row.spacing <= room || bounds.width == 0 { break }
        }
        for s in shown { slots.firstIndex(of: s).map { row.addArrangedSubview(buttons[$0]) } }
        if more > 0 {
            let b = slotButton(KeySlot(key: "+\(more)", label: "", id: nil))
            b.action = #selector(moreClicked(_:))
            b.isEnabled = true
            b.toolTip = list == nil ? "All \(KeyBarModel.symbol(mods)) keys" : "\(more) more"
            b.setAccessibilityLabel("\(more) more keys")
            row.addArrangedSubview(b)
        }
        if chips.isEmpty { row.addArrangedSubview(spacer) }
    }

    /// A flat slot: the key in a small capsule, then its word; production's target in its color, bold; F8 on a server
    /// in red. The whole of it in the tooltip, as a narrow slot cuts it.
    private func slotButton(_ s: KeySlot) -> SlotButton {
        let b = SlotButton(title: "", target: self, action: #selector(slotClicked(_:)))
        let font = NSFont.systemFont(ofSize: 12)
        let target = list == nil && s.id.map(KeyBarModel.targeted.contains) == true ? target : nil
        let t = NSMutableAttributedString(attributedString: s.key.isEmpty ? NSAttributedString() : KeyCap.text(s.key, font: font))   // a hint without a key: words only
        if !s.label.isEmpty {
            let color = list == nil && server && s.id == "file.trash" ? Palette.fail : s.id == nil ? .secondaryLabelColor : .labelColor   // gone for good
            t.append(NSAttributedString(string: (s.key.isEmpty ? "" : " ") + s.label, attributes: [.foregroundColor: color, .font: font]))
        }
        if let target {
            t.append(NSAttributedString(string: " " + target.text, attributes: target.prod
                ? [.foregroundColor: Palette.prod, .font: NSFont.boldSystemFont(ofSize: font.pointSize)] : [.foregroundColor: NSColor.secondaryLabelColor, .font: font]))
        }
        b.attributedTitle = t
        b.toolTip = s.label.isEmpty ? nil : "\(s.key) \(s.label)" + (target.map { " \($0.text)" + ($0.prod ? ", a production server" : "") } ?? "")
        b.setAccessibilityLabel(KeyBarModel.spoken(s, target: target))
        b.refusesFirstResponder = true
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.identifier = s.id.map { .init($0) }
        b.isEnabled = s.id.map { list != nil || canRun($0) } ?? false
        return b
    }

    @objc private func slotClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, list != nil || canRun(id) else { return NSSound.beep() }
        onRun?(id)
    }

    /// A list's "+N": a menu of what didn't fit; the layers' — the F1 sheet on that layer.
    @objc private func moreClicked(_ sender: NSButton) {
        guard list != nil else {
            onMore?(mods)
            return
        }
        let menu = NSMenu()
        for s in slots where s.id != nil && !row.arrangedSubviews.contains(where: { $0.identifier?.rawValue == s.id }) {
            menu.addItem(MenuAction.item("\(s.label)  \(s.key)") { [weak self] in self?.onRun?(s.id!) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func chipClicked(_ sender: ModChip) {
        pinned.formSymmetricDifference(sender.flag)
        render()
    }

    /// A window's keys (`AppDelegate.KeyRow`), each key once — the first row's, the window's own before the menu's;
    /// a click runs that row.
    func show(_ rows: [AppDelegate.KeyRow]) {
        var seen: Set<String> = []
        let rows = rows.filter { seen.insert($0.key).inserted }
        onRun = { id in Int(id).flatMap { rows.indices.contains($0) ? rows[$0] : nil }?.run() }
        list = rows.enumerated().map { KeySlot(key: $0.element.key, label: $0.element.label, id: "\($0.offset)") }
    }

    /// As wide as all its slots side by side: a bar centered on its own (a panel's empty state) is given that much.
    var naturalWidth: CGFloat { ceil(buttons.map(\.fittingSize.width).reduce(12, +) + CGFloat(buttons.count) * row.spacing) + 1 }   // as `place` counts

    /// Tests: what the chips show — held (lit) and pinned (outlined).
    var chipStates: [(flag: NSEvent.ModifierFlags, held: Bool, pinned: Bool)] { chips.map { ($0.flag, $0.held, $0.pinned) } }
    var shownSlots: [KeySlot] { row.arrangedSubviews.compactMap { v in buttons.firstIndex { $0 === v }.map { slots[$0] } } }
}

/// A slot: no border, a light fill under the mouse (or while it flashes for a command that ran), its title cut at
/// the end if it must; dimmed while it can't run.
final class SlotButton: NSButton {
    private var inside = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(attributedTitle.size().width) + 12, height: 23) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { inside = true }
    override func mouseExited(with event: NSEvent) { inside = false }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted || inside && isEnabled {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let t = attributedTitle, h = t.size().height
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.45)
        t.draw(with: NSRect(x: 6, y: (bounds.height - h) / 2, width: bounds.width - 12, height: h),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// A key as the bar draws it: its symbols on a small capsule, in the flow of the text, read out as the key.
enum KeyCap {
    static func text(_ key: String, font: NSFont) -> NSAttributedString {
        let s = NSAttributedString(string: key, attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
        let size = NSSize(width: max(18, ceil(s.size().width) + 9), height: 17)
        let image = NSImage(size: size, flipped: false) { r in
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 1), xRadius: 4, yRadius: 4)
            NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
            p.fill()
            NSColor.separatorColor.setStroke()
            p.lineWidth = 1
            p.stroke()
            s.draw(at: NSPoint(x: (r.width - s.size().width) / 2, y: (r.height - s.size().height) / 2))
            return true
        }
        image.cacheMode = .never   // its colors are dynamic
        image.accessibilityDescription = key
        let a = NSTextAttachment()
        a.image = image
        a.bounds = NSRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)   // centered on the word
        return NSAttributedString(attachment: a)
    }
}

/// ⇧ ⌥ ⌘ ⌃ left of the keys: filled with the accent while held, outlined while a click keeps its layer.
final class ModChip: NSButton {
    let flag: NSEvent.ModifierFlags
    private let name: String
    var held = false { didSet { if held != oldValue { changed() } } }
    var pinned = false { didSet { if pinned != oldValue { changed() } } }

    init(_ flag: NSEvent.ModifierFlags, _ name: String) {
        self.flag = flag
        self.name = name
        super.init(frame: .zero)
        title = KeyBarModel.symbol(flag)
        isBordered = false
        refusesFirstResponder = true
        toolTip = "\(name): hold it to see its keys, or click to keep them shown — ⎋ or another click lets go"
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 21).isActive = true
        changed()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func changed() {
        setAccessibilityLabel("\(name) layer" + (pinned ? ", pinned" : held ? ", held" : ""))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        let accent = NSColor.controlAccentColor
        if held {
            accent.setFill()
            p.fill()
        } else if pinned {
            accent.setStroke()
            p.lineWidth = 1.5
            p.stroke()
        }
        let s = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12.5),
                                                              .foregroundColor: held ? NSColor.white : pinned ? accent : NSColor.secondaryLabelColor])
        let size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// A document window's frame (Р9) — the viewer's, the editor's, an output window's: what it shows, a status line under
/// it, and its keys along the bottom: its own, then the menu bar's that work there, as F1 over it lists them
/// (`AppDelegate.keyRows`). Laid out by frames, so the scroll view has its size from the start (the viewer sizes its
/// text from it).
@MainActor
final class DocFrame: NSView {
    let scroll: NSScrollView
    private let status = NSTextField(labelWithString: "")
    let keys = KeyBarView(chips: false)
    private var said = ""
    private var flashed = 0

    /// What a window's key bar shows (tests set it: there's no app delegate there).
    static var rows: (NSWindow) -> [AppDelegate.KeyRow] = { w in
        (NSApp.delegate as? AppDelegate).flatMap { app in NSApp.mainMenu.map { app.keyRows(over: w, menu: $0) } } ?? []
    }

    init(_ scroll: NSScrollView, size: NSSize) {
        self.scroll = scroll
        super.init(frame: NSRect(origin: .zero, size: size))
        let bar: CGFloat = 30, line: CGFloat = 22
        keys.frame = NSRect(x: 0, y: 0, width: size.width, height: bar)
        keys.autoresizingMask = [.width, .maxYMargin]
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 10, y: bar + 3, width: size.width - 20, height: line - 6)
        status.autoresizingMask = [.width, .maxYMargin]
        let rule = NSBox(frame: NSRect(x: 0, y: bar + line - 1, width: size.width, height: 1))
        rule.boxType = .separator
        rule.autoresizingMask = [.width, .maxYMargin]
        scroll.frame = NSRect(x: 0, y: bar + line, width: size.width, height: size.height - bar - line)
        scroll.autoresizingMask = [.width, .height]
        for v in [scroll, rule, status, keys] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The status line: what the window shows now (its encoding, a filter, "running…"); a `flash` stays a few seconds.
    var text: String {
        get { status.stringValue }
        set {
            said = newValue
            if flashed == 0 { status.stringValue = newValue }
        }
    }

    /// Where a document window's file or command is, said under its title: "web-01 · /var/log/nginx" on a server (its
    /// saved name), "~/Projects/site" here; nothing for a temporary copy of something else (an archive's entry, git's
    /// output), whose folder says nothing.
    static func place(_ dir: String, host: String?) -> String {
        if let host { return "\(host) · \(dir)".bidiVisible }
        let temp = NSTemporaryDirectory(), real = (temp as NSString).resolvingSymlinksInPath
        return dir.hasPrefix(temp) || dir.hasPrefix(real) ? "" : (dir as NSString).abbreviatingWithTildeInPath.bidiVisible
    }

    /// Says something in the status line for a few seconds (a save's note: the panels' status line is behind this window).
    func flash(_ note: String) {
        flashed += 1
        status.stringValue = note.bidiVisible
        Task {
            try? await Task.sleep(for: .seconds(4))
            flashed -= 1
            if flashed == 0 { status.stringValue = said }
        }
    }

    /// Its keys as they are now — on becoming key, and when what works changes (a command ended, hex on).
    func showKeys() {
        if let w = window { keys.show(Self.rows(w)) }
    }
}

extension NSWindow {
    /// A document window's status line.
    var statusText: String { (contentView as? DocFrame)?.text ?? "" }
    var docFrame: DocFrame? { contentView as? DocFrame }

    /// Its line in the Window menu: the title and where it is, so two "app.log" of two servers read apart there (the
    /// menu has no subtitles).
    var windowsMenuTitle: String { subtitle.isEmpty ? title : "\(title) — \(subtitle)" }
    func listInWindowsMenu() {
        if isVisible { NSApp.changeWindowsItem(self, title: windowsMenuTitle, filename: false) }
    }
}
