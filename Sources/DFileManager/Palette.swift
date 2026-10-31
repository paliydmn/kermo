import AppKit
import DFMCore

/// Kermo's colors by what they mean, one meaning each: red that only ever says "failed" gets seen. System colors,
/// so light, dark and Increase Contrast come with them. Themes keep their own panel colors (`Theme`).
enum Palette {
    /// Selection, focus, the cursor, marked files.
    static let accent = NSColor.controlAccentColor
    /// Open, running, done.
    static let ok = NSColor.systemGreen
    /// Failed, or can't be undone.
    static let fail = NSColor.systemRed
    /// Look here: git modified, a sync conflict, a disk filling up. Amber, as no system color is: yellow doesn't
    /// read as text on white, and orange is root's.
    static let warn = NSColor(name: "warn") { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.949, green: 0.702, blue: 0.239, alpha: 1)
            : NSColor(srgbRed: 0.620, green: 0.369, blue: 0, alpha: 1)   // #9E5E00: 4.7:1 on the light rows
    }
    /// Acting as root.
    static let root = NSColor.systemOrange
    /// A production server — never red, which says something failed.
    static let prod = NSColor.systemPurple
    static let secondary = NSColor.secondaryLabelColor
    static let separator = NSColor.separatorColor
}

/// Every SF Symbol Kermo shows: names from here only, so a test can ask macOS for each. All of them are in
/// SF Symbols 4 or older (macOS 13), below Kermo's macOS 14.
enum Symbol: String, CaseIterable {
    // places
    case server = "server.rack", mac = "laptopcomputer", ssh = "apple.terminal", folder, doc, recent = "clock", network, archive = "archivebox",
         search = "magnifyingglass", internalDisk = "internaldrive", externalDisk = "externaldrive", tag, command, list = "list.bullet"
    // marks
    case lock = "lock.fill", root = "number", branch = "arrow.triangle.branch", tunnel = "arrow.left.arrow.right",
         notPublished = "icloud.and.arrow.up", sync = "arrow.triangle.2.circlepath", changes = "plusminus",
         activity = "clock.arrow.circlepath", star, add = "plus.circle", eject, refresh = "arrow.clockwise", filter = "line.3.horizontal.decrease"
    // states and results
    case check = "checkmark", warn = "exclamationmark.triangle", warnFill = "exclamationmark.triangle.fill", crit = "exclamationmark.octagon.fill",
         failed = "xmark.circle", dot = "circle.fill", ring = "circle", diamond = "diamond.fill", pending = "circle.dotted"
    // controls
    case close = "xmark", remove = "xmark.circle.fill", more = "ellipsis.circle", expand = "chevron.right",
         collapse = "chevron.down", pause = "pause.fill", resume = "play.fill", startNow = "forward.fill", show = "eye",
         hide = "eye.slash", sidebar = "sidebar.left", copy = "doc.on.doc", trash, down = "arrow.down", up = "arrow.up",
         splitRight = "rectangle.split.2x1", maximize = "arrow.up.left.and.arrow.down.right", restore = "arrow.down.right.and.arrow.up.left",
         right = "arrow.right", left = "arrow.left", plus, undo = "arrow.uturn.backward"
    // Settings' tabs
    case general = "gearshape", appearance = "paintpalette", keyboard, terminal, document = "doc.text", safety = "lock.shield",
         advanced = "slider.horizontal.3"
    // a Tools preset's, when it names none or one this macOS lacks
    case tool = "wrench"
    // watching: the menu bar's item, Snooze
    case monitor = "gauge.with.dots.needle.33percent", snooze = "bell.slash", maintenance = "wrench.and.screwdriver", quit = "power"

    /// `label`: what VoiceOver says for it.
    func image(_ label: String? = nil) -> NSImage { NSImage(systemSymbolName: rawValue, accessibilityDescription: label)! }

    /// A Tools preset's own `icon`, not one of Kermo's: whether this macOS has it, and its image — else `tool`'s.
    static func exists(_ name: String) -> Bool { NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil }
    static func preset(_ name: String?) -> NSImage { name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } ?? tool.image() }

    /// In `color`, `size` points — not a template, so a button's title or a menu draws it in that color, not its own.
    func image(_ label: String? = nil, color: NSColor, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage {
        let i = image(label).withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color])))!
        i.isTemplate = false
        return i
    }

    /// Inline in text — a list's mark, a tab title's state — in `color`, as big as `font`.
    func text(_ color: NSColor, font: NSFont, label: String? = nil) -> NSAttributedString {
        let a = NSTextAttachment()
        a.image = image(label, color: color, size: font.pointSize * 0.85, weight: .semibold)
        return NSAttributedString(attachment: a)
    }
}

/// A state by shape and color, so it reads without the color too: ● on (open, running, listening), ◆ failed,
/// ○ needs a look, a grey dot off. Busy is a spinner, where it shows.
enum StateMark {
    case on, failed, attention, off

    var symbol: Symbol { switch self { case .on, .off: .dot; case .failed: .diamond; case .attention: .ring } }
    var color: NSColor { switch self { case .on: Palette.ok; case .failed: Palette.fail; case .attention: Palette.warn; case .off: .tertiaryLabelColor } }
    func image(_ label: String, size: CGFloat = 8) -> NSImage { symbol.image(label, color: color, size: size) }
    func text(_ label: String, font: NSFont) -> NSAttributedString { symbol.text(color, font: font, label: label) }
}

/// A server's environment, said one way everywhere — path bar, Picker rows, the sidebar, terminal tabs, editor
/// titles: a capsule with a word in capitals (only these are), its color for the eye and the word for everyone else.
enum Chip: String, CaseIterable {
    case prod, root, locked

