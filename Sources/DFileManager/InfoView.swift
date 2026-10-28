import AppKit
import CryptoKit
import DFMCore
import UniformTypeIdentifiers

/// ⌘I — Quick View's Info tab (R-48, Р9): everything an admin wants about one file, in rows "name — value", and its
/// quick fixes (chmod, chown, hidden/locked flags, quarantine removal, checksums, code signature). A server's file says
/// what its folder's listing knew; its fix is Permissions & Owner…, which works there. What's on its way (a folder's
/// size, a hash, a quarantine walk) stops when the file shown changes or Quick View closes.
@MainActor
final class InfoView: NSView {
    private(set) var path: String?
    private let textView: NSTextView
    private let scroll: NSScrollView
    private let modeField = NSTextField(string: "")
    private let ownerField = NSTextField(string: "")
    private let hiddenBox = NSButton(checkboxWithTitle: "Hidden", target: nil, action: nil)
    private let lockedBox = NSButton(checkboxWithTitle: "Locked (uchg)", target: nil, action: nil)
    private let localControls = NSStackView()
    private let serverControls = NSStackView()
    private var extra: [(String, String)] = []   // rows filled in later (hashes, signature, quarantine)
    private var cancel = CancelFlag()   // the file shown changed, or Quick View closed: stops a walk, a hash
    private var shown: Snapshot?
    private var server: [(String, String)]?
    private var contents: String?   // a folder's, once measured
    private var reads = 0
    /// Runs a command of the app's (a server file's Permissions & Owner…).
    var onCommand: ((String) -> Void)?
    /// What it says now, row by row (tests).
    private(set) var rows: [(String, String)] = []
    var controlsShown: Bool { !localControls.isHidden || !serverControls.isHidden }   // tests

