import Foundation

/// Where files live: this Mac, or a server over SFTP.
public enum Endpoint: Hashable, Sendable, Codable {
    case local
    case sftp(SFTPTarget)

    /// This Mac on both sides, or one server (`SFTPTarget.isSameServer`) however each side connects to it.
    public func isSameFilesystem(as o: Endpoint) -> Bool {
        switch (self, o) {
        case (.local, .local): true
        case let (.sftp(a), .sftp(b)): a.isSameServer(as: b)
        default: false
        }
    }
}

/// What a cross-endpoint transfer needs from either side. Paths are absolute; nothing follows a symlink.
protocol TransferFS: AnyObject, Sendable {
    func lstat(_ path: String) throws -> SFTPClient.Attrs?
    /// Each path's `lstat`, in order; with the requests in flight together on a server.
    func lstat(_ paths: [String]) -> [Result<SFTPClient.Attrs?, Error>]
    func list(_ dir: String) throws -> [(name: String, attrs: SFTPClient.Attrs)]
    /// Each folder's items, in order; nil for one that couldn't be listed. A server lists them with the requests in
    /// flight together (`SFTPClient.list(_ dirs:)`).
    func list(_ dirs: [String]) -> [[(name: String, attrs: SFTPClient.Attrs)]?]
    func mkdir(_ path: String) throws
    func remove(_ path: String) throws
    func rmdir(_ path: String) throws
    /// These files, then these empty folders, with the requests in flight together on a server. The ones that
    /// didn't go, with why.
    func remove(_ paths: [String]) -> [(path: String, error: Error)]
    func rmdir(_ paths: [String]) -> [(path: String, error: Error)]
    func rename(_ from: String, _ to: String, replace: Bool) throws
    func readlink(_ path: String) throws -> String
    /// The one exception: symlinks followed, to tell where a path really is.
    func realpath(_ path: String) throws -> String
    func symlink(_ destination: String, at link: String) throws
    func setAttrs(_ path: String, mtime: Double?, mode: UInt32?) throws
    func reader(_ path: String, offset: Int64, size: Int64) throws -> PieceReader
    func writer(_ path: String, offset: Int64) throws -> PieceWriter
    /// Drops the connection (cancel); the next call connects again, unless the job was cancelled.
    func close()
}

extension TransferFS {
    func lstat(_ paths: [String]) -> [Result<SFTPClient.Attrs?, Error>] { paths.map { p in Result { try lstat(p) } } }
    func list(_ dirs: [String]) -> [[(name: String, attrs: SFTPClient.Attrs)]?] { dirs.map { try? list($0) } }
    func remove(_ paths: [String]) -> [(path: String, error: Error)] { paths.compactMap { p in do { try remove(p); return nil } catch { return (p, error) } } }
    func rmdir(_ paths: [String]) -> [(path: String, error: Error)] { paths.compactMap { p in do { try rmdir(p); return nil } catch { return (p, error) } } }
}

extension TransferFS {
    /// Where other file systems are mounted (`/proc/self/mounts` on Linux; read through this side, so a server's own),
    /// as `FileJob.mounts` parses it. None if it can't be read — a BSD or macOS server: no stop there.
    func mountPoints(_ file: String) -> Set<String> {
        guard let r = try? reader(file, offset: 0, size: 0) else { return [] }
        defer { r.close() }
        var data = Data()
        while data.count < 4 << 20, let piece = try? r.read() { data.append(piece) }
        return FileJob.mounts(String(decoding: data, as: UTF8.self))
    }
}

extension Result {
    /// The value, or nil for an error. (`try? get()` would flatten an optional value: "nothing there" and "failed" alike.)
    var value: Success? { if case .success(let v) = self { v } else { nil } }
}

protocol PieceReader {
    func read() throws -> Data?
    func close()
}

protocol PieceWriter {
    func write(_ data: Data) throws
    /// Where the file surely holds everything written before, in one piece (Retry continues from here).
    var confirmed: Int64 { get }
    func finish() throws
    func close()
}

extension SFTPClient.ReadStream: PieceReader {}
extension SFTPClient.WriteStream: PieceWriter {}

/// A server, connected on first use and again after the connection dropped (Retry after a network blip).
final class RemoteFS: TransferFS, @unchecked Sendable {
    let target: SFTPTarget
    private let env: [String: String]
    private let cancel: CancelFlag?
    private let lock = NSLock()
    private var client: SFTPClient?

    /// `cancel` stops a connection being made, and once set, connecting again (a cancelled job doesn't log in
    /// again just to tidy up).
    init(_ target: SFTPTarget, env: [String: String], cancel: CancelFlag? = nil) {
        self.target = target
        self.env = env
        self.cancel = cancel
    }

    func session() throws -> SFTPClient {
        if let c = lock.withLock({ client }), c.isConnected { return c }
        if cancel?.isCancelled == true { throw CancellationError() }
        let c = try SFTPClient(target, env: env, cancel: cancel)
        lock.withLock { client = c }
        // Cancelled while it logged in: `closeWhenQuiet` found no client then.
        if cancel?.isCancelled == true { c.closeWhenQuiet() }
        return c
    }

    /// Root's uid when this is a root session — a root panel, or a login as root itself (`root@host`, an alias whose
    /// user is root: D-088) — else nil.
    var rootUID: UInt32? { target.sudo || Self.loginUID(target, env: env) == target.rootUID ? target.rootUID : nil }

