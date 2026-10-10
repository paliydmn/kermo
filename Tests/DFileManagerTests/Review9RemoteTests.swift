import AppKit
import Testing
@testable import DFMCore
@testable import DFileManager

private func tempRoot() throws -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r8-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// R8: at launch, server and archive copies older than a day go; fresh ones and anything else stay.
@Test func launchSweepRemovesDayOldTempCopies() throws {
    let fm = FileManager.default
    let root = try tempRoot()
    defer { TempCopies.remove(root) }   // read-only folders inside
    let old = Date(timeIntervalSinceNow: -2 * 86_400)
    for name in ["dfm-sftp-old", "dfm-archive-old", "dfm-sftp-new", "dfm-ssh-old", "other-old", "dfm-sftp-kept-old"] {
        try fm.createDirectory(atPath: root + "/\(name)/sub", withIntermediateDirectories: true)
        try Data("server config\n".utf8).write(to: URL(fileURLWithPath: root + "/\(name)/sub/sshd_config"))
        if name.hasPrefix("dfm-archive") { chmod(root + "/\(name)/sub", 0o555) }   // archives bring read-only folders
        if name.contains("kept") { TempCopies.keep(root + "/" + name) }   // text that didn't reach its server
        if name.hasSuffix("old") { try fm.setAttributes([.modificationDate: old], ofItemAtPath: root + "/" + name) }
    }
    // A link named like a copy: the link goes, never what it points to.
    let outside = root + "/other-old/sub/sshd_config"
    try fm.createSymbolicLink(atPath: root + "/dfm-sftp-link", withDestinationPath: root + "/other-old")
    var t = [timeval(tv_sec: Int(old.timeIntervalSince1970), tv_usec: 0), timeval(tv_sec: Int(old.timeIntervalSince1970), tv_usec: 0)]
    lutimes(root + "/dfm-sftp-link", &t)

    TempCopies.sweep(in: root)
    #expect(try fm.contentsOfDirectory(atPath: root).sorted() == ["dfm-sftp-kept-old", "dfm-sftp-new", "dfm-ssh-old", "other-old"])
    #expect(fm.fileExists(atPath: outside))
}

/// R8: closing the editor of a server file removes its local copy only after the last upload finished, and keeps it
/// when that upload failed (the copy is then the only one of the text).
@MainActor @Test func editorCopyGoesAfterTheLastUploadOnly() async throws {
    let fm = FileManager.default
    let root = try tempRoot()
    defer { try? fm.removeItem(atPath: root) }
    func copy(_ name: String) throws -> String {
        try fm.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: URL(fileURLWithPath: root + "/\(name)/f.conf"))
        return root + "/" + name
    }
    let attrs = SFTPClient.Attrs(kind: .file, size: 2, mtime: 0, mode: nil)

    let never = try copy("never-saved"), state0 = AppDelegate.RemoteEdit(baseline: attrs)
    await state0.closed(removing: never).value
    #expect(!fm.fileExists(atPath: never))

    let slow = try copy("uploading"), state1 = AppDelegate.RemoteEdit(baseline: attrs)
    let gate = AsyncStream<Void>.makeStream()
    state1.upload = Task { for await _ in gate.stream {}; return true }
    let removal = state1.closed(removing: slow)
    try await Task.sleep(for: .milliseconds(100))
    #expect(fm.fileExists(atPath: slow), "never while the upload runs")
    gate.continuation.finish()
    await removal.value
    #expect(!fm.fileExists(atPath: slow))

    let failed = try copy("failed"), state2 = AppDelegate.RemoteEdit(baseline: attrs)
    state2.upload = Task { false }
    await state2.closed(removing: failed).value
    #expect(fm.fileExists(atPath: failed))
    #expect(fm.fileExists(atPath: failed + "/" + TempCopies.keptMarker), "marked kept: the launch sweep leaves it")
}

/// R8: a save's copy is marked kept while its upload runs (quitting then leaves it to the launch sweep otherwise),
/// and unmarked once the last save is on the server; a failed one stays marked.
@MainActor @Test func copyIsKeptWhileItsUploadRuns() async throws {
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let marker = root + "/" + TempCopies.keptMarker
    let state = AppDelegate.RemoteEdit(baseline: SFTPClient.Attrs(kind: .file, size: 2, mtime: 0, mode: nil))
    let before = AppDelegate.RemoteEdit.uploading

    let first = AsyncStream<Void>.makeStream(), second = AsyncStream<Void>.makeStream()
    state.save(in: root) { for await _ in first.stream {}; return true }
    #expect(FileManager.default.fileExists(atPath: marker), "kept from the moment the upload starts")
    state.save(in: root) { for await _ in second.stream {}; return true }
    #expect(AppDelegate.RemoteEdit.uploading == before + 2, "quitting is asked about")
    first.continuation.finish()
    try await Task.sleep(for: .milliseconds(100))
    #expect(FileManager.default.fileExists(atPath: marker), "a later save still uploads")
    second.continuation.finish()
    #expect(await state.upload?.value == true)
    #expect(!FileManager.default.fileExists(atPath: marker))
    #expect(AppDelegate.RemoteEdit.uploading == before)

    state.save(in: root) { false }
    #expect(await state.upload?.value == false)
    #expect(FileManager.default.fileExists(atPath: marker), "the copy is the only one of that text")
}

/// R8: the viewer and the editor tell their opener when they close (that's when the copy goes).
@MainActor @Test func viewerAndEditorReportClosing() throws {
    _ = NSApplication.shared
    let root = try tempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let url = URL(fileURLWithPath: root + "/f.txt")
    try Data("x\n".utf8).write(to: url)
    var closed: [String] = []
    let v = Viewer(url)
    v.onClose = { closed.append("viewer") }
    v.close()
    let e = try Editor(url)
    e.onClose = { closed.append("editor") }
    e.close()
    e.close()
    #expect(closed == ["viewer", "editor"])
}

/// R8: Save As (when the copy changed on disk) doesn't offer the copy's own folder — it goes when the editor closes.
@Test func saveAsSkipsTheCopysFolder() {
    #expect(TempCopies.holds(URL(fileURLWithPath: NSTemporaryDirectory() + "dfm-sftp-1/sshd_config")))
    #expect(TempCopies.holds(URL(fileURLWithPath: NSTemporaryDirectory() + "dfm-archive-1/a.txt")))
    #expect(!TempCopies.holds(URL(fileURLWithPath: "/etc/ssh/sshd_config")))
}
