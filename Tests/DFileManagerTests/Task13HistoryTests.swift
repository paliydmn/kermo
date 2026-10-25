import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 13: server file history and diff with a server.

/// `AppDelegate.historyRoot` and the `serverHistory` default are the app's: these tests take turns.
@Suite(.serialized) @MainActor struct HistoryAppTests {

/// Saves keep versions in ~/.config/dfilemanager/history.noindex (Spotlight stays out by the name) unless
/// `defaults write com.dmn.dfilemanager serverHistory -bool false`.
@Test func serverHistoryCanBeTurnedOff() {
    let app = AppDelegate()
    let was = UserDefaults.standard.object(forKey: "serverHistory")
    defer { UserDefaults.standard.set(was, forKey: "serverHistory") }
    UserDefaults.standard.removeObject(forKey: "serverHistory")
    #expect(app.serverHistory?.root == AppDelegate.historyRoot && AppDelegate.historyRoot == Config.path("history.noindex"))
    UserDefaults.standard.set(false, forKey: "serverHistory")
    #expect(app.serverHistory == nil)
}

/// Deleting a saved server offers to delete its file history too — only when it has one, and no other saved server
/// at that address keeps using it (as with its password).
@Test func deletingAServerOffersItsHistory() throws {
    let root = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-hdel-" + UUID().uuidString
    let was = AppDelegate.historyRoot
    AppDelegate.historyRoot = root
    defer { AppDelegate.historyRoot = was; try? FileManager.default.removeItem(atPath: root) }
    let app = AppDelegate()
    let web = SavedServer(address: "me@web.invalid")!, db = SavedServer(address: "me@db.invalid")!
    app.savedServers = [web, db]
    #expect(app.historyToDelete(with: web) == nil, "none yet")
    ServerHistory(root: root).keep(Data("v".utf8), SFTPClient.Attrs(kind: .file, size: 1, mtime: 0, mode: nil), of: web.target, "/etc/a")
    #expect(app.historyToDelete(with: web) == root + "/me@web.invalid" && app.historyToDelete(with: db) == nil)
    var twin = SavedServer(address: "me@web.invalid")!
    twin.name = "web again"
    app.savedServers.append(twin)
    #expect(app.historyToDelete(with: web) == nil, "the twin keeps using it")
}
}

/// Compare Files' pair, three rules in order: two marked files; the cursor's and the same name in the other panel's
/// folder, if it's there; the cursor's and the other panel's cursor's.
@MainActor @Test func diffPairRules() async {
    var asked: [String] = []
    func pair(_ marked: [String], _ cursor: String?, _ same: String?, _ other: String?, there: Bool = true) async -> [String]? {
        await AppDelegate.diffPair(marked: marked, cursor: cursor, sameName: same, otherCursor: other) { asked.append($0); return there ? $0 : nil }.map { [$0, $1] }
    }
    #expect(await pair(["m1", "m2"], "c", "s", "o") == ["m1", "m2"] && asked.isEmpty, "two marked: nothing looked at")
    #expect(await pair(["m1", "m2", "m3"], "c", "s", "o") == ["c", "s"] && asked == ["s"], "three: the cursor's rules")
    #expect(await pair(["c"], "c", "s", "o", there: false) == ["c", "o"], "no such name next door: the other cursor")
    #expect(await pair([], "c", nil, "o") == ["c", "o"], "the other panel isn't a folder here")
    asked = []
    #expect(await pair([], nil, nil, "o") == nil && asked.isEmpty, "no file under the cursor")
    #expect(await pair(["c"], "c", "s", nil, there: false) == nil)

    // What the diff and its window call each side: a server's file "host:/path", a version its file and date.
    #expect(AppDelegate.DiffSide(path: "/srv/a", server: SFTPTarget(host: "me@web")).label == "me@web:/srv/a")
    #expect(AppDelegate.DiffSide(path: "/h/me@web/srv/a@2026-10-12_03-04-05", name: "me@web:/srv/a @ 2026-10-12 03:04:05").label == "me@web:/srv/a @ 2026-10-12 03:04:05")
    #expect(AppDelegate.DiffSide(path: "/tmp/a").label == "/tmp/a")
}

