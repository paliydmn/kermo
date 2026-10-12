import Foundation
import Testing
@testable import DFMCore

// Server file history: versions a save replaced, kept on this Mac (`ServerHistory`). Every test has a root of its
// own in the temp folder: none of them touches ~/.config.

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-hist-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func attrs(_ size: Int, mtime: Double = 1_700_000_000) -> SFTPClient.Attrs { SFTPClient.Attrs(kind: .file, size: Int64(size), mtime: mtime, mode: 0o644) }
private let web = SFTPTarget(host: "me@web")
private let when = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 3, minute: 4, second: 5))!

/// A version sits where its file is on the server, named with the time its save replaced it — and goes back.
@Test func versionPathsMirrorTheServer() throws {
    let h = ServerHistory(root: "/h")
    #expect(h.path(of: web, "/etc/nginx/nginx.conf", at: when) == "/h/me@web/etc/nginx/nginx.conf@2026-10-12_03-04-05")
    #expect(h.path(of: web, "/etc/nginx/nginx.conf", at: when, n: 3) == "/h/me@web/etc/nginx/nginx.conf@2026-10-12_03-04-05-3")
    #expect(h.path(of: SFTPTarget(host: "me@web", port: 2222), "/a", at: when) == "/h/me@web_2222/a@2026-10-12_03-04-05")
    #expect(h.path(of: SFTPTarget(host: "me@web", port: 22), "/a", at: when) == "/h/me@web/a@2026-10-12_03-04-05", "22 is no port at all")
    #expect(h.path(of: web, "relative/x", at: when) == "/h/me@web/relative/x@2026-10-12_03-04-05")

    for path in ["/etc/nginx/nginx.conf", "/srv/конфіг/файл ✓.conf", "/home/me/a@b.txt", "/top"] {
        let v = try #require(h.path(of: web, path, at: when))
        let back = try #require(h.origin(of: v))
        #expect(back.server == "me@web" && back.path == path && back.date == when, "\(path)")
    }
    #expect(ServerHistory.parse("a@b@2026-10-12_03-04-05-2").map { [$0.name, "\($0.n)"] } == ["a@b", "2"])
    for name in ["x", "x@", "x@2026-10-12", "x@2026-13-01_00-00-00", "x@2026-10-12_03-04-05-1", "x@2026-10-12_03-04-05-", "x@2026-10-12_03-04-05.1",
                 "x@2026-10-12T03-04-05", "x@２０２６-10-12_03-04-05"] {
        #expect(ServerHistory.parse(name) == nil, "\(name)")
    }
    #expect(h.origin(of: "/elsewhere/me@web/a@2026-10-12_03-04-05") == nil)
}

/// A server path ends up in a path on this Mac: whatever it holds, a version stays inside the root.
@Test func serverPathsStayInsideTheRoot() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let h = ServerHistory(root: d + "/root")
    let tricks = ["../../etc/passwd", "/../../x", "a/../../../b", "\0/x", "x\0/../../y", "//a//b", "/a/./b", "/a/../../..//c", "..."]
    for (i, path) in tricks.enumerated() {
        let v = try #require(h.path(of: web, path, at: when), "\(path)")
        #expect(v.hasPrefix(d + "/root/me@web/") && !v.contains("\0") && !v.split(separator: "/").contains(".."), "\(v)")
        #expect(h.keep(Data("\(i)".utf8), attrs(1), of: web, path, at: when.addingTimeInterval(Double(i))) == nil, "\(path)")
    }
    for host in ["..", ".", "", "a/../../b", "x\0y"] {
        let v = try #require(h.path(of: SFTPTarget(host: host), "/f", at: when))
        #expect(v.hasPrefix(d + "/root/") && !v.contains("\0") && !v.split(separator: "/").contains(".."), "\(host): \(v)")
        #expect(h.keep(Data("h".utf8), attrs(1), of: SFTPTarget(host: host), "/f", at: when) == nil)
    }
    #expect(h.path(of: web, "/", at: when) == nil && h.path(of: web, "a/..", at: when) == nil)
    #expect(h.keep(Data(), attrs(0), of: web, "/", at: when) != nil, "no name: says so")
    #expect(try FileManager.default.contentsOfDirectory(atPath: d) == ["root"], "nothing written next to the root")
    #expect(h.versions(of: web, "/etc/passwd").count == 1 && h.versions(of: web, "/x").count == 1)
}

