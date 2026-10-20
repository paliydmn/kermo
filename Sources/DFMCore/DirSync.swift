import Foundation

/// Recursive folder comparison for Synchronize Folders. Produces one row per difference: a file or a whole
/// folder that exists on one side only, or a file that differs. Folders present on both sides are walked into.
public enum DirSync {
    public enum Action: Sendable, Equatable { case equal, toRight, toLeft, skip, trashLeft, trashRight }

    public struct Item: Sendable {
        public let path: String          // relative to the left root (and to the right one, unless `rightPath` says otherwise)
        /// Names match regardless of case (one side may be case-insensitive): `docs/a` on the right is `Docs/a` on
        /// the left. Each side's path keeps its own spelling, so a case-sensitive side is never written a twin.
        public var rightPath: String? = nil
        public let left: FileItem?       // nil = missing on that side
        public let right: FileItem?
        public var action: Action
        /// Same date but different size/content, or file vs. folder: no safe default direction.
        public let isConflict: Bool
        /// A folder that couldn't be listed on one side (mode 000, a pulled drive, a dropped share): its contents
        /// are unknown, so nothing below it is copied or trashed. Or a file whose contents weren't compared.
        public var unreadable: String? = nil
    }

    /// Lists folders for `compare`, in order: each one's items, or why it couldn't be listed.
    public typealias Lister = @Sendable (_ dirs: [String]) -> [Result<[FileItem], Error>]

    /// This Mac's folders, as the panel lists them.
    public static let localList: Lister = { $0.map { d in Result { try DirLister.list(d) } } }

