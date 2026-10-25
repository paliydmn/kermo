import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Review 1, phase 1: one language of color and icons.

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Every symbol Kermo names is one this macOS has (a missing one would crash where it's force-unwrapped), and no code
/// names one past the registry, so the list stays whole. It can't tell which macOS brought a symbol: `Symbol` keeps to
/// SF Symbols 4 (macOS 13) by hand.
@Test func everySymbolExistsAndComesFromTheRegistry() throws {
    for s in Symbol.allCases { #expect(NSImage(systemSymbolName: s.rawValue, accessibilityDescription: nil) != nil, "\(s.rawValue)") }
    var outside: [String] = []
    for case let file as URL in FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
    where file.pathExtension == "swift" && file.lastPathComponent != "Palette.swift" {
        if try String(contentsOf: file, encoding: .utf8).contains("systemSymbolName:") { outside.append(file.lastPathComponent) }
    }
    #expect(outside.isEmpty, "symbols named outside `Symbol`: \(outside)")
}

/// A chip is a word in capitals that VoiceOver says in full, in its color: production purple, never red.
@MainActor @Test func chipsSayTheirWord() {
    #expect(Chip.allCases.map(\.word) == ["PROD", "ROOT", "LOCKED"])
    #expect(Chip.allCases.map { $0.image.accessibilityDescription } == ["production", "root", "locked"])
    #expect(Chip.prod.color == Palette.prod && Palette.prod != Palette.fail && Chip.root.color == Palette.root)
    let menu = Chip.prod.menuTitle("db1")
    #expect(menu.string == "PROD db1" && menu.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Palette.prod)
    #expect((Chip.prod.text.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image?.accessibilityDescription == "production")
}

/// Amber, the one color that isn't the system's, reads as text in both appearances (WCAG AA, 4.5:1).
@Test func warnReadsAsText() {
    for (name, background) in [(NSAppearance.Name.aqua, NSColor.white), (.darkAqua, NSColor(white: 0.12, alpha: 1)), (.aqua, NSColor(white: 0.96, alpha: 1))] {
        var ratio: CGFloat = 0
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { ratio = Theme.contrast(Palette.warn.usingColorSpace(.sRGB)!, background) }
        #expect(ratio >= 4.5, "\(name.rawValue): \(ratio)")
    }
}

/// A state reads by its shape too: failed is a diamond, needing a look a ring, on and off a dot.
@Test func statesHaveShapes() {
    #expect([StateMark.on, .failed, .attention, .off].map(\.symbol) == [.dot, .diamond, .ring, .dot])
    #expect(StateMark.failed.color == Palette.fail && StateMark.on.color == Palette.ok && StateMark.failed.image("failed").accessibilityDescription == "failed")
}

