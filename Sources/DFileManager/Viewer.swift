import AppKit
import DFMCore
import UniformTypeIdentifiers

/// F3 viewer. Keys: & filter lines (!text: without it) · e errors and warnings, errors only, all · h hex · p readable plist/JSON ·
/// f follow (tail -f) · l line numbers · w wrap · ⌘F find · Esc/q/F3 close.
/// Text ≤ 4 MB loads whole. Bigger files (and rotated logs unpacking past 4 MB, via a temp copy) are memory-mapped and shown through a sliding 256 KB window:
/// scrolling past either edge slides it; g goes to a position, / and n search the whole file. Error/warning lines are tinted.
@MainActor
final class Viewer: NSWindowController, NSWindowDelegate {
    enum Mode { case text, hex, pretty }

    private static var open: [Viewer] = []
    private var url: URL   // a rotated log that unpacks past 4 MB: its unpacked temp copy (see `unpackHuge`)
    private var unpacked: URL?   // that copy, removed on close
    var unpackedCopy: URL? { unpacked }   // for tests
    private let textView = ViewerTextView(usingTextLayoutManager: false)   // TextKit 1: line rects for the sliding window
    let scroll = NSScrollView()
    private let spinner = NSProgressIndicator()   // while a (re)load is in flight
    private var wrap = false
    private var mode = Mode.text
    private var canPretty = false
    private var asText = false   // h from hex: text even if it looks binary
    private var info = ""
    private var followTask: Task<Void, Never>?
    private var follower: FollowReader?   // made on the first poll from `followOffset`; kept across f off/on
    private var polling = false           // a FollowReader is polled from one thread at a time
    private var followOffset: UInt64 = 0 { didSet { follower = nil; filterRest = ""; held = ""; heldRuns = []; ansi = ANSI() } }   // the text was reloaded: follow from its end
    /// What a poll read after f went off (it was on its way): shown when f is on again — the reader is past it.
    private var held = ""
    private var heldRuns: [ANSI.Run] = []
    /// The colors of what follow appends: a sequence cut between two polls waits, a color goes on.
    private var ansi = ANSI()
    private(set) var lineFilter: LineFilter?   // & : only the lines with (or without) a text, the followed ones too
    private var filterRest = ""   // followed text after its last "\n", filtered once the line is whole
    var followLimit = 8 << 20   // UTF-16 units kept while following; the oldest lines go
    private var loadGen = 0
    // Huge files (see the extension below)
    fileprivate var isHuge = false
    private(set) var big: Data? { didSet { if big == nil { bigFile = nil } } }   // the whole file, memory-mapped
    private var bigFile: BigFile.Mapped?   // `big`'s file, open: what / and & read
    private(set) var win = 0..<0         // byte range shown, line-aligned (inside a long line: cut there)
    fileprivate var winEncoding = ""     // how it decoded: Windows-1251 is a byte per character
    private(set) var sliding = false
    var findNeedle = ""
    private(set) var lastMatch: Int?
    fileprivate var hexOffset: UInt64 = 0
    fileprivate var truncated = false   // remapped after a truncate: the next window says so
    fileprivate var label: String?      // an unpacked copy's original: "3 MB · gzip, 20 MB unpacked"; a server log's tail: "last 4 MB of 1.2 GB"
    /// A server's file shown from a local copy of it from byte `from` on (a big log: its tail, see `remoteLimit`):
    /// follow appends what `tail -F` there prints to the copy.
    private var remote: (target: SFTPTarget, path: String, from: Int64)?
    private var remoteTail: Process?
    private var tail: String?   // a server log's tail is shown: how much of it (& filters just that, unless grep there ran)
    private var serverFiltered = false   // & ran grep on the server: the lines are the whole log's
    private var followStopped = false   // the server's `tail -F` ended and wasn't started again
    /// `l`: the line-number gutter (remembered), shown where the text is the whole file from its first line.
    private var ruler: LineNumberRuler?
    /// Lines a follow dropped off the top since the text was loaded: numbers go on from there.
    private var dropped = 0
    var defaults = UserDefaults.standard   // tests: their own
    private var numbersOn: Bool { defaults.bool(forKey: "viewerLineNumbers") }
    /// Following, scrolled up from the end: what comes in waits below (End resumes).
    private var followPaused = false
    /// Called once the window closes (a temp copy goes then).
    var onClose: (@MainActor () -> Void)?

    /// A server's file bigger than this is shown by its tail only, so F3 on a big log doesn't download all of it
    /// first: as much as loads whole.
    nonisolated static let remoteLimit = Int64(hugeLimit)

    /// How much of a server's file F3 fetches: the last `remoteLimit` of one that reads like a log (`.log`, a rotated
    /// `.log.3` or `syslog.1`, `.txt`, no extension, or plain text by MIME type), all of anything else — a CSV, JSON
    /// or binary file is read from its start, and the end of a .gz unpacks to nothing.
    nonisolated static func tailLimit(for name: String) -> Int64? {
        guard !CompressedFile.matches(name) else { return nil }
        var n = name as NSString
        if !n.pathExtension.isEmpty, n.pathExtension.allSatisfy(\.isNumber) { n = n.deletingPathExtension as NSString }   // app.log.3
        let ext = n.pathExtension.lowercased()
        let text = ext.isEmpty || ["log", "txt", "out", "err"].contains(ext) || UTType(filenameExtension: ext)?.preferredMIMEType == "text/plain"
        return text ? remoteLimit : nil
    }

    static func show(_ url: URL, remote: (target: SFTPTarget, path: String, from: Int64)? = nil, onClose: (@MainActor () -> Void)? = nil) {
        let v = Viewer(url, remote: remote)
        v.onClose = onClose
        if let remote { v.window?.title = "\(remote.target.host):\(remote.path)".bidiVisible }
        open.append(v)
        v.showWindow(nil)
    }