    /// The uid a login has: `id -u` there, once per server and account while the app runs. nil: it couldn't tell (an
    /// SFTP-only account runs no command), and counts as not root, as before.
    // ponytail: one that failed on a dropped connection is remembered too; the next launch asks again.
    static func loginUID(_ t: SFTPTarget, env: [String: String]) -> UInt32? {
        let key = "\(t.host):\(t.port ?? 22):\(t.localServer ?? "")"
        if let known = uidLock.withLock({ uids[key] }) { return known }
        let uid = askUID(t, env)
        uidLock.withLock { uids[key] = .some(uid) }
        return uid
    }
    nonisolated(unsafe) static var uids: [String: UInt32?] = [:]
    private static let uidLock = NSLock()
    /// Tests: in place of `id -u` there (a test target's own session is its user's, as ever).
    nonisolated(unsafe) static var askUID: @Sendable (SFTPTarget, [String: String]) -> UInt32? = { t, env in
        guard t.localServer == nil, let out = try? SSHCommand.capture(t, "id -u", env: env) else { return nil }
        return out.split(whereSeparator: \.isNewline).last.flatMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }   // a login script may print first
    }

    func close() { lock.withLock { client }?.close() }
    func closeWhenQuiet() { lock.withLock { client }?.closeWhenQuiet() }

    func lstat(_ path: String) throws -> SFTPClient.Attrs? { try session().lstat(path) }
    func lstat(_ paths: [String]) -> [Result<SFTPClient.Attrs?, Error>] {
        guard !paths.isEmpty else { return [] }
        do { return try session().lstat(paths) } catch { return paths.map { _ in .failure(error) } }
    }
    func list(_ dir: String) throws -> [(name: String, attrs: SFTPClient.Attrs)] { try session().list(dir) }
    func list(_ dirs: [String]) -> [[(name: String, attrs: SFTPClient.Attrs)]?] {
        guard let c = try? session() else { return dirs.map { _ in nil } }
        var listed = c.list(dirs)[...]   // in order, without the ones that failed
        return dirs.map { d in listed.first?.dir == d ? listed.popFirst()!.items : nil }
    }
    // Owner-only while it fills (a read-only source folder mustn't block its own copy); real mode set afterwards.
    func mkdir(_ path: String) throws { try session().mkdir(path, mode: 0o700) }
    func remove(_ path: String) throws { try session().remove(path) }
    func rmdir(_ path: String) throws { try session().rmdir(path) }
    func remove(_ paths: [String]) -> [(path: String, error: Error)] { batch(paths) { $0.remove($1) } }
    func rmdir(_ paths: [String]) -> [(path: String, error: Error)] { batch(paths) { $0.rmdir($1) } }
    private func batch(_ paths: [String], _ body: (SFTPClient, [String]) -> [(path: String, error: Error)]) -> [(path: String, error: Error)] {
        guard !paths.isEmpty else { return [] }
        do { return body(try session(), paths) } catch { return paths.map { ($0, error) } }
    }
    func rename(_ from: String, _ to: String, replace: Bool) throws { try session().rename(from, to, replace: replace) }
    func readlink(_ path: String) throws -> String { try session().readlink(path) }
    func realpath(_ path: String) throws -> String { try session().realpath(path) }
    func symlink(_ destination: String, at link: String) throws { try session().symlink(destination, at: link) }
    func setAttrs(_ path: String, mtime: Double?, mode: UInt32?) throws { try session().setAttrs(path, mtime: mtime, mode: mode) }
    func reader(_ path: String, offset: Int64, size: Int64) throws -> PieceReader { try session().openRead(path, offset: offset, sizeHint: size) }
    func writer(_ path: String, offset: Int64) throws -> PieceWriter { try session().openWrite(path, offset: offset) }
}

/// This Mac, through plain POSIX calls (the local side of an upload or download).
final class LocalFS: TransferFS, Sendable {
    func lstat(_ path: String) throws -> SFTPClient.Attrs? {
        var s = stat()
        guard Darwin.lstat(path, &s) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.posixError()
        }
        return Self.attrs(s)
    }

    func list(_ dir: String) throws -> [(name: String, attrs: SFTPClient.Attrs)] {
        try DirLister.list(dir).map { ($0.name, SFTPClient.Attrs(kind: $0.kind, size: $0.size, mtime: $0.mtime, mode: $0.mode & 0o7777)) }
    }

    func mkdir(_ path: String) throws { try check(Darwin.mkdir(path, 0o700)) }
    func remove(_ path: String) throws { try check(unlink(path)) }
    func rmdir(_ path: String) throws { try check(Darwin.rmdir(path)) }
    func rename(_ from: String, _ to: String, replace: Bool) throws {
        try check(replace ? Darwin.rename(from, to) : renamex_np(from, to, UInt32(RENAME_EXCL)))
    }
    func readlink(_ path: String) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: path)
    }
    func realpath(_ path: String) throws -> String {
        guard let r = Darwin.realpath(path, nil) else { throw Self.posixError() }
        defer { free(r) }
        return String(cString: r)
    }
    func symlink(_ destination: String, at link: String) throws { try check(Darwin.symlink(destination, link)) }

    func setAttrs(_ path: String, mtime: Double?, mode: UInt32?) throws {
        if let mode { try check(fchmodat(AT_FDCWD, path, mode_t(mode & 0o7777), AT_SYMLINK_NOFOLLOW)) }
        if let mtime {
            let t = timespec(tv_sec: Int(mtime), tv_nsec: Int((mtime - mtime.rounded(.down)) * 1e9))
            var times = [t, t]
            try check(utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW))
        }
    }

    func reader(_ path: String, offset: Int64, size: Int64) throws -> PieceReader {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.posixError() }
        guard lseek(fd, off_t(offset), SEEK_SET) >= 0 else { Darwin.close(fd); throw Self.posixError() }
        return FDReader(fd: fd)
    }

    func writer(_ path: String, offset: Int64) throws -> PieceWriter {
        // O_NOFOLLOW: the partial file's own name, never something a link points at.
        let fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (offset > 0 ? 0 : O_TRUNC), 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        guard lseek(fd, off_t(offset), SEEK_SET) >= 0 else { Darwin.close(fd); throw Self.posixError() }
        return FDWriter(fd: fd, confirmed: offset)
    }

    func close() {}

    static func attrs(_ s: stat) -> SFTPClient.Attrs {
        let kind: FileItem.Kind = switch s.st_mode & S_IFMT {
        case S_IFDIR: .dir
        case S_IFLNK: .link
        case S_IFREG: .file
        default: .other
        }
        return SFTPClient.Attrs(kind: kind, size: kind == .dir ? 0 : Int64(s.st_size),
                                mtime: Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9,
                                mode: UInt32(s.st_mode) & 0o7777)
    }

    static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private func check(_ r: Int32) throws { if r != 0 { throw Self.posixError() } }

    private final class FDReader: PieceReader {
        let fd: Int32
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        init(fd: Int32) { self.fd = fd }
        func read() throws -> Data? {
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n < 0 { throw LocalFS.posixError() }
                return n == 0 ? nil : Data(buf[0..<n])
            }
        }
        func close() { Darwin.close(fd) }
    }

    private final class FDWriter: PieceWriter {
        let fd: Int32
        var open = true
        var confirmed: Int64
        init(fd: Int32, confirmed: Int64) { self.fd = fd; self.confirmed = confirmed }
        func write(_ data: Data) throws {
            try data.withUnsafeBytes { buf in
                var done = 0
                while done < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + done, buf.count - done)
                    if n < 0 && errno == EINTR { continue }
                    if n < 0 { throw LocalFS.posixError() }
                    done += n
                    confirmed += Int64(n)
                }
            }
        }
        func finish() throws {
            open = false
            guard Darwin.close(fd) == 0 else { throw LocalFS.posixError() }   // NFS/SMB report a failed write here
        }
        func close() { if open { open = false; Darwin.close(fd) } }
    }
}

