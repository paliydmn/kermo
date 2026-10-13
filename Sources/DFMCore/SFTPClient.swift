import CryptoKit
import Foundation

/// SFTP v3 spoken directly over the system `ssh … -s sftp` (a root panel's: `ssh … sudo -n -- <sftp-server>`, see
/// `SudoServer`; for `.local()` targets, `/usr/libexec/sftp-server` on pipes), for transfers that need what the `sftp` CLI can't give: per-file errors, conflicts, byte progress,
/// pause and cancel. Login and connection sharing stay OpenSSH's (`SFTP.startMaster`, ControlMaster).
///
/// Blocking calls, made by one worker thread at a time; a reader thread hands each response to its request.
/// Reads and writes are pipelined (`window` requests in flight), as the `sftp` client does.
public final class SFTPClient: @unchecked Sendable {
    public struct Attrs: Sendable, Equatable {
        public var kind: FileItem.Kind
        public var size: Int64
        public var mtime: Double
        public var mode: UInt32?   // permission bits (07777); nil when the server didn't say
        public var uid: UInt32? = nil, gid: UInt32? = nil
        public var type: UInt32 = 0   // S_IFMT of an `.other` (FIFO, socket, device); 0 otherwise
        /// SHA-256 of the content (`download`/`upload` of a file up to `hashLimit`): size and whole-second mtime miss
        /// a same-size change within the second. Never from the server itself.
        public var sha256: Data? = nil

        /// These, if they say what the item is — a listing's may not (SFTP v3 lets a server leave the mode out, and a
        /// lister may not type an entry); nil: ask `lstat`.
        var typed: Attrs? { mode == nil || kind == .other ? nil : self }

        /// A baseline for a file that wasn't there: none matches it, so `upload` asks about one there now.
        public static let nothing = Attrs(kind: .file, size: -1, mtime: 0, mode: nil)
    }

    public let target: SFTPTarget
    /// A root session on a server with SELinux: `upload` writes into the file itself, never renames a new one over it —
    /// the new one would have its folder's label, not the file's (`/etc/shadow` losing `shadow_t`).
    public private(set) var writesInPlace = false
    /// Extensions the server announced (name → version).
    public private(set) var extensions: [String: String] = [:]

    static let chunk = 32_768
    static let window = 64
    /// READDIRs in flight for one folder: a server sends some 100 names an answer (OpenSSH), so 10 000 names were
    /// 100 waits one after another. Each one sent past the end answers an EOF of its own, dropped.
    static let readdirs = 8

    private let process = Process()
    private let toServer: FileHandle
    private let fromServer: FileHandle
    private let writeFD: Int32, readFD: Int32   // FileHandle.fileDescriptor raises once closed
    private let cond = NSCondition()
    private var responses: [UInt32: (type: UInt8, body: Data)] = [:]
    private var ignored = Set<UInt32>()   // answers nobody waits for any more (an abandoned pipeline)
    private var lostReason: String?
    private var answers = 0   // packets heard so far: whether the server is still at work (`closeWhenQuiet`)
    private var nextID: UInt32 = 1
    /// Waits for the server one after another: what a far server makes a job wait for (time ≈ this × RTT; tests count
    /// them). Each wait for a request sent after the last counted wait began counts once — the rest of a batch or
    /// pipeline was in flight with it. One worker thread at a time, as every call. (After 2³² requests the ids wrap
    /// and it stops counting; no test gets there.)
    private(set) var roundTrips = 0
    private var lastSent: UInt32 = 0, waveEnd: UInt32 = 0
    private let errors = ErrorTail()

    public init(_ t: SFTPTarget, env: [String: String] = [:], cancel: CancelFlag? = nil) throws {
        target = t
        try SFTP.startMaster(t, env: env, cancel: cancel)
        var sudoPath = "", sudoPassword: String?
        if t.sudo {
            (sudoPath, sudoPassword, writesInPlace) = try SudoServer.prepare(t, env: env, cancel: cancel)
            let (program, arguments) = SudoServer.launch(t, path: sudoPath, password: sudoPassword != nil)
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = arguments
        } else if let server = t.localServer {
            process.executableURL = URL(fileURLWithPath: server)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // -s: the "sftp" after the host is a subsystem, not a command. Rides on the master startMaster brought up.
            process.arguments = SFTP.connectionOptions(t) + ["-x", "-a", "-s"] + t.arguments() + ["sftp"]
        }
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let input = Pipe(), output = Pipe(), err = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = err
        toServer = input.fileHandleForWriting
        fromServer = output.fileHandleForReading
        writeFD = toServer.fileDescriptor
        readFD = fromServer.fileDescriptor
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)   // a dead server: EPIPE, not a killed app
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        let errHandle = err.fileHandleForReading
        Thread { [errors] in
            // POSIX read: FileHandle.availableData raises (an uncatchable ObjC exception) on some read errors.
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(errHandle.fileDescriptor, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                errors.append(Data(buf[0..<n]))
            }
            try? errHandle.close()
        }.start()
        Thread { [self] in readLoop() }.start()
        let previous = cancel?.onCancel { [self] in close() } ?? nil
        defer { cancel?.onCancel(previous) }

