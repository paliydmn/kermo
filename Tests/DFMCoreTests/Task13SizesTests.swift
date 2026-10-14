import Foundation
import Testing
@testable import DFMCore

// Task 13: folder sizes by the server's own `du` (`ServerSizes`).

/// GNU du 9.4 (uutils 0.8 says the same) and busybox 1.37 on a folder with an unreadable subfolder and a name that isn't there: each prints what it
/// could read, its complaints on stderr, and exits 1. A size with a complaint under it is "at least".
@Test func duAnswersAreReadWhateverTheExitStatus() {
    let names = ["a", "b", "missing"]
    let gnu = ServerSizes.parse("Welcome to the server\nkermo-sizes\n3349\ta\n500\tb\n", errors: """
        du: cannot read directory 'b/locked': Permission denied
        du: cannot access 'missing': No such file or directory
        """, status: 1, names: names)
    #expect(gnu == ["a": .init(bytes: 3349), "b": .init(bytes: 500, partial: true)])
    let busybox = ServerSizes.parse("kermo-sizes\n11541\ta\n12788\tb\n", errors: "\n\ndu: can't open 'b/locked': Permission denied\n\ndu: missing: No such file or directory\n",
                                    status: 1, names: names)
    #expect(busybox == ["a": .init(bytes: 11541), "b": .init(bytes: 12788, partial: true)])
    #expect(ServerSizes.parse("kermo-sizes\n0\ta\n", errors: "", status: 0, names: names) == ["a": .init(bytes: 0)])
}

/// Only the names asked for, and only after the script's own line (a login script may print "12\tx" too); a complaint
/// that points at none of them (a name du quotes its own way) makes every size "at least"; no line, no size.
@Test func duLinesAreMatchedByName() {
    let names = ["sp ace", "tab\there", "-rf", "it's"]
    let out = "12\tsp ace\nkermo-sizes\n7\tsp ace\n9\ttab\there\n5\t-rf\n3\tother\n2\tit's\nnot a number\tx\n"
    #expect(ServerSizes.parse(out, errors: "", status: 0, names: names)
            == ["sp ace": .init(bytes: 7), "tab\there": .init(bytes: 9), "-rf": .init(bytes: 5), "it's": .init(bytes: 2)])
    let odd = ServerSizes.parse(out, errors: "du: cannot read directory \"it's/x\": Permission denied", status: 1, names: names)
    #expect(odd.values.allSatisfy(\.partial) && odd.count == 4)
    #expect(ServerSizes.parse(out, errors: "du: cannot read directory 'it's/x'", status: 0, names: names).values.allSatisfy { !$0.partial },
            "exit 0: nothing went unread")
    #expect(ServerSizes.parse("12\ta\n", errors: "", status: 0, names: ["a"]).isEmpty, "no script line: nothing is du's")
}

/// A long list goes in several runs, each command line well under Linux's 128 KiB for one argument, in order.
@Test func manyNamesGoInSeveralRuns() {
    let names = (0..<20_000).map { "folder-\($0)'s" }
    let runs = ServerSizes.chunks(names)
    #expect(runs.count > 1 && Array(runs.joined()) == names)
    for run in runs {
        let line = "sh -c " + ShellContext.quote("set -- " + (["/srv"] + run).map(ShellContext.quote).joined(separator: " ") + "\n" + ServerSizes.script)
        #expect(line.utf8.count < 100_000)
    }
    #expect(ServerSizes.chunks([]) == [] && ServerSizes.chunks(["a"]) == [["a"]])
}

/// A server panel's status line says what's free there (`statvfs@openssh.com`: what `df` calls Available), asked in the
/// listing's own wave: the listing waits no more than before. A listing that fails drops the question with it.
@Test func freeSpaceRidesTheListingsWave() throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-free-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    for i in 0..<150 { FileManager.default.createFile(atPath: d + "/f\(i)", contents: nil) }
    let kept = KeptSession(.local())
    defer { kept.close() }
    _ = try SFTP.list(.local(), d, on: kept)
    let c = try #require(kept.client)
    var before = c.roundTrips
    _ = try SFTP.list(.local(), d, on: kept)
    let plain = c.roundTrips - before
    var free: Int64?
    before = c.roundTrips
    #expect(try SFTP.list(.local(), d, free: { free = $0 }, on: kept).count == 150)
    #expect(c.roundTrips - before == plain, "\(c.roundTrips - before) against \(plain)")
    var st = statvfs()
    #expect(statvfs(d, &st) == 0)
    let available = Int64(st.f_bavail) * Int64(st.f_frsize)
    #expect(abs((free ?? -1) - available) < 64 << 20, "\(String(describing: free)) against \(available)")

    #expect(throws: SFTPError.self) { try SFTP.list(.local(), d + "/gone", free: { _ in Issue.record("a failed listing says nothing") }, on: kept) }
    free = nil
    #expect(try SFTP.list(.local(), d, free: { free = $0 }, on: kept).count == 150 && free != nil)
    #expect(kept.client === c)
}

