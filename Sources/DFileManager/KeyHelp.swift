import AppKit

/// F1: every bound key, grouped by menu, generated from the command registry (so keymap.json shows up).
/// Type to filter, ⎋ closes. The key bar's "+N" opens it on one modifier layer.
@MainActor
final class KeyHelp: NSObject, NSSearchFieldDelegate {
    typealias Section = (title: String, rows: [(title: String, keys: String)])

    /// The menus in menu bar order, the app's last: its only key is F1 itself.
    static let groups = Array(AppDelegate.menus.dropFirst() + AppDelegate.menus.prefix(1))

    /// Menu groups in `groups` order (keyboard-only commands last), each command with its keys.
    /// `layer`: only keys with exactly these modifiers. `query`: substring of title, aliases or keys.
    static func sections(_ commands: [Command], query: String = "", layer: NSEvent.ModifierFlags? = nil) -> [Section] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [(String, [(String, String)])] = []
        for g in groups + [nil] {
            let rows = commands.filter { $0.menu == g && !$0.hidden }.compactMap { c -> (String, String)? in
                let keys = c.keys.filter { layer == nil || $0.flags == layer }.map(\.display).joined(separator: "  ")
                guard !keys.isEmpty, q.isEmpty || "\(c.title) \(c.aliases) \(keys)".localizedCaseInsensitiveContains(q) else { return nil }
                return (c.title, keys)
            }
            if !rows.isEmpty { out.append((g ?? "Keyboard", rows)) }
        }
        return out
    }

    /// `sections`' rows whose title or keys contain `query`.
    static func filter(_ sections: [Section], _ query: String) -> [Section] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return sections.map { s in (s.title, s.rows.filter { q.isEmpty || "\($0.title) \($0.keys)".localizedCaseInsensitiveContains(q) }) }
            .filter { !$0.rows.isEmpty }
    }

    private static var current: KeyHelp?
    private let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    private let field = NSSearchField()
    private let text = NSTextView()
    private let commands: [Command]
    private let layer: NSEvent.ModifierFlags?
    private let fixed: [Section]?   // over a viewer or an editor: its keys, not the registry's
    private let fields: [Section]   // after the registry's: the text fields' own (`fieldKeys`)
    private weak var parent: NSWindow?

    /// The keys of the main window's text fields, as their key bar shows them while they have the focus (F1 doesn't
    /// come there: a field takes F1 for itself).
    static var fieldKeys: [Section] {
        [("Command Line", AppDelegate.commandLineKeys), ("Quick Filter", PanelViewController.filterKeys), ("Path Bar", PanelViewController.pathKeys)].map { title, slots in
            (title, slots.map { ($0.label, $0.key) })
        }
    }

    static func show(over window: NSWindow, commands: [Command], layer: NSEvent.ModifierFlags? = nil, fixed: [Section]? = nil, fields: [Section] = []) {
        current?.close()
        let h = KeyHelp(parent: window, commands: commands, layer: layer, fixed: fixed, fields: fields)
        current = h
        window.beginSheet(h.sheet)
        h.sheet.makeFirstResponder(h.field)
    }

    private init(parent: NSWindow, commands: [Command], layer: NSEvent.ModifierFlags?, fixed: [Section]?, fields: [Section]) {
        self.parent = parent
        self.commands = commands
        self.layer = layer
        self.fixed = fixed
        self.fields = fields
        super.init()
        field.placeholderString = layer.map { "Filter \(KeyBarModel.symbol($0)) keys" } ?? "Filter keys"
        field.delegate = self
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.keyEquivalent = "\r"
        let content = NSView()
        for v in [field, scroll, done] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            done.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        sheet.contentView = content
        sheet.minSize = NSSize(width: 420, height: 300)
        render()
    }

    private func render() {
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 300)]
        para.headIndent = 0
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
        let keys: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                                                   .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let s = NSMutableAttributedString()
        let sections = (fixed.map { Self.filter($0, field.stringValue) } ?? Self.sections(commands, query: field.stringValue, layer: layer))
            + Self.filter(fields, field.stringValue)
        for (i, sec) in sections.enumerated() {
            s.append(NSAttributedString(string: (i == 0 ? "" : "\n") + sec.title.uppercased() + "\n", attributes: head))
            for r in sec.rows {
                s.append(NSAttributedString(string: r.title + "\t", attributes: body))
                s.append(NSAttributedString(string: r.keys + "\n", attributes: keys))
            }
        }
        if sections.isEmpty { s.append(NSAttributedString(string: "No keys match.", attributes: body)) }
        text.textStorage?.setAttributedString(s)
    }

    @objc private func close() {
        parent?.endSheet(sheet)
        if Self.current === self { Self.current = nil }
    }

    func controlTextDidChange(_ obj: Notification) { render() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        close()
        return true
    }
}