        let late = CancelFlag()   // no answer to a password session: its sudo took the packet as well
        do {
            var hello = Packet(Self.INIT)
            hello.u32(3)
            // sudo reads the password line, then sftp-server the packet: one write, nothing between them.
            try send(hello, after: sudoPassword.map { Data(($0 + "\n").utf8) } ?? Data())
            if sudoPassword != nil {
                DispatchQueue.global().asyncAfter(deadline: .now() + SudoServer.versionWait) { [weak self] in
                    guard let self, isConnected, cond.withLock({ answers }) == 0 else { return }
                    late.cancel()
                    close()
                }
            }
            let (type, body) = try wait(0)
            var r = Reader(body)
            guard type == Self.VERSION, try r.u32() >= 3 else { throw protocolError("unexpected greeting") }
            while !r.atEnd { extensions[try r.text()] = try r.text() }
        } catch {
            close()   // else ssh and the reader thread stay forever
            guard t.sudo else { throw error }
            SudoServer.forget(t)   // sudoers changed since it was looked at, say: looked at again next time
            if late.isCancelled { throw SudoServer.noStdinPassword(t, path: sudoPath) }
            if !(error is CancellationError), cancel?.isCancelled != true, let why = SudoServer.explain(t, path: sudoPath, errors.text) {
                throw SFTPError(message: why, connection: true)
            }
            throw error
        }
    }

    /// A session for `body`, closed after it. `cancel` closes it at any point, connecting or not: whatever waits
    /// for the server fails at once.
    public static func session<T>(_ t: SFTPTarget, env: [String: String] = [:], cancel: CancelFlag,
                                  _ body: (SFTPClient) throws -> T) throws -> T {
        let c = try SFTPClient(t, env: env, cancel: cancel)
        let previous = cancel.onCancel { c.close() }
        defer { cancel.onCancel(previous); c.close() }
        return try body(c)
    }

    /// Ends the session; waiting calls fail with a connection error. Required: the reader thread keeps the client
    /// (and its ssh) alive until then. The pipes stay open until the client goes: closing them here could hand
    /// their numbers to another file while a write is still on its way.
    public func close() {
        lost("Connection closed")
        if process.isRunning { process.terminate() }
    }

    public var isConnected: Bool { cond.withLock { lostReason == nil } }

    /// Ends the session once the server has answered nothing for `seconds`: after cancel, a slow link that still
    /// answers is waited for (writes already sent, then the cleanup), one gone silent is cut off. 5 s, not less: a
    /// 32 KiB write takes over a second below 32 KiB/s, and a link can stall a couple of seconds; cut off then, the
    /// partial file stays (a cancelled job doesn't connect again to remove it).
    public func closeWhenQuiet(_ seconds: Double = 5) {
        let heard = cond.withLock { answers }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            guard isConnected else { return }
            if cond.withLock({ answers }) == heard { close() } else { closeWhenQuiet(seconds) }
        }
    }

    // MARK: - Operations

    /// nil: nothing there. Doesn't follow a symlink.
    public func lstat(_ path: String) throws -> Attrs? {
        do { return try attrs(Self.LSTAT, path) } catch let e as SFTPError where e.code == Self.NO_SUCH_FILE { return nil }
    }

    /// `lstat` of each path, with the requests in flight together (`window` at a time), in the paths' order.
    public func lstat(_ paths: [String]) -> [Result<Attrs?, Error>] {
        each(Self.LSTAT, paths) { t, body, path in
            if t == Self.STATUS {
                do { try status(body, path: path, okOnly: true) } catch let e as SFTPError where e.code == Self.NO_SUCH_FILE { return nil }
            }
            guard t == Self.ATTRS else { throw protocolError("STAT answered \(t)") }
            var r = Reader(body)
            return try r.attrs()
        }
    }

    /// Names with their attributes ("." and ".." left out). Names are as the server sent them: untrusted.
    /// `owners` hears each name's owner and group as the server's `ls -l` line names them (else their numbers).
    public func list(_ dir: String, owners: ((_ name: String, _ owner: String, _ group: String) -> Void)? = nil) throws -> [(name: String, attrs: Attrs)] {
        let handle = try open(dir: dir)
        var inflight: [UInt32] = []
        defer { forget(inflight); closeUnheard(handle) }
        var out: [(name: String, attrs: Attrs)] = []
        while true {
            if inflight.isEmpty {
                for _ in 0..<Self.readdirs {
                    var p = Packet(Self.READDIR)
                    p.string(handle)
                    inflight.append(try send(p))
                }
            }
            let (type, body) = try wait(inflight.removeFirst())
            if type == Self.STATUS, try status(body, path: dir) == Self.EOF { return out }
            out += try names(type, body, owners: owners)
        }
    }

    /// A READDIR answer's entries, "." and ".." left out; `owners` as in `list`.
    private func names(_ type: UInt8, _ body: Data, owners: ((_ name: String, _ owner: String, _ group: String) -> Void)? = nil) throws -> [(name: String, attrs: Attrs)] {
        guard type == Self.NAME else { throw protocolError("READDIR answered \(type)") }
        var r = Reader(body), out: [(name: String, attrs: Attrs)] = []
        for _ in 0..<(try r.u32()) {
            let name = try r.text()
            var long: [Substring] = []   // the `ls -l` line: parsed only when owners are asked for
            if owners == nil { _ = try r.bytes() } else { long = try r.text().split(separator: " ") }
            let a = try r.attrs()
            guard name != "." && name != ".." else { continue }
            out.append((name, a))
            if let owners {
                owners(name, long.count >= 9 ? String(long[2]) : a.uid.map(String.init) ?? "",
                       long.count >= 9 ? String(long[3]) : a.gid.map(String.init) ?? "")
            }
        }
        return out
    }

    /// These folders listed with their requests in flight together (`window` folders at a time): a level of a tree
    /// in a few round trips, not a few per folder. One that can't be opened or read all through is left out.
    func list(_ dirs: [String]) -> [(dir: String, items: [(name: String, attrs: Attrs)])] {
        var out: [(dir: String, items: [(name: String, attrs: Attrs)])] = []
        for start in stride(from: 0, to: dirs.count, by: Self.window) {
            let opening = dirs[start..<min(start + Self.window, dirs.count)].map { d -> (String, UInt32?) in
                var p = Packet(Self.OPENDIR)
                p.string(d)
                return (d, try? send(p))
            }
            var open: [(dir: String, handle: Data, items: [(name: String, attrs: Attrs)], ok: Bool)] = opening.compactMap { d, id in
                guard let id, let a = try? wait(id), a.type == Self.HANDLE, case var r = Reader(a.body), let h = try? r.bytes() else { return nil }
                return (d, h, [], true)
            }
            // Until each says EOF, some after more answers than others. 4 READDIRs each, not `readdirs`: a batch's small
            // folders still end in one wave (a few hundred names, then EOF) without 7 spare EOFs a folder.
            var reading = Array(open.indices)
            while !reading.isEmpty {
                let sent = reading.map { i in
                    (i, (0..<4).map { _ -> UInt32? in
                        var p = Packet(Self.READDIR)
                        p.string(open[i].handle)
                        return try? send(p)
                    })
                }
                reading = sent.compactMap { i, ids in
                    var rest = ids[...]
                    defer { forget(rest.compactMap { $0 }) }   // past the end: EOFs; after a failure: whatever
                    while let next = rest.popFirst() {
                        guard let id = next, let a = try? wait(id) else { open[i].ok = false; return nil }
                        if a.type == Self.STATUS {
                            if (try? status(a.body, path: open[i].dir)) != Self.EOF { open[i].ok = false }
                            return nil
                        }
                        guard let more = try? names(a.type, a.body) else { open[i].ok = false; return nil }
                        open[i].items += more
                    }
                    return i
                }
            }
            open.forEach { closeUnheard($0.handle) }
            out += open.filter(\.ok).map { ($0.dir, $0.items) }
        }
        return out
    }

    /// Bytes below `path` (⌥Space on a server folder), counted as a copy counts them (`FileJob.measure`): nothing
    /// followed, unreadable parts count as nothing. A connection lost or `cancel` midway throws: that's no size.
    /// Level by level, each level's folders listed together (`list(_ dirs:)`): a far server's round trips add up.
    public func measure(_ path: String, cancel: CancelFlag? = nil) throws -> Int64 {
        var bytes: Int64 = 0, level: [String] = []
        func add(_ path: String, _ known: Attrs?) {
            guard let a = known?.typed ?? (try? lstat(path)) ?? nil else { return }
            if a.kind == .dir { level.append(path) } else { bytes += a.size }
        }
        add(path, nil)
        while !level.isEmpty, cancel?.isCancelled != true {
            let dirs = level
            level = []
            for (dir, items) in list(dirs) {
                for c in items where FileJob.isSafeName(c.name) { add((dir as NSString).appendingPathComponent(c.name), c.attrs) }
            }
        }
        if cancel?.isCancelled == true { throw CancellationError() }
        if !isConnected { throw lostError() }
        return bytes
    }

    public func mkdir(_ path: String, mode: UInt32 = 0o755) throws {
        var p = Packet(Self.MKDIR)
        p.string(path)
        p.u32(Self.ATTR_PERMISSIONS)
        p.u32(mode)
        try expectOK(p, path)
    }

    /// A folder, or a symlink to one (what a copy goes into, as on this Mac); false when nothing is there.
    public func isFolder(_ path: String) throws -> Bool {
        guard let a = try lstat(path) else { return false }
        return a.kind == .dir || a.kind == .link && (try? stat(path))?.kind == .dir   // a dangling link: not a folder
    }

    /// `mkdir -p`: each missing folder on the way. Fails if something on the way is a file.
    public func makeDirectories(_ path: String) throws {
        var p = ""
        for part in path.split(separator: "/") {
            p += "/" + part
            guard let a = try lstat(p) else { try mkdir(p); continue }
            if a.kind != .dir && a.kind != .link { throw SFTPError(message: "“\(p)” is not a folder") }
        }
    }

    public func rmdir(_ path: String) throws { try simple(Self.RMDIR, path) }
    public func remove(_ path: String) throws { try simple(Self.REMOVE, path) }

    /// Removes these files (not folders) with their requests in flight together (`window` at a time): a folder of
    /// thousands goes in a few round trips, not one each. The ones that didn't go, with why.
    public func remove(_ paths: [String]) -> [(path: String, error: Error)] { failures(Self.REMOVE, paths) }
    /// These empty folders, as `remove(_ paths:)` does files.
    public func rmdir(_ paths: [String]) -> [(path: String, error: Error)] { failures(Self.RMDIR, paths) }

    private func failures(_ type: UInt8, _ paths: [String]) -> [(path: String, error: Error)] {
        zip(paths, each(type, paths) { t, body, path in
            guard t == Self.STATUS else { throw protocolError("\(type == Self.REMOVE ? "REMOVE" : "RMDIR") answered \(t)") }
            try status(body, path: path, okOnly: true)
        }).compactMap { path, r in
            guard case .failure(let e) = r else { return nil }
            return (path, e)
        }
    }

    /// A `type` request for each path, `window` in flight; each answer through `answer`, in the paths' order.
    private func each<T>(_ type: UInt8, _ paths: [String], _ answer: (_ type: UInt8, _ body: Data, _ path: String) throws -> T) -> [Result<T, Error>] {
        var out: [Result<T, Error>] = [], inflight: [(id: Result<UInt32, Error>, path: String)] = []
        func settle(_ r: (id: Result<UInt32, Error>, path: String)) {
            out.append(Result { let (t, body) = try wait(try r.id.get()); return try answer(t, body, r.path) })
        }
        for path in paths {
            var p = Packet(type)
            p.string(path)
            inflight.append((Result { try send(p) }, path))
            if inflight.count >= Self.window { settle(inflight.removeFirst()) }
        }
        inflight.forEach(settle)
        return out
    }

    /// `replace`: atomically over an existing file when the server can (posix-rename). Without it, never over an
    /// existing item: "already exists". But an existing `to` may be the item itself reached another way — a name in
    /// another case on a disk that ignores case, a symlinked folder or "." on the way — and SFTP v3 has no inode to
    /// tell. So a server without posix-rename never just removes `to`: the item steps aside to a fresh name first:
    /// `to` gone with it, it was this one (renamed); still there, it's another (removed with `replace`, else put
    /// back and refused). Without `replace` only a case-only new name gets that far. The item itself is never deleted.
    public func rename(_ from: String, _ to: String, replace: Bool = false) throws {
        if replace && extensions["posix-rename@openssh.com"] != nil {
            var p = Packet(Self.EXTENDED)
            p.string("posix-rename@openssh.com")
            p.string(from)
            p.string(to)
            return try expectOK(p, from)
        }
        if try lstat(to) != nil {
            let taken = SFTPError(message: "“\((to as NSString).lastPathComponent)” already exists.")
            guard replace || from != to && from.lowercased() == to.lowercased() else { throw taken }
            let aside = (from as NSString).deletingLastPathComponent + "/.dfm-rename-" + UUID().uuidString
            try plainRename(from, aside)
            do {
                if try lstat(to) == nil { return try plainRename(aside, to) }
                if replace {
                    try remove(to)
                    return try plainRename(aside, to)
                }
                try plainRename(aside, from)
            } catch {
                // Not put back (the connection dropped): say where it is.
                guard (try? plainRename(aside, from)) != nil else { throw SFTPError(message: "\(error.localizedDescription) — it's now “\(aside)”") }
                throw error
            }
            throw taken
        }
        try plainRename(from, to)
    }

    private func plainRename(_ from: String, _ to: String) throws {
        var p = Packet(Self.RENAME)
        p.string(from)
        p.string(to)
        try expectOK(p, from)
    }

    public func readlink(_ path: String) throws -> String { try name(Self.READLINK, path) }

    /// Where each symlink points, the errno following it gives (0: it resolves; ENOENT: dangling) and whether it lands
    /// on a folder, with all the requests in flight together. One that can't even be read is left out.
    public func targets(_ links: [String]) -> [String: (target: String, error: Int32, dir: Bool)] {
        let sent = links.compactMap { path -> (String, UInt32, UInt32)? in
            var r = Packet(Self.READLINK), s = Packet(Self.STAT)
            r.string(path)
            s.string(path)
            guard let rid = try? send(r) else { return nil }
            guard let sid = try? send(s) else { forget([rid]); return nil }
            return (path, rid, sid)
        }
        var out: [String: (target: String, error: Int32, dir: Bool)] = [:]
        for (path, rid, sid) in sent {
            let link = try? wait(rid), st = try? wait(sid)
            guard let link, link.type == Self.NAME else { continue }
            var r = Reader(link.body)
            guard (try? r.u32()) == 1, let target = try? r.text() else { continue }
            let code = st.flatMap { a -> UInt32? in
                var b = Reader(a.body)
                return a.type == Self.STATUS ? try? b.u32() : Self.OK
            }
            var a = st.map { Reader($0.body) }
            let dir = code == Self.OK && (try? a?.attrs())??.kind == .dir
            out[path] = (target, code == Self.OK ? 0 : code == Self.NO_SUCH_FILE ? ENOENT : code == Self.PERMISSION_DENIED ? EACCES : EIO, dir)
        }
        return out
    }

    /// The server's own spelling of `path`: symlinks followed, "//", "." and ".." gone.
    public func realpath(_ path: String) throws -> String { try name(Self.REALPATH, path) }

    private func name(_ request: UInt8, _ path: String) throws -> String {
        var p = Packet(request)
        p.string(path)
        let (type, body) = try call(p)
        if type == Self.STATUS { _ = try status(body, path: path) }
        var r = Reader(body)
        guard type == Self.NAME, try r.u32() == 1 else { throw protocolError("\(request == Self.READLINK ? "READLINK" : "REALPATH") answered \(type)") }
        return try r.text()
    }

    /// OpenSSH's sftp-server takes (target, link) — the reverse of the draft, which every OpenSSH client follows.
    public func symlink(_ destination: String, at link: String) throws {
        var p = Packet(Self.SYMLINK)
        p.string(destination)
        p.string(link)
        try expectOK(p, link)
    }

    /// Modification (and access) time, permission bits, owner and group (both: v3 sends them together). Doesn't
    /// follow a symlink only if the server can't.
    public func setAttrs(_ path: String, mtime: Double?, mode: UInt32?, owner: (uid: UInt32, gid: UInt32)? = nil) throws {
        try expectOK(Self.setstat(path, mtime: mtime, mode: mode, owner: owner), path)
    }

    static func setstat(_ path: String, mtime: Double?, mode: UInt32?, owner: (uid: UInt32, gid: UInt32)? = nil) -> Packet {
        var p = Packet(Self.SETSTAT)
        p.string(path)
        p.u32((owner == nil ? 0 : Self.ATTR_UIDGID) | (mtime == nil ? 0 : Self.ATTR_ACMODTIME) | (mode == nil ? 0 : Self.ATTR_PERMISSIONS))
        if let owner { p.u32(owner.uid); p.u32(owner.gid) }
        if let mode { p.u32(mode & 0o7777) }
        if let mtime { p.u32(UInt32(clamping: Int64(mtime))); p.u32(UInt32(clamping: Int64(mtime))) }
        return p
    }

    // MARK: - Streams

    /// Reads a file in order from `offset`, keeping `window` requests in flight. `sizeHint` (from a stat) stops
    /// the pipeline from overshooting small files: the last read ends at it, and the one asking for the end of the
    /// file goes in the same wave. A file that grew past it is still read to its end.
    public final class ReadStream {
        let c: SFTPClient, handle: Data, path: String, hint: UInt64
        var next: UInt64
        var inflight: [(id: UInt32, offset: UInt64, len: Int)] = []
        var eof = false

        init(_ c: SFTPClient, _ handle: Data, _ path: String, offset: UInt64, hint: UInt64) {
            self.c = c; self.handle = handle; self.path = path; self.next = offset; self.hint = hint
        }

        /// The next piece, or nil at the end of the file.
        public func read() throws -> Data? {
            while true {
                while !eof && inflight.count < (next > hint ? 1 : SFTPClient.window) {
                    // Overshooting the hint, a read came back short and its rest was one more wait before the end.
                    let len = next < hint ? Int(min(UInt64(SFTPClient.chunk), hint - next)) : SFTPClient.chunk
                    inflight.append((try c.sendRead(handle, next, len), next, len))
                    next += UInt64(len)
                }
                guard !inflight.isEmpty else { return nil }
                let r = inflight.removeFirst()
                let (type, body) = try c.wait(r.id)
                if type == SFTPClient.STATUS {
                    guard try c.status(body, path: path) == SFTPClient.EOF else { throw c.protocolError("READ answered OK") }
                    eof = true
                    abandon()
                    continue
                }
                guard type == SFTPClient.DATA else { throw c.protocolError("READ answered \(type)") }
                var rd = Reader(body)
                let data = try rd.bytes()
                guard data.count <= r.len else { throw c.protocolError("READ returned too much") }
                guard !data.isEmpty else {   // never from OpenSSH; taken as the end rather than asked again forever
                    eof = true
                    abandon()
                    continue
                }
                if data.count < r.len {
                    // Short read: ask for the rest before anything later, so pieces stay in order.
                    let off = r.offset + UInt64(data.count)
                    inflight.insert((try c.sendRead(handle, off, r.len - data.count), off, r.len - data.count), at: 0)
                }
                return data
            }
        }

        public func close() {
            abandon()
            c.closeUnheard(handle)
        }

        private func abandon() {
            c.forget(inflight.map(\.id))
            inflight = []
        }
    }

    public func openRead(_ path: String, offset: Int64 = 0, sizeHint: Int64 = 0) throws -> ReadStream {
        ReadStream(self, try open(path, Self.FXF_READ), path, offset: UInt64(offset), hint: UInt64(max(0, sizeHint)))
    }

    /// Writes from `offset` on, `window` writes in flight; `finish` waits for the last of them.
    public final class WriteStream {
        let c: SFTPClient, handle: Data, path: String
        var offset: UInt64
        var inflight: [(id: UInt32, end: UInt64)] = []
        var closed = false   // its CLOSE went out: never a second one (the server may hand the handle to another file)
        /// Where the file surely holds all that was written, in one piece: each write before it answered OK. (After an
        /// error the ones sent later may have landed past a hole.)
        public private(set) var confirmed: Int64

        init(_ c: SFTPClient, _ handle: Data, _ path: String, offset: UInt64) {
            self.c = c; self.handle = handle; self.path = path; self.offset = offset; confirmed = Int64(offset)
        }

        public func write(_ data: Data) throws {
            var i = data.startIndex
            while i < data.endIndex {
                let piece = data[i..<min(i + SFTPClient.chunk, data.endIndex)]
                var p = Packet(SFTPClient.WRITE)
                p.string(handle)
                p.u64(offset)
                p.string(piece)
                inflight.append((try c.send(p), offset + UInt64(piece.count)))
                offset += UInt64(piece.count)
                i += piece.count
                if inflight.count >= SFTPClient.window { try check(inflight.removeFirst()) }
            }
        }

        public func finish() throws {
            while !inflight.isEmpty { try check(inflight.removeFirst()) }
            closed = true
            try c.closeHandle(handle)
        }

        /// `finish`, with the file's mode and date sent right behind the close instead of after its answer (the
        /// server takes requests in order): one round trip for both. A mode the owner can write (or none) goes right
        /// behind the writes, before their answers: one more round trip saved, and a partial that failed half-way
        /// stays writable for the Retry that reopens it. Any other mode only once every write landed — such a
        /// partial mustn't turn read-only under that Retry. The mode's and date's failure is returned, not thrown:
        /// the data is there.
        public func finish(mtime: Double?, mode: UInt32?) throws -> Error? {
            if let mode, mode & 0o200 == 0 {
                do { while !inflight.isEmpty { try check(inflight.removeFirst()) } } catch { close(); throw error }
            }
            var closing = Packet(SFTPClient.CLOSE)
            closing.string(handle)
            var sent: [UInt32] = []   // the close, then the mode and date
            closed = true
            do {
                sent.append(try c.send(closing))
                sent.append(try c.send(SFTPClient.setstat(path, mtime: mtime, mode: mode)))
                while !inflight.isEmpty { try check(inflight.removeFirst()) }
                let (type, body) = try c.wait(sent[0])
                guard type == SFTPClient.STATUS else { throw c.protocolError("CLOSE answered \(type)") }
                try c.status(body, path: path, okOnly: true)
            } catch {
                c.forget(inflight.map(\.id) + sent)   // the handle is closed (or the connection gone): no close() after
                inflight = []
                throw error
            }
            do {
                let (type, body) = try c.wait(sent[1])
                guard type == SFTPClient.STATUS else { throw c.protocolError("SETSTAT answered \(type)") }
                try c.status(body, path: path, okOnly: true)
                return nil
            } catch { return error }
        }

        /// Gives up (after an error, or cancelled): unanswered writes are dropped, the handle closed.
        public func close() {
            c.forget(inflight.map(\.id))
            inflight = []
            guard !closed else { return }
            closed = true
            try? c.closeHandle(handle)
        }

        private func check(_ w: (id: UInt32, end: UInt64)) throws {
            let (type, body) = try c.wait(w.id)
            guard type == SFTPClient.STATUS else { throw c.protocolError("WRITE answered \(type)") }
            _ = try c.status(body, path: path, okOnly: true)
            confirmed = Int64(w.end)
        }
    }

    /// `offset` > 0 continues a partial file; 0 creates (or truncates) it. `exclusive`: fail if it exists.
    /// A new file is owner-only (a key or .env in transit is nobody else's business); callers set its real mode.
    public func openWrite(_ path: String, offset: Int64 = 0, exclusive: Bool = false) throws -> WriteStream {
        let flags = Self.FXF_WRITE | Self.FXF_CREAT | (offset > 0 ? 0 : exclusive ? Self.FXF_EXCL : Self.FXF_TRUNC)
        return WriteStream(self, try open(path, flags, mode: 0o600), path, offset: UInt64(offset))
    }

    /// Server-side copy (`copy-data`): the bytes never cross the network.
    public var canCopyData: Bool { extensions["copy-data"] != nil }

    /// Copies `length` bytes (0 = to the end) of `from` at `offset` into `to` at the same offset.
    public func copyData(_ from: String, to: String, offset: Int64, length: Int64) throws {
        let rh = try open(from, Self.FXF_READ)
        defer { closeUnheard(rh) }
        let wh = try open(to, Self.FXF_WRITE | Self.FXF_CREAT | (offset > 0 ? 0 : Self.FXF_TRUNC), mode: 0o600)   // new: owner-only, as openWrite
        defer { try? closeHandle(wh) }
        var p = Packet(Self.EXTENDED)
        p.string("copy-data")
        p.string(rh)
        p.u64(UInt64(offset))
        p.u64(UInt64(length))
        p.string(wh)
        p.u64(UInt64(offset))
        try expectOK(p, from)
    }

    // MARK: - Requests

    private func open(_ path: String, _ flags: UInt32, mode: UInt32 = 0o644) throws -> Data {
        var p = Packet(Self.OPEN)
        p.string(path)
        p.u32(flags)
        p.u32(Self.ATTR_PERMISSIONS)
        p.u32(mode)
        return try handle(p, path)
    }

    private func open(dir: String) throws -> Data {
        var p = Packet(Self.OPENDIR)
        p.string(dir)
        return try handle(p, dir)
    }

    func closeHandle(_ h: Data) throws {
        var p = Packet(Self.CLOSE)
        p.string(h)
        try expectOK(p, "")
    }

    /// A read handle's or a folder's close, its answer not waited for: it can't lose data, and the server takes it
    /// before anything sent after it. One wait less per file read and per folder listed.
    func closeUnheard(_ h: Data) {
        var p = Packet(Self.CLOSE)
        p.string(h)
        if let id = try? send(p) { forget([id]) }
    }

    private func handle(_ p: Packet, _ path: String) throws -> Data {
        let (type, body) = try call(p)
        if type == Self.STATUS { _ = try status(body, path: path, okOnly: true) }
        var r = Reader(body)
        guard type == Self.HANDLE else { throw protocolError("OPEN answered \(type)") }
        return try r.bytes()
    }

    private func attrs(_ type: UInt8, _ path: String) throws -> Attrs {
        var p = Packet(type)
        p.string(path)
        let (t, body) = try call(p)
        if t == Self.STATUS { _ = try status(body, path: path, okOnly: true) }
        var r = Reader(body)
        guard t == Self.ATTRS else { throw protocolError("STAT answered \(t)") }
        return try r.attrs()
    }

    private func simple(_ type: UInt8, _ path: String) throws {
        var p = Packet(type)
        p.string(path)
        try expectOK(p, path)
    }

    private func expectOK(_ p: Packet, _ path: String) throws {
        let (type, body) = try call(p)
        guard type == Self.STATUS else { throw protocolError("expected a status, got \(type)") }
        _ = try status(body, path: path, okOnly: true)
    }

    func sendRead(_ handle: Data, _ offset: UInt64, _ len: Int) throws -> UInt32 {
        var p = Packet(Self.READ)
        p.string(handle)
        p.u64(offset)
        p.u32(UInt32(len))
        return try send(p)
    }

    /// The status code (OK or EOF); anything else throws with the server's message.
    @discardableResult
    func status(_ body: Data, path: String, okOnly: Bool = false) throws -> UInt32 {
        var r = Reader(body)
        let code = try r.u32()
        if code == Self.OK || (code == Self.EOF && !okOnly) { return code }
        let text = (try? r.text()) ?? ""
        let fallback = [Self.EOF: "Unexpected end of file", Self.NO_SUCH_FILE: "No such file or directory",
                        Self.PERMISSION_DENIED: "Permission denied", Self.OP_UNSUPPORTED: "Not supported by the server"][code]
        var e = SFTPError(message: text.isEmpty || text == "Failure" ? fallback ?? "Failure" : text)
        e.code = code
        throw e
    }

    private func call(_ p: Packet) throws -> (UInt8, Data) {
        return try wait(try send(p))
    }

    // MARK: - Wire

    /// `after`: bytes that go first, in the same write (a password line for sudo, before INIT).
    @discardableResult
    func send(_ p: Packet, after prefix: Data = Data()) throws -> UInt32 {
        var p = p
        let id: UInt32 = cond.withLock {
            defer { nextID &+= 1; if nextID == 0 { nextID = 1 } }
            return nextID
        }
        if p.type != Self.INIT { p.setID(id) }
        lastSent = id
        guard isConnected else { throw lostError() }
        var out = prefix
        withUnsafeBytes(of: UInt32(p.body.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(p.body)
        let ok = out.withUnsafeBytes { buf -> Bool in
            var done = 0
            while done < buf.count {
                let n = Darwin.write(writeFD, buf.baseAddress! + done, buf.count - done)
                if n < 0 { if errno == EINTR { continue }; return false }
                done += n
            }
            return true
        }
        guard ok, isConnected else {
            lost("Connection to \(target.host) lost")
            throw lostError()
        }
        return p.type == Self.INIT ? 0 : id
    }

    func wait(_ id: UInt32) throws -> (type: UInt8, body: Data) {
        if id > waveEnd { roundTrips += 1; waveEnd = lastSent }
        let r = cond.withLock { () -> (type: UInt8, body: Data)? in
            while true {
                if let r = responses.removeValue(forKey: id) { return r }
                if lostReason != nil { return nil }
                cond.wait()
            }
        }
        guard let r else { throw lostError() }   // outside the lock: lostError takes it too
        return r
    }

    func forget(_ ids: [UInt32]) {
        cond.withLock {
            for id in ids where responses.removeValue(forKey: id) == nil { ignored.insert(id) }
        }
    }

    private func readLoop() {
        let fd = readFD
        func exactly(_ n: Int) -> Data? {
            var d = Data(count: n)
            var got = 0
            let ok = d.withUnsafeMutableBytes { buf -> Bool in
                while got < n {
                    let r = Darwin.read(fd, buf.baseAddress! + got, n - got)
                    if r < 0 && errno == EINTR { continue }
                    if r <= 0 { return false }
                    got += r
                }
                return true
            }
            return ok ? d : nil
        }
        while let head = exactly(4) {
            let len = Int(head.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
            guard len >= 1, len <= 1 << 20 else {
                // Not SFTP (text a login script prints, a reply too big): nothing after it can be trusted. The
                // server would wait for us forever, so it goes, and so does every call waiting for an answer.
                lost(protocolError("a packet of \(len) bytes — or text a login script such as .bashrc printed").message)
                if process.isRunning { process.terminate() }
                break
            }
            guard let body = exactly(len) else { break }
            let type = body[body.startIndex]
            let id: UInt32 = type == Self.VERSION ? 0
                : body.count >= 5 ? body.subdata(in: body.startIndex + 1 ..< body.startIndex + 5).withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) } : 0
            let rest = body.subdata(in: body.startIndex + (type == Self.VERSION ? 1 : min(5, body.count)) ..< body.endIndex)
            cond.withLock {
                answers += 1
                if ignored.remove(id) == nil { responses[id] = (type, rest) }
                cond.broadcast()
            }
        }
        process.waitUntilExit()
        lost("Connection to \(target.host) lost")
    }

    private func lost(_ reason: String) {
        cond.withLock {
            if lostReason == nil { lostReason = reason }
            cond.broadcast()
        }
    }

    func lostError() -> SFTPError {
        let why = errors.text.split(whereSeparator: \.isNewline).filter { !$0.contains("Warning: Permanently added") }.joined(separator: "\n")
        let reason = cond.withLock { lostReason } ?? "Connection lost"
        return SFTPError(message: why.isEmpty ? reason : "\(reason): \(why)", connection: true)
    }

    func protocolError(_ what: String) -> SFTPError {
        SFTPError(message: "SFTP protocol error from \(target.host): \(what)")
    }

    // MARK: - Protocol constants (draft-ietf-secsh-filexfer-02)

    static let INIT: UInt8 = 1, VERSION: UInt8 = 2, OPEN: UInt8 = 3, CLOSE: UInt8 = 4, READ: UInt8 = 5, WRITE: UInt8 = 6
    static let LSTAT: UInt8 = 7, SETSTAT: UInt8 = 9, OPENDIR: UInt8 = 11, READDIR: UInt8 = 12
    static let REMOVE: UInt8 = 13, MKDIR: UInt8 = 14, RMDIR: UInt8 = 15, REALPATH: UInt8 = 16, STAT: UInt8 = 17, RENAME: UInt8 = 18
    static let READLINK: UInt8 = 19, SYMLINK: UInt8 = 20
    static let STATUS: UInt8 = 101, HANDLE: UInt8 = 102, DATA: UInt8 = 103, NAME: UInt8 = 104, ATTRS: UInt8 = 105
    static let EXTENDED: UInt8 = 200
    static let FXF_READ: UInt32 = 1, FXF_WRITE: UInt32 = 2, FXF_CREAT: UInt32 = 8, FXF_TRUNC: UInt32 = 0x10, FXF_EXCL: UInt32 = 0x20
    static let ATTR_SIZE: UInt32 = 1, ATTR_UIDGID: UInt32 = 2, ATTR_PERMISSIONS: UInt32 = 4, ATTR_ACMODTIME: UInt32 = 8
    static let ATTR_EXTENDED: UInt32 = 0x8000_0000
    static let OK: UInt32 = 0, EOF: UInt32 = 1, NO_SUCH_FILE: UInt32 = 2, PERMISSION_DENIED: UInt32 = 3, OP_UNSUPPORTED: UInt32 = 8
}