extension SudoPasswordTests {

/// A stand-in du first in PATH (`.local()`: this Mac's sh) answering as GNU du does: each name as given, one argument
/// each (spaces, a leading "-", a quote), stdout read though it exits 1, the unreadable one "at least". This Mac's own du
/// has no `-b`: no sizes (the walk). A root panel's goes through its sudo, `-n` first.
@Test func duRunsInTheFolderThere() throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-du-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d + "/bin", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    try Data("""
        #!/bin/sh
        [ "$1" = -slbx ] || exit 9
        [ "$2" = /dev/null ] && { printf '0\\t/dev/null\\n'; exit 0; }
        [ "$2" = -- ] || exit 9; shift 2
        [ "$(pwd -P)" = "$KERMO_WANT_DIR" ] || { echo "du: wrong folder $(pwd)" >&2; exit 9; }
        s=0
        for n; do
          [ "$n" = locked ] && { echo "du: cannot read directory 'locked/x': Permission denied" >&2; s=1; }
          [ "$n" = missing ] && { echo "du: cannot access 'missing': No such file or directory" >&2; s=1; continue; }
          printf '%s\\t%s\\n' "${#n}" "$n"
        done
        exit $s
        """.utf8).write(to: URL(fileURLWithPath: d + "/bin/du"))
    chmod(d + "/bin/du", 0o755)
    try FileManager.default.createDirectory(atPath: d + "/srv dir", withIntermediateDirectories: true)
    let env = ["PATH": d + "/bin:/usr/bin:/bin", "KERMO_WANT_DIR": d + "/srv dir"]
    let names = ["a b", "-rf", "it's", "locked", "missing"]
    let sizes = try ServerSizes.measure(names, in: d + "/srv dir", on: .local(), env: env)
    #expect(sizes == ["a b": .init(bytes: 3), "-rf": .init(bytes: 3), "it's": .init(bytes: 4), "locked": .init(bytes: 6, partial: true)])

    let fake = try fakeSudo(d)
    #expect(try ServerSizes.measure(["a b"], in: d + "/srv dir", on: .local(sudo: fake), env: env) == ["a b": .init(bytes: 3)])
    #expect(sudoLog(fake).first?.hasPrefix("-n -- sh -c ") == true)

    #expect(try ServerSizes.measure(["a b"], in: d + "/srv dir", on: .local(), env: ["KERMO_WANT_DIR": d + "/srv dir"]) == nil,
            "this Mac's du: no -b")
    let e = try #require(throws: SFTPError.self) { try ServerSizes.measure(["a"], in: d + "/nowhere", on: .local(), env: env) }
    #expect(e.message.contains("nowhere"))
}

/// ⎋ ends this side's ssh: `measure` is back at once. On a server du would go on (sshd sends it no signal, and it writes
/// nothing until it's done): the script's watcher finds its stderr closed and kills it. Here as there — the script in a
/// session of its own (this Mac's Process.terminate reaches the whole group), and only its pipes closed.
@Test(.timeLimit(.minutes(1))) func escStopsDuThere() async throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-du-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d + "/bin", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    try Data("""
        #!/bin/sh
        [ "$2" = /dev/null ] && exit 0
        echo $$ > "\(d)/pid"
        exec sleep 30
        """.utf8).write(to: URL(fileURLWithPath: d + "/bin/du"))
    chmod(d + "/bin/du", 0o755)
    let env = ["PATH": d + "/bin:/usr/bin:/bin"]
    let cancel = CancelFlag()
    Timeouts.queue.asyncAfter(deadline: .now() + 0.5) { cancel.cancel() }
    let started = Date()
    #expect(throws: CancellationError.self) { try ServerSizes.measure(["a"], in: d, on: .local(), env: env, cancel: cancel) }
    #expect(Date().timeIntervalSince(started) < 5)

    unlink(d + "/pid")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = ["-e", "setsid; exec @ARGV", "/bin/sh", "-c", "set -- \(ShellContext.quote(d)) a\n" + ServerSizes.script]
    p.environment = env
    let out = Pipe(), err = Pipe()
    (p.standardInput, p.standardOutput, p.standardError) = (FileHandle.nullDevice, out, err)
    try p.run()
    var pid: Int32?
    for _ in 0..<50 where pid == nil {
        pid = Int32(String(decoding: FileManager.default.contents(atPath: d + "/pid") ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        if pid == nil { try await Task.sleep(for: .milliseconds(100)) }
    }
    let du = try #require(pid)
    try out.fileHandleForReading.close()   // what sshd does once ssh is gone
    try err.fileHandleForReading.close()
    var gone = false
    for _ in 0..<50 where !gone {
        gone = kill(du, 0) != 0
        if !gone { try await Task.sleep(for: .milliseconds(100)) }
    }
    #expect(gone, "du \(du) still runs")
    if !gone { kill(du, SIGKILL) }
    p.waitUntilExit()
}

}