/// Two saves within one second keep both; the same file on another port is another server's.
@Test func versionsDontOverwriteOrMix() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let h = ServerHistory(root: d)
    let other = SFTPTarget(host: "me@web", port: 2222)
    #expect(h.keep(Data("one".utf8), attrs(3), of: web, "/etc/app.conf", at: when) == nil)
    #expect(h.keep(Data("two".utf8), attrs(3), of: web, "/etc/app.conf", at: when) == nil)
    #expect(h.keep(Data("port".utf8), attrs(4), of: other, "/etc/app.conf", at: when) == nil)
    let mine = h.versions(of: web, "/etc/app.conf")
    #expect(mine.map(\.n) == [2, 1] && mine.map(\.size) == [3, 3], "newest first")
    #expect(mine.map { FileManager.default.contents(atPath: $0.path) } == [Data("two".utf8), Data("one".utf8)])
    #expect(h.versions(of: other, "/etc/app.conf").map { FileManager.default.contents(atPath: $0.path) } == [Data("port".utf8)])
    #expect(h.versions(of: web, "/etc/app").isEmpty && h.versions(of: web, "/etc/app.con").isEmpty, "only that file's")
}

/// 20 versions a file and 200 MB in all by default (smaller here); the oldest go first.
@Test func oldestVersionsGoFirst() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    var h = ServerHistory(root: d)
    #expect(h.perFile == 20 && h.total == 200 << 20 && ServerHistory.fileLimit == 5 << 20)
    h.perFile = 3
    for i in 0..<5 { h.keep(Data("v\(i)".utf8), attrs(2), of: web, "/a", at: when.addingTimeInterval(Double(i))) }
    #expect(h.versions(of: web, "/a").map { FileManager.default.contents(atPath: $0.path) } == ["v4", "v3", "v2"].map { Data($0.utf8) })

    h.total = 1000
    let block = Data(repeating: 7, count: 300)
    h.keep(block, attrs(300), of: web, "/old", at: when.addingTimeInterval(-100))
    h.keep(block, attrs(300), of: SFTPTarget(host: "db"), "/x", at: when.addingTimeInterval(10))
    h.keep(block, attrs(300), of: web, "/new", at: when.addingTimeInterval(20))
    #expect(h.versions(of: web, "/old").count == 1, "906 bytes: all stay")
    h.keep(block, attrs(300), of: web, "/newer", at: when.addingTimeInterval(30))
    #expect(h.versions(of: web, "/old").isEmpty && h.versions(of: web, "/a").count == 3, "1206: the oldest of all goes")
    h.keep(block, attrs(300), of: web, "/newest", at: when.addingTimeInterval(40))
    #expect(h.versions(of: web, "/a").isEmpty && h.versions(of: SFTPTarget(host: "db"), "/x").isEmpty, "then the next oldest, on any server")
    #expect(["/new", "/newer", "/newest"].allSatisfy { h.versions(of: web, $0).count == 1 })
}

/// A file over 5 MB has no version, and says so; one that can't be written says why — neither throws.
@Test func noVersionSaysWhy() throws {
    let d = tempDir()
    defer { chmod(d + "/locked", 0o700); try? FileManager.default.removeItem(atPath: d) }
    #expect(ServerHistory(root: d + "/root").keep(nil, attrs(6 << 20), of: web, "/big.log", at: when) == "file over 5 MB")
    #expect(!FileManager.default.fileExists(atPath: d + "/root"))
    try FileManager.default.createDirectory(atPath: d + "/locked", withIntermediateDirectories: true)
    chmod(d + "/locked", 0o500)
    let why = ServerHistory(root: d + "/locked/root").keep(Data("x".utf8), attrs(1), of: web, "/a", at: when)
    #expect(why != nil && why!.lowercased().contains("permission"), "\(why ?? "")")
}

/// What's kept can be a server's secrets: owner-only folders and files, out of Time Machine. The file has the date it
/// had on the server.
@Test func historyIsPrivate() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let h = ServerHistory(root: d + "/history.noindex")
    #expect(h.keep(Data("secret".utf8), attrs(6, mtime: 1_600_000_000), of: web, "/srv/app/.env", at: when) == nil)
    let v = try #require(h.versions(of: web, "/srv/app/.env").first)
    func mode(_ p: String) -> mode_t { var st = stat(); lstat(p, &st); return st.st_mode & 0o777 }
    for dir in [h.root, h.folder(web), h.folder(web) + "/srv", h.folder(web) + "/srv/app"] { #expect(mode(dir) == 0o700, "\(dir)") }
    #expect(mode(v.path) == 0o600)
    let a = try FileManager.default.attributesOfItem(atPath: v.path)
    #expect((a[.modificationDate] as? Date)?.timeIntervalSince1970 == 1_600_000_000)
    #expect(try URL(fileURLWithPath: h.root).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
}