/// Names a server sends needn't be UTF-8 (Latin-1 from an old system). Each byte that isn't part of a UTF-8
/// character becomes U+F0000 + byte (private use), and that byte again on the way out, so a request names the very
/// bytes listed. A real character of that block is taken apart the same way: the trip is exact both ways.
/// ponytail: only SFTPClient speaks it; a name typed with such a character, ssh command lines (search, tar, tail)
/// and this Mac's own non-UTF-8 names (DirLister) don't.
enum WireName {
    static let base: UInt32 = 0xF0000
    static func isEscape(_ c: Unicode.Scalar) -> Bool { c.value & ~0xFF == base }

    static func decode(_ d: Data) -> String {
        if !d.contains(where: { $0 >= 0x80 }) { return String(decoding: d, as: UTF8.self) }
        var out = String.UnicodeScalarView(), parser = Unicode.UTF8.ForwardParser(), it = d.makeIterator(), raw = d.makeIterator()
        func escape(_ n: Int) { for _ in 0..<n { out.append(Unicode.Scalar(base + UInt32(raw.next()!))!) } }
        while true {
            switch parser.parseScalar(from: &it) {
            case .valid(let e):
                let c = Unicode.UTF8.decode(e)
                if isEscape(c) { escape(e.count) } else { out.append(c); for _ in 0..<e.count { _ = raw.next() } }
            case .error(let n): escape(n)
            case .emptyInput: return String(out)
            }
        }
    }