    /// `listRight`: the right side's lister when it isn't `list` (a server: see `lister`); `tolerance` then comes
    /// from the side on this Mac. `byContent` reads both sides as local files.
    /// Level by level, `SFTPClient.window` folders at a time, both sides at once: a server's round trips add up per
    /// level, not per folder. The rows come out as a walk into each folder in turn would give them.
    public static func compare(left: String, right: String, byContent: Bool = false, includeHidden: Bool = false,
                               isCancelled: () -> Bool = { false }, list: @escaping Lister = localList,
                               listRight: Lister? = nil, tolerance: Double? = nil) -> [Item] {
        var out: [Item] = []
        let tolerance = tolerance ?? mtimeTolerance([left, right]), listRight = listRight ?? list
        func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
        func full(_ root: String, _ rel: String) -> String { rel.isEmpty ? root : (root as NSString).appendingPathComponent(rel) }
        func walkOrder() -> [Item] {
            out.map { ($0, $0.path.split(separator: "/").map { key(String($0)) }) }.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
        }
        // Folders on both sides, to walk into: (left path, right path), relative.
        var level = [(rel: "", rightRel: "")]
        while !level.isEmpty {
            var next: [(rel: String, rightRel: String)] = []
            for start in stride(from: 0, to: level.count, by: SFTPClient.window) {
                let batch = level[start..<min(start + SFTPClient.window, level.count)]
                // The right side in the background meanwhile; `rs` is read only after `done`.
                nonisolated(unsafe) var rs: [Result<[FileItem], Error>] = []
                let done = DispatchSemaphore(value: 0), rightDirs = batch.map { full(right, $0.rightRel) }
                DispatchQueue.global(qos: .userInitiated).async { rs = listRight(rightDirs); done.signal() }
                let ls = list(batch.map { full(left, $0.rel) })
                done.wait()
                for ((rel, rightRel), lr, rr) in zip(zip(batch, ls), rs).map({ ($0.0, $0.1, $1) }) {
                    func children(_ r: Result<[FileItem], Error>) throws -> [String: [FileItem]] {
                        Dictionary(grouping: try r.get().filter { includeHidden || !$0.isHidden }) { key($0.name) }
                    }
                    let l: [String: [FileItem]], r: [String: [FileItem]]
                    do {
                        l = try children(lr)
                        r = try children(rr)
                    } catch {
                        // Not "empty": mirror would trash everything on the other side.
                        let why = (error as? POSIXError).map { String(cString: strerror($0.code.rawValue)) } ?? error.localizedDescription
                        out.append(Item(path: rel.isEmpty ? "." : rel, left: nil, right: nil, action: .skip, isConflict: true, unreadable: why))
                        continue
                    }
                    for k in Set(l.keys).union(r.keys).sorted() {
                        if isCancelled() { return walkOrder() }
                        let a = l[k]?.first, b = r[k]?.first
                        func under(_ rel: String, _ name: String) -> String { rel.isEmpty ? name : rel + "/" + name }
                        let path = under(rel, (a ?? b)!.name), rightPath = under(rightRel, (b ?? a)!.name)
                        // `Makefile` and `makefile` on a case-sensitive side are one name on the other: neither is copied
                        // (nor anything below), and the row says why, rather than one of them silently left out.
                        if (l[k]?.count ?? 0) > 1 || (r[k]?.count ?? 0) > 1 {
                            let names = Set(((l[k] ?? []) + (r[k] ?? [])).map(\.name)).sorted().joined(separator: ", ")
                            out.append(Item(path: path, rightPath: rightPath, left: a, right: b, action: .skip, isConflict: true,
                                            unreadable: "names differ only in case: \(names)"))
                            continue
                        }
                        switch (a, b) {
                        case let (a?, nil): out.append(Item(path: path, rightPath: rightPath, left: a, right: nil, action: .toRight, isConflict: false))
                        case let (nil, b?): out.append(Item(path: path, rightPath: rightPath, left: nil, right: b, action: .toLeft, isConflict: false))
                        case let (a?, b?):
                            if a.kind == .dir && b.kind == .dir { next.append((path, rightPath)); continue }
                            if (a.kind == .dir) != (b.kind == .dir) {
                                out.append(Item(path: path, rightPath: rightPath, left: a, right: b, action: .skip, isConflict: true))
                                continue
                            }
                            let r = row(path, a, b, left: left, right: right, byContent: byContent, tolerance: tolerance, rightPath: rightPath,
                                        isCancelled: isCancelled)
                            // `README` here, `readme` there, not alike: one file renamed on a disk that ignores case, two
                            // unrelated ones where both sides tell them apart (two servers) — copying the newer over the
                            // other's name replaced that one. Shown, not synchronized.
                            if r.action != .equal, a.name.precomposedStringWithCanonicalMapping != b.name.precomposedStringWithCanonicalMapping {
                                out.append(Item(path: path, rightPath: rightPath, left: a, right: b, action: .skip, isConflict: true,
                                                unreadable: "names differ in case: \(a.name) here, \(b.name) there"))
                            } else {
                                out.append(r)
                            }
                        case (nil, nil): break
                        }
                    }
                }
            }
            level = next
        }
        return walkOrder()
    }

    /// The row for something that is a file (or link, …) on both sides.
    static func row(_ path: String, _ a: FileItem, _ b: FileItem, left: String, right: String, byContent: Bool, tolerance: Double,
                    rightPath: String? = nil, isCancelled: () -> Bool = { false }) -> Item {
        let sameTime = sameMoment(a, b, tolerance: tolerance)
        var same = sameTime && a.size == b.size
        func item(_ action: Action, conflict: Bool, unreadable: String? = nil) -> Item {
            Item(path: path, rightPath: rightPath, left: a, right: b, action: action, isConflict: conflict, unreadable: unreadable)
        }
        if same && byContent && a.kind == .file && b.kind == .file {   // never open a FIFO (blocks) or follow a link
            if a.isDataless || b.isDataless {   // reading would download it: contents unknown, neither equal nor different
                return item(.skip, conflict: true, unreadable: "not downloaded (iCloud / Dropbox)")
            }
            same = filesEqual((left as NSString).appendingPathComponent(path), (right as NSString).appendingPathComponent(rightPath ?? path),
                              isCancelled: isCancelled)
        }
        if same { return item(.equal, conflict: false) }
        if sameTime { return item(.skip, conflict: true) }
        return item(a.mtime > b.mtime ? .toRight : .toLeft, conflict: false)
    }

