import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

/// Task 15 sss-4: writes on this Mac never leave a file half old, half new — or empty.

private func folder() throws -> String {
    let dir = NSTemporaryDirectory() + "dfm-sss4-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func read(_ path: String) -> String? { FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } }

private func run(_ tool: String, _ args: [String], in dir: String) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    try p.run()
    p.waitUntilExit()
}

extension ServerLockTests {   // swaps `AppDelegate.answering`, as the other tests that do it there

/// F-05: a zip extracted with Overwrite over files that are there unpacks into a staging folder first. Its second
/// member is broken (bad CRC): bsdtar has replaced the first by then, and writes the broken one under its name — after
/// the fix neither lands, both old files stay as they were. A good zip replaces both, and leaves no staging folder.
@MainActor @Test func anExtractThatFailsOverFilesLeavesThemAsTheyWere() async throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try Data(String(repeating: "NEW-A", count: 1000).utf8).write(to: URL(fileURLWithPath: dir + "/a.txt"))
    try Data(String(repeating: "NEW-B", count: 1000).utf8).write(to: URL(fileURLWithPath: dir + "/b.txt"))
    try run("/usr/bin/zip", ["-q", "-0", "good.zip", "a.txt", "b.txt"], in: dir)   // stored: b's bytes are there to break
    var bytes = try Data(contentsOf: URL(fileURLWithPath: dir + "/good.zip"))
    let b = try #require(bytes.range(of: Data("NEW-BNEW-B".utf8)))
    bytes[b.lowerBound + 100] ^= 0xff
    try bytes.write(to: URL(fileURLWithPath: dir + "/bad.zip"))

    let dest = dir + "/dest"
    try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
    let panel = PanelViewController(tabs: [dest], index: 0, showHidden: true)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let app = AppDelegate()
    app.panels = [panel]
    var asked: [String] = []
    AppDelegate.answering = { m, _, _ in asked.append(m); return 1 }   // Overwrite
    defer { AppDelegate.answering = nil }

    for (zip, ok) in [("bad.zip", false), ("good.zip", true)] {
        try Data("old-a".utf8).write(to: URL(fileURLWithPath: dest + "/a.txt"))
        try Data("old-b".utf8).write(to: URL(fileURLWithPath: dest + "/b.txt"))
        await app.extract(dir + "/" + zip, nil, to: dest)
        // the output window says so under tar's own error
        let window = NSApp.windows.last { $0.title.hasPrefix("Extract “\(zip)”") && $0.isVisible }
        let said = (window?.docFrame?.scroll.documentView as? NSTextView)?.string ?? ""
        #expect(said.hasSuffix(ok ? "" : AppDelegate.nothingExtracted((dest as NSString).abbreviatingWithTildeInPath) + "\n") && window != nil, "\(zip): \(said)")
        #expect(ok != said.contains("Nothing was extracted"), "\(zip)")
        window?.close()
        #expect(read(dest + "/a.txt") == (ok ? String(repeating: "NEW-A", count: 1000) : "old-a"), "\(zip)")
        #expect(read(dest + "/b.txt") == (ok ? String(repeating: "NEW-B", count: 1000) : "old-b"), "\(zip)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest).sorted() == ["a.txt", "b.txt"], "\(zip): no staging folder")
    }
    #expect(asked == Array(repeating: "2 items already exist in \((dest as NSString).abbreviatingWithTildeInPath)", count: 2), "once each, before")
}
}

/// T-02: servers.json with one bad entry (`"port": "22"`, hand-edited) keeps the other two in the list; the file as
/// it was is copied — not moved — to servers.json.broken byte for byte, and the problem says how many and where.
/// Before, the whole list came back empty and the file was moved aside without a word. Never in ~/.config.
@MainActor @Test func aBrokenServerEntryHidesOnlyItself() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let names = ["web", "db", "cache"]
    let servers = names.map { n -> SavedServer in var s = SavedServer(); s.name = n; s.host = n + ".example.com"; return s }
    var entries = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(servers)) as? [[String: Any]])
    entries[1]["port"] = "22"
    let text = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted])
    try text.write(to: URL(fileURLWithPath: dir + "/servers.json"))

    let (loaded, problem) = Config.loadEach("servers.json", as: SavedServer.self, in: dir)
    #expect(loaded.map(\.name) == ["web", "cache"])
    #expect(problem == "servers.json: an entry of 3 couldn't be read and is left out — the file as it was is kept as servers.json.broken")
    #expect(FileManager.default.contents(atPath: dir + "/servers.json.broken") == text)
    #expect(FileManager.default.contents(atPath: dir + "/servers.json") == text, "copied, not moved")

    // said once at launch, with the config problems
    let was = Config.unreadable
    defer { Config.unreadable = was }
    Config.unreadable = []
    #expect(Config.noting((loaded, problem)).count == 2 && Config.unreadable == [problem])
}