    static func encode(_ s: String) -> Data {
        guard s.unicodeScalars.contains(where: isEscape) else { return Data(s.utf8) }
        var d = Data()
        for c in s.unicodeScalars { if isEscape(c) { d.append(UInt8(c.value - base)) } else { d.append(contentsOf: String(c).utf8) } }
        return d
    }
}

/// An outgoing packet: type, then (filled in by `send`) the request id, then the fields.
struct Packet {
    let type: UInt8
    var body: Data

    init(_ type: UInt8) {
        self.type = type
        body = Data([type])
        if type != SFTPClient.INIT { body.append(contentsOf: [0, 0, 0, 0]) }
    }

    mutating func setID(_ id: UInt32) {
        withUnsafeBytes(of: id.bigEndian) { body.replaceSubrange(1..<5, with: $0) }
    }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { body.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { body.append(contentsOf: $0) } }
    mutating func string(_ d: Data) { u32(UInt32(d.count)); body.append(d) }
    mutating func string(_ s: String) { string(WireName.encode(s)) }
}

struct Reader {
    let data: Data
    var pos: Int

    init(_ data: Data) { self.data = data; pos = data.startIndex }
    var atEnd: Bool { pos >= data.endIndex }

    mutating func u8() throws -> UInt8 {
        guard pos < data.endIndex else { throw SFTPError(message: "SFTP protocol error: short packet") }
        defer { pos += 1 }
        return data[pos]
    }
    mutating func u32() throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 { v = v << 8 | UInt32(try u8()) }
        return v
    }
    mutating func u64() throws -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<8 { v = v << 8 | UInt64(try u8()) }
        return v
    }
    mutating func bytes() throws -> Data {
        let n = Int(try u32())
        guard n <= data.endIndex - pos else { throw SFTPError(message: "SFTP protocol error: short packet") }
        defer { pos += n }
        return data.subdata(in: pos ..< pos + n)
    }
    mutating func text() throws -> String { WireName.decode(try bytes()) }

    mutating func attrs() throws -> SFTPClient.Attrs {
        let flags = try u32()
        var a = SFTPClient.Attrs(kind: .file, size: 0, mtime: 0, mode: nil)
        if flags & SFTPClient.ATTR_SIZE != 0 { a.size = Int64(clamping: try u64()) }
        if flags & SFTPClient.ATTR_UIDGID != 0 { a.uid = try u32(); a.gid = try u32() }
        if flags & SFTPClient.ATTR_PERMISSIONS != 0 {
            let m = try u32()
            a.mode = m & 0o7777
            a.type = m & 0o170000
            a.kind = switch m & 0o170000 {
            case 0o040000: .dir
            case 0o120000: .link
            case 0o100000: .file
            default: .other
            }
            if a.kind != .other { a.type = 0 }
        }
        if flags & SFTPClient.ATTR_ACMODTIME != 0 { _ = try u32(); a.mtime = Double(try u32()) }
        if flags & SFTPClient.ATTR_EXTENDED != 0 { for _ in 0..<(try u32()) { _ = try bytes(); _ = try bytes() } }
        if a.kind == .dir { a.size = 0 }
        return a
    }
}

