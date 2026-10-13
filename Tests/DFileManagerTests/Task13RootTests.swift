import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 13: a server panel as root (`SFTPTarget.sudo`).

/// A stand-in for a server's sudo that runs what follows `-n --` (DFMCore's tests have the logging one).
func fakeSudo(in dir: String) throws -> String {
    let path = dir + "/sudo"
    try Data("#!/bin/sh\n[ \"$1\" = -n ] && [ \"$2\" = -- ] || exit 2\nexec \"$3\"\n".utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, 0o755)
    return path
}

/// Dragged or copied out of a root panel, items are its user's: the pasteboard never carries root.
@Test @MainActor func rootItemsOnAPasteboardAreTheUsers() {
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))
    defer { pb.releaseGlobally() }
    let root = SFTPTarget(host: "deploy@web").asRoot()
    pb.clearContents()
    pb.writeObjects(TransferItems(from: .sftp(root), paths: ["/etc/hosts"]).pasteboardWriters)
    #expect(TransferItems(pb) == TransferItems(from: .sftp(root.asRoot(false)), paths: ["/etc/hosts"]))
}

extension ServerLockTests {
/// A locked server's root panel asks for Touch ID as its user's does (same user@host:port); refused, the panel stays.
@Test func rootPanelOfALockedServerAsks() async throws {
    var local = SavedServer(address: "localhost")!
    local.locked = true
    var asked = 0, answer = false
    ServerLock.servers = { [local] }
    ServerLock.authenticate = { _ in asked += 1; return answer }
    defer { ServerLock.servers = { [] }; ServerLock.relock() }
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-rootlock-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let root = SFTPTarget.local(sudo: try fakeSudo(in: dir))
    #expect(ServerLock.needsUnlock(root) && ServerLock.server(for: root)?.id == local.id)

    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    func settle() async { for _ in 0..<250 where panel.busyMessage != nil { try? await Task.sleep(for: .milliseconds(20)) } }
    panel.loadRemote(root, dir: dir, select: nil)
    await settle()
    #expect(asked == 1 && panel.remote == nil)
    answer = true
    panel.loadRemote(root, dir: dir, select: nil)
    await settle()
    #expect(asked == 2 && panel.remote?.target == root)
}
}