    init(_ url: URL, remote: (target: SFTPTarget, path: String, from: Int64)? = nil) {   // internal for tests; use show(_:)
        self.url = url
        self.remote = remote
        if let from = remote?.from, from > 0 {
            let shown = Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
            let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            label = "last \(fmt(shown)) of \(fmt(from + shown))"
            tail = fmt(shown)
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = url.lastPathComponent.bidiVisible
        w.subtitle = "Loading…"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.onKey = { [unowned self] in handleKey($0) }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        w.contentView = scroll
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(spinner)
        spinner.centerXAnchor.constraint(equalTo: scroll.centerXAnchor).isActive = true
        spinner.centerYAnchor.constraint(equalTo: scroll.centerYAnchor).isActive = true
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        scroll.documentView = textView
        setWrap(false)
        w.center()
        w.setFrameAutosaveName("Viewer")
        w.makeFirstResponder(textView)

        // Its size off the main thread (a file on a share that stopped answering).
        let path = url.path, pretty = ["plist", "json", "strings", "mobileconfig", "entitlements"].contains(url.pathExtension.lowercased())
        Task { [weak self] in
            let huge = await Blocking.run(.userInitiated) { Self.isHuge(path) }
            guard let self else { return }
            isHuge = huge
            // Over 4 MB it would go formatted, whole, into the text view (seconds per End, f or w): the window instead.
            canPretty = pretty && !huge
            load(canPretty ? .pretty : .text)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// A text with its colors, made off the main thread (`painted`) and put in a text view on it (`show`).
    struct Painted: Sendable {
        var text: String
        var levels: [(range: NSRange, level: TextFormat.Level)] = []
        var syntax: [(range: NSRange, token: Syntax.Token)] = []
        var runs: [ANSI.Run] = []
    }

    /// F3's colors for a text named `name`: escape sequences become colors, then a known format gets syntax colors and
    /// anything else (a log) error/warning tints. Size-capped to stay fast, as F3's.
    nonisolated static func painted(_ text: String, name: String) -> Painted {
        let (plain, runs) = ANSI.parse(text), n = plain.utf16.count
        if let lang = Syntax.language(forFileName: name), n <= 2 << 20 { return Painted(text: plain, syntax: Syntax.tokens(plain, lang), runs: runs) }
        return Painted(text: plain, levels: n <= 8 << 20 ? ANSIColors.uncolored(TextFormat.logLevels(in: plain), runs) : [], runs: runs)
    }

    static func show(_ p: Painted, in textView: NSTextView) {
        let storage = textView.textStorage!
        storage.setAttributedString(NSAttributedString(string: p.text, attributes: [.font: font, .foregroundColor: NSColor.textColor]))
        if p.syntax.isEmpty { tint(storage, p.levels, offset: 0) } else { SyntaxColors.apply(p.syntax, to: storage) }
        ANSIColors.apply(p.runs, to: storage, font: font)
    }

    func windowWillClose(_ notification: Notification) {
        followTask?.cancel()
        remoteTail?.terminate()
        Self.open.removeAll { $0 === self }
        onClose?()
        onClose = nil
        if let unpacked { try? FileManager.default.removeItem(at: unpacked) }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if big != nil, mode == .text, followTask == nil, lineFilter == nil {   // huge file: whole-file navigation
            switch (e.keyCode, mods) {
            case (115, []), (126, .command): showWindow(around: 0, top: 0); return true                       // Home, ⌘↑
            case (119, []), (125, .command): self.big = nil; openBig(around: .max); return true               // End, ⌘↓ (remapped: it may have grown)
            case (5, []): goToDialog(); return true                                                            // g
            case (44, []): findDialog(); return true                                                           // /
            case (45, []): find(from: (lastMatch ?? visibleTop()?.offset ?? 0) + 1); return true               // n
            default: break
            }
        }
        if mode == .hex, isHuge, e.keyCode == 5, mods.isEmpty { goToDialog(); return true }
        if e.keyCode == 26, mods == .shift { filterDialog(); return true }   // & (⇧7), like less
        guard mods.isEmpty else { return false }
        switch e.keyCode {
        case 53, 99, 109, 12: window?.performClose(nil)          // Esc, F3, F10, q
        case 13: setWrap(!wrap)                                   // w
        case 4:                                                   // h
            if mode == .hex { asText = true } else if mode == .text, lineFilter == nil, let top = visibleTop() { hexOffset = UInt64(top.offset) & ~15 }   // huge file: hex from here
            load(mode == .hex ? .text : .hex)
        case 35: load(mode == .pretty ? .text : .pretty)          // p
        case 3: setFollow(followTask == nil)                     // f
        case 14: cycleLevels()                                    // e
        case 37: setNumbers(!numbersOn)                           // l
        default: return false
        }
        return true
    }

    /// Its keys for what it shows now, as the subtitle names them; F1 over it lists them too.
    var keyHints: [(key: String, label: String)] {
        var keys = [("&", "filter"), ("e", "errors"), ("h", "hex"), ("f", "follow"), ("l", "lines"), ("w", "wrap"), ("⌘F", "find"), ("Esc", "close")]
        if canPretty { keys.insert(("p", "readable"), at: 2) }
        if big != nil && mode == .text && lineFilter == nil { keys.insert(contentsOf: [("g", "go to"), ("/ n", "find in file")], at: 0) }
        if isHuge && mode == .hex { keys.insert(("g", "go to"), at: 0) }
        return keys
    }

    static func keyHelp(of window: NSWindow?) -> KeyHelp.Section? {
        open.first { $0.window === window && window != nil }.map { v in
            ("Viewer", v.keyHints.map { ($0.label.prefix(1).uppercased() + $0.label.dropFirst(), $0.key) })
        }
    }

    private func updateSubtitle() {
        let keys = keyHints.map { "\($0.key) \($0.label)" }
        let filtered = mode == .hex ? nil : lineFilter.map { f in
            [f.text.isEmpty ? nil : "LINES \(f.exclude ? "WITHOUT" : "WITH") “\(f.text)”",
             f.level.map { $0 == .error ? "ERRORS ONLY" : "ERRORS + WARNINGS" }].compactMap { $0 }.joined(separator: " · ")
                + (serverFiltered ? " IN THE WHOLE FILE (grep on the server)" : tail.map { " IN THE LAST \($0) ONLY" } ?? "")
        }
        let follow = followTask != nil ? [followPaused ? "FOLLOWING · paused — End resumes" : "FOLLOWING"] : followStopped ? ["FOLLOW STOPPED · f to resume"] : []
        window?.subtitle = ([info] + [filtered, showNumbers()].compactMap { $0 } + follow + keys).joined(separator: " · ")
    }

    /// The gutter on or off as `l` and the text allow; what to say where it can't be: numbers count from the file's
    /// first line, so not for a big file's window, a log's tail, or a filtered view (hex has its offsets).
    private func showNumbers() -> String? {
        let why = !numbersOn || mode == .hex ? nil : isHuge ? "line numbers: files up to 4 MB"
            : tail != nil ? "line numbers: not for the last part of a log" : lineFilter != nil ? "line numbers: not while filtered" : nil
        let on = numbersOn && mode != .hex && why == nil
        if on, ruler == nil {
            ruler = LineNumberRuler(textView: textView)
            scroll.verticalRulerView = ruler
            scroll.hasVerticalRuler = true
        }
        scroll.rulersVisible = on
        ruler?.firstLine = dropped
        ruler?.invalidate()
        return why
    }

    /// `l`: line numbers on or off, here and in viewers to come.
    func setNumbers(_ on: Bool) {   // internal for tests
        defaults.set(on, forKey: "viewerLineNumbers")
        updateSubtitle()
    }

    /// `e`: all lines → errors and warnings → errors only → all, together with an `&` filter.
    func cycleLevels() {   // internal for tests
        let next: TextFormat.Level? = switch lineFilter?.level { case nil: .warning; case .warning?: .error; case .error?: nil }
        setLineFilter(Self.filter(lineFilter?.spec ?? "", level: next))
    }

    // MARK: - Loading (off main thread)

    private func load(_ newMode: Mode) {
        if newMode == .pretty && !canPretty { return NSSound.beep() }
        if newMode != .text { setFollow(false) }
        mode = newMode
        if newMode == .text && isHuge { return openBig() }
        spinner.startAnimation(nil)
        loadGen += 1
        sliding = false   // a window or & pass this supersedes drops its result, and with it its own clearing
        let gen = loadGen
        let url = url
        let hexOffset = hexOffset, asText = asText, shown = unpacked == nil ? label : nil, base = UInt64(remote?.from ?? 0), filter = lineFilter
        let server = tail != nil && unpacked == nil ? remote : nil   // a big log's tail: & runs grep there, over all of it
        Task { [weak self] in
            if newMode == .text, CompressedFile.matches(url.path),
               let copy = await Blocking.run(.userInitiated, { Self.unpackHuge(url, asText: asText) }) {
                guard let self, gen == loadGen else { try? FileManager.default.removeItem(at: copy.url); return }
                self.url = copy.url
                unpacked = copy.url
                label = copy.label
                isHuge = true
                return openBig()
            }
            let lang = Syntax.language(forFileName: url.lastPathComponent)
            let (text, info, size, binary, levels, syntax, grepped, runs) = await Blocking.run(.userInitiated) {
                () -> (String, String, UInt64, Bool, [(range: NSRange, level: TextFormat.Level)], [(range: NSRange, token: Syntax.Token)], Bool, [ANSI.Run]) in
                var (text, info, size, binary) = Self.read(url, newMode, hexOffset: hexOffset, asText: asText, label: shown, base: base)
                var grepped = false
                if newMode != .hex, !binary, let filter {
                    if let server, !filter.text.isEmpty, let lines = Self.serverLines(server.target, server.path, filter) {
                        (text, grepped) = (TextFormat.decode(lines).text, true)
                        if let level = filter.level { text = LineFilter(level: level).apply(text) }   // grep took the text: the level is looked at here
                    } else {
                        text = filter.apply(text)
                    }
                }
                if binary { return (text, info, size, true, [], [], false, []) }
                var runs: [ANSI.Run] = []
                if newMode == .text { (text, runs) = ANSI.parse(text) }   // colors, not escape sequences (hex: the bytes)
                let n = text.utf16.count
                // Known formats get syntax colors; anything else (logs) gets error/warning tints. Size-capped to stay fast.
                if newMode != .hex, let lang = lang ?? (newMode == .pretty ? .xml : nil), n <= 2 << 20 {
                    let isJSON = newMode == .pretty && (text.hasPrefix("{") || text.hasPrefix("["))
                    return (text, info, size, false, [], Syntax.tokens(text, isJSON ? .json : lang), grepped, runs)
                }
                let levels = newMode == .text && n <= 8 << 20 ? ANSIColors.uncolored(TextFormat.logLevels(in: text), runs) : []
                return (text, info, size, false, levels, [], grepped, runs)
            }
            guard let self, gen == loadGen else { return }
            spinner.stopAnimation(nil)
            serverFiltered = grepped
            if binary { mode = .hex }   // what's shown: h then shows it as text
            self.info = info
            followOffset = size
            Self.show(Painted(text: text, levels: levels, syntax: syntax, runs: runs), in: textView)
            dropped = 0
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            updateSubtitle()
        }
    }

    /// Text that looks binary (and isn't `asText`) comes back as hex, `binary`. `label` says what the file is in
    /// place of its size; `base` is where it starts in the server's file (a tail: hex offsets are the real ones).
    nonisolated static func read(_ url: URL, _ mode: Mode, hexOffset: UInt64 = 0, asText: Bool = false, label: String? = nil,   // internal for tests
                                 base: UInt64 = 0) -> (String, String, UInt64, binary: Bool) {
        if let what = FileInfo.notRegular(url.path) {   // F3 on a FIFO waited for a writer forever
            return ("“\(url.lastPathComponent)” is \(what) — nothing to show", "error", 0, false)
        }
        guard let h = try? FileHandle(forReadingFrom: url) else {
            return ("Can't open \(url.path): \(String(cString: strerror(errno)))", "error", 0, false)
        }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: 0)
        let sizeText = label ?? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        let full: UInt64 = 32 << 20, chunk = 4 << 20

        switch mode {
        case .hex:
            let at = min(hexOffset, size)
            try? h.seek(toOffset: at)
            let data = (try? h.read(upToCount: 1 << 20)) ?? Data()
            let what = size <= 1 << 20 ? "" : at == 0 ? " of first 1 MB" : " · 1 MB at \(ByteCountFormatter.string(fromByteCount: Int64(base + at), countStyle: .file))"
            return (TextFormat.hexDump(data, base: Int(base + at)), "\(sizeText) · hex" + what, size, false)
        case .pretty:
            let data = (try? h.read(upToCount: Int(min(size, full)))) ?? Data()
            if let s = TextFormat.prettyPlist(data) { return (s, "\(sizeText) · property list (as XML)", size, false) }
            if let s = TextFormat.prettyJSON(data) { return (s, "\(sizeText) · JSON (formatted)", size, false) }
            return read(url, .text, asText: asText, label: label)   // h chose text: p back from readable keeps it
        case .text:
            if CompressedFile.matches(url.path), let z = CompressedFile.read(url.path, limit: Int(full)) {   // rotated log.gz…: unpacked
                let what = unpackedInfo(z, sizeText)
                if !asText, TextFormat.looksBinary(z.data) {
                    return (TextFormat.hexDump(z.data.prefix(1 << 20)), what + " · binary, hex of first 1 MB", size, true)
                }
                let (text, enc) = TextFormat.decode(z.data)
                return (text, "\(what) · \(enc)", size, false)
            }
            let head = (try? h.read(upToCount: Int(size <= full ? size : UInt64(chunk)))) ?? Data()
            if !asText, TextFormat.looksBinary(head) {
                return (TextFormat.hexDump(head.prefix(1 << 20), base: Int(base)), "\(sizeText) · binary, hex of first 1 MB", size, true)
            }
            guard size > full else {
                let (text, enc) = TextFormat.decode(head)
                return (text, "\(sizeText) · \(enc)", size, false)
            }
            try? h.seek(toOffset: size - UInt64(chunk))
            let tail = (try? h.read(upToCount: chunk)) ?? Data()
            let (headText, enc) = TextFormat.decode(head)
            let skipped = ByteCountFormatter.string(fromByteCount: Int64(size) - Int64(2 * chunk), countStyle: .file)
            let text = headText + "\n\n··· \(skipped) skipped ···\n\n" + TextFormat.decode(tail).text
            return (text, "\(sizeText) · \(enc) · first and last 4 MB", size, false)
        }
    }

    /// "3 MB · gzip, 20 MB unpacked" (or "first 32 MB unpacked", "damaged after 6.8 MB").
    nonisolated static func unpackedInfo(_ z: (data: Data, compression: String, truncated: Bool, damaged: Bool), _ sizeText: String) -> String {
        let unpacked = ByteCountFormatter.string(fromByteCount: Int64(z.data.count), countStyle: .file)
        return "\(sizeText) · \(z.compression), " + (z.damaged ? z.data.isEmpty ? "damaged, nothing unpacked" : "damaged after \(unpacked)"
                                                   : z.truncated ? "first \(unpacked) unpacked" : "\(unpacked) unpacked")
    }

    private static func tint(_ storage: NSTextStorage, _ levels: [(range: NSRange, level: TextFormat.Level)], offset: Int) {
        guard !levels.isEmpty else { return }
        storage.beginEditing()
        for (range, level) in levels {
            storage.addAttribute(.foregroundColor, value: level == .error ? NSColor.systemRed : NSColor.systemOrange,
                                 range: NSRange(location: range.location + offset, length: range.length))
        }
        storage.endEditing()
    }

    // MARK: - Follow (tail -f): poll for growth, append, keep scrolled to the end

    func setFollow(_ on: Bool) {   // internal for tests
        let wasOn = followTask != nil
        followTask?.cancel()
        followTask = nil
        remoteTail?.terminate()
        remoteTail = nil
        followStopped = false
        followPaused = false
        if isHuge && wasOn && !on && mode == .text { big = nil; openBig(around: .max) }   // remap: the file grew
        if on, let remote, unpacked == nil { startTail(remote) }
        if on {
            if isHuge { mode = .text; openBig(around: .max) } else if mode != .text { load(.text) }
            textView.scrollToEndOfDocument(nil)
            followTask = Task { [weak self] in
                while (try? await Task.sleep(for: .milliseconds(500))) != nil {   // cancelled (f off): no poll after it
                    await self?.pollGrowth()
                }
            }
        }
        updateSubtitle()
    }

    /// The lines of the server's `path` that `f` keeps, by `grep -F` there (ASCII case folded), up to `hugeLimit` of
    /// them; nil if it didn't run (no grep, the connection gone): the caller filters what it has.
    /// ponytail: grep sees the raw bytes — a text across a color's codes ("ERROR: x" in a colored log) isn't found
    /// there; a local filter of the tail would be, at the cost of the whole log.
    nonisolated static func serverLines(_ t: SFTPTarget, _ path: String, _ f: LineFilter) -> Data? {
        let command = "LC_ALL=C grep -a -F -i \(f.exclude ? "-v " : "")-e \(ShellContext.quote(f.text)) -- \(ShellContext.quote(path))"
        var out = Data(), full = false
        let flag = CancelFlag()
        do {
            let (status, _) = try SSHCommand.run(t, command, env: SSHAskpass.env, cancel: flag) { d in
                out.append(d)
                if out.count > hugeLimit { full = true; flag.cancel() }
            }
            guard status <= 1 else { return nil }   // 1: no line matched
        } catch {
            guard full else { return nil }
        }
        if full, let nl = out.prefix(hugeLimit).lastIndex(of: 10) { out = out.prefix(through: nl) }   // as many whole lines as load
        return out
    }

    /// `tail -F` on the server from where the local copy ends (byte `from` + its size), appended to it: the local
    /// follow then just works, rotation included (tail -F reopens by name). Off: the ssh is stopped; on again: picks
    /// up from the new end.
    private func startTail(_ remote: (target: SFTPTarget, path: String, from: Int64)) {
        let started = Date()
        remoteTail = Self.tail(remote.target, remote.path, from: remote.from, into: url) { [weak self] p in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.tailEnded(p, remote, started: started) } }
        }
        if remoteTail == nil { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.followStoppedOnServer() } } }
    }

    /// The server's `tail -F` ended though follow is on (the connection dropped, sshd restarted, it was killed):
    /// started again from where the copy ends while the shared connection is up — not if it ended within seconds
    /// (it would only end again) — else the title says follow stopped.
    private func tailEnded(_ p: Process, _ remote: (target: SFTPTarget, path: String, from: Int64), started: Date) {
        guard remoteTail === p, followTask != nil else { return }   // f off (or on again) did that
        remoteTail = nil
        let quick = Date().timeIntervalSince(started) < 5
        Task {
            let up = quick ? false : await Blocking.run(.utility) { SFTP.isConnected(remote.target) }
            guard remoteTail == nil, followTask != nil, !followStopped else { return }
            if up { startTail(remote) } else { followStoppedOnServer() }
        }
    }

    /// Follow is off, saying why: f starts it again, f again turns it off — as any other time.
    private func followStoppedOnServer() {
        guard followTask != nil else { return }
        setFollow(false)
        followStopped = true
        updateSubtitle()
    }

    private static func tail(_ t: SFTPTarget, _ path: String, from: Int64, into copy: URL,
                             onExit: @escaping @Sendable (Process) -> Void) -> Process? {
        var st = stat()
        let fd = Darwin.open(copy.path, O_WRONLY | O_APPEND)
        guard fd >= 0, fstat(fd, &st) == 0 else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = SSHCommand.arguments(t, command: SSHCommand.follow(path, after: from + st.st_size), tty: false)
        p.environment = ProcessInfo.processInfo.environment.merging(SSHAskpass.env) { $1 }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = onExit
        return (try? p.run()) != nil ? p : nil
    }

    /// Reads and decodes off the main thread; scrolls along only if the end was on screen, so one can scroll up and read.
    private func pollGrowth() async {
        guard !sliding, !polling else { return }
        polling = true
        defer { polling = false }
        let filter = lineFilter, carried = filterRest, made = follower, path = url.path, from = followOffset, colors = ansi
        let polled = await Blocking.run(.utility) { () -> (FollowReader, String, [(range: NSRange, level: TextFormat.Level)], String, ANSI, [ANSI.Run])? in
            // Opened here, not on the main thread: a file on a share that stopped answering.
            // A FIFO is never opened: that waits for a writer for good (and would take its data from the real reader).
            guard let reader = made ?? (FileInfo.notRegular(path) == nil ? FollowReader(path: path, from: from) : nil) else { return nil }
            var rest = carried
            let text = reader.poll().map { e in
                switch e {
                case .data(let d): filter.map { $0.apply(TextFormat.decode(d).text, rest: &rest) } ?? TextFormat.decode(d).text
                case .rotated: "\n——— file rotated ———\n"
                case .truncated: "\n——— file truncated ———\n"
                }
            }.joined()
            var colors = colors
            let (plain, runs) = colors.feed(text)
            return (reader, plain, ANSIColors.uncolored(TextFormat.logLevels(in: plain), runs), rest, colors, runs)
        }
        guard let (reader, read, readLevels, rest, colors, readRuns) = polled, follower === made, followOffset == from else { return }   // reloaded meanwhile
        follower = reader
        filterRest = rest
        ansi = colors
        let shift = held.utf16.count
        let runs = heldRuns + readRuns.map { ANSI.Run(NSRange(location: $0.range.location + shift, length: $0.range.length), $0.style) }
        guard followTask != nil else { (held, heldRuns) = (held + read, runs); return }   // f off meanwhile
        let text = held + read, levels = held.isEmpty ? readLevels : ANSIColors.uncolored(TextFormat.logLevels(in: text), runs)
        (held, heldRuns) = ("", [])
        guard !text.isEmpty, let storage = textView.textStorage, let lm = textView.layoutManager else { return }
        let clip = scroll.contentView
        let atEnd = clip.bounds.maxY >= textView.frame.height - 20
        let start = storage.length
        storage.append(NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: NSColor.textColor]))
        Self.tint(storage, levels, offset: start)
        ANSIColors.apply(runs, to: storage, offset: start, font: Self.font)
        let cut = FollowReader.trimCount(storage.mutableString, limit: followLimit)
        if cut > 0 {   // the lines that go still count
            dropped += storage.mutableString.substring(to: cut).utf16.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
            ruler?.firstLine = dropped
        }
        if cut > 0 {   // keep what's on screen in place
            let dy = atEnd ? 0 : lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: cut), effectiveRange: nil).minY
            let top = clip.bounds.origin
            storage.deleteCharacters(in: NSRange(location: 0, length: cut))
            if dy > 0 {
                lm.ensureLayout(for: textView.textContainer!)
                clip.scroll(to: NSPoint(x: top.x, y: max(0, top.y - dy)))
                scroll.reflectScrolledClipView(clip)
            }
        }
        ruler?.invalidate()
        if atEnd { textView.scrollToEndOfDocument(nil) }
    }

    private func setWrap(_ on: Bool) {
        // A big file's window: the same text stays at the top left, and the toggle's own scrolling slides nothing.
        let lm = textView.layoutManager!, tc = textView.textContainer!
        let keep = big != nil && textView.string.utf16.count > 0 ? lm.characterIndexForGlyph(at: topLeftGlyph(lm, tc)) : nil
        let wasSliding = sliding
        sliding = true
        defer { sliding = wasSliding }
        wrap = on
        if on {
            scroll.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            tc.widthTracksTextView = true
            tc.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            textView.frame.size.width = scroll.contentSize.width
        } else {
            scroll.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            tc.widthTracksTextView = false
            tc.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        if let keep { scroll(toChar: keep, delta: 0, dx: -tc.lineFragmentPadding - textView.textContainerOrigin.x) }
    }
}

