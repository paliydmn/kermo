import AppKit
import Testing
@testable import DFileManager
import DFMCore

// Task 9 QA follow-up, group "viewer2" (V4–V7).

@MainActor
private func waitUntil(_ what: String, _ cond: () -> Bool) async throws {
    for _ in 0..<500 where !cond() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(cond(), "timed out: \(what)")
}

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9v2-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor private func press(_ tv: NSTextView, _ chars: String, _ keyCode: UInt16) {
    tv.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!)
}

/// "2026-10-07 12:00:00 INFO request 000123 xxxx…\n" lines up to `size`, then "LAST LINE\n".
private func bigLog(_ path: String, _ size: Int) throws -> Data {
    var d = Data()
    var i = 0
    while d.count < size {
        d.append(contentsOf: String(format: "2026-10-07 12:00:00 INFO request %06d ", i).utf8 + Array(repeating: 0x78, count: i % 61) + [10])
        i += 1
    }
    d.append(contentsOf: "LAST LINE\n".utf8)
    try d.write(to: URL(fileURLWithPath: path))
    return d
}

/// Answers the sheet on `w` (Save is the first button) once it is up.
@MainActor private func answer(_ w: NSWindow?, _ code: NSApplication.ModalResponse) async throws {
    try await waitUntil("a sheet") { w?.attachedSheet != nil }
    guard let w, let sheet = w.attachedSheet else { return }
    w.endSheet(sheet, returnCode: code)
    try await waitUntil("sheet gone") { w.attachedSheet !== sheet }
}

/// V4: a UTF-8 config with one damaged byte opens as UTF-8 (the byte shows as U+FFFD, the Cyrillic stays readable),
/// and the first save asks before writing U+FFFD in its place (Cancel there: the next ⌘S asks again); then it saves
/// as UTF-8, not Windows-1251. A real Windows-1251 file opens as such and its first save asks too.
@MainActor @Test func editorKeepsDamagedUTF8AndAsksBeforeSaving() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/app.conf"
    let original = Data("# Налаштування\nname = ".utf8) + [0xff] + Data(" сервер\n".utf8)
    try original.write(to: URL(fileURLWithPath: path))
    let e = try Editor(URL(fileURLWithPath: path))
    defer { e.close() }
    #expect(e.textView.string == "# Налаштування\nname = \u{FFFD} сервер\n")
    #expect(e.window?.statusText.contains("UTF-8 (damaged)") == true)
    e.textView.string += "мітка = так\n"
    #expect(await !e.save())
    try await answer(e.window, .alertSecondButtonReturn)   // Cancel
    #expect(FileManager.default.contents(atPath: path) == original)
    #expect(await !e.save())   // asks again
    try await answer(e.window, .alertFirstButtonReturn)    // Save
    try await waitUntil("saved") { FileManager.default.contents(atPath: path) != original && !e.saving }   // written off the main thread
    #expect(FileManager.default.contents(atPath: path) == Data("# Налаштування\nname = \u{FFFD} сервер\nмітка = так\n".utf8))
    e.textView.string += "ще\n"
    #expect(await e.save())   // asked once

    let cp = dir + "/old.conf"
    let cpData = "# Коментар\nkey = значення\n".data(using: .windowsCP1251)!
    try cpData.write(to: URL(fileURLWithPath: cp))
    let e2 = try Editor(URL(fileURLWithPath: cp))
    defer { e2.close() }
    #expect(e2.textView.string == "# Коментар\nkey = значення\n")
    #expect(await !e2.save())
    func inode() -> ino_t { var st = stat(); stat(cp, &st); return st.st_ino }
    let before = inode()
    try await answer(e2.window, .alertFirstButtonReturn)
    try await waitUntil("saved") { inode() != before && !e2.saving }   // the same bytes, written off the main thread
    #expect(FileManager.default.contents(atPath: cp) == cpData)
    e2.textView.string += "ще = 2\n"
    #expect(await e2.save())   // answered Save once: not asked again
    #expect(FileManager.default.contents(atPath: cp) == "# Коментар\nkey = значення\nще = 2\n".data(using: .windowsCP1251)!)
}