// MARK: - Viewing and editing a server's file (F3 / F4)

extension SFTPClient {
    /// Follows a symlink (`lstat` doesn't).
    public func stat(_ path: String) throws -> Attrs { try attrs(Self.STAT, path) }

    public struct ChangedOnServer: LocalizedError {
        public let attrs: Attrs
        public var errorDescription: String? { "It changed on the server since it was opened." }
    }

    /// Files this big at most get a `sha256` in their baseline (configs, scripts): reading them back costs little.
    public static let hashLimit: Int64 = 1 << 20

    /// Copies the server's file into the local file `local` (owner-only); returns its attributes then — the
    /// baseline `upload` checks against. `last`: only that many bytes off its end (the tail of a big log);
    /// the attributes are still the whole file's.
    public func download(_ remote: String, to local: String, last: Int64? = nil) throws -> Attrs {
        var a = try stat(remote)
        guard a.kind == .file else { throw SFTPError(message: "“\((remote as NSString).lastPathComponent)” isn't a regular file") }
        let fd = Darwin.open(local, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LocalFS.posixError() }
        defer { Darwin.close(fd) }
        let r = try openRead(remote, offset: last.map { max(0, a.size - $0) } ?? 0, sizeHint: a.size)
        defer { r.close() }
        var hash = SHA256()
        while let d = try r.read() {
            hash.update(data: d)
            try d.withUnsafeBytes { b in
                var off = 0
                while off < b.count {
                    let n = Darwin.write(fd, b.baseAddress! + off, b.count - off)
                    if n < 0 { if errno == EINTR { continue }; throw LocalFS.posixError() }
                    off += n
                }
            }
        }
        if a.size <= last ?? a.size && a.size <= Self.hashLimit { a.sha256 = Data(hash.finalize()) }
        return a
    }

