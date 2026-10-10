import AppKit
import DFMCore
import Testing
@testable import DFileManager

/// R1: ⌘E history is kept per host: the local one (the key as before) and one per server (user@host:port), so `rm …`
/// typed on a server isn't offered locally or on another server.
@Test func commandHistoryIsKeyedByHost() {
    let web = SFTPTarget(host: "deploy@web"), db = SFTPTarget(host: "deploy@db")
    #expect(AppDelegate.historyKey(nil) == "cmdHistory")
    #expect(AppDelegate.historyKey(web) != "cmdHistory" && AppDelegate.historyKey(web) != AppDelegate.historyKey(db))
    #expect(AppDelegate.historyKey(web) == AppDelegate.historyKey(SFTPTarget(host: "deploy@web", port: 22)), "22 is the default port")
    #expect(AppDelegate.historyKey(web) != AppDelegate.historyKey(SFTPTarget(host: "deploy@web", port: 2222)))
}

/// R1: on a production server rm, mv, chmod, chown, dd and systemctl stop / restart ask first — also behind sudo, env,
/// command, exec, time, their options, VAR=value and a path (also sudo's and env's own: /usr/bin/sudo rm), and as
/// `\rm` (past an alias); status, ls or a word inside the arguments don't.
@Test func dangerousCommandsAreSpottedBehindSudoAndEnv() {
    for c in ["rm -rf build", "sudo rm -- 'a b'", "sudo -u www rm x", "sudo -n -u www /bin/rm x", "env FOO=1 rm x", "FOO=1 rm x",
              "mv a b", "chmod +x deploy.sh", "chown -R www:www /srv", "dd if=/dev/zero of=/dev/sda", "systemctl stop nginx",
              "sudo systemctl --no-block restart nginx", "  rm x", "/usr/bin/sudo rm -rf x", "/usr/bin/env rm x", "sudo -E /usr/bin/env rm x",
              "FOO=/usr/bin rm x", "\\rm x", "sudo \\rm -rf x", "command rm x", "exec rm x", "time rm -r x", "/usr/bin/time rm x"] {
        #expect(Shell.isDangerous(c), Comment(rawValue: c))
    }
    for c in ["ls -la", "systemctl status nginx", "sudo systemctl reload nginx", "echo rm", "grep -r rm .", "rmdir x", "cat chmod.log",
              "git rm --cached x", "", "sudo", "FOO=1", "/usr/bin/sudo ls", "FOO=/usr/bin ls", "\\ls", "time ls"] {
        #expect(!Shell.isDangerous(c), Comment(rawValue: c))
    }
}

/// P15: a UTF-8 character cut by a pipe read shows whole once the rest arrives, not as U+FFFD — wherever the cut
/// falls, in stdout and stderr alike; a truly bad byte still shows as U+FFFD when the stream ends.
@Test func outputCutInsideAUTF8CharacterIsShownWhole() {
    let text = "héllo wörld — 😀 ⌘E\n"
    let bytes = Array(text.utf8)
    for cut in 0...bytes.count {
        var rest = Data()
        let out = utf8Chunk(Data(bytes[..<cut]), rest: &rest) + utf8Chunk(Data(bytes[cut...]), rest: &rest) + utf8Chunk(Data(), rest: &rest)
        #expect(out == text, "cut at \(cut)")
    }
    var rest = Data()
    var out = ""
    for b in bytes { out += utf8Chunk(Data([b]), rest: &rest) }   // a byte at a time
    #expect(out + utf8Chunk(Data(), rest: &rest) == text)

    rest = Data()
    out = utf8Chunk(Data([0x61, 0xFF, 0x62]), rest: &rest)
    #expect(out == "a\u{FFFD}b" && rest.isEmpty, "a bad byte in the middle")
    out = utf8Chunk(Data([0x63, 0xE2, 0x82]), rest: &rest)
    #expect(out == "c" && rest.count == 2, "an unfinished character waits")
    #expect(utf8Chunk(Data(), rest: &rest) == "\u{FFFD}" && rest.isEmpty, "…and shows as U+FFFD at the end of the stream")
}

