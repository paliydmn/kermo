import AppKit

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

    /// Unmodified keys other than F-keys (↩ ⌫ Space Tab /) stay out — they're on the F1 sheet.
    /// ⌥+digit duplicates of F-keys (⌥5 = F5, ⇧⌥6 = ⇧F6, ⌥0 = F10) collapse into one hint slot naming the digits there.
    /// One slot per command per layer (its first key there). F-keys first by number, then registry order.
    /// `server`: the active panel is a server's, where F8 deletes (after a question): no Trash there.
    static func layers(_ commands: [Command], server: Bool = false) -> [(mods: NSEvent.ModifierFlags, slots: [KeySlot])] {
        var slots: [UInt: [(f: Int, slot: KeySlot)]] = [:]
        var hinted: [UInt: [Int]] = [:]   // per layer: the F-key numbers its ⌥ digits stand for
        // The terminal's pane arrows stay out too: the bar is the panels' (the terminal shows only ⌃O there).
        for c in commands where !c.id.hasPrefix("term.pane.") && !c.id.hasPrefix("term.resize.") {
            for k in c.keys {
                let m = k.flags, f = fNumber(k.name)
                if m.isEmpty && f == nil { continue }
                if m.contains(.option), let d = Int(k.name),
                   c.keys.contains(where: { $0.flags == m.subtracting(.option) && fNumber($0.name) == (d == 0 ? 10 : d) }) {
                    hinted[m.rawValue, default: []].append(d == 0 ? 10 : d)
                    continue
                }
                if slots[m.rawValue]?.contains(where: { $0.slot.id == c.id }) == true { continue }
                let label = server && c.id == "file.trash" ? "Delete…" : c.short.isEmpty ? c.title : c.short
                slots[m.rawValue, default: []].append((f ?? 99, KeySlot(key: k.display, label: label, id: c.id)))
            }
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

    /// Mouse users' file actions (F3–F8): the last to go under "+N" on a narrow window.
    static let core: Set<String> = ["file.view", "file.edit", "file.copy", "file.move", "file.mkdir", "file.trash"]

    /// What fits in `capacity` slots: all of them, or capacity−1 plus a "+N" count.
    /// Slots not in `core` go first, then core ones, each from the end; shown ones stay in order.
    static func fit(_ slots: [KeySlot], capacity: Int) -> (shown: [KeySlot], more: Int) {
        guard slots.count > capacity, capacity > 0 else { return (slots, 0) }
        let kept = slots.indices.filter { slots[$0].id.map(core.contains) == true }
        let spare = slots.indices.filter { !kept.contains($0) }
        let shown = Set((kept + spare).prefix(capacity - 1))
        return (slots.indices.filter(shown.contains).map { slots[$0] }, slots.count - shown.count)
    }
}

/// Bottom row (replaces the F-key bar): F1–F10 at rest; holding modifiers for a moment shows that layer.
/// Click a slot = press its key. "Hold ▾" pins a layer for the mouse until ⎋ or the next command.
@MainActor
final class KeyBarView: NSView {
    var onRun: ((String) -> Void)?
    var onMore: ((NSEvent.ModifierFlags) -> Void)?
    var canRun: (String) -> Bool = { _ in true }
    var terminalShown: () -> Bool = { false }
    /// The active panel is a server's (F8: Delete…).
    var server = false {
        didSet { if server != oldValue { reload(commands) } }
    }

    private var commands: [Command] = []
    private var layers: [(mods: NSEvent.ModifierFlags, slots: [KeySlot])] = []
    private var held: NSEvent.ModifierFlags = []
    private(set) var pinned: NSEvent.ModifierFlags?
    private var holdTask: Task<Void, Never>?
    private let hold = NSButton(title: "", target: nil, action: nil)
    private let row = NSStackView()
    private var capacity = 10

    init() {
        super.init(frame: .zero)
        hold.target = self
        hold.action = #selector(showLayerMenu)
        hold.bezelStyle = .accessoryBarAction
        hold.refusesFirstResponder = true
        hold.toolTip = "Hold ⇧ ⌥ ⌘ ⌃ to see their keys, or pick a layer here"
        hold.setContentHuggingPriority(.required, for: .horizontal)
        hold.widthAnchor.constraint(equalToConstant: 84).isActive = true
        row.distribution = .fillEqually
        row.spacing = 2
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        row.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [hold, row])
        stack.spacing = 6
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 4, right: 4)
        stack.setHuggingPriority(.defaultHigh, for: .vertical)   // as tall as its keys: the panels above take the rest
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload(_ commands: [Command]) {
        self.commands = commands
        layers = KeyBarModel.layers(commands, server: server)
        render()
    }

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
        pinned = nil
        render()
    }

    func unpin() -> Bool {
        guard pinned != nil else { return false }
        pinned = nil
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
        let c = max(2, Int((bounds.width - 100) / 86))
        if c != capacity {
            capacity = c
            Task { render() }   // not while AppKit is laying out
        }
    }

    func render() {
        let mods = pinned ?? held
        hold.title = pinned == nil && !held.isEmpty ? "Holding" : "Hold \(pinned.map(KeyBarModel.symbol) ?? "—") ▾"
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let slots = terminalShown() ? [KeySlot(key: "⌃O", label: "Panels", id: "view.terminal")]
            : layers.first { $0.mods == mods }?.slots ?? []
        guard !slots.isEmpty else {
            let l = NSTextField(labelWithString: "No commands for \(KeyBarModel.symbol(mods)) · F1 — all keys")
            l.textColor = .secondaryLabelColor
            return row.addArrangedSubview(l)
        }
        let (shown, more) = KeyBarModel.fit(slots, capacity: capacity)
        for s in shown {
            let b = slotButton(s.key, s.label, #selector(slotClicked(_:)))
            b.identifier = s.id.map { .init($0) }
            b.isEnabled = s.id.map(canRun) ?? false
            row.addArrangedSubview(b)
        }
        if more > 0 {
            let b = slotButton("+\(more)", "", #selector(moreClicked))
            b.toolTip = "All \(KeyBarModel.symbol(mods)) keys"
            row.addArrangedSubview(b)
        }
    }

    private func slotButton(_ key: String, _ label: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        let t = NSMutableAttributedString(string: label.isEmpty ? key : key + " ", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        t.append(NSAttributedString(string: label, attributes: [.foregroundColor: NSColor.labelColor]))
        b.attributedTitle = t
        b.bezelStyle = .accessoryBarAction
        b.refusesFirstResponder = true
        b.lineBreakMode = .byTruncatingTail
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return b
    }

    @objc private func slotClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, canRun(id) else { return NSSound.beep() }
        onRun?(id)
    }

    @objc private func moreClicked() { onMore?(pinned ?? held) }

    @objc private func showLayerMenu() {
        let names: [(NSEvent.ModifierFlags, String)] = [(.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command")]
        let menu = NSMenu()
        for l in layers where l.slots.contains(where: { $0.id != nil }) {   // not a layer of hints alone
            let name = l.mods.isEmpty ? "— F-keys" : KeyBarModel.symbol(l.mods) + "  " + names.filter { l.mods.contains($0.0) }.map(\.1).joined(separator: "-")
            let it = NSMenuItem(title: "\(name)  (\(l.slots.filter { $0.id != nil }.count))", action: #selector(pickLayer(_:)), keyEquivalent: "")
            it.target = self
            it.tag = Int(l.mods.rawValue)
            it.state = l.mods == (pinned ?? []) ? .on : .off
            menu.addItem(it)
        }
        let h = menu.size.height + 4   // open upwards: the bar is at the bottom of the window
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: hold.isFlipped ? -h : hold.bounds.height + h), in: hold)
    }

    @objc private func pickLayer(_ sender: NSMenuItem) {
        let m = NSEvent.ModifierFlags(rawValue: UInt(sender.tag))
        pinned = m.isEmpty ? nil : m
        render()
    }
}