extension FileJob {
    /// Both sides on one server, however each connects to it: one connection, renames, server-side copies.
    var sameSide: Bool { from.isSameFilesystem(as: to) }

    func makeFS(_ e: Endpoint) -> TransferFS {
        switch e {
        case .local: LocalFS()
        case .sftp(let t): RemoteFS(t, env: sshEnv, cancel: cancelFlag)
        }
    }

    /// Copy / move where at least one side is a server. Same shape as `transfer` (conflicts, errors, pause,
    /// progress), over two `TransferFS`: one connection per side, or one for both on the same server. `given`: the
    /// server side's connection, the caller's (tests count its round trips).
    func runAcross(_ given: TransferFS? = nil) {
        if kind == .delete { return deleteAcross(given) }
        guard kind == .copy || kind == .move, destDir != nil || !pairs.isEmpty else {
            update { $0.errors.append("Only copy and move work on a server"); $0.state = .failed }
            return finish()
        }
        func fs(_ e: Endpoint) -> TransferFS { e == .local ? LocalFS() : given ?? makeFS(e) }
        let src = fs(from)
        let dst = sameSide ? src : fs(to)
        // It stops by itself and removes its partial file over the live connection, however long a slow link takes
        // to get there; a server that stops answering is cut off (and not connected to again).
        cancelFlag.onCancel { [src, dst].forEach { ($0 as? RemoteFS)?.closeWhenQuiet() } }
        defer {
            cancelFlag.onCancel(nil)
            src.close()
            dst.close()
        }
        update { $0.state = .scanning }
        if let destDir { sweepPartials(dst, destDir) }
        // A root session writes a folder into `destDir` only if nobody else can change it (S-03): its owner could
        // swap the folder just made for a link to /etc. One look, for the whole job.
        if let destDir, (dst as? RemoteFS)?.rootUID != nil, let a = (try? dst.lstat(destDir)) ?? nil, othersCanChange(dst, a) { barredParent = destDir }
        var work = pairs.isEmpty ? sources.map { ($0, (destDir! as NSString).appendingPathComponent(targetName ?? ($0 as NSString).lastPathComponent)) } : pairs
        var seen = work.map { _ in (src: SFTPClient.Attrs?.none, dst: SFTPClient.Attrs??.none) }   // none: not looked at
        if !pairs.isEmpty {
            // Synchronize: each to exactly its pair, and not one that changed since Compare. Both sides of every pair
            // looked at together (a far server: a few round trips for thousands of pairs, not two each), and what's
            // seen goes on to the scan and the copy. (Pairs are rows of one Compare: none is inside another.)
            seen = zip(src.lstat(pairs.map(\.src)), dst.lstat(pairs.map(\.dst))).map { ($0.value ?? nil, $1.value) }
            let ok = pairs.indices.filter { i in
                !isCancelled && !changed(pairs[i].src, expected, seen[i].src) && !changed(pairs[i].dst, expectedTarget, seen[i].dst ?? nil)
            }
            (work, seen) = (ok.map { pairs[$0] }, ok.map { seen[$0] })
        }
        // A move on one server is a rename: no walk of each tree first (thousands of folders on a far server took
        // minutes before the first rename) or after it; the progress counts items, as a local move does.
        countsItems = kind == .move && sameSide
        var files = 0, bytes: Int64 = 0, depths: [Int] = []
        for ((s, _), seen) in zip(work, seen) where !isCancelled {
            let m = countsItems ? (files: 1, bytes: Int64(0), depth: Int.max) : measure(src, s, seen.src)
            files += m.files
            bytes = bytes.saturatingAdd(m.bytes)
            depths.append(max(m.depth, 0))
        }
        update { $0.totalFiles = files; $0.totalBytes = bytes; $0.state = .running }
        for (((s, d), seen), depth) in zip(zip(work, seen), depths) {
            guard !isCancelled else { break }
            transferAcross(src, s, dst, d, move: kind == .move, maxDepth: depth, seen: seen)
            if countsItems { update { $0.doneFiles += 1 } }
        }
        finish()
    }

    /// ⇧F8 / F8 on a server (no Trash there): bottom-up over one connection, past what can't go, each failure
    /// under its own path (Retry / Skip / Abort), like the local `remove`. Never follows a symlink. All the sources
    /// together: one look at every one (a Synchronize's check against Compare too), then `removeAcross` — a far
    /// server's round trips add up per batch of `SFTPClient.window`, not per item. `given`: a connection of the
    /// caller's (tests count its round trips).
    func deleteAcross(_ given: TransferFS? = nil) {
        let fs = given ?? makeFS(from)
        cancelFlag.onCancel { fs.close() }
        defer {
            cancelFlag.onCancel(nil)
            fs.close()
        }
        update { $0.totalFiles = sources.count; $0.state = .running }
        var tops: [(path: String, attrs: SFTPClient.Attrs)] = []
        for (s, looked) in zip(sources, fs.lstat(sources)) {
            guard !isCancelled else { return finish() }
            var a = looked.value   // none: that look failed — asked again the usual way
            if !changed(s, expected, a ?? nil), a != nil || attempt(s, { a = try fs.lstat(s) }), let a = a ?? nil { tops.append((s, a)) }
            else { update { $0.doneFiles += 1 } }   // changed since Compare, already gone, or skipped
        }
        // A folder and something in it (search results can hold both): the folder takes it along.
        let folders = Set(tops.filter { $0.attrs.kind == .dir }.map(\.path))
        func inFolder(_ p: String) -> Bool {
            let up = (p as NSString).deletingLastPathComponent
            return up != p && (folders.contains(up) || inFolder(up))
        }
        let along = tops.filter { inFolder($0.path) }.count
        tops.removeAll { inFolder($0.path) }
        update { $0.doneFiles += along }
        // A root session: the folders the tops are in, one look for all (D-082). In one others can change, a top
        // swapped for a link to / between its look and its listing would send root's delete there.
        if (fs as? RemoteFS)?.rootUID != nil {
            let parents = Array(Set(tops.map { ($0.path as NSString).deletingLastPathComponent }))
            let barred = Set(zip(parents, fs.lstat(parents)).filter { _, a in (a.value ?? nil).map { othersCanChange(fs, $0) } ?? false }.map(\.0))
            for t in tops where barred.contains((t.path as NSString).deletingLastPathComponent) { notEntered((t.path as NSString).deletingLastPathComponent) }
            update { $0.doneFiles += tops.filter { barred.contains(($0.path as NSString).deletingLastPathComponent) }.count }
            tops.removeAll { barred.contains(($0.path as NSString).deletingLastPathComponent) }
        }
        removeAcross(fs, tops)
        finish()
    }

