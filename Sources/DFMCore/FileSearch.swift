import Foundation

public struct SearchQuery: Sendable {
    public var root: String
    public var name: String = ""          // Mask(filter:) semantics: text, *.glob or re:regex; empty = any
    public var contains: String = ""      // empty = don't look inside files
    public var caseSensitive = false      // content only; see BigFile.foldCase for what case-insensitive folds
    public var includeHidden = false
    public var spotlight = false          // use the Spotlight index (fast; skips what Spotlight doesn't index)
    public var tag = ""                   // Finder tag name (case-insensitive); empty = any

    public init(root: String) { self.root = root }
}

/// Recursive find. Results are FileItems whose `name` is the path relative to `root`,
/// so a panel can show and operate on them as if they were in one folder.
public enum FileSearch {
    /// - Returns: how many files a content search skipped because they aren't downloaded (iCloud / Dropbox
    ///   placeholders: reading one would download it).
    @discardableResult
    public static func run(_ q: SearchQuery, isCancelled: () -> Bool, onMatch: (FileItem) -> Void) -> Int {
        let mask = q.name.isEmpty ? nil : Mask(filter: q.name)
        let needle = Array(q.contains.utf8)
        var skipped = 0
        func matches(_ item: FileItem, _ full: String) -> Bool {
            guard q.includeHidden || !item.isHidden else { return false }
            if let mask, !mask.matches(item.name) { return false }
            if !q.tag.isEmpty, !FinderTags.read(full).contains(where: { $0.name.caseInsensitiveCompare(q.tag) == .orderedSame }) { return false }
            if !needle.isEmpty {
                guard item.kind == .file else { return false }
                guard let found = contentMatch(item, full, needle, caseSensitive: q.caseSensitive, isCancelled: isCancelled) else { skipped += 1; return false }
                return found
            }
            return true
        }
        let root = q.root == "/" ? "" : q.root
        if q.spotlight {
            spotlight(q, isCancelled: isCancelled) { full in
                guard full.hasPrefix(root + "/"), let item = lstatItem(full) else { return }
                let rel = String(full.dropFirst(root.count + 1))
                if matches(item, full), q.includeHidden || !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                    onMatch(item.renamed(rel))
                }
            }
            return skipped
        }
        var rootStat = stat()
        guard lstat(q.root, &rootStat) == 0 else { return skipped }
        func walk(_ dir: String, _ rel: String) {
            for item in (try? DirLister.list(dir.isEmpty ? "/" : dir)) ?? [] {
                if isCancelled() { return }
                let full = dir + "/" + item.name
                let relName = rel.isEmpty ? item.name : rel + "/" + item.name
                if matches(item, full) { onMatch(item.renamed(relName)) }
                if item.kind == .dir && (q.includeHidden || !item.isHidden) {
                    var s = stat()
                    if lstat(full, &s) == 0 && s.st_dev == rootStat.st_dev { walk(full, relName) }
                }
            }
        }
        walk(root, "")
        return skipped
    }

    /// Whether file `item` at `path` holds `needle`; nil for a placeholder (iCloud / Dropbox), which reading would
    /// download whole, so it isn't searched.
    static func contentMatch(_ item: FileItem, _ path: String, _ needle: [UInt8], caseSensitive: Bool, isCancelled: () -> Bool = { false }) -> Bool? {
        item.isDataless ? nil : fileContains(path, needle, caseSensitive: caseSensitive, isCancelled: isCancelled)
    }

    /// Streams the file in 1 MB chunks (overlapping by needle length − 1, so matches across chunk edges count).
    /// Cancelled, it stops at the next chunk: false.
    public static func fileContains(_ path: String, _ needle: [UInt8], caseSensitive: Bool, isCancelled: () -> Bool = { false }) -> Bool {
        guard !needle.isEmpty, let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        var n = needle
        if !caseSensitive { n.withUnsafeMutableBytes(BigFile.foldCase) }
        var carry: [UInt8] = []
        while !isCancelled(), let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty {
            var buf = carry + chunk
            if !caseSensitive { buf.withUnsafeMutableBytes(BigFile.foldCase) }
            let found = buf.withUnsafeBytes { b in n.withUnsafeBytes { m in memmem(b.baseAddress, b.count, m.baseAddress, m.count) != nil } }
            if found { return true }
            carry = Array(buf.suffix(n.count - 1))
        }
        return false
    }

    /// mdfind's paths as they come; stops it once `isCancelled` (looked at every 0.1 s while it says nothing).
    private static func spotlight(_ q: SearchQuery, isCancelled: () -> Bool, each: (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        var args = ["-onlyin", q.root]
        if !q.contains.isEmpty {
            args.append(q.contains)
        } else if !q.tag.isEmpty {
            let t = q.tag.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            args.append("kMDItemUserTags == \"\(t)\"cd")
        } else {
            // mdfind -name wants plain text; the Mask filter afterwards applies the real pattern.
            let plain = q.name.replacingOccurrences(of: "re:", with: "").filter { !"*?[]^$\\()|+{}".contains($0) }
            // '*' alone finds nothing on macOS 27; '**' is every name.
            args += plain.isEmpty ? ["kMDItemFSName == '**'"] : ["-name", plain]
        }
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        try? out.fileHandleForWriting.close()   // our copy: else EOF never comes
        defer {
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
        }
        let fd = out.fileHandleForReading.fileDescriptor
        var pending = Data(), buf = [UInt8](repeating: 0, count: 1 << 16)
        while !isCancelled() {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 100) == 0 { continue }
            let n = read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            pending.append(contentsOf: buf[0..<n])
            guard let end = pending.lastIndex(of: 10) else { continue }
            for line in pending[..<end].split(separator: 10) where !isCancelled() { each(String(decoding: line, as: UTF8.self)) }
            pending = Data(pending[(end + 1)...])
        }
    }

    // MARK: - On a server: find and grep run there (GNU find, for -printf)

    /// The search as a command line for the server's shell, run in `q.root`: a "type size mtime ./path" record,
    /// NUL-ended, for each entry below (with `contains`, each file holding it: grep -l, then one find per batch of
    /// hits for their details). Hidden folders are pruned there; the name mask is applied here (Mask isn't find's
    /// -name). Tags and Spotlight are this Mac's.
    /// ponytail: every name crosses the wire and grep reads files the mask drops; send plain globs as -iname if big trees get slow.
    public static func remoteCommand(_ q: SearchQuery) -> String {
        let find = "find . -xdev -mindepth 1 " + (q.includeHidden ? "" : "-name '.*' -prune -o ")
        guard !q.contains.isEmpty else { return find + #"-printf '%y %m %s %T@ %p\0'"# }
        return find + "-type f -exec grep -lZ\(q.caseSensitive ? "" : "i")F -e \(ShellContext.quote(q.contains)) -- {} + | "
            + #"xargs -0r sh -c 'exec find "$@" -prune -printf "%y %m %s %T@ %p\0"' sh"#
    }

    /// `run` on a server, hits as they come, named by their path below the root. Throws what the server said when
    /// the search failed outright (no GNU find there, the folder gone); unreadable folders on the way are skipped.
    public static func runRemote(_ q: SearchQuery, on t: SFTPTarget, env: [String: String] = [:], cancel: CancelFlag? = nil,
                                 onMatch: (FileItem) -> Void) throws {
        let mask = q.name.isEmpty ? nil : Mask(filter: q.name)
        var pending = Data(), found = false
        let (status, errors) = try SSHCommand.run(t, SSHCommand.inDir(q.root, remoteCommand(q)), env: env, cancel: cancel) { data in
            pending += data
            guard let end = pending.lastIndex(of: 0) else { return }
            for record in String(decoding: pending[..<end], as: UTF8.self).split(separator: "\0") {
                guard let item = remoteItem(record), mask?.matches((item.name as NSString).lastPathComponent) ?? true else { continue }
                found = true
                onMatch(item)
            }
            pending = Data(pending[(end + 1)...])
        }
        let why = errors.split(separator: "\n").filter { !$0.hasSuffix("Permission denied") }.joined(separator: "\n")
        if status != 0 && !found && !why.isEmpty { throw SFTPError(message: why) }
    }

    /// "f 644 120 1696767890.5 ./a/b.txt" (find's %y %m %s %T@ %p) → an item named "a/b.txt", its permissions too.
    static func remoteItem(_ record: Substring) -> FileItem? {
        let f = record.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard f.count == 5, f[4].hasPrefix("./"), f[4].count > 2 else { return nil }
        let kind: FileItem.Kind = switch f[0] { case "f": .file; case "d": .dir; case "l": .link; default: .other }
        return FileItem(name: String(f[4].dropFirst(2)), kind: kind, size: kind == .dir ? 0 : Int64(f[2]) ?? 0, mtime: Double(f[3]) ?? 0,
                        mode: (SFTP.special[String(f[0])].map(UInt32.init) ?? 0) | (UInt32(f[1], radix: 8) ?? 0), flags: 0)
    }

    static func lstatItem(_ path: String) -> FileItem? {
        var s = stat()
        guard lstat(path, &s) == 0 else { return nil }
        let kind: FileItem.Kind = switch s.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .dir
        case S_IFLNK: .link
        default: .other
        }
        return FileItem(name: (path as NSString).lastPathComponent, kind: kind, size: kind == .dir ? 0 : Int64(s.st_size),
                        mtime: Double(s.st_mtimespec.tv_sec), mode: UInt32(s.st_mode), flags: s.st_flags, uid: s.st_uid, gid: s.st_gid)
    }
}

extension FileItem {
    func renamed(_ name: String) -> FileItem {
        var it = FileItem(name: name, kind: kind, size: size, mtime: mtime, mode: mode, flags: flags, label: label, uid: uid, gid: gid)
        it.linkDir = linkDir
        return it
    }
}

/// Thread-safe "stop" flag shared between the UI and a background worker.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (@Sendable () -> Void)?
    public init() {}
    public func cancel() {
        let h = lock.withLock { () -> (@Sendable () -> Void)? in
            cancelled = true
            defer { handler = nil }
            return handler
        }
        h?()
    }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    /// Runs `handler` on cancel (right away if already cancelled), replacing the previous one; nil removes it.
    /// Returns the one replaced: a step that hooks in for a while puts it back (`onCancel(previous)`), so the
    /// caller's own handler (a job closing its connections) still runs on a later cancel.
    @discardableResult
    public func onCancel(_ handler: (@Sendable () -> Void)?) -> (@Sendable () -> Void)? {
        let (now, previous) = lock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
            defer { if !cancelled { self.handler = handler } }
            return (cancelled, self.handler)
        }
        if now { handler?() }
        return previous
    }
}
