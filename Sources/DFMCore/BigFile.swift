import Foundation

/// Byte-level helpers for viewing files too big to load whole (multi-GB logs). They work on memory-mapped
/// Data and "\n" line boundaries, so they behave the same for UTF-8 and single-byte encodings.
public enum BigFile {
    /// Start of the line containing `offset`. Looks back at most `limit` bytes, so a giant line is cut there.
    public static func lineStart(_ d: Data, at offset: Int, limit: Int = 1 << 20) -> Int {
        d.withUnsafeBytes { b in
            var i = min(max(offset, 0), b.count)
            let stop = max(0, i - limit)
            while i > stop && b[i - 1] != 10 { i -= 1 }
            return i == stop && stop > 0 ? min(max(offset, 0), b.count) : i
        }
    }

    /// Start of the line after the one containing `offset` (or the end of the data).
    public static func nextLine(_ d: Data, after offset: Int) -> Int {
        d.withUnsafeBytes { b in
            guard offset >= 0, offset < b.count, let base = b.baseAddress else { return b.count }
            guard let p = memchr(base + offset, 10, b.count - offset) else { return b.count }
            return base.distance(to: UnsafeRawPointer(p)) + 1
        }
    }

    /// A line-aligned slice of about `size` bytes with `offset` in its middle (clamped to the data). Inside a line
    /// longer than a quarter of it (minified JSON) it starts mid-line, and it ends mid-line rather than more than an
    /// eighth early, so `offset` is always well inside and sliding moves on; a cut never splits a UTF-8 character.
    public static func window(_ d: Data, around offset: Int, size: Int) -> Range<Int> {
        // Near the end: always through the last byte. Cutting back to a line start there left the last lines
        // out of every window, so End and scrolling never reached them.
        if offset + size / 2 >= d.count { return charStart(d, lineStart(d, at: max(0, d.count - size)))..<d.count }
        let start = charStart(d, lineStart(d, at: max(0, offset - size / 2), limit: size / 4))
        guard start + size < d.count else { return start..<d.count }
        return start..<charStart(d, lineStart(d, at: start + size, limit: size / 8))
    }

    /// `i` moved back off UTF-8 continuation bytes (at most 3) to where its character starts.
    private static func charStart(_ d: Data, _ i: Int) -> Int {
        d.withUnsafeBytes { b in
            var j = i
            while j > max(0, i - 3), j < b.count, b[j] & 0xc0 == 0x80, b[j - 1] != 10 { j -= 1 }
            return j
        }
    }

    /// Number of "\n" bytes in `r`.
    public static func newlines(_ d: Data, _ r: Range<Int>) -> Int {
        var n = 0, i = r.lowerBound
        while i < r.upperBound {
            let next = nextLine(d, after: i)
            if next > r.upperBound || (next == d.count && (d.isEmpty || d[d.count - 1] != 10)) { break }
            n += 1
            i = next
        }
        return n
    }

    /// Offset where line `n` (0-based) starts, counting from `start` (which must be a line start).
    public static func lineOffset(_ d: Data, from start: Int, line n: Int) -> Int {
        var i = start
        for _ in 0..<n where i < d.count { i = nextLine(d, after: i) }
        return i
    }

    /// First occurrence of `needle` at or after `from`. Without `caseSensitive`, case is folded (see `foldCase`).
    public static func find(_ needle: [UInt8], in d: Data, from: Int, caseSensitive: Bool, chunk: Int = 4 << 20) -> Int? {
        guard !needle.isEmpty, from >= 0 else { return nil }
        var n = needle
        if !caseSensitive { n.withUnsafeMutableBytes(foldCase) }
        return d.withUnsafeBytes { b -> Int? in
            guard let base = b.baseAddress else { return nil }
            var buf = [UInt8](repeating: 0, count: chunk + n.count)
            var pos = from
            while pos + n.count <= b.count {
                let len = min(chunk + n.count - 1, b.count - pos)   // overlap so matches across chunks count
                let hit: Int? = caseSensitive
                    ? memmem(base + pos, len, n, n.count).map { base.distance(to: UnsafeRawPointer($0)) }
                    : buf.withUnsafeMutableBytes { m -> Int? in
                        let w = UnsafeMutableRawBufferPointer(rebasing: m[0..<len])
                        w.copyMemory(from: UnsafeRawBufferPointer(rebasing: b[pos..<pos + len]))
                        foldCase(w)
                        return memmem(m.baseAddress!, len, n, n.count).map { pos + m.baseAddress!.distance(to: $0) }
                    }
                if let hit { return hit }
                pos += chunk
            }
            return nil
        }
    }

    /// A file mapped, and kept open: a scan of seconds reads it through the descriptor instead — a truncate meanwhile
    /// (copytruncate) turns the mapping's lost pages into SIGBUS, a read just gets less — and sees the very file the
    /// mapping shows, not whatever its name holds now (logrotate), nor what was appended after.
    public final class Mapped: @unchecked Sendable {
        public let data: Data
        let fd: Int32
        init(_ data: Data, _ fd: Int32) { self.data = data; self.fd = fd }
        deinit { close(fd) }
    }

