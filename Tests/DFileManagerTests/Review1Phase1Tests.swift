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


/// The Modified column: today's and yesterday's by those words — from midnight to midnight — this year's by month and
/// day, older by the ISO day, 24-hour and in English whatever the locale; `isoDates` keeps "2026-10-25 13:33".
@Test func datesSayTodayYesterdayThenTheDay() {
    let cal = Calendar.current
    func at(_ m: Int, _ d: Int, _ h: Int, _ min: Int, year: Int = 2026) -> Date { cal.date(from: DateComponents(year: year, month: m, day: d, hour: h, minute: min))! }
    let c = DateColumn(at(10, 25, 14, 0), iso: false)
    #expect(c.text(at(10, 25, 0, 0)) == "Today 00:00" && c.text(at(10, 25, 13, 33)) == "Today 13:33")
    #expect(c.text(at(10, 24, 0, 0)) == "Yesterday 00:00" && c.text(at(10, 24, 23, 59)) == "Yesterday 23:59")
    #expect(c.text(at(10, 23, 23, 59)) == "Oct 23 23:59" && c.text(at(1, 1, 9, 5)) == "Jan 1 09:05", "this year's: month and day")
    #expect(c.text(at(12, 31, 23, 59, year: 2025)) == "2025-12-31" && c.text(at(1, 1, 0, 0, year: 2027)) == "2027-01-01")
    #expect(c.text(at(10, 26, 9, 0)) == "Oct 26 09:00", "tomorrow (a clock ahead) isn't today")
    #expect(DateColumn(at(10, 25, 14, 0), iso: true).text(at(10, 25, 13, 33)) == "2026-10-25 13:33")
    #expect(DateColumn(at(10, 25, 23, 59), iso: false) != DateColumn(at(10, 26, 0, 0), iso: false), "a new day: the column is drawn again")
}

extension ServerLockTests {
/// The Connect picker (⌃⌘K, ⌘K) says production and locked by the servers' chips, before their names. It lists this
/// Mac's ~/.ssh/config hosts after the saved servers too: only read, and found by title, so they don't matter here.
@MainActor @Test func connectPickerShowsChips() {
    var web = SavedServer(address: "me@web.invalid")!, vault = SavedServer(address: "me@vault.invalid")!
    (web.name, web.prod, vault.name, vault.locked) = ("web", true, "vault", true)
    let app = AppDelegate()
    app.savedServers = [web, vault, SavedServer(address: "me@plain.invalid")!]
    app.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
    defer { Picker.dismiss(); app.window = nil }
    app.showConnect()
    let rows = Picker.current?.rows ?? []
    func chips(_ title: String) -> [String?]? { rows.first { $0.title == title }?.badges.map(\.accessibilityDescription) }
    #expect(chips("web") == ["production"] && chips("vault") == ["locked"] && chips("me@plain.invalid") == [])
}
}

/// A failed or pending login marks its own server — host and port — not every saved server on that address (two
/// containers behind port forwards on 127.0.0.1).
@Test func aFailureMarksOnlyItsPort() {
    var a = SavedServer(address: "deploy@127.0.0.1:52201")!, b = SavedServer(address: "deploy@127.0.0.1:52203")!
    (a.name, b.name) = ("web", "staging")
    var list = ServerList(saved: [a, b])
    list.errors[ServerRow.key(b.target)] = "Connection refused"
    list.connecting = [ServerRow.key(a.target)]
    let rows = SidebarModel.serverRows(list)
    #expect(rows.first { $0.title == "staging" }?.status == .failed("Connection refused"))
    #expect(rows.first { $0.title == "web" }?.status == .connecting)
}