/// V4 follow-up: closing a changed Windows-1251 file and choosing Save, then Save in the encoding question, saves
/// it and closes the window (the close used to stop at the encoding question).
@MainActor @Test func editorCloseSavesThroughTheEncodingQuestion() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let cp = dir + "/old.conf"
    try "# Коментар\n".data(using: .windowsCP1251)!.write(to: URL(fileURLWithPath: cp))
    let e = try Editor(URL(fileURLWithPath: cp))
    var closed = false
    e.onClose = { closed = true }
    defer { if !closed { e.close() } }
    e.textView.insertText("ключ = 1\n", replacementRange: NSRange(location: 0, length: 0))
    #expect(e.window?.isDocumentEdited == true)
    #expect(e.windowShouldClose(e.window!) == false)
    try await answer(e.window, .alertFirstButtonReturn)   // Save changes? Save
    try await answer(e.window, .alertFirstButtonReturn)   // Save as Windows-1251? Save
    try await waitUntil("closed") { closed }
    #expect(FileManager.default.contents(atPath: cp) == "ключ = 1\n# Коментар\n".data(using: .windowsCP1251)!)
}

/// V5: a log copied and truncated under its writer (leading NULs) opens as text, not hex; a real binary opens as hex,
/// and h shows it as text anyway (and h again goes back to hex).
@MainActor @Test func viewerShowsALogWithLeadingNULsAsTextAndHTogglesBinaryToText() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let log = (0..<100).map { "2026-10-07 12:00:00 worker \($0) ok\n" }.joined()
    let holed = URL(fileURLWithPath: dir + "/app.log")
    try (Data(repeating: 0, count: 64 << 10) + Data(log.utf8)).write(to: holed)
    let (text, info, _, binary) = Viewer.read(holed, .text)
    #expect(!binary && text.hasSuffix(log) && !info.contains("hex"), "\(info)")

    let bin = URL(fileURLWithPath: dir + "/core")
    try (Data([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1, 3, 0, 0, 0]) + Data("hello marker".utf8)).write(to: bin)
    #expect(Viewer.read(bin, .text).binary)
    #expect(Viewer.read(bin, .text, asText: true).0.hasSuffix("hello marker"))

    let v = Viewer(bin)
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    try await waitUntil("hex") { tv.string.hasPrefix("00000000  cf fa ed fe") }
    press(tv, "h", 4)
    try await waitUntil("as text") { tv.string.hasSuffix("hello marker") }
    press(tv, "h", 4)
    try await waitUntil("hex again") { tv.string.hasPrefix("00000000  cf fa ed fe") }
}

/// V6: a 5 MB log goes the sliding-window way (not whole into the text view): End shows its last line, find in the
/// whole file and follow still work there.
@MainActor @Test func viewerShowsAFiveMegabyteLogThroughTheWindow() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/five.log"
    let data = try bigLog(path, 5 << 20)
    #expect(Viewer.isHuge(path))
    #expect(!Viewer.isHuge(try { let p = dir + "/three.log"; _ = try bigLog(p, 3 << 20); return p }()))

    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    #expect(v.win.lowerBound == 0 && v.win.count <= 256 << 10)

    press(tv, "", 119)   // End
    try await waitUntil("last window") { v.big != nil && v.win.upperBound == data.count && !v.sliding }
    #expect(tv.string.hasSuffix("LAST LINE\n"))

    v.findNeedle = "request 000042 "
    v.find(from: 0)
    try await waitUntil("found") { v.lastMatch != nil && !v.sliding && v.win.contains(v.lastMatch!) }
    #expect(v.lastMatch == data.range(of: Data("request 000042 ".utf8))?.lowerBound)

    v.setFollow(true)
    defer { v.setFollow(false) }
    try await waitUntil("at the end") { !v.sliding && tv.string.hasSuffix("LAST LINE\n") }
    let h = try #require(FileHandle(forWritingAtPath: path))
    try h.seekToEnd()
    try h.write(contentsOf: Data("followed ERROR\n".utf8))
    try h.close()
    try await waitUntil("followed") { tv.string.hasSuffix("LAST LINE\nfollowed ERROR\n") }
}

