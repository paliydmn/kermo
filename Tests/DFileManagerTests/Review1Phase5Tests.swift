import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Review 1, phase 5: dialogs — one anatomy, one style, one modality.

/// Every view under `v`, depth first.
@MainActor private func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
@MainActor private func texts(_ a: NSAlert) -> [String] { a.accessoryView.map(all)?.compactMap { ($0 as? NSTextField)?.stringValue } ?? [] }

/// R-54: the title is the question, its buttons the action, its others, then Cancel; the strip shows only for
/// production or root; up to five items, then "and N more"; the command as given, in mono; the note.
@MainActor @Test func aConfirmationHasOneAnatomy() throws {
    var c = Confirm("Delete 7 items on web-01 permanently?", action: "Delete")
    (c.chips, c.place) = ([.prod, .locked], "web-01")
    c.items = (1...7).map { Confirm.Item(name: "f\($0).txt", symbol: .doc, size: "\($0) KB") }
    c.runs = "Runs on web-01 as root, through the server's sudo."
    c.command = "rm -rf -- /var/www/site/old\nsecond line"
    c.note = "A server has no Trash. This can't be undone."
    c.others = ["Compare"]
    let a = c.alert()
    #expect(a.messageText == "Delete 7 items on web-01 permanently?" && a.informativeText.isEmpty)
    #expect(a.buttons.map(\.title) == ["Delete", "Compare", "Cancel"] && c.buttons == a.buttons.map(\.title))
    let shown = texts(a)
    #expect(shown.contains("f1.txt") && shown.contains("f5.txt") && !shown.contains("f6.txt") && shown.contains("and 2 more"))
    #expect(shown.contains("5 KB") && shown.contains(c.runs!) && shown.contains(c.note!))
    let mono = a.accessoryView.map(all)?.compactMap { $0 as? NSTextField }.first { $0.font?.isFixedPitch == true }
    #expect(mono?.stringValue == c.command, "the command as it runs, not a paraphrase")
    #expect(a.accessoryView.map(all)?.contains { $0 is TintBox && $0.subviews.first?.accessibilityLabel() == "production: web-01" } == true, "production's strip")
    #expect(Confirm.strip([.locked], "web-01") == nil && Confirm.strip([], "x") == nil, "no strip but production's or root's")
    #expect(Confirm.strip([.root], "this Mac") != nil)
    #expect(Confirm.list((1...5).map { Confirm.Item(name: "\($0)") }).subviews.count == 5, "five: no \"and 0 more\"")
}

/// R-54 6–7, research §5.8: on production and for what can't be undone ↩ is Cancel and the action ⌘↩ — and a line says
/// so; elsewhere ↩ is the action and ⎋ Cancel, and no line. Red only for what can't be undone.
@MainActor @Test func returnIsCancelWhereItMatters() {
    func keys(_ a: NSAlert) -> [String] { a.buttons.map { ($0.keyEquivalentModifierMask == .command ? "⌘" : "") + $0.keyEquivalent } }
    func hint(_ a: NSAlert) -> Bool { texts(a).contains { $0.contains("Cancel") && $0.contains("Delete") } }
    var c = Confirm("Delete the tunnel “db”?", action: "Delete")
    #expect(!c.safe && keys(c.alert()) == ["\r", "\u{1b}"] && !hint(c.alert()) && !c.alert().buttons[0].hasDestructiveAction)
    c.irreversible = true
    #expect(c.safe && keys(c.alert()) == ["⌘\r", "\r"] && hint(c.alert()) && c.alert().buttons[0].hasDestructiveAction)
    var prod = Confirm("Restart nginx on web-01?", action: "Restart")
    prod.chips = [.prod]
    #expect(prod.safe && keys(prod.alert()) == ["⌘\r", "\r"] && !prod.alert().buttons[0].hasDestructiveAction, "production: ↩ Cancel, not red")
    var root = Confirm("Let sudo in Terminal use Touch ID?", action: "Enable")
    root.chips = [.root]
    #expect(!root.safe, "root alone: the strip, ↩ the action")
    var stop = Confirm("Stop web?", action: "Stop")
    stop.returnCancels = true
    #expect(stop.safe && keys(stop.alert()) == ["⌘\r", "\r"])
    var mine = Confirm("“a.txt” changed on disk", action: "Reload")
    (mine.cancel, mine.irreversible) = ("Keep Mine", true)
    #expect(mine.buttons == ["Reload", "Keep Mine"] && keys(mine.alert()) == ["⌘\r", "\r"], "Keep Mine is the safe one: ↩")
    #expect(texts(mine.alert()).contains { $0.contains("Keep Mine") && $0.contains("Reload") })
}