extension ServerCopiesTests {
/// Compare Files with a server's file: it's fetched as a preview is (the copy already here for that size and date, else
/// downloaded and kept with the others; nothing over 64 MB), and `diff -u` names it "host:/path", not its copy's temp
/// path — a server's file against this Mac's, and against another server's.
@Test func diffWithAServerShowsItsNameNotItsCopy() async throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-sdiff-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { ServerCopies.quit(); try? FileManager.default.removeItem(atPath: d) }
    try Data("a\nb\n".utf8).write(to: URL(fileURLWithPath: d + "/web.conf"))
    try Data("a\nc\n".utf8).write(to: URL(fileURLWithPath: d + "/db.conf"))
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let app = AppDelegate()
    func side(_ name: String) throws -> AppDelegate.DiffSide {
        let a = try FileManager.default.attributesOfItem(atPath: d + "/" + name)
        return .init(path: d + "/" + name, server: .local(), size: (a[.size] as! NSNumber).int64Value, mtime: (a[.modificationDate] as! Date).timeIntervalSince1970.rounded(.down))
    }
    func run(_ command: String) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    let web = try side("web.conf"), db = try side("db.conf")
    let copy = try #require(await app.localCopy(web, in: panel))
    #expect(copy != web.path && copy.contains("/dfm-sftp-"))
    #expect(FileManager.default.contents(atPath: copy) == Data("a\nb\n".utf8))
    #expect(await app.localCopy(web, in: panel) == copy, "the copy for that size and date: not fetched again")
    #expect(ServerCopies.preview(of: .local(), web.path, size: web.size, mtime: web.mtime)?.path == copy, "kept as a preview's")

    let mine = AppDelegate.DiffSide(path: d + "/db.conf")
    let local = try run(AppDelegate.diffCommand(copy, mine.path, labels: (web.label, mine.label)))
    #expect(local.hasPrefix("--- localhost:\(d)/web.conf\n+++ \(d)/db.conf\n") && !local.contains("dfm-sftp-"), "\(local)")
    let dbCopy = try #require(await app.localCopy(db, in: panel))
    let both = try run(AppDelegate.diffCommand(copy, dbCopy, labels: (web.label, db.label)))
    #expect(both == "--- localhost:\(d)/web.conf\n+++ localhost:\(d)/db.conf\n@@ -1,2 +1,2 @@\n a\n-b\n+c\n", "\(both)")
    #expect(AppDelegate.diffCommand("/x y", "/z", labels: nil) == "diff -u '/x y' /z", "this Mac's files only: as before")

    var huge = web
    huge.size = PanelViewController.previewLimit + 1
    huge.mtime += 1
    #expect(await app.localCopy(huge, in: panel) == nil && panel.statusText.contains("too big to compare"))
}
}

/// A picker row can take keys of its own (Server File History: F3 views, ⌘⇧D diffs, ⌘R reverts): the highlighted
/// row's run, the picker closed first. F3 needn't come as a key equivalent: plain key-downs are looked at too.
@MainActor @Test func pickerRowsTakeKeysOfTheirOwn() async {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    var ran: [String] = [], dismissed = 0
    func show() -> KeyPanel {
        Picker.show(over: window, placeholder: "", items: ["a", "b"].map { n in
            Picker.Item(title: n, actions: [.init(key: Shortcut("f3")!, label: "") { ran.append("view \(n)") },
                                            .init(key: Shortcut("cmd+shift+d")!, label: "Diff") { ran.append("diff \(n)") },
                                            .init(key: Shortcut("cmd+r")!, label: "Revert") { ran.append("revert \(n)") }]) { ran.append("run \(n)") }
        }, onDismiss: { dismissed += 1 })
        let panel = Picker.current!.panel
        (panel.contentView?.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)?.selectRowIndexes([1], byExtendingSelection: false)
        return panel
    }
    func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags = [], _ chars: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }
    func settle() async { for _ in 0..<50 where ran.count < 3 { try? await Task.sleep(for: .milliseconds(10)) } }

    show().sendEvent(key(99, [.function], "\u{F706}"))   // F3, as a plain key-down
    #expect(Picker.current == nil)
    #expect(show().performKeyEquivalent(with: key(2, [.command, .shift], "d")) && Picker.current == nil)
    #expect(show().performKeyEquivalent(with: key(15, .command, "r")) && Picker.current == nil)
    await settle()
    #expect(ran == ["view b", "diff b", "revert b"] && dismissed == 0, "\(ran)")

    let p = show()
    #expect(!p.performKeyEquivalent(with: key(14, .command, "e")), "no ⌘E here: left to the rest")
    p.sendEvent(key(0, [], "a"))
    #expect(Picker.current != nil, "typing still filters")
    Picker.current?.panel.sendEvent(key(53, [], "\u{1b}"))
}

