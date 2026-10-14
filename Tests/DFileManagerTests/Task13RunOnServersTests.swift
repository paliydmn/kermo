import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

@MainActor private func text(_ w: NSWindow) -> NSTextStorage? { ((w.contentView as? NSScrollView)?.documentView as? NSTextView)?.textStorage }

/// Run on Servers' output (`.local()` targets: this Mac's sh): one window, each line under its server's name — names
/// lined up, stderr in red — then the summary with what failed in red and named, the skipped too. ⎋ stops them all and
/// keeps the window for the summary, then closes it. (Quitting's count of running windows: other tests' windows run
/// meanwhile, so it isn't looked at here.)
@MainActor @Test func severalServersShareOneOutputWindow() async throws {
    _ = NSApplication.shared
    let title = "Run on 3 servers: k13-" + UUID().uuidString.prefix(6)
    let servers = [MultiRun.Server(name: "web1", target: .local(persist: 1)), MultiRun.Server(name: "db", target: .local(persist: 2))]
    var outcomes: [MultiRun.Outcome]?
    Shell.run("echo hi; echo no >&2; exit 3", on: servers, skipped: ["vault"], env: [:], title: title) { outcomes = $0 }
    let w = try #require(NSApp.windows.first { $0.title == title })
    for _ in 0..<500 where outcomes == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(outcomes == [.exit(3), .exit(3)])
    let storage = try #require(text(w))
    let lines = storage.string.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.filter { $0.hasPrefix("web1 │ ") }.sorted() == ["web1 │ hi", "web1 │ no"] && lines.filter { $0.hasPrefix("db   │ ") }.count == 2,
            "\(lines)")
    #expect(lines.suffix(2) == ["✗ 2 (web1: exit 3, db: exit 3)  🔒 1 skipped (vault)", ""], "\(lines)")
    let err = (storage.string as NSString).range(of: "│ no")
    #expect(storage.attribute(.foregroundColor, at: err.location + 2, effectiveRange: nil) as? NSColor == .systemRed)
    let x = (storage.string as NSString).range(of: "✗")
    #expect(storage.attribute(.foregroundColor, at: x.location, effectiveRange: nil) as? NSColor == .systemRed)
    #expect(storage.attribute(.foregroundColor, at: (storage.string as NSString).range(of: "🔒").location, effectiveRange: nil) as? NSColor == .textColor)
    #expect(w.subtitle.hasPrefix("3 servers · done · ") && w.subtitle.hasSuffix(" · Esc closes"))
    w.close()

    let slow = "Run on 2 servers: k13-" + UUID().uuidString.prefix(6)
    var ended: [MultiRun.Outcome]?
    Shell.run("echo start; sleep 5; echo done", on: servers, skipped: [], env: [:], title: slow) { ended = $0 }
    let s = try #require(NSApp.windows.first { $0.title == slow })
    defer { s.close() }
    for _ in 0..<300 where text(s)?.string.components(separatedBy: "start").count != 3 { try await Task.sleep(for: .milliseconds(10)) }
    s.windowController?.cancelOperation(nil)
    for _ in 0..<300 where ended == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(ended == [.stopped, .stopped] && s.isVisible && text(s)?.string.hasSuffix("⎋ 2 stopped\n") == true)
    #expect(s.subtitle.hasPrefix("2 servers · stopped · "))
    s.windowController?.cancelOperation(nil)
    #expect(!s.isVisible, "⎋ again closes it")
}
