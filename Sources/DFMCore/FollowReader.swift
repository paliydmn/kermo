import Foundation

/// `tail -F` for the viewer's follow mode. Each poll returns what was appended since the last one, whole lines only,
/// so neither a line nor a UTF-8 character is cut between polls; a last line still without its "\n" after
/// `patience` polls comes out anyway (progress dots, a log ending without "\n"), cut only between characters. Keeps the file open and compares the name's
/// device/inode with it: a new file under the name is a rotation (the old file's rest is read first, then the new
/// one from its start), the same file getting shorter is a truncation. Poll from one thread at a time.
public final class FollowReader: @unchecked Sendable {
    public enum Event: Equatable { case data(Data), rotated, truncated }

    private let path: String
    private var fd: Int32
    private var dev: dev_t
    private var ino: ino_t
    public private(set) var offset: UInt64
    private var waited = 0   // polls an unfinished last line has waited for its "\n"
    private let patience = 3

    /// Follows `path` from byte `offset` (where what's already shown ends).
    public init?(path: String, from offset: UInt64) {
        var st = stat()
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        guard fstat(fd, &st) == 0 else { close(fd); return nil }
        (self.path, self.fd, dev, ino, self.offset) = (path, fd, st.st_dev, st.st_ino, offset)
    }
    deinit { close(fd) }

    /// What changed since the last poll; at most `max` bytes of each file per call (the rest comes next time).
    public func poll(max: Int = 8 << 20) -> [Event] {
        var st = stat()
        if stat(path, &st) == 0, st.st_dev != dev || st.st_ino != ino {   // a new file under the name (none yet: keep reading the old)
            let new = open(path, O_RDONLY | O_CLOEXEC)
            if new >= 0, fstat(new, &st) == 0 {
                let rest = read(max, wholeLines: false)
                var old = stat()
                if fstat(fd, &old) == 0, UInt64(old.st_size) > offset {   // more of the old file left: switch next time
                    close(new)
                    return Self.events(rest)
                }
                close(fd)
                (fd, dev, ino, offset) = (new, st.st_dev, st.st_ino, 0)
                return (rest.isEmpty ? [] : [.data(rest)]) + [.rotated] + Self.events(read(max, wholeLines: true))
            }
            if new >= 0 { close(new) }
        }
        guard fstat(fd, &st) == 0 else { return [] }
        var events: [Event] = []
        if UInt64(st.st_size) < offset {   // start over from (near) the beginning
            events.append(.truncated)
            offset = st.st_size > 1 << 20 ? UInt64(st.st_size) - (1 << 20) : 0
        }
        return events + Self.events(read(max, wholeLines: true))
    }

    private static func events(_ d: Data) -> [Event] { d.isEmpty ? [] : [.data(d)] }

    /// From `offset`, at most `max` bytes, and moves `offset` past them. With `wholeLines`, only through the last "\n";
    /// a line longer than `max` (or any read of `max` bytes) is cut at a UTF-8 character boundary.
    private func read(_ max: Int, wholeLines: Bool) -> Data {
        var st = stat()
        guard fstat(fd, &st) == 0, UInt64(st.st_size) > offset else { return Data() }
        let want = Int(min(UInt64(st.st_size) - offset, UInt64(max)))
        var d = Data(count: want)
        let n = d.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(offset)) }
        guard n > 0 else { return Data() }
        d.count = n
        if wholeLines {
            if let nl = d.lastIndex(of: 10) { d.count = nl + 1 }
            else if n < max, waited < patience { waited += 1; return Data() }   // an unfinished line: next time
            else { d.count = Self.utf8Boundary(d) }
        } else if n == max { d.count = Self.utf8Boundary(d) }   // the old file's rest in pieces: not inside a character
        waited = 0
        offset += UInt64(d.count)
        return d
    }

    /// Length of `d` without a UTF-8 character cut at its end.
    public static func utf8Boundary(_ d: Data) -> Int {
        var i = d.count
        while i > 0, d.count - i < 4, d[i - 1] & 0xC0 == 0x80 { i -= 1 }   // continuation bytes
        guard i > 0, d[i - 1] >= 0xC0 else { return d.count }              // ends on ASCII (or isn't UTF-8)
        let lead = d[i - 1], need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2
        return d.count - (i - 1) >= need ? d.count : i - 1
    }

    /// UTF-16 units to drop from the start of followed text longer than `limit`: down to about half of it, at a line start.
    /// (Half, so the cut, which re-lays out everything after it, comes rarely.)
    public static func trimCount(_ s: NSString, limit: Int) -> Int {
        guard s.length > limit else { return 0 }
        let from = s.length - limit / 2   // a "\n" at the very end doesn't count: that would drop everything
        let nl = s.range(of: "\n", range: NSRange(location: from, length: s.length - from - 1))
        return nl.location == NSNotFound ? s.rangeOfComposedCharacterSequence(at: from).location : nl.location + 1
    }
}
