import AppKit
import CryptoKit
@testable import DFMCore
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

/// What Save as Administrator's root write does, run as us instead (no root in tests): sh, with stderr as the failure,
/// as osascript gives it.
private func runAsUs(_ command: String) -> Admin.Outcome {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    let err = Pipe()
    p.standardError = err
    try? p.run()
    let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return p.terminationStatus == 0 ? .ok : .failed(msg)
}

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-editor-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
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

/// sss-2: a save written into the server's file that failed on the way says what the file there is now — maybe cut
/// short, or put back — and where the whole new text is on the server (the partial file).
@MainActor @Test func aFailedWriteIntoTheFileSaysWhereTheTextIs() {
    let saved = URL(fileURLWithPath: "/tmp/dfm-sftp-X/site.conf")
    struct Full: LocalizedError { var errorDescription: String? { "No space left on device" } }
    let partial = "/etc/nginx/sites-available/.dfm-partial-1-X"
    let cut = AppDelegate.notUploaded(saved, host: "srv", SFTPClient.InPlaceFailed(partial: partial, restored: false, error: Full()), editorOpen: true) ?? ""
    #expect(cut.contains("No space left on device") && cut.contains("may be cut short") && cut.contains(partial), "\(cut)")
    let back = AppDelegate.notUploaded(saved, host: "srv", SFTPClient.InPlaceFailed(partial: partial, restored: true, error: Full()), editorOpen: false) ?? ""
    #expect(back.contains("put back") && !back.contains("cut short") && back.contains(partial) && back.contains(saved.path), "\(back)")
}

/// T-07: a save's temp file a crash left next to the file goes at the next save there once a day old (by its name's
/// time and its date; an older version's name has none: its date alone). A fresh one may be a save running.
@MainActor @Test func aSaveSweepsDayOldTempFilesOfSaves() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-editor-" + UUID().uuidString
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let now = Int(Date().timeIntervalSince1970), old = Date(timeIntervalSinceNow: -2 * 86_400)
    let stale = [".dfm-save-\(now - 2 * 86_400)-\(UUID().uuidString)", ".dfm-save-\(UUID().uuidString)"]
    let fresh = [".dfm-save-\(now - 60)-\(UUID().uuidString)", ".dfm-save-\(now)-\(UUID().uuidString)"]
    for (i, n) in (stale + fresh).enumerated() {
        try Data("half a save\n".utf8).write(to: URL(fileURLWithPath: dir + "/" + n))
        if i != 3 { try fm.setAttributes([.modificationDate: old], ofItemAtPath: dir + "/" + n) }   // a running one's name is new, its date may not be
    }
    try Data("original\n".utf8).write(to: URL(fileURLWithPath: dir + "/doc.txt"))
    let e = try Editor(URL(fileURLWithPath: dir + "/doc.txt"))
    defer { e.close() }
    e.textView.string = "edited\n"
    #expect(await e.save())
    #expect(try fm.contentsOfDirectory(atPath: dir).sorted() == (fresh + ["doc.txt"]).sorted())
}

/// They swap the one `Editor.runAsAdmin`: one at a time.
@Suite(.serialized) @MainActor struct AdminSaveTests {
    /// Save as Administrator checks the disk again right before the root write: a change made while the
    /// "is protected" sheet was up isn't overwritten. Overwrite (force) still goes through as root.
    @Test func adminSaveRechecksTheDiskBeforeWriting() async throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/hosts"
        try Data("v1\n".utf8).write(to: URL(fileURLWithPath: path))
        var commands: [String] = []
        let real = Editor.runAsAdmin
        defer { Editor.runAsAdmin = real }
        Editor.runAsAdmin = { cmd in commands.append(cmd); return runAsUs(cmd) }

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