    /// `tops` and all in them, never following a symlink. The files among them go first, `SFTPClient.window` together.
    /// The folders' trees go level by level, all at once: `window` folders listed together and their files removed
    /// together as each batch is listed (a far server: a few round trips a batch, not a few a folder); then the
    /// folders, deepest level first, each batch together. What a batch couldn't do goes the usual way after — Retry /
    /// Skip / Abort under its own path. What stays keeps the folders above it, unasked: one real error, not a "not
    /// empty" for each of them up to the top. The progress counts each top once it's done.
    func removeAcross(_ fs: TransferFS, _ tops: [(path: String, attrs: SFTPClient.Attrs)]) {
        // Synchronize: something put below a folder since Compare (a file written, a folder moved in — which changes
        // the folder's date, not always the file's) stays, and so do the folders above it. A folder newer than that
        // isn't gone into: what changed in it can't be told. A second off for whole-second dates.
        // Compare's moment by this Mac's clock, the dates by the server's: a server running behind showed a change made
        // after Compare as older, and it went. Its clock is read from a file made where the delete is (deleting there
        // takes writing there), once.
        let since = comparedAt.map { $0 - 2 + (tops.first.map { clockOffset(fs, ($0.path as NSString).deletingLastPathComponent) } ?? 0) }
        let barred = tops.filter { othersCanChange(fs, $0.attrs) }
        barred.forEach { notEntered($0.path) }
        update { $0.doneFiles += barred.count }
        var dirs = tops.filter { $0.attrs.kind == .dir && !othersCanChange(fs, $0.attrs) }.map { (path: $0.path, parent: -1, kept: false) }
        var levels = [0..<dirs.count]
        func keep(_ i: Int) {   // it and each folder above it
            var i = i
            while i >= 0 && !dirs[i].kept { dirs[i].kept = true; i = dirs[i].parent }
        }
        func batches(_ r: Range<Int>) -> [Range<Int>] {
            stride(from: r.lowerBound, to: r.upperBound, by: SFTPClient.window).map { $0..<min($0 + SFTPClient.window, r.upperBound) }
        }
        /// Together, then what didn't go one by one; a file that stays keeps its folder (`dir`; -1: a top). False: cancelled.
        func remove(_ files: [(path: String, dir: Int)]) -> Bool {
            let failed = Set(fs.remove(files.map(\.path)).map(\.path))
            for f in files where failed.contains(f.path) {
                guard !isCancelled else { return false }
                if !attempt(f.path, { try fs.remove(f.path) }) { keep(f.dir) }
            }
            return true
        }
        let files = tops.filter { $0.attrs.kind != .dir }.map(\.path)
        for batch in batches(files.indices) {
            waitWhilePaused()
            guard !isCancelled else { return }
            update { $0.current = (files[batch.lowerBound] as NSString).lastPathComponent }
            guard remove(batch.map { (files[$0], -1) }) else { return }
            update { $0.doneFiles += batch.count }
        }
        if let first = dirs.first { update { $0.current = (first.path as NSString).lastPathComponent } }
        while let level = levels.last, !level.isEmpty {
            for batch in batches(level) {
                waitWhilePaused()
                guard !isCancelled else { return }
                var files: [(path: String, dir: Int)] = []
                for (i, listed) in zip(batch, fs.list(batch.map { dirs[$0].path })) {
                    var items = listed ?? []
                    guard listed != nil || attempt(dirs[i].path, { items = try fs.list(dirs[i].path) }) else { keep(i); continue }
                    for c in items where Self.isSafeName(c.name) {
                        let p = (dirs[i].path as NSString).appendingPathComponent(c.name)
                        if othersCanChange(fs, c.attrs) { notEntered(p); keep(i) }
                        else if c.attrs.kind == .dir && mounted(fs).contains(p) { otherVolumeAcross(p); keep(i) }   // read once, at the first folder
                        else if let since, c.attrs.mtime > since { update { $0.errors.append("\(p): newer than Compare — kept") }; keep(i) }
                        else if c.attrs.kind == .dir { dirs.append((p, i, false)) } else { files.append((p, i)) }
                    }
                }
                guard remove(files) else { return }
            }
            levels.append(level.upperBound..<dirs.count)
        }
        for batch in levels.reversed().flatMap(batches) {
            waitWhilePaused()
            guard !isCancelled else { return }
            let empty = batch.filter { !dirs[$0].kept }
            let failed = Set(fs.rmdir(empty.map { dirs[$0].path }).map(\.path))
            for i in empty where failed.contains(dirs[i].path) {
                guard !isCancelled else { return }
                if !attempt(dirs[i].path, { try fs.rmdir(dirs[i].path) }) { keep(dirs[i].parent) }
            }
        }
        update { $0.doneFiles += levels[0].count }
    }

    /// Files and bytes below `path` (what the progress bar counts), and how deep its folders go (-1: not a folder).
    /// Unreadable parts count as nothing. Level by level, `SFTPClient.window` folders listed together: a far server's
    /// round trips add up per level, not per folder (thousands of folders were minutes of "Scanning…").
    func measure(_ fs: TransferFS, _ path: String, _ known: SFTPClient.Attrs? = nil) -> (files: Int, bytes: Int64, depth: Int) {
        // A listing without a mode (SFTP v3 allows it) or an entry the lister couldn't type: ask lstat, like the copy
        // will, so the depth below matches what transferAcross sees.
        func attrs(_ path: String, _ known: SFTPClient.Attrs?) -> SFTPClient.Attrs? { known?.typed ?? (try? fs.lstat(path)) ?? nil }
        guard let a = attrs(path, known) else { return (0, 0, -1) }
        guard a.kind == .dir else { return (1, a.size, -1) }
        guard !othersCanChange(fs, a) else { return (0, 0, 0) }   // not gone into: nothing to count
        // Each folder with its parent: its own files first, what's below it added once all is listed.
        var dirs = [(path: path, parent: -1, files: 0, bytes: Int64(0))], level = 0..<1, depth = -1
        walk: while !level.isEmpty {
            depth += 1
            let next = dirs.count
            for start in stride(from: level.lowerBound, to: level.upperBound, by: SFTPClient.window) {
                guard !isCancelled else { break walk }
                let batch = start..<min(start + SFTPClient.window, level.upperBound)
                for (i, items) in zip(batch, fs.list(batch.map { dirs[$0].path })) {
                    for child in items ?? [] where Self.isSafeName(child.name) {
                        let p = (dirs[i].path as NSString).appendingPathComponent(child.name)
                        guard let a = attrs(p, child.attrs) else { continue }
                        if a.kind == .dir { if !othersCanChange(fs, a) { dirs.append((p, i, 0, 0)) } } else { dirs[i].files += 1; dirs[i].bytes = dirs[i].bytes.saturatingAdd(a.size) }
                    }
                }
            }
            level = next..<dirs.count
        }
        for i in dirs.indices.dropFirst().reversed() {   // deepest first: a folder's own totals are whole by then
            dirs[dirs[i].parent].files += dirs[i].files
            dirs[dirs[i].parent].bytes = dirs[dirs[i].parent].bytes.saturatingAdd(dirs[i].bytes)
        }
        for d in dirs { measured[d.path] = (d.files, d.bytes) }
        return (dirs[0].files, dirs[0].bytes, depth)
    }

