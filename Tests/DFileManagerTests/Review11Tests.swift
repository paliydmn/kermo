import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 11 review.

@MainActor private func names(_ p: PanelViewController) -> [String] { (0..<p.table.numberOfRows).compactMap { p.item(at: $0)?.name } }
private func file(_ name: String) -> FileItem { FileItem(name: name, kind: .file, size: 1, mtime: 0, mode: 0o644, flags: 0) }

/// H2: each batch of hits re-sorted all of them on the main thread — 100 000 hits took a minute at 100 % CPU.
/// Hits now go to the end as found and are sorted once, when the search ends; the footer says what was searched.
@MainActor @Test func searchHitsAreSortedOnceWhenTheSearchEnds() {
    let panel = PanelViewController(tabs: [NSTemporaryDirectory()], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let flag = panel.beginSearch("*.txt containing “needle”", in: "/x")
    panel.addSearchResults([file("b"), file("c")], from: flag)
    panel.addSearchResults([file("a")], from: flag)
    #expect(names(panel) == ["b", "c", "a"])
    #expect(panel.statusText.hasPrefix("🔍 *.txt containing “needle”: searching… 3 found · "), "\(panel.statusText)")
    panel.finishSearch(flag)
    #expect(names(panel) == ["a", "b", "c"])
    #expect(panel.statusText.hasPrefix("🔍 *.txt containing “needle”: 3 found · ⌫ back · "), "\(panel.statusText)")
}

/// By the clock: in the full suite the main actor is so busy at first that 500 sleeps of 10 ms took over 10 s.
@MainActor private func waitUntil(_ done: () -> Bool) async {
    let end = Date().addingTimeInterval(20)
    while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
}
private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r11-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
@MainActor private func pathCommand(_ panel: PanelViewController, _ tv: NSTextView, _ sel: Selector) {
    _ = panel.control(NSTextField(), textView: tv, doCommandBy: sel)   // any control but the filter field is the path field
}

/// A4: ↩ on a link to a folder, ⌘L ↩ and ⌘L ⇥ look at the disk off the main thread (a link into a share that stopped
/// answering hung the app). What they find still applies — unless the panel went elsewhere meanwhile.
@MainActor @Test func linksAndTypedPathsAreLookedAtOffTheMainThread() async throws {
    let dir = tempDir(), parent = (dir as NSString).deletingLastPathComponent
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: dir + "/real/sub", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir + "/real/f.txt", contents: Data())
    try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: "real")
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.table.numberOfRows == 3 }

    panel.moveCursor(toName: "link")
    panel.openCursor(intoPackage: false)
    panel.reload()   // a re-list meanwhile doesn't drop the ↩
    await waitUntil { panel.path == dir + "/link" }
    #expect(panel.path == dir + "/link")

    panel.goUp()
    await waitUntil { panel.path == dir && panel.table.numberOfRows == 3 }
    panel.moveCursor(toName: "link")
    panel.openCursor(intoPackage: false)
    panel.goUp()   // before the link was looked at: the panel goes up, and stays there
    await waitUntil { panel.path == parent }
    try await Task.sleep(for: .milliseconds(300))
    #expect(panel.path == parent)

    let field = NSTextView()
    field.string = dir + "/real/f.txt"
    pathCommand(panel, field, #selector(NSResponder.insertNewline(_:)))
    await waitUntil { panel.path == dir + "/real" && panel.selectedItems.first?.name == "f.txt" }
    #expect(panel.path == dir + "/real" && panel.selectedItems.first?.name == "f.txt", "a file: its folder, the cursor on it")

    field.string = dir + "/re"
    pathCommand(panel, field, #selector(NSResponder.insertTab(_:)))
    await waitUntil { field.string != dir + "/re" }
    #expect(field.string == dir + "/real/")
}

/// N10: ⌘P on a folder of a disk that isn't connected did nothing (and checked on the main thread). Now it says why.
@Test func jumpSaysWhyAFolderIsntThere() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/f", contents: Data())
    #expect(AppDelegate.whyNotThere(dir) == nil)
    #expect(AppDelegate.whyNotThere("/Volumes/dfm-unplugged/sub")?.message == "“dfm-unplugged” isn't connected")
    #expect(AppDelegate.whyNotThere("/Volumes/dfm-unplugged/sub")?.gone == false, "its places stay for when it's back")
    #expect(AppDelegate.whyNotThere(dir + "/f")?.message == "Not a folder: " + (dir as NSString).abbreviatingWithTildeInPath + "/f")
    let missing = try #require(AppDelegate.whyNotThere(dir + "/nope"))
    #expect(missing.message == "No such folder: " + (dir as NSString).abbreviatingWithTildeInPath + "/nope" && missing.gone)
}

