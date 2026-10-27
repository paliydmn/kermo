import AppKit
import Testing
@testable import DFileManager

// Review 1, phase 6: Settings (⌘,) — tabs of rows, each an option the code reads, written and applied its way.

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor private func window(_ app: AppDelegate, tabs: [SettingsTab]? = nil, defaults: UserDefaults = UserDefaults(suiteName: "kermo-settings-\(UUID().uuidString)")!) -> SettingsWindow {
    _ = NSApplication.shared
    if app.commands.isEmpty { app.commands = app.makeCommands() }
    let w = SettingsWindow(app: app, tabs: tabs ?? app.settingsTabs, defaults: defaults)
    w.refresh()
    return w
}

/// A control of the window by its row's title (its accessibility label), on any tab.
@MainActor private func control<T: NSView>(_ w: SettingsWindow, _ label: String, as: T.Type = NSControl.self) -> T? {
    func find(_ v: NSView) -> T? {
        if let t = v as? T, v.accessibilityLabel() == label || (v as? ThemeSwatch)?.theme.name == label { return t }
        return v.subviews.lazy.compactMap(find).first
    }
    return w.tabs.tabViewItems.lazy.compactMap { $0.viewController.map { find($0.view) } ?? nil }.first
}

@MainActor private func click(_ c: NSControl) { _ = (c.target as? NSObject)?.perform(c.action, with: c) }

/// The keys the code reads: `forKey: "…"`, and the terminal's two switches and drawer read by name.
private func keysRead() throws -> Set<String> {
    let read = try NSRegularExpression(pattern: #"(?:forKey:|Self\.on\(|heightKey:)\s*"([A-Za-z0-9_.]+)""#)
    var keys = Set<String>()
    for case let file as URL in FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
        let s = try String(contentsOf: file, encoding: .utf8)
        for m in read.matches(in: s, range: NSRange(s.startIndex..., in: s)) { keys.insert((s as NSString).substring(with: m.range(at: 1))) }
    }
    return keys
}

/// Every option of docs/configuration.md's Options table is a row with its key, and no row has a key the code doesn't read.
@MainActor @Test func everyOptionIsASettingsRow() throws {
    let page = try String(contentsOf: root.appendingPathComponent("docs/configuration.md"), encoding: .utf8)
    let options = page.components(separatedBy: "## Options").last!.components(separatedBy: "\n## ").first!
    let documented = Set(options.split(separator: "\n").compactMap { line -> String? in
        guard line.hasPrefix("| `"), let end = line.dropFirst(3).firstIndex(of: "`") else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: 3)..<end])
    })
    #expect(documented.count >= 15, "the scan found the table")
    let app = AppDelegate(), rows = app.settingsTabs.flatMap { $0.groups.flatMap(\.rows) }, keys = Set(rows.compactMap(\.key))
    #expect(documented.subtracting(keys).isEmpty, "documented, no row in Settings: \(documented.subtracting(keys).sorted())")
    let unread = keys.subtracting(try keysRead())
    #expect(unread.isEmpty, "a row whose key nothing reads: \(unread.sorted())")
    let w = window(app)   // each key is shown on its row
    for k in keys { #expect(labels(w).contains(k), "\(k) isn't shown") }
}

@MainActor private func labels(_ w: SettingsWindow) -> Set<String> {
    func all(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(all) }
    return Set(w.tabs.tabViewItems.flatMap { $0.viewController.map { all($0.view) } ?? [] })
}

/// Tools PR 5 / 8 add Monitor and Tools: one entry each.
@MainActor @Test func aNewTabIsOneEntry() {
    let app = AppDelegate()
    let monitor = SettingsTab(title: "Monitor", symbol: .general, groups: [("Notifications", [SettingsRow(title: "Alerts", key: "kermoTestKey", control: .toggle(true))])])
    let suite = UserDefaults(suiteName: "kermo-settings-\(UUID().uuidString)")!
    let w = window(app, tabs: app.settingsTabs + [monitor], defaults: suite)
    #expect(w.tabs.tabViewItems.map(\.label) == ["General", "Appearance", "Terminal", "Editor & Viewer", "Servers & Safety", "Advanced", "Monitor"])
    let s = try? #require(control(w, "Alerts", as: NSSwitch.self))
    #expect(s?.state == .on, "its default")
    s?.state = .off
    s.map(click)
    #expect(suite.object(forKey: "kermoTestKey") as? Bool == false, "written to the window's defaults")
}

/// ⌘, opens it from the Kermo menu.
@MainActor @Test func settingsIsACommand() {
    let c = AppDelegate().makeCommands().first { $0.id == "app.settings" }
    #expect(c?.title == "Settings…" && c?.menu == "Kermo" && c?.keys.map(\.display) == ["⌘,"])
}

extension ServerLockTests {
    /// A row writes the key the code reads and applies it as the menu does: Dates → the panels' Modified column at
    /// once, a theme → applyTheme, Show hidden files → the command View ▸ Hidden Files runs. (`UserDefaults.standard`:
    /// where the code reads them; put back after.)
    @Test func aRowWritesItsKeyAndAppliesIt() throws {
        let std = UserDefaults.standard, saved = ["isoDates", "theme", "showHidden"].map { ($0, std.object(forKey: $0)) }
        defer { for (k, v) in saved { if let v { std.set(v, forKey: k) } else { std.removeObject(forKey: k) } } }
        std.removeObject(forKey: "isoDates")
        std.removeObject(forKey: "theme")
        std.set(false, forKey: "showHidden")
        let app = AppDelegate()
        let panel = PanelViewController(tabs: [NSTemporaryDirectory()], index: 0, showHidden: false)
        panel.loadViewIfNeeded()
        defer { panel.shutdown() }
        app.panels = [panel]
        app.window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        app.terminal = EmbeddedTerminal(covering: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        let w = window(app, defaults: std)

        let dates = try #require(control(w, "Dates", as: NSSegmentedControl.self))
        #expect(dates.selectedSegment == 0 && !panel.dates.iso)
        dates.selectedSegment = 1
        click(dates)
        #expect(std.bool(forKey: "isoDates") && panel.dates.iso, "the panel's column at once, not in 3 s")

        let mc = try #require(control(w, "Midnight Commander", as: ThemeSwatch.self))
        click(mc)
        #expect(std.string(forKey: "theme") == "Midnight Commander" && app.window.appearance?.name == .darkAqua && mc.isChosen)

        let hidden = try #require(control(w, "Show hidden files", as: NSSwitch.self))
        #expect(hidden.state == .off)
        click(hidden)
        #expect(std.bool(forKey: "showHidden") && panel.showHidden && hidden.state == .on, "View ▸ Hidden Files ran")
    }
}
