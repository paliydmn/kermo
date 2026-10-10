import AppKit
import DFMCore

/// Runs shell commands in an output window (⌘E ⇧↩, a server panel's ⌘E, tar / diff / git) or hands them to the
/// terminal app (⌘↩). ⌘E ↩ on a local panel types into the ⌃O shell instead: `EmbeddedTerminal.run`.
@MainActor
enum Shell {
    /// Login shell, so PATH matches what the user has in their terminal (Homebrew etc.).
    /// `onExit` gets the exit status.
    /// `title`: what it does, for the window, in place of the command line.
    static func run(_ command: String, in dir: String, diff: Bool = false, title: String? = nil, onExit: @escaping @MainActor (Int32) -> Void = { _ in }) {
        OutputWindow.start(command, in: dir, on: nil, diff: diff, title: title, onExit: onExit)
    }

    /// On a server, in its folder `dir`, over the panel's ssh connection (the login shell there runs it).
    static func run(_ command: String, on server: SFTPTarget, in dir: String, title: String? = nil, onExit: @escaping @MainActor (Int32) -> Void = { _ in }) {
        OutputWindow.start(command, in: dir, on: server, diff: false, title: title, onExit: onExit)
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

    /// R1: a command that removes, moves, re-owns or stops things, which asks first on a production server: `rm`, `mv`,
    /// `chmod`, `chown`, `dd` or `systemctl stop|restart` as the first word, behind sudo / doas / env, their options,
    /// VAR=value and a path (/bin/rm). ponytail: the first word only — `cd x && rm`, `xargs rm`, `find -delete` pass.
    nonisolated static func isDangerous(_ command: String) -> Bool {
        var words = command.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        let name = { (w: String) in (w as NSString).lastPathComponent }   // /usr/bin/sudo, /bin/rm
        while let w = words.first, ["sudo", "doas", "env", "nohup", "command", "exec", "time"].contains(name(w)) || w.hasPrefix("-") || w.contains("=") {
            words = words.dropFirst(["-u", "-g"].contains(w) ? 2 : 1)   // `sudo -u www rm …`
        }
        guard let first = words.first.map({ String(name($0).drop(while: { $0 == "\\" })) }) else { return false }   // `\rm`: past the alias
        if first == "systemctl" { return words.dropFirst().first { !$0.hasPrefix("-") }.map { ["stop", "restart"].contains($0) } == true }
        return ["rm", "mv", "chmod", "chown", "dd"].contains(first)
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
private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    /// In the order read — an error line stays next to the output around it. Empty data: that stream's EOF.
    private var parts: [(stream: Int, data: Data)] = [], scheduled = false

    /// Adds a read (empty: EOF); true if the main thread has to be asked to take it.
    func put(_ d: Data, _ stream: Int) -> Bool {
        lock.withLock {
            if !d.isEmpty, let last = parts.last, last.stream == stream, !last.data.isEmpty { parts[parts.count - 1].data.append(d) }
            else { parts.append((stream, d)) }
            defer { scheduled = true }
            return !scheduled
        }
    }

    func take() -> [(stream: Int, data: Data)] {
        lock.withLock {
            defer { parts = []; scheduled = false }
            return parts
        }
    }
}

@MainActor
private final class OutputWindow: NSWindowController, NSWindowDelegate {
    private static var open: [OutputWindow] = []
    private let textView = NSTextView()
    private let process = Process()
    private let started = Date()
    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")

    static func start(_ command: String, in dir: String, on server: SFTPTarget?, diff: Bool, title: String?, onExit: @escaping @MainActor (Int32) -> Void) {
        let w = OutputWindow(command, dir, server, diff, onExit)
        if let title { w.window?.title = title.bidiVisible }
        open.append(w)
        w.showWindow(nil)
    }

    private init(_ command: String, _ dir: String, _ server: SFTPTarget?, _ diff: Bool, _ onExit: @escaping @MainActor (Int32) -> Void) {
        let place = server.map { "🌐 \($0.host):\(dir)" } ?? (dir as NSString).abbreviatingWithTildeInPath
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = (server.map { "\($0.host) $ " } ?? "$ ") + command.bidiVisible
        w.subtitle = place + " · running… · Esc closes (and stops)"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self

        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.usesFindBar = true
        w.contentView = scroll
        w.center()
        w.setFrameAutosaveName("Output")

        if let server {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = SSHCommand.arguments(server, command: SSHCommand.inDir(dir, command), tty: false)
            process.environment = ProcessInfo.processInfo.environment.merging(SSHAskpass.env) { $1 }
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inbox = inbox
        for (pipe, stream) in [(out, 0), (err, 1)] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let data = h.availableData
                if data.isEmpty { h.readabilityHandler = nil }
                guard inbox.put(data, stream) else { return }   // a hop is on its way already: it takes this too
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.drain(in: tv) } }
            }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.status = status; self?.ended() } }
            // A child that keeps a pipe (`./server &`) would hold the report forever: half a second after the exit it comes anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self?.ended(now: true) } }
        }
        report = { [weak self] in
            guard let self else { return }
            let secs = String(format: "%.1fs", Date().timeIntervalSince(self.started))
            self.window?.subtitle = place + " · exit \(self.status) · \(secs)" + (self.trimmed ? " · only the last 4 MB kept" : "")
            if diff {
                // diff exits 1 when files differ — that's the normal case, not an error.
                Self.colorizeDiff(tv)
                if self.status == 0 { self.append(Data("Files are identical.\n".utf8), false, in: tv) }
            } else if self.status != 0 {
                self.append(Data("\n[exit \(self.status)]\n".utf8), true, in: tv)
            }
            onExit(self.status)
        }
        do { try process.run() } catch { append(Data("\(error.localizedDescription)\n".utf8), true, in: tv) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// What the window keeps (UTF-16 units): the oldest lines go — a `tail -f` left for a day would grow without end.
    static let limit = 4 << 20
    private var trimmed = false
    private let inbox = Inbox()

    /// Shows what the pipes gave since the last hop; at EOF, a character cut by the last read too.
    private func drain(in tv: NSTextView) {
        for (stream, data) in inbox.take() {
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

    private func append(_ data: Data, _ isErr: Bool, in tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        var s = utf8Chunk(data, rest: &rest[isErr ? 1 : 0])
        s = Self.ansi.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        appendTerminalOutput(s, to: storage, pendingCR: &pendingCR, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: isErr ? NSColor.systemRed : NSColor.textColor,
        ])
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
                : line.hasPrefix("+") ? .systemGreen : line.hasPrefix("-") ? .systemRed : line.hasPrefix("@@") ? .systemPurple : nil
            if let color { storage.addAttribute(.foregroundColor, value: color, range: range) }
        }
        storage.endEditing()
    }

    override func cancelOperation(_ sender: Any?) { window?.performClose(nil) }

    /// The process group is still there — the shell (Process made it a group leader), or a child it left behind
    /// (`sleep 30 &`, `tail -f x &`), which `process.isRunning` wouldn't see. Pid 0: the process never ran (killpg(0) would be us).
    /// Once seen gone it stays gone: pids wrap (99999), and a window left open for days would otherwise count — and at
    /// quit, SIGKILL — whatever process group got its number since. `ended` looks once the command is over, so the
    /// usual case latches right then.
    /// ponytail: a child left behind (`sleep 30 &`) that dies later, unlooked at, is open to that until the next look;
    /// a periodic look (or a kqueue on the group) would close it.
    private var gone = false
    private var alive: Bool {
        guard !gone, process.processIdentifier > 0 else { return false }
        gone = killpg(process.processIdentifier, 0) != 0
        return !gone
    }

    /// SIGTERM to the whole process group — a `tail -f | grep` pipeline, not only the shell; false if nothing runs.
    /// `forceKill` is the SIGKILL for what ignores it.
    private func stop() -> Bool {
        guard alive else { return false }
        killpg(process.processIdentifier, SIGTERM)
        return true
    }
    private func forceKill() { if alive { killpg(process.processIdentifier, SIGKILL) } }

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