/// A7: ⌃G looked for the repo on the main thread (and ⌃D ran `git config` there, up to 30 s). Off it now; the
/// answers stay the same.
@MainActor @Test func gitChangesLookForTheRepoOffTheMainThread() async throws {
    let plain = tempDir(), repo = tempDir()
    defer { for d in [plain, repo] { try? FileManager.default.removeItem(atPath: d) } }
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = ["init", "-q", repo]
    try git.run()
    git.waitUntilExit()
    FileManager.default.createFile(atPath: repo + "/new.txt", contents: Data("x".utf8))

    let panel = PanelViewController(tabs: [plain], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.path == plain && !panel.statusText.isEmpty }
    var said = false
    for _ in 0..<5 where !said {   // the listing's own git status landing just then redraws the line over the message
        panel.showGitChanges()
        for _ in 0..<100 where !said {
            said = panel.statusText == "Not a git work tree"
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    #expect(said && panel.searchTitle == nil)

    panel.navigate(to: repo)
    await waitUntil { panel.path == repo }
    panel.showGitChanges()
    panel.reload()   // the folder changed meanwhile: a re-list, not the user going elsewhere
    await waitUntil { panel.searchTitle != nil && panel.statusText.contains("found · ⌫ back") }
    #expect(panel.searchTitle != nil && names(panel) == ["new.txt"], "\(panel.statusText)")
}

/// A2: ⌘I read lstat, xattrs, the ACL and a link's target on the main thread, and again after each line filled in
/// later (size, hash). It's one read off the main thread now; the lines are the same.
@Test func infoIsReadAsOneSnapshot() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/f", contents: Data("abc".utf8))
    chmod(dir + "/f", 0o640)
    try FileManager.default.createSymbolicLink(atPath: dir + "/l", withDestinationPath: "f")
    let f = InfoWindow.snapshot(dir + "/f")
    #expect(f.ok && !f.isDir && f.mode == "640" && f.lines.first == "Path:       \(dir)/f")
    #expect(f.lines.contains { $0.hasPrefix("Size:       3 bytes") })
    #expect(InfoWindow.snapshot(dir + "/l").lines.contains { $0.hasPrefix("Kind:       Symbolic link → f") })
    #expect(InfoWindow.snapshot(dir).isDir)
    let gone = InfoWindow.snapshot(dir + "/nope")
    #expect(!gone.ok && gone.lines.last == "No such file or directory")
}

/// A3: validating a drop asked each path's volume on the main thread at every mouse move — over a share that stopped
/// answering, the drag hung. Asked once per drag off the main thread now; a copy until the answer is in.
@MainActor @Test func dragAsksVolumesOncePerDragOffTheMainThread() async {
    let a = Foundation.NSTemporaryDirectory(), b = NSHomeDirectory()   // one volume, wherever $DFM_TEST_TMP is
    #expect(!DragVolumes.same(a, b, drag: 7001), "not known yet: copy")
    await waitUntil { DragVolumes.same(a, b, drag: 7001) }
    #expect(DragVolumes.same(a, b, drag: 7001))
    #expect(!DragVolumes.same(a, b, drag: 7002), "another drag asks again")
}

/// A8: ⌃1…⌃7 wrote tags on the main thread and stopped at the first file that refused, without saying how many
/// were left; the rest were never tagged. Off the main thread now, through to the end, with a count.
@Test func tagsGoOnPastAFileThatRefuses() throws {
    let d = tempDir()
    defer { chflags(d + "/a-locked", 0); try? FileManager.default.removeItem(atPath: d) }
    for n in ["a-locked", "b"] { FileManager.default.createFile(atPath: d + "/" + n, contents: nil) }
    chflags(d + "/a-locked", UInt32(UF_IMMUTABLE))
    let urls = [d + "/a-locked", d + "/b"].map { URL(fileURLWithPath: $0) }
    let red = FinderTags.Tag(name: "Red", color: 6)
    let failed = AppDelegate.setTags(urls) { tags, first in first.contains(red) ? tags.filter { $0 != red } : tags + [red] }
    #expect(failed.count == 1 && failed[0].hasPrefix("“a-locked”: "), "\(failed)")
    #expect(FinderTags.read(d + "/b") == [red], "the next file still gets it")
}

/// A1: ⌘S wrote, fsynced, renamed and read the file back for its hash on the main thread — on a share that stopped
/// answering, the app hung. The disk work runs off it now; the text can't change meanwhile.
@MainActor @Test func savingWritesOffTheMainThread() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try Data("old\n".utf8).write(to: URL(fileURLWithPath: d + "/a.conf"))
    link(d + "/a.conf", d + "/b.conf")   // hard-linked: rewritten in place, through the hook below
    let e = try Editor(URL(fileURLWithPath: d + "/a.conf"))
    e.textView.string = "new\n"
    nonisolated(unsafe) var onMain: Bool?, editable: Bool?
    let tv = e.textView
    e.willRewriteInPlace = { _ in
        onMain = Thread.isMainThread
        let read = { MainActor.assumeIsolated { tv.isEditable } }
        editable = Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }
    #expect(await e.save())
    #expect(onMain == false && editable == false)
    #expect(e.textView.isEditable)
    #expect(try String(contentsOfFile: d + "/b.conf", encoding: .utf8) == "new\n")
}

