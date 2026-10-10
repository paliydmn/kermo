import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

@MainActor
private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r10-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
    return dir
}

@MainActor
private func waitUntil(_ done: () -> Bool) async {
    for _ in 0..<1000 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
}

/// A panel on `dir`, its tab then opened "on a server": this Mac's sftp-server at `remoteDir`.
@MainActor
private func onServer(_ dir: String, at remoteDir: String) async throws -> PanelViewController {
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    await waitUntil { panel.path == dir && !panel.statusText.isEmpty }
    panel.loadRemote(.local(), dir: remoteDir, select: nil)
    await waitUntil { panel.remote?.dir == remoteDir }
    try #require(panel.remote?.dir == remoteDir)
    return panel
}

// MARK: - §1: a local place from a server tab opens in a new tab

@MainActor @Test func localPlaceFromAServerTabOpensANewTab() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = try await onServer(dir, at: dir)
    defer { panel.shutdown() }
    panel.navigate(to: dir + "/sub")   // Favorites, ⌘P, Home… all come as a pushed navigation
    await waitUntil { panel.remote == nil }
    #expect(panel.path == dir + "/sub" && panel.tabPaths.count == 2 && panel.tabIndex == 1)
    let left = try #require(panel.remoteTabs.first)
    #expect(panel.remoteTabs.count == 1 && !left.isCurrent && left.dir == dir, "the server tab stays, behind the new one")
}

@MainActor @Test func missingLocalPlaceFromAServerTabLeavesItAlone() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = try await onServer(dir, at: dir)
    defer { panel.shutdown() }
    var gone: [String] = []
    panel.onGone = { gone.append($0) }
    panel.navigate(to: dir + "/nope")
    await waitUntil { panel.statusError }
    #expect(panel.tabPaths.count == 1 && panel.remote?.dir == dir, "no second copy of the server tab")
    #expect(gone == [dir + "/nope"])
}

// MARK: - §3: `..` at a server's root asks first

@MainActor @Test func upAtTheServerRootAsksBeforeDisconnecting() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let saved = PanelViewController.confirmLeaving
    defer { PanelViewController.confirmLeaving = saved }
    var asked: [String] = [], answer = false
    PanelViewController.confirmLeaving = { target, back, _ in asked.append("\(target.host) \(back)"); return answer }

    let panel = try await onServer(dir, at: "/usr")
    defer { panel.shutdown() }
    panel.goUp()   // /usr → /: still on the server, nothing asked
    await waitUntil { panel.remote?.dir == "/" }
    #expect(panel.remote?.dir == "/" && asked.isEmpty)

    panel.goUp()   // Cancel
    await waitUntil { !asked.isEmpty }
    try await Task.sleep(for: .milliseconds(100))
    #expect(asked == ["localhost \(dir)"] && panel.remote?.dir == "/" && panel.tabPaths.count == 1)

    answer = true
    panel.goUp()   // Disconnect
    await waitUntil { panel.remote == nil }
    #expect(asked.count == 2 && panel.remote == nil && panel.path == dir && panel.tabPaths.count == 1)
}

// MARK: - §4: what's gone and what's only out of reach

@Test func goneMeansNoSuchFileOnAMountedDisk() throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r10-gone-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir + "/locked/inside", withIntermediateDirectories: true)
    defer { chmod(dir + "/locked", 0o755); try? FileManager.default.removeItem(atPath: dir) }
    let fm = FileManager.default
    try fm.createSymbolicLink(atPath: dir + "/to-disk", withDestinationPath: "/Volumes/dfm-no-such-disk/projects")
    try fm.createSymbolicLink(atPath: dir + "/to-nothing", withDestinationPath: dir + "/nothing")

    #expect(!Frecency.isGone(dir))
    #expect(Frecency.isGone(dir + "/nope") && Frecency.isGone(dir + "/nope/deeper"))
    #expect(Frecency.isGone(dir + "/to-nothing"), "a link to a deleted folder on this disk")
    #expect(!Frecency.isGone("/Volumes/dfm-no-such-disk/projects"), "an unplugged disk keeps its places")
    #expect(!Frecency.isGone("/Volumes/dfm-no-such-disk"))
    #expect(!Frecency.isGone(dir + "/to-disk/app"), "also through a link")
    chmod(dir + "/locked", 0)
    #expect(!Frecency.isGone(dir + "/locked/inside"), "access denied isn't deleted")
}

@Test func forgettingAFolderForgetsWhatWasInside() {
    var f = Frecency()
    for p in ["/a/b", "/a/b/c", "/a/bc", "/x"] { f.visit(p) }
    f.remove(under: "/a/b")
    #expect(Set(f.entries.keys) == ["/a/bc", "/x"])
}

// MARK: - §5: errors in the status line

@MainActor @Test func statusLineErrorIsRedWithASignUntilTheNextStatus() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    panel.loadViewIfNeeded()
    defer { panel.shutdown() }
    await waitUntil { panel.listedItems.count == 1 }
    panel.navigate(to: dir + "/nope")
    await waitUntil { panel.statusError }
    #expect(panel.statusError && panel.statusText == "\(dir)/nope: The operation couldn’t be completed. No such file or directory")
    panel.flash("★ Bookmarked")
    #expect(!panel.statusError)
}

// MARK: - §2: SSH / SFTP look like buttons

@MainActor @Test func serverActionsArePills() throws {
    let t = SFTPTarget(host: "root@web")
    let row = ServerRow(target: t, title: "web", sessions: [ServerSession(id: UUID(), kind: .sftp, target: t, dir: "/")])
    let view = try #require(SidebarController().outlineView(NSOutlineView(), viewFor: nil, item: SidebarController.Node(place: .server(row))) as? NSStackView)
    let buttons = view.arrangedSubviews.compactMap { $0 as? PillButton }
    #expect(buttons.map(\.title) == ["SSH", "SFTP"])
    let plain = NSButton(title: "SFTP", target: nil, action: nil)
    plain.isBordered = false
    plain.font = buttons[1].font
    #expect(buttons[1].intrinsicContentSize.width == plain.intrinsicContentSize.width + 8, "a few pt wider, no bezel")
}

// MARK: - I10: systemctl in the F2 menu, on a server panel only

@MainActor @Test func serviceCommandsShowOnServerPanelsOnly() {
    typealias C = AppDelegate.UserCommand
    let all = [C(title: "Disk usage", command: "du -sh %S"), C(title: "Service status", command: "systemctl status %f", server: true),
               C(title: "Quarantine", command: "xattr -dr com.apple.quarantine %S", server: false)]
    #expect(AppDelegate.userCommands(all, onServer: true).map(\.title)
            == ["Disk usage", "Service status", "Restart service", "Failed services", "Service log (last 200 lines)"],
            "the built-in ones the file lacks follow (task 11, N14)")
    #expect(AppDelegate.userCommands(all, onServer: false).map(\.title) == ["Disk usage", "Quarantine"])
    let restart = ShellContext(dir: "/etc/systemd/system", otherDir: nil, cursor: "nginx.service", targets: [])
        .expand("sudo systemctl restart %f && systemctl status --no-pager %f")!
    #expect(restart == "sudo systemctl restart nginx.service && systemctl status --no-pager nginx.service")
    #expect(Shell.isDangerous(restart), "a production server asks first (R1)")
}
