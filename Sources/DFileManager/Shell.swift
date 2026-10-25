import AppKit
import DFMCore

/// Runs shell commands in an output window (⌘E ⇧↩, a server panel's ⌘E, tar / diff / git) or hands them to the
/// terminal app (⌘↩). ⌘E ↩ on a local panel types into the ⌃O shell instead: `EmbeddedTerminal.run`.
@MainActor
enum Shell {
    /// Login shell, so PATH matches what the user has in their terminal (Homebrew etc.).
    /// `onExit` gets the exit status.
    /// `title`: what it does, for the window, in place of the command line. `failed`: said under it if it fails.
    static func run(_ command: String, in dir: String, diff: Bool = false, title: String? = nil, failed: String? = nil,
                    onExit: @escaping @MainActor (Int32) -> Void = { _ in }) {
        OutputWindow.start(command, in: dir, on: nil, diff: diff, title: title, failed: failed, onExit: onExit)
    }

    /// On a server, in its folder `dir`, over the panel's ssh connection (the login shell there runs it). `follow`: a
    /// simple command that runs until stopped (`journalctl -f`), which then ends there too (`SSHCommand.endsWithSSH`).
    static func run(_ command: String, on server: SFTPTarget, in dir: String, follow: Bool = false, title: String? = nil,
                    onExit: @escaping @MainActor (Int32) -> Void = { _ in }) {
        OutputWindow.start(command, in: dir, on: server, diff: false, follow: follow, title: title, onExit: onExit)
    }

    /// One command on several servers (Run on Servers…), in one output window: each line as it comes, "web1 │ …", stderr
    /// in red; then the summary. ⎋ stops them all and keeps the window; again, closes it. `ended`: each server's outcome
    /// (its index in `servers`) as soon as it's known — whatever becomes of the window. `skipped`: named in the summary
    /// (locked, Touch ID refused). `again`: ⌘R once it's over (given this window, for a question); true — it started
    /// again, in a window of its own — closes this one.
    static func run(_ command: String, on servers: [MultiRun.Server], skipped: [String], env: [String: String], title: String,
                    again: (@MainActor (NSWindow?) async -> Bool)? = nil, ended: @escaping @MainActor (Int, MultiRun.Outcome) -> Void) {
        OutputWindow.start(command, on: servers, skipped: skipped, env: env, title: title, again: again, ended: ended)
    }

    /// What the server's login shell runs for `command` in `dir`: a follow wrapped to end with ssh (its stdin then a
    /// pipe held open, see `OutputWindow`).
    static func remote(_ command: String, in dir: String, follow: Bool) -> String {
        SSHCommand.inDir(dir, follow ? SSHCommand.endsWithSSH(command) : command)
    }

