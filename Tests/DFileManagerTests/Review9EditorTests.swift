import AppKit
import Testing
@testable import DFileManager

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-editor-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func put(_ bytes: [UInt8], _ path: String) throws { try Data(bytes).write(to: URL(fileURLWithPath: path)) }
private func put(_ s: String, _ path: String) throws { try Data(s.utf8).write(to: URL(fileURLWithPath: path)) }
private func disk(_ path: String) -> [UInt8] { [UInt8](FileManager.default.contents(atPath: path) ?? Data()) }

/// E2: a UTF-8 BOM and CRLF line ends survive a save, and a line typed in a CRLF file gets CRLF too;
/// the save is still the A3 baseline (the next ⌘S doesn't ask). A file with mixed line ends is written as it is.
@MainActor @Test func saveKeepsBOMAndCRLF() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/notes.txt"
    try put([0xEF, 0xBB, 0xBF] + Array("a\r\nb\r\n".utf8), path)

    let e = try Editor(URL(fileURLWithPath: path))
    defer { e.close() }
    #expect(e.textView.string == "a\nb\n")
    e.textView.string += "c\n"   // Enter types \n
    #expect(await e.save())
    #expect(disk(path) == [0xEF, 0xBB, 0xBF] + Array("a\r\nb\r\nc\r\n".utf8))
    #expect(await e.save())

    // Damaged UTF-8 (V4) with a BOM: the BOM isn't shown as U+FEFF and is written back.
    let damaged = dir + "/damaged.txt"
    try put([0xEF, 0xBB, 0xBF] + Array("привіт\r\n".utf8) + [0xFF], damaged)
    let d = try Editor(URL(fileURLWithPath: damaged))
    defer { d.close() }
    #expect(d.textView.string == "привіт\n\u{FFFD}")
    #expect(d.window?.subtitle.contains("UTF-8 (damaged)") == true)
    #expect(await d.save(force: true))
    #expect(disk(damaged) == [0xEF, 0xBB, 0xBF] + Array("привіт\r\n\u{FFFD}".utf8))

    let mixed = dir + "/mixed.txt"
    try put("a\r\nb\n", mixed)
    let m = try Editor(URL(fileURLWithPath: mixed))
    defer { m.close() }
    m.textView.string += "c\n"
    #expect(await m.save())
    #expect(disk(mixed) == Array("a\r\nb\nc\n".utf8))
}

/// E2: a hard-linked file is rewritten in place — every name sees the new text, still one inode.
@MainActor @Test func saveKeepsHardLinks() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try put("v1\n", dir + "/a.txt")
    #expect(link(dir + "/a.txt", dir + "/b.txt") == 0)

    let e = try Editor(URL(fileURLWithPath: dir + "/a.txt"))
    defer { e.close() }
    e.textView.string = "v2\n"
    #expect(await e.save())
    #expect(disk(dir + "/b.txt") == Array("v2\n".utf8))
    var a = stat(), b = stat()
    stat(dir + "/a.txt", &a)
    stat(dir + "/b.txt", &b)
    #expect(a.st_ino == b.st_ino && a.st_nlink == 2)
    #expect(await e.save())   // A3 baseline is the in-place write
}

/// E2: temp+rename keeps the original's BSD flags and creation date.
@MainActor @Test func saveKeepsFlagsAndCreationDate() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/a.txt"
    try put("v1\n", path)
    let born = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes([.creationDate: born], ofItemAtPath: path)
    #expect(chflags(path, UInt32(UF_HIDDEN)) == 0)
    var before = stat()
    stat(path, &before)

    let e = try Editor(URL(fileURLWithPath: path))
    defer { e.close() }
    e.textView.string = "v2\n"
    #expect(await e.save())
    var after = stat()
    stat(path, &after)
    #expect(after.st_ino != before.st_ino)   // went through temp+rename
    #expect(after.st_flags & UInt32(UF_HIDDEN) != 0)
    #expect(after.st_birthtimespec.tv_sec == 1_600_000_000)
    #expect(disk(path) == Array("v2\n".utf8))

    // A locked file isn't saved, and no temp file (locked too, by the copied flags) is left behind.
    #expect(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
    defer { chflags(path, 0) }
    e.textView.string = "v3\n"
    #expect(await !e.save())
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["a.txt"])
    #expect(disk(path) == Array("v2\n".utf8))
}

