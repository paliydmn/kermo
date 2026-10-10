import Foundation
import Testing
@testable import DFMCore

// These run the real `sftp` client against the local /usr/libexec/sftp-server (no ssh, no network).

private let t = SFTPTarget.local()

private func tempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-sftp-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
private func write(_ path: String, _ text: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
}
private func read(_ path: String) -> String? {
    (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) }
}

@Test func sftpListsTrickyNames() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let names = ["plain.txt", "with space.txt", "it's [1] *star?.txt", "кирилиця.txt", "\"quoted\".txt"]
    for n in names { write(d + "/" + n, n) }
    try FileManager.default.createDirectory(atPath: d + "/sub dir", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: d + "/link", withDestinationPath: "plain.txt")

    let items = try SFTP.list(t, d)
    let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name.precomposedStringWithCanonicalMapping, $0) })
    for n in names { #expect(byName[n.precomposedStringWithCanonicalMapping]?.kind == .file, "\(n)") }
    #expect(byName["sub dir"]?.kind == .dir)
    #expect(byName["link"]?.kind == .link)
    #expect(byName["plain.txt"]?.size == Int64("plain.txt".utf8.count))
    #expect(abs((byName["plain.txt"]?.mtime ?? 0) - Date().timeIntervalSince1970) < 120)   // minute precision
    #expect(items.count == names.count + 2)   // no "." / ".."
}

@Test func sftpRenamesAndDeletes() throws {
    let remote = tempDir()
    defer { try? FileManager.default.removeItem(atPath: remote) }
    write(remote + "/tree/it's [1].txt", "A")
    write(remote + "/tree/deep/b.txt", "B")
    write(remote + "/tree/up load.txt", "U")

    let c = try SFTPClient(t)
    defer { c.close() }
    try c.mkdir(remote + "/new [dir]")
    try c.rename(remote + "/tree/up load.txt", remote + "/new [dir]/moved.txt")
    #expect(read(remote + "/new [dir]/moved.txt") == "U")

    let del = FileJob(.delete, sources: [remote + "/tree", remote + "/new [dir]/moved.txt"], from: .sftp(t), to: .sftp(t), destDir: nil)
    del.run()
    #expect(del.progress.errors.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: remote + "/tree"))
    #expect(!FileManager.default.fileExists(atPath: remote + "/new [dir]/moved.txt"))

    #expect(throws: SFTPError.self) { try SFTP.list(t, remote + "/missing") }
}

@Test func sftpHome() throws {
    #expect(try SFTP.home(t).hasPrefix("/"))
}

@Test func sshConfigHostsWithInclude() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    write(d + "/extra.conf", "Host db1 db2\n  HostName 10.0.0.5\n  User postgres\n")
    write(d + "/config", """
        # comment
        Include \(d)/extra.conf
        Host web
            HostName web.example.com
            User deploy
            Port 2222
        Host *.internal !bastion
            User ops
        Host bastion
          User=admin
        """)
    let hosts = SSHConfig.hosts(file: d + "/config")
    #expect(hosts.map(\.alias) == ["db1", "db2", "web", "bastion"])
    #expect(hosts[0].hostName == "10.0.0.5" && hosts[1].user == "postgres")
    #expect(hosts[2] == SSHConfig.Host(alias: "web", hostName: "web.example.com", user: "deploy", port: 2222))
    #expect(hosts[3].user == "admin")
}

@Test func serverAddresses() {
    #expect(ServerAddress.parse("deploy@web:/var/www") == .sftp(SFTPTarget(host: "deploy@web"), path: "/var/www"))
    #expect(ServerAddress.parse("db1") == .sftp(SFTPTarget(host: "db1"), path: nil))
    #expect(ServerAddress.parse("sftp://root@10.0.0.5:2222/etc") == .sftp(SFTPTarget(host: "root@10.0.0.5", port: 2222), path: "/etc"))
    #expect(ServerAddress.parse("smb://nas.local/share") == .mount(URL(string: "smb://nas.local/share")!))
    #expect(ServerAddress.parse("nfs://srv/export") == .mount(URL(string: "nfs://srv/export")!))
    #expect(ServerAddress.parse("  ") == nil)
    #expect(ServerAddress.parse("-oProxyCommand=touch x") == nil)   // S11
    #expect(ServerAddress.parse("ssh://-oProxyCommand=x/") == nil)
    #expect(SSHCommand.line(SFTPTarget(host: "h", port: 2)) == "ssh -p 2 -- h")
}

@Test func sftpErrorsSayWhyAndAreNotConnectionErrors() {
    do {
        _ = try SFTP.list(t, "/dfm-definitely-missing-\(UUID().uuidString)")
        Issue.record("expected an error")
    } catch let e as SFTPError {
        #expect(e.message == "No such file" && !e.connection, "a missing folder isn't \"Can't connect\": \(e.message)")
        #expect(e.errorDescription == e.message)
    } catch { Issue.record("unexpected \(error)") }
}

@Test func sshConfigParsingRules() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    write(d + "/loop.conf", "Include \(d)/loop.conf\nHost looped\n")   // self-include must stop
    write(d + "/config", """
        Host first
          HostName one.example
          HostName two.example
          Port notanumber
        Match host first
          User should-not-apply
        Host * ?.wild !neg
          User ops
        Host first
          User later-wins-not
          HostName three.example
        Host "quoted"
          User=eq
        Include \(d)/loop.conf \(d)/missing-*.conf
        Host tabbed	tab.example
        \tUser\ttabs
        """)
    let hosts = SSHConfig.hosts(file: d + "/config")
    #expect(hosts.prefix(3).map(\.alias) == ["first", "quoted", "looped"])
    let first = hosts.first
    #expect(first?.hostName == "one.example" && first?.port == nil && first?.user == nil)   // first value wins; Match resets
    #expect(hosts.dropFirst().first?.user == "eq")
    #expect(hosts.last?.user == "tabs")
    #expect(hosts.map(\.alias).suffix(2) == ["tabbed", "tab.example"])
    #expect(SSHConfig.hosts(file: d + "/nope").isEmpty)
}