/// N20: every F5/F6/F8/Sync job stayed in memory with its sources, results and errors: `onFinish` held the job and
/// the job held `onFinish`. A finished job, and a queued one cancelled before it ran, go now.
@MainActor @Test func finishedJobsAreLetGo() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    FileManager.default.createFile(atPath: d + "/a", contents: Data("x".utf8))
    let ops = OpsController(window: NSWindow()) { _ in }
    weak var done: FileJob?
    do {
        let job = FileJob(.copy, sources: [d + "/a"], destDir: d + "/out")
        try FileManager.default.createDirectory(atPath: d + "/out", withIntermediateDirectories: true)
        done = job
        ops.enqueue(job, title: "Copy")
    }
    await waitUntil { ops.pending == 0 }
    #expect(FileManager.default.fileExists(atPath: d + "/out/a"))
    await waitUntil { done == nil }
    #expect(done == nil, "a finished job is let go")
}

/// A10: the output window (⌘E, F2) kept all a command printed, and hopped to the main thread for each read — a
/// `tail -f` left for a day grew without end. It keeps the last 4 MB now and takes reads in batches.
@MainActor @Test func outputWindowKeepsTheLastFewMegabytes() async throws {
    _ = NSApplication.shared
    let tag = "dfm-a10-" + UUID().uuidString.prefix(8)
    var status: Int32?
    Shell.run("echo \(tag) >/dev/null; head -c 6000000 /dev/zero | tr '\\0' x | fold -w 99; echo END", in: NSTemporaryDirectory()) { status = $0 }
    for _ in 0..<6000 where status == nil { try await Task.sleep(for: .milliseconds(10)) }
    let w = try #require(NSApp.windows.first { $0.title.contains(tag) })
    defer { w.close() }
    let text = try #require((w.contentView as? NSScrollView)?.documentView as? NSTextView).string
    #expect(status == 0 && text.hasSuffix("xEND\n"), "\(String(describing: status)) \(text.suffix(80).debugDescription)")
    #expect(text.utf16.count <= 4 << 20, "\(text.utf16.count)")
    #expect(w.subtitle.contains("only the last 4 MB kept"), "\(w.subtitle)")
}

