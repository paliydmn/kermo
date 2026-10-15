import Foundation

/// One queued file operation. Runs on its own thread (blocking I/O never touches the
/// Swift cooperative pool); the UI polls `progress` and answers questions via the
/// synchronous `resolve*` callbacks, which may block the worker until the user decides.
public final class FileJob: @unchecked Sendable {
    public enum Kind: Sendable { case copy, move, trash, delete }

    public enum ConflictChoice: Sendable { case overwrite, skip, keepBoth, overwriteIfNewer, cancel }
    public enum ErrorChoice: Sendable { case retry, skip, abort }
    public enum State: Sendable, Equatable { case queued, scanning, running, done, cancelled, failed }

    public struct Conflict: Sendable {
        public let src: String, dst: String
        public let srcSize: Int64, dstSize: Int64
        public let srcMtime: Double, dstMtime: Double
        public let bothDirs: Bool
        /// A file (or link) would replace a folder: always asked on its own, never by "apply to all".
        public var replacesFolder = false
        /// What's there is what this job just put there: two sources land on one name (`Makefile` and `makefile` on
        /// a case-insensitive volume). Always asked on its own too: "apply to all" would have one replace the other.
        public var createdByThisJob = false
    }

    public struct Progress: Sendable {
        public var state = State.queued
        public var totalBytes: Int64 = 0, doneBytes: Int64 = 0
        public var totalFiles = 0, doneFiles = 0
        public var current = ""
        public var errors: [String] = []
    }

    public let kind: Kind
    /// Where the sources are and where they go. Both `.local`: the copyfile path below; otherwise `runAcross`
    /// (Transfer.swift) over SFTP.
    public let from: Endpoint, to: Endpoint
    /// For a server: ssh's environment (SSH_ASKPASS for password prompts).
    let sshEnv: [String: String]
    public let sources: [String]
    /// Destination directory (copy/move). With a single source, `targetName` may rename it.
    public let destDir: String?
    public let targetName: String?
    /// Explicit source → destination paths (Synchronize Folders); used instead of destDir when set.
    public let pairs: [(src: String, dst: String)]

    /// Called on the worker thread. Return (choice, applyToAllRemaining).
    public var resolveConflict: @Sendable (Conflict) -> (ConflictChoice, Bool) = { _ in (.skip, false) }
    /// Called on the worker thread. Return (choice, applyToAllRemaining).
    public var resolveError: @Sendable (_ path: String, _ message: String) -> (ErrorChoice, Bool) = { _, _ in (.skip, false) }
    public var onFinish: @Sendable () -> Void = {}
    /// Synchronize: each path as Compare saw it (nil = nothing there). A pair or trash item whose path no longer
    /// matches changed after Compare: it is skipped and reported, never overwritten or trashed on a stale plan.
    public var expected: [String: FileItem?] = [:]
    /// The same for a pair's destination: a map of its own, as a server's path may be spelled like one on this Mac.
    public var expectedTarget: [String: FileItem?] = [:]

    let lock = NSLock()
    private var _progress = Progress()
    private var _cancelled = false
    private var _paused = false
    var currentFileBytes: Int64 = 0
    private var _results: [(src: String, dst: String)] = []
    private var conflictPolicy: ConflictChoice?
    private var errorPolicy: ErrorChoice?
    /// A move within one volume: each source is one rename, so progress counts the sources — no tree walks.
    var countsItems = false   // a move that renames: progress counts the items, no walk of their trees
    /// Device and inode of everything this job created (worker thread only): see `Conflict.createdByThisJob`.
    private var created = Set<String>()
    /// Its device (nil: gone).
    @discardableResult
    private func noteCreated(_ path: String) -> dev_t? {
        guard let s = Self.lstat(path) else { return nil }
        created.insert(Self.key(s))
        return s.st_dev
    }
    private static func key(_ s: stat) -> String { "\(s.st_dev):\(s.st_ino)" }
    /// The folder a `transfer` writes into, as its caller already knows it: its device (a rename needs the source on
    /// it), and whether this job made it, or one above it. Saves looking at each file's destination folder again.
    private struct Into { let dev: dev_t, created: Bool }
    /// `path` or a folder above it is one this job created: a folder moved here by one rename brings its whole tree.
    private func isCreated(_ path: String) -> Bool {
        var p = path
        while !created.isEmpty {
            if let s = Self.lstat(p), created.contains("\(s.st_dev):\(s.st_ino)") { return true }
            let up = (p as NSString).deletingLastPathComponent
            if up == p || up.isEmpty { return false }
            p = up
        }
        return false
    }
    /// The same across a server (SFTP has no inodes): each path this job wrote, compared as a case- and
    /// normalization-insensitive volume would. On a case-sensitive server that may ask once too often, never too little.
    var createdAcross = Set<String>()
    /// Each folder's files and bytes as `measure` counted them: what Skip adds to the progress, without a second walk.
    var measured: [String: (files: Int, bytes: Int64)] = [:]
    static func foldedPath(_ p: String) -> String { p.precomposedStringWithCanonicalMapping.lowercased() }
    /// Fired by `cancel()`: a transfer over SFTP drops its connections, so a stalled server can't hold it up.
    let cancelFlag = CancelFlag()

