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

/// T-10: reads not shown yet piled up without end while the main thread was busy. Past the limit the oldest go and
/// the window is told (its "only the last 4 MB kept"); an EOF is never dropped.
@Test func theOutputInboxKeepsItsLimit() {
    let inbox = Inbox()
    #expect(inbox.put(Data(repeating: 1, count: 1000), 1))
    for _ in 0..<320 { _ = inbox.put(Data(repeating: 0x78, count: 1 << 16), 0) }   // 20 MB, nobody taking
    _ = inbox.put(Data(), 1)
    #expect(inbox.peak <= Inbox.limit)
    let (parts, cut) = inbox.take()
    #expect(cut)
    #expect(parts.map(\.data.count).reduce(0, +) <= Inbox.limit)
    #expect(parts.last?.stream == 1 && parts.last?.data.isEmpty == true, "stderr's EOF kept")
    #expect(parts.first?.stream == 0, "the oldest went: stderr's first read")
    #expect(inbox.put(Data("x".utf8), 0), "taken: the next read asks the main thread again")
    #expect(inbox.take().cut == false)
}

/// T-10: 12 MB printed while the main thread is held (a sheet up, a Keychain read) stays within the inbox's limit,
/// and all of it to the end is read with POSIX read (no `availableData`, which raises on a read error).
@MainActor @Test func aFirehoseWhileTheMainThreadIsBusyStaysBounded() async throws {
    _ = NSApplication.shared
    let tag = "dfm-t10-" + UUID().uuidString.prefix(8)
    var status: Int32?
    Shell.run("echo \(tag) >/dev/null; head -c 12000000 /dev/zero | tr '\\0' x | fold -w 99; echo END", in: NSTemporaryDirectory()) { status = $0 }
    let w = try #require(NSApp.windows.first { $0.title.contains(tag) })
    defer { w.close() }
    let shell = try #require(w.delegate as? OutputWindow)
    usleep(1_000_000)   // the main thread busy: nothing drains
    await waitUntil(60) { status != nil }
    #expect(shell.inbox.peak <= Inbox.limit, "\(shell.inbox.peak)")
    let text = try #require((w.contentView as? NSScrollView)?.documentView as? NSTextView).string
    #expect(status == 0 && text.hasSuffix("xEND\n"), "\(String(describing: status)) \(text.suffix(80).debugDescription)")
    #expect(w.subtitle.contains("only the last 4 MB kept"), "\(w.subtitle)")
}

extension ServerLockTests {   // they swap `AppDelegate.runAsAdmin` and `answering`, as Enable Touch ID for sudo's test does
    /// S-05: a refused copy says why on the panel and never gets to the password (nothing runs as root); one that
    /// would replace what's there asks first, and Cancel runs nothing.
    @Test func adminCopyRefusesBeforeThePassword() async throws {
        let d = tempDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: d + "/Work/backup", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: d + "/shared", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: d + "/to/Work", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: d + "/shared/Work", withDestinationPath: "/etc")
        var ran: [String] = [], asked: [(String, [String])] = []
        let admin = AppDelegate.runAsAdmin
        AppDelegate.runAsAdmin = { ran.append($0); return .ok }
        defer { AppDelegate.runAsAdmin = admin; AppDelegate.answering = nil }
        let app = AppDelegate()
        app.panels = [PanelViewController(tabs: [d], index: 0, showHidden: false), PanelViewController(tabs: [d], index: 0, showHidden: false)]
        app.panels.forEach { $0.loadViewIfNeeded() }
        defer { app.panels.forEach { $0.shutdown() } }
        AppDelegate.answering = { m, b, _ in asked.append((m, b)); return 1 }   // Cancel

        await app.adminTransfer([d + "/Work"], to: d + "/Work/backup", move: false)
        #expect(app.panels[0].statusText.contains("Copy as administrator: Cannot copy a folder into itself"), "\(app.panels[0].statusText)")
        await app.adminTransfer([d + "/Work"], to: d + "/shared", move: true)
        #expect(app.panels[0].statusText.contains("is a link — not followed as root"), "\(app.panels[0].statusText)")
        #expect(ran.isEmpty && asked.isEmpty)