    /// Fire-and-forget (GUI tools like `code --diff`): no output window.
    static func spawn(_ command: String, in dir: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// At quit: what the output windows run (`tail -f`, a `| grep` pipeline) ends with the app.
    static func terminateAll() { OutputWindow.terminateAll() }
    /// For the quit confirmation: the output windows whose command (or what it left behind) still runs, or nil.
    static var busy: String? { OutputWindow.busy }

    /// R1: a command that removes, moves, re-owns, truncates or stops things, which asks first on a production server:
    /// `rm`, `mv`, `chmod`, `chown`, `dd`, `truncate`, `shred`, `unlink`, `find … -delete / -exec`, `rsync --delete`,
    /// `git clean / reset --hard`, `systemctl stop|restart|disable|mask|kill`, and `> file` — in any command of a list
    /// or pipeline (`cd x && rm -rf y`, `ls; rm x`, `… | xargs rm`, `$(…)`), behind sudo / doas / env / xargs, their
    /// options, VAR=value and a path (/bin/rm). Quotes aren't parsed: a separator inside them asks once too often.
    nonisolated static func isDangerous(_ command: String) -> Bool {
        command.components(separatedBy: CharacterSet(charactersIn: ";&|\n()`")).contains(where: isDangerousOne) || writesOver(command)
    }

    private nonisolated static func isDangerousOne(_ command: String) -> Bool {
        var words = command.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        let name = { (w: String) in (w as NSString).lastPathComponent }   // /usr/bin/sudo, /bin/rm
        var takesValue = ["-u", "-g"]   // `sudo -u www rm …`
        while let w = words.first, ["sudo", "doas", "env", "nohup", "command", "exec", "time", "xargs"].contains(name(w)) || w.hasPrefix("-") || w.contains("=") {
            if name(w) == "xargs" { takesValue = ["-I", "-n", "-P", "-L", "-s", "-E"] }   // `xargs -I {} rm {}`
            words = words.dropFirst(takesValue.contains(w) ? 2 : 1)
        }
        guard let first = words.first.map({ String(name($0).drop(while: { $0 == "\\" })) }) else { return false }   // `\rm`: past the alias
        let rest = words.dropFirst()
        switch first {
        case "systemctl": return rest.first { !$0.hasPrefix("-") }.map { ["stop", "restart", "disable", "mask", "kill"].contains($0) } == true
        case "find": return rest.contains { ["-delete", "-exec", "-execdir", "-ok"].contains($0) }
        case "rsync": return rest.contains { $0.hasPrefix("--delete") || $0 == "--remove-source-files" }
        case "git":
            let sub = rest.first { !$0.hasPrefix("-") }
            return sub == "clean" || sub == "reset" && rest.contains("--hard")
        default: return ["rm", "mv", "chmod", "chown", "dd", "truncate", "shred", "unlink"].contains(first)
        }
    }

    /// `> file` (not `>>`, `>&2`, nor into /dev/null): the file is emptied before the command even runs.
    private nonisolated static func writesOver(_ command: String) -> Bool {
        let c = Array(command)
        for i in c.indices where c[i] == ">" && (i == 0 || c[i - 1] != ">") {
            let after = c[(i + 1)...]
            if after.first == ">" || after.first == "&" { continue }
            let target = String(after.drop { $0 == " " || $0 == "\t" }.prefix { !$0.isWhitespace && !";&|)".contains($0) })
            if !target.isEmpty && target != "/dev/null" { return true }
        }
        return false
    }

    static func runInTerminal(_ command: String, in dir: String, terminalApp: URL) {
        let script = "#!/bin/zsh -l\ncd \(ShellContext.quote(dir)) || exit 1\n\(command)\necho\nexec $SHELL -l\n"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dfm-command-\(UUID().uuidString).command")   // swept a day later (TempCopies)
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o700)
            NSWorkspace.shared.open([url], withApplicationAt: terminalApp, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Appends output from a pty (sftp's progress meter): CRLF line ends, a lone CR redraws the current line,
/// and `script` echoes the EOF of its empty stdin as "^D" + 2 backspaces. A chunk ending in CR may be the
/// first half of a CRLF, so that CR waits in `pendingCR` for the next chunk.
func appendTerminalOutput(_ chunk: String, to storage: NSTextStorage, pendingCR: inout Bool, attributes: [NSAttributedString.Key: Any]) {
    var s = (pendingCR ? "\r" : "") + chunk
    pendingCR = s.hasSuffix("\r")
    if pendingCR { s.removeLast() }
    s = s.replacingOccurrences(of: "^D\u{8}\u{8}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
    for (i, part) in s.components(separatedBy: "\r").enumerated() {
        if i > 0 {
            let text = storage.string as NSString
            let newline = text.range(of: "\n", options: .backwards).location
            let from = newline == NSNotFound ? 0 : newline + 1
            storage.deleteCharacters(in: NSRange(location: from, length: text.length - from))
        }
        storage.append(NSAttributedString(string: part, attributes: attributes))
    }
}

/// `data` as text up to its last whole UTF-8 character: a character the read cut waits in `rest` and is finished by the
/// next chunk. Empty `data` is the end of the stream: what's left shows as is (a really bad byte: U+FFFD).
func utf8Chunk(_ data: Data, rest: inout Data) -> String {
    let all = rest + data
    let end = data.isEmpty ? all.count : FollowReader.utf8Boundary(all)
    rest = Data(all.dropFirst(end))
    return String(decoding: all.prefix(end), as: UTF8.self)
}

/// Output read off the pipes and not shown yet, per stream (stdout, stderr): a chatty command hops to the main thread
/// once per batch, not once per read.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    /// In the order read — an error line stays next to the output around it. Empty data: that stream's EOF.
    private var parts: [(stream: Int, data: Data)] = [], scheduled = false
    /// While the main thread is busy (a sheet, a slow Keychain) a firehose (`cat /dev/urandom | base64`) piled up
    /// here without end. Past `limit` the oldest pieces go, as the window drops its oldest lines anyway (`trimmed`).
    static let limit = 8 << 20
    private var bytes = 0, cut = false
    private(set) var peak = 0

    /// Adds a read (empty: EOF); true if the main thread has to be asked to take it.
    func put(_ d: Data, _ stream: Int) -> Bool {
        lock.withLock {
            // Pieces of up to 1 MB: the oldest go whole, nothing is copied to cut one.
            if !d.isEmpty, let last = parts.last, last.stream == stream, !last.data.isEmpty, last.data.count < 1 << 20 {
                parts[parts.count - 1].data.append(d)
            } else { parts.append((stream, d)) }
            bytes += d.count
            while bytes > Self.limit, let i = parts.firstIndex(where: { !$0.data.isEmpty }) {   // an EOF stays
                bytes -= parts.remove(at: i).data.count
                cut = true
            }
            peak = max(peak, bytes)
            defer { scheduled = true }
            return !scheduled
        }
    }

    /// What's there, and whether some of it went (`limit`).
    func take() -> (parts: [(stream: Int, data: Data)], cut: Bool) {
        lock.withLock {
            defer { parts = []; bytes = 0; cut = false; scheduled = false }
            return (parts, cut)
        }
    }
}

/// An output window, seeing its key equivalents before the main menu does (⌘R is Refresh there).
private final class KeyWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool { onKey?(event) == true || super.performKeyEquivalent(with: event) }
}

/// Lines of several servers (`MultiRun`) read off their pipes and not shown yet: the main thread takes them in batches.
private final class LineInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(server: Int, text: String, error: Bool)] = [], scheduled = false

    /// True if the main thread has to be asked to take it.
    func put(_ line: (Int, String, Bool)) -> Bool {
        lock.withLock {
            lines.append(line)
            defer { scheduled = true }
            return !scheduled
        }
    }

    func take() -> [(server: Int, text: String, error: Bool)] {
        lock.withLock {
            defer { lines = []; scheduled = false }
            return lines
        }
    }
}

@MainActor
final class OutputWindow: NSWindowController, NSWindowDelegate {
    private static var open: [OutputWindow] = []
    private let process = Process()
    private let started = Date()
    /// Run on Servers': stops them all — no process of the window's own then.
    private var servers: CancelFlag?
    /// Set once they're all over: what `alive` reads, also at quit (no run loop to hear it then).
    private let over = CancelFlag()