/// T-03: a broken bookmarks.json (not even JSON) is copied aside before the first save writes over it; the same
/// file again isn't copied twice, and another broken one doesn't replace the first copy. frecency.json — a whole.
@MainActor @Test func aBrokenStateFileIsKeptBeforeItsSavedOver() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let file = dir + "/bookmarks.json", broken = Data(#"["~/a" "~/b"]"#.utf8)
    try broken.write(to: URL(fileURLWithPath: file))
    let (marks, problem) = Config.loadEach("bookmarks.json", as: String.self, in: dir)
    #expect(marks.isEmpty)
    #expect(problem?.hasPrefix("bookmarks.json couldn't be read (") == true)
    #expect(problem?.hasSuffix(", so it starts empty — the file as it was is kept as bookmarks.json.broken") == true, "\(problem ?? "")")
    try Data(#"["~/c"]"#.utf8).write(to: URL(fileURLWithPath: file))   // the first save, as Config.save writes it
    #expect(FileManager.default.contents(atPath: file + ".broken") == broken)

    try broken.write(to: URL(fileURLWithPath: file))
    _ = Config.loadEach("bookmarks.json", as: String.self, in: dir)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["bookmarks.json", "bookmarks.json.broken"], "not twice")
    let other = Data(#"["~/a", 5, "~/b"]"#.utf8)
    try other.write(to: URL(fileURLWithPath: file))
    let (some, said) = Config.loadEach("bookmarks.json", as: String.self, in: dir)
    #expect(some == ["~/a", "~/b"] && said?.contains("an entry of 3") == true && said?.contains("bookmarks.json.broken-") == true)
    #expect(FileManager.default.contents(atPath: file + ".broken") == broken, "the first copy stays")
    let dated = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("bookmarks.json.broken-") }
    #expect(dated.count == 1 && FileManager.default.contents(atPath: dir + "/" + (dated.first ?? "")) == other)

    try Data("{".utf8).write(to: URL(fileURLWithPath: dir + "/frecency.json"))
    let (frecency, why) = Config.loadKeeping("frecency.json", as: Frecency.self, in: dir)
    #expect(frecency == nil && why?.hasSuffix("kept as frecency.json.broken") == true)
    #expect(FileManager.default.contents(atPath: dir + "/frecency.json.broken") == Data("{".utf8))
}

/// F-12: what Put Back and Undo of a copy act on is the item recorded, by inode: one renamed away in Finder, with
/// another item given its name, is left alone; the same item (renamed into the Trash, which keeps the inode) or one
/// gone (the move says so) goes on. trash.json an older version wrote (path alone) still reads, by name as before.
@Test func putBackAndUndoGoByTheItemNotTheName() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let a = dir + "/a.txt", b = dir + "/b.txt", gone = dir + "/gone.txt"
    try Data("a".utf8).write(to: URL(fileURLWithPath: a))
    try Data("b".utf8).write(to: URL(fileURLWithPath: b))
    let recorded = [TrashEntry(origin: "/x/a.txt", at: a), TrashEntry(origin: "/x/b.txt", at: b), TrashEntry(origin: "/x/gone", ino: 7)]
    #expect(recorded[0].ino != nil && recorded[0].ino != recorded[1].ino)
    #expect(rename(b, dir + "/b-renamed.txt") == 0)
    try Data("another".utf8).write(to: URL(fileURLWithPath: b))   // Finder: something else under that name now
    let (pairs, others) = TrashEntry.same(zip([a, b, gone], recorded).map { ($0, $1) })
    #expect(pairs.map(\.from) == [a, gone] && pairs.map(\.to) == ["/x/a.txt", "/x/gone"])
    #expect(others == [b])

    let old = try JSONDecoder().decode([String: TrashEntry].self, from: Data(#"{"/t/a": "/x/a"}"#.utf8))
    #expect(old == ["/t/a": TrashEntry(origin: "/x/a", ino: nil)])
    let again = try JSONDecoder().decode([String: TrashEntry].self, from: JSONEncoder().encode(["/t/a": recorded[0]]))
    #expect(again == ["/t/a": recorded[0]])
}

/// F-04 in the F6 dialog: "foo" typed for the folder "Foo" on a case-insensitive disk is that folder itself, so it's a
/// rename — before, it was taken for an existing folder to move into ("Cannot move a folder into itself"). Another
/// folder, or the same spelling, isn't.
@Test func typingTheSameNameInAnotherCaseIsARename() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: dir + "/Foo", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: dir + "/Bar", withIntermediateDirectories: true)
    try #require(FileManager.default.fileExists(atPath: dir + "/foo"), "a case-sensitive volume: nothing to test")
    #expect(AppDelegate.isRespelling(dir + "/Foo", dir + "/foo"))
    #expect(!AppDelegate.isRespelling(dir + "/Foo", dir + "/Foo") && !AppDelegate.isRespelling(dir + "/Foo", dir + "/Bar"))
}