/// V7: a big log truncated while shown: the next move maps it again (no crash on the lost pages), says
/// "file truncated", and the size in the subtitle is the new one.
@MainActor @Test func viewerRemapsABigLogTruncatedUnderIt() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/rotating.log"
    let data = try bigLog(path, 6 << 20)
    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    v.showWindow(around: 5 << 20, top: BigFile.lineStart(data, at: 5 << 20))
    try await waitUntil("near the end") { v.win.contains(5 << 20) && !v.sliding }

    let h = try #require(FileHandle(forWritingAtPath: path))
    try h.truncate(atOffset: 1 << 20)
    try h.close()
    #expect(v.visibleTop() == nil)   // touched nothing past the new end
    try await waitUntil("remapped") { v.big?.count == 1 << 20 && !v.win.isEmpty && !v.sliding }
    #expect(v.win.upperBound <= 1 << 20)
    let subtitle = v.window?.statusText ?? ""
    #expect(subtitle.hasPrefix("file truncated · 1 MB"), "\(subtitle)")
    v.showWindow(around: 0, top: 0)
    try await waitUntil("start") { v.win.lowerBound == 0 && !v.sliding }
    #expect(v.window?.statusText.contains("truncated") == false)
}

/// V5 follow-up: a big log behind an 8 GB sparse hole (copytruncate) opens as text without reading through the hole,
/// and End is as quick (it used to take seconds per GB on every open and every End, so each wait here timed out).
@MainActor @Test func viewerSkipsASparseHoleQuickly() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/holed.log"
    let h = try #require(FileHandle(forWritingAtPath: { FileManager.default.createFile(atPath: path, contents: nil); return path }()))
    try h.seek(toOffset: 8 << 30)
    try h.write(contentsOf: Data(((0..<100).map { "2026-10-07 12:00:00 worker \($0) ok\n" }.joined() + "LAST LINE\n").utf8))
    try h.close()

    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    press(tv, "", 119)   // End
    try await waitUntil("last window") { v.big != nil && v.win.upperBound == v.big!.count && !v.sliding && tv.string.hasSuffix("LAST LINE\n") }
}

/// V5 follow-up: a .plist that doesn't parse and looks binary, switched to text with h, stays text when p falls back
/// from "readable" (it used to drop the choice and show hex again).
@MainActor @Test func prettyFallbackKeepsTheTextChoice() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let url = URL(fileURLWithPath: dir + "/broken.plist")
    try (Data([0, 1, 2, 3, 4, 5, 6, 7]) + Data("not a plist marker".utf8)).write(to: url)
    #expect(Viewer.read(url, .pretty).binary)
    let (text, _, _, binary) = Viewer.read(url, .pretty, asText: true)
    #expect(!binary && text.hasSuffix("not a plist marker"))
}

/// V6 follow-up: a rotated log.gz that unpacks to 6 MB goes through the window too (unpacked to a temp copy that
/// goes on close), with the subtitle saying what it was unpacked from; End reaches its last line.
@MainActor @Test func viewerShowsABigUnpackedLogThroughTheWindow() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/app.log.1"
    let data = try bigLog(path, 6 << 20)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    p.arguments = [path]
    try p.run()
    p.waitUntilExit()
    try #require(p.terminationStatus == 0)

    let v = Viewer(URL(fileURLWithPath: path + ".gz"))
    var closed = false
    v.onClose = { closed = true }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    #expect(v.big == data && v.win.count <= 256 << 10)
    let subtitle = v.window?.statusText ?? ""
    #expect(subtitle.contains("· gzip, ") && subtitle.contains(" unpacked · UTF-8 · showing"), "\(subtitle)")
    press(tv, "", 119)   // End
    try await waitUntil("last window") { v.win.upperBound == data.count && !v.sliding }
    #expect(tv.string.hasSuffix("LAST LINE\n"))
    let copy = try #require(v.unpackedCopy)
    v.close()
    #expect(closed && !FileManager.default.fileExists(atPath: copy.path))
}

