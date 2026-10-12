import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 13: server file history and diff with a server.

/// Saves keep versions in ~/.config/dfilemanager/history.noindex (Spotlight stays out by the name) unless
/// `defaults write com.dmn.dfilemanager serverHistory -bool false`.
@MainActor @Test func serverHistoryCanBeTurnedOff() {
    let app = AppDelegate()
    let was = UserDefaults.standard.object(forKey: "serverHistory")
    defer { UserDefaults.standard.set(was, forKey: "serverHistory") }
    UserDefaults.standard.removeObject(forKey: "serverHistory")
    #expect(app.serverHistory?.root == AppDelegate.historyRoot && AppDelegate.historyRoot == Config.path("history.noindex"))
    UserDefaults.standard.set(false, forKey: "serverHistory")
    #expect(app.serverHistory == nil)
}

/// Compare Files' pair, three rules in order: two marked files; the cursor's and the same name in the other panel's
/// folder, if it's there; the cursor's and the other panel's cursor's.
@MainActor @Test func diffPairRules() async {
    var asked: [String] = []
    func pair(_ marked: [String], _ cursor: String?, _ same: String?, _ other: String?, there: Bool = true) async -> [String]? {
        await AppDelegate.diffPair(marked: marked, cursor: cursor, sameName: same, otherCursor: other) { asked.append($0); return there ? $0 : nil }.map { [$0, $1] }
    }
    #expect(await pair(["m1", "m2"], "c", "s", "o") == ["m1", "m2"] && asked.isEmpty, "two marked: nothing looked at")
    #expect(await pair(["m1", "m2", "m3"], "c", "s", "o") == ["c", "s"] && asked == ["s"], "three: the cursor's rules")
    #expect(await pair(["c"], "c", "s", "o", there: false) == ["c", "o"], "no such name next door: the other cursor")
    #expect(await pair([], "c", nil, "o") == ["c", "o"], "the other panel isn't a folder here")
    asked = []
    #expect(await pair([], nil, nil, "o") == nil && asked.isEmpty, "no file under the cursor")
    #expect(await pair(["c"], "c", "s", nil, there: false) == nil)
}

extension ServerCopiesTests {
/// Compare Files with a server's file: it's fetched as a preview is (the copy already here for that size and date, else
/// downloaded and kept with the others; nothing over 64 MB), and `diff -u` names it "host:/path", not its copy's temp
/// path — a server's file against this Mac's, and against another server's.
@Test func diffWithAServerShowsItsNameNotItsCopy() async throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-sdiff-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { ServerCopies.quit(); try? FileManager.default.removeItem(atPath: d) }
    try Data("a\nb\n".utf8).write(to: URL(fileURLWithPath: d + "/web.conf"))
    try Data("a\nc\n".utf8).write(to: URL(fileURLWithPath: d + "/db.conf"))
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let app = AppDelegate()
    func side(_ name: String) throws -> AppDelegate.DiffSide {
        let a = try FileManager.default.attributesOfItem(atPath: d + "/" + name)
        return .init(path: d + "/" + name, server: .local(), size: (a[.size] as! NSNumber).int64Value, mtime: (a[.modificationDate] as! Date).timeIntervalSince1970.rounded(.down))
    }
    func run(_ command: String) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    let web = try side("web.conf"), db = try side("db.conf")
    let copy = try #require(await app.localCopy(web, in: panel))
    #expect(copy != web.path && copy.contains("/dfm-sftp-"))
    #expect(FileManager.default.contents(atPath: copy) == Data("a\nb\n".utf8))
    #expect(await app.localCopy(web, in: panel) == copy, "the copy for that size and date: not fetched again")
    #expect(ServerCopies.preview(of: .local(), web.path, size: web.size, mtime: web.mtime)?.path == copy, "kept as a preview's")

    let mine = AppDelegate.DiffSide(path: d + "/db.conf")
    let local = try run(AppDelegate.diffCommand(copy, mine.path, labels: (web.label, mine.label)))
    #expect(local.hasPrefix("--- localhost:\(d)/web.conf\n+++ \(d)/db.conf\n") && !local.contains("dfm-sftp-"), "\(local)")
    let dbCopy = try #require(await app.localCopy(db, in: panel))
    let both = try run(AppDelegate.diffCommand(copy, dbCopy, labels: (web.label, db.label)))
    #expect(both == "--- localhost:\(d)/web.conf\n+++ localhost:\(d)/db.conf\n@@ -1,2 +1,2 @@\n a\n-b\n+c\n", "\(both)")
    #expect(AppDelegate.diffCommand("/x y", "/z", labels: nil) == "diff -u '/x y' /z", "this Mac's files only: as before")

    var huge = web
    huge.size = PanelViewController.previewLimit + 1
    huge.mtime += 1
    #expect(await app.localCopy(huge, in: panel) == nil && panel.statusText.contains("too big to compare"))
}
}
