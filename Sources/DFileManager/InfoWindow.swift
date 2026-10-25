import AppKit
import CryptoKit
import DFMCore
import UniformTypeIdentifiers

/// ⌘I: everything an admin wants about one file, plus quick fixes
/// (chmod, chown, hidden/locked flags, quarantine removal, checksums, code signature).
@MainActor
final class InfoWindow: NSWindowController, NSWindowDelegate {
    private static var open: [InfoWindow] = []
    private let path: String
    private let textView: NSTextView
    private let modeField = NSTextField(string: "")
    private let ownerField = NSTextField(string: "")
    private let hiddenBox = NSButton(checkboxWithTitle: "Hidden", target: nil, action: nil)
    private let lockedBox = NSButton(checkboxWithTitle: "Locked (uchg)", target: nil, action: nil)
    private var extra: [String] = []   // lines filled in asynchronously (sizes, hashes, signature)
    private let cancel = CancelFlag()   // set on close: stops a quarantine walk
    private var shown: Snapshot?
    private var contents: String?   // a folder's, once measured
    private var reads = 0

    static func show(_ url: URL) {
        let w = InfoWindow(url.path)
        open.append(w)
        w.showWindow(nil)
    }

    private init(_ path: String) {
        self.path = path
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Info — " + (path as NSString).lastPathComponent.bidiVisible
        w.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init(window: w)
        w.delegate = self
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 8, height: 8)

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
        for f in [modeField, ownerField] { f.font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
        // Off until the file is read: a click on a box showing "off" for a locked file would unlock it.
        for c in [hiddenBox, lockedBox] as [NSControl] { c.isEnabled = false }
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
        let controls = NSStackView(views: [row1, row2, row3])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)

        let root = NSView()
        for v in [scroll, controls] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controls.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        w.contentView = root
        w.center()
        textView.string = path + "\n\nReading…"
        reload { [weak self] s in
            guard let self, s.isDir else { return }
            contents = "Contents:   calculating…"
            render()
            let cancel = cancel   // closing the window stops the walk
            Task { [weak self] in
                let (files, bytes) = await Blocking.run(.utility) { DirLister.measure(path, isCancelled: { cancel.isCancelled }) }
                guard let self else { return }
                contents = "Contents:   \(files) files, \(Self.bytes(bytes))"
                render()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        cancel.cancel()
        Self.open.removeAll { $0 === self }
    }
    override func cancelOperation(_ sender: Any?) { window?.performClose(nil) }

    // MARK: - Content

    /// What the window shows of the file: read off the main thread (⌘I on a share that stopped answering hung the app).
    struct Snapshot: Sendable {
        var lines: [String]
        var ok = false, isDir = false
        var mode = "", owner = "", hidden = false, locked = false
    }

    /// Reads the file again, off the main thread, then shows it; `then` sees what was read.
    private func reload(then: (@MainActor (Snapshot) -> Void)? = nil) {
        reads += 1
        let n = reads, path = path
        Task { [weak self] in
            let s = await Blocking.run(.userInitiated) { Self.snapshot(path) }
            guard let self, n == reads else { return }
            shown = s
            render()
            then?(s)
        }
    }

    /// The last snapshot and the lines filled in since.
    private func render() {
        guard let s = shown else { return }
        textView.string = (s.lines + [""] + [contents].compactMap { $0 } + extra).joined(separator: "\n")
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
        guard lstat(path, &s) == 0 else { return Snapshot(lines: [path, "", String(cString: strerror(errno))]) }
        let url = URL(fileURLWithPath: path)
        let rv = try? url.resourceValues(forKeys: [.contentTypeKey, .addedToDirectoryDateKey, .localizedTypeDescriptionKey])
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func date(_ t: timespec) -> String { df.string(from: Date(timeIntervalSince1970: Double(t.tv_sec))) }

        var kind = rv?.localizedTypeDescription ?? "?"
        if s.st_mode & S_IFMT == S_IFLNK {
            kind = "Symbolic link → " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "?")
        }
        var lines = [
            "Path:       \(path)",
            "Kind:       \(kind)" + (rv?.contentType.map { "  (\($0.identifier))" } ?? ""),
            "Size:       \(Self.bytes(Int64(s.st_size)))  ·  on disk \(Self.bytes(Int64(s.st_blocks) * 512))",
            "Owner:      \(FileInfo.userName(s.st_uid)) (\(s.st_uid)) : \(FileInfo.groupName(s.st_gid)) (\(s.st_gid))",
            "Mode:       \(FileInfo.modeString(s.st_mode))  (\(FileInfo.octal(s.st_mode)))",
            "Flags:      \(FileInfo.flagNames(s.st_flags).joined(separator: ", ").nilIfEmpty ?? "none")",
            "Created:    \(date(s.st_birthtimespec))",
            "Modified:   \(date(s.st_mtimespec))",
            "Changed:    \(date(s.st_ctimespec))   (inode)",
            "Accessed:   \(date(s.st_atimespec))",
        ]
        if let added = rv?.addedToDirectoryDate { lines.append("Added:      \(df.string(from: added))") }
        lines.append("Inode:      \(s.st_ino)   Links: \(s.st_nlink)   Device: \((s.st_dev >> 24) & 0xff),\(s.st_dev & 0xffffff)")   // major,minor
        let xattrs = FileInfo.xattrs(path)
        lines.append("Xattrs:     " + (xattrs.isEmpty ? "none" : xattrs.map { "\($0.name) (\($0.size) B)" }.joined(separator: "\n            ")))
        if let q = FileInfo.xattrString(path, "com.apple.quarantine") {
            lines.append("Quarantine: \(q)")
        }
        if let acl = FileInfo.acl(path) {
            lines.append("ACL:        " + acl.replacingOccurrences(of: "\n", with: "\n            "))
        }
        return Snapshot(lines: lines, ok: true, isDir: s.st_mode & S_IFMT == S_IFDIR, mode: FileInfo.octal(s.st_mode),
                        owner: "\(FileInfo.userName(s.st_uid)):\(FileInfo.groupName(s.st_gid))",
                        hidden: s.st_flags & UInt32(UF_HIDDEN) != 0, locked: s.st_flags & UInt32(UF_IMMUTABLE) != 0)
    }