/// D-146: a test run's config is a folder of its own — the production log, file history, keymap, frecency and saved
/// servers land there, whatever a test forgets to point elsewhere; the user's ~/.config/dfilemanager isn't read or written.
@Test func aTestRunKeepsAConfigOfItsOwn() {
    let real = (NSHomeDirectory() as NSString).appendingPathComponent(".config/dfilemanager")
    #expect(Config.isTestRun && Config.dir != real && !Config.dir.hasPrefix(real), "\(Config.dir)")
    #expect(Config.path("audit.jsonl").hasPrefix(Config.dir + "/") && Config.dir.hasSuffix("kermo-config-\(getpid())"))
}

/// Saves written into a file in place keep its old text in `Editor.keptDir`, shared by the whole process: these take
/// turns (one makes it read-only for a moment).
@Suite(.serialized) @MainActor struct InPlaceSaveTests {
    /// F-02: a hard-linked file is saved in place (a rename would split its links). A shorter text leaves exactly the
    /// new length, the same inode, the link whole. While it's written, the old text is kept — ours only, with the
    /// file's path — and goes once the file is whole. A write that stops midway (a full disk) puts the old text back,
    /// the same inode, both names, and says so; the text stays unsaved in the window.
    @Test func aSaveInPlaceNeverEmptiesTheFile() async throws {
        _ = NSApplication.shared
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = dir + "/inplace-a.conf", b = dir + "/inplace-b.conf"
        let old = String(repeating: "old line\n", count: 1000)
        try Data(old.utf8).write(to: URL(fileURLWithPath: a))
        #expect(link(a, b) == 0)
        let inode = FileJob.lstat(a)?.st_ino

        let e = try Editor(URL(fileURLWithPath: a))
        defer { e.close() }
        let seen = Seen()
        e.writeText = { h, data in   // the copy, as it is while the file is written
            seen.copies = copies("inplace-a.conf").map { Editor.keptDir + "/" + $0 }
            seen.texts = seen.copies.map { FileManager.default.contents(atPath: $0) }
            seen.modes = seen.copies.map { (try? FileManager.default.attributesOfItem(atPath: $0)[.posixPermissions] as? Int) ?? 0 }
            seen.origins = seen.copies.map(Editor.keptOriginal)
            try h.write(contentsOf: data)
        }
        e.textView.insertText("short\n", replacementRange: NSRange(location: 0, length: (old as NSString).length))
        #expect(await e.save())
        #expect(read(a) == "short\n" && read(b) == "short\n" && FileJob.lstat(a)?.st_ino == inode)
        #expect(seen.texts == [Data(old.utf8)] && seen.modes == [0o600] && seen.origins == [URL(fileURLWithPath: a).resolvingSymlinksInPath().path], "kept while written: \(seen.origins)")
        #expect(copies("inplace-a.conf").isEmpty, "the copy goes once the file is whole")
        #expect((try FileManager.default.attributesOfItem(atPath: Editor.keptDir)[.posixPermissions] as? Int) == 0o700)
        #expect((try URL(fileURLWithPath: Editor.keptDir).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true)

        try Data(old.utf8).write(to: URL(fileURLWithPath: a))
        let new = String(repeating: "new text\n", count: 2000)
        e.textView.insertText(new, replacementRange: NSRange(location: 0, length: (e.textView.string as NSString).length))
        e.writeText = { h, data in   // the disk fills up after 4 KB
            try h.write(contentsOf: data.prefix(4096))
            throw POSIXError(.ENOSPC)
        }
        #expect(await !e.save(force: true))
        #expect(read(a) == old && read(b) == old && FileJob.lstat(a)?.st_ino == inode, "put back")
        #expect(said(e).contains("No space left on device") && said(e).contains("The file is as it was before this save."), "\(said(e))")
        #expect(copies("inplace-a.conf").isEmpty, "put back whole: no copy left")
        #expect(e.window?.isDocumentEdited == true && e.textView.string == new, "the text stays, unsaved")
        if let sheet = e.window?.attachedSheet { e.window?.endSheet(sheet) }

        // The file can't be written at all, nor its old text written back (open for reading only): the copy stays, named.
        let fd = open(a, O_RDONLY)
        do {
            _ = try Editor.rewriteInPlace(Data(new.utf8), fd, path: a) { try $0.write(contentsOf: $1) }
            Issue.record("written through a read-only descriptor")
        } catch {
            #expect(error.localizedDescription.contains("The file may be cut short. Its text before this save is kept in"), "\(error.localizedDescription)")
        }
        let kept = copies("inplace-a.conf").map { Editor.keptDir + "/" + $0 }
        defer { kept.forEach { _ = unlink($0) } }
        #expect(kept.count == 1 && kept.first.flatMap { FileManager.default.contents(atPath: $0) } == Data(old.utf8) && read(a) == old, "the old text is kept")
    }

