import AppKit

/// Panel color schemes; View ▸ Theme… (stored in defaults as "theme").
struct Theme {
    let name: String
    var background: NSColor? = nil   // nil: system colors, alternating rows
    var text: NSColor = .labelColor
    var dir: NSColor = .labelColor
    var exec: NSColor = .labelColor
    var hidden: NSColor = .secondaryLabelColor
    var marked: NSColor = Palette.accent   // with bold and a ✓: themes keep their own
    var cursor: NSColor? = nil       // nil: system selection
    var grid: NSColor? = nil         // column separators
    var mono = false

    static let all: [Theme] = [
        Theme(name: "System"),
        Theme(name: "Midnight Commander", background: rgb(0x0000AA), text: rgb(0xC8C8C8), dir: .white, exec: rgb(0x55FF55),
              hidden: rgb(0x8C8CD8), marked: rgb(0xFFFF55), cursor: rgb(0x008C8C), grid: rgb(0x00AAAA), mono: true),
        Theme(name: "Solarized Dark", background: rgb(0x002B36), text: rgb(0x93A1A1), dir: rgb(0x268BD2), exec: rgb(0x859900),
              hidden: rgb(0x586E75), marked: rgb(0xCB4B16), cursor: rgb(0x0B4F5E), mono: true),
        Theme(name: "Far Manager", background: rgb(0x000080), text: rgb(0x55FFFF), dir: .white, exec: rgb(0x55FF55),
              hidden: rgb(0x5F87AF), marked: rgb(0xFFFF55), cursor: rgb(0x008080), grid: rgb(0x55FFFF), mono: true),
        Theme(name: "Dracula", background: rgb(0x282A36), text: rgb(0xF8F8F2), dir: rgb(0xBD93F9), exec: rgb(0x50FA7B),
              hidden: rgb(0x6272A4), marked: rgb(0xFF79C6), cursor: rgb(0x44475A), mono: true),
        Theme(name: "Nord", background: rgb(0x2E3440), text: rgb(0xD8DEE9), dir: rgb(0x88C0D0), exec: rgb(0xA3BE8C),
              hidden: rgb(0x616E88), marked: rgb(0xEBCB8B), cursor: rgb(0x434C5E), mono: true),
        Theme(name: "Gruvbox Dark", background: rgb(0x282828), text: rgb(0xEBDBB2), dir: rgb(0x83A598), exec: rgb(0xB8BB26),
              hidden: rgb(0x928374), marked: rgb(0xFABD2F), cursor: rgb(0x504945), mono: true),
        Theme(name: "Monokai", background: rgb(0x272822), text: rgb(0xF8F8F2), dir: rgb(0x66D9EF), exec: rgb(0xA6E22E),
              hidden: rgb(0x75715E), marked: rgb(0xF92672), cursor: rgb(0x49483E), mono: true),
        Theme(name: "One Dark", background: rgb(0x282C34), text: rgb(0xABB2BF), dir: rgb(0x61AFEF), exec: rgb(0x98C379),
              hidden: rgb(0x5C6370), marked: rgb(0xE5C07B), cursor: rgb(0x3E4451), mono: true),
        Theme(name: "Tokyo Night", background: rgb(0x1A1B26), text: rgb(0xA9B1D6), dir: rgb(0x7AA2F7), exec: rgb(0x9ECE6A),
              hidden: rgb(0x565F89), marked: rgb(0xFF9E64), cursor: rgb(0x283457), mono: true),
        Theme(name: "Catppuccin Mocha", background: rgb(0x1E1E2E), text: rgb(0xCDD6F4), dir: rgb(0x89B4FA), exec: rgb(0xA6E3A1),
              hidden: rgb(0x6C7086), marked: rgb(0xF38BA8), cursor: rgb(0x45475A), mono: true),
        Theme(name: "Solarized Light", background: rgb(0xFDF6E3), text: rgb(0x657B83), dir: rgb(0x268BD2), exec: rgb(0x859900),
              hidden: rgb(0x93A1A1), marked: rgb(0xD33682), cursor: rgb(0xDDD6C1), mono: true),   // magenta: red says failed
        Theme(name: "GitHub Light", background: .white, text: rgb(0x24292F), dir: rgb(0x0969DA), exec: rgb(0x1A7F37),
              hidden: rgb(0x8C959F), marked: rgb(0xBF3989), cursor: rgb(0xDDF4FF)),   // pink, not red (failed) or blue (folders)
    ]

