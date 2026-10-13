import Foundation
import Testing
@testable import DFMCore

// Task 13: a server panel as root (`SFTPTarget.sudo`).

/// `stdin` reaches the command, then end of file — more than a pipe holds too; without it the command reads nothing,
/// as before. A command that stops reading early neither hangs nor kills the app (EPIPE).
@Test func commandsReadWhatTheyAreGiven() throws {
    #expect(try SSHCommand.capture(.local(), "cat", stdin: Data("one\ntwo".utf8)) == "one\ntwo")
    #expect(try SSHCommand.capture(.local(), "IFS= read -r a; echo \"[$a]\"; cat", stdin: Data("line\nrest".utf8)) == "[line]\nrest")
    let big = Data(repeating: 0x61, count: 300_000)
    #expect(try SSHCommand.capture(.local(), "wc -c | tr -d ' '", stdin: big) == "300000\n")
    #expect(try SSHCommand.capture(.local(), "head -c 3", stdin: big) == "aaa")
    #expect(try SSHCommand.capture(.local(), "cat") == "", "no stdin: end of file at once")
}

/// A stand-in for a server's sudo: logs its arguments next to itself, then runs what follows `-n --`.
func fakeSudo(_ dir: String, _ body: String = #"[ "$1" = -n ] && [ "$2" = -- ] || exit 2; exec "$3""#) throws -> String {
    let path = dir + "/sudo-" + UUID().uuidString.prefix(8)
    try Data("#!/bin/sh\necho \"$*\" >> \"$0.log\"\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, 0o755)
    return path
}

func sudoLog(_ fake: String) -> [String] {
    (try? String(contentsOfFile: fake + ".log", encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
}

private func rootTempDir() -> String {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-root-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// The root session is ssh running `sudo -n -- <sftp-server>` as a command (`-T`), not the sftp subsystem (`-s`),
/// on the same connection; the user's own stays as it was.
@Test func rootSessionIsSudoOnTheServersSftpServer() {
    let t = SFTPTarget(host: "me@web", port: 2222).asRoot()
    let (program, args) = SudoServer.launch(t, path: "/usr/lib/openssh/sftp-server")
    #expect(program == "/usr/bin/ssh")
    #expect(!args.contains("-s") && args.contains("-T") && args.contains("-x") && args.contains("-a"))
    #expect(args.suffix(4) == ["2222", "--", "me@web", "sudo -n -- /usr/lib/openssh/sftp-server"])
    #expect(Array(args.prefix(SFTP.connectionOptions(t).count)) == SFTP.connectionOptions(SFTPTarget(host: "me@web", port: 2222)), "one connection with the user's")
    #expect(SudoServer.probe(t).hasPrefix("sh -c ") && SudoServer.paths.allSatisfy(SudoServer.probe(t).contains))
    #expect(SudoServer.program(t) == "sudo" && SudoServer.program(.local().asRoot()) == "/usr/bin/false", "a test target never runs this Mac's sudo")
}

/// The path is one of the list, whatever else the server prints (a login script, a hostile server): never its text.
@Test func sftpServerPathOnlyFromTheList() {
    #expect(SudoServer.pick(Data("Welcome!\n/usr/lib/ssh/sftp-server\n".utf8)) == "/usr/lib/ssh/sftp-server")
    #expect(SudoServer.pick(Data("/tmp/x/sftp-server\n/usr/lib/openssh/sftp-server2\n".utf8)) == nil)
    #expect(SudoServer.pick(Data(" /usr/lib/openssh/sftp-server\n".utf8)) == nil)
}

/// Root is never decoded: a pasted, dropped or restored target is its user. Root and user aren't the same server.
@Test func rootIsNeverDecoded() throws {
    let root = SFTPTarget(host: "me@web", port: 2222).asRoot()
    let back = try JSONDecoder().decode(SFTPTarget.self, from: JSONEncoder().encode(root))
    #expect(root.sudo && !back.sudo && back == root.asRoot(false))
    #expect(!String(decoding: try JSONEncoder().encode(root), as: UTF8.self).contains("sudo"))
    let local = SFTPTarget.local(sudo: "/tmp/fake", selinux: true)
    let localBack = try JSONDecoder().decode(SFTPTarget.self, from: JSONEncoder().encode(local))
    #expect(localBack.localSudo == nil && !localBack.localSELinux && localBack.localServer == nil && !localBack.sudo)
    #expect(!root.isSameServer(as: root.asRoot(false)) && root.isSameServer(as: SFTPTarget(host: "me@web", port: 2222).asRoot()))
}

/// End to end on this Mac's sftp-server through a stand-in sudo: the list finds it (macOS's own path), `sudo -n`
/// on it with nothing to read says it runs; then the session. The next session doesn't look again.
@Test func rootPanelListsAndSavesThroughSudo() throws {
    let d = rootTempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fake = try fakeSudo(d)
    let t = SFTPTarget.local(sudo: fake)
    try Data("old".utf8).write(to: URL(fileURLWithPath: d + "/f.conf"))
    #expect(try SFTP.list(t, d).map(\.name).contains("f.conf"))
    #expect(sudoLog(fake) == ["-n -- /usr/libexec/sftp-server", "-n -- /usr/libexec/sftp-server"], "the look, then the session")
    try Data("new".utf8).write(to: URL(fileURLWithPath: d + "/l"))
    let c = try SFTPClient(t)
    defer { c.close() }
    let a = try c.stat(d + "/f.conf")
    try c.upload(d + "/l", to: d + "/f.conf", baseline: a)
    #expect(FileManager.default.contents(atPath: d + "/f.conf") == Data("new".utf8))
    #expect(sudoLog(fake).count == 3, "known: no second look")
}