// MARK: - Huge files: a sliding window over the memory-mapped file

extension Viewer {
    /// Bigger text lays out too slowly whole (TextKit 1: ~1 s for End, f or w at 4 MB, 3–9 s at 32 MB).
    fileprivate nonisolated static let hugeLimit = 4 << 20

    /// Over 4 MB and not a compressed log that unpacks (those are read capped): a .zst the app can't unpack, or a
    /// plain file only named .gz, still gets the mmap window and the whole-file hex.
    nonisolated static func isHuge(_ path: String) -> Bool {   // internal for tests
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) > hugeLimit
            && !(CompressedFile.matches(path) && CompressedFile.read(path, limit: 0) != nil)
    }
    /// A rotated log that unpacks to over 4 MB of text, unpacked (up to 32 MB) to a temp file the window then maps,
    /// with what its subtitle says about the original. nil for a smaller or binary one: `read` shows those whole.
    nonisolated static func unpackHuge(_ url: URL, asText: Bool) -> (url: URL, label: String)? {   // internal for tests
        guard let z = CompressedFile.read(url.path, limit: 32 << 20), z.data.count > hugeLimit,
              asText || !TextFormat.looksBinary(z.data) else { return nil }
        let copy = URL(fileURLWithPath: NSTemporaryDirectory() + "dfm-archive-unpacked-" + UUID().uuidString)   // swept if left behind
        guard (try? z.data.write(to: copy)) != nil else { return nil }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        return (copy, unpackedInfo(z, ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
    }

    /// Laid out in full before scrolling so positions are exact; 256 KB lays out in ~70 ms (1 MB: ~280 ms). Its
    /// escape sequences are colors, not text: a place in a line maps back to the file's bytes past them (`ANSI.bytes`).
    fileprivate static let windowSize = 256 << 10

    /// Maps the file (once) and shows the window around `offset` (`.max`: the end).
    fileprivate func openBig(around offset: Int = 0) {
        func show(_ d: Data) {
            let o = min(offset, d.count)
            if lineFilter != nil { showFiltered(d) } else { showWindow(around: o, top: o) }
        }
        if let big { return show(big) }
        let url = url, asText = asText
        spinner.startAnimation(nil)
        loadGen += 1   // a load started meanwhile (h right after a truncate's remap) wins
        let gen = loadGen
        Task { [weak self] in
            let mapped = await Blocking.run { () -> (BigFile.Mapped, binary: Bool)? in
                guard let m = BigFile.map(url.path) else { return nil }
                return (m, !asText && TextFormat.looksBinary(m.data.dropFirst(Self.dataStart(url.path))))
            }
            guard let self, gen == loadGen else { return }
            guard let mapped, !mapped.binary else { return load(.hex) }
            big = mapped.0.data
            bigFile = mapped.0
            followOffset = UInt64(mapped.0.data.count)
            show(mapped.0.data)
        }
    }

    /// Where a sparse file's first data is (a copytruncate log's hole can be gigabytes: not read through); 0 if none.
    nonisolated static func dataStart(_ path: String) -> Int {
        let fd = Darwin.open(path, O_RDONLY)
        defer { if fd >= 0 { Darwin.close(fd) } }
        return fd < 0 ? 0 : max(0, Int(lseek(fd, 0, SEEK_DATA)))
    }

    /// The file got shorter than its mapping (truncated under us): touching the lost pages would crash (SIGBUS).
    /// Maps it again and shows the same place, saying so; true if it did.
    /// ponytail: stat-then-touch still races a truncate in between (the window's copy, `visibleTop`: microseconds;
    /// the whole-file `/` and `&` read the file itself); reading windows with pread instead of mmap would close that.
    fileprivate func remapIfShrunk(near offset: Int) -> Bool {
        var st = stat()
        guard let big, stat(url.path, &st) == 0, Int(st.st_size) < big.count else { return false }
        self.big = nil
        truncated = true
        openBig(around: offset)
        return true
    }

    /// Shows the window around `offset` with the row holding byte `top` at the top of the view (moved down by
    /// `delta` points, and that byte `dx` points right of the view's left edge, to keep the picture still while
    /// sliding; without `dx` it is just brought into view), optionally selecting `select` from there.
    func showWindow(around offset: Int, top: Int, delta: CGFloat = 0, dx: CGFloat? = nil, select: String? = nil) {
        guard let big, !remapIfShrunk(near: offset) else { return }
        sliding = true
        loadGen += 1
        let gen = loadGen
        let size = Self.windowSize
        Task { [weak self] in
            let (w, text, enc, levels, line, inLine, runs) = await Blocking.run(.userInitiated) {
                () -> (Range<Int>, String, String, [(range: NSRange, level: TextFormat.Level)], Int, Int, [ANSI.Run]) in
                let w = BigFile.window(big, around: offset, size: size)
                let (decoded, enc) = TextFormat.decode(big.subdata(in: w))
                let (text, runs) = ANSI.parse(decoded)   // colors, not escape sequences
                // `top` as a line of the window and characters into it (it can be deep inside a long line)
                let t = min(max(top, w.lowerBound), w.upperBound), line = BigFile.newlines(big, w.lowerBound..<t)
                let from = BigFile.lineOffset(big, from: w.lowerBound, line: line)
                let inLine = ANSI.units(big.subdata(in: from..<t), singleByte: enc == "Windows-1251")
                return (w, text, enc, ANSIColors.uncolored(TextFormat.logLevels(in: text), runs), line, inLine, runs)
            }
            guard let self, gen == loadGen else { return }
            spinner.stopAnimation(nil)
            win = w
            winEncoding = enc
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: NSColor.textColor]))
            Self.tint(textView.textStorage!, levels, offset: 0)
            ANSIColors.apply(runs, to: textView.textStorage!, font: Self.font)
            let ns = textView.string as NSString, ch = min(charIndex(ofLine: line) + inLine, ns.length)
            scroll(toChar: ch, delta: delta, dx: dx)
            var shown = NSRange(location: ch, length: 0)
            if let select {
                let r = ns.range(of: select, options: .caseInsensitive, range: NSRange(location: ch, length: min(ns.length - ch, 1 << 16)))
                if r.location != NSNotFound { shown = r; textView.setSelectedRange(r); textView.showFindIndicator(for: r) }
            }
            if dx == nil { textView.scrollRangeToVisible(shown) }   // without wrap, a long line's place may be off to the side
            let fmt = { (n: Int) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
            info = (truncated ? "file truncated · " : "") + "\(label ?? fmt(big.count)) · \(enc) · showing \(fmt(w.lowerBound))–\(fmt(w.upperBound)) (\(w.lowerBound * 100 / max(big.count, 1))%)"
            truncated = false
            updateSubtitle()
            sliding = false
        }
    }

    /// The & filter over the whole file (read in pieces, not through the mapping: a truncate during the scan would be
    /// SIGBUS): its kept lines (as many as load whole), shown whole — no window to slide. Following, a poll waits
    /// (`sliding`) so nothing it appends is replaced.
    fileprivate func showFiltered(_ d: Data) {
        guard let filter = lineFilter, let file = bigFile else { return }
        sliding = true
        loadGen += 1
        let gen = loadGen
        spinner.startAnimation(nil)
        Task { [weak self] in
            let (text, enc, levels, more, runs) = await Blocking.run(.userInitiated) {
                () -> (String, String, [(range: NSRange, level: TextFormat.Level)], Bool, [ANSI.Run]) in
                let (kept, more) = filter.apply(file, limit: Self.hugeLimit)
                let (decoded, enc) = TextFormat.decode(kept)
                let (text, runs) = ANSI.parse(decoded)
                return (text, enc, ANSIColors.uncolored(TextFormat.logLevels(in: text), runs), more, runs)
            }
            guard let self, gen == loadGen else { return }
            spinner.stopAnimation(nil)
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: NSColor.textColor]))
            Self.tint(textView.textStorage!, levels, offset: 0)
            ANSIColors.apply(runs, to: textView.textStorage!, font: Self.font)
            if followTask != nil { textView.scrollToEndOfDocument(nil) } else { textView.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
            let fmt = { (n: Int) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
            info = "\(label ?? fmt(d.count)) · \(enc)" + (more ? " · first \(fmt(Self.hugeLimit)) of matching lines" : "")
            updateSubtitle()
            sliding = false
        }
    }

    /// Scrolling into either edge of the window slides it, keeping the top line where it is on screen. A window of
    /// a few long unwrapped rows (minified JSON, a wide CSV) is no taller than the view: its edges are left and right,
    /// and column 0 of several rows is where the next row starts, not the window's start: going back takes pulling
    /// past the edge (a trackpad's overscroll), or Home / g. A resize's own scrolling slides nothing.
    @objc fileprivate func scrolled() {
        if followTask != nil {   // L4: scrolled up, it stays put while lines come in — the subtitle says so
            let paused = scroll.contentView.bounds.maxY < textView.frame.height - 20
            if paused != followPaused { followPaused = paused; updateSubtitle() }
        }
        guard let big, !sliding, !scroll.inLiveResize, mode == .text, followTask == nil, lineFilter == nil, let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let b = scroll.contentView.bounds, f = textView.frame, used = lm.usedRect(for: tc).height
        let tall = wrap || used > b.height, oneRow = used < 2 * lm.defaultLineHeight(for: Self.font)
        let left = -scroll.contentView.contentInsets.left, past = b.minX < left || b.minY < -scroll.contentView.contentInsets.top
        let atEnd = (tall ? b.maxY >= f.height - 1 : b.maxX >= f.width - 1) && win.upperBound < big.count
        let atStart = (tall ? b.minY <= 0 : past || oneRow && b.minX <= left) && win.lowerBound > 0
        guard atEnd || atStart, let top = visibleTop() else { return }
        let w = BigFile.window(big, around: top.offset, size: Self.windowSize)
        if tall, atEnd ? w.upperBound > win.upperBound : w.lowerBound < win.lowerBound {
            showWindow(around: top.offset, top: top.offset, delta: top.delta, dx: top.dx)   // the top line stays put
        } else {   // that wouldn't move it on (a few long rows, or rows filling the view): a page past its edge
            let at = atEnd ? win.upperBound : win.lowerBound
            showWindow(around: at, top: at)
        }
    }

    /// File offset of the character at the view's top left (the start of the top row, unless scrolled sideways), how
    /// far (points) the view is scrolled past that row's top, and how far right of that character the view's left edge is.
    func visibleTop() -> (offset: Int, delta: CGFloat, dx: CGFloat)? {
        guard let big, !remapIfShrunk(near: win.lowerBound), let lm = textView.layoutManager, let tc = textView.textContainer, textView.string.utf16.count > 0 else { return nil }
        let b = scroll.contentView.bounds, o = textView.textContainerOrigin, g = topLeftGlyph(lm, tc)
        let ch = lm.characterIndexForGlyph(at: g), rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let line = textView.string.utf16.prefix(ch).reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        let from = BigFile.lineOffset(big, from: win.lowerBound, line: line), units = ch - charIndex(ofLine: line)
        let end = big[from..<max(from, win.upperBound)].firstIndex(of: 10) ?? max(from, win.upperBound)   // its line, as the window has it
        return (from + ANSI.bytes(big.subdata(in: from..<end), units: units, singleByte: winEncoding == "Windows-1251"), b.minY - o.y - rect.minY,
                b.minX - o.x - rect.minX - lm.location(forGlyphAt: g).x)
    }

    /// The glyph at the view's top left.
    fileprivate func topLeftGlyph(_ lm: NSLayoutManager, _ tc: NSTextContainer) -> Int {
        let b = scroll.contentView.bounds, o = textView.textContainerOrigin
        return lm.glyphIndex(for: NSPoint(x: max(0, b.minX - o.x), y: max(0, b.minY - o.y)), in: tc)
    }

    /// UTF-16 index where line `n` of the shown text starts.
    private func charIndex(ofLine n: Int) -> Int {
        guard n > 0 else { return 0 }
        var seen = 0, i = 0
        for c in textView.string.utf16 {
            i += 1
            if c == 10 { seen += 1; if seen == n { return i } }
        }
        return i
    }

    private func scroll(toChar idx: Int, delta: CGFloat, dx: CGFloat?) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, textView.string.utf16.count > 0 else { return }
        lm.ensureLayout(for: tc)   // the view's height must be final, or the scroll position gets clamped short
        textView.sizeToFit()
        let g = lm.glyphIndexForCharacter(at: min(idx, textView.string.utf16.count - 1))
        let rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil), o = textView.textContainerOrigin
        let clip = scroll.contentView
        let x = dx.map { rect.minX + lm.location(forGlyphAt: g).x + o.x + $0 } ?? clip.bounds.minX
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: x, y: rect.minY + o.y + delta), size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: Go to / find in the whole file

    private func ask(_ message: String, value: String, then: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { r in
            MainActor.assumeIsolated { if r == .alertFirstButtonReturn { then(field.stringValue) } }
        }
    }

    fileprivate func goToDialog() {
        let size = big?.count ?? ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        ask("Go to: 50%, 1.5G, 4096 or end", value: "") { [weak self] s in
            guard let self else { return }
            guard let pos = BigFile.position(s, size: size) else { return NSSound.beep() }
            if mode == .hex {
                hexOffset = UInt64(pos) & ~15
                load(.hex)
            } else {
                showWindow(around: pos, top: pos)   // remaps first if the file shrank
            }
        }
    }

    fileprivate func filterDialog() {
        ask("Show only lines with (!text: lines without it; empty: no text filter):", value: lineFilter?.spec ?? "") { [weak self] s in
            guard let self else { return }
            setLineFilter(Self.filter(s, level: lineFilter?.level))
        }
    }

    /// `&`'s text with `e`'s level kept: the level alone when the text is empty, nil when neither.
    nonisolated static func filter(_ spec: String, level: TextFormat.Level?) -> LineFilter? {
        var f = LineFilter(spec)
        if let level { if f == nil { f = LineFilter(level: level) } else { f!.level = level } }
        return f
    }

    /// Shows the text again through `filter` (nil: all of it), in text mode; a huge file is remapped first, so a
    /// follow goes on from its new end.
    func setLineFilter(_ filter: LineFilter?) {   // internal for tests
        guard filter != lineFilter || mode == .hex else { return }
        lineFilter = filter
        guard isHuge else { return load(mode == .hex ? .text : mode) }
        mode = .text
        big = nil
        openBig(around: followTask != nil ? .max : 0)
    }

    fileprivate func findDialog() {
        ask("Find in the whole file (case-insensitive):", value: findNeedle) { [weak self] s in
            guard let self, !s.isEmpty else { return }
            findNeedle = s
            lastMatch = nil
            find(from: visibleTop()?.offset ?? 0)
        }
    }

    func find(from start: Int) {
        guard !findNeedle.isEmpty else { return findDialog() }
        guard let file = bigFile else { return }
        let needle = Array(findNeedle.utf8), shown = findNeedle
        window?.subtitle = "Searching for “\(shown)”…"
        Task { [weak self] in
            // Through the mapped file's descriptor, not the mapping: a truncate during a scan of seconds would be SIGBUS.
            let hit = await Blocking.run(.userInitiated) { BigFile.find(needle, in: file, from: start, caseSensitive: false) }
            guard let self else { return }
            guard let hit else {
                NSSound.beep()
                window?.subtitle = "“\(shown)” not found below this point"
                return
            }
            lastMatch = hit
            showWindow(around: hit, top: hit, delta: -scroll.contentView.bounds.height / 3, select: shown)
        }
    }
}