    var word: String { rawValue.uppercased() }
    /// What VoiceOver says.
    var spoken: String { self == .prod ? "production" : rawValue }
    var color: NSColor { switch self { case .prod: Palette.prod; case .root: Palette.root; case .locked: Palette.secondary } }

    /// A server's chips: production, root (a root panel's by default), locked with Touch ID.
    @MainActor static func of(_ t: SFTPTarget, root: Bool? = nil) -> [Chip] {
        [SavedServer.isProd(t) ? .prod : nil, root ?? t.sudo ? .root : nil, ServerLock.server(for: t)?.locked == true ? .locked : nil].compactMap { $0 }
    }

    /// The color of a place with these chips — the active panel's line, a tab's, the "→ F5" mark: production's (a
    /// production root panel's too: its chips say both), else root's; nil for anywhere else.
    static func tint(_ chips: [Chip]) -> NSColor? { chips.contains(.prod) ? Palette.prod : chips.contains(.root) ? Palette.root : nil }

    private static var font: NSFont { .systemFont(ofSize: 9.5, weight: .bold) }

    /// Drawn each time it shows, so it follows light and dark. ~9.5 pt caps on a 14 pt capsule: white on production's
    /// and root's color; locked, quieter, with its lock.
    var image: NSImage {
        let fg: NSColor = self == .locked ? .secondaryLabelColor : .white
        let text = NSAttributedString(string: word, attributes: [.font: Self.font, .foregroundColor: fg, .kern: 0.4])
        let lock = self == .locked ? Symbol.lock.image(nil, color: fg, size: 7.5, weight: .bold) : nil
        let lead: CGFloat = lock.map { 5 + $0.size.width + 2 } ?? 5
        let size = NSSize(width: ceil(lead + text.size().width + 5), height: 14)
        let image = NSImage(size: size, flipped: false) { r in
            (self == .locked ? NSColor.quaternaryLabelColor : color).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            lock?.draw(in: NSRect(x: 5, y: (r.height - lock!.size.height) / 2, width: lock!.size.width, height: lock!.size.height))
            text.draw(at: NSPoint(x: lead, y: (r.height - Self.font.capHeight) / 2 + Self.font.descender))
            return true
        }
        image.cacheMode = .never   // its colors are dynamic
        image.accessibilityDescription = spoken
        return image
    }

    /// Inline in text, on the text's baseline: a terminal tab's title, a checkbox's.
    var text: NSAttributedString {
        let a = NSTextAttachment()
        a.image = image
        a.bounds = NSRect(x: 0, y: -3, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: a)
    }

    /// Several inline, a space apart: a tab title's lead. nil for none.
    static func text(_ chips: [Chip]) -> NSAttributedString? {
        guard !chips.isEmpty else { return nil }
        let s = NSMutableAttributedString()
        for c in chips { if s.length > 0 { s.append(NSAttributedString(string: " ")) }; s.append(c.text) }
        return s
    }

    /// A state that just is, in a status line — `⎇ main ↑1`, `120 GB free`, `SFTP`: grey words on a light capsule,
    /// none of the colors above. Read out as its words.
    static func plain(_ words: String, symbol: Symbol? = nil) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let text = NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        let mark = symbol?.image(nil, color: .secondaryLabelColor, size: 9, weight: .semibold)
        let lead: CGFloat = mark.map { 5 + $0.size.width + 3 } ?? 5
        let size = NSSize(width: ceil(lead + text.size().width + 5), height: 16)
        let image = NSImage(size: size, flipped: false) { r in
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            mark?.draw(in: NSRect(x: 5, y: (r.height - mark!.size.height) / 2, width: mark!.size.width, height: mark!.size.height))
            text.draw(at: NSPoint(x: lead, y: (r.height - text.size().height) / 2))
            return true
        }
        image.cacheMode = .never   // its colors are dynamic
        image.accessibilityDescription = words
        let a = NSTextAttachment()
        a.image = image
        a.bounds = NSRect(x: 0, y: -4, width: size.width, height: size.height)
        return NSAttributedString(attachment: a)
    }

    /// For a menu item, which takes no picture in its title: the word in the chip's color, then the title.
    func menuTitle(_ title: String, size: CGFloat = 0) -> NSAttributedString {
        let s = NSMutableAttributedString(string: word + " ", attributes: [.foregroundColor: color, .font: NSFont.menuFont(ofSize: size).bold])
        s.append(NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: size)]))
        return s
    }
}

extension NSWindow {
    /// A server file's chips (production, root, locked) at the end of its title bar, as its panel's path bar shows
    /// them: the editor's and the viewer's.
    func showChips(_ chips: [Chip]) {
        guard !chips.isEmpty else { return }
        let stack = NSStackView(views: chips.map { NSImageView(image: $0.image) })
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        stack.frame.size = NSSize(width: stack.fittingSize.width, height: 28)
        let bar = NSTitlebarAccessoryViewController()
        bar.layoutAttribute = .trailing
        bar.view = stack
        addTitlebarAccessoryViewController(bar)
    }
}

/// A chip that gives way to a name in a narrow row (the sidebar's): drawn whole or not at all, never squeezed.
final class ChipView: NSView {
    let chip: Chip
    init(_ chip: Chip) {
        self.chip = chip
        super.init(frame: .zero)
        setContentCompressionResistancePriority(.init(240), for: .horizontal)   // below a name's
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(chip.spoken)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { chip.image.size }
    var shown: Bool { bounds.width >= intrinsicContentSize.width }
    override func draw(_ dirtyRect: NSRect) {
        guard shown else { return }
        let i = chip.image
        i.draw(in: NSRect(x: 0, y: (bounds.height - i.size.height) / 2, width: i.size.width, height: i.size.height))
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
