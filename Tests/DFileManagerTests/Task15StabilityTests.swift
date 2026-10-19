import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

/// Task 15 sss-6: small stability holes — bad saved state, hostile servers, endless output.

/// T-05: a `folderSort` value Kermo didn't write (empty, a lone colon) used to trap on every visit to that folder.
@Test func aDamagedFolderSortFallsBackToName() {
    for bad in ["", ":", "::", "x", "name:", ":1", "nope:0x"] {
        let order = PanelViewController.sortOrder(bad)
        #expect(order.key == .name, "\(bad)")
    }
    #expect(PanelViewController.sortOrder(nil) == (.name, true))
    #expect(PanelViewController.sortOrder("") == (.name, true))
    #expect(PanelViewController.sortOrder("size:0") == (.size, false))
    #expect(PanelViewController.sortOrder("mtime:1") == (.mtime, true))
    #expect(PanelViewController.sortOrder("mtime") == (.mtime, true))
}

/// T-04: a server can say any size; two files of `Int64.max` marked (or listed) trapped the status line's sum.
@Test func twoHugeSizesDontOverflowTheStatusLine() {
    let huge = FileItem(name: "a", kind: .file, size: .max, mtime: 0, mode: 0o644, flags: 0)
    let other = FileItem(name: "b", kind: .file, size: .max, mtime: 0, mode: 0o644, flags: 0)
    let dir = FileItem(name: "d", kind: .dir, size: 0, mtime: 0, mode: 0o755, flags: 0)
    #expect(PanelViewController.bytes(of: [huge, other], dirSizes: [:]) == .max)
    #expect(PanelViewController.bytes(of: [huge, dir], dirSizes: ["d": .max]) == .max)
    #expect(PanelViewController.bytes(of: [dir], dirSizes: ["d": 5]) == 5)
}

/// By the clock: the main actor is busy in the full suite.
@MainActor private func waitUntil(_ seconds: Double = 20, _ done: () -> Bool) async {
    let end = Date().addingTimeInterval(seconds)
    while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
}
private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-sss6-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// T-09: ⌘L ⇥ on a server that took the connection and then said nothing (its sftp-server stuck on a dead NFS
/// mount) kept a thread and that server's process for each ⇥, until the connection died. The next ⇥ ends the
/// one before, and a few seconds end the last; neither beeps nor changes what's typed.
@MainActor @Test func tabOnAServerThatDoesntAnswerLetsGo() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d + "/srvonly", withIntermediateDirectories: true)
    let server = d + "/sftp-server"   // answers until told to hang: then each new session's server just waits
    try Data("""
    #!/bin/sh
    [ -e '\(d)/hang' ] || exec /usr/libexec/sftp-server
    echo $$ >> '\(d)/pids'
    exec sleep 60
    """.utf8).write(to: URL(fileURLWithPath: server))
    chmod(server, 0o755)
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    panel.loadRemote(.local(server: server), dir: d, select: nil)
    await waitUntil { panel.remote?.dir == d }
    FileManager.default.createFile(atPath: d + "/hang", contents: nil)
    func pids() -> [pid_t] {
        ((try? String(contentsOfFile: d + "/pids", encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
    }

    let field = NSTextView()
    field.string = "s"
    _ = panel.control(NSTextField(), textView: field, doCommandBy: #selector(NSResponder.insertTab(_:)))
    await waitUntil { pids().count == 1 }
    _ = panel.control(NSTextField(), textView: field, doCommandBy: #selector(NSResponder.insertTab(_:)))
    await waitUntil { pids().count == 2 }
    let p = pids()
    try #require(p.count == 2)
    await waitUntil(3) { !alive(p[0]) }
    #expect(!alive(p[0]), "the second ⇥ ends the first")
    #expect(alive(p[1]))
    await waitUntil(10) { !alive(p[1]) }
    #expect(!alive(p[1]), "and its deadline the second")
    #expect(field.string == "s")
}
