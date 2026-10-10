import AppKit
import Testing
@testable import DFileManager
@testable import DFMCore

@MainActor
private func waitUntil(_ what: String, _ cond: () -> Bool) async throws {
    for _ in 0..<1000 where !cond() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(cond(), "timed out: \(what)")
}

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r10-viewer-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func append(_ path: String, _ s: String) throws {
    let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? h.close() }
    try h.seekToEnd()
    try h.write(contentsOf: Data(s.utf8))
}

// MARK: - I1: & filters the viewer's lines, like less

@Test func lineFilterKeepsOrDropsLines() throws {
    #expect(LineFilter("") == nil && LineFilter("!") == nil)
    let with = try #require(LineFilter("error")), without = try #require(LineFilter("!error"))
    #expect(!with.exclude && without.exclude && without.spec == "!error")
    let text = "a ok\nb ERROR\nc Error: x\nd fine"
    #expect(with.apply(text) == "b ERROR\nc Error: x\n")
    #expect(without.apply(text) == "a ok\nd fine", "the last line counts without its \\n")

    var rest = ""
    #expect(with.apply("x error\ny err", rest: &rest) == "x error\n" && rest == "y err")
    #expect(with.apply("or\nz\n", rest: &rest) == "y error\n" && rest.isEmpty, "a line cut between polls is judged whole")

    // A Windows log: "\r\n" is one Character, and still ends a line — also when a poll cuts it in two.
    #expect(with.apply("error one\r\nok two\r\n") == "error one\n" && without.apply("error one\r\nok two\r\n") == "ok two\n")
    #expect(without.apply("ok\r", rest: &rest) == "" && without.apply("\nerror\r\n", rest: &rest) == "ok\n" && rest.isEmpty)
}

@Test func lineFilterOverAMappedFileFoldsCaseAndStopsAtItsLimit() throws {
    let data = Data("1 ПОМИЛКА диска\n2 ok\n3 помилка мережі\n4 ok".utf8)
    let f = try #require(LineFilter("Помилка"))
    let (kept, more) = f.apply(data, limit: 1 << 20)
    #expect(String(decoding: kept, as: UTF8.self) == "1 ПОМИЛКА диска\n3 помилка мережі\n" && !more)
    #expect(String(decoding: try #require(LineFilter("!помилка")).apply(data, limit: 1 << 20).0, as: UTF8.self) == "2 ok\n4 ok")
    let (first, cut) = f.apply(data, limit: 30)
    #expect(String(decoding: first, as: UTF8.self) == "1 ПОМИЛКА диска\n" && cut)
}

@MainActor @Test func viewerFilterShowsMatchingLinesAndFollowsThroughIt() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/app.log"
    try Data("start\nGET /a 200\nGET /b 500 error\nPOST /c 200\n".utf8).write(to: URL(fileURLWithPath: path))

    let v = Viewer(URL(fileURLWithPath: path))
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    try await waitUntil("loaded") { tv.string.hasPrefix("start") }
    v.setLineFilter(LineFilter("get"))
    try await waitUntil("filtered") { tv.string == "GET /a 200\nGET /b 500 error\n" }
    #expect(v.window?.subtitle.contains("LINES WITH “get”") == true)
    v.setLineFilter(LineFilter("!get"))
    try await waitUntil("excluded") { tv.string == "start\nPOST /c 200\n" }

    v.setLineFilter(LineFilter("error"))
    try await waitUntil("errors") { tv.string == "GET /b 500 error\n" }
    v.setFollow(true)
    try append(path, "GET /d 200\nGET /e 502 err")
    try await Task.sleep(for: .milliseconds(700))
    try append(path, "or\nGET /f 200\n")
    try await waitUntil("followed") { tv.string.hasSuffix("/e 502 error\n") }
    try await Task.sleep(for: .milliseconds(700))
    #expect(tv.string == "GET /b 500 error\nGET /e 502 error\n")

    v.setFollow(false)
    v.setLineFilter(nil)
    try await waitUntil("all lines") { tv.string.hasSuffix("GET /f 200\n") && tv.string.hasPrefix("start\n") }
}

/// Over 4 MB (the sliding window): the filter goes over the whole file, not the window on screen.
@MainActor @Test func hugeFileFilterScansTheWholeFile() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var text = Data()
    var i = 0
    while text.count < 5 << 20 {
        text.append(contentsOf: (i == 3 ? "line 3 NEEDLE\n" : "line \(i) xxxxxxxxxxxxxxxxxxxxxxxx\n").utf8)
        i += 1
    }
    text.append(contentsOf: "last needle\n".utf8)
    let url = URL(fileURLWithPath: dir + "/huge.log")
    try text.write(to: url)

    let v = Viewer(url)
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    try await waitUntil("first window") { v.big != nil && !v.win.isEmpty && !v.sliding }
    v.setLineFilter(LineFilter("needle"))
    try await waitUntil("filtered") { tv.string == "line 3 NEEDLE\nlast needle\n" && !v.sliding }
    v.setLineFilter(nil)
    try await waitUntil("window again") { tv.string.hasPrefix("line 0 ") && !v.sliding }
    #expect(v.win.lowerBound == 0 && v.win.count <= 256 << 10)
}
