import Foundation
import Testing
@testable import DFMCore

// Task 13: Copy SSH Key to Server… (`SSHKeyCopy`). Never this Mac's ~/.ssh: the test sshd's own authorized_keys.

/// A public key file is one line of a known type; anything else (a private key picked by mistake, two keys) isn't sent.
@Test func onlyAPublicKeyLineIsSent() {
    #expect(SSHKeyCopy.line("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK0= me@mac\n") == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK0= me@mac")
    #expect(SSHKeyCopy.line("ecdsa-sha2-nistp256 AAAAE2Vj\n") != nil && SSHKeyCopy.line("sk-ssh-ed25519@openssh.com AAAAGn== x") != nil)
    #expect(SSHKeyCopy.line("-----BEGIN OPENSSH " + "PRIVATE KEY-----\nb3Blbn\n-----END OPENSSH " + "PRIVATE KEY-----\n") == nil)   // made up
    #expect(SSHKeyCopy.line("ssh-ed25519 AAAA one\nssh-ed25519 BBBB two\n") == nil)
    #expect(SSHKeyCopy.line("ssh-ed25519 AAAA;rm x") == nil && SSHKeyCopy.line("") == nil)
}

/// What ssh says when a server's host key changed (OpenSSH 10.3; the same with BatchMode): read from the line that names
/// the file in full ("Add correct host key in …" cuts it short), the host as known_hosts names it. The address's own line
/// (CheckHostIP) isn't the one; other failures aren't a change.
@Test func aChangedHostKeyIsRead() {
    let said = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
        Someone could be eavesdropping on you right now (man-in-the-middle attack)!
        It is also possible that a host key has just been changed.
        The fingerprint for the ED25519 key sent by the remote host is
        SHA256:KKEiekWvluTKax6JzdMGedc4ocvunCpugqUdDJAmUf4.
        Please contact your system administrator.
        Add correct host key in /Users/me/.ssh/kno to get rid of this message.
        Offending key for IP in /Users/me/.ssh/known_hosts:7
        Offending ED25519 key in /Users/me/.ssh/known_hosts:12
        Host key for [192.0.2.7]:2222 has changed and you have requested strict checking.
        Host key verification failed.
        """
    let c = HostKeyChange.parse(said)
    #expect(c == HostKeyChange(host: "[192.0.2.7]:2222", file: "/Users/me/.ssh/known_hosts", line: 12, keyType: "ED25519",
                               fingerprint: "SHA256:KKEiekWvluTKax6JzdMGedc4ocvunCpugqUdDJAmUf4"))
    #expect(c?.message("web1").hasPrefix("web1's host key has changed. Either the server was reinstalled, or someone is intercepting the connection.") == true)
    #expect(HostKeyChange.parse("me@web1: Permission denied (publickey,password).") == nil)
    let web1 = "user me\nhostname 192.0.2.7\nport 2222\nuserknownhostsfile /Users/me/.ssh/known_hosts /Users/me/.ssh/known_hosts2\n"
    let failed = SFTP.loginFailure(said, SFTPTarget(host: "me@web1")) { web1 }
    #expect(failed.connection && failed.hostKey == c && failed.message == c?.message("me@web1"), "everywhere a login fails, in plain words")
    #expect(SFTP.loginFailure("Permission denied", SFTPTarget(host: "web1")) { web1 }.message == "Permission denied")
    // The server's banner can say all that too, about another host or file: then it's only text, nothing to remove.
    for other in [web1.replacingOccurrences(of: "port 2222", with: "port 22"),
                  web1.replacingOccurrences(of: "userknownhostsfile /Users/me/.ssh/known_hosts ", with: "userknownhostsfile "),
                  "hostkeyalias web1\n" + web1] {
        #expect(SFTP.loginFailure(said, SFTPTarget(host: "me@web1")) { other }.hostKey == nil, "\(other)")
    }
    #expect(SFTP.knownHosts(sshG: "hostkeyalias web1\n" + web1)?.name == "web1" && SFTP.knownHosts(sshG: web1)?.name == "[192.0.2.7]:2222")
    #expect(HostKeyChange.parse(said.replacingOccurrences(of: "Offending ED25519 key in /Users/me/.ssh/known_hosts:12\n", with: "")) == nil, "no line to remove")
}

extension SudoPasswordTests {

/// A server's host key replaced: ssh refuses, the change is read from what it said, the old key goes from the file it
/// named (the test's own known_hosts), and the next login takes the new key.
@Test(.timeLimit(.minutes(1))) func aChangedHostKeyIsRemovedAndTheNextLoginWorks() throws { try withTestSSHD { t, d, _ in
    func ssh(_ checking: String) throws -> (status: Int32, said: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=\(checking)", "-o", "UserKnownHostsFile=\(d)/known_hosts",
                       "-o", "ControlPath=none", "-o", "AddKeysToAgent=no"] + t.arguments() + ["true"]
        let err = Pipe()
        (p.standardInput, p.standardOutput, p.standardError) = (FileHandle.nullDevice, FileHandle.nullDevice, err)
        try p.run()
        let said = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, said)
    }
    #expect(try ssh("yes").status == 0, "known")
    let gen = Process()
    gen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    gen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", d + "/other_host_key"]
    try gen.run()
    gen.waitUntilExit()
    let other = try String(contentsOfFile: d + "/other_host_key.pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
    try Data("[127.0.0.1]:\(t.port!) \(other)\n".utf8).write(to: URL(fileURLWithPath: d + "/known_hosts"))

    let refused = try ssh("yes")
    #expect(refused.status == 255)
    let change = try #require(HostKeyChange.parse(refused.said), "\(refused.said)")
    #expect(change.host == "[127.0.0.1]:\(t.port!)" && change.file == d + "/known_hosts" && change.line == 1)
    let g = Process(), out = Pipe()
    g.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    g.arguments = ["-G", "-o", "UserKnownHostsFile=\(d)/known_hosts"] + t.arguments()
    (g.standardInput, g.standardOutput, g.standardError) = (FileHandle.nullDevice, out, FileHandle.nullDevice)
    try g.run()
    let sshG = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(SFTP.loginFailure(refused.said, t) { sshG }.hostKey == change, "ssh -G names this host and file")
    try #require(change.file == d + "/known_hosts")
    try change.remove()
    #expect(!(try String(contentsOfFile: d + "/known_hosts", encoding: .utf8)).contains(other))
    #expect(throws: SFTPError.self) { try change.remove() }   // nothing left to find: not "done"
    #expect(try ssh("accept-new").status == 0, "the new key taken, as the askpass question would")
} }

/// The key goes in once — a second time finds it there — after a newline the file's last line lacked, into a folder
/// and file made owner-only; then a login with that key alone works, past the shared connection. Before, it didn't.
@Test(.timeLimit(.minutes(1))) func copiedKeyLogsIn() throws { try withTestSSHD { t, d, own in
    let gen = Process()
    gen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    gen.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "me@mac", "-f", d + "/new_key"]
    try gen.run()
    gen.waitUntilExit()
    let key = try #require(SSHKeyCopy.line(String(contentsOfFile: d + "/new_key.pub", encoding: .utf8)))
    #expect(try SSHKeyCopy.verify(t, identity: d + "/new_key", options: own)?.contains("Permission denied") == true)

    #expect(try SSHKeyCopy.install(key, on: t, file: d + "/authorized_keys"))
    #expect(try !SSHKeyCopy.install(key, on: t, file: d + "/authorized_keys"), "there already")
    let lines = try String(contentsOfFile: d + "/authorized_keys", encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2 && lines.last.map(String.init) == key)
    #expect(try SSHKeyCopy.verify(t, identity: d + "/new_key", options: own) == nil)

    try Data("ssh-ed25519 AAAAold x".utf8).write(to: URL(fileURLWithPath: d + "/ak2"))
    #expect(try SSHKeyCopy.install(key, on: t, file: d + "/ak2"))
    #expect(try String(contentsOfFile: d + "/ak2", encoding: .utf8) == "ssh-ed25519 AAAAold x\n" + key + "\n")

    #expect(try SSHKeyCopy.install(key, on: t, file: d + "/fresh/.ssh/authorized_keys"))
    let fm = FileManager.default
    #expect((try fm.attributesOfItem(atPath: d + "/fresh/.ssh")[.posixPermissions] as? Int) == 0o700)
    #expect((try fm.attributesOfItem(atPath: d + "/fresh/.ssh/authorized_keys")[.posixPermissions] as? Int) == 0o600)
    #expect(throws: SFTPError.self) { try SSHKeyCopy.install(key, on: t, file: d + "/ak2/x") }   // a file on the way
} }

}