/// V6 follow-up: a 5 MB JSON opens as text through the window, not formatted whole into the text view; p isn't
/// offered there. A small one still opens formatted.
@MainActor @Test func viewerShowsABigJSONThroughTheWindow() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/dump.json"
    try Data(("[" + (0..<200_000).map { "\"item \($0) xxxxxxxxxxxxxxxx\"" }.joined(separator: ",\n") + "]\n").utf8).write(to: URL(fileURLWithPath: path))
    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    #expect(v.window?.statusText.contains("p readable") == false)
    press(tv, "p", 35)
    try await Task.sleep(for: .milliseconds(200))
    #expect(v.big != nil && tv.string.utf16.count <= 256 << 10)

    let small = URL(fileURLWithPath: dir + "/small.json")
    try Data("{\"b\":1,\"a\":[2]}".utf8).write(to: small)
    let s = Viewer(small)
    defer { s.close() }
    let stv = try #require(s.scroll.documentView as? NSTextView)
    try await waitUntil("formatted") { stv.string.contains("\"a\" : [\n") }
}

/// V6 follow-up: a 6 MB minified JSON (one line, Cyrillic in it) goes through the window and the window moves
/// through that one line: scrolling to its bottom (wrap on) or right edge (wrap off) slides it on, keeping the same
/// place at the top; no cut splits a character; End shows the last bytes and find selects a match deep inside.
@MainActor @Test func viewerSlidesThroughAOneLineFile() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/min.json"
    var data = Data("[".utf8), i = 0
    while data.count < 6 << 20 { data.append(contentsOf: Array("{\"id\":\(i),\"name\":\"значення \(i)\"},".utf8)); i += 1 }
    data.append(contentsOf: Array("{\"id\":-1,\"name\":\"КІНЕЦЬ\"}]".utf8))
    try data.write(to: URL(fileURLWithPath: path))

    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    let clip = v.scroll.contentView
    func settle() { tv.layoutManager!.ensureLayout(for: tv.textContainer!); tv.sizeToFit() }
    func wholeChars() {
        #expect(data[v.win.lowerBound] & 0xc0 != 0x80 && (v.win.upperBound == data.count || data[v.win.upperBound] & 0xc0 != 0x80), "\(v.win)")
    }
    press(tv, "w", 13)   // wrap on
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    for _ in 0..<2 {
        let before = v.win
        clip.scroll(to: NSPoint(x: 0, y: clip.documentRect.height - clip.bounds.height))
        v.scroll.reflectScrolledClipView(clip)
        let atBottom = try #require(v.visibleTop())
        try await waitUntil("slid forward") { v.win != before && !v.sliding }
        #expect(v.win.lowerBound > before.lowerBound && v.win.contains(atBottom.offset))
        let top = try #require(v.visibleTop()).offset   // the same place: the start of its wrapped row
        #expect(top <= atBottom.offset && top > atBottom.offset - 1024, "\(top) vs \(atBottom.offset)")
        wholeChars()
    }

    press(tv, "w", 13)   // wrap off: one long row; its edge is the right one
    settle()
    try await waitUntil("settled") { !v.sliding }   // the toggle may recentre on the top-left character first
    settle()
    let before = v.win
    clip.scroll(to: NSPoint(x: clip.documentRect.width - clip.bounds.width, y: 0))
    v.scroll.reflectScrolledClipView(clip)
    let atRight = try #require(v.visibleTop())
    try await waitUntil("slid right") { v.win != before && !v.sliding }
    #expect(v.win.lowerBound > before.lowerBound && v.win.contains(atRight.offset))
    let left = try #require(v.visibleTop()).offset   // the next page: from (a little before) where the window ended
    #expect(left <= before.upperBound && left > before.upperBound - 1024, "\(left) vs \(before.upperBound)")
    wholeChars()

    let needle = "{\"id\":\(i / 2),"
    v.findNeedle = needle
    v.find(from: 0)
    try await waitUntil("found") { v.lastMatch != nil && !v.sliding && v.win.contains(v.lastMatch!) }
    #expect(v.lastMatch == data.range(of: Data(needle.utf8))?.lowerBound)
    let sel = tv.selectedRange()
    #expect((tv.string as NSString).substring(with: sel) == needle)
    #expect(tv.visibleRect.intersects(rect(tv, sel)), "match not on screen")

    press(tv, "", 119)   // End
    try await waitUntil("last window") { v.big != nil && v.win.upperBound == data.count && !v.sliding }
    #expect(tv.string.hasSuffix("\"КІНЕЦЬ\"}]"))
    let end = (tv.string as NSString).range(of: "КІНЕЦЬ", options: .backwards)
    #expect(tv.visibleRect.intersects(rect(tv, end)), "the end not on screen")
    wholeChars()
}