/// N11: follow on a server went on saying FOLLOWING after its `tail -F` there ended (a dropped connection, sshd
/// restarted, the process killed). Now it says it stopped and f picks it up again.
@MainActor @Test func serverFollowSaysWhenItStops() async throws {
    _ = NSApplication.shared
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let url = URL(fileURLWithPath: d + "/app.log")
    try Data("line\n".utf8).write(to: url)
    let v = Viewer(url, remote: (SFTPTarget(host: "dfm-no-such-host.invalid"), "/var/log/app.log", 0))
    defer { v.close() }
    for _ in 0..<500 where v.window?.subtitle.hasPrefix("Loading") == true { try await Task.sleep(for: .milliseconds(10)) }
    v.setFollow(true)
    await waitUntil { v.window?.subtitle.contains("FOLLOW STOPPED · f to resume") == true }   // ssh can't even resolve it
    #expect(v.window?.subtitle.contains("FOLLOW STOPPED · f to resume") == true, "\(v.window?.subtitle ?? "")")
    #expect(v.window?.subtitle.contains("FOLLOWING") == false)
}

/// N8: a panel in a folder of a disk that went away kept its rows: it went up one level, and that was gone too.
/// It goes up to the nearest folder still there (/Volumes for an unplugged disk).
@MainActor @Test func panelInAGoneFolderGoesUpToOneThatIsThere() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d + "/disk/sub", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: d + "/disk/sub/r300.bin", contents: Data())
    let panel = PanelViewController(tabs: [d + "/disk/sub"], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.path == d + "/disk/sub" && panel.table.numberOfRows == 2 }
    try FileManager.default.removeItem(atPath: d + "/disk")   // the disk and the folder above with it
    panel.reload()
    await waitUntil { panel.path == d }
    #expect(panel.path == d && names(panel).isEmpty, "\(panel.path)")
}

/// N4: on a server panel a symlink's row says where it points, as on this Mac (tooltip; beside the name if it fits).
@MainActor @Test func serverLinksShowTheirTarget() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d + "/usr/bin", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: d + "/bin", withDestinationPath: "usr/bin")
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    panel.loadRemote(.local(), dir: d, select: nil)
    await waitUntil { panel.remote?.dir == d && names(panel).contains("bin") }
    let row = try #require((0..<panel.table.numberOfRows).first { panel.item(at: $0)?.name == "bin" })
    let cell = panel.tableView(panel.table, viewFor: panel.table.tableColumn(withIdentifier: .init("name")), row: row) as? NSTableCellView
    #expect(cell?.toolTip == "→ usr/bin")
}

