import AppKit
import Testing
@testable import DFileManager

@MainActor
private func waitUntil(_ what: String, _ cond: () -> Bool) async throws {
    for _ in 0..<500 where !cond() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(cond(), "timed out: \(what)")
}

private func append(_ path: String, _ s: some Sequence<UInt8>) throws {
    let h = try #require(FileHandle(forWritingAtPath: path))
    defer { try? h.close() }
    try h.seekToEnd()
    try h.write(contentsOf: Data(s))
}

/// V3 + V8 (task 9): follow (f) on a growing log: a character written in two halves arrives whole, scrolling up
/// stops the autoscroll, a rotated file is followed (and said to be rotated) even when the new one is already
/// bigger, and the kept text is capped without moving what's on screen.
@MainActor @Test func viewerFollowsAGrowingAndRotatedLog() async throws {
    _ = NSApplication.shared
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-follow-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/app.log"
    let initial = (0..<300).map { String(format: "line %03d xxxxxxxxxx\n", $0) }.joined()
    try Data(initial.utf8).write(to: URL(fileURLWithPath: path))

    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    try await waitUntil("loaded") { tv.string == initial }
    v.setFollow(true)
    let clip = v.scroll.contentView
    func atEnd() -> Bool { clip.bounds.maxY >= tv.frame.height - 20 }

    let line = Array("привіт ERROR\n".utf8)
    try append(path, line[..<3])   // "п" and half of "р"
    try await Task.sleep(for: .milliseconds(700))
    try append(path, line[3...])
    try await waitUntil("whole line") { tv.string.hasSuffix("\n") && tv.string.count > initial.count }
    #expect(tv.string == initial + "привіт ERROR\n")
    #expect(atEnd())

    // Scrolled up to read: new lines come in, the view stays put.
    clip.scroll(to: .zero)
    v.scroll.reflectScrolledClipView(clip)
    try append(path, "while reading\n".utf8)
    try await waitUntil("appended") { tv.string.hasSuffix("while reading\n") }
    #expect(clip.bounds.minY == 0)
    try append(path, "still reading\n".utf8)
    try await waitUntil("appended") { tv.string.hasSuffix("still reading\n") }
    #expect(clip.bounds.minY == 0)
    tv.scrollToEndOfDocument(nil)   // back at the end: autoscroll again
    try append(path, "at the end\n".utf8)
    try await waitUntil("appended") { tv.string.hasSuffix("at the end\n") }
    #expect(atEnd())

    // Rotation: the new file is already longer than the old one was.
    try FileManager.default.moveItem(atPath: path, toPath: path + ".1")
    try append(path + ".1", "last old line\n".utf8)
    try Data((initial + "first new line\n").utf8).write(to: URL(fileURLWithPath: path))
    try await waitUntil("rotated") { tv.string.hasSuffix("first new line\n") }
    #expect(tv.string.contains("at the end\nlast old line\n\n——— file rotated ———\nline 000"))
    #expect(!tv.string.contains("truncated"))

    // Capped: the oldest lines go, and the line at the top of the view stays there.
    let lm = try #require(tv.layoutManager)
    func topLine() -> String {
        let i = lm.characterIndexForGlyph(at: lm.glyphIndex(for: NSPoint(x: 0, y: clip.bounds.minY - tv.textContainerOrigin.y + 1), in: tv.textContainer!))
        let ns = tv.string as NSString
        return ns.substring(with: ns.lineRange(for: NSRange(location: i, length: 0)))
    }
    let ns = tv.string as NSString
    let keep = ns.range(of: "line 200", options: .backwards)
    clip.scroll(to: NSPoint(x: 0, y: lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: keep.location), effectiveRange: nil).minY + tv.textContainerOrigin.y))
    v.scroll.reflectScrolledClipView(clip)
    #expect(topLine() == "line 200 xxxxxxxxxx\n")
    v.followLimit = ns.length
    try append(path, "over the limit\n".utf8)
    try await waitUntil("trimmed") { tv.string.hasSuffix("over the limit\n") }
    #expect(tv.string.utf16.count <= v.followLimit / 2 + 100 && !tv.string.contains("привіт"))
    #expect(topLine() == "line 200 xxxxxxxxxx\n")
}

/// V3: f off and on again neither repeats what was already followed nor loses what came in while off.
@MainActor @Test func viewerFollowOffAndOnDoesNotRepeatText() async throws {
    _ = NSApplication.shared
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-follow-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/app.log"
    try Data("start\n".utf8).write(to: URL(fileURLWithPath: path))

    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    try await waitUntil("loaded") { tv.string == "start\n" }
    v.setFollow(true)
    try append(path, "A\n".utf8)
    try await waitUntil("A") { tv.string.hasSuffix("A\n") }
    v.setFollow(false)
    try append(path, "C\n".utf8)
    try await Task.sleep(for: .milliseconds(700))
    #expect(tv.string == "start\nA\n")
    v.setFollow(true)
    try append(path, "B\n".utf8)
    try await waitUntil("B") { tv.string.hasSuffix("B\n") }
    try await Task.sleep(for: .milliseconds(700))
    #expect(tv.string == "start\nA\nC\nB\n")
}