    /// Lists `side`'s folders for `compare`: this Mac's as the panel does, a server's over one SFTP connection
    /// (whole seconds — the panel's `ls` has minutes) that `close` drops, and so does `cancel`: ⎋ doesn't wait for a
    /// server that stopped answering.
    public static func lister(_ side: Endpoint, env: [String: String] = [:], cancel: CancelFlag? = nil) -> (list: Lister, close: @Sendable () -> Void) {
        guard case .sftp(let t) = side else { return (localList, {}) }
        let fs = RemoteFS(t, env: env, cancel: cancel)
        let previous = cancel?.onCancel(nil)   // the other side's, server to server
        cancel?.onCancel { previous?(); fs.close() }
        return (lister(fs), { fs.close() })
    }

    /// A server's folders, each batch with the requests in flight together (`SFTPClient.list(_ dirs:)`).
    static func lister(_ fs: TransferFS) -> Lister {
        { dirs in
            zip(dirs, fs.list(dirs)).map { dir, listed in
                // One the batch couldn't list: once more on its own, for why (or it lists now).
                Result {
                    try (listed ?? fs.list(dir)).filter { FileJob.isSafeName($0.name) }.map {
                        FileItem(name: $0.name, kind: $0.attrs.kind, size: $0.attrs.size, mtime: $0.attrs.mtime, mode: $0.attrs.mode ?? 0, flags: 0)
                    }
                }
            }
        }
    }

    /// Seconds two mtimes may differ by and still be one moment: SMB rounds to 1 s, FAT and exFAT keep 2 s.
    public static func mtimeTolerance(_ paths: [String]) -> Double {
        paths.contains { path in
            var s = statfs()
            guard statfs(path, &s) == 0 else { return false }
            let type = withUnsafeBytes(of: s.f_fstypename) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            return type == "msdos" || type == "exfat"
        } ? 2 : 1
    }

    /// Same moment within `tolerance` — or, on FAT/exFAT (`tolerance` 2) at the same size, exactly an hour apart:
    /// FAT keeps local time, so a change to or from daylight saving time shifts every file on it by 3600 s.
    /// Elsewhere mtimes are UTC, and a same-size file written an hour later (an hourly status file, a disk image
    /// band) is a real edit. FAT behind SMB/NFS isn't detected and loses the hour rule: a re-copy, never a miss.
    public static func sameMoment(_ a: FileItem, _ b: FileItem, tolerance: Double) -> Bool {
        let d = abs(a.mtime - b.mtime)
        return d <= tolerance || tolerance >= 2 && a.size == b.size && abs(d - 3600) <= tolerance
    }

    /// Mirror mode: make the target side an exact copy — everything that differs is copied across, and what
    /// exists only on the target side goes to the Trash. File-vs-folder clashes and uncompared files stay skipped.
    public static func mirror(_ items: [Item], toRight: Bool) -> [Item] {
        items.map { item in
            var it = item
            if it.unreadable != nil { return it }
            switch (it.left, it.right) {
            case (_?, nil): it.action = toRight ? .toRight : .trashLeft
            case (nil, _?): it.action = toRight ? .trashRight : .toLeft
            case let (a?, b?) where it.action != .equal && (a.kind == .dir) == (b.kind == .dir): it.action = toRight ? .toRight : .toLeft
            default: break
            }
            return it
        }
    }