        await app.adminTransfer([d + "/Work"], to: d + "/to", move: false)
        #expect(asked.map(\.0) == ["“Work” is in \((d as NSString).abbreviatingWithTildeInPath)/to already. Replace as administrator?"])
        #expect(asked.first?.1 == ["Replace", "Cancel"] && ran.isEmpty)
        AppDelegate.answering = { m, b, _ in asked.append((m, b)); return 0 }   // Replace
        await app.adminTransfer([d + "/Work"], to: d + "/to", move: false)
        #expect(ran == [AdminCommand.copy([d + "/Work"], to: d + "/to")])
        await app.adminTransfer([d + "/Work"], to: d + "/to", move: true)   // mv -n never replaces: no question
        #expect(asked.count == 2 && ran.count == 2)
    }
}

/// A tag search's hits are named from ~ (`Documents/x.pdf`) wherever the panel is: F8, ⇧F8, F5, ↩ took them from the
/// panel's folder — another folder's file of that name, or a backup's. And %s / ⌥F5 in any search's results named the
/// hit by its last component in the search's root: `rm %s` on `build/old/config.yml` meant `./config.yml`.
@MainActor @Test func searchHitsAreActedOnWhereTheyAre() throws {
    let d = tempDir(), elsewhere = tempDir()
    defer { for p in [d, elsewhere] { try? FileManager.default.removeItem(atPath: p) } }
    let app = AppDelegate()
    app.panels = [PanelViewController(tabs: [elsewhere], index: 0, showHidden: false), PanelViewController(tabs: [elsewhere], index: 0, showHidden: false)]
    app.panels.forEach { $0.loadViewIfNeeded() }
    defer { app.panels.forEach { $0.shutdown() } }
    let panel = app.panels[0]
    let flag = panel.beginSearch("tagged “Red”", in: d, root: d)
    panel.addSearchResults([FileItem(name: "sub/x.pdf", kind: .file, size: 1, mtime: 0, mode: 0o644, flags: 0)], from: flag)
    panel.finishSearch(flag)
    panel.moveCursor(toName: "sub/x.pdf")
    #expect(panel.targetURLs.map(\.path) == [d + "/sub/x.pdf"], "not \(elsewhere)/sub/x.pdf")
    let context = app.shellContext
    #expect(context.dir == d && context.targets == ["sub/x.pdf"] && context.cursor == "sub/x.pdf")
    #expect(AppDelegate.name(URL(fileURLWithPath: "/a/b/c"), in: "/a") == "b/c" && AppDelegate.name(URL(fileURLWithPath: "/x/y"), in: "/") == "x/y")
    #expect(AppDelegate.name(URL(fileURLWithPath: "/a"), in: "/a") == "a", "the folder itself: its name, as before")
}