    /// The server's file as it is now, whole (it follows a symlink): small ones only.
    private func contents(_ remote: String, size: Int64) throws -> Data {
        let r = try openRead(remote, sizeHint: size)
        defer { r.close() }
        var out = Data()
        while let d = try r.read() { out.append(d) }
        return out
    }

    /// Puts the local file in place of `remote`. First all of it into a partial file next to it, so a dropped
    /// connection never leaves a cut-off config; then renamed over it — or, if that would change the owner
    /// (someone else's file), `remote` is a symlink or the session `writesInPlace`, copied into it on the server, which
    /// keeps owner, mode, links and SELinux label. Throws `ChangedOnServer` if the server's copy isn't `baseline` any more, unless `force`.
    /// Returns the new attributes (the next baseline).
    /// `cancel` stops it (CancellationError) and removes the partial file, over a slow link too (`closeWhenQuiet`).
    /// `replaced` gets the file it replaced, once it's in place: its attributes, and its bytes up to
    /// `ServerHistory.fileLimit` (nil over that) — from the check's own read when there is one, else read first.
    /// `check` gets the partial file's path once it holds all of the new text, before it takes the file's place (either
    /// way): a throw leaves the file as it was, the partial file gone (`ConfigCheck`'s "before").
    @discardableResult
    public func upload(_ local: String, to remote: String, baseline: Attrs?, force: Bool = false, cancel: CancelFlag? = nil,
                       replaced: ((Attrs, Data?) -> Void)? = nil, check: ((_ partial: String) throws -> Void)? = nil) throws -> Attrs {
        let previous = cancel?.onCancel { [self] in closeWhenQuiet() } ?? nil
        defer { cancel?.onCancel(previous) }
        let entry = try lstat(remote)
        let cur = entry?.kind == .link ? try stat(remote) : entry
        let keep = replaced != nil && cur?.kind == .file && cur!.size <= ServerHistory.fileLimit
        var old: Data?
        // Size + whole-second mtime is all SFTP v3 tells; a same-size change within that second shows in the content.
        // ponytail: over `hashLimit` it still slips by; a server-side hash (`sha256sum` over ssh) if that ever matters.
        if !force, let baseline, let cur {
            var changed = cur.size != baseline.size || cur.mtime != baseline.mtime
            if !changed, let sum = baseline.sha256 {
                let now = try contents(remote, size: cur.size)
                changed = Data(SHA256.hash(data: now)) != sum
                old = now
            }
            if changed { throw ChangedOnServer(attrs: cur) }
        }
        if keep, old == nil { old = try contents(remote, size: cur!.size) }   // `force` keeps exactly what it overwrites
        let fd = Darwin.open(local, O_RDONLY)
        guard fd >= 0 else { throw LocalFS.posixError() }
        defer { Darwin.close(fd) }
        let partial = ((remote as NSString).deletingLastPathComponent as NSString).appendingPathComponent(FileJob.partialName())
        let w = try openWrite(partial, exclusive: true)
        var hash = SHA256()
        var modeError: Error?   // the mode didn't take: no rename then (a copy into `remote` keeps its own)
        do {
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                if cancel?.isCancelled == true { throw CancellationError() }
                let n = Darwin.read(fd, &buf, buf.count)
                if n < 0 { if errno == EINTR { continue }; throw LocalFS.posixError() }
                if n == 0 { break }
                hash.update(data: buf[0..<n])
                try w.write(Data(buf[0..<n]))
            }
            modeError = try w.finish(mtime: nil, mode: cur?.mode ?? 0o644)   // with the close: one wait, not two
        } catch {
            w.close()
            try? remove(partial)
            throw error
        }
        do {
            try check?(partial)
            let mine = try lstat(partial)
            if let cur, writesInPlace || entry?.kind == .link || cur.uid == nil || cur.uid != mine?.uid || cur.gid != mine?.gid {
                if canCopyData {
                    try copyData(partial, to: remote, offset: 0, length: 0)
                } else {
                    let r = try openRead(partial, sizeHint: mine?.size ?? 0)
                    defer { r.close() }
                    let out = try openWrite(remote)
                    do { while let d = try r.read() { try out.write(d) }; try out.finish() } catch { out.close(); throw error }
                }
                try? remove(partial)
            } else {
                if let modeError { throw modeError }
                try rename(partial, remote, replace: true)
            }
        } catch {
            try? remove(partial)
            throw error
        }
        if let cur, cur.kind == .file { replaced?(cur, keep ? old : nil) }
        var a = try stat(remote)
        if a.size <= Self.hashLimit { a.sha256 = Data(hash.finalize()) }   // what was sent: the next save's baseline
        return a
    }
}

/// The last few KB of ssh's stderr, for the message when the connection drops.
private final class ErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d); if data.count > 4096 { data = data.suffix(4096) } } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