    /// The queued work for a reviewed plan, each job with its label: trash first, then a copy job per direction.
    /// Every job knows what Compare saw at its paths, so it skips whatever changed since (`FileJob.expected`).
    /// A side on a server (`sides`) has no Trash: what goes there is deleted.
    /// `comparedAt`: when Compare began; a delete on a server keeps what's newer (`FileJob.comparedAt`).
    public static func jobs(_ items: [Item], left: String, right: String, sides: (left: Endpoint, right: Endpoint) = (.local, .local),
                            env: [String: String] = [:], comparedAt: Double? = nil) -> [(job: FileJob, label: String)] {
        func full(_ it: Item, onRight: Bool) -> String {
            onRight ? (right as NSString).appendingPathComponent(it.rightPath ?? it.path) : (left as NSString).appendingPathComponent(it.path)
        }
        func make(_ a: Action, from onRight: Bool, _ job: ([Item]) -> FileJob) -> FileJob? {
            let xs = items.filter { $0.action == a }
            guard !xs.isEmpty else { return nil }
            let j = job(xs)
            for it in xs {   // updateValue: a nil (absent) must stay in
                j.expected.updateValue(onRight ? it.right : it.left, forKey: full(it, onRight: onRight))
                j.expectedTarget.updateValue(onRight ? it.left : it.right, forKey: full(it, onRight: !onRight))
            }
            return j
        }
        var out: [(job: FileJob, label: String)] = []
        for (a, onRight, side) in [(Action.trashRight, true, "right"), (.trashLeft, false, "left")] {
            let e = onRight ? sides.right : sides.left
            if let j = make(a, from: onRight, { xs in
                let paths = xs.map { full($0, onRight: onRight) }
                guard e != .local else { return FileJob(.trash, sources: paths) }   // the Trash: nothing lost
                let job = FileJob(.delete, sources: paths, from: e, to: e, destDir: nil, sshEnv: env)
                job.comparedAt = comparedAt
                return job
            }) {
                out.append((j, "Sync: \(j.sources.count) only on the \(side) → " + (e == .local ? "Trash" : "deleted (\(place(e, onRight ? right : left)))")))
            }
        }
        for (a, onRight, arrow) in [(Action.toRight, false, "→"), (.toLeft, true, "←")] {
            let (from, to) = onRight ? (sides.right, sides.left) : (sides.left, sides.right)
            if let j = make(a, from: onRight, { xs in
                FileJob(copyPairs: xs.map { (full($0, onRight: onRight), full($0, onRight: !onRight)) }, from: from, to: to, sshEnv: env)
            }) {
                out.append((j, "Sync \(arrow) \(place(to, onRight ? left : right)) (\(j.sources.count))"))
            }
        }
        return out
    }

    /// "~/Projects" here, "host:/srv/app" on a server.
    public static func place(_ e: Endpoint, _ path: String) -> String {
        if case .sftp(let t) = e { "\(t.host):\(path)" } else { (path as NSString).abbreviatingWithTildeInPath }
    }

    /// What a row can be set to: copy from a side that has it, trash a side-only item, or skip.
    public static func choices(_ it: Item) -> [Action] {
        if it.action == .equal { return [.equal] }
        if it.unreadable != nil { return [.skip] }
        return (it.left != nil ? [.toRight] : []) + (it.right != nil ? [.toLeft] : [])
            + (it.right == nil ? [.trashLeft] : []) + (it.left == nil ? [.trashRight] : []) + [.skip]
    }

    /// Cancelled, it stops at the next 1 MB: false, never "equal" unread. Both read into the same two buffers.
    public static func filesEqual(_ a: String, _ b: String, isCancelled: () -> Bool = { false }) -> Bool {
        let fa = open(a, O_RDONLY | O_CLOEXEC), fb = open(b, O_RDONLY | O_CLOEXEC)
        defer { if fa >= 0 { close(fa) }; if fb >= 0 { close(fb) } }
        guard fa >= 0, fb >= 0 else { return false }
        let size = 1 << 20
        let x = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16), y = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { x.deallocate(); y.deallocate() }
        while !isCancelled() {
            // A read that fails isn't the end: two files that can't be read aren't the same.
            let n = fill(fa, x, size), m = fill(fb, y, size)
            guard n >= 0, n == m else { return false }
            if n == 0 { return true }
            if memcmp(x, y, n) != 0 { return false }
        }
        return false
    }

    /// Reads until `count` bytes or the end of the file (a short read isn't the end); -1: an error.
    private static func fill(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var got = 0
        while got < count {
            let r = read(fd, p + got, count - got)
            if r < 0 { if errno == EINTR { continue }; return -1 }
            if r == 0 { break }
            got += r
        }
        return got
    }
}
