import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

private let a = SFTPTarget(host: "deploy@web", port: 2222)
private let b = SFTPTarget(host: "nas")

@Test @MainActor func serverItemsRoundTripThroughAPasteboard() {
    let pb = NSPasteboard(name: .init("dfm-test-" + UUID().uuidString))
    defer { pb.releaseGlobally() }

    let remote = TransferItems(from: .sftp(a), paths: ["/var/www/a b.txt", "/var/www/кирилиця"])
    pb.clearContents()
    pb.writeObjects(remote.pasteboardWriters)
    #expect(TransferItems(pb) == remote)
    // Finder sees no file in it, so it can't take the drop.
    #expect(pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.isEmpty ?? true)

    let local = TransferItems(from: .local, paths: ["/tmp/x y", "/tmp/z"])
    pb.clearContents()
    pb.writeObjects(local.pasteboardWriters)
    #expect(TransferItems(pb) == local)

    // Items of two servers at once (can't come from one panel): only the first server's.
    pb.clearContents()
    pb.writeObjects([TransferItems.pasteboardItem(a, "/1"), TransferItems.pasteboardItem(b, "/2"), TransferItems.pasteboardItem(a, "/3")])
    #expect(TransferItems(pb) == TransferItems(from: .sftp(a), paths: ["/1", "/3"]))

    pb.clearContents()
    pb.setString("just text", forType: .string)
    #expect(TransferItems(pb) == nil)
}

@Test @MainActor func dropOperationFollowsFinderRulesAcrossServers() {
    let none: NSDragOperation = [.copy, .move, .generic]   // no modifier held
    func op(_ from: Endpoint, _ paths: [String], _ to: Endpoint, _ target: String, _ mask: NSDragOperation = none) -> NSDragOperation {
        PanelViewController.dragOperation(mask: mask, items: TransferItems(from: from, paths: paths), to: to, target: target)
    }
    let home = NSTemporaryDirectory()
    #expect(op(.local, [home], .local, NSHomeDirectory()) == .move)                // same volume (both exist)
    #expect(op(.local, ["/tmp/f"], .sftp(a), "/srv") == .copy)
    #expect(op(.sftp(a), ["/srv/f"], .local, home) == .copy)
    #expect(op(.sftp(a), ["/srv/f"], .sftp(a), "/srv/sub") == .move)             // same server: rename
    let locked = SFTPTarget(host: a.host, port: 2222, persist: 60)                  // A1: same server, other settings
    #expect(op(.sftp(a), ["/srv/f"], .sftp(locked), "/srv/sub") == .move)
    #expect(op(.sftp(a), ["/srv/f"], .sftp(locked), "/srv") == [])
    #expect(op(.sftp(a), ["/srv/f"], .sftp(b), "/srv") == .copy)
    #expect(op(.sftp(a), ["/srv/f"], .sftp(b), "/srv", .copy) == .copy)          // ⌥
    #expect(op(.sftp(a), ["/srv/f"], .sftp(b), "/srv", .generic) == .move)       // ⌘
    #expect(op(.sftp(a), ["/srv/f"], .sftp(a), "/srv/sub", .copy) == .copy)
    // Into the folder they're already in, or onto themselves: nothing.
    #expect(op(.sftp(a), ["/srv/f"], .sftp(a), "/srv") == [])
    #expect(op(.sftp(a), ["/srv/d"], .sftp(a), "/srv/d") == [])
    #expect(op(.sftp(a), ["/srv/f"], .sftp(b), "/srv") != [])                     // same path, other server: fine
    #expect(op(.local, ["/srv/f"], .sftp(a), "/srv") != [])
    #expect(op(.local, [], .local, "/tmp") == [])
}
