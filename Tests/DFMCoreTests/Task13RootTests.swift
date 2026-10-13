import Foundation
import Testing
@testable import DFMCore

// Task 13: a server panel as root (`SFTPTarget.sudo`).

/// A stand-in for a server's sudo: logs its arguments next to itself, then runs what follows `-n --`.
func fakeSudo(_ dir: String, _ body: String = #"[ "$1" = -n ] && [ "$2" = -- ] || exit 2; shift 2; exec "$@""#) throws -> String {
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
    #expect(SudoServer.launch(t, path: "/usr/lib/openssh/sftp-server", password: true).arguments.last == "sudo -S -p '' -k -- /usr/lib/openssh/sftp-server",
            "`-p ''`: an empty prompt, not `-p -k`")
    #expect(SudoServer.probe(t).contains("[ -d /sys/fs/selinux ] && echo kermo-selinux"))
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

/// `SFTP.sudoPassword` and `SudoServer.versionWait` are global: the tests that set them or need them unset take turns.
/// So do the rest that run processes: together they start dozens of `sh`, stand-in sudos and sftp-servers, and next
/// to the whole suite that pushed its 5-second timing tests over (`connectingCanBeCancelled` and the like).
@Suite(.serialized) struct SudoPasswordTests {

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

/// ⌘S from a root panel: the same `upload` as the user's panel — 8 round trips for a 2 KB file opened with F4, the
/// new text renamed over it. With SELinux on the server (`/sys/fs/selinux`, looked at with sftp-server's path) it
/// writes into the file itself (the same inode keeps its label): 12 round trips — copied into on the server, as a
/// symlink's (13: one more to follow it) or another owner's file always was. Measured on the code before: 8 and 13.
@Test func rootSaveWritesInPlaceUnderSELinux() throws {
    let d = rootTempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    func put(_ p: String, _ b: UInt8) throws { try Data(repeating: b, count: 2048).write(to: URL(fileURLWithPath: p)) }
    func inode(_ p: String) -> ino_t { var st = stat(); lstat(p, &st); return st.st_ino }
    func save(_ t: SFTPTarget, _ name: String, link: Bool = false) throws -> (trips: Int, inPlace: Bool, flag: Bool) {
        let file = d + "/" + name
        try put(link ? file + ".real" : file, 1)
        if link { try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: file + ".real") }
        let c = try SFTPClient(t)
        defer { c.close() }
        let a = try c.download(file, to: d + "/l" + name)   // F4: the baseline has its SHA-256
        try put(d + "/l" + name, 2)
        let ino = inode(link ? file + ".real" : file), before = c.roundTrips
        try c.upload(d + "/l" + name, to: file, baseline: a) { _, _ in }   // the app keeps the version it replaces
        #expect(FileManager.default.contents(atPath: file) == Data(repeating: 2, count: 2048))
        return (c.roundTrips - before, inode(link ? file + ".real" : file) == ino, c.writesInPlace)
    }
    let user = try save(.local(), "user")
    let root = try save(.local(sudo: try fakeSudo(d)), "root")
    let selinux = try save(.local(sudo: try fakeSudo(d), selinux: true), "selinux")
    let link = try save(.local(), "link", link: true)
    #expect(user.trips == 8 && !user.inPlace && !user.flag)
    #expect(root.trips == 8 && !root.inPlace && !root.flag, "root without SELinux: renamed, as the user's")
    #expect(selinux.trips == 12 && selinux.inPlace && selinux.flag, "the partial file, copied into the file, removed; no rename")
    #expect(link.trips == 13 && link.inPlace, "as before")
}

