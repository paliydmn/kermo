import AppKit
import Testing
@testable import DFileManager

/// Sets a file's mtime to exactly `s`'s (what `touch -r` does), so only its bytes or identity tell it apart.
private func setMtime(_ path: String, like s: Editor.Stamp) {
    var t = [timespec(tv_sec: s.sec, tv_nsec: s.nsec), timespec(tv_sec: s.sec, tv_nsec: s.nsec)]
    utimensat(AT_FDCWD, path, &t, 0)
}

/// A3 (task 9, = E1): ⌘S in the F4 editor never silently overwrites a file another process changed meanwhile —
/// whether its mtime went back, its inode changed, or only its bytes did. "Overwrite" (force) then writes ours.
@MainActor @Test func localEditSaveChecksForChangesOnDisk() async throws {
    _ = NSApplication.shared
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-editor-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let fm = FileManager.default
    let path = dir + "/doc.txt"
    func write(_ s: String, to p: String = path) throws { try Data(s.utf8).write(to: URL(fileURLWithPath: p)) }
    func disk() -> String? { fm.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } }
    try write("original\n")

    let e = try Editor(URL(fileURLWithPath: path))
    defer { e.close() }
    e.textView.string = "QA-EDITOR-VERSION\n"

    // Another process writes a different document, with an older mtime (the old check only noticed newer ones).
    try write("other doc\n")
    try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: path)
    #expect(await !e.save())
    #expect(disk() == "other doc\n")
    #expect(await e.save(force: true))   // "Overwrite"
    #expect(disk() == "QA-EDITOR-VERSION\n")
    #expect(await e.save())   // nothing changed since our own save: no question

    // Replaced by another file (new inode) with the same size and mtime.
    let mine = try #require(Editor.Stamp(path))
    try write("QA-EDITOR-VERSIOX\n", to: dir + "/new.txt")
    setMtime(dir + "/new.txt", like: mine)
    #expect(rename(dir + "/new.txt", path) == 0)
    #expect(await !e.save())
    #expect(disk() == "QA-EDITOR-VERSIOX\n")
    #expect(await e.save(force: true))

    // Rewritten in place, same inode, size and mtime: only the bytes differ.
    let now = try #require(Editor.Stamp(path))
    let h = try #require(FileHandle(forWritingAtPath: path))
    try h.write(contentsOf: Data("qa".utf8))
    try h.close()
    setMtime(path, like: now)
    #expect(Editor.Stamp(path) == now)
    #expect(await !e.save())
    #expect(disk() == "qa-EDITOR-VERSION\n")

    // A deleted file isn't a conflict: saving recreates it.
    try fm.removeItem(atPath: path)
    #expect(await e.save())
    #expect(disk() == "QA-EDITOR-VERSION\n")
}

/// Through a symlink the check and the write are on the target; the link stays a link.
@MainActor @Test func localEditSaveThroughSymlinkChecksTheTarget() async throws {
    _ = NSApplication.shared
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-editor-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let fm = FileManager.default
    try Data("v1\n".utf8).write(to: URL(fileURLWithPath: dir + "/real.conf"))
    try fm.createSymbolicLink(atPath: dir + "/link.conf", withDestinationPath: "real.conf")

    let e = try Editor(URL(fileURLWithPath: dir + "/link.conf"))
    defer { e.close() }
    e.textView.string = "mine\n"
    #expect(await e.save())
    #expect(await e.save())
    #expect(try fm.destinationOfSymbolicLink(atPath: dir + "/link.conf") == "real.conf")
    try Data("theirs\n".utf8).write(to: URL(fileURLWithPath: dir + "/real.conf"))
    #expect(await !e.save())
    #expect(fm.contents(atPath: dir + "/real.conf") == Data("theirs\n".utf8))
}

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-editor-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// Save as Administrator checks the disk again right before the root write: a change made while the
/// "is protected" sheet was up isn't overwritten. Overwrite (force) still goes through as root.
@MainActor @Test func adminSaveRechecksTheDiskBeforeWriting() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/hosts"
    try Data("v1\n".utf8).write(to: URL(fileURLWithPath: path))
    var commands: [String] = []
    let real = Editor.runAsAdmin
    defer { Editor.runAsAdmin = real }
    Editor.runAsAdmin = { cmd in   // no root in tests: run the same command as us
        commands.append(cmd)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? .ok : .failed("exit \(p.terminationStatus)")
    }

    let e = try Editor(URL(fileURLWithPath: path))
    defer { e.close() }
    e.textView.string = "mine\n"
    try Data("theirs\n".utf8).write(to: URL(fileURLWithPath: path))   // while the sheet was up
    #expect(await !e.adminSave(Data("mine\n".utf8), force: false))
    #expect(commands.isEmpty)
    #expect(FileManager.default.contents(atPath: path) == Data("theirs\n".utf8))

    #expect(await e.adminSave(Data("mine\n".utf8), force: true))   // Overwrite → as administrator
    #expect(commands.count == 1)
    #expect(FileManager.default.contents(atPath: path) == Data("mine\n".utf8))
    #expect(await e.adminSave(Data("mine\n".utf8), force: false))   // our own write is the new baseline
}