/// Runs `command` in an output window; returns the shell's pid (its process group's id) and the window.
@MainActor private func start(_ command: String, pidFile: String, onExit: @escaping @MainActor (Int32) -> Void = { _ in }) async throws -> (pid: pid_t, window: NSWindow) {
    Shell.run("echo $$ > \(ShellContext.quote(pidFile)); " + command, in: NSTemporaryDirectory(), onExit: onExit)
    let window = try #require(NSApp.windows.first { $0.isVisible && $0.title.hasSuffix(command) })
    for _ in 0..<100 {
        if let pid = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap({ pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            return (pid, window)
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw CancellationError()
}

@MainActor private func groupGone(_ pid: pid_t, within polls: Int = 60) async -> Bool {
    for _ in 0..<polls {
        if killpg(pid, 0) == -1 { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// P15, one test (the quit half SIGTERMs every output window, so no other may be running then): "[exit N]" and the
/// exit callback come after the last output, even from a child that outlives the shell by a moment — but a child
/// that keeps the pipe (`sleep 30 &`, `./server &`) holds them only half a second; closing the output window, and
/// quitting, end the whole process group — what the shell started too, also what it left behind after exiting —
/// with a SIGKILL for whatever ignores the SIGTERM (quitting waits for it: there's no run loop after
/// applicationWillTerminate), a window closed moments before quitting included; the quit confirmation counts the
/// windows whose command (or its leftover) still runs.
@MainActor @Test func exitComesAfterTheLastOutputAndClosingOrQuittingEndsTheProcessGroup() async throws {
    _ = NSApplication.shared
    let late = "(sleep 0.1; echo last) & exit 3"
    let status: Int32 = await withCheckedContinuation { cont in
        Shell.run(late, in: NSTemporaryDirectory()) { cont.resume(returning: $0) }
    }
    let lateWindow = try #require(NSApp.windows.first { $0.isVisible && $0.title.hasSuffix(late) })
    let text = try #require(((lateWindow.contentView as? NSScrollView)?.documentView as? NSTextView)?.string)
    lateWindow.close()
    #expect(status == 3 && text == "last\n\n[exit 3]\n", Comment(rawValue: text))

    let dir = NSTemporaryDirectory() + "dfm-review9-cmdline-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let command = "trap '' HUP TERM; sleep 30 & sleep 30; wait"

    let closed = try await start(command, pidFile: dir + "/closed.pid")
    defer { killpg(closed.pid, SIGKILL) }
    closed.window.close()
    #expect(await groupGone(closed.pid), "closing the window")

    // The shell exits at once, a child of it keeps the group and the pipe: the exit callback comes anyway, the
    // confirmation counts the window, closing it ends the child.
    var exit: Int32?
    let orphan = try await start("sleep 30 & exit 3", pidFile: dir + "/orphan.pid") { exit = $0 }
    defer { killpg(orphan.pid, SIGKILL) }
    for _ in 0..<40 where exit == nil { try await Task.sleep(for: .milliseconds(50)) }
    #expect(exit == 3, "reported half a second after the exit, not when the child ends")
    for _ in 0..<40 where kill(orphan.pid, 0) == 0 { try await Task.sleep(for: .milliseconds(50)) }   // the shell is reaped…
    try #require(kill(orphan.pid, 0) == -1 && killpg(orphan.pid, 0) == 0, "…the group lives on")
    #expect(Shell.busy == "1 command running in an output window (a split or combine stops part way)")
    orphan.window.close()
    #expect(await groupGone(orphan.pid), "closing the window after the shell is gone")
    #expect(Shell.busy == nil)

    let stopping = try await start(command, pidFile: dir + "/stopping.pid")
    defer { killpg(stopping.pid, SIGKILL) }
    let quit = try await start(command, pidFile: dir + "/quit.pid")
    defer { killpg(quit.pid, SIGKILL); quit.window.close() }
    #expect(Shell.busy == "2 commands running in an output window (a split or combine stops part way)")
    stopping.window.close()   // ignores the SIGTERM: its SIGKILL would come in 2 s — quitting doesn't wait that long
    Shell.terminateAll()
    #expect(await groupGone(quit.pid, within: 10), "quitting")
    #expect(await groupGone(stopping.pid, within: 10), "quitting, a window closed just before")
    #expect(Shell.busy == nil)
}
