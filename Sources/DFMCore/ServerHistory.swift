import Foundation

/// Versions of server files that a save replaced (⌘S in the editor, a save in another app, Revert), kept on this Mac in
/// a mirror of the server's paths: `<root>/<user@host[_port]>/<path there>/<name>@<YYYY-MM-DD_HH-MM-SS>`, so a panel
/// browses them as they are. The name has the save's time; the file, the date it had on the server. They hold whatever
/// the server's files do (`.env`, keys): folders 0700, files 0600, the root out of Time Machine and — named
/// `history.noindex` by the app — out of Spotlight.
public struct ServerHistory: Sendable {
    public let root: String
    public var perFile = 20                // versions of one file; the oldest go first
    public var total: Int64 = 200 << 20    // all of them together; the oldest go first
    public static let fileLimit: Int64 = 5 << 20   // a bigger file gets no version

    public struct Version: Equatable, Sendable {
        public let path: String
        public let date: Date   // when a save replaced it
        public let n: Int       // the 2nd, 3rd… version saved within that second
        public let size: Int64
    }

    public init(root: String) { self.root = root }

    /// The server's folder: its address, and "_2222" after it for a port other than 22.
    public func folder(_ t: SFTPTarget) -> String {
        root + "/" + Self.clean(t.host + (t.port.map { $0 == 22 ? "" : "_\($0)" } ?? ""))
    }

    /// One plain name out of what a server or an address says: no "/" or NUL in it, never "", "." or "..".
    static func clean(_ s: String) -> String {
        let c = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\0", with: "_")
        return ["", ".", ".."].contains(c) ? "_" : c
    }

    /// A server path's folders and name: "." and empty parts go, ".." goes up but never above the server's folder.
    static func parts(_ path: String) -> [String] {
        var out: [String] = []
        for p in path.split(separator: "/") {
            switch p {
            case ".": continue
            case "..": _ = out.popLast()
            default: out.append(clean(String(p)))
            }
        }
        return out
    }

    /// Where `path` on `t` keeps the version a save replaced at `date` (`n` > 1: the next ones in that second); nil
    /// for a path without a name ("/", "a/..").
    public func path(of t: SFTPTarget, _ path: String, at date: Date, n: Int = 1) -> String? {
        let parts = Self.parts(path)
        guard let name = parts.last else { return nil }
        return ([folder(t)] + parts.dropLast()).joined(separator: "/") + "/" + name + "@" + Self.stamp(date) + (n > 1 ? "-\(n)" : "")
    }

    /// A version's path back into the server's folder, the path there, and when it was saved; nil outside the root.
    public func origin(of version: String) -> (server: String, path: String, date: Date)? {
        guard version.hasPrefix(root + "/") else { return nil }
        let parts = version.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        guard parts.count > 1, let v = Self.parse(parts.last!) else { return nil }
        return (parts[0], "/" + (parts.dropFirst().dropLast() + [v.name]).joined(separator: "/"), v.date)
    }

    /// "nginx.conf@2026-10-12_03-00-00-2" → ("nginx.conf", that time, 2); nil for any other name.
    public static func parse(_ name: String) -> (name: String, date: Date, n: Int)? {
        guard let at = name.lastIndex(of: "@") else { return nil }
        var s = name[name.index(after: at)...]
        var n = 1
        if s.count > 19 {
            guard s[s.index(s.startIndex, offsetBy: 19)] == "-", let k = Int(s.dropFirst(20)), k > 1 else { return nil }
            n = k
            s = s.prefix(19)
        }
        let f = s.split(separator: "-", omittingEmptySubsequences: false).flatMap { $0.split(separator: "_", omittingEmptySubsequences: false) }
        guard s.count == 19, f.count == 6, f.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let date = Calendar.current.date(from: DateComponents(year: Int(f[0]), month: Int(f[1]), day: Int(f[2]),
                                                                    hour: Int(f[3]), minute: Int(f[4]), second: Int(f[5]))),
              stamp(date) == s else { return nil }
        return (String(name[..<at]), date, n)
    }