    static func start(_ command: String, in dir: String, on server: SFTPTarget?, diff: Bool, follow: Bool = false, title: String?,
                      failed: String? = nil, onExit: @escaping @MainActor (Int32) -> Void) {
        let w = OutputWindow(command, dir, server, diff, follow, failed, onExit)
        if let title { w.window?.title = title.bidiVisible }
        open.append(w)
        w.showWindow(nil)
    }

    static func start(_ command: String, on servers: [MultiRun.Server], skipped: [String], env: [String: String], title: String,
                      again: (@MainActor (NSWindow?) async -> Bool)?, ended: @escaping @MainActor (Int, MultiRun.Outcome) -> Void) {
        let w = OutputWindow(servers, skipped: skipped, command: command, env: env, again: again, ended: ended)
        w.window?.title = title.bidiVisible
        open.append(w)
        w.showWindow(nil)
    }

    /// The window and its text view, empty.
    private static func window() -> (KeyWindow, NSTextView) {
        let w = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.usesFindBar = true
        w.contentView = scroll
        w.center()
        w.setFrameAutosaveName("Output")
        return (w, tv)
    }

    /// A follow's stdin, held open while its ssh runs and never written (`SSHCommand.endsWithSSH`).
    private var held: FileHandle?

    private init(_ command: String, _ dir: String, _ server: SFTPTarget?, _ diff: Bool, _ follow: Bool, _ failed: String?,
                 _ onExit: @escaping @MainActor (Int32) -> Void) {
        let place = server.map { "\($0.host):\(dir)" } ?? (dir as NSString).abbreviatingWithTildeInPath
        let (w, tv) = Self.window()
        w.title = (server.map { "\($0.host) $ " } ?? "$ ") + command.bidiVisible
        w.subtitle = place + " · running… · ⎋ Stop"
        super.init(window: w)
        w.delegate = self

        if let server {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = SSHCommand.arguments(server, command: Shell.remote(command, in: dir, follow: follow), tty: false)
            process.environment = ProcessInfo.processInfo.environment.merging(SSHAskpass.env) { $1 }
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }
        if server != nil, follow {
            let input = Pipe()
            process.standardInput = input
            held = input.fileHandleForWriting
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inbox = inbox
        for (pipe, stream) in [(out, 0), (err, 1)] {
            let h = pipe.fileHandleForReading, fd = h.fileDescriptor   // fileDescriptor raises once the handle is closed
            // POSIX read: FileHandle.availableData raises (an uncatchable ObjC exception) on some read errors.
            Thread { [weak self] in
                var buf = [UInt8](repeating: 0, count: 1 << 16)
                while true {
                    let n = Darwin.read(fd, &buf, buf.count)
                    if n < 0 && errno == EINTR { continue }
                    // Empty: EOF, or a read error — the stream's end either way.
                    if inbox.put(n > 0 ? Data(buf[0..<n]) : Data(), stream) {   // else a hop is on its way: it takes this too
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.drain(in: tv) } }
                    }
                    if n <= 0 { break }
                }
                try? h.close()
            }.start()
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.status = status; try? self?.held?.close(); self?.ended() } }
            // A child that keeps a pipe (`./server &`) would hold the report forever: half a second after the exit it comes anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self?.ended(now: true) } }
        }
        report = { [weak self] in
            guard let self else { return }
            let secs = String(format: "%.1fs", Date().timeIntervalSince(self.started))
            self.window?.subtitle = place + " · exit \(self.status) · \(secs)" + (self.trimmed ? " · only the last 4 MB kept" : "") + " · ⎋ Close"
            if diff {
                // diff exits 1 when files differ — that's the normal case, not an error.
                Self.colorizeDiff(tv)
                if self.status == 0 { self.append(Data("Files are identical.\n".utf8), false, in: tv) }
            } else if self.status != 0 {
                self.append(Data("\n[exit \(self.status)]\n".utf8), true, in: tv)
                if let failed { self.append(Data((failed + "\n").utf8), false, in: tv) }
            }
            onExit(self.status)
        }
        do { try process.run() } catch { append(Data("\(error.localizedDescription)\n".utf8), true, in: tv) }
    }

    /// Run on Servers': `MultiRun` on a thread of its own, its lines taken in batches; the summary once all are over.
    private init(_ list: [MultiRun.Server], skipped: [String], command: String, env: [String: String],
                 again: (@MainActor (NSWindow?) async -> Bool)?, ended: @escaping @MainActor (Int, MultiRun.Outcome) -> Void) {
        let (w, tv) = Self.window()
        let count = list.count + skipped.count
        w.subtitle = "\(count) server\(count == 1 ? "" : "s") · running… · ⎋ Stop"
        let cancel = CancelFlag()
        servers = cancel
        super.init(window: w)
        w.delegate = self
        w.onKey = { [weak self] e in   // ⌘R: again, once it's over (before the main menu's Refresh)
            guard let self, Shortcut(event: e) == Shortcut("cmd+r"), let again else { return false }
            if alive { NSSound.beep() } else { Task { if await again(self.window) { self.window?.close() } } }
            return true
        }
        let names = list.map(\.name), width = names.map(\.count).max() ?? 0   // the skipped have no lines
        let inbox = LineInbox(), over = over
        Thread { [weak self] in
            let outcomes = MultiRun.run(list, command, env: env, cancel: cancel, ended: { i, o in
                DispatchQueue.main.async { MainActor.assumeIsolated { ended(i, o) } }   // not through the window: it may be gone
            }) { i, text, error in
                guard inbox.put((i, text, error)) else { return }   // a hop is on its way already: it takes this too
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(inbox.take(), names, width, in: tv) } }
            }
            over.cancel()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.show(inbox.take(), names, width, in: tv)
                    let summary = MultiRun.summary(zip(names, outcomes).map { ($0, $1) } + skipped.map { ($0, .skipped) })
                    let text = NSMutableAttributedString(string: "\n" + summary + "\n", attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.textColor])
                    let all = text.string as NSString, x = all.range(of: "✗")
                    if x.location != NSNotFound {   // the failures in red, with their names
                        let next = all.range(of: "  ", range: NSRange(location: x.location, length: all.length - x.location)).location
                        text.addAttribute(.foregroundColor, value: Palette.fail,
                                          range: NSRange(location: x.location, length: (next == NSNotFound ? all.length - 1 : next) - x.location))
                    }
                    tv.textStorage?.append(text)
                    self.kept(in: tv)
                    self.window?.subtitle = "\(count) server\(count == 1 ? "" : "s") · " + (cancel.isCancelled ? "stopped" : "done")
                        + " · " + String(format: "%.1fs", Date().timeIntervalSince(self.started)) + " · ⎋ Close" + (again == nil ? "" : " · ⌘R Run Again")
                }
            }
        }.start()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Several servers' lines: "web1 │ " dimmed, then the line, red from stderr.
    private func show(_ lines: [(server: Int, text: String, error: Bool)], _ names: [String], _ width: Int, in tv: NSTextView) {
        guard let storage = tv.textStorage, !lines.isEmpty else { return }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let batch = NSMutableAttributedString()
        for l in lines {
            let (text, runs) = ANSI.parse(l.text)   // ponytail: a color left on at a line's end doesn't go on into that server's next one
            batch.append(NSAttributedString(string: MultiRun.label(names[l.server], width: width), attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            let line = NSMutableAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: l.error ? Palette.fail : NSColor.textColor])
            if !l.error { for r in runs { line.addAttributes(ANSIColors.attributes(r.style, font: font), range: r.range) } }   // stderr: red wins
            batch.append(line)
        }
        storage.append(batch)
        kept(in: tv)
    }

    /// What the window keeps (UTF-16 units): the oldest lines go — a `tail -f` left for a day would grow without end.
    static let limit = 4 << 20
    private var trimmed = false
    let inbox = Inbox()

    /// Shows what the pipes gave since the last hop; at EOF, a character cut by the last read too.
    private func drain(in tv: NSTextView) {
        let (parts, cut) = inbox.take()
        if cut { trimmed = true }
        for (stream, data) in parts {
            append(data, stream == 1, in: tv)   // empty at EOF: flushes a character a read cut
            if data.isEmpty { ended() }
        }
    }

    private var pendingCR = false
    private var rest = [Data(), Data()]   // stdout's and stderr's character cut by a read, finished by the next one
    /// stdout EOF, stderr EOF and the exit: `report` ("[exit N]", onExit) waits for all three, so it never comes before
    /// the last output — or, `now`, half a second after the exit when a backgrounded child still keeps a pipe. Once.
    private var ends = 0
    private var status: Int32 = 0
    private var report: () -> Void = {}

    private func ended(now: Bool = false) {
        ends += 1
        guard ends == 3 || now else { return }
        report(); report = {}
        _ = alive   // looked at now, a finished command's group is seen gone — and stays so (see `alive`)
    }

    /// Each stream's colors (`ANSI`): a sequence cut by a read waits for the next one, a color goes on.
    private var ansi = [ANSI(), ANSI()]

    /// stdout in its colors; stderr red whatever colors it has (red wins).
    private func append(_ data: Data, _ isErr: Bool, in tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: isErr ? Palette.fail : NSColor.textColor]
        let (s, runs) = ansi[isErr ? 1 : 0].feed(utf8Chunk(data, rest: &rest[isErr ? 1 : 0]), end: data.isEmpty)
        // In pieces of one style each: a CR in any of them redraws the line, whatever its colors.
        let text = s as NSString
        var at = 0
        for r in isErr ? [] : runs {
            appendTerminalOutput(text.substring(with: NSRange(location: at, length: r.range.location - at)), to: storage, pendingCR: &pendingCR, attributes: base)
            appendTerminalOutput(text.substring(with: r.range), to: storage, pendingCR: &pendingCR,
                                 attributes: base.merging(ANSIColors.attributes(r.style, font: font)) { $1 })
            at = NSMaxRange(r.range)
        }
        appendTerminalOutput(text.substring(from: at), to: storage, pendingCR: &pendingCR, attributes: base)
        kept(in: tv)
    }

    /// What it keeps (`limit`), and the end in view.
    private func kept(in tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let cut = FollowReader.trimCount(storage.mutableString, limit: Self.limit)
        if cut > 0 {
            storage.deleteCharacters(in: NSRange(location: 0, length: cut))
            trimmed = true
        }
        tv.scrollToEndOfDocument(nil)
    }

    private static func colorizeDiff(_ tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let text = storage.string as NSString
        storage.beginEditing()
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, range, _, _ in
            guard let line else { return }
            let color: NSColor? = line.hasPrefix("+++") || line.hasPrefix("---") ? .secondaryLabelColor
                : line.hasPrefix("+") ? .systemGreen : line.hasPrefix("-") ? .systemRed : line.hasPrefix("@@") ? Palette.secondary : nil
            if let color { storage.addAttribute(.foregroundColor, value: color, range: range) }
        }
        storage.endEditing()
    }

    /// ⎋: what runs stops first, and the window stays with what it said (several servers': and the summary); ⎋ again —
    /// or with nothing running — closes it, a command that ignored the first one getting its SIGKILL as closing gives.
    private var stopAsked = false
    override func cancelOperation(_ sender: Any?) {
        if !stopAsked, stop() {
            stopAsked = true
            window?.subtitle = "stopping… · ⎋ Close"
        } else {
            window?.performClose(nil)
        }
    }

    /// The process group is still there — the shell (Process made it a group leader), or a child it left behind
    /// (`sleep 30 &`, `tail -f x &`), which `process.isRunning` wouldn't see. Pid 0: the process never ran (killpg(0) would be us).
    /// Once seen gone it stays gone: pids wrap (99999), and a window left open for days would otherwise count — and at
    /// quit, SIGKILL — whatever process group got its number since. `ended` looks once the command is over, so the
    /// usual case latches right then.
    /// ponytail: a child left behind (`sleep 30 &`) that dies later, unlooked at, is open to that until the next look;
    /// a periodic look (or a kqueue on the group) would close it.
    private var gone = false
    private var alive: Bool {
        if servers != nil { return !over.isCancelled }
        guard !gone, process.processIdentifier > 0 else { return false }
        gone = killpg(process.processIdentifier, 0) != 0
        return !gone
    }

    /// SIGTERM to the whole process group — a `tail -f | grep` pipeline, not only the shell; false if nothing runs.
    /// `forceKill` is the SIGKILL for what ignores it.
    private func stop() -> Bool {
        guard alive else { return false }
        if let servers { servers.cancel() } else { killpg(process.processIdentifier, SIGTERM) }   // their ssh get a SIGTERM each
        return true
    }
    private func forceKill() { if servers == nil, alive { killpg(process.processIdentifier, SIGKILL) } }

    /// Closed while the command ran: stopping, SIGKILL in 2 s — and `terminateAll` reaches them meanwhile.
    private static var stopping: [OutputWindow] = []

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
        guard stop() else { return }
        Self.stopping.append(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in MainActor.assumeIsolated { forceKill(); Self.stopping.removeAll { $0 === self } } }
    }

    /// At quit (no run loop after this: waits here): every window's command, SIGKILL to what's still there after a second.
    static func terminateAll() {
        let stopped = (open + stopping).filter { $0.stop() }
        for _ in 0..<20 where stopped.contains(where: \.alive) { usleep(50_000) }
        stopped.forEach { $0.forceKill() }
    }

    /// For the quit confirmation: how many windows' commands quitting would end (a `cat parts > target` stops part way).
    static var busy: String? {
        let n = open.filter(\.alive).count
        return n > 0 ? "\(n) command\(n == 1 ? "" : "s") running in an output window (a split or combine stops part way)" : nil
    }
}