    /// With nowhere to keep the old text, an in-place save writes anyway and says so. A copy a crash left — a minute old
    /// or more, a regular file of ours — is what the next launch names, by the file's path (one being written now isn't,
    /// nor Finder's .DS_Store).
    @Test func anInPlaceSaveWithoutACopySaysSoAndACrashsCopyIsNamed() async throws {
        _ = NSApplication.shared
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = dir + "/inplace-linked.conf"
        try Data("old\n".utf8).write(to: URL(fileURLWithPath: a))
        #expect(link(a, dir + "/inplace-twin.conf") == 0)
        let e = try Editor(URL(fileURLWithPath: a))
        defer { e.close() }
        try FileManager.default.createDirectory(atPath: Editor.keptDir, withIntermediateDirectories: true)
        chmod(Editor.keptDir, 0o500)
        e.textView.string = "new\n"
        e.textDidChange(Notification(name: NSText.didChangeNotification))
        let saved = await e.save()
        chmod(Editor.keptDir, 0o700)
        #expect(saved && read(a) == "new\n" && read(dir + "/inplace-twin.conf") == "new\n")
        #expect(e.window?.statusText.hasPrefix("Saved in place without a copy of its old text first") == true, "\(e.window?.statusText ?? "")")

        let stale = Editor.keptDir + "/2026-01-01_00-00-00-abcd1234-crashed.conf", fresh = Editor.keptDir + "/2026-01-01_00-00-01-abcd1235-running.conf"
        let finder = Editor.keptDir + "/.DS_Store"
        for p in [stale, fresh, finder] { FileManager.default.createFile(atPath: p, contents: Data("before\n".utf8), attributes: [.posixPermissions: 0o600]) }
        defer { [stale, fresh, finder].forEach { _ = unlink($0) } }
        for p in [stale, finder] { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: p) }
        _ = "/etc/crashed.conf".withCString { setxattr(stale, "com.kermo.original", $0, strlen($0), 0, 0) }
        let cut = Editor.cutShortSaves()
        #expect(cut.contains(stale) && !cut.contains(fresh) && !cut.contains(finder), "\(cut)")
        #expect(Editor.keptOriginal(stale) == "/etc/crashed.conf" && Editor.keptOriginal(fresh) == "running.conf")
    }
}

/// The copies of old texts in-place saves keep (`Editor.keptDir`) with this file's name.
private func copies(_ name: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: Editor.keptDir)) ?? []).filter { $0.hasSuffix("-" + name) }
}

/// What the sheet on the editor's window says.
@MainActor private func said(_ e: Editor) -> String {
    func text(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(text) }
    return (e.window?.attachedSheet?.contentView.map(text) ?? []).joined(separator: " ")
}

/// What the write hook saw, off the main thread (one save at a time).
private final class Seen: @unchecked Sendable {
    var copies: [String] = [], texts: [Data?] = [], modes: [Int] = [], origins: [String] = []
}
