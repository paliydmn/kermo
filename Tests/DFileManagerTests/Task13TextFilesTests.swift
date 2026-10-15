import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Text files Quick Look shows as an icon, and the file actions next to them.

@MainActor private func waitUntil(_ done: () -> Bool) async {
    for _ in 0..<500 { if done() { return }; try? await Task.sleep(for: .milliseconds(10)) }
}
private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t13text-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// ⌃Q: a text with a name Quick Look doesn't know shows as text, F3's colors; a binary one, and what Quick Look
/// knows, stay with Quick Look; over 256 KB, the first part and a line that says so.
@MainActor @Test func quickViewShowsTextQuickLookWouldNot() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    FileManager.default.createFile(atPath: d + "/hosts", contents: Data("127.0.0.1 localhost\n".utf8))
    FileManager.default.createFile(atPath: d + "/blob", contents: Data([0x7f, 0x45, 0x4c, 0x46] + [UInt8](repeating: 0, count: 64) + [1, 2, 3]))
    FileManager.default.createFile(atPath: d + "/notes.txt", contents: Data("plain\n".utf8))
    FileManager.default.createFile(atPath: d + "/big.conf", contents: Data(repeating: UInt8(ascii: "x"), count: TextPeek.limit + 10))
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    panel.setQuickView(true)
    panel.preview(URL(fileURLWithPath: d + "/hosts"))
    await waitUntil { panel.peekedText != nil }
    #expect(panel.peekedText == "127.0.0.1 localhost\n")
    panel.preview(URL(fileURLWithPath: d + "/blob"))
    await waitUntil { panel.peekedText == nil }
    #expect(panel.peekedText == nil, "binary: Quick Look's")
    panel.preview(URL(fileURLWithPath: d + "/big.conf"))
    await waitUntil { panel.peekedText != nil }
    #expect(panel.peekedText?.hasSuffix("··· first 256 KB · F3 views it all ···\n") == true)
    #expect(panel.peekedText?.utf16.count == TextPeek.limit + "\n\n··· first 256 KB · F3 views it all ···\n".utf16.count)
    panel.preview(URL(fileURLWithPath: d + "/notes.txt"))
    #expect(panel.peekedText == nil, "Quick Look shows .txt itself, at once")
    panel.preview(URL(fileURLWithPath: d + "/hosts"))
    await waitUntil { panel.peekedText != nil }
    panel.preview(URL(fileURLWithPath: d))   // a folder: Quick Look's, once looked at
    await waitUntil { panel.peekedText == nil }
    #expect(panel.peekedText == nil)
    // No setQuickView(false): QLPreviewView's close asserts outside a window.
}