/// sudo's refusals in plain words, told apart by exit status and text: each "needs a password" (sudo 1.8/1.9,
/// sudo-rs 0.2.13, 0.2.2), requiretty, anything else as sudo said it. Exit 0 runs, whatever it says on stderr.
/// Without a way to ask (no app): "needs a password", with the sudoers line that allows it without one.
@Test func sudoRefusalsInPlainWords() throws {
    let d = rootTempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    func connect(_ body: String) throws -> [String] {
        let fake = try fakeSudo(d, body)
        let c = try SFTPClient(.local(sudo: fake))
        c.close()
        return sudoLog(fake)
    }
    func refusal(_ body: String) -> String {
        do { _ = try connect(body); return "connected" } catch let e as SFTPError { return e.connection ? e.message : "not a connection error" } catch { return "\(error)" }
    }
    for text in ["sudo: a password is required", "sudo: interactive authentication is required", "sudo-rs: authentication failed: interaction required"] {
        let m = refusal("echo '\(text)' >&2; exit 1")
        #expect(m.hasPrefix("sudo on localhost needs a password") && m.hasSuffix("<user> ALL=(root) NOPASSWD: /usr/libexec/sftp-server"), "\(text): \(m)")
    }
    #expect(refusal("echo 'sudo: sorry, you must have a tty to run sudo' >&2; exit 1").contains("Defaults requiretty"))
    #expect(refusal("echo 'sudo: no such user' >&2; exit 1") == "sudo on localhost didn't run sftp-server: sudo: no such user")
    #expect(refusal("exit 3") == "sudo on localhost didn't run sftp-server: exit 3")
    // Lecture, warnings, even a "password" text: exit 0 and VERSION are what count.
    #expect(try connect("echo 'We trust you have received the usual lecture' >&2; echo 'sudo: a password is required' >&2; exec \"$3\"").count == 2)
    // The look said yes, the session says no (sudoers changed in between): the same words, and it looks again next time.
    let flip = try fakeSudo(d, #"n=$(wc -l < "$0.log"); [ $n -le 1 ] && exec "$3"; echo "sudo: a password is required" >&2; exit 1"#)
    let said = #expect(throws: SFTPError.self) { try SFTPClient(.local(sudo: flip)) }
    #expect(said?.message.hasPrefix("sudo on localhost needs a password") == true && said?.connection == true)
    #expect((try? SFTPClient(.local(sudo: flip))) == nil)
    #expect(sudoLog(flip).count == 3, "the look, the session that failed, the look again (it fails there now)")
}

/// sudo that wants a password: `-n` refuses as sudo 1.9 does; `-S -p '' -k` reads exactly one line, then runs what
/// follows `--`. Its log has its arguments, never what it read.
static let passwordSudo = #"""
    case "$1" in
    -n) echo "sudo: a password is required" >&2; exit 1;;
    -S) [ "$2" = -p ] && [ "$3" = "" ] && [ "$4" = -k ] && [ "$5" = -- ] || exit 2
        IFS= read -r pw; [ "$pw" = "kermo-test-pw" ] || { echo "Sorry, try again." >&2; echo "sudo: 1 incorrect password attempt" >&2; exit 1; }
        shift 5; exec "$@";;
    esac
    exit 2
    """#

/// Asks give these answers in turn; what each ask was told (wrong or not) and what sudo took.
final class Answers: @unchecked Sendable {
    var left: [String?], wrong: [Bool] = [], taken: [String] = []
    init(_ a: [String?]) { left = a }
}
static func answering(_ a: Answers, _ body: () throws -> Void) rethrows {
    SFTP.sudoPassword = { _, wrong in a.wrong.append(wrong); return a.left.isEmpty ? nil : a.left.removeFirst() }
    SFTP.sudoPasswordTaken = { _, p in a.taken.append(p) }
    defer { SFTP.sudoPassword = nil; SFTP.sudoPasswordTaken = nil }
    try body()
}

/// Only when `-n` refused for want of one: the password is asked for, tried alone with the session's own command (one
/// line, end of file: sftp-server ends at once), then the session reads it as a line before INIT. Never in an
/// argument. Not remembered as a server that needs none.
@Test func sudoWithAPassword() throws {
    let d = rootTempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fake = try fakeSudo(d, Self.passwordSudo)
    let a = Answers(["kermo-test-pw"])
    try Self.answering(a) {
        #expect(try SFTP.list(.local(sudo: fake), d).map(\.name).contains((fake as NSString).lastPathComponent))
        #expect(a.wrong == [false] && a.taken == ["kermo-test-pw"])
        #expect(sudoLog(fake) == ["-n -- /usr/libexec/sftp-server", "-S -p  -k -- /usr/libexec/sftp-server", "-S -p  -k -- /usr/libexec/sftp-server"])
        a.left = ["kermo-test-pw"]
        _ = try SFTP.list(.local(sudo: fake), d)
        #expect(sudoLog(fake).count == 6 && a.wrong == [false, false], "`-n` again first: a password needed once isn't assumed")
    }
    #expect(!(try String(contentsOfFile: fake + ".log", encoding: .utf8)).contains("kermo-test-pw"))
}

/// A wrong one costs one sudo attempt and asks again (told it was wrong); three, as sudo's own, then sudo's own words;
/// Cancel stops at once and cancels what asked (a job's next item doesn't ask again).
@Test func wrongSudoPasswordAsksAgain() throws {
    let d = rootTempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fake = try fakeSudo(d, Self.passwordSudo)
    let a = Answers(["nope", "kermo-test-pw"])
    try Self.answering(a) {
        _ = try SFTP.list(.local(sudo: fake), d)
        #expect(a.wrong == [false, true] && a.taken == ["kermo-test-pw"] && sudoLog(fake).filter { $0.hasPrefix("-S") }.count == 3, "2 checks, the session")

        let three = try fakeSudo(d, Self.passwordSudo)
        a.left = ["a", "b", "c", "kermo-test-pw"]
        a.wrong = []
        let e = #expect(throws: SFTPError.self) { try SFTPClient(.local(sudo: three)) }
        #expect(e?.message == "sudo on localhost refused the password 3 times: Sorry, try again.\nsudo: 1 incorrect password attempt" && a.wrong == [false, true, true])
        #expect(sudoLog(three).filter { $0.hasPrefix("-S") }.count == 3, "3 checks, no session")

        let cancel = try fakeSudo(d, Self.passwordSudo)
        a.left = [nil]
        let flag = CancelFlag()
        #expect(throws: CancellationError.self) { try SFTPClient(.local(sudo: cancel), cancel: flag) }
        #expect(sudoLog(cancel) == ["-n -- /usr/libexec/sftp-server"] && flag.isCancelled, "nothing sent; what asked is cancelled")

        // A copy from a root panel: Cancel on the sheet ends the job, no Retry / Skip / Abort, not asked per item.
        let job = FileJob(.copy, sources: [d + "/a", d + "/b"], from: .sftp(.local(sudo: try fakeSudo(d, Self.passwordSudo))), to: .local, destDir: d + "/down")
        let prompts = Answers([])
        job.resolveError = { _, _ in prompts.wrong.append(true); return (.skip, false) }
        a.left = [nil, nil, nil]
        a.wrong = []
        job.run()
        #expect(job.isCancelled && prompts.wrong.isEmpty && a.wrong.count == 1, "asked \(a.wrong.count) times")
    }
}

/// The password sudo took, but sftp-server isn't allowed to the user (e.g. all their rules are NOPASSWD for other
/// commands, where `sudo -v` would pass without reading a thing): sudo's own words at once, not asked 3 times.
@Test func sudoThatRefusesTheCommandSaysWhy() throws {
    let d = rootTempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fake = try fakeSudo(d, #"""
        [ "$1" = -n ] && { echo "sudo: a password is required" >&2; exit 1; }
        IFS= read -r pw; echo "Sorry, user me is not allowed to execute '$6' as root on web." >&2; exit 1
        """#)
    let a = Answers(["kermo-test-pw", "kermo-test-pw", "kermo-test-pw"])
    try Self.answering(a) {
        let e = #expect(throws: SFTPError.self) { try SFTPClient(.local(sudo: fake)) }
        #expect(e?.message == "sudo on localhost refused: Sorry, user me is not allowed to execute '/usr/libexec/sftp-server' as root on web.")
        #expect(a.wrong == [false] && a.taken.isEmpty)
    }
}

/// NOPASSWD: the password is never asked for, never sent (sudo wouldn't read it: it would go to sftp-server).
@Test func noPasswordAskedWhereSudoNeedsNone() throws {
    let d = rootTempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let fake = try fakeSudo(d)
    let a = Answers(["kermo-test-pw"])
    try Self.answering(a) { _ = try SFTP.list(.local(sudo: fake), d) }
    #expect(a.wrong.isEmpty && a.taken.isEmpty && !sudoLog(fake).contains { $0.hasPrefix("-S") })
}

/// sudo-rs 0.2.2 has no `-p` (and would read all of stdin): its "invalid option" isn't a wrong password — set up
/// NOPASSWD instead. A sudo that takes the check but swallows the session's stdin: the same words after `versionWait`.
@Test func sudoThatCantTakeAPasswordLineSaysNOPASSWD() throws {
    let d = rootTempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    let old = try fakeSudo(d, #"""
        [ "$1" = -n ] && { echo "sudo-rs: authentication failed: interaction required" >&2; exit 1; }
        echo "sudo-rs: invalid option provided" >&2; echo "usage: sudo -h | -K | -k | -V" >&2; exit 1
        """#)
    let a = Answers(["kermo-test-pw", "kermo-test-pw"])
    try Self.answering(a) {
        let e = #expect(throws: SFTPError.self) { try SFTPClient(.local(sudo: old)) }
        #expect(e?.message.contains("can't take a password from Kermo") == true && e?.message.hasSuffix("NOPASSWD: /usr/libexec/sftp-server") == true)
        #expect(a.wrong == [false], "asked once: not a wrong password")

        let swallow = try fakeSudo(d, #"""
            [ "$1" = -n ] && { echo "sudo: a password is required" >&2; exit 1; }
            IFS= read -r pw; [ $(wc -l < "$0.log") -le 2 ] && exec "$6"; exec cat >/dev/null
            """#)   // the check (2nd call) runs sftp-server; the session's stdin is swallowed
        let was = SudoServer.versionWait
        SudoServer.versionWait = 1
        defer { SudoServer.versionWait = was }
        let started = Date()
        let late = #expect(throws: SFTPError.self) { try SFTPClient(.local(sudo: swallow)) }
        #expect(late?.message.contains("can't take a password from Kermo") == true && Date().timeIntervalSince(started) < 5)
    }
}
}

/// No sftp-server in the list: said so, with Alpine's way to get one. Whatever the probe printed besides doesn't count.
@Test func sftpServerNotFoundSaysWhere() throws {
    let t = SFTPTarget(host: "me@alpine").asRoot()
    #expect(throws: SFTPError.self) { try SudoServer.check(t, Data("motd\n".utf8), 127, "") }
    do { _ = try SudoServer.check(t, Data(), 127, "") } catch let e as SFTPError {
        #expect(e.connection && e.message.hasPrefix("sftp-server not found on me@alpine") && e.message.contains("apk add openssh-sftp-server"))
    } catch { Issue.record("\(error)") }
    #expect(SudoServer.explain(t, path: "/usr/lib/ssh/sftp-server", "sudo: a password is required")?.hasSuffix("me ALL=(root) NOPASSWD: /usr/lib/ssh/sftp-server") == true)
    #expect(try SudoServer.check(t, Data("/usr/lib/ssh/sftp-server\n".utf8), 0, "unknown setting: 'requiretty'") == "/usr/lib/ssh/sftp-server", "sudo-rs warns and runs")
}

