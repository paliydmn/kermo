import AppKit
import Testing
@testable import DFileManager
@testable import DFMCore

@MainActor
private func waitUntil(_ what: String, _ cond: () -> Bool) async throws {
    for _ in 0..<500 where !cond() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(cond(), "timed out: \(what)")
}

/// The viewer's sliding window over a 33 MB log (just over the 32 MB whole-file limit): never shown on screen, but laid out and scrolled for real.
@MainActor @Test func hugeFileViewerSlidesAndSearches() async throws {
    _ = NSApplication.shared
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-huge-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let lineLen = 50, count = (33 << 20) / 50
    var bytes = [UInt8](repeating: 0x78, count: count * lineLen)   // "0000123456 xxxx…x\n", 50 bytes per line
    for i in 0..<count {
        var n = i
        for d in (0..<10).reversed() { bytes[i * lineLen + d] = UInt8(48 + n % 10); n /= 10 }
        bytes[i * lineLen + 10] = 32
        bytes[i * lineLen + lineLen - 1] = 10
    }
    for k in 11..<lineLen - 1 { bytes[600_000 * lineLen + k] = 0x7A }   // "zzz…" on line 600000 only
    let data = Data(bytes)
    let url = URL(fileURLWithPath: dir + "/big.log")
    try data.write(to: url)

    let v = Viewer(url)
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    #expect(v.win.lowerBound == 0 && v.win.count <= 256 << 10 && v.win.count % lineLen == 0)
    #expect(v.visibleTop()?.offset == 0)

    // Jump to the middle: that line is at the top.
    let mid = 20 << 20, top = mid / lineLen * lineLen
    v.showWindow(around: mid, top: top)
    try await waitUntil("middle window") { v.win.contains(mid) && !v.sliding }
    #expect(v.visibleTop()?.offset == top)

    // Scrolling to the window's bottom edge slides it forward; the same line stays at the top.
    let before = v.win
    let clip = v.scroll.contentView
    clip.scroll(to: NSPoint(x: 0, y: clip.documentRect.height - clip.bounds.height))
    v.scroll.reflectScrolledClipView(clip)
    let atBottom = try #require(v.visibleTop())
    try await waitUntil("slid forward") { v.win != before && !v.sliding }
    #expect(v.win.lowerBound > before.lowerBound && v.win.contains(atBottom.offset))
    #expect(v.visibleTop()?.offset == atBottom.offset)

    // Whole-file search lands on the only "zzz" line, far outside the current window.
    v.findNeedle = "ZZZZ"
    v.find(from: 25 << 20)   // well past the current window (debug builds scan slowly)
    try await waitUntil("found") { v.lastMatch != nil && !v.sliding && v.win.contains(v.lastMatch!) }
    #expect(v.lastMatch == 600_000 * lineLen + 11)
}

/// V1 (task 8): End in a file over 32 MB shows its very last lines — lines of any length, not page-aligned.
@MainActor @Test func hugeFileViewerEndShowsTheLastLine() async throws {
    _ = NSApplication.shared
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-huge-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var text = Data()
    var i = 0
    while text.count < 33 << 20 {
        text.append(contentsOf: "2026-10-07 12:00:00 INFO request \(i) ".utf8 + Array(repeating: 0x78, count: i % 97) + [10])
        i += 1
    }
    text.append(contentsOf: "LIVE 39\nLIVE 40\nNEEDLE-AT-END ERROR\n".utf8)
    let url = URL(fileURLWithPath: dir + "/huge.log")
    try text.write(to: url)

    let v = Viewer(url)
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    v.showWindow(around: text.count, top: text.count)   // End
    try await waitUntil("last window") { v.win.upperBound == text.count && !v.sliding }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    #expect(tv.string.hasSuffix("LIVE 40\nNEEDLE-AT-END ERROR\n"))
    // And it's on screen: the last line's rect lies inside the visible part of the view.
    let lm = try #require(tv.layoutManager)
    let ns = tv.string as NSString
    let lastLine = ns.range(of: "NEEDLE-AT-END ERROR", options: .backwards)
    let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: lastLine, actualCharacterRange: nil), in: tv.textContainer!)
        .offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
    let visible = v.scroll.contentView.bounds
    #expect(rect.minY >= visible.minY && rect.maxY <= visible.maxY + 1, "last line \(rect) not in \(visible)")
}