/// N16: ⌘L ⇥ on a server tab completed from this Mac's folders (/Libr → /Library/, which isn't on the server).
/// It lists the server's folder now.
@MainActor @Test func pathCompletionOnAServerTabListsTheServer() async throws {
    let mac = tempDir(), server = tempDir()
    defer { for d in [mac, server] { try? FileManager.default.removeItem(atPath: d) } }
    try FileManager.default.createDirectory(atPath: mac + "/localonly", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: server + "/srvonly", withIntermediateDirectories: true)
    let panel = PanelViewController(tabs: [mac], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.path == mac }
    panel.loadRemote(.local(), dir: server, select: nil)
    await waitUntil { panel.remote?.dir == server }
    let field = NSTextView()
    field.string = "s"
    pathCommand(panel, field, #selector(NSResponder.insertTab(_:)))
    await waitUntil { field.string != "s" }
    #expect(field.string == "srvonly/")
    field.string = server + "/sr"
    pathCommand(panel, field, #selector(NSResponder.insertTab(_:)))
    await waitUntil { field.string != server + "/sr" }
    #expect(field.string == server + "/srvonly/")
}

/// N12: F3 on a big server log shows its last 4 MB, and & filtered just those — said only by "last 4 MB of 15 MB"
/// at the start of a long title. The filter itself says so now.
@MainActor @Test func filterOnAServerLogsTailSaysItsReach() async throws {
    _ = NSApplication.shared
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let url = URL(fileURLWithPath: d + "/lines.log")
    try Data("a 77777\nb\n".utf8).write(to: url)
    let v = Viewer(url, remote: (SFTPTarget(host: "dfm-no-such-host.invalid"), "/var/log/lines.log", 10_700_000))   // no grep there
    defer { v.close() }
    for _ in 0..<500 where v.window?.subtitle.hasPrefix("Loading") == true { try await Task.sleep(for: .milliseconds(10)) }
    v.setLineFilter(LineFilter("77777"))
    let fmt = ByteCountFormatter.string(fromByteCount: 10, countStyle: .file)
    await waitUntil { v.window?.subtitle.contains("LINES WITH “77777”") == true }
    #expect(v.window?.subtitle.contains("LINES WITH “77777” IN THE LAST \(fmt) ONLY") == true, "\(v.window?.subtitle ?? "")")
}

/// N4 (decided): on this Mac too, a link to a folder sorts with the folders and reads <DIR> once its target is known.
@MainActor @Test func localLinksToFoldersSortWithFolders() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d + "/zdir", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: d + "/a.txt", contents: Data())
    try FileManager.default.createSymbolicLink(atPath: d + "/bin", withDestinationPath: "zdir")
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { names(panel) == ["bin", "zdir", "a.txt"] }
    #expect(names(panel) == ["bin", "zdir", "a.txt"])
    #expect(PanelViewController.sizeText(try #require(panel.item(at: 1)), measured: nil) == "<DIR>")
}

/// N12 (decided): & on a big server log's tail runs grep -F there, over the whole log — not only the 4 MB fetched.
@MainActor @Test func filterOnAServerLogGrepsItThere() async throws {
    _ = NSApplication.shared
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let log = d + "/server.log", copy = URL(fileURLWithPath: d + "/tail.log")
    try Data("early 77777\nmiddle\nlate 77777\nend\n".utf8).write(to: URL(fileURLWithPath: log))
    try Data("late 77777\nend\n".utf8).write(to: copy)   // what F3 fetched: the tail
    let v = Viewer(copy, remote: (.local(), log, 19))   // .local(): the command runs here, as a server's would
    defer { v.close() }
    let tv = try #require(v.scroll.documentView as? NSTextView)
    await waitUntil { tv.string.hasPrefix("late") }
    v.setLineFilter(LineFilter("77777"))
    await waitUntil { tv.string.hasPrefix("early") }
    #expect(tv.string == "early 77777\nlate 77777\n")
    #expect(v.window?.subtitle.contains("LINES WITH “77777” IN THE WHOLE FILE (grep on the server)") == true, "\(v.window?.subtitle ?? "")")
    v.setLineFilter(LineFilter("!77777"))
    await waitUntil { tv.string.hasPrefix("middle") }
    #expect(tv.string == "middle\nend\n")
}

/// N3: "1 items" in the footer; N15: an SFTP panel's footer said "2 marked" twice.
@MainActor @Test func footerCountsReadRight() async throws {
    #expect(PanelViewController.countText(1, "items", 0) == "1 item")
    #expect(PanelViewController.countText(1, "items", 1536).hasPrefix("1 item, "))
    #expect(PanelViewController.countText(1, "marked", 0) == "1 marked")
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for n in ["a", "b", "c"] { FileManager.default.createFile(atPath: d + "/" + n, contents: Data()) }
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    panel.loadRemote(.local(), dir: d, select: nil)
    await waitUntil { panel.remote?.dir == d && names(panel).count == 3 }
    panel.markAll()
    #expect(panel.statusText.components(separatedBy: "marked").count == 2, "\(panel.statusText)")
    #expect(panel.statusText.contains("3 items"))
}