private final class ViewerTextView: NSTextView {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

/// ⌃Q's own view of a text Quick Look would show as an icon (`TextFormat.previewsAsText`): read-only, F3's colors and
/// line numbers, the file's first `limit` bytes.
final class TextPeek: NSScrollView {
    nonisolated static let limit = 256 << 10
    let textView = NSTextView(usingTextLayoutManager: false)   // TextKit 1: the line-number gutter
    private var ruler: LineNumberRuler?

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        documentView = textView
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The file's text as shown, read and colored off the main thread; nil for what Quick Look shows (binary, not a
    /// regular file, unreadable). Past `limit`: the first part, and a line that says so.
    nonisolated static func read(_ url: URL) -> Viewer.Painted? {
        guard FileInfo.notRegular(url.path) == nil, let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: limit + 1)) ?? Data()
        guard TextFormat.previewsAsText(url.lastPathComponent, head: head) else { return nil }
        let more = head.count > limit ? "\n\n··· first \(limit >> 10) KB · F3 views it all ···\n" : ""
        return Viewer.painted(TextFormat.decode(head.prefix(limit)).text + more, name: url.lastPathComponent)
    }

    /// `top`: a new file, shown from its start; else the same one again (a re-list), where it was.
    func show(_ p: Viewer.Painted, numbers: Bool, top: Bool = true) {
        let at = contentView.bounds.origin
        Viewer.show(p, in: textView)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.sizeToFit()   // laid out while hidden, it kept the last file's height: lines past it weren't drawn
        if top { textView.scrollRangeToVisible(NSRange(location: 0, length: 0)) } else { contentView.scroll(to: at); reflectScrolledClipView(contentView) }
        if numbers, ruler == nil {
            ruler = LineNumberRuler(textView: textView)
            verticalRulerView = ruler
            hasVerticalRuler = true
        }
        rulersVisible = numbers
        ruler?.invalidate()
    }
}