    nonisolated private static func bytes(_ n: Int64) -> String {
        n < 1000 ? "\(n) bytes" : "\(n.formatted()) bytes (\(ByteCountFormatter.short(n)))"   // the exact count, then the short one
    }

    /// Reports a failed change (`code`: its errno); for permission errors offers to run `adminCommand` as root instead.
    private func fail(_ what: String, _ code: Int32, adminCommand: String) {
        let alert = NSAlert()
        alert.messageText = "\(what) failed"
        alert.informativeText = String(cString: strerror(code))
        guard code == EPERM || code == EACCES else { return alert.beginSheetModal(for: window!) }
        alert.addButton(withTitle: "Try as Administrator")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            Task {
                if case .failed(let msg) = await Admin.run(adminCommand) {
                    let a = NSAlert()
                    a.messageText = "\(what) failed"
                    a.informativeText = msg
                    a.runModal()
                }
                self?.reload()
            }
        }
    }

    // MARK: - Actions

    // The changes go off the main thread, as the reads do: a share that stopped answering.
    @objc private func applyMode() {
        guard let mode = mode_t(modeField.stringValue, radix: 8), mode <= 0o7777 else { return NSSound.beep() }
        let path = path
        Task {
            let code = await Blocking.run(.userInitiated) { FileInfo.setMode(path, mode) ? 0 : errno }
            if code != 0 { fail("chmod", code, adminCommand: AdminCommand.chmod(String(mode, radix: 8), path)) }
            reload()
        }
    }

    @objc private func applyOwner() {
        let parts = ownerField.stringValue.split(separator: ":").map(String.init)
        guard let user = parts.first, let pw = getpwnam(user) else { return NSSound.beep() }
        var gid = gid_t.max   // -1: leave group unchanged
        if parts.count > 1 {
            guard let gr = getgrnam(parts[1]) else { return NSSound.beep() }
            gid = gr.pointee.gr_gid
        }
        let path = path, uid = pw.pointee.pw_uid, group = gid, owner = ownerField.stringValue
        Task {
            let code = await Blocking.run(.userInitiated) { lchown(path, uid, group) == 0 ? 0 : errno }
            if code != 0 { fail("chown", code, adminCommand: AdminCommand.chown(owner, path)) }
            reload()
        }
    }

    @objc private func toggleFlags() {
        let path = path, hidden = hiddenBox.state == .on, locked = lockedBox.state == .on
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

    /// Off the main thread: a big tree (an Xcode download) takes a while. Closing the window stops it.
    @objc private func removeQuarantine(_ sender: NSButton) {
        sender.isEnabled = false
        extra.append("Quarantine: removing…")
        render()
        let i = extra.count - 1
        let path = path, cancel = cancel
        Task { [weak self] in
            let removed = await Blocking.run(.userInitiated) { FileInfo.removeQuarantine(path, cancel: cancel) }
            guard let self else { return }
            sender.isEnabled = true
            extra[i] = "Quarantine removed from \(removed) item\(removed == 1 ? "" : "s")."
            reload()
        }
    }

    @objc private func signature() {
        extra.append("Code signature: checking…")
        let i = extra.count - 1
        let path = path
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
            guard let self else { return }
            extra[i] = "Code signature:\n  " + out.replacingOccurrences(of: "\n", with: "\n  ")
            render()
        }
    }

    @objc private func md5() { checksum("MD5") }
    @objc private func sha1() { checksum("SHA-1") }
    @objc private func sha256() { checksum("SHA-256") }

    /// The pass the first checksum button started, for the file as it was then (inode, size, date); the other buttons
    /// take its result, waiting for it if it's still reading. A file changed since gets a new pass.
    private var digests: (file: String, pass: Task<Result<[String: String], DigestFailure>, Never>)?
    struct DigestFailure: Error { let text: String }

    private func checksum(_ name: String) {
        extra.append("\(name): computing…")
        let i = extra.count - 1
        let path = path, cancel = cancel   // closing the window stops it
        Task { [weak self] in
            let file = await Blocking.run(.userInitiated) { () -> String in
                var st = stat()
                return stat(path, &st) == 0 ? "\(st.st_ino) \(st.st_size) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)" : ""
            }
            guard let self else { return }
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
            extra[i] = "\(name):".padding(toLength: 12, withPad: " ", startingAt: 0) + text
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