    init() {
        scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init(frame: .zero)
        textView.isEditable = false
        textView.drawsBackground = false
        scroll.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)

        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            return b
        }
        modeField.placeholderString = "0644"
        modeField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        ownerField.placeholderString = "user:group"
        ownerField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        for f in [modeField, ownerField] { f.font = .monospacedSystemFont(ofSize: 12, weight: .regular); f.controlSize = .small }
        // Off until the file is read: a click on a box showing "off" for a locked file would unlock it.
        for c in [hiddenBox, lockedBox] as [NSControl] { c.isEnabled = false; c.controlSize = .small }
        hiddenBox.target = self
        hiddenBox.action = #selector(toggleFlags)
        lockedBox.target = self
        lockedBox.action = #selector(toggleFlags)

        let row1 = NSStackView(views: [NSTextField(labelWithString: "Mode"), modeField, button("chmod", #selector(applyMode)),
                                       NSTextField(labelWithString: "  Owner"), ownerField, button("chown", #selector(applyOwner))])
        let row2 = NSStackView(views: [hiddenBox, lockedBox, button("Remove Quarantine", #selector(removeQuarantine(_:))),
                                       button("Code Signature", #selector(signature))])
        let row3 = NSStackView(views: [NSTextField(labelWithString: "Checksum"), button("MD5", #selector(md5)),
                                       button("SHA-1", #selector(sha1)), button("SHA-256", #selector(sha256))])
        for r in [row1, row2, row3] { r.spacing = 6; localControls.addArrangedSubview(r) }
        localControls.orientation = .vertical
        localControls.alignment = .leading
        serverControls.addArrangedSubview(button("Permissions & Owner…", #selector(serverAttributes)))
        for v in [localControls, serverControls] {
            v.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)
            v.setHuggingPriority(.required, for: .vertical)
        }
        let stack = NSStackView(views: [scroll, localControls, serverControls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.distribution = .fill
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        serverControls.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A file (or folder) on this Mac: read off the main thread (⌘I on a share that stopped answering hung the app); a
    /// folder's contents counted once the cursor has rested on it a moment.
    func show(local path: String) {
        guard path != self.path || server != nil else { return }
        stop()
        self.path = path
        server = nil
        localControls.isHidden = false
        serverControls.isHidden = true
        hiddenBox.isEnabled = false
        lockedBox.isEnabled = false
        rows = [("Path", path), ("", "Reading…")]
        draw()
        reload { [weak self] s in
            guard let self, s.isDir else { return }
            let cancel = cancel
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))   // passing over folders: none is walked
                guard let self, !cancel.isCancelled else { return }
                contents = "calculating…"
                render()
                let (files, bytes) = await Blocking.run(.utility) { DirLister.measure(path, isCancelled: { cancel.isCancelled }) }
                guard !cancel.isCancelled else { return }
                contents = "\(files) files, \(Self.bytes(bytes))"
                render()
            }
        }
    }

    /// A server's file, as its folder's listing knew it: nothing is asked of the server for it.
    /// `controls`: Permissions & Owner… — a server file's; not a list row's (a port, a service).
    func show(server rows: [(String, String)], controls: Bool = true) {
        stop()
        path = nil
        server = rows
        localControls.isHidden = true
        serverControls.isHidden = !controls
        self.rows = rows
        draw()
    }

    /// Quick View closed, or the file went: what's on its way stops.
    func stop() {
        cancel.cancel()
        cancel = CancelFlag()
        reads += 1
        shown = nil
        contents = nil
        extra = []
        digests = nil
        path = nil
    }

    /// What a server's file's Info says, from its folder's listing: where, what, how big, when, whose, which mode.
    static func serverRows(server: String, path: String, item: FileItem, owner: (String, String)?, link: String?) -> [(String, String)] {
        let kind = switch item.kind {
        case .dir: "Folder"
        case .link: "Symbolic link" + (link.map { " → \($0)" } ?? "")
        case .other: PanelViewController.specialKind(item) ?? "Special file"
        case .file: "File"
        }
        var rows = [("Server", server), ("Path", path), ("Kind", kind)]
        if item.kind != .dir { rows.append(("Size", bytes(item.size))) }
        rows.append(("Modified", date(Date(timeIntervalSince1970: item.mtime))))
        if let owner { rows.append(("Owner", "\(owner.0) : \(owner.1)")) }
        rows.append(("Mode", "\(Perms.string(item.mode))  (\(String(item.mode & 0o7777, radix: 8)))"))
        return rows
    }

    nonisolated static func date(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.string(from: d)
    }

    /// The rows as text: each name in a column of its own, its value beside it, a long one wrapping under itself.
    private func draw() {
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 96)]
        para.headIndent = 96
        para.paragraphSpacing = 2
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]
        let value: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.labelColor,
                                                    .paragraphStyle: para]
        let s = NSMutableAttributedString()
        for (i, (name, v)) in rows.enumerated() {
            s.append(NSAttributedString(string: (i == 0 ? "" : "\n") + name + "\t", attributes: label))
            s.append(NSAttributedString(string: v.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: value))
        }
        textView.textStorage?.setAttributedString(s)
    }

    // MARK: - Content

    /// What Info shows of a file here: read off the main thread.
    struct Snapshot: Sendable {
        var rows: [(String, String)]
        var ok = false, isDir = false
        var mode = "", owner = "", hidden = false, locked = false
    }

    /// Reads the file again, off the main thread, then shows it; `then` sees what was read.
    private func reload(then: (@MainActor (Snapshot) -> Void)? = nil) {
        reads += 1
        guard let path else { return }
        let n = reads
        Task { [weak self] in
            let s = await Blocking.run(.userInitiated) { Self.snapshot(path) }
            guard let self, n == reads else { return }
            shown = s
            render()
            then?(s)
        }
    }

    /// The last snapshot, a folder's contents and the rows filled in since.
    private func render() {
        guard let s = shown else { return }
        rows = s.rows + [contents.map { ("Contents", $0) }].compactMap { $0 } + extra
        draw()
        hiddenBox.isEnabled = s.ok
        lockedBox.isEnabled = s.ok
        guard s.ok else { return }
        if window?.firstResponder !== modeField.currentEditor() { modeField.stringValue = s.mode }
        if window?.firstResponder !== ownerField.currentEditor() { ownerField.stringValue = s.owner }
        hiddenBox.state = s.hidden ? .on : .off
        lockedBox.state = s.locked ? .on : .off
    }

    nonisolated static func snapshot(_ path: String) -> Snapshot {
        var s = stat()
        guard lstat(path, &s) == 0 else { return Snapshot(rows: [("Path", path), ("Error", String(cString: strerror(errno)))]) }
        let url = URL(fileURLWithPath: path)
        let rv = try? url.resourceValues(forKeys: [.contentTypeKey, .addedToDirectoryDateKey, .localizedTypeDescriptionKey])
        func date(_ t: timespec) -> String { Self.date(Date(timeIntervalSince1970: Double(t.tv_sec))) }

        var kind = rv?.localizedTypeDescription ?? "?"
        if s.st_mode & S_IFMT == S_IFLNK {
            kind = "Symbolic link → " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "?")
        }
        var rows = [
            ("Path", path),
            ("Kind", kind + (rv?.contentType.map { "  (\($0.identifier))" } ?? "")),
            ("Size", "\(Self.bytes(Int64(s.st_size)))  ·  on disk \(Self.bytes(Int64(s.st_blocks) * 512))"),
            ("Owner", "\(FileInfo.userName(s.st_uid)) (\(s.st_uid)) : \(FileInfo.groupName(s.st_gid)) (\(s.st_gid))"),
            ("Mode", "\(FileInfo.modeString(s.st_mode))  (\(FileInfo.octal(s.st_mode)))"),
            ("Flags", FileInfo.flagNames(s.st_flags).joined(separator: ", ").nilIfEmpty ?? "none"),
            ("Created", date(s.st_birthtimespec)),
            ("Modified", date(s.st_mtimespec)),
            ("Changed", date(s.st_ctimespec) + "   (inode)"),
            ("Accessed", date(s.st_atimespec)),
        ]
        if let added = rv?.addedToDirectoryDate { rows.append(("Added", Self.date(added))) }
        rows.append(("Inode", "\(s.st_ino)   Links: \(s.st_nlink)   Device: \((s.st_dev >> 24) & 0xff),\(s.st_dev & 0xffffff)"))   // major,minor
        let xattrs = FileInfo.xattrs(path)
        rows.append(("Xattrs", xattrs.isEmpty ? "none" : xattrs.map { "\($0.name) (\($0.size) B)" }.joined(separator: "\n")))
        if let q = FileInfo.xattrString(path, "com.apple.quarantine") { rows.append(("Quarantine", q)) }
        if let acl = FileInfo.acl(path) { rows.append(("ACL", acl)) }
        return Snapshot(rows: rows, ok: true, isDir: s.st_mode & S_IFMT == S_IFDIR, mode: FileInfo.octal(s.st_mode),
                        owner: "\(FileInfo.userName(s.st_uid)):\(FileInfo.groupName(s.st_gid))",
                        hidden: s.st_flags & UInt32(UF_HIDDEN) != 0, locked: s.st_flags & UInt32(UF_IMMUTABLE) != 0)
    }

    nonisolated static func bytes(_ n: Int64) -> String {
        n < 1000 ? "\(n) bytes" : "\(n.formatted()) bytes (\(ByteCountFormatter.short(n)))"   // the exact count, then the short one
    }

    /// Reports a failed change (`code`: its errno); for permission errors offers to run `adminCommand` as root instead.
    private func fail(_ what: String, _ code: Int32, adminCommand: String) {
        let alert = NSAlert()
        alert.messageText = "\(what) failed"
        alert.informativeText = String(cString: strerror(code))
        guard let window else { return }
        guard code == EPERM || code == EACCES else { return alert.beginSheetModal(for: window) }
        alert.addButton(withTitle: "Try as Administrator")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                if case .failed(let msg) = await Admin.run(adminCommand), let window = self?.window {
                    let a = NSAlert()
                    a.messageText = "\(what) failed"
                    a.informativeText = msg
                    a.beginSheetModal(for: window) { _ in }
                }
                self?.reload()
            }
        }
    }

    // MARK: - Actions

    // The changes go off the main thread, as the reads do: a share that stopped answering.
    @objc private func applyMode() {
        guard let path, let mode = mode_t(modeField.stringValue, radix: 8), mode <= 0o7777 else { return NSSound.beep() }
        Task {
            let code = await Blocking.run(.userInitiated) { FileInfo.setMode(path, mode) ? 0 : errno }
            if code != 0 { fail("chmod", code, adminCommand: AdminCommand.chmod(String(mode, radix: 8), path)) }
            reload()
        }
    }

    @objc private func applyOwner() {
        let parts = ownerField.stringValue.split(separator: ":").map(String.init)
        guard let path, let user = parts.first, let pw = getpwnam(user) else { return NSSound.beep() }
        var gid = gid_t.max   // -1: leave group unchanged
        if parts.count > 1 {
            guard let gr = getgrnam(parts[1]) else { return NSSound.beep() }
            gid = gr.pointee.gr_gid
        }
        let uid = pw.pointee.pw_uid, group = gid, owner = ownerField.stringValue
        Task {
            let code = await Blocking.run(.userInitiated) { lchown(path, uid, group) == 0 ? 0 : errno }
            if code != 0 { fail("chown", code, adminCommand: AdminCommand.chown(owner, path)) }
            reload()
        }
    }

    @objc private func toggleFlags() {
        guard let path else { return }
        let hidden = hiddenBox.state == .on, locked = lockedBox.state == .on
        Task {
            let code = await Blocking.run(.userInitiated) { () -> Int32? in
                var s = stat()
                guard lstat(path, &s) == 0 else { return nil }
                var flags = s.st_flags
                for (on, bit) in [(hidden, UInt32(UF_HIDDEN)), (locked, UInt32(UF_IMMUTABLE))] {
                    if on { flags |= bit } else { flags &= ~bit }
                }
                return lchflags(path, flags) == 0 ? 0 : errno
            }
            guard let code else { return }
            if code != 0 {
                let names = [(hidden, "hidden", "nohidden"), (locked, "uchg", "nouchg")].map { $0.0 ? $0.1 : $0.2 }
                fail("chflags", code, adminCommand: AdminCommand.chflags(names.joined(separator: ","), path))
            }
            reload()
        }
    }

    /// Off the main thread: a big tree (an Xcode download) takes a while. Another file shown, or Quick View closed, stops it.
    @objc private func removeQuarantine(_ sender: NSButton) {
        guard let path else { return }
        sender.isEnabled = false
        extra.append(("Quarantine", "removing…"))
        render()
        let i = extra.count - 1, cancel = cancel
        Task { [weak self] in
            let removed = await Blocking.run(.userInitiated) { FileInfo.removeQuarantine(path, cancel: cancel) }
            sender.isEnabled = true
            guard let self, !cancel.isCancelled, extra.indices.contains(i) else { return }
            extra[i] = ("Quarantine", "removed from \(removed) item\(removed == 1 ? "" : "s")")
            reload()
        }
    }

    @objc private func signature() {
        guard let path else { return }
        extra.append(("Code signature", "checking…"))
        render()
        let i = extra.count - 1, cancel = cancel
        Task { [weak self] in
            let out = await Blocking.run { () -> String in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                p.arguments = ["-dv", "--verbose=2", path]
                let pipe = Pipe()
                p.standardError = pipe
                p.standardOutput = pipe
                guard (try? p.run()) != nil else { return "codesign not available" }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let self, !cancel.isCancelled, extra.indices.contains(i) else { return }
            extra[i] = ("Code signature", out)
            render()
        }
    }

    @objc private func serverAttributes() { onCommand?("file.attrs") }   // ⌘⌥A's: works on a server too

    @objc private func md5() { checksum("MD5") }
    @objc private func sha1() { checksum("SHA-1") }
    @objc private func sha256() { checksum("SHA-256") }

    /// The pass the first checksum button started, for the file as it was then (inode, size, date); the other buttons
    /// take its result, waiting for it if it's still reading. A file changed since gets a new pass.
    private var digests: (file: String, pass: Task<Result<[String: String], DigestFailure>, Never>)?
    struct DigestFailure: Error { let text: String }

    private func checksum(_ name: String) {
        guard let path else { return }
        extra.append((name, "computing…"))
        render()
        let i = extra.count - 1, cancel = cancel   // another file shown, or Quick View closed, stops it
        Task { [weak self] in
            let file = await Blocking.run(.userInitiated) { () -> String in
                var st = stat()
                return stat(path, &st) == 0 ? "\(st.st_ino) \(st.st_size) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)" : ""
            }
            guard let self, !cancel.isCancelled else { return }
            let pass: Task<Result<[String: String], DigestFailure>, Never>
            if let d = digests, d.file == file {
                pass = d.pass
            } else {
                pass = Task { await Blocking.run(.userInitiated) { Self.digests(path, cancel: cancel) } }
                digests = (file, pass)
            }
            let result = await pass.value
            if case .failure = result, digests?.pass == pass { digests = nil }   // the next click tries again
            let text = switch result {
            case .success(let all): all[name] ?? ""
            case .failure(let f): f.text
            }
            guard !cancel.isCancelled, extra.indices.contains(i) else { return }
            extra[i] = (name, text)
            render()
        }
    }

    /// MD5, SHA-1 and SHA-256 of the file, by name, in one read of it (1 MB at a time): on a slow disk three reads
    /// fight each other.
    nonisolated static func digests(_ path: String, cancel: CancelFlag) -> Result<[String: String], DigestFailure> {
        func fail(_ text: String) -> Result<[String: String], DigestFailure> { .failure(DigestFailure(text: text)) }
        var st = stat()   // a placeholder would be downloaded whole just to hash it
        if stat(path, &st) == 0 && st.st_flags & UInt32(SF_DATALESS) != 0 { return fail("skipped: not downloaded (iCloud / Dropbox)") }
        if let what = FileInfo.notRegular(path) { return fail("skipped: \(what)") }   // a FIFO would block the read for good
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return fail("can't read (\(String(cString: strerror(errno))))") }
        defer { Darwin.close(fd) }
        var md5 = Insecure.MD5(), sha1 = Insecure.SHA1(), sha256 = SHA256()
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buf.deallocate() }
        while !cancel.isCancelled {
            let n = Darwin.read(fd, buf.baseAddress, buf.count)
            if n < 0 && errno == EINTR { continue }
            // a read that fails (a disk error, a share gone) says so: a hash of what came before would pass for the file's
            if n < 0 { return fail("can't read (\(String(cString: strerror(errno))))") }
            if n == 0 { break }
            let chunk = UnsafeRawBufferPointer(rebasing: buf[..<n])
            md5.update(bufferPointer: chunk)
            sha1.update(bufferPointer: chunk)
            sha256.update(bufferPointer: chunk)
        }
        if cancel.isCancelled { return fail("stopped") }
        return .success(["MD5": md5.finalize().hex, "SHA-1": sha1.finalize().hex, "SHA-256": sha256.finalize().hex])
    }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