/// Where `r` of `tv`'s text is drawn, in the text view's coordinates.
@MainActor private func rect(_ tv: NSTextView, _ r: NSRange) -> NSRect {
    let lm = tv.layoutManager!
    return lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tv.textContainer!)
        .offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
}

/// V7 follow-up: h right after the shown big log is truncated ends in hex and stays there (the remap the truncate
/// starts used to finish last and put text back while in hex mode, so the next h then stuck to text); h again: text.
@MainActor @Test func viewerHexAfterATruncateStaysHex() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/rotating.log"
    _ = try bigLog(path, 6 << 20)
    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    let h = try #require(FileHandle(forWritingAtPath: path))
    try h.truncate(atOffset: 1 << 20)
    try h.close()
    press(tv, "h", 4)
    try await waitUntil("hex") { tv.string.hasPrefix("00000000  32 30 32 36") }
    try await Task.sleep(for: .milliseconds(500))
    #expect(tv.string.hasPrefix("00000000  32 30 32 36"))
    press(tv, "h", 4)
    try await waitUntil("text") { v.big?.count == 1 << 20 && !v.sliding && tv.string.hasPrefix("2026-10-07") }
}

/// V5 follow-up: a log fetched from a server (not sparse) with 10 MB of real NULs before its text — a copytruncate
/// hole written out — opens as text through the window, and End shows its last line.
@MainActor @Test func viewerShowsALogAfterTenMegabytesOfRealNULs() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/fetched.log"
    try (Data(count: 10 << 20) + Data(((0..<100).map { "2026-10-07 12:00:00 worker \($0) ok\n" }.joined() + "LAST LINE\n").utf8))
        .write(to: URL(fileURLWithPath: path))
    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    press(tv, "", 119)   // End
    try await waitUntil("last window") { v.big != nil && v.win.upperBound == v.big!.count && !v.sliding && tv.string.hasSuffix("LAST LINE\n") }
}

/// The text from the character at the view's top left on, `n` UTF-16 units of it.
@MainActor private func topLeftText(_ v: Viewer, _ n: Int) -> String {
    let tv = v.scroll.documentView as! NSTextView, b = v.scroll.contentView.bounds, o = tv.textContainerOrigin
    let lm = tv.layoutManager!
    let ch = lm.characterIndexForGlyph(at: lm.glyphIndex(for: NSPoint(x: max(0, b.minX - o.x), y: max(0, b.minY - o.y)), in: tv.textContainer!))
    let ns = tv.string as NSString
    return ns.substring(with: NSRange(location: ch, length: min(n, ns.length - ch)))
}

