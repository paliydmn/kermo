import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

@MainActor private func text(_ w: NSWindow) -> NSTextStorage? { ((w.contentView as? NSScrollView)?.documentView as? NSTextView)?.textStorage }

@MainActor private func color(_ s: NSTextStorage, of word: String) -> NSColor? {
    let r = (s.string as NSString).range(of: word)
    return r.location == NSNotFound ? nil : s.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor
}

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-logs-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// The output window shows a command's colors instead of dropping them — a color cut between two reads too — and
/// stderr stays red whatever colors it has; Run on Servers' lines alike.
@MainActor @Test func outputWindowsShowColors() async throws {
    _ = NSApplication.shared
    let title = "dfm colors " + UUID().uuidString.prefix(6)
    var status: Int32?
    Shell.run(#"printf '\033[31mred\033[0m plain\n\033[1;3'; sleep 0.3; printf '2mgreen\033[0m\n'; printf '\033[33mwarned\033[0m\n' >&2"#,
              in: NSTemporaryDirectory(), title: title) { status = $0 }
    let w = try #require(NSApp.windows.first { $0.title == title })
    defer { w.close() }
    for _ in 0..<300 where status == nil { try await Task.sleep(for: .milliseconds(10)) }
    let s = try #require(text(w))
    #expect(!s.string.contains("\u{1B}") && s.string.contains("red plain\n") && s.string.contains("green\n") && s.string.contains("warned\n"), "\(s.string)")
    #expect(color(s, of: "red") == .systemRed && color(s, of: "plain") == .textColor && color(s, of: "green") == .systemGreen)
    #expect(color(s, of: "warned") == .systemRed, "stderr: red wins")
    let bold = s.attribute(.font, at: (s.string as NSString).range(of: "green").location, effectiveRange: nil) as? NSFont
    #expect(bold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)

    let multi = "Run on 1 server: dfm-" + UUID().uuidString.prefix(6)
    var done = false
    Shell.run(#"printf '\033[36mcyan\033[0m line\n'"#, on: [MultiRun.Server(name: "here", target: .local())], skipped: [], env: [:], title: multi) { _, _ in done = true }
    let m = try #require(NSApp.windows.first { $0.title == multi })
    defer { m.close() }
    for _ in 0..<300 where !done { try await Task.sleep(for: .milliseconds(10)) }
    for _ in 0..<100 where text(m)?.string.contains("cyan") != true { try await Task.sleep(for: .milliseconds(10)) }
    let ms = try #require(text(m))
    #expect(ms.string.contains("here │ cyan line\n") && color(ms, of: "cyan") == .systemCyan && color(ms, of: " line") == .textColor)
}

/// The viewer shows a log's colors, not its escape sequences; a line with colors of its own isn't tinted by its level
/// as well, one without is. Followed, a color cut between two polls comes out whole.
@MainActor @Test func viewerShowsColorsAndFollowsThem() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/app.log"
    try Data("\u{1B}[32mstarted\u{1B}[0m with a warning\nplain error here\n".utf8).write(to: URL(fileURLWithPath: path))
    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    for _ in 0..<500 where !tv.string.hasPrefix("started") { try await Task.sleep(for: .milliseconds(10)) }
    let s = try #require(tv.textStorage)
    #expect(s.string == "started with a warning\nplain error here\n")
    #expect(color(s, of: "started") == .systemGreen && color(s, of: "with a warning") == .textColor, "colored: no orange for its warning")
    #expect(color(s, of: "plain error") == .systemRed, "no colors of its own: tinted")
    v.setFollow(true)
    let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? h.close() }
    try h.seekToEnd()
    try h.write(contentsOf: Data("\u{1B}[3".utf8))
    try await Task.sleep(for: .milliseconds(700))
    try h.write(contentsOf: Data("4mblue\u{1B}[0m tail\n".utf8))
    for _ in 0..<300 where !tv.string.hasSuffix("blue tail\n") { try await Task.sleep(for: .milliseconds(10)) }
    #expect(tv.string.hasSuffix("here\nblue tail\n") && color(s, of: "blue") == .systemBlue && color(s, of: " tail") == .textColor)
}

/// Level tints stay off lines with a color of their own, whatever else they hold.
@Test func levelTintsSkipColoredLines() {
    let text = "a error\nb error\nc warning\n"
    let levels = TextFormat.logLevels(in: text)
    let runs = [ANSI.Run(NSRange(location: 8, length: 1), ANSI.Style(color: 2)), ANSI.Run(NSRange(location: 16, length: 1), ANSI.Style(bold: true))]
    #expect(ANSIColors.uncolored(levels, runs).map(\.range.location) == [0, 16], "b's colored; c only bold")
    #expect(ANSIColors.uncolored(levels, []).count == 3)
}