/// Server File History… is a command: ⌘⇧P finds it, keymap.json can bind it, the File menu lists it.
@MainActor @Test func serverFileHistoryIsACommand() {
    let commands = AppDelegate().makeCommands()
    let c = commands.first { $0.id == "server.history" }
    #expect(c?.title == "Server File History…" && c?.menu == "File")
    let found = HeaderSearchModel.results("file history", commands: commands, folders: [], files: [], recent: [])
    #expect(found.flatMap(\.hits).contains { if case .command(let id) = $0.target { id == "server.history" } else { false } }, "\(found)")
}

/// A save's "no history: …" went only to the panels' status line, which sits behind the editor that saved: the editor
/// says it too, in place of its subtitle for a few seconds.
@MainActor @Test func editorSaysWhatASaveDidntKeep() throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-enote-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try Data("x\n".utf8).write(to: URL(fileURLWithPath: dir + "/app.conf"))
    let e = try Editor(URL(fileURLWithPath: dir + "/app.conf"), remote: "web:/etc/app.conf")
    defer { e.close() }
    let usual = e.window?.subtitle
    #expect(usual?.contains("⌘S Save") == true)
    e.flash("Saved “app.conf” to web · no history: file over 5 MB")
    #expect(e.window?.subtitle == "Saved “app.conf” to web · no history: file over 5 MB")
}

/// Revert put a version on the server, but its open editor still showed the old text, and its next ⌘S asked "changed
/// on the server". An editor without changes of its own shows the version now and saves against what's there; one
/// with changes keeps them (its ⌘S then asks, with Compare).
@MainActor @Test func revertShowsInTheFilesEditor() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-erev-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let copy = URL(fileURLWithPath: dir + "/app.conf")
    try Data("now\n".utf8).write(to: copy)
    let t = SFTPTarget(host: "me@web.invalid")
    let before = SFTPClient.Attrs(kind: .file, size: 4, mtime: 100, mode: 0o644), after = SFTPClient.Attrs(kind: .file, size: 4, mtime: 200, mode: 0o644)
    let e = try Editor(copy, remote: "web:/etc/app.conf")
    defer { e.close() }
    e.server = (t, "/etc/app.conf", AppDelegate.RemoteEdit(baseline: before))

    #expect(await e.reverted(to: Data("old\n".utf8), attrs: after))
    #expect(e.textView.string == "old\n" && !e.changed && e.server?.state.baseline == after)
    #expect(FileManager.default.contents(atPath: copy.path) == Data("old\n".utf8))

    e.textView.string = "mine\n"
    e.textDidChange(Notification(name: NSText.didChangeNotification))
    #expect(await !e.reverted(to: Data("older\n".utf8), attrs: before))
    #expect(e.textView.string == "mine\n" && e.server?.state.baseline == after, "its own changes stay")
}

/// Save As of a server file's copy kept the editor tied to that server's file: a later Revert from its Server File
/// History found this window and wrote the old server text into the new local file. After Save As it's a local file.
@MainActor @Test func saveAsLeavesTheServerFile() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-esas-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let copy = URL(fileURLWithPath: dir + "/app.conf"), mine = URL(fileURLWithPath: dir + "/mine.conf")
    try Data("now\n".utf8).write(to: copy)
    let t = SFTPTarget(host: "me@web.invalid"), attrs = SFTPClient.Attrs(kind: .file, size: 4, mtime: 100, mode: 0o644)
    Editor.open(copy, remote: "web:/etc/app.conf", server: (t, "/etc/app.conf", AppDelegate.RemoteEdit(baseline: attrs)))
    for _ in 0..<250 where Editor.editing(t, "/etc/app.conf") == nil { try await Task.sleep(for: .milliseconds(20)) }
    let e = try #require(Editor.editing(t, "/etc/app.conf"))
    defer { e.close() }
    #expect(Editor.server(of: e.window)?.path == "/etc/app.conf")

    #expect(await e.saveAs(mine))
    #expect(Editor.editing(t, "/etc/app.conf") == nil && Editor.server(of: e.window) == nil)
    #expect(await !e.reverted(to: Data("old\n".utf8), attrs: attrs))
    #expect(FileManager.default.contents(atPath: mine.path) == Data("now\n".utf8) && e.textView.string == "now\n")
}
