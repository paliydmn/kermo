import AppKit
import Testing
@testable import DFMCore
@testable import DFileManager

// Task 9 §6, servers: R2.

/// R2: a server log's tail says what it is — "last 4 MB of 1.2 GB" — where the size goes.
@MainActor @Test func viewerOfARemoteTailSaysSo() async throws {
    _ = NSApplication.shared
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9remote-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    let url = URL(fileURLWithPath: d + "/syslog")
    try Data(repeating: 0x61, count: 2048).write(to: url)
    let fmt = { ByteCountFormatter.short($0) }
    func loaded(_ v: Viewer) async throws -> String {
        for _ in 0..<1000 where v.window?.subtitle.hasPrefix("Loading") == true { try await Task.sleep(for: .milliseconds(20)) }
        return v.window?.subtitle ?? ""
    }

    let tail = Viewer(url, remote: (SFTPTarget(host: "web"), "/var/log/syslog", 5_000_000_000))
    defer { tail.close() }
    #expect(try await loaded(tail).hasPrefix("last \(fmt(2048)) of \(fmt(5_000_002_048)) · UTF-8"))

    let whole = Viewer(url, remote: (SFTPTarget(host: "web"), "/var/log/syslog", 0))
    defer { whole.close() }
    #expect(try await loaded(whole).hasPrefix("\(fmt(2048)) · UTF-8"))
}
