import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 13: Copy SSH Key to Server… — which key, and where it's offered.

/// The server's own key file's public half if it has one; else ~/.ssh's usual ones that are there, ed25519 first.
@Test func theKeyToCopy() throws {
    let home = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-keys-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: home) }
    #expect(AppDelegate.publicKeys(identity: nil, home: home).isEmpty)
    for k in ["id_rsa", "id_ed25519", "work"] { FileManager.default.createFile(atPath: home + "/.ssh/\(k).pub", contents: Data("ssh-x AAAA".utf8)) }
    #expect(AppDelegate.publicKeys(identity: nil, home: home) == [home + "/.ssh/id_ed25519.pub", home + "/.ssh/id_rsa.pub"])
    #expect(AppDelegate.publicKeys(identity: home + "/.ssh/work", home: home) == [home + "/.ssh/work.pub"])
    #expect(AppDelegate.publicKeys(identity: home + "/.ssh/nopub", home: home).count == 2, "no .pub next to it: the usual ones")
}

/// In each server's menu after Copy SSH Command, and in ⌘⇧P.
@MainActor @Test func copyKeyIsInEachServersMenu() {
    let app = AppDelegate()
    let row = ServerRow(target: SFTPTarget(host: "me@web.invalid"), saved: nil, title: "web")
    let titles = app.serverMenu(.server(row)).map(\.title)
    #expect(titles.firstIndex(of: "Copy SSH Command").map { titles[$0 + 1] } == "Copy SSH Key to Server…", "\(titles)")
    let hits = HeaderSearchModel.results("ssh-copy-id", commands: app.makeCommands(), folders: [], files: [], recent: [])
    #expect(hits.first?.hits.first?.title == "Copy SSH Key to Server…")
}