    /// Dark chrome on dark backgrounds; nil (system) for the System theme. Light themes keep light chrome. Dark is
    /// what white text reads better on: by luminance — pure blue's HSB brightness (0.67) passed for light (MC, Far).
    var appearance: NSAppearance? {
        background.flatMap { NSAppearance(named: Self.contrast($0, .white) > Self.contrast($0, .black) ? .darkAqua : .aqua) }
    }

    /// The cursor of a panel that isn't focused, an outline: the system's quietest label color, a theme's dimmed text.
    var outline: NSColor { background == nil ? .tertiaryLabelColor : hidden }
    /// The line under the active panel's path bar on this Mac: MC's and Far's cyan, else the theme's folder color.
    var accent: NSColor { background == nil ? Palette.accent : grid ?? dir }

    /// The ⌃O terminal's default text and background: a dark theme's own, with its text only if that reads at 7:1
    /// or better (WCAG AAA); else light gray on dark gray. Light themes get that too: the ANSI palette is for dark.
    var terminal: (text: NSColor, background: NSColor) {
        guard let bg = background, appearance?.name == .darkAqua else { return (Self.rgb(0xE6E6E6), Self.rgb(0x1E1E1E)) }
        return (Self.contrast(text, bg) >= 7 ? text : Self.rgb(0xE6E6E6), bg)
    }

    /// WCAG 2 contrast ratio, 1…21.
    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func luminance(_ c: NSColor) -> CGFloat {
            let c = c.usingColorSpace(.sRGB)!
            let f = { (v: CGFloat) in v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * f(c.redComponent) + 0.7152 * f(c.greenComponent) + 0.0722 * f(c.blueComponent)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @MainActor static var current: Theme { all.first { $0.name == UserDefaults.standard.string(forKey: "theme") } ?? all[0] }

    private static func rgb(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}

/// Draws the cursor row in the theme's color (nil, System: the system's selection) while the panel is focused, and an
/// outline in `outline` while it isn't — a dimmed fill read as one more selection.
final class PanelRowView: NSTableRowView {
    var cursor: NSColor?
    var outline: NSColor = .tertiaryLabelColor
    override func drawSelection(in dirtyRect: NSRect) {
        guard isEmphasized else {
            outline.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.75, dy: 0.75), xRadius: 4, yRadius: 4)
            path.lineWidth = 1.5
            return path.stroke()
        }
        guard let cursor else { return super.drawSelection(in: dirtyRect) }
        cursor.setFill()
        bounds.fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { cursor == nil ? super.interiorBackgroundStyle : .normal }   // a theme keeps its text colors
}

/// A column title on the theme's background (nil: the system's header).
final class PanelHeaderCell: NSTableHeaderCell {
    var fill: NSColor?
    override func draw(withFrame r: NSRect, in view: NSView) {
        guard let fill else { return super.draw(withFrame: r, in: view) }
        fill.setFill()
        r.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: r.maxX - 1, y: r.minY + 4, width: 1, height: r.height - 8).fill()
        NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
        drawInterior(withFrame: r.insetBy(dx: 0, dy: (r.height - attributedStringValue.size().height) / 2), in: view)   // centered, as the system's
    }
}

/// The header's piece above an always-shown scroller, for a theme with a background.
final class PanelHeaderCorner: NSView {
    let cell = PanelHeaderCell(textCell: "")
    override func draw(_ dirtyRect: NSRect) { cell.draw(withFrame: bounds, in: self) }
}

/// An always-shown scroller's track in the theme's background (nil: the system's).
final class ThemeScroller: NSScroller {
    var fill: NSColor?
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in r: NSRect, highlight: Bool) {
        guard let fill, scrollerStyle == .legacy else { return super.drawKnobSlot(in: r, highlight: highlight) }
        fill.setFill()
        r.fill()
    }
}