/// V6 follow-up: a minified .js — a licence header line, then one 6 MB line — goes through the window (it used to be
/// 0..<38, the header alone, for good): scrolling slides it on with and without wrap, and find selects a match.
@MainActor @Test func viewerSlidesPastAShortLineBeforeALongOne() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/vendor.min.js"
    var data = Data("/*! lib v3.7.1 | (c) Someone | MIT */\n".utf8), i = 0
    while data.count < 6 << 20 { data.append(contentsOf: Array("function f\(i)(a){return a+\(i)};".utf8)); i += 1 }
    try data.write(to: URL(fileURLWithPath: path))

    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    let clip = v.scroll.contentView
    press(tv, "w", 13)   // wrap on
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    #expect(v.win.count > 128 << 10, "\(v.win)")
    var before = v.win
    clip.scroll(to: NSPoint(x: 0, y: clip.documentRect.height - clip.bounds.height))
    v.scroll.reflectScrolledClipView(clip)
    try await waitUntil("slid down") { v.win != before && !v.sliding }
    #expect(v.win.lowerBound > before.lowerBound)

    v.findNeedle = "function f100("
    v.find(from: 0)
    try await waitUntil("found") { v.lastMatch != nil && !v.sliding && v.win.contains(v.lastMatch!) }
    #expect((tv.string as NSString).substring(with: tv.selectedRange()) == "function f100(")

    press(tv, "w", 13)   // wrap off
    tv.layoutManager!.ensureLayout(for: tv.textContainer!)
    tv.sizeToFit()
    try await waitUntil("settled") { !v.sliding }
    before = v.win
    clip.scroll(to: NSPoint(x: clip.documentRect.width - clip.bounds.width, y: 0))
    v.scroll.reflectScrolledClipView(clip)
    try await waitUntil("slid right") { v.win != before && !v.sliding }
    #expect(v.win.lowerBound > before.lowerBound)
}

/// V6 follow-up: without wrap, a window of a few long rows that fits the view's height (a CSV with 33 KB lines) moves
/// on at its right edge each time — it used to recentre on the top-left character, in its first half: the same window.
@MainActor @Test func viewerSlidesAFewLongRowsWithoutWrap() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/wide.csv"
    var data = Data(), i = 0
    while data.count < 6 << 20 {
        data.append(contentsOf: Array("\(i)".utf8) + Array(repeating: UInt8(ascii: ","), count: 1) + Array(repeating: UInt8(ascii: "x"), count: 33_000) + [13, 10])
        i += 1
    }
    try data.write(to: URL(fileURLWithPath: path))

    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    let clip = v.scroll.contentView
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    for _ in 0..<3 {
        let before = v.win
        clip.scroll(to: NSPoint(x: clip.documentRect.width - clip.bounds.width, y: 0))
        v.scroll.reflectScrolledClipView(clip)
        try await waitUntil("slid right") { v.win != before && !v.sliding }
        #expect(v.win.lowerBound > before.lowerBound && v.win.upperBound > before.upperBound, "\(before) → \(v.win)")
    }
}

/// V6 follow-up: in a one-line file with damaged UTF-8 (a stray 0xFF every few hundred bytes), sliding keeps the
/// text that was at the top on screen — a U+FFFD counted as 3 bytes skipped ~1 KB that was never shown per slide.
@MainActor @Test func viewerSlidesThroughDamagedUTF8WithoutSkipping() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/damaged.json"
    var data = Data("[".utf8), i = 0
    while data.count < 6 << 20 {
        data.append(contentsOf: Array("{\"id\":\(i),\"name\":\"значення \(i)\"},".utf8))
        if i % 10 == 0 { data.append(0xff) }
        i += 1
    }
    try data.write(to: URL(fileURLWithPath: path))

    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    let clip = v.scroll.contentView
    press(tv, "w", 13)   // wrap on
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    for _ in 0..<2 {
        let before = v.win
        clip.scroll(to: NSPoint(x: 0, y: clip.documentRect.height - clip.bounds.height))
        v.scroll.reflectScrolledClipView(clip)
        let shown = topLeftText(v, 24)
        try await waitUntil("slid forward") { v.win != before && !v.sliding }
        #expect(topLeftText(v, 600).contains(shown), "lost “\(shown)”: now “\(topLeftText(v, 60))”")
    }
}

/// A 6 MB CSV of 33 KB CRLF lines "поле N,xxx…" (a window holds a few of them), or a 6 MB one-line JSON.
private func wideCSV(_ path: String) throws {
    var data = Data(), i = 0
    while data.count < 6 << 20 { data.append(contentsOf: Array("поле \(i),".utf8) + Array(repeating: UInt8(ascii: "x"), count: 33_000) + [13, 10]); i += 1 }
    try data.write(to: URL(fileURLWithPath: path))
}
private func oneLineJSON(_ path: String) throws {
    var data = Data("[".utf8), i = 0
    while data.count < 6 << 20 { data.append(contentsOf: Array("{\"id\":\(i),\"name\":\"entry \(i)\"},".utf8)); i += 1 }
    try data.write(to: URL(fileURLWithPath: path))
}