/// Save As from the conflict sheet: the text goes to the new file, the changed one is left alone,
/// and the editor now edits the new file (fresh baseline: the next ⌘S doesn't ask).
@MainActor @Test func conflictSaveAsWritesElsewhereAndFollowsTheNewFile() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let fm = FileManager.default
    try Data("v1\n".utf8).write(to: URL(fileURLWithPath: dir + "/a.conf"))
    let e = try Editor(URL(fileURLWithPath: dir + "/a.conf"))
    defer { e.close() }
    e.textView.string = "mine\n"
    try Data("theirs\n".utf8).write(to: URL(fileURLWithPath: dir + "/a.conf"))
    #expect(await !e.save())

    let b = URL(fileURLWithPath: dir + "/b.conf")
    #expect(await e.saveAs(b))
    #expect(e.url == b)
    #expect(e.window?.title == "b.conf")
    #expect(fm.contents(atPath: b.path) == Data("mine\n".utf8))
    #expect(fm.contents(atPath: dir + "/a.conf") == Data("theirs\n".utf8))
    e.textView.string = "mine 2\n"
    #expect(await e.save())
    #expect(fm.contents(atPath: b.path) == Data("mine 2\n".utf8))
}

/// Reload that can't read the file (binary now, or gone) fails visibly and keeps the user's text.
@MainActor @Test func reloadFailureKeepsTheTextAndSaysSo() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/doc.txt"
    try Data("v1\n".utf8).write(to: URL(fileURLWithPath: path))
    let e = try Editor(URL(fileURLWithPath: path))
    defer { e.close() }
    e.textView.string = "mine\n"
    try Data([0x61, 0, 0x62]).write(to: URL(fileURLWithPath: path))
    #expect(await !e.reload())
    #expect(e.window?.attachedSheet != nil)
    #expect(e.textView.string == "mine\n")
    try FileManager.default.removeItem(atPath: path)
    #expect(await !e.reload())
    #expect(e.textView.string == "mine\n")
    try Data("v2\n".utf8).write(to: URL(fileURLWithPath: path))
    #expect(await e.reload())
    #expect(e.textView.string == "v2\n")
}

/// R13: a save to a server that was cancelled (⎋ in the panel) or failed after its editor was closed says where the
/// text is kept; with the editor still open, a cancel stays quiet (the editor shows it unsaved).
@MainActor @Test func unsentSaveWithTheEditorClosedSaysWhereTheTextIs() {
    let saved = URL(fileURLWithPath: "/tmp/dfm-sftp-X/notes.txt")
    struct Failed: LocalizedError { var errorDescription: String? { "no route" } }
    #expect(AppDelegate.notUploaded(saved, host: "srv", CancellationError(), editorOpen: true) == nil)
    #expect(AppDelegate.notUploaded(saved, host: "srv", CancellationError(), editorOpen: false)?.contains(saved.path) == true)
    let open = AppDelegate.notUploaded(saved, host: "srv", Failed(), editorOpen: true) ?? ""
    #expect(open.contains("no route") && !open.contains(saved.path))
    let closed = AppDelegate.notUploaded(saved, host: "srv", Failed(), editorOpen: false) ?? ""
    #expect(closed.contains("no route") && closed.contains(saved.path))
}

/// Typing and undoing it all back is no change: closing doesn't ask. A real change does.
@MainActor @Test func editorAsksOnlyAboutRealChanges() throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-editor-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try Data("original\n".utf8).write(to: URL(fileURLWithPath: dir + "/doc.txt"))
    let e = try Editor(URL(fileURLWithPath: dir + "/doc.txt"))
    defer { e.close() }
    e.textView.string = "edited\n"
    e.textDidChange(Notification(name: NSText.didChangeNotification))
    #expect(e.changed)
    e.textView.string = "original\n"
    e.textDidChange(Notification(name: NSText.didChangeNotification))
    #expect(!e.changed)
    #expect(e.windowShouldClose(try #require(e.window)))
}