    /// Partial copies another job left in `dir` (a disk pulled out mid-copy, the app quit): gone once over a day old —
    /// a newer one may be a copy still running. Their ._ twins too (exFAT, FAT32).
    /// Its date alone won't do: a copy sets the source's (old) date on its partial just before the rename. So the
    /// name says when it was made, too; one made over a day ago and not written since is nobody's any more.
    func sweepPartials(_ fs: TransferFS, _ dir: String) {
        let cutoff = Date().timeIntervalSince1970 - 86_400
        for c in (try? fs.list(dir)) ?? [] where Self.isStalePartial(c.name, c.attrs, before: cutoff) {
            let path = (dir as NSString).appendingPathComponent(c.name)
            if fs is LocalFS { lchflags(path, 0) }   // a locked one an older version left: unlink can't remove it locked
            try? fs.remove(path)
        }
    }

    /// A partial file made and last written before `cutoff` (seconds since 1970): nobody's any more.
    static func isStalePartial(_ name: String, _ a: SFTPClient.Attrs, before cutoff: Double) -> Bool {
        a.kind == .file && a.mtime < cutoff && isSafeName(name) && (partialMade(name).map { $0 < cutoff } ?? false)
    }

    /// ".dfm-partial-<seconds since 1970>-<UUID>": a partial copy, and when it was begun.
    static func partialName() -> String { ".dfm-partial-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)" }

    /// When the partial named `name` (or its ._ twin) was begun; 0 for one named before names said so (only its
    /// date tells then); nil if it isn't one.
    static func partialMade(_ name: String) -> Double? {
        let n = name.hasPrefix("._") ? name.dropFirst(2) : Substring(name)
        guard n.hasPrefix(".dfm-partial-") else { return nil }
        let rest = n.dropFirst(".dfm-partial-".count)
        guard let dash = rest.firstIndex(of: "-"), let t = Double(rest[..<dash]), rest.count > 36 else { return 0 }
        return t
    }

    /// S-03: a root session (a root panel, a login as root) doesn't go into a folder someone else on the server can change — one that
    /// isn't root's, or that its group or others may write to without the sticky bit. Between the listing that found
    /// it and the next step in it (SFTP has no openat) they could swap what's there for a link to `/`, and root would
    /// delete, read or write there. Its owner and mode come with that listing: no round trip more. One that doesn't
    /// say (no owner or mode sent) counts as theirs.
    /// ponytail: a top item's own folder isn't looked at (the top swapped between its look and its listing still
    /// races); root-side helpers (`rm -r --one-file-system`) if it bites.
    func othersCanChange(_ fs: TransferFS, _ a: SFTPClient.Attrs) -> Bool {
        guard a.kind == .dir, let root = (fs as? RemoteFS)?.rootUID else { return false }
        guard let uid = a.uid, let mode = a.mode else { return true }
        return uid != root || mode & 0o022 != 0 && mode & UInt32(S_ISVTX) == 0
    }