extension ServerLockTests {   // swaps `AppDelegate.answering`
    /// A zip the index can't read through (its second member's header is damaged) had no names to ask about, so ⌥F9
    /// extracted straight into the folder — bsdtar writes the members it can, over the files there, unasked. It goes
    /// through a staging folder now, as a tar: tar fails on the bad member, and nothing lands.
    @MainActor @Test func anArchiveTheIndexCantReadIsntExtractedOverFiles() async throws {
        _ = NSApplication.shared
        let dir = tempDir(), dest = dir + "/dest"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        try Data(String(repeating: "NEW-A", count: 100).utf8).write(to: URL(fileURLWithPath: dir + "/a.txt"))
        try Data(String(repeating: "NEW-B", count: 100).utf8).write(to: URL(fileURLWithPath: dir + "/b.txt"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-0", "u.zip", "a.txt", "b.txt"]
        zip.currentDirectoryURL = URL(fileURLWithPath: dir)
        try zip.run()
        zip.waitUntilExit()
        var bytes = try Data(contentsOf: URL(fileURLWithPath: dir + "/u.zip"))
        let second = try #require(bytes.range(of: Data("PK\u{3}\u{4}".utf8), in: 4..<bytes.count))
        bytes[second.lowerBound + 2] = 9   // b's local header: no longer a header
        try bytes.write(to: URL(fileURLWithPath: dir + "/u.zip"))
        #expect((try? ArchiveIndex.read(dir + "/u.zip")) == nil, "the index can't read it")
        try Data("old-a".utf8).write(to: URL(fileURLWithPath: dest + "/a.txt"))

        let panel = PanelViewController(tabs: [dest], index: 0, showHidden: true)
        panel.loadViewIfNeeded()
        defer { panel.shutdown() }
        let app = AppDelegate()
        app.panels = [panel]
        AppDelegate.answering = { _, _, _ in 1 }   // Overwrite, if asked
        defer { AppDelegate.answering = nil }
        await app.extract(dir + "/u.zip", nil, to: dest)
        func window() -> NSWindow? { NSApp.windows.last { $0.title.hasPrefix("Extract “u.zip”") } }
        func said() -> String { ((window()?.contentView as? NSScrollView)?.documentView as? NSTextView)?.string ?? "" }
        await waitUntil { said().contains("[exit") && (try? FileManager.default.contentsOfDirectory(atPath: dest))?.count == 1 }
        window()?.close()
        #expect(said().contains("[exit"), "tar failed on the bad member: \(said())")
        #expect(FileManager.default.contents(atPath: dest + "/a.txt") == Data("old-a".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest) == ["a.txt"], "no staging folder left")
    }
}

/// R-04: the production question looked at a command's first word only: `cd /srv && rm -rf releases/*`, `ls; rm x`,
/// `find . -delete`, `> app.log` ran unasked. Each command of a list or pipeline counts now, and more ways to destroy.
@Test func dangerousCommandsAreSpottedAnywhereInTheLine() {
    for c in ["cd /srv/app && rm -rf releases/*", "ls; rm x", "true || rm x", "ls | xargs rm", "ls | xargs -I {} rm {}",
              "echo $(rm x)", "find . -name '*.log' -delete", "find . -exec rm {} +", "truncate -s0 f", "shred -u key",
              "rsync -a --delete src/ dst/", "git clean -fdx", "git reset --hard HEAD~1", "> app.log", "echo x > /etc/hosts",
              "cat a 2> err.log", "systemctl disable nginx", "sudo systemctl mask nginx", "cd x\nrm y"] {
        #expect(Shell.isDangerous(c), Comment(rawValue: c))
    }
    for c in ["ls -la | grep x", "cd /srv && git status", "echo hi >> log", "make 2>&1 | tee", "ls > /dev/null", "ls 2>/dev/null",
              "find . -name x", "rsync -a src/ dst/", "git reset HEAD x", "git log --oneline", "echo a && echo b"] {
        #expect(!Shell.isDangerous(c), Comment(rawValue: c))
    }
}

/// E-02: closing the main window with an editor in the Dock asked the quit question (it counted visible windows only),
/// the app lived on with the editor, and the answer stuck: a later ⌘Q quit with its unsaved text unasked.
@MainActor @Test func aWindowInTheDockKeepsTheAppAlive() {
    final class Docked: NSWindow { override var isMiniaturized: Bool { true }; override var canBecomeMain: Bool { true } }
    let main = NSWindow(), editor = Docked(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    #expect(!editor.isVisible)
    #expect(AppDelegate.keepsAlive(editor, besides: main))
    #expect(!AppDelegate.keepsAlive(main, besides: main))
}

extension ServerCopiesTests {
    /// E-03: a server file's copy saved in another app goes up once two looks a second apart see it settled. Saved
    /// right before ⌘Q, it was still "on the server": the quit question didn't name it and quitting removed it.
    @Test func aCopySavedJustBeforeQuitIsKept() throws {
        let d = tempDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        let dir = d + "/dfm-sftp-test"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir + "/app.conf")
        try Data("old".utf8).write(to: url)
        let c = ServerCopies.Copy(url, .local(), d + "/app.conf", listed: (3, 0), baseline: SFTPClient.Attrs(kind: .file, size: 3, mtime: 0, mode: 0o644), preview: false)
        ServerCopies.add(c)
        #expect(ServerCopies.unsynced.isEmpty)
        try Data("new text".utf8).write(to: url)   // the other app's ⌘S, then ⌘Q here at once
        #expect(ServerCopies.unsynced.map(\.url) == [url])
        ServerCopies.quit()
        #expect(FileManager.default.contents(atPath: url.path) == Data("new text".utf8), "kept, with its marker")
        #expect(FileManager.default.fileExists(atPath: dir + "/" + TempCopies.keptMarker))
    }
}

/// E-05: a state file that's there but can't be read (root's after a `sudo` edit) read as no file: the list started
/// empty, unsaid, and the next save replaced the user's file. It's said now and never saved over; a menu file that
/// can't be read is an error, not a reason to write the examples over it.
@Test func anUnreadableStateFileIsNeverSavedOver() throws {
    let d = tempDir()
    defer { chmod(d + "/servers.json", 0o600); try? FileManager.default.removeItem(atPath: d) }
    try Data("[{\"host\":\"me@web\"}]".utf8).write(to: URL(fileURLWithPath: d + "/servers.json"))
    chmod(d + "/servers.json", 0o000)
    let (value, problem) = Config.loadKeeping("servers.json", as: [String: String].self, in: d)
    #expect(value == nil && problem?.contains("won't save over it") == true, "\(problem ?? "")")
    Config.save("servers.json", ["new"], in: d)
    Config.flush()
    chmod(d + "/servers.json", 0o600)
    #expect(FileManager.default.contents(atPath: d + "/servers.json") == Data("[{\"host\":\"me@web\"}]".utf8))
    #expect(try Config.contents(d + "/missing") == nil)
    chmod(d + "/servers.json", 0o000)
    #expect(throws: (any Error).self) { try Config.contents(d + "/servers.json") }
}

/// E-06: a reload (the file changed on disk, nothing unsaved) kept the old text's undo steps: ⌘Z then applied them to
/// the new text — garbled, or out of range — and a save wrote that over the change.
@MainActor @Test func aReloadForgetsTheOldTextsUndo() async throws {
    _ = NSApplication.shared
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let url = URL(fileURLWithPath: d + "/a.txt")
    try Data("first version\n".utf8).write(to: url)
    let e = try Editor(url)
    defer { e.close() }
    e.textView.setSelectedRange(NSRange(location: 0, length: 0))
    e.textView.insertText("typed ", replacementRange: e.textView.selectedRange())
    #expect(e.textView.undoManager?.canUndo == true)
    #expect(await e.save())
    try Data("x\n".utf8).write(to: url)   // a git pull
    #expect(await e.reload())
    #expect(e.textView.string == "x\n")
    #expect(e.textView.undoManager?.canUndo != true)
}

/// S2-05: F8 on a server deleted what's at each name now, whatever the panel had listed — a server panel isn't watched,
/// its listing can be hours old, and there's no Trash. What's another thing since (a file rewritten, a folder in a
/// file's place) is skipped and named; a folder that's still a folder goes, whatever was added to it.
@MainActor @Test func aServerDeleteSkipsWhatChangedSinceItWasListed() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fm = FileManager.default
    for f in ["x", "y", "z"] { fm.createFile(atPath: d + "/" + f, contents: Data("1".utf8)) }
    try fm.createDirectory(atPath: d + "/w", withIntermediateDirectories: true)
    let listed = try SFTP.list(.local(), d)
    Thread.sleep(forTimeInterval: 1.1)   // whole-second dates
    fm.createFile(atPath: d + "/x", contents: Data("rewritten".utf8))
    try fm.removeItem(atPath: d + "/y")
    try fm.createDirectory(atPath: d + "/y", withIntermediateDirectories: true)
    fm.createFile(atPath: d + "/w/new", contents: nil)
    let job = AppDelegate.serverDelete(listed, in: d, on: .local(), env: [:])
    job.runAcross()
    #expect(fm.fileExists(atPath: d + "/x") && fm.fileExists(atPath: d + "/y"))
    #expect(!fm.fileExists(atPath: d + "/z") && !fm.fileExists(atPath: d + "/w"))
    #expect(Set(job.progress.errors) == ["\(d)/x: changed since it was listed, skipped", "\(d)/y: changed since it was listed, skipped"])
}

extension ServerLockTests {   // swaps `AppDelegate.answering`
    /// S2-03: "changed on the server" → Overwrite wrote over whatever was there by then, unchecked: a change made while
    /// the question (or Compare's diff) was up went unseen. Overwrite now replaces the version it showed; one newer asks again.
    @MainActor @Test func overwriteReplacesOnlyTheVersionItShowed() async throws {
        let d = tempDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        let file = d + "/app.conf", mine = d + "/mine"
        try Data("v1\n".utf8).write(to: URL(fileURLWithPath: file))
        let c = try SFTPClient(.local())
        let state = AppDelegate.RemoteEdit(baseline: try #require(try c.stat(file)))
        c.close()
        try await Task.sleep(for: .milliseconds(1100))
        try Data("v2 from a deploy\n".utf8).write(to: URL(fileURLWithPath: file))
        try Data("mine\n".utf8).write(to: URL(fileURLWithPath: mine))
        let app = AppDelegate()
        app.panels = [PanelViewController(tabs: [d], index: 0, showHidden: false)]
        app.panels.forEach { $0.loadViewIfNeeded() }
        defer { app.panels.forEach { $0.shutdown() } }
        var asked = 0
        AppDelegate.answering = { _, _, _ in
            asked += 1
            if asked == 1 {   // while the question is up, the deploy writes again
                usleep(1_100_000)
                try? Data("v3, never seen\n".utf8).write(to: URL(fileURLWithPath: file))
                return 0   // Overwrite (v2)
            }
            return 2   // Cancel
        }
        defer { AppDelegate.answering = nil }
        #expect(await !app.upload(URL(fileURLWithPath: mine), to: file, on: .local(), state))
        #expect(asked == 2, "asked again about v3")
        #expect(FileManager.default.contents(atPath: file) == Data("v3, never seen\n".utf8))

        AppDelegate.answering = { _, _, _ in 0 }
        #expect(await app.upload(URL(fileURLWithPath: mine), to: file, on: .local(), state))   // v3 shown, then overwritten
        #expect(FileManager.default.contents(atPath: file) == Data("mine\n".utf8))
    }
}

extension ServerLockTests {   // swaps `AppDelegate.answering`
    /// S2-04: one server file saved from two places at once (its editor and its ↩ copy in another app, a revert
    /// meanwhile) — both were checked against the same version and the last rename won: the other text was gone. The
    /// second waits for the first, finds the file changed, and asks.
    @MainActor @Test func twoSavesOfOneServerFileDontBothWin() async throws {
        let d = tempDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        let file = d + "/app.conf"
        try Data("v0\n".utf8).write(to: URL(fileURLWithPath: file))
        try Data("from the editor\n".utf8).write(to: URL(fileURLWithPath: d + "/a"))
        try Data("from the other app\n".utf8).write(to: URL(fileURLWithPath: d + "/b"))
        let c = try SFTPClient(.local())
        let v0 = try #require(try c.stat(file))
        c.close()
        let app = AppDelegate()
        app.panels = [PanelViewController(tabs: [d], index: 0, showHidden: false)]
        app.panels.forEach { $0.loadViewIfNeeded() }
        defer { app.panels.forEach { $0.shutdown() } }
        var asked: [String] = []
        AppDelegate.answering = { m, _, _ in asked.append(m); return 2 }   // Cancel
        defer { AppDelegate.answering = nil }
        async let one = app.upload(URL(fileURLWithPath: d + "/a"), to: file, on: .local(), AppDelegate.RemoteEdit(baseline: v0))
        async let two = app.upload(URL(fileURLWithPath: d + "/b"), to: file, on: .local(), AppDelegate.RemoteEdit(baseline: v0))
        let (a, b) = await (one, two)
        #expect(a != b, "one wrote, one asked")
        #expect(asked.count == 1 && asked.first?.contains("changed on") == true, "\(asked)")
        #expect(FileManager.default.contents(atPath: file) == Data((a ? "from the editor\n" : "from the other app\n").utf8))
    }
}