/// R-53, HIG: as macOS lays an alert out — two buttons in a row, the action right of Cancel (Keep Mine left of
/// Reload); three or more one under another, the action on top, Cancel at the bottom.
@MainActor @Test func buttonsSitWhereHIGPutsThem() {
    var two = Confirm("q", action: "Delete")
    two.irreversible = true
    let a = two.alert()
    a.layout()
    #expect(a.buttons[1].frame.minX < a.buttons[0].frame.minX, "Cancel · Delete")
    var mine = Confirm("q", action: "Reload")
    mine.cancel = "Keep Mine"
    let m = mine.alert()
    m.layout()
    #expect(m.buttons[1].frame.minX < m.buttons[0].frame.minX, "Keep Mine · Reload")
    var three = Confirm("q", action: "Reload")
    three.others = ["Compare"]
    let t = three.alert()
    t.layout()
    #expect(t.buttons[0].frame.minY > t.buttons[1].frame.minY && t.buttons[1].frame.minY > t.buttons[2].frame.minY, "Reload, Compare, Cancel from the top")
}

/// R-57: F5's question says what and how many before where — names (five, then "and N more") with the sizes the
/// panel shows; a folder's size only once counted.
@MainActor @Test func copyAsksWithWhatAndHowMany() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r1p5-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir + "/a.txt", contents: Data(count: 2048))
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let a = URL(fileURLWithPath: dir + "/a.txt"), until = Date().addingTimeInterval(60)   // D-097: a loaded run lists late
    while panel.listed([a])[0].symbol == nil, Date() < until { try await Task.sleep(for: .milliseconds(10)) }
    try #require(panel.listed([a])[0].symbol != nil)
    let listed = panel.listed([URL(fileURLWithPath: dir + "/a.txt"), URL(fileURLWithPath: dir + "/sub"), URL(fileURLWithPath: "/elsewhere/b")])
    #expect(listed.map(\.name) == ["a.txt", "sub", "b"])
    #expect(listed.map(\.size) == ["2 KB", "", ""] && listed[0].symbol == .doc && listed[1].symbol == .folder && listed[2].symbol == nil)
}

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The sources, line by line, comments out: (file, line number, text).
private func sourceLines() throws -> [(file: String, n: Int, text: String)] {
    var out: [(String, Int, String)] = []
    for case let file as URL in FileManager.default.enumerator(at: root.appendingPathComponent("Sources/DFileManager"), includingPropertiesForKeys: nil)!
    where file.pathExtension == "swift" {
        for (i, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated()
        where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { out.append((file.lastPathComponent, i + 1, line)) }
    }
    return out
}

/// R-52, R-54: app-modal only where there's no window or the question is the whole app's — through
/// `AppDelegate.modal` — and the server sheet's key chooser; production said by the strip, never in words; red and
/// "↩ = Cancel" built in one place, `Confirm` (a form's Delete… button opens one).
@Test func dialogsGoThroughOneBuilder() throws {
    var found: [String] = []
    for (file, n, line) in try sourceLines() {
        let at = "\(file):\(n)"
        if line.contains("runModal()"), !["AppDelegate.swift", "Commands.swift"].contains(file) || (file == "Commands.swift" && !line.contains("open.runModal()")) {
            found.append("\(at): runModal outside AppDelegate.modal")
        }
        for words in ["prodNote", "is a production server", "are production servers", "(production)"] where line.contains(words) { found.append("\(at): \(words)") }
        if line.contains("hasDestructiveAction"), file != "Confirm.swift", !line.contains("\"Delete…\"") { found.append("\(at): red outside Confirm") }
        if line.range(of: #"default: [1-9]"#, options: .regularExpression) != nil { found.append("\(at): ↩ = Cancel outside Confirm") }
        if line.contains("await confirm(\""), line.contains("info:") { found.append("\(at): the old confirm") }
    }
    #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    let modal = try sourceLines().filter { $0.text.contains("AppDelegate.modal(") || $0.text.contains("Self.modal(") }.map { "\($0.file)" }
    #expect(Set(modal) == ["AppDelegate.swift", "Editor.swift", "EmbeddedTerminal.swift", "PanelViewController.swift"],
            "Quit; an editor that failed to open, a terminal question, Disconnect SFTP and Paste — each only with no window")
}

/// R-55: a taken name — two cards with the panel's sizes and dates, "Newer" on the newer by date; Replace, Skip, Keep
/// Both, Cancel answer as Overwrite, Skip, Keep Both and Cancel did; "Only replace older files" makes Replace the old
/// Overwrite if Newer. Apply to all only where it was; Compare… only file over file, when there's a diff to show.
@MainActor @Test func aTakenNameShowsTwoCards() throws {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let c = FileJob.Conflict(src: "/Users/me/Downloads/config.yaml", dst: "/srv/site/config.yaml", srcSize: 185, dstSize: 190,
                             srcMtime: now.timeIntervalSince1970 - 60, dstMtime: now.timeIntervalSince1970 - 86_400 * 12, bothDirs: false)
    let q = OpsController.conflictQuestion(c, from: .local, on: .local, compare: true, now: now)
    #expect(q.alert.messageText == "“config.yaml” is already in site")
    #expect(q.alert.buttons.map(\.title) == ["Replace", "Skip", "Keep Both", "Cancel"] && q.alert.buttons[0].keyEquivalent == "\r")
    let cards = q.alert.accessoryView.map(all)?.compactMap { $0.isAccessibilityElement() ? $0.accessibilityLabel() : nil } ?? []
    let when = DateColumn(now)
    #expect(cards.contains("In site now: config.yaml, 190 B · \(when.text(Date(timeIntervalSince1970: c.dstMtime)))"), "\(cards)")
    #expect(cards.contains("From Downloads: config.yaml, 185 B · \(when.text(Date(timeIntervalSince1970: c.srcMtime))), newer"), "\(cards)")
    #expect(q.choice(0) == .overwrite && q.choice(1) == .skip && q.choice(2) == .keepBoth && q.choice(3) == .cancel)
    q.older?.state = .on
    #expect(q.choice(0) == .overwriteIfNewer && q.choice(1) == .skip, "the old Overwrite if Newer, through Replace")
    #expect(q.alert.showsSuppressionButton && q.alert.suppressionButton?.title == "Apply to all remaining conflicts" && q.link?.title == "Compare…")

    var mine = c
    mine.createdByThisJob = true
    #expect(!OpsController.conflictQuestion(mine, from: .local, on: .local, compare: false).alert.showsSuppressionButton)
    #expect(OpsController.conflictQuestion(mine, from: .local, on: .local, compare: false).link == nil)
    let dirs = OpsController.conflictQuestion(FileJob.Conflict(src: "/a/x", dst: "/b/x", srcSize: 0, dstSize: 0, srcMtime: 1, dstMtime: 1, bothDirs: true),
                                              from: .local, on: .local, compare: true)
    #expect(dirs.alert.buttons.map(\.title) == ["Merge", "Skip", "Keep Both", "Cancel"] && dirs.choice(0) == .overwrite && dirs.older == nil && dirs.link == nil)
    #expect(dirs.alert.suppressionButton?.title == "Apply to all remaining folders")
    var folder = c
    folder.replacesFolder = true
    let f = OpsController.conflictQuestion(folder, from: .local, on: .local, compare: true)
    #expect(f.alert.buttons.map(\.title) == ["Skip", "Keep Both", "Replace Folder", "Cancel"] && f.choice(0) == .skip && f.choice(2) == .overwrite)
    #expect(!f.alert.showsSuppressionButton)
}

extension ServerLockTests {
/// R-55 on a production server: its strip and name in the title, the cards named by machine, ↩ Cancel and ⌘↩ Replace.
@MainActor @Test func aTakenNameOnProductionAsksSafely() {
    var prod = SavedServer(address: "deploy@web.invalid")!
    (prod.prod, prod.name) = (true, "web-01")
    ServerLock.servers = { [prod] }
    defer { ServerLock.servers = { [] } }
    let c = FileJob.Conflict(src: "/Users/me/site/a.conf", dst: "/srv/site/a.conf", srcSize: 1, dstSize: 2, srcMtime: 5, dstMtime: 5, bothDirs: false)
    let q = OpsController.conflictQuestion(c, from: .local, on: .sftp(prod.target), compare: true)
    #expect(q.alert.messageText == "“a.conf” is already in site on web-01")
    #expect(q.alert.buttons.map { ($0.keyEquivalentModifierMask == .command ? "⌘" : "") + $0.keyEquivalent } == ["⌘\r", "", "", "\r"])
    let labels = q.alert.accessoryView.map(all)?.compactMap { $0.isAccessibilityElement() ? $0.accessibilityLabel() : nil } ?? []
    #expect(labels.contains { $0.hasPrefix("On web-01 now: a.conf") && !$0.hasSuffix("newer") } && labels.contains { $0.hasPrefix("From this Mac: a.conf") })
    #expect(q.alert.accessoryView.map(all)?.contains { $0.accessibilityLabel() == "production: web-01" } == true, "the strip")
}
}
