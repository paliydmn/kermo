import AppKit
import Foundation
import Testing
@testable import DFileManager

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9l-app-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// L19: F4 reads the file (up to 32 MB, maybe on a share that doesn't answer) off the main thread: `Editor.open`
/// returns before the read, and the window shows up once it's done.
@MainActor @Test func editorOpenReadsOffTheMainThread() async throws {
    _ = NSApplication.shared
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let url = URL(fileURLWithPath: d + "/sshd_config")
    try Data("Port 22\n".utf8).write(to: url)

    Editor.open(url)
    #expect(Editor.window(for: url) == nil, "not read on the main thread")
    for _ in 0..<100 where Editor.window(for: url) == nil { try await Task.sleep(for: .milliseconds(20)) }
    let window = try #require(Editor.window(for: url))
    defer { window.close() }
    #expect((window.windowController as? Editor)?.textView.string == "Port 22\n")
}

/// L19: coming back to the editor checks the file and reloads it off the main thread, too.
@MainActor @Test func editorFocusReloadsOffTheMainThread() async throws {
    _ = NSApplication.shared
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let url = URL(fileURLWithPath: d + "/hosts")
    try Data("old\n".utf8).write(to: url)
    let e = try Editor(url)
    e.showWindow(nil)
    defer { e.close() }
    try Data("new, longer\n".utf8).write(to: url)

    e.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
    #expect(e.textView.string == "old\n", "not read on the main thread")
    for _ in 0..<100 where e.textView.string == "old\n" { try await Task.sleep(for: .milliseconds(20)) }
    #expect(e.textView.string == "new, longer\n")
}
