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
    case server = "server.rack", ssh = "apple.terminal", folder, recent = "clock", network, archive = "archivebox",
         search = "magnifyingglass", internalDisk = "internaldrive", externalDisk = "externaldrive", tag
    // marks
    case lock = "lock.fill", root = "number", branch = "arrow.triangle.branch", tunnel = "arrow.left.arrow.right",
         notPublished = "icloud.and.arrow.up", sync = "arrow.triangle.2.circlepath", changes = "plusminus",
         activity = "clock.arrow.circlepath", star, add = "plus.circle", eject, refresh = "arrow.clockwise"
    // states and results
    case check = "checkmark", warn = "exclamationmark.triangle", warnFill = "exclamationmark.triangle.fill",
         failed = "xmark.circle", dot = "circle.fill", ring = "circle", diamond = "diamond.fill", pending = "circle.dotted"
    // controls
    case close = "xmark", remove = "xmark.circle.fill", more = "ellipsis.circle", expand = "chevron.right",
         collapse = "chevron.down", pause = "pause.fill", resume = "play.fill", startNow = "forward.fill", show = "eye",
         hide = "eye.slash", sidebar = "sidebar.left", copy = "doc.on.doc", trash, down = "arrow.down", up = "arrow.up",
         right = "arrow.right", left = "arrow.left"

    /// `label`: what VoiceOver says for it.
    func image(_ label: String? = nil) -> NSImage { NSImage(systemSymbolName: rawValue, accessibilityDescription: label)! }

    /// In `color`, `size` points.
    func image(_ label: String? = nil, color: NSColor, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage {
        image(label).withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color])))!
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

    /// For a menu item, which takes no picture in its title: the word in the chip's color, then the title.
    func menuTitle(_ title: String, size: CGFloat = 0) -> NSAttributedString {
        let s = NSMutableAttributedString(string: word + " ", attributes: [.foregroundColor: color, .font: NSFont.menuFont(ofSize: size).bold])
        s.append(NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: size)]))
        return s
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