/// N13 (decided): "… changed on web1 since you opened it" had Overwrite on ↩, so the habitual ⌘S ↩ wrote over
/// someone's changes. ↩ is Cancel there now (and on this Mac's "changed on disk"); Overwrite takes a click.
@MainActor @Test func overwriteIsNotTheDefaultAnswer() {
    let a = AppDelegate.alert("x changed", info: "", ["Overwrite", "Reload", "Cancel"], default: 2)
    #expect(a.buttons.map(\.keyEquivalent) == ["", "", "\r"])
    let plain = AppDelegate.alert("q", info: "", ["Save", "Cancel"])
    #expect(plain.buttons.map(\.keyEquivalent) == ["\r", "\u{1b}"], "others as before")
}

/// N14 (decided): an existing usermenu.json never got the systemctl / journalctl entries (I10), and a server panel
/// offered Mac commands (xattr, top -o mem). There the built-in server entries come after the user's own (unless the
/// file has them), and an entry without "server" that calls a Mac-only tool isn't offered.
@MainActor @Test func serverUserMenuHasServiceEntriesAndNoMacOnes() {
    typealias C = AppDelegate.UserCommand
    let old = [C(title: "Disk usage", command: "du -sh %S"), C(title: "Remove quarantine", command: "xattr -dr com.apple.quarantine %S"),
               C(title: "top by memory", command: "top -o mem", terminal: true), C(title: "Reveal", command: "open -R %F"),
               C(title: "Mine", command: "systemctl --failed --no-pager", server: true)]
    let onServer = AppDelegate.userCommands(old, onServer: true)
    #expect(onServer.map(\.title) == ["Disk usage", "Mine", "Service status", "Restart service", "Service log (last 200 lines)"])
    #expect(AppDelegate.userCommands(old, onServer: false).map(\.title) == ["Disk usage", "Remove quarantine", "top by memory", "Reveal"])
    #expect(!AppDelegate.macOnly("openssl x509 -in %f -noout -text") && AppDelegate.macOnly("cat %f | pbcopy"))
}

/// N7: an empty FAT32 or exFAT stick read "Zero KB free": the "important usage" figure is 0 there (fskit), the
/// plain one is right. That one is taken when the first says nothing.
@Test func freeSpaceFallsBackWhereImportantUsageIsZero() {
    let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    #expect(PanelViewController.freeText(important: 0, available: 628_000_000) == fmt(628_000_000))
    #expect(PanelViewController.freeText(important: nil, available: 628_000_000) == fmt(628_000_000))
    #expect(PanelViewController.freeText(important: 5_000_000_000, available: 4_000_000_000) == fmt(5_000_000_000), "APFS: purgeable counts")
    #expect(PanelViewController.freeText(important: nil, available: nil) == "?")
}

/// N18: after ⌘⇧P ▸ Theme… no row had the cursor (↩, F3, ⌃L did nothing until an arrow put it on ".."). N19: ↩ in
/// the quick filter left the cursor on "..", not on the first match (as MC and TC do).
@MainActor @Test func themeAndQuickFilterKeepTheCursorOnAFile() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for n in ["README.md", "a.txt", "bin.usr-is-merged"] { FileManager.default.createFile(atPath: d + "/" + n, contents: Data()) }
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { names(panel).count == 3 }
    panel.moveCursor(toName: "bin.usr-is-merged")
    panel.applyTheme()
    #expect(panel.selectedItems.map(\.name) == ["bin.usr-is-merged"])

    panel.moveCursor(to: 0)   // ".."
    panel.applyFilter("README")
    panel.confirmFilter()
    #expect(panel.selectedItems.map(\.name) == ["README.md"])
}

/// N5: the output window of an extract on a server was titled with the raw command line
/// (mkdir -p -- … && if tar --version …); it says what it does.
@MainActor @Test func outputWindowCanSayWhatItDoes() async throws {
    _ = NSApplication.shared
    var done = false
    let title = "Extract “a.tar.gz” → out " + UUID().uuidString.prefix(6)
    Shell.run("true", in: NSTemporaryDirectory(), title: title) { _ in done = true }
    for _ in 0..<500 where !done { try await Task.sleep(for: .milliseconds(10)) }
    let w = try #require(NSApp.windows.first { $0.title == title })
    w.close()
}

