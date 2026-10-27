import Foundation
import Testing
@testable import DFileManager

/// This checkout's root.
private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func text(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

/// Every default shortcut of every command is on docs/shortcuts.md, as the menus write it (⌃⌥⇧⌘). A range there
/// ("⌘1…⌘4") covers the keys between; a few are written as the character typed ("⌘+" for ⇧⌘=).
@MainActor @Test func everyDefaultShortcutIsInTheDocs() throws {
    var page = try text("docs/shortcuts.md")
    let range = try NSRegularExpression(pattern: #"(\S*?)(\d)…\1(\d)"#)
    for m in range.matches(in: page, range: NSRange(page.startIndex..., in: page)) {
        let s = page as NSString, mods = s.substring(with: m.range(at: 1))
        guard let a = Int(s.substring(with: m.range(at: 2))), let b = Int(s.substring(with: m.range(at: 3))), a <= b else { continue }
        page += " " + (a...b).map { mods + "\($0)" }.joined(separator: " ")
    }
    let typed = ["⇧⌘=": "⌘+", "⇧=": "`+`"]
    var missing: [String] = []
    for c in AppDelegate().makeCommands() {
        for k in c.keys where !page.contains(k.display) && !(typed[k.display].map(page.contains) ?? false) {
            missing.append("\(c.title): \(k.display)")
        }
    }
    #expect(missing.isEmpty, "not on docs/shortcuts.md: \(missing)")
}

/// The `defaults` the app keeps by itself — window state, recents, choices made in the UI — aren't options to set by
/// hand, so docs/configuration.md leaves them out ("Leave those to the app"). A key the code reads that is in neither
/// list fails here: document it, or add it below.
private let keptByTheApp: Set<String> = [
    "folderSort", "lastMask", "listSort", "panelPaths", "placeLastList", "panelSession", "panelTabIndex", "panelTabs", "recentFilters", "recentServers", "recentTags",
    "runOnServers", "runOnServersCommand", "searchCase", "searchHidden", "searchFrecency", "searchName", "searchRecent", "searchSpotlight",
    "searchTag", "searchText", "showHidden", "showPerms", "sidebarFolded", "sidebarVisible", "splitSize", "sshTabs", "terminalGroups", "theme",
    "updateChecked", "updateLatest", "updateSkipped",
    "viewerLineNumbers",
]

@Test func everyOptionIsDocumented() throws {
    let page = try text("docs/configuration.md")
    let read = try NSRegularExpression(pattern: #"(?:forKey|forKey:)\s*:?\s*"([A-Za-z0-9_.]+)""#)
    var keys = Set<String>()
    let sources = root.appendingPathComponent("Sources")
    for case let file as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
        let s = try String(contentsOf: file, encoding: .utf8)
        for m in read.matches(in: s, range: NSRange(s.startIndex..., in: s)) { keys.insert((s as NSString).substring(with: m.range(at: 1))) }
    }
    #expect(keys.count > keptByTheApp.count, "the scan found the keys")
    let undocumented = keys.subtracting(keptByTheApp).filter { !page.contains("`\($0)`") }.sorted()
    #expect(undocumented.isEmpty, "read in Sources/, not on docs/configuration.md: \(undocumented)")
    #expect(keptByTheApp.subtracting(keys).isEmpty, "no longer read: \(keptByTheApp.subtracting(keys).sorted())")
}