    /// S-01: Save as Administrator puts a text that fits in argv in the command itself — no temp file of ours exists for
    /// anything running as us to change while macOS asks for the password. The admin step is stubbed: nothing runs as root.
    @Test func adminSaveSendsAShortTextInTheCommand() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let dir = try tempDir()
        defer { try? fm.removeItem(atPath: dir) }
        try Data("original\n".utf8).write(to: URL(fileURLWithPath: dir + "/hosts"))
        let e = try Editor(URL(fileURLWithPath: dir + "/hosts"))
        defer { e.close() }
        let admin = Editor.runAsAdmin
        defer { Editor.runAsAdmin = admin }
        let text = "127.0.0.1 it's \"quoted\" $HOME `x` \\ %s\r\nend\n"
        var command: String?, temps: [String] = []
        Editor.runAsAdmin = { cmd in
            command = cmd
            temps = ((try? fm.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])   // a file with our text, if any
                .filter { $0.hasPrefix("dfm-admin-save-") && fm.contents(atPath: NSTemporaryDirectory() + $0) == Data(text.utf8) }
            return runAsUs(cmd)
        }
        #expect(await e.adminSave(Data(text.utf8), force: false))
        #expect(command?.contains(ShellContext.quote(text)) == true)
        #expect(command?.contains(NSTemporaryDirectory() + "dfm-admin-save-") == false, "root's own copy only")
        #expect(temps.isEmpty)
        #expect(fm.contents(atPath: dir + "/hosts") == Data(text.utf8))
    }

    /// S-01 / T-07: a text too long for argv goes through a temp file that is the user's alone (0600) while root copies it,
    /// and gone after. Root writes only what hashes to the text: a temp file changed meanwhile writes nothing.
    @Test func adminSaveSendsALongTextThroughAnOwnerOnlyFileRootChecks() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let dir = try tempDir()
        defer { try? fm.removeItem(atPath: dir) }
        try Data("original\n".utf8).write(to: URL(fileURLWithPath: dir + "/hosts"))
        let e = try Editor(URL(fileURLWithPath: dir + "/hosts"))
        defer { e.close() }
        let admin = Editor.runAsAdmin
        defer { Editor.runAsAdmin = admin }
        let long = Data((String(repeating: "x", count: AdminCommand.argvLimit) + "\n").utf8)
        var temp: String?, mode: mode_t?, text: Data?, swap = false
        Editor.runAsAdmin = { cmd in
            guard let r = cmd.range(of: #"/\S*dfm-admin-save-[0-9A-F-]+"#, options: .regularExpression) else { return .failed(cmd) }
            let path = String(cmd[r])
            var st = stat()
            if lstat(path, &st) == 0 { mode = st.st_mode & 0o777 }
            (temp, text) = (path, fm.contents(atPath: path))
            if swap { try? Data("evil\n".utf8).write(to: URL(fileURLWithPath: path)) }   // while the password is asked
            return runAsUs(cmd)
        }
        #expect(await e.adminSave(long, force: false))
        #expect(mode == 0o600, "\(String(mode ?? 0, radix: 8))")
        #expect(text == long)
        #expect(temp.map { !fm.fileExists(atPath: $0) } == true, "removed after")
        #expect(fm.contents(atPath: dir + "/hosts") == long)

        swap = true
        #expect(await !e.adminSave(long + Data("more\n".utf8), force: false))
        #expect(fm.contents(atPath: dir + "/hosts") == long, "nothing written")
        #expect(e.window?.attachedSheet != nil, "says why")
    }

    /// S-01: root checks the file right before writing — a change made while the password was asked isn't overwritten;
    /// the editor asks "changed on disk" as it does for any change.
    @Test func adminSaveAsksWhenTheFileChangedDuringThePassword() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let dir = try tempDir()
        defer { try? fm.removeItem(atPath: dir) }
        let path = dir + "/hosts"
        try Data("v1\n".utf8).write(to: URL(fileURLWithPath: path))
        let e = try Editor(URL(fileURLWithPath: path))
        defer { e.close() }
        let admin = Editor.runAsAdmin
        defer { Editor.runAsAdmin = admin }
        Editor.runAsAdmin = { cmd in
            try? Data("theirs, longer\n".utf8).write(to: URL(fileURLWithPath: path))
            return runAsUs(cmd)
        }
        #expect(await !e.adminSave(Data("mine\n".utf8), force: false))
        #expect(fm.contents(atPath: path) == Data("theirs, longer\n".utf8))
        #expect(e.noticed != nil && e.noticed == Editor.Stamp(path), "asked about the version on disk")
        #expect(e.window?.attachedSheet == nil, "not a failure")
    }
}