/// N17: the Midnight Commander theme drew the sidebar's headers and the key bar's F1…F10 dark blue on blue, and the
/// footer and command line light: pure blue's HSB brightness (0.67) passed for a light background, so the chrome got
/// the light appearance. Luminance decides now.
@MainActor @Test func blueThemesGetDarkChrome() {
    func theme(_ name: String) -> Theme { Theme.all.first { $0.name == name }! }
    #expect(theme("Midnight Commander").appearance?.name == .darkAqua)
    #expect(theme("Far Manager").appearance?.name == .darkAqua)
    #expect(theme("Solarized Light").appearance?.name == .aqua && theme("GitHub Light").appearance?.name == .aqua)
    #expect(theme("System").appearance == nil)
}

/// A16: a custom diffCommand had %1 filled in before %2, so a first path holding "%2" got the second path pasted
/// inside its quotes — unquoted, a command injection. Both are filled in one pass now.
@Test func diffCommandFillsBothPathsInOnePass() {
    let a = ShellContext.quote("/x/odd%2name"), b = ShellContext.quote("/y/$(touch PWNED)")
    #expect(AppDelegate.fillDiff("code --diff %1 %2", a, b) == "code --diff \(a) \(b)")
}

/// A14: with a panel on a server, ⌘U moved the other into the local folder hidden behind the server tab, ⌘⇧D
/// compared with a same-named file there, and ⌘I in an archive opened Info (chmod, chown) of the archive's folder.
@MainActor @Test func serverAndArchivePanelsDontActOnTheFolderBehindThem() async throws {
    let mac = tempDir(), server = tempDir()
    defer { for d in [mac, server] { try? FileManager.default.removeItem(atPath: d) } }
    let local = PanelViewController(tabs: [mac], index: 0, showHidden: false), remote = PanelViewController(tabs: [mac], index: 0, showHidden: false)
    for p in [local, remote] { p.loadViewIfNeeded() }
    defer { local.shutdown(); remote.shutdown() }
    remote.loadRemote(.local(), dir: server, select: nil)
    await waitUntil { local.path == mac && remote.remote?.dir == server }
    #expect(local.plainFolder == mac && remote.plainFolder == nil, "⌘⇧D: no same-named file behind a server tab")
    #expect(remote.infoURL == nil && local.infoURL?.path == mac)

    #expect(AppDelegate.swap(local, remote))   // ⌘U: the server folder and the local one change places
    await waitUntil { local.remote?.dir == server && remote.path == mac && remote.remote == nil }
    #expect(local.remote?.dir == server && remote.remote == nil && remote.path == mac)
}

/// ↩ on an archive while its folder changed (the watcher re-lists) was dropped: the re-list counted as going
/// elsewhere. Found by escapeRestoresTheSearchAndArchiveHeaders under load.
@MainActor @Test func archiveOpensThoughTheFolderChanges() async throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    FileManager.default.createFile(atPath: d + "/f", contents: Data("x".utf8))
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["cf", d + "/a.tar", "-C", d, "f"]
    try tar.run()
    tar.waitUntilExit()
    let panel = PanelViewController(tabs: [d], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { names(panel).count == 2 }
    panel.enterArchive(d + "/a.tar")
    panel.reload()   // the folder changed meanwhile
    await waitUntil { panel.archive != nil }
    try await Task.sleep(for: .milliseconds(200))
    #expect(panel.archive != nil && names(panel) == ["f"])
}