/// Pages forward once without wrap (scrolls to the window's right edge).
@MainActor private func pageRight(_ v: Viewer) async throws {
    let clip = v.scroll.contentView, before = v.win
    clip.scroll(to: NSPoint(x: clip.documentRect.width - clip.bounds.width, y: 0))
    v.scroll.reflectScrolledClipView(clip)
    try await waitUntil("paged right") { v.win != before && !v.sliding }
}

/// V6 follow-up: w on a big file keeps the window and the text at the top left — a wide CSV or a one-line JSON read
/// a page or two in used to page on (or back) by itself, the toggle's own scrolling taken for reaching an edge.
@MainActor @Test func viewerWrapToggleKeepsThePlace() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    for (name, make, pages) in [("wide.csv", wideCSV, 1), ("min.json", oneLineJSON, 2)] as [(String, (String) throws -> Void, Int)] {
        try make(dir + "/" + name)
        let v = Viewer(URL(fileURLWithPath: dir + "/" + name))
        defer { v.close() }
        let tv = try #require(v.scroll.documentView as? NSTextView)
        try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
        for _ in 0..<pages { try await pageRight(v) }
        for _ in 0..<2 {
            let before = v.win, shown = topLeftText(v, 16)
            press(tv, "w", 13)
            tv.layoutManager!.ensureLayout(for: tv.textContainer!)
            tv.sizeToFit()
            try await Task.sleep(for: .milliseconds(300))
            try await waitUntil("still") { !v.sliding }
            #expect(v.win == before, "\(name): \(before) → \(v.win)")
            #expect(topLeftText(v, 600).contains(shown), "\(name): lost “\(shown)”: now “\(topLeftText(v, 40))”")
        }
    }
}

/// V6 follow-up: without wrap, in a window of a few long rows that fits the view, going back to column 0 to read
/// the next row's start stays put (it used to page back ~128 KB per nudge, a page forward already landing there);
/// pulling on past the left edge (a trackpad's overscroll) pages back. A one-row window still pages back at its left edge.
@MainActor @Test func viewerColumnZeroDoesNotPageBack() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try wideCSV(dir + "/wide.csv")
    let v = Viewer(URL(fileURLWithPath: dir + "/wide.csv"))
    defer { v.close() }
    let clip = v.scroll.contentView
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    try await pageRight(v)
    clip.scroll(to: NSPoint(x: 200, y: 0))
    v.scroll.reflectScrolledClipView(clip)
    let before = v.win, left = -clip.contentInsets.left   // where the view rests at column 0
    clip.scroll(to: NSPoint(x: left, y: 0))
    v.scroll.reflectScrolledClipView(clip)
    try await Task.sleep(for: .milliseconds(300))
    try await waitUntil("still") { !v.sliding }
    #expect(v.win == before, "\(before) → \(v.win)")
    clip.setBoundsOrigin(NSPoint(x: left - 30, y: 0))   // a trackpad pulling past the edge
    try await waitUntil("paged back") { v.win.lowerBound < before.lowerBound && !v.sliding }

    try oneLineJSON(dir + "/min.json")
    let j = Viewer(URL(fileURLWithPath: dir + "/min.json"))
    defer { j.close() }
    try await waitUntil("first window") { j.big != nil && !j.win.isEmpty && !j.sliding }
    try await pageRight(j)
    let paged = j.win
    j.scroll.contentView.scroll(to: NSPoint(x: -j.scroll.contentView.contentInsets.left, y: 0))
    j.scroll.reflectScrolledClipView(j.scroll.contentView)
    try await waitUntil("one row: back at its left edge") { j.win.lowerBound < paged.lowerBound && !j.sliding }
}