@Test func serverAddressShapes() {
    #expect(ServerAddress.parse("ssh://u@h:22/") == .sftp(SFTPTarget(host: "u@h", port: 22), path: "/"))
    #expect(ServerAddress.parse("sftp://host") == .sftp(SFTPTarget(host: "host"), path: nil))
    #expect(ServerAddress.parse("host:") == .sftp(SFTPTarget(host: "host"), path: nil))
    #expect(ServerAddress.parse("u@h") == .sftp(SFTPTarget(host: "u@h"), path: nil))
    #expect(ServerAddress.parse("h:rel/path") == .sftp(SFTPTarget(host: "h"), path: "rel/path"))
    #expect(ServerAddress.parse("host:2222") == .sftp(SFTPTarget(host: "host", port: 2222), path: nil))   // digits alone: a port (R25)
    #expect(ServerAddress.parse("SMB://nas/share") == .mount(URL(string: "SMB://nas/share")!))
    #expect(ServerAddress.parse("afp://nas/share") == .mount(URL(string: "afp://nas/share")!))
    #expect(ServerAddress.parse("https://dav.example/remote.php") == .mount(URL(string: "https://dav.example/remote.php")!))
    #expect(ServerAddress.parse("ftp://x") == .mount(URL(string: "ftp://x")!))
    #expect(ServerAddress.parse("") == nil)
}

@Test func sshCommandArgumentsAndExitStatus() {
    let a = SSHCommand.arguments(SFTPTarget(host: "me@nas", port: 2222))
    #expect(a.suffix(4) == ["-p", "2222", "--", "me@nas"])   // ssh's -p, not sftp's -P
    #expect(a.contains("ControlMaster=auto") && a.contains { $0.hasPrefix("ControlPath=\(SFTP.controlDir)/") }, "one connection with SFTP sessions")
    #expect(SSHCommand.arguments(SFTPTarget(host: "prod")).suffix(2) == ["--", "prod"])
    #expect(SSHCommand.line(SFTPTarget(host: "me@nas", port: 2222)) == "ssh -p 2222 -- me@nas")
    #expect(SSHCommand.describe(status: 255 << 8) == "ssh exited with status 255")   // raw wait(2) status
    #expect(SSHCommand.describe(status: 0) == "Connection closed")
    #expect(SSHCommand.describe(status: 9) == "ssh ended by signal 9")
}

// F8: these two run real ssh (a DNS lookup of a .invalid name; a SYN to a blackhole address), nothing gets through.

@Test func unreachableServerSaysWhyInsteadOfConnectionClosed() {
    do {
        _ = try SFTP.list(SFTPTarget(host: "dfm-no-such-host.invalid"), "/")
        Issue.record("expected an error")
    } catch let e as SFTPError {
        #expect(e.connection)
        #expect(e.message.contains("dfm-no-such-host.invalid"), "got: \(e.message)")
    } catch { Issue.record("unexpected \(error)") }
}

@Test func connectingCanBeCancelled() {
    let flag = CancelFlag()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { flag.cancel() }
    let started = Date()
    do {
        _ = try SFTP.list(SFTPTarget(host: "10.255.255.1"), "/", cancel: flag)   // never answers: ConnectTimeout is 15 s
        Issue.record("expected an error")
    } catch {
        // Offline, the connect fails at once instead; either way nobody waits for the timeout.
        #expect(error is CancellationError || (error as? SFTPError)?.connection == true, "got: \(error)")
    }
    #expect(Date().timeIntervalSince(started) < 5)
}

@Test func keyFileGoesToSshAndSftpAlone() {
    let t = SFTPTarget(host: "me@nas", port: 2222, identity: "~/.ssh/nas")
    let key = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/nas")
    #expect(SSHCommand.arguments(t).suffix(8) == ["-p", "2222", "-i", key, "-o", "IdentitiesOnly=yes", "--", "me@nas"])
    #expect(SSHCommand.line(t) == "ssh -p 2222 -i \(key) -o IdentitiesOnly=yes -- me@nas")
    #expect(!SSHCommand.arguments(SFTPTarget(host: "nas")).contains("-i"))
}

/// The saved password reaches askpass once, through a FIFO that's gone once the login returns.
@Test func savedPasswordIsReadOnceThroughAFifo() throws {
    func askpass(_ env: [String: String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"[ -p "$DFM_ASKPASS_FIFO" ] && cat "$DFM_ASKPASS_FIFO""#]
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    let t = SFTPTarget(host: "me@nas")
    SFTP.password = { $0 == t ? "s3cr et" : nil }
    defer { SFTP.password = nil }
    var path = ""
    let answers = try SFTP.withPassword(t) { env in
        path = env["DFM_ASKPASS_FIFO"] ?? ""
        return [try askpass(env), try askpass(env)]
    }
    #expect(answers == ["s3cr et", ""], "a second prompt (wrong password) gets nothing: the dialog asks")
    #expect(path.hasPrefix(SFTP.controlDir + "/") && !FileManager.default.fileExists(atPath: path))
    // Unread (the key was enough): still gone afterwards.
    try SFTP.withPassword(t) { env in
        path = env["DFM_ASKPASS_FIFO"] ?? ""
        #expect(FileManager.default.fileExists(atPath: path))
    }
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(SFTP.withPassword(SFTPTarget(host: "other")) { $0 }.isEmpty, "no saved password: no FIFO")
}