    /// This Mac's time: the folder is read by people.
    static func stamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d_%02d-%02d-%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// `path`'s versions on `t`, newest first.
    public func versions(of t: SFTPTarget, _ path: String) -> [Version] {
        guard let any = self.path(of: t, path, at: Date()) else { return [] }
        let dir = (any as NSString).deletingLastPathComponent, name = Self.parts(path).last!
        return Self.versions(in: dir).filter { Self.parse(($0.path as NSString).lastPathComponent)?.name == name }.sorted(by: Self.newer)
    }

    private static func newer(_ a: Version, _ b: Version) -> Bool { a.date != b.date ? a.date > b.date : a.n != b.n ? a.n > b.n : a.path > b.path }

    /// The versions in `dir` (`deep`: and below it).
    private static func versions(in dir: String, deep: Bool = false) -> [Version] {
        let fm = FileManager.default
        let names = (deep ? fm.subpaths(atPath: dir) : try? fm.contentsOfDirectory(atPath: dir)) ?? []
        return names.compactMap { sub in
            let p = dir + "/" + sub
            var st = stat()
            guard let v = parse((sub as NSString).lastPathComponent), lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
            return Version(path: p, date: v.date, n: v.n, size: Int64(st.st_size))
        }
    }

    /// Keeps `data`: what `path` on `t` held (`attrs`) before a save replaced it at `date`; nil `data`: the file was
    /// over `fileLimit`. Never throws — a version that can't be kept mustn't stop the save; returns why there's
    /// none, or nil once it's kept. Then the oldest go beyond `perFile` versions of the file and `total` bytes.
    @discardableResult
    public func keep(_ data: Data?, _ attrs: SFTPClient.Attrs, of t: SFTPTarget, _ path: String, at date: Date = Date()) -> String? {
        guard let data else { return "file over \(Self.fileLimit >> 20) MB" }
        guard let first = self.path(of: t, path, at: date) else { return "“\(path)” has no file name" }
        let dir = (first as NSString).deletingLastPathComponent
        // Can't happen with `parts`; a mistake there must not write outside the root.
        guard URL(fileURLWithPath: dir).standardized.path.hasPrefix(URL(fileURLWithPath: root).standardized.path + "/") else {
            return "“\(path)” leads outside the history folder"
        }
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch {
            return error.localizedDescription
        }
        // Every time, not only when the folder is new: one made by an older build or by hand would go to Time Machine.
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        var url = URL(fileURLWithPath: root)
        try? url.setResourceValues(v)
        var n = 1, file = first, fd: Int32 = -1
        while true {   // two saves within a second: the next number, never over the first
            fd = open(file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd < 0, errno == EEXIST, n < 1000 else { break }
            n += 1
            file = self.path(of: t, path, at: date, n: n)!
        }
        guard fd >= 0 else { return String(cString: strerror(errno)) }
        let written = data.withUnsafeBytes { b in
            var off = 0
            while off < b.count {
                let k = write(fd, b.baseAddress! + off, b.count - off)
                if k < 0 { if errno == EINTR { continue }; return errno }
                off += k
            }
            return Int32(0)
        }
        var times = [timeval(tv_sec: Int(attrs.mtime), tv_usec: 0), timeval(tv_sec: Int(attrs.mtime), tv_usec: 0)]
        futimes(fd, &times)
        close(fd)
        guard written == 0 else {
            unlink(file)
            return String(cString: strerror(written))
        }
        prune(dir: dir, name: Self.parts(path).last!)
        return nil
    }

    private func prune(dir: String, name: String) {
        let mine = Self.versions(in: dir).filter { Self.parse(($0.path as NSString).lastPathComponent)?.name == name }.sorted(by: Self.newer)
        for v in mine.dropFirst(perFile) { unlink(v.path) }
        // ponytail: walks the whole history on every save; an index file if it ever holds tens of thousands.
        let all = Self.versions(in: root, deep: true)
        var left = all.reduce(0) { $0 + $1.size }
        for v in all.sorted(by: Self.newer).reversed() where left > total {
            unlink(v.path)
            left -= v.size
        }
    }
}
