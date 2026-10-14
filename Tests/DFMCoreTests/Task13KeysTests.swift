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

extension SudoPasswordTests {

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
