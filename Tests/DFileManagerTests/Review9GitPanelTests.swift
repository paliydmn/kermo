import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

/// L14: a panel whose `git status` hangs (here: the repo's .gitignore is a FIFO, as a repo on a stale mount would)
/// still shows the git column for the healthy repo it moves to next.
@MainActor @Test(.enabled(if: GitStatus.available)) func gitColumnComesAfterAStuckRepo() async throws {
    let base = NSTemporaryDirectory() + "dfm-gitpanel-" + UUID().uuidString
    let stuck = base + "/stuck", healthy = base + "/healthy"
    for d in [stuck, healthy] {
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        let p = try Process.run(URL(fileURLWithPath: "/usr/bin/git"), arguments: ["init", "-q", d])
        p.waitUntilExit()
    }
    #expect(mkfifo(stuck + "/.gitignore", 0o644) == 0)
    defer {
        let fd = open(stuck + "/.gitignore", O_WRONLY | O_NONBLOCK)   // lets a git still blocked on it finish
        if fd >= 0 { close(fd) }
        try? FileManager.default.removeItem(atPath: base)
    }
    FileManager.default.createFile(atPath: healthy + "/new.txt", contents: nil)

    let panel = PanelViewController(tabs: [stuck], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let column = panel.table.tableColumn(withIdentifier: .init("git"))!
    try await Task.sleep(for: .milliseconds(500))   // the stuck repo's git status has started and hangs
    #expect(column.isHidden)
    panel.navigate(to: healthy)
    for _ in 0..<300 where column.isHidden { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!column.isHidden, "the healthy repo's status shows without waiting for the stuck one")
}