    public convenience init(_ kind: Kind, sources: [String], destDir: String? = nil, targetName: String? = nil) {
        self.init(kind, sources: sources, from: .local, to: .local, destDir: destDir, targetName: targetName)
    }

    /// Copy or move between any two places (local, a server, another server).
    public init(_ kind: Kind, sources: [String], from: Endpoint, to: Endpoint, destDir: String?, targetName: String? = nil,
                sshEnv: [String: String] = [:]) {
        self.kind = kind
        self.from = from
        self.to = to
        self.sshEnv = sshEnv
        self.sources = sources
        self.destDir = destDir
        self.targetName = sources.count == 1 ? targetName : nil
        self.pairs = []
    }

    /// Copies each `src` to exactly `dst`, replacing what's there (sync already decided the direction).
    public init(copyPairs: [(src: String, dst: String)], from: Endpoint = .local, to: Endpoint = .local, sshEnv: [String: String] = [:]) {
        kind = .copy
        self.from = from
        self.to = to
        self.sshEnv = sshEnv
        sources = copyPairs.map(\.src)
        destDir = nil
        targetName = nil
        pairs = copyPairs
        conflictPolicy = .overwrite
    }

    public var progress: Progress {
        lock.withLock {
            var p = _progress
            p.doneBytes += currentFileBytes
            return p
        }
    }
    public var isCancelled: Bool { lock.withLock { _cancelled } }

