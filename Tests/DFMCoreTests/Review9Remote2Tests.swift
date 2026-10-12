import Foundation
import Testing
@testable import DFMCore

// Task 9 §6, servers: R2, R3, R25.

/// R25: a port after the host (`host:port`, `host:port:/path`) and IPv6 hosts, bracketed or bare; the scp-style
/// forms keep working.
@Test func serverAddressTakesPortsAndIPv6() {
    func sftp(_ host: String, _ port: Int? = nil, _ path: String? = nil) -> ServerAddress { .sftp(SFTPTarget(host: host, port: port), path: path) }
    #expect(ServerAddress.parse("user@host:2222") == sftp("user@host", 2222))
    #expect(ServerAddress.parse("h:2222:/var/log") == sftp("h", 2222, "/var/log"))
    #expect(ServerAddress.parse("u@h:2222:~/logs") == sftp("u@h", 2222, "~/logs"))
    #expect(ServerAddress.parse("h:2222:") == sftp("h", 2222))
    #expect(ServerAddress.parse("[::1]") == sftp("::1"))
    #expect(ServerAddress.parse("u@[::1]:22") == sftp("u@::1", 22))
    #expect(ServerAddress.parse("[fe80::1]:2222:/etc") == sftp("fe80::1", 2222, "/etc"))
    #expect(ServerAddress.parse("root@[2001:db8::5]:/srv") == sftp("root@2001:db8::5", nil, "/srv"))
    #expect(ServerAddress.parse("fe80::1") == sftp("fe80::1"))
    #expect(ServerAddress.parse("u@2001:db8::5") == sftp("u@2001:db8::5"))
    #expect(ServerAddress.parse("sftp://u@[::1]:2222/etc") == sftp("u@::1", 2222, "/etc"))
    // Unchanged: a path after ":" (relative too), a bare host, a user, "-" never a host.
    #expect(ServerAddress.parse("deploy@web:/var/www") == sftp("deploy@web", nil, "/var/www"))
    #expect(ServerAddress.parse("h:rel/path") == sftp("h", nil, "rel/path"))
    #expect(ServerAddress.parse("h:12:30.log") == sftp("h", nil, "12:30.log"))
    #expect(ServerAddress.parse("h:/mail@box") == sftp("h", nil, "/mail@box"))
    #expect(ServerAddress.parse("u@h") == sftp("u@h"))
    #expect(ServerAddress.parse("host:") == sftp("host"))
    #expect(ServerAddress.parse("h:70000") == nil)
    #expect(ServerAddress.parse("[-oProxyCommand=x]") == nil)
    #expect(ServerAddress.parse("[::1]x") == nil)
    #expect(SSHCommand.arguments(SFTPTarget(host: "u@fe80::1")).last == "u@fe80::1")
}

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-r9remote-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// R3: a save to a server stops on a change of the same size made in the same second (which size and whole-second
/// mtime don't show); an unchanged file still saves, again and again, and a file over 1 MB is checked as before.
@Test func remoteSaveSeesASameSizeChangeInTheSameSecond() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fm = FileManager.default
    let conf = d + "/nginx.conf", local = d + "/local.conf"
    try Data("listen 80;\n".utf8).write(to: URL(fileURLWithPath: conf))
    let c = try SFTPClient(.local())
    defer { c.close() }

    var base = try c.download(conf, to: local)
    try Data("listen 8080;\n".utf8).write(to: URL(fileURLWithPath: local))
    base = try c.upload(local, to: conf, baseline: base)   // unchanged there: saves
    try Data("listen 8081;\n".utf8).write(to: URL(fileURLWithPath: local))
    base = try c.upload(local, to: conf, baseline: base)   // the next save: its baseline is what the last one sent
    #expect(fm.contents(atPath: conf) == Data("listen 8081;\n".utf8))

    // A colleague's edit, same size, same second.
    try Data("listen 9090;\n".utf8).write(to: URL(fileURLWithPath: conf))
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: base.mtime)], ofItemAtPath: conf)
    try Data("listen 8082;\n".utf8).write(to: URL(fileURLWithPath: local))
    #expect(throws: SFTPClient.ChangedOnServer.self) { try c.upload(local, to: conf, baseline: base) }
    #expect(fm.contents(atPath: conf) == Data("listen 9090;\n".utf8))

    // Over 1 MB: no content check (size and mtime only).
    let big = d + "/big.log"
    try Data(repeating: 0x61, count: (1 << 20) + 1).write(to: URL(fileURLWithPath: big))
    #expect(try c.download(big, to: local).sha256 == nil)
}

/// R2: F3 on a big server log fetches only its tail; the attributes are still the whole file's.
@Test func remoteDownloadTakesOnlyTheTail() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let log = d + "/app.log", local = d + "/tail.log"
    let content = Data((0..<20_000).map { "line \($0)\n" }.joined().utf8)
    try content.write(to: URL(fileURLWithPath: log))
    let c = try SFTPClient(.local())
    defer { c.close() }

    let a = try c.download(log, to: local, last: 4096)
    #expect(a.size == Int64(content.count))
    #expect(FileManager.default.contents(atPath: local) == content.suffix(4096))
    #expect(a.sha256 == nil)   // a part: never a save's baseline
    #expect(try c.download(log, to: local, last: 1 << 30).size == Int64(content.count))   // smaller than the tail: all of it
    #expect(FileManager.default.contents(atPath: local) == content)
}