/// A18: F3, F4 or a hash on a FIFO opened it for reading and waited for a writer for good; Compare by contents took
/// two files that couldn't be read for equal; a volume's blocks × block size could overflow and trap.
@MainActor @Test func oddFilesAndFiguresAreHandled() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    mkfifo(d + "/fifo", 0o644)
    let (text, _, _, _) = Viewer.read(URL(fileURLWithPath: d + "/fifo"), .text)
    #expect(text == "“fifo” is a FIFO — nothing to show")
    #expect(throws: (any Error).self) { try Editor(URL(fileURLWithPath: d + "/fifo")) }
    FileManager.default.createFile(atPath: d + "/a", contents: Data("x".utf8))
    chmod(d + "/a", 0)
    defer { chmod(d + "/a", 0o644) }
    if getuid() != 0 { #expect(!DirSync.filesEqual(d + "/a", d + "/a"), "unreadable isn't equal") }
    #expect(SidebarModel.bytes(.max, 4096) == .max && SidebarModel.bytes(10, 4096) == 40960)
}

/// Code review: busy's ⎋ waited for the work to return — a check stuck on a share that stopped answering (F5's
/// destination, ⌃D's git config) kept "… ⎋ cancels" up for good. It's back at once now.
@MainActor @Test func busyReturnsOnEscapeThoughTheWorkIsStuck() async throws {
    let panel = PanelViewController(tabs: [NSTemporaryDirectory()], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    let stuck = DispatchSemaphore(value: 0)
    defer { stuck.signal() }   // lets the work go at the end
    Task { panel.cancelBusy() }   // ⎋, once busy is waiting
    let r = await panel.busy("Checking…") { _ in stuck.wait(); return 1 }   // deaf to ⎋ until the end, as a stuck stat
    guard case .failure(let e) = r else { Issue.record("expected cancellation"); return }   // back before the work: by ⎋
    #expect(e is CancellationError)
}

/// Code review: with FOLLOW STOPPED shown, f could only start follow again, never turn it off (a tail that ends at
/// once put it back). A stop now turns follow off and says so; f is the plain toggle again.
@MainActor @Test func stoppedFollowIsOffAndFTogglesIt() async throws {
    _ = NSApplication.shared
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let url = URL(fileURLWithPath: d + "/app.log")
    try Data("line\n".utf8).write(to: url)
    let v = Viewer(url, remote: (SFTPTarget(host: "dfm-no-such-host.invalid"), "/var/log/app.log", 0))
    defer { v.close() }
    for _ in 0..<500 where v.window?.subtitle.hasPrefix("Loading") == true { try await Task.sleep(for: .milliseconds(10)) }
    v.setFollow(true)
    await waitUntil { v.window?.subtitle.contains("FOLLOW STOPPED") == true }
    #expect(v.window?.subtitle.contains("FOLLOW STOPPED · f to resume") == true && v.window?.subtitle.contains("FOLLOWING") == false)
    v.setFollow(true)   // f: on again (and, the server still out of reach, stopped again)
    #expect(v.window?.subtitle.contains("FOLLOWING") == true)
    await waitUntil { v.window?.subtitle.contains("FOLLOW STOPPED") == true }
    v.setFollow(false)  // f while on: off, no note
    #expect(v.window?.subtitle.contains("FOLLOW") == false)
}

/// View ▸ Theme…: the picker opens on the theme in use, shows each highlighted one at once, and ⎋ goes back (↩ keeps it).
@MainActor @Test func pickerPreviewsTheHighlightedRow() async {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    var log: [String] = []
    func show() {
        Picker.show(over: window, placeholder: "", items: ["a", "b", "c"].map { n in
            Picker.Item(title: n, preview: { log.append(n) }) { log.append("run " + n) }
        }, selected: 1) { log.append("back") }
    }
    func press(_ sel: Selector) { _ = Picker.current!.control(NSTextField(), textView: NSTextView(), doCommandBy: sel) }

    show()
    #expect(log.last == "b", "opens on the one in use")
    press(#selector(NSResponder.moveDown(_:)))
    press(#selector(NSResponder.cancelOperation(_:)))
    #expect(log.suffix(2) == ["c", "back"])

    log = []
    show()
    press(#selector(NSResponder.moveUp(_:)))
    press(#selector(NSResponder.insertNewline(_:)))
    for _ in 0..<50 where log.last != "run a" { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(log.last == "run a" && !log.contains("back"))
}