    /// The mount points in /proc/self/mounts' text; a field's space, tab, newline and backslash come as \040 \011
    /// \012 \134. Not "/": every path is below that one.
    static func mounts(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").compactMap { line -> String? in
            let f = line.split(separator: " ")
            guard f.count > 1 else { return nil }
            var out = "", s = Substring(f[1])
            while let i = s.firstIndex(of: "\\") {
                out += s[..<i]
                let code = s[s.index(after: i)...].prefix(3)
                if code.count == 3, let n = UInt8(code, radix: 8) { out.append(Character(Unicode.Scalar(n))); s = s[s.index(i, offsetBy: 4)...] }
                else { out.append("\\"); s = s[s.index(after: i)...] }
            }
            out += s
            return out == "/" ? nil : out
        })
    }

    /// A server's mount points, read once per side and job (D-084): a delete or a move off a server stops at them, as
    /// ⇧F8 and a move between volumes do on this Mac.
    func mounted(_ fs: TransferFS) -> Set<String> {
        if let known = mountCache[ObjectIdentifier(fs)] { return known }
        let m = fs is LocalFS ? [] : fs.mountPoints(mountsFile)
        mountCache[ObjectIdentifier(fs)] = m
        return m
    }

    /// The server's clock less this Mac's, in whole seconds, from an empty file made in `dir` and removed; 0 if it
    /// can't be made (or this Mac is the side).
    func clockOffset(_ fs: TransferFS, _ dir: String) -> Double {
        guard !(fs is LocalFS) else { return 0 }
        let probe = (dir as NSString).appendingPathComponent(".dfm-clock-" + UUID().uuidString)
        guard let w = try? fs.writer(probe, offset: 0) else { return 0 }
        defer { try? fs.remove(probe) }
        guard (try? w.finish()) != nil, let a = (try? fs.lstat(probe)) ?? nil else { return 0 }
        return (a.mtime - Date().timeIntervalSince1970).rounded()
    }

    /// A folder another volume is mounted on: on this Mac by device (as `FileJob.transfer`), on a server by its list.
    func isMountPoint(_ fs: TransferFS, _ path: String, in parent: String) -> Bool {
        guard fs is LocalFS else { return mounted(fs).contains(path) }
        guard let up = Self.lstat(parent) else { return false }
        return crossesVolume(path, nil, up.st_dev)
    }

    func otherVolumeAcross(_ path: String) {
        update { $0.errors.append("\(path): another volume is mounted here — skipped") }
    }

    /// Said once in the summary, not asked: Retry would find the same folder.
    func notEntered(_ path: String) {
        let line = "\(path): someone else on the server can change this folder — not entered as root. Do it as its owner, or in a terminal there"
        update { if !$0.errors.contains(line) { $0.errors.append(line) } }   // once, however many items it held
    }

    /// A name a server sent can be anything: never one that leaves the folder it was listed in.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }

    private func skip(_ fs: TransferFS, _ path: String, _ a: SFTPClient.Attrs) {
        guard !countsItems else { return }
        let (f, b) = measured[path] ?? { let m = measure(fs, path, a); return (m.files, m.bytes) }()   // a file: no walk
        update { $0.doneFiles += f; $0.doneBytes = $0.doneBytes.saturatingAdd(b) }
    }

    /// `root`: the top folder this job copies into (nil: this is the top). `maxDepth`: how deep the source's folders
    /// went before the job wrote anything; `depth`: how deep `src` is in it.
    /// `seen`: `src` and `dstIn` as just looked at (`dst`'s none: not looked at; some nil: nothing there).
    private func transferAcross(_ sfs: TransferFS, _ src: String, _ dfs: TransferFS, _ dstIn: String, move: Bool,
                                root: String? = nil, depth: Int = 0, maxDepth: Int,
                                seen: (src: SFTPClient.Attrs?, dst: SFTPClient.Attrs??) = (nil, nil)) {
        let top = root == nil
        waitWhilePaused()
        guard !isCancelled else { return }
        let outer = pair
        pair = (src, dstIn)
        defer { pair = outer }
        if top { update { $0.topsBegun += 1 } }
        var dst = dstIn
        var found = seen.src
        guard found != nil || attempt(src, {
            found = try sfs.lstat(src)
            if found == nil { throw JobError(message: "No such file or directory") }
        }), let s = found else { return }
        update { $0.current = (src as NSString).lastPathComponent; $0.currentSize = 0 }
        // Deeper than the source went before the job began: a folder this job made, so the copy is inside its
        // source, however that was reached (an alias, this Mac and localhost, another case, no marker allowed).
        // ponytail: a listing that failed while measuring counts as no subfolders, so a network blip then can
        // refuse a real subfolder here as "into itself".
        if s.kind == .dir && depth > maxDepth { return fail(src, "Cannot \(move ? "move" : "copy") a folder into itself") }

        var (here, there) = (src, dst)
        if top && sameSide && s.kind == .dir {
            // Where both really are: a symlinked folder or "//" on the way mustn't hide one place, or one inside the other.
            // (A file seen two ways is harmless here: a move is a rename, a copy lands on the file itself.)
            func real(_ p: String) throws -> String {
                (try sfs.realpath((p as NSString).deletingLastPathComponent) as NSString).appendingPathComponent((p as NSString).lastPathComponent)
            }
            guard attempt(src, { here = try real(src); there = try real(dst) }) else { return skip(sfs, src, s) }
        }
        if sameSide && here == there {
            // Copy onto itself = duplicate (Finder behaviour); move onto itself = no-op.
            if move { return skip(sfs, src, s) }
            dst = FileJob.uniqueName(dst) { (try? dfs.lstat($0)) ?? nil != nil }
        } else if top && sameSide && s.kind == .dir && there.hasPrefix(here + "/") {
            return fail(src, "Cannot \(move ? "move" : "copy") a folder into itself")
        }

        var existing: SFTPClient.Attrs?
        if dst == dstIn, let d = seen.dst { existing = d }
        else { guard attempt(dst, { existing = try dfs.lstat(dst) }) else { return skip(sfs, src, s) } }
        // Two connections no comparison tells apart (another alias of the server, this Mac and localhost) can still
        // name one file: replacing it with its own copy and then deleting the source would lose it. Same for a
        // link copied over itself (the old one is cleared first). A same-server move is a rename: safe. And a folder
        // merged onto itself, whose source would be emptied into itself and deleted (below the top, two folders
        // aren't one unless their tops are). When that can't be told (no marker may be made there), a copy goes on
        // and meets the real errors itself; a move doesn't risk its source.
        if let d = existing, d.kind == s.kind, s.kind == .dir ? top : move ? !sameSide : s.kind == .link {
            var same: Bool? = false
            guard attempt(dst, { same = try mightBeOneFile(sfs, src, dfs, dst, dir: s.kind == .dir) }) else { return skip(sfs, src, s) }
            if same == true { return fail(src, "It is “\(dst)” itself — not \(move ? "moved" : "copied")") }
            if same == nil && move { return fail(src, "Can't tell whether “\(dst)” is this one itself (no access to mark it) — not moved") }
        }
        var merge = false
        if let d = existing {
            // Whole seconds, as a server keeps them: the Mac's fraction mustn't make a file uploaded before "newer".
            let conflict = Conflict(src: src, dst: dst, srcSize: s.size, dstSize: d.size,
                                    srcMtime: s.mtime.rounded(.down), dstMtime: d.mtime.rounded(.down),
                                    bothDirs: s.kind == .dir && d.kind == .dir, replacesFolder: d.kind == .dir && s.kind != .dir,
                                    createdByThisJob: wroteAcross(dst))
            var choice = askConflict(conflict)
            if choice == .overwriteIfNewer {
                choice = conflict.srcMtime > conflict.dstMtime || conflict.bothDirs ? .overwrite : .skip
            }
            switch choice {
            case .cancel: cancel(); return
            case .skip: return skip(sfs, src, s)
            case .keepBoth:
                dst = FileJob.uniqueName(dst) { (try? dfs.lstat($0)) ?? nil != nil }
                existing = nil
            case .overwrite, .overwriteIfNewer:
                if conflict.bothDirs {
                    merge = true
                } else if s.kind != .file || d.kind != .file {
                    // Anything but file over file (that one is replaced atomically below): the new one under a temporary
                    // name first — a link removed before a copy that then failed left neither (a link never goes through it).
                    return replaceAcross(sfs, src, s, dfs, dst, d, move: move, root: root, depth: depth, maxDepth: maxDepth)
                }
            }
        }

        // Same server: a move is a rename (instant, nothing crosses the network).
        if move && sameSide && !merge {
            guard attempt(src, {
                do { try sfs.rename(src, dst, replace: existing != nil) } catch where s.kind == .dir && isBelow(sfs, dst, src) {
                    throw JobError(message: "Cannot move a folder into itself")   // reached through a name in another case
                }
            }) else { return }
            noteAcross(dst)
            guard !countsItems else { return }
            let (f, b, _) = measure(dfs, dst)
            update { $0.doneFiles += f; $0.doneBytes = $0.doneBytes.saturatingAdd(b) }
            return
        }

        let root = root ?? dst
        // Not a file either (D-082): the partial written there as root, then renamed by name — between the two, its
        // folder's owner can swap what the names lead to.
        if top, let parent = barredParent, (dst as NSString).deletingLastPathComponent == parent { notEntered(parent); return skip(sfs, src, s) }
        switch s.kind {
        case .dir:
            if othersCanChange(sfs, s) { return notEntered(src) }
            if merge, let d = existing, othersCanChange(dfs, d) { notEntered(dst); return skip(sfs, src, s) }
            // Listed before the copy exists: a folder that is somehow inside its source isn't copied into itself.
            var children: [(name: String, attrs: SFTPClient.Attrs)] = []
            guard attempt(src, { children = try sfs.list(src) }) else { return }
            // Nor one it reaches through another connection or a name in another case (no path comparison sees
            // those): a source folder that is the top of the copy stops it here, before it recurses until it crashes.
            // (A top not there yet can't be one of the children listed. One that can't be marked can't be written
            // into either: the copy stops at its own mkdir.)
            for child in children where child.attrs.kind == .dir && Self.isSafeName(child.name) && (merge || !top) {
                var same: Bool? = false
                guard attempt(src, { same = try mightBeOneFile(sfs, (src as NSString).appendingPathComponent(child.name), dfs, root, dir: true) })
                else { return skip(sfs, src, s) }
                if same == true { return fail(src, "Cannot \(move ? "move" : "copy") a folder into itself") }
            }
            if !merge {
                guard attempt(dst, { try dfs.mkdir(dst) }) else { return skip(sfs, src, s) }
                noteAcross(dst)
            }
            for child in children {
                guard !isCancelled else { return }
                let from = (src as NSString).appendingPathComponent(child.name)
                guard Self.isSafeName(child.name) else {
                    fail(src + "/" + child.name, "Unsafe name from the server — not copied")
                    continue
                }
                if move && child.attrs.kind == .dir && isMountPoint(sfs, from, in: src) { otherVolumeAcross(from); continue }
                // What the listing said of it goes along: a far server's lstat per file was one wait more each. And in
                // a folder just made on a server nothing is there yet — but for a name an item copied in before has
                // except for case or composition, taken on a disk that ignores those: looked at, the conflict asks.
                let to = (dst as NSString).appendingPathComponent(child.name)
                let fresh = !merge && !(dfs is LocalFS) && !createdAcross.contains(Self.foldedPath(to))
                transferAcross(sfs, from, dfs, to, move: move, root: root, depth: depth + 1, maxDepth: maxDepth,
                               seen: (child.attrs.typed, fresh ? .some(nil) : nil))
            }
            // Mode and date last: a read-only folder mustn't block its own copy, and filling it bumps its date.
            // Not on a folder merged into: that one keeps its own (as L2 locally: ~/.ssh stays 0700).
            if !merge { keepAttrs(dfs, dst, s) }
            if move && !isCancelled { try? sfs.rmdir(src) }   // fails harmlessly if something inside was skipped
        case .link:
            var target = ""
            guard attempt(src, { target = try sfs.readlink(src) }) else { return }
            if existing != nil { guard attempt(dst, { try dfs.remove(dst) }) else { return } }
            guard attempt(dst, { try dfs.symlink(target, at: dst) }) else { return }
            noteAcross(dst)
            fileDone(src, s.size)   // what measure counted for it
            if move { if dfs is LocalFS { Self.flush(dst) }; attempt(src) { try sfs.remove(src) } }
        case .file:
            guard copyAcross(sfs, src, s, dfs, dst, replace: existing != nil) else { return }
            noteAcross(dst)
            if move { if dfs is LocalFS { Self.flush(dst) }; attempt(src) { try sfs.remove(src) } }
        case .other:
            fail(src, "Not a regular file — not copied")
        }
    }

    /// A folder replacing a file or a link, or the other way round (F-10): the new one first, whole, under a temporary
    /// name beside it; only then the old one goes (to the Trash on this Mac) and the new one takes its name. A copy
    /// that fails or is stopped midway leaves the old one as it was and takes its own half copy away; a move's half
    /// is kept (its source is partly gone), and the summary names where.
    private func replaceAcross(_ sfs: TransferFS, _ src: String, _ s: SFTPClient.Attrs, _ dfs: TransferFS, _ dst: String,
                               _ d: SFTPClient.Attrs, move: Bool, root: String?, depth: Int, maxDepth: Int) {
        let temp = (dst as NSString).deletingLastPathComponent + "/.dfm-new-" + UUID().uuidString   // never swept: a move's may be all there is
        let before = progress.errors.count
        transferAcross(sfs, src, dfs, temp, move: move, root: root, depth: depth, maxDepth: maxDepth, seen: (s, .some(nil)))
        guard !isCancelled, progress.errors.count == before, ((try? dfs.lstat(temp)) ?? nil) != nil else {
            guard ((try? dfs.lstat(temp)) ?? nil) != nil else { return }
            if move { update { $0.errors.append("\(dst): kept as it was; what was moved so far is in \(temp)") } }
            else if let t = (try? dfs.lstat(temp)) ?? nil { try? removeTree(dfs, temp, t) }
            return
        }
        guard attempt(dst, {
            // Neither a folder: renamed over it in one step (a link is replaced itself, never what it points at).
            if s.kind != .dir && d.kind != .dir { return try dfs.rename(temp, dst, replace: true) }
            // On this Mac a replaced folder goes to the Trash (a server has none).
            if dfs is LocalFS && d.kind == .dir { try FileManager.default.trashItem(at: URL(fileURLWithPath: dst), resultingItemURL: nil) }
            else if (try dfs.lstat(dst)) != nil { try removeTree(dfs, dst, d) }
            try dfs.rename(temp, dst, replace: false)
        }) else {
            return update { $0.errors.append("\(dst): the new one is in \(temp)") }
        }
        noteAcross(dst)
    }

    private func noteAcross(_ path: String) { createdAcross.insert(Self.foldedPath(path)) }
    /// `path` or a folder above it is one this job wrote (`Conflict.createdByThisJob`).
    private func wroteAcross(_ path: String) -> Bool {
        var p = Self.foldedPath(path)
        while !createdAcross.isEmpty {
            if createdAcross.contains(p) { return true }
            let up = (p as NSString).deletingLastPathComponent
            if up == p || up.isEmpty { return false }
            p = up
        }
        return false
    }

    /// One file into a hidden partial next to `dst`, then renamed over it. Retry continues from what the partial
    /// already holds (a dropped connection costs only what was in flight). Cancel / Skip remove the partial.
    private func copyAcross(_ sfs: TransferFS, _ src: String, _ s: SFTPClient.Attrs, _ dfs: TransferFS, _ dst: String, replace: Bool) -> Bool {
        let partial = (dst as NSString).deletingLastPathComponent + "/" + Self.partialName()
        var source = s       // the version the partial holds
        var kept: Int64 = 0  // how far the partial holds it without a gap (writes sent after a failed one may have landed)
        var retrying = false
        var attrsSent = false, attrsError: Error?   // mode and date went along with the close (a server's writer)
        update { $0.currentSize = source.size }
        let ok = attempt(src) {
            defer { retrying = true }
            // A retry goes on from what the partial holds; the first try's partial is a fresh name: nothing to ask.
            var done = retrying ? min((try dfs.lstat(partial))?.size ?? 0, kept) : 0
            if retrying, let now = try sfs.lstat(src), now.size != source.size || now.mtime != source.mtime {
                // Changed since: its new version (size, date, mode) from the start, not spliced onto the old one's
                // (nor next time, if this attempt fails before the partial is truncated).
                (done, kept, source) = (0, 0, now)
            }
            lock.withLock { currentFileBytes = done }
            if sameSide, let r = dfs as? RemoteFS, try r.session().canCopyData {
                // Same server: it copies, in slices so pause, cancel and the progress bar still work.
                let slice: Int64 = 64 << 20
                repeat {
                    waitWhilePaused()
                    if isCancelled { return }
                    let n = min(slice, source.size - done)
                    try r.session().copyData(src, to: partial, offset: done, length: n == 0 ? 0 : n)
                    done += n
                    kept = done
                    lock.withLock { currentFileBytes = done }
                } while done < source.size
                return
            }
            let reader = try sfs.reader(src, offset: done, size: source.size)
            defer { reader.close() }
            let writer = try dfs.writer(partial, offset: done)
            var finished = false
            defer { if !finished { writer.close() } }
            defer { kept = writer.confirmed }
            while let piece = try reader.read() {
                waitWhilePaused()
                if isCancelled { return }
                try writer.write(piece)
                done += Int64(piece.count)
                lock.withLock { currentFileBytes = done }
            }
            finished = true
            if let w = writer as? SFTPClient.WriteStream {   // one round trip for the close, mode and date
                attrsError = try w.finish(mtime: source.mtime, mode: source.mode)
                attrsSent = true
            } else {
                try writer.finish()
            }
        }
        lock.withLock { currentFileBytes = 0 }
        guard ok, !isCancelled else {
            try? dfs.remove(partial)
            if !isCancelled { skip(sfs, src, s) }
            return false
        }
        if !attrsSent { keepAttrs(dfs, partial, source, as: dst) } else if let attrsError { attrsNotKept(dst, attrsError) }
        guard attempt(dst, { try dfs.rename(partial, dst, replace: replace) }) else {
            try? dfs.remove(partial)
            return false
        }
        fileDone(src, s.size)
        return true
    }

    /// Mode and date onto the copy. A server that refuses them (vfat / exFAT on Linux: EPERM) still has the data,
    /// so that's no failure, nor a question per file — but reported, not swallowed.
    private func keepAttrs(_ fs: TransferFS, _ path: String, _ s: SFTPClient.Attrs, as shown: String? = nil) {
        do { try fs.setAttrs(path, mtime: s.mtime, mode: s.mode) } catch { attrsNotKept(shown ?? path, error) }
    }

    private func attrsNotKept(_ path: String, _ error: Error) {
        guard !isCancelled else { return }
        let message = (error as? POSIXError).map { String(cString: strerror($0.code.rawValue)) } ?? error.localizedDescription
        update { $0.errors.append("\(path): mode and date not kept — \(message)") }
    }

    /// Whether `src` and `dst` could be one file seen two ways; nil when that can't be told (permission denied).
    /// SFTP has no inode: a marker folder made in `dst` and found in `src` says they're one folder (`dir`: a folder
    /// merged into is written to anyway, its parent maybe not — /var/www), else made next to them that they share
    /// a folder, and then a name equal but for case may be the same entry. (A folder that can't be marked inside
    /// and isn't beside the other may still be it, reached another way: can't tell.)
    private func mightBeOneFile(_ sfs: TransferFS, _ src: String, _ dfs: TransferFS, _ dst: String, dir: Bool) throws -> Bool? {
        guard (src as NSString).lastPathComponent.lowercased() == (dst as NSString).lastPathComponent.lowercased() else { return false }
        if dir, let inside = try marked(sfs, src, dfs, dst) { return inside }
        let beside = try marked(sfs, (src as NSString).deletingLastPathComponent, dfs, (dst as NSString).deletingLastPathComponent)
        return dir && beside == false ? nil : beside
    }

    /// Whether a marker folder made in `there` shows up in `here`; nil when it may not be made.
    private func marked(_ sfs: TransferFS, _ here: String, _ dfs: TransferFS, _ there: String) throws -> Bool? {
        let marker = ".dfm-same-" + UUID().uuidString
        let made = (there as NSString).appendingPathComponent(marker)
        do {
            try dfs.mkdir(made)
            defer { try? dfs.rmdir(made) }
            return try sfs.lstat((here as NSString).appendingPathComponent(marker)) != nil
        } catch let e as POSIXError where [.EACCES, .EPERM, .EROFS].contains(e.code) {
            return nil
        } catch let e as SFTPError where e.code == SFTPClient.PERMISSION_DENIED {
            return nil
        }
    }

    /// Whether `path` is below the folder `dir` on one server, however either is spelled (a name in another case).
    private func isBelow(_ fs: TransferFS, _ path: String, _ dir: String) -> Bool {
        sequence(first: (path as NSString).deletingLastPathComponent) { p in
            let up = (p as NSString).deletingLastPathComponent
            return up == p ? nil : up
        }.contains { (try? mightBeOneFile(fs, $0, fs, dir, dir: true)) == true }
    }

    /// Deletes what's at `path` (a folder with everything in it), never following a symlink.
    private func removeTree(_ fs: TransferFS, _ path: String, _ a: SFTPClient.Attrs) throws {
        guard a.kind == .dir else { return try fs.remove(path) }
        if othersCanChange(fs, a) { throw JobError(message: "Someone else on the server can change this folder — not entered as root") }
        if mounted(fs).contains(path) { throw JobError(message: "Another volume is mounted here — not deleted") }
        for child in try fs.list(path) where Self.isSafeName(child.name) {
            try removeTree(fs, (path as NSString).appendingPathComponent(child.name), child.attrs)
        }
        try fs.rmdir(path)
    }
}