/// E3: config files get a final newline on save (crontab ignores a last line without one), other files don't;
/// a server copy goes by its path there; the setting can turn it off; it follows the file's CRLF.
@MainActor @Test func configFilesGetAFinalNewline() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    for p in ["/etc/hosts", "/private/etc/ssh/sshd_config", "/Users/u/.zshrc", "/tmp/crontab.ab12Cd",
              // the per-user spool files cron reads, named after the user (Debian, RHEL, macOS)
              "/var/spool/cron/crontabs/root", "/var/spool/cron/root", "/var/at/tabs/dmn", "/private/var/at/tabs/dmn",
              "/usr/lib/cron/tabs/root",
              "a.conf", "a.cfg", "a.ini", "a.yml", "a.yaml", "a.toml"] {
        #expect(Editor.isConfig(p), "\(p)")
    }
    for p in ["/Users/u/notes.txt", "main.swift", "/var/log/system.log"] { #expect(!Editor.isConfig(p), "\(p)") }

    func saved(_ name: String, _ text: String, remote: String? = nil) async throws -> String {
        try put(text, dir + "/" + name)
        let e = try Editor(URL(fileURLWithPath: dir + "/" + name), remote: remote)
        defer { e.close() }
        e.textView.string += "x"
        #expect(await e.save())
        return String(decoding: disk(dir + "/" + name), as: UTF8.self)
    }
    #expect(try await saved("crontab", "* * * * * job ") == "* * * * * job x\n")
    #expect(try await saved("app.conf", "a=1\n") == "a=1\nx\n")
    #expect(try await saved("app.ini", "a=1\r\n") == "a=1\r\nx\r\n")
    #expect(try await saved("notes.txt", "a\n") == "a\nx")
    #expect(try await saved("motd", "hi\n", remote: "🔴 PROD host:/etc/motd") == "hi\nx\n")
    #expect(try await saved("root", "0 3 * * * /backup.sh", remote: "host:/var/spool/cron/crontabs/root") == "0 3 * * * /backup.shx\n")

    // File ▸ Ensure Final Newline shows and toggles it for this window.
    try put("a=1", dir + "/menu.conf")
    let e = try Editor(URL(fileURLWithPath: dir + "/menu.conf"))
    defer { e.close() }
    let item = NSMenuItem(title: "", action: #selector(Editor.toggleFinalNewline(_:)), keyEquivalent: "")
    #expect(e.validateMenuItem(item) && item.state == .on)
    e.toggleFinalNewline(nil)
    #expect(e.validateMenuItem(item) && item.state == .off)
    e.textView.string += "x"
    #expect(await e.save())
    #expect(disk(dir + "/menu.conf") == Array("a=1x".utf8))

    let real = Editor.finalNewlineSetting
    defer { Editor.finalNewlineSetting = real }
    Editor.finalNewlineSetting = { false }
    #expect(try await saved("off.conf", "a=1\n") == "a=1\nx")
    Editor.finalNewlineSetting = { true }
    #expect(try await saved("on.txt", "a\n") == "a\nx\n")
}

/// E2: an unedited file with doubled CRs (autocrlf run twice) saves back byte for byte.
@MainActor @Test func saveKeepsDoubledCR() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/w.txt"
    try put("a\r\r\nb\r\n", path)
    let e = try Editor(URL(fileURLWithPath: path))
    defer { e.close() }
    #expect(await e.save())
    #expect(disk(path) == Array("a\r\r\nb\r\n".utf8))
}

/// E2: the in-place rewrite doesn't write through a file swapped for a symlink or another file after it was checked.
@MainActor @Test func inPlaceSaveDoesntFollowASwap() async throws {
    _ = NSApplication.shared
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let a = dir + "/a.conf", victim = dir + "/victim"
    try put("victim\n", victim)
    let swaps: [@Sendable () -> Int32] = [{ symlink(victim, a) }, { link(victim, a) }]
    for swap in swaps {
        try put("v1\n", a)
        #expect(link(a, dir + "/b.conf") == 0)   // hard-linked: rewritten in place
        let e = try Editor(URL(fileURLWithPath: a))
        defer { e.close() }
        e.willRewriteInPlace = { p in unlink(p); _ = swap() }
        e.textView.string = "v2\n"
        #expect(await !e.save())
        #expect(disk(victim) == Array("victim\n".utf8))
        unlink(a)
        unlink(dir + "/b.conf")
    }
}