    /// Top-level items this job newly created (copy/move target, or where trash put them) — what undo needs.
    /// Items that merged into or overwrote something existing are left out: those can't be undone safely.
    public var results: [(src: String, dst: String)] { lock.withLock { _results } }
    public var isPaused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }
    public func cancel() {
        lock.withLock { _cancelled = true; _paused = false }
        cancelFlag.cancel()
    }

    func update(_ f: (inout Progress) -> Void) { lock.withLock { f(&_progress) } }

    // MARK: - Running

    public func start() {
        let t = Thread { [self] in
            run()
            onFinish()
        }
        t.name = "FileJob \(kind)"
        t.qualityOfService = .userInitiated
        t.stackSize = 16 << 20   // transfer() recurses once per folder level; PATH_MAX caps that at ~500 levels
        t.start()
    }

    /// Synchronous entry point (used by `start()` and by tests).
    public func run() {
        if from != .local || to != .local { return runAcross() }
        switch kind {
        case .copy, .move:
            update { $0.state = .scanning }
            if let destDir { sweepPartials(LocalFS(), destDir) }
            countsItems = kind == .move && destDir.map { d in sources.allSatisfy { Self.sameVolume($0, d) } } == true
            let (files, bytes) = countsItems ? (sources.count, Int64(0)) : sources.reduce((0, Int64(0))) { acc, s in
                let t = DirLister.measure(s, isCancelled: { isCancelled })
                return (acc.0 + t.0, acc.1 + t.1)
            }
            update { $0.totalFiles = files; $0.totalBytes = bytes; $0.state = .running }
            for (src, dst) in pairs {
                guard !isCancelled else { break }
                if changedSinceCompare(LocalFS(), src, LocalFS(), dst) { skipCount(src); continue }
                if let done = transfer(src, dst, move: false, top: true) { lock.withLock { _results.append((src, done)) } }
            }
            guard let destDir else { return finish() }
            for src in sources {
                guard !isCancelled else { break }
                let name = targetName ?? (src as NSString).lastPathComponent
                if let dst = transfer(src, (destDir as NSString).appendingPathComponent(name), move: kind == .move, top: true) {
                    lock.withLock { _results.append((src, dst)) }
                }
                if countsItems { update { $0.doneFiles += 1 } }
            }
        case .trash, .delete:
            update { $0.totalFiles = sources.count; $0.state = .running }
            for src in sources {
                guard !isCancelled else { break }
                update { $0.current = (src as NSString).lastPathComponent }
                if changedSinceCompare(LocalFS(), src) { update { $0.doneFiles += 1 }; continue }
                var trashed: NSURL?
                if kind == .trash {
                    attempt(src) { try FileManager.default.trashItem(at: URL(fileURLWithPath: src), resultingItemURL: &trashed) }
                } else {
                    remove(src)
                }
                if let path = trashed?.path { lock.withLock { _results.append((src, path)) } }
                update { $0.doneFiles += 1 }
            }
        }
        finish()
    }

    func finish() {
        update { p in
            if p.state != .failed { p.state = isCancelledUnlocked ? .cancelled : .done }
            p.current = ""
        }
    }
    private var isCancelledUnlocked: Bool { _cancelled }   // only call while holding `lock`

    /// Deletes bottom-up and keeps going past what can't go, each failure under its own path. (removeItem stops
    /// at the first one: half the tree gone, and the error names only the top folder.) Never follows symlinks.
    /// `isDir`: as the folder's listing said (nil: look).
    @discardableResult
    private func remove(_ path: String, isDir: Bool? = nil) -> Bool {
        guard isDir ?? (Self.lstat(path).map { $0.st_mode & S_IFMT == S_IFDIR } ?? false) else {
            return attempt(path) { try Self.check(unlink(path)) }
        }
        var ok = true
        for child in (try? DirLister.list(path)) ?? [] {
            guard !isCancelled else { return false }
            ok = remove((path as NSString).appendingPathComponent(child.name), isDir: child.kind == .dir) && ok
        }
        return ok && attempt(path) { try Self.check(rmdir(path)) }   // a folder with leftovers stays, already reported
    }

    /// Size (files only: a folder's is 0 in a listing) and mtime against `expected` (`dst`: `expectedTarget`), each
    /// on its own side; a mismatch goes in `errors`.
    func changedSinceCompare(_ fs: TransferFS, _ src: String, _ dfs: TransferFS? = nil, _ dst: String? = nil) -> Bool {
        changed(src, expected, (try? fs.lstat(src)) ?? nil) || dst.map { changed($0, expectedTarget, (try? (dfs ?? fs).lstat($0)) ?? nil) } == true
    }

    /// `path` as it is now (`a`, nil: nothing there; looked at only if Compare saw it) against what Compare saw there.
    func changed(_ path: String, _ saw: [String: FileItem?], _ a: @autoclosure () -> SFTPClient.Attrs?) -> Bool {
        guard let want = saw[path] else { return false }
        let a = a()
        guard a?.mtime != want?.mtime || a.map({ $0.kind == .dir }) != want.map({ $0.kind == .dir })
            || want?.kind == .file && a?.size != want?.size else { return false }
        update { $0.errors.append("\(path): changed since Compare, skipped") }
        return true
    }

    // MARK: - Copy / move

    /// Returns the final destination if it was newly created there in full (nil if skipped, failed,
    /// merged or overwritten).
    /// `top`: a source the user picked. Only there can the destination lie inside the source folder — below it
    /// the destination is a folder this job made or merged into, and symlinks are copied, never followed.
    /// `into`: what the caller knows of the destination's folder (nil: a top item, looked at when needed).
    @discardableResult
    private func transfer(_ src: String, _ dstIn: String, move: Bool, top: Bool = false, into: Into? = nil) -> String? {
        waitWhilePaused()   // APFS clones never call the copyfile progress callback, so pause takes effect here
        guard !isCancelled else { return nil }
        var dst = dstIn
        guard let s = Self.lstat(src) else {
            fail(src, "No such file or directory")
            return nil
        }
        let errorsBefore = progress.errors.count
        let srcIsDir = s.st_mode & S_IFMT == S_IFDIR
        update { $0.current = (src as NSString).lastPathComponent }

        if src == dst {
            // Copy onto itself = duplicate (Finder behaviour); move onto itself = no-op.
            if move { skipCount(src, s); return nil }
            dst = Self.uniqueName(dst)
        } else if top && srcIsDir && (dst.hasPrefix(src + "/") || Self.isInside((dst as NSString).deletingLastPathComponent, s)) {
            fail(src, "Cannot \(move ? "move" : "copy") a folder into itself")
            return nil
        }

        var merge = false
        var createsNew = true
        var createdHere = into?.created ?? false   // dst, when it's a folder this job made (or is inside one)
        var dstDev: dev_t?

        if let d = Self.lstat(dst) {
            createsNew = false
            let dstIsDir = d.st_mode & S_IFMT == S_IFDIR
            createdHere = into.map { $0.created || created.contains(Self.key(d)) } ?? isCreated(dst)
            dstDev = d.st_dev
            let conflict = Conflict(src: src, dst: dst, srcSize: Int64(s.st_size), dstSize: Int64(d.st_size),
                                    srcMtime: Self.mtime(s), dstMtime: Self.mtime(d), bothDirs: srcIsDir && dstIsDir,
                                    replacesFolder: dstIsDir && !srcIsDir, createdByThisJob: createdHere)
            var choice = askConflict(conflict)
            if choice == .overwriteIfNewer {
                choice = conflict.srcMtime > conflict.dstMtime || conflict.bothDirs ? .overwrite : .skip
            }
            switch choice {
            case .cancel: cancel(); return nil
            case .skip: skipCount(src, s); return nil
            case .keepBoth:
                dst = Self.uniqueName(dst)
                createsNew = true
                createdHere = into?.created ?? false
            case .overwrite, .overwriteIfNewer:
                if srcIsDir && dstIsDir {
                    merge = true
                } else if srcIsDir || dstIsDir {
                    // Type mismatch (file ↔ folder): the destination goes to the Trash, never straight away.
                    guard attempt(dst, { try FileManager.default.trashItem(at: URL(fileURLWithPath: dst), resultingItemURL: nil) })
                    else { skipCount(src, s); return nil }
                }
                // file → file overwrite is handled atomically below (temp + rename).
            }
        }

        // Fast path: same-volume move is a rename (instant, keeps everything).
        if move && !merge && into.map({ $0.dev == s.st_dev }) ?? Self.sameVolume(src, (dst as NSString).deletingLastPathComponent) {
            guard attempt(src, { try Self.check(Darwin.rename(src, dst)) }) else { return nil }
            noteCreated(dst)
            if !countsItems {
                let (f, b) = DirLister.measure(dst, isCancelled: { isCancelled })
                update { $0.doneFiles += f; $0.doneBytes += b }
            }
            return createsNew ? dst : nil
        }

        if srcIsDir {
            if !merge {
                guard attempt(dst, { try Self.check(mkdir(dst, 0o700)) }) else { skipCount(src, s); return nil }
                dstDev = noteCreated(dst)
                createdHere = true
            }
            var children: [FileItem] = []
            // Unreadable (mode 000, TCC, a pulled drive): an error to retry or skip, not an empty folder.
            guard attempt(src, { children = try DirLister.list(src) }) else { return nil }
            if !DirLister.hasNativeXattrs(src) {
                // "._name" holds name's xattrs: copyfile carries them along with name, and unlinking name removes
                // its "._" too. Copied on its own it would be junk on the Mac — or vanish mid-move (F3).
                let names = Set(children.map(\.name))
                children.removeAll { $0.name.hasPrefix("._") && names.contains(String($0.name.dropFirst(2))) }
            }
            let here = dstDev.map { Into(dev: $0, created: createdHere) }
            for child in children {
                guard !isCancelled else { return nil }
                transfer((src as NSString).appendingPathComponent(child.name),
                         (dst as NSString).appendingPathComponent(child.name), move: move, into: here)
            }
            // Permissions, xattrs, ACLs and dates last, so a read-only source dir doesn't block its own copy.
            // Not on a folder merged into: that one keeps its own (a FAT folder must not make ~/.ssh 0777).
            if !merge { _ = copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_METADATA)) }
            if move { _ = rmdir(src) }   // fails harmlessly if something inside was skipped
        } else {
            guard copyFile(src, dst, size: Int64(s.st_size)) else { return nil }
            noteCreated(dst)
            if move { attempt(src) { try Self.check(unlink(src)) } }
        }
        return createsNew && !merge && !isCancelled && progress.errors.count == errorsBefore ? dst : nil
    }

    /// Copies one file (or symlink) with APFS clone when possible, into a hidden partial file renamed over `dst`
    /// once whole: a crash or a pulled drive never leaves a cut-off file under the real name.
    private func copyFile(_ src: String, _ dst: String, size: Int64) -> Bool {
        let target = (dst as NSString).deletingLastPathComponent + "/" + Self.partialName()

        let ok = attempt(src) {
            let state = copyfile_state_alloc()
            defer { copyfile_state_free(state) }
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyProgressCallback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(self).toOpaque())
            // CLONE = clone-or-copy with ACL, stat, xattrs, data; never follows a source symlink.
            let r = copyfile(src, target, state, copyfile_flags_t(COPYFILE_CLONE))
            lock.withLock { currentFileBytes = 0 }
            if r != 0 {
                let err = errno
                unlink(target)
                if isCancelled { return }
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
            }
            do { try Self.check(Darwin.rename(target, dst)) } catch { unlink(target); throw error }
        }
        if ok && !isCancelled {
            update { $0.doneFiles += 1; $0.doneBytes += size }
        }
        return ok && !isCancelled
    }

    fileprivate func copyProgress(_ copied: Int64) {
        lock.withLock { currentFileBytes = copied }
    }

    /// Blocks the worker while paused. Polling is fine at this granularity.
    func waitWhilePaused() {
        while isPaused && !isCancelled { usleep(100_000) }
    }

    // MARK: - Questions & errors

    func askConflict(_ c: Conflict) -> ConflictChoice {
        if c.replacesFolder || c.createdByThisJob { return resolveConflict(c).0 }
        if let p = lock.withLock({ conflictPolicy }) { return p }
        let (choice, all) = resolveConflict(c)
        if all { lock.withLock { conflictPolicy = choice } }
        return choice
    }

    /// Runs `body`, asking the user on failure (retry / skip / abort). Returns true on success.
    @discardableResult
    func attempt(_ path: String, _ body: () throws -> Void) -> Bool {
        while !isCancelled {
            do {
                try body()
                return true
            } catch {
                if error is CancellationError { cancel() }   // a sudo password sheet's Cancel: no Retry / Skip / Abort after it
                if isCancelled { return false }   // the failure is the cancel itself (a dropped connection, COPYFILE_QUIT)
                let message = (error as? POSIXError).map { String(cString: strerror($0.code.rawValue)) } ?? error.localizedDescription
                let policy = lock.withLock { errorPolicy }
                let (choice, all) = policy.map { ($0, false) } ?? resolveError(path, message)
                if all { lock.withLock { errorPolicy = choice } }
                switch choice {
                case .retry: continue
                case .skip:
                    update { $0.errors.append("\(path): \(message)") }
                    return false
                case .abort:
                    update { $0.errors.append("\(path): \(message)"); $0.state = .failed }
                    cancel()
                    return false
                }
            }
        }
        return false
    }

    func fail(_ path: String, _ message: String) {
        attempt(path) { throw JobError(message: message) }
    }

    /// `s`: `src` as just looked at (a file's size is that; a folder is walked).
    private func skipCount(_ src: String, _ s: stat? = nil) {
        guard !countsItems else { return }
        let (f, b) = s.map { $0.st_mode & S_IFMT == S_IFDIR } == false ? (1, Int64(s!.st_size))
            : DirLister.measure(src, isCancelled: { isCancelled })
        update { $0.doneFiles += f; $0.doneBytes += b }
    }

    // MARK: - Helpers

    /// "name.txt" → "name 2.txt", "name 3.txt", ... (Finder's Keep Both).
    public static func uniqueName(_ path: String) -> String {
        uniqueName(path) { lstat($0) != nil }
    }

    static func uniqueName(_ path: String, exists: (String) -> Bool) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = (dir as NSString).appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// Is `dir` the folder `s` describes, or inside it? By device + inode of `dir`'s real ancestors, so a symlink
    /// (dst = link → src/sub) or other letter case on a case-insensitive volume (Dir → dir/sub) can't hide it.
    static func isInside(_ dir: String, _ s: stat) -> Bool {
        guard let real = realpath(dir, nil) else { return false }
        var p = String(cString: real)
        free(real)
        while true {
            var a = stat()
            if Darwin.lstat(p, &a) == 0 && a.st_dev == s.st_dev && a.st_ino == s.st_ino { return true }
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p || parent.isEmpty { return false }
            p = parent
        }
    }

    /// Can `path` be renamed into `dir`? rename(2) can't cross volumes (EXDEV): those need a copy and a delete.
    /// `dir` is followed (~/usb → /Volumes/USB is on the stick), `path` isn't (a link moves as the link).
    public static func sameVolume(_ path: String, _ dir: String) -> Bool {
        var b = stat()
        guard let a = lstat(path), fstatat(AT_FDCWD, dir, &b, 0) == 0 else { return false }
        return a.st_dev == b.st_dev
    }

    static func lstat(_ path: String) -> stat? {
        var s = stat()
        return Darwin.lstat(path, &s) == 0 ? s : nil
    }

    private static func mtime(_ s: stat) -> Double {
        Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9
    }

    private static func check(_ result: Int32) throws {
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

struct JobError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// copyfile(3) status callback: reports per-file data progress, honours pause and cancel.
private let copyProgressCallback: copyfile_callback_t = { what, stage, state, _, _, ctx in
    let job = Unmanaged<FileJob>.fromOpaque(ctx!).takeUnretainedValue()
    if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        job.copyProgress(Int64(copied))
    }
    job.waitWhilePaused()
    return job.isCancelled ? COPYFILE_QUIT : COPYFILE_CONTINUE
}