    public static func map(_ path: String) -> Mapped? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0 else { close(fd); return nil }
        guard st.st_size > 0 else { return Mapped(Data(), fd) }
        let size = Int(st.st_size)
        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { close(fd); return nil }
        return Mapped(Data(bytesNoCopy: p, count: size, deallocator: .unmap), fd)
    }

    /// `find` over the mapped file, through its descriptor (see `Mapped`), within what's mapped. A file cut short
    /// meanwhile is searched to where it ends now.
    public static func find(_ needle: [UInt8], in file: Mapped, from: Int, caseSensitive: Bool, chunk: Int = 4 << 20) -> Int? {
        find(needle, fd: file.fd, from: from, end: file.data.count, caseSensitive: caseSensitive, chunk: chunk)
    }

    /// The same over the file at `path`, to its end.
    public static func find(_ needle: [UInt8], inFile path: String, from: Int, caseSensitive: Bool, chunk: Int = 4 << 20) -> Int? {
        guard !needle.isEmpty, from >= 0 else { return nil }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return find(needle, fd: fd, from: from, end: .max, caseSensitive: caseSensitive, chunk: chunk)
    }

    static func find(_ needle: [UInt8], fd: Int32, from: Int, end: Int, caseSensitive: Bool, chunk: Int) -> Int? {
        guard !needle.isEmpty, from >= 0 else { return nil }
        var pos = from
        while pos + needle.count <= end {
            let want = min(chunk + needle.count - 1, end - pos)   // overlap so matches across pieces count
            let d = read(fd, at: pos, count: want)
            if let hit = find(needle, in: d, from: 0, caseSensitive: caseSensitive, chunk: max(d.count, 1)) { return pos + hit }
            guard d.count == want else { return nil }   // the end: the file is shorter now
            pos += chunk
        }
        return nil
    }

    /// Up to `count` bytes of `fd` at `offset`: fewer only at the end (a short read is no end), none on an error.
    static func read(_ fd: Int32, at offset: Int, count: Int) -> Data {
        var d = Data(count: count), got = 0
        d.withUnsafeMutableBytes { b in
            while got < count {
                let n = Darwin.pread(fd, b.baseAddress! + got, count - got, off_t(offset + got))
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                got += n
            }
        }
        return d.prefix(got)
    }

    /// "50%", "1.5G", "200m", "4096", "end" → a byte offset within `size`; nil if it isn't one of those.
    public static func position(_ input: String, size: Int) -> Int? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "end" || s == "$" { return size }
        if s.hasSuffix("%"), let p = Double(s.dropLast()), (0...100).contains(p) { return Int(Double(size) * p / 100) }
        let units: [Character: Double] = ["k": 0x1p10, "m": 0x1p20, "g": 0x1p30, "t": 0x1p40]
        let (num, mult) = s.last.flatMap { units[$0] }.map { (s.dropLast(), $0) } ?? (Substring(s), 1)
        guard let v = Double(num), v >= 0 else { return nil }
        return Int(min(v * mult, Double(size)))   // clamp as Double: Int(1e300) or Int(inf) traps
    }

    /// Folds case in place without moving a byte: ASCII letters, and two-byte UTF-8 letters whose fold is two bytes
    /// too (Latin-1 and Latin Extended, Greek, Cyrillic, Armenian), so "ПОМИЛКА" reads as "помилка". Folding twice
    /// is folding once (a chunk's folded tail is carried into the next). ponytail: three-byte scripts (Georgian,
    /// fullwidth Latin) and folds that change length (ß / SS, İ) stay as they are; decode and compare if they matter.
    public static func foldCase(_ b: UnsafeMutableRawBufferPointer) {
        var i = 0
        while i < b.count {
            let c = b[i]
            if c >= 65 && c <= 90 {
                b[i] = c | 0x20
            } else if c >= 0xC2 && c <= 0xDF && i + 1 < b.count && b[i + 1] & 0xC0 == 0x80 {
                let f = fold2[Int(c & 0x1F) << 6 | Int(b[i + 1] & 0x3F)]
                b[i] = UInt8(0xC0 | f >> 6)
                b[i + 1] = UInt8(0x80 | f & 0x3F)
                i += 1
            }
            i += 1
        }
    }

    /// Code point (< 0x800) → its lowercase of uppercase (ς → Σ → σ), kept only if that is two bytes too.
    static let fold2: [UInt16] = (0..<0x800).map { cp in
        func one(_ s: String) -> Unicode.Scalar? { s.unicodeScalars.count == 1 ? s.unicodeScalars.first : nil }
        guard let s = Unicode.Scalar(UInt32(cp)) else { return UInt16(cp) }
        let candidates = [one(s.properties.uppercaseMapping).flatMap { one($0.properties.lowercaseMapping) }, one(s.properties.lowercaseMapping)]
        return candidates.compactMap { $0 }.first { (0x80..<0x800).contains($0.value) }.map { UInt16($0.value) } ?? UInt16(cp)
    }
}
