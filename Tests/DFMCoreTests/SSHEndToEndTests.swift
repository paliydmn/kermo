import Foundation
import Testing
@testable import DFMCore

// Copy / move through the real OpenSSH path: a throwaway sshd on 127.0.0.1 (own host key, own authorized_keys,
// nothing in ~/.ssh touched), a ControlMaster brought up the way startMaster would, then `ssh -s sftp` riding it.

private func sh(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// A free port: the kernel's pick for a socket bound to 0.
func freeTCPPort() -> Int {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(s) }
    var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                           sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) } }
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
    return Int(UInt16(bigEndian: addr.sin_port))
}

/// A throwaway sshd on 127.0.0.1 (its own host key and authorized_keys: nothing in ~/.ssh touched; `config`: more
/// sshd_config lines) and a ControlMaster to it, started the way startMaster starts one (`masterArguments`: its log
/// too) but with the test's own known_hosts. `body` gets the target, the test's folder and the options its own ssh
/// commands need (that known_hosts).
func withTestSSHD(config: String = "", _ body: (_ t: SFTPTarget, _ dir: String, _ ssh: [String]) throws -> Void) throws {
    let fm = FileManager.default
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-sshd-" + UUID().uuidString.prefix(8)
    try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: d) }
    #expect(sh(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", d + "/host_key"]) == 0)
    #expect(sh(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", d + "/user_key"]) == 0)
    try fm.copyItem(atPath: d + "/user_key.pub", toPath: d + "/authorized_keys")

    let port = freeTCPPort()
    try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(d)/host_key
        AuthorizedKeysFile \(d)/authorized_keys
        PidFile \(d)/sshd.pid
        UsePAM no
        StrictModes no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        Subsystem sftp /usr/libexec/sftp-server
        \(config)

        """.write(toFile: d + "/sshd_config", atomically: true, encoding: .utf8)
    let sshd = Process()
    sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
    sshd.arguments = ["-f", d + "/sshd_config", "-D", "-e"]
    sshd.standardError = FileHandle.nullDevice
    try sshd.run()
    defer { sshd.terminate() }

    let t = SFTPTarget(host: NSUserName() + "@127.0.0.1", port: port, identity: d + "/user_key")
    // The test's own known_hosts; same ControlPath (%C) as the app computes, so SFTPClient finds the master.
    // AddKeysToAgent=no: a `yes` in ~/.ssh/config would leave each run's throwaway key in the agent, and a few hundred
    // of them make password logins elsewhere fail with "Too many authentication failures".
    let own = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=\(d)/known_hosts", "-o", "AddKeysToAgent=no"]
    let master = ["/usr/bin/ssh"] + own + SFTP.connectionOptions(t)
    defer {
        _ = sh(master + ["-O", "exit"] + t.arguments())
        unlink(SFTP.masterLog(t))
    }
    var up = false
    for _ in 0..<50 where !up {
        up = sh(master + SFTP.masterArguments(t) + t.arguments()) == 0
        if !up { usleep(100_000) }
    }
    try #require(up, "sshd on 127.0.0.1:\(port) never accepted the key")
    try body(t, d, own)
}

@Test(.timeLimit(.minutes(1))) func copyAndMoveOverRealSSH() throws { try withTestSSHD { t, d, _ in
    let fm = FileManager.default
    let home = d + "/home", remote = d + "/remote", back = d + "/back"
    for dir in [home + "/tree/sub", remote, back] { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    var big = Data(count: 5_000_000)
    big.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, 5_000_000) }
    try big.write(to: URL(fileURLWithPath: home + "/tree/sub/big.bin"))
    try Data("it's".utf8).write(to: URL(fileURLWithPath: home + "/tree/it's [1].txt"))

    let upload = FileJob(.copy, sources: [home + "/tree"], from: .local, to: .sftp(t), destDir: remote)
    upload.run()
    #expect(upload.progress.state == .done && upload.progress.errors.isEmpty, "\(upload.progress.errors)")
    #expect(fm.contents(atPath: remote + "/tree/sub/big.bin") == big)

    let download = FileJob(.move, sources: [remote + "/tree"], from: .sftp(t), to: .local, destDir: back)
    download.run()
    #expect(download.progress.state == .done && download.progress.errors.isEmpty, "\(download.progress.errors)")
    #expect(fm.contents(atPath: back + "/tree/sub/big.bin") == big)
    #expect(fm.contents(atPath: back + "/tree/it's [1].txt") == Data("it's".utf8))
    #expect(!fm.fileExists(atPath: remote + "/tree"))
    #expect(download.progress.doneBytes == download.progress.totalBytes)

    // Task 8, R1: ⌘E / F2 on a server panel runs on the server, in its folder, each name one argument there.
    let names = ["$(touch PWNED)", "it's", "two\nlines", "-rf"]
    for n in names { fm.createFile(atPath: remote + "/" + n, contents: nil) }
    let ctx = ShellContext(dir: remote, otherDir: nil, cursor: names[0], targets: names)
    func onServer(_ command: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "UserKnownHostsFile=\(d)/known_hosts"]
            + SSHCommand.arguments(t, command: SSHCommand.inDir(remote, command), tty: false)
        p.currentDirectoryURL = URL(fileURLWithPath: "/")   // not the folder it must run in
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    #expect(onServer(try #require(ctx.expand("pwd"))) == remote + "\n")
    let listed = onServer(try #require(ctx.expand("printf '<%%s>' %s %f")))
    #expect(listed == names.map { "<\($0.hasPrefix("-") ? "./" + $0 : $0)>" }.joined() + "<$(touch PWNED)>")
    #expect(!fm.fileExists(atPath: remote + "/PWNED") && !fm.fileExists(atPath: "/PWNED"))
    #expect(ctx.expand("cp %s %D") == nil)   // the other panel is on another machine: refused, not a local path

    // R2: following a server's log appends what it writes from where the local copy ends — also after rotation.
    let log = remote + "/app.log", copy = d + "/copy.log"
    try Data("one\n".utf8).write(to: URL(fileURLWithPath: log))
    try Data("one\n".utf8).write(to: URL(fileURLWithPath: copy))
    let tail = Process()
    tail.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    tail.arguments = ["-o", "BatchMode=yes", "-o", "UserKnownHostsFile=\(d)/known_hosts"]
        + SSHCommand.arguments(t, command: SSHCommand.follow(log, after: 4), tty: false)
    tail.standardOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: copy))
    try (tail.standardOutput as! FileHandle).seekToEnd()
    tail.standardError = FileHandle.nullDevice
    tail.standardInput = FileHandle.nullDevice
    try tail.run()
    defer {
        tail.terminate()
        // The server's own tail: sshd without a tty sends it no SIGHUP, and tail -F of a deleted folder writes nothing
        // to get SIGPIPE — it stayed, one per run (task 11, N2). The "server" is this Mac: it goes by its unique path.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "--", "-F -- " + log]
        try? kill.run()
        kill.waitUntilExit()
    }
    func copyIs(_ s: String) -> Bool {
        for _ in 0..<100 { if fm.contents(atPath: copy) == Data(s.utf8) { return true }; usleep(50_000) }
        return false
    }
    usleep(300_000)
    let h = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
    try h.seekToEnd(); try h.write(contentsOf: Data("two\n".utf8)); try h.close()
    #expect(copyIs("one\ntwo\n"))
    try fm.moveItem(atPath: log, toPath: log + ".1")   // logrotate: move, then a new file
    try Data("three\n".utf8).write(to: URL(fileURLWithPath: log))
    #expect(copyIs("one\ntwo\nthree\n"))
}}