/// F-03: the root write never empties the file first: a shorter text is cut to its length after, hard links stay, and a
/// write that fails (a full disk; here a file size limit set right before it) never leaves it shorter — at worst the new
/// text over the old.
@Test func adminWriteRewritesInPlaceWithoutEmptyingFirst() throws {
    let fm = FileManager.default
    let dir = try tempDir()
    defer { try? fm.removeItem(atPath: dir) }
    let path = dir + "/hosts", other = dir + "/link"
    try Data("a long old line\n".utf8).write(to: URL(fileURLWithPath: path))
    #expect(link(path, other) == 0)
    func write(_ text: String, limit: String = "") -> Admin.Outcome {
        var st = stat()
        stat(path, &st)
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let stamp = "\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(String(format: "%09d", st.st_mtimespec.tv_nsec))"
        let cmd = AdminCommand.writeContents(.text(text), sha256: digest, to: path, stamp: stamp, length: text.utf8.count)
        #expect(cmd.contains("umask 022; "))
        return runAsUs(cmd.replacingOccurrences(of: "umask 022; ", with: "umask 022; " + limit))
    }
    guard case .ok = write("short\n") else { Issue.record("write failed"); return }
    #expect(fm.contents(atPath: path) == Data("short\n".utf8))
    #expect(fm.contents(atPath: other) == Data("short\n".utf8), "hard link kept")

    let old = String(repeating: "o", count: 8192), new = String(repeating: "n", count: 16384)   // the limit: 4 KiB
    guard case .ok = write(old) else { Issue.record("write failed"); return }
    guard case .failed = write(new, limit: "ulimit -f 4; trap '' XFSZ; ") else { Issue.record("wrote past the limit"); return }
    #expect(fm.contents(atPath: path)?.count == old.utf8.count, "not cut short")   // macOS refuses the whole write: old text
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

/// Line starts moved along by edits are the ones counted afresh: random inserts and deletes anywhere, with "\n",
/// "\r\n", a lone "\r" (which may come to pair with a "\n"), U+2028, a final newline put in and taken out.
@MainActor @Test func lineStartsFollowEdits() {
    var rng = SystemRandomNumberGenerator()
    let bits = ["a", "bc", "\n", "\r", "\r\n", "\u{2028}", "ї", "\n\n", "xyz\n"]
    func piece() -> String { (0..<Int.random(in: 0...4, using: &rng)).map { _ in bits.randomElement(using: &rng)! }.joined() }
    for _ in 0..<300 {
        let text = NSMutableString(string: (0..<Int.random(in: 0...12, using: &rng)).map { _ in piece() }.joined())
        var starts = LineNumberRuler.lineStarts(text)
        for _ in 0..<20 {
            let at = Int.random(in: 0...text.length, using: &rng), cut = Int.random(in: 0...min(3, text.length - at), using: &rng)
            let new = Bool.random(using: &rng) ? piece() : ""
            text.replaceCharacters(in: NSRange(location: at, length: cut), with: new)
            let edited = NSRange(location: at, length: (new as NSString).length), delta = (new as NSString).length - cut
            starts = LineNumberRuler.lineStarts(starts, text, edited: edited, delta: delta)
            #expect(starts == LineNumberRuler.lineStarts(text), "\(text.debugDescription)")
            if starts != LineNumberRuler.lineStarts(text) { return }
        }
    }
    let t = NSMutableString(string: "a\nb")   // a final newline: a last, empty line
    var s = LineNumberRuler.lineStarts(t)
    t.append("\n")
    s = LineNumberRuler.lineStarts(s, t, edited: NSRange(location: 3, length: 1), delta: 1)
    #expect(s == [0, 2, 4])
    t.deleteCharacters(in: NSRange(location: 3, length: 1))
    #expect(LineNumberRuler.lineStarts(s, t, edited: NSRange(location: 3, length: 0), delta: -1) == [0, 2])
}

/// A re-tint paints only what changed, and the text ends up as a full tint would color it: a block comment opened
/// and closed midway, a letter typed right after a string (it wears the string's red till the tint), random edits.
@MainActor @Test func aReTintColorsAsAFullOneWould() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let file = dir + "/a.c"
    try (0..<40).map { "int f\($0)(void) { return \"s\($0)\" + 0x\($0); } // done \($0)\n" }.joined().write(toFile: file, atomically: true, encoding: .utf8)
    let e = try Editor(URL(fileURLWithPath: file))
    defer { e.window?.close() }
    let storage = e.textView.textStorage!
    func colors(_ s: NSTextStorage) -> [String] {
        var out: [String] = []
        s.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: s.length)) { v, r, _ in out.append("\(r.location)+\(r.length) \(String(describing: v))") }
        return out
    }
    func full() -> [String] {
        let copy = NSTextStorage(attributedString: storage)
        SyntaxColors.apply(Syntax.tokens(copy.string, .clike), to: copy)
        return colors(copy)
    }
    func type(_ s: String, at i: Int, replacing n: Int = 0) async {
        e.textView.setSelectedRange(NSRange(location: i, length: n))
        e.textView.insertText(s, replacementRange: e.textView.selectedRange())
        for _ in 0..<300 { if colors(storage) == full() { break }; try? await Task.sleep(for: .milliseconds(10)) }
        #expect(colors(storage) == full(), "after “\(s)” at \(i)")
    }
    for _ in 0..<300 { if colors(storage) == full() { break }; try? await Task.sleep(for: .milliseconds(10)) }   // the first tint
    let mid = (storage.string as NSString).range(of: "int f20").location
    await type("/*", at: mid)             // everything after it a comment
    await type("*/", at: mid + 200)       // and back
    let quote = (storage.string as NSString).range(of: "\"s3\"").location + 4
    await type("x", at: quote)            // right after a string: plain again
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<15 {
        let at = Int.random(in: 0...storage.length, using: &rng)
        await type(["\"", "/*", "*/", "//", "\n", "0x1f", "q"].randomElement(using: &rng)!, at: at, replacing: min(Int.random(in: 0...3, using: &rng), storage.length - at))
    }
}

/// What a re-tint paints: the edit itself even with the tokens all the same (typed letters may wear a neighbour's
/// color), and a token that only looks unmoved after an edit before it (it's another text there now).
@MainActor @Test func aReTintPaintsTheEditAndWhatMoved() {
    let s = (range: NSRange(location: 5, length: 2), token: Syntax.Token.string)
    #expect(SyntaxColors.changed([s], [s], edited: NSRange(location: 9, length: 1), delta: 1, length: 20) == NSRange(location: 9, length: 1))
    #expect(SyntaxColors.changed([s], [s], edited: NSRange(location: 20, length: 0), delta: 0, length: 20) == nil)
    // 3 letters in at 0: the old string is at 8 now, the one at 5 is new.
    #expect(SyntaxColors.changed([s], [s], edited: NSRange(location: 0, length: 3), delta: 3, length: 20) == NSRange(location: 0, length: 10))
    let moved = (range: NSRange(location: 8, length: 2), token: Syntax.Token.string)
    #expect(SyntaxColors.changed([s], [moved], edited: NSRange(location: 0, length: 3), delta: 3, length: 20) == NSRange(location: 0, length: 3))
}
