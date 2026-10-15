import Foundation
import UniformTypeIdentifiers

/// Viewer helpers: decoding, hex dumps, readable plist/JSON, log-line highlighting.
public enum TextFormat {
    /// UTF-8 first (tolerating a character cut at chunk edges), then UTF-8 with a few bad bytes shown as U+FFFD
    /// (see `mostlyUTF8`), then Windows-1251, then lossy UTF-8.
    public static func decode(_ data: Data) -> (text: String, encoding: String) {
        for trimStart in 0...3 {
            for trimEnd in 0...3 where data.count > trimStart + trimEnd {
                if let s = String(data: data.dropFirst(trimStart).dropLast(trimEnd), encoding: .utf8) { return (s, "UTF-8") }
            }
        }
        if data.isEmpty { return ("", "UTF-8") }
        if !mostlyUTF8(data), let s = String(data: data, encoding: .windowsCP1251) { return (s, "Windows-1251") }
        return (String(decoding: data, as: UTF8.self), "UTF-8 (lossy)")
    }

    /// UTF-8 with some damage (a cut or corrupted byte) rather than another encoding: more bytes in well-formed
    /// multi-byte characters than in malformed ones. Windows-1251 text only now and then forms a valid UTF-8 pair,
    /// and ASCII with a stray high byte has no multi-byte characters at all.
    public static func mostlyUTF8(_ data: Data) -> Bool {
        data.withUnsafeBytes { b in
            var it = b.makeIterator(), parser = Unicode.UTF8.ForwardParser(), multi = 0, bad = 0
            while true {
                switch parser.parseScalar(from: &it) {
                case .valid(let c): if c.count > 1 { multi += c.count }
                case .error(let n): bad += n
                case .emptyInput: return multi > bad
                }
            }
        }
    }

    /// Binary rather than text: over 1 in 20 of the first 8 KB are NULs or control bytes other than tab, newlines,
    /// form feed, backspace and ESC (colored logs). A leading run of NULs doesn't count — a log copied and truncated
    /// under a writer without O_APPEND (logrotate's copytruncate) starts with a hole up to where the writer was (real
    /// NULs once fetched from a server) — up to `nulRunLimit`: more NULs than that (a disk image, a preallocated or
    /// all-NUL file) is binary after a quick scan, not one of gigabytes. The viewer skips a sparse hole of any size
    /// before asking (SEEK_DATA).
    public static func looksBinary(_ data: Data) -> Bool {
        let lead = data.withUnsafeBytes { b in
            zeros.withUnsafeBytes { z -> Int? in
                var i = 0
                while i < min(b.count, nulRunLimit) {
                    let n = min(z.count, b.count - i)
                    if memcmp(b.baseAddress! + i, z.baseAddress!, n) != 0 { return b[i..<i + n].firstIndex { $0 != 0 } }
                    i += n
                }
                return nil
            }
        }
        guard let lead else { return !data.isEmpty }   // all NULs: binary
        let sample = data.dropFirst(lead).prefix(8192)
        let control = sample.reduce(0) { n, b in n + ((b < 0x20 && ![8, 9, 10, 11, 12, 13, 27].contains(b)) || b == 0x7f ? 1 : 0) }
        return control * 20 > sample.count
    }

    /// Quick Look previews it by its name: macOS knows the extension as text, an image, PDF, audio or video, an
    /// archive or a property list. `.conf`, `.env`, `.bak`, `syslog.1` or no extension at all it doesn't know (a
    /// made-up type), and `server.key` / `id_rsa.pub` it takes for a Keynote or Publisher file: an icon only.
    public static func quickLookShows(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let t = UTType(filenameExtension: ext) else { return false }
        return [UTType.text, .image, .pdf, .audiovisualContent, .archive, .propertyList, .message, .threeDContent].contains { t.conforms(to: $0) }
    }

    /// `data` without a UTF-8 character cut at its end (a lead byte whose continuation bytes didn't fit).
    static func utf8Whole(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        for back in 1...min(3, data.count) {
            let b = data[data.endIndex - back]
            guard b & 0xC0 == 0x80 else {   // not a continuation byte: a lead (or ASCII) — whole if its length fits
                let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
                return need > back ? data.dropLast(back) : data
            }
        }
        return data
    }

    /// How much of a file's start `previewsAsText` looks at.
    public static let previewSniff = 64 << 10

    /// Text the panel previews itself, where Quick Look would show an icon: a name it doesn't know, and a start
    /// (`previewSniff`) that doesn't look binary — what F3 would show as text. UTF-16 reads as binary there too.
    public static func previewsAsText(_ name: String, head: Data) -> Bool {
        !quickLookShows(name) && !looksBinary(head.prefix(previewSniff))
    }

    /// A copy of `src` in `dir` named `<name>.txt`, so Quick Look shows it as text: a clone where the volume allows
    /// (no bytes copied), else its first `limit` bytes — named `<name> (first 4 MB).txt` when that cuts it, never inside
    /// a UTF-8 character. Read by the owner only: a server's `.env` or key may be in it, and an app Quick Look opens it
    /// in mustn't save into a copy that's thrown away.
    public static func textCopy(of src: String, in dir: String, limit: Int = 4 << 20) throws -> String {
        let name = (src as NSString).lastPathComponent
        var dst = (dir as NSString).appendingPathComponent(name + ".txt")
        if clonefile(src, dst, 0) == 0 {
            chmod(dst, 0o400)
            return dst
        }
        guard let h = FileHandle(forReadingAtPath: src) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? h.close() }
        var head = try h.read(upToCount: limit + 1) ?? Data()
        if head.count > limit {
            dst = (dir as NSString).appendingPathComponent("\(name) (first \(limit >> 20) MB).txt")
            head = utf8Whole(head.prefix(limit))
        }
        guard FileManager.default.createFile(atPath: dst, contents: head, attributes: [.posixPermissions: 0o400])
        else { throw POSIXError(.EIO) }
        return dst
    }

    public static let nulRunLimit = 256 << 20
    private static let zeros = [UInt8](repeating: 0, count: 64 << 10)

    /// `00000010  48 65 6c 6c 6f …  |Hello…|`, offsets starting at `base`.
    public static func hexDump(_ data: Data, base: Int = 0) -> String {
        let bytes = [UInt8](data)
        var out = ""
        out.reserveCapacity(bytes.count * 4 + bytes.count / 16 * 14)
        let hexDigits = Array("0123456789abcdef")
        for line in stride(from: 0, to: bytes.count, by: 16) {
            let row = bytes[line..<min(line + 16, bytes.count)]
            out += String(format: "%08llx  ", Int64(base + line))   // 64-bit: a tail of a 5 GB log starts past 32 bits
            for (i, b) in row.enumerated() {
                out.append(hexDigits[Int(b >> 4)])
                out.append(hexDigits[Int(b & 0xf)])
                out += i == 7 ? "  " : " "
            }
            out += String(repeating: " ", count: (16 - row.count) * 3 + (row.count < 8 ? 1 : 0))
            out += " |" + String(row.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." }) + "|\n"
        }
        return out
    }

    /// Any property list (binary, XML, OpenStep) as readable XML; nil if it isn't one.
    public static func prettyPlist(_ data: Data) -> String? {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0) else { return nil }
        return String(data: xml, encoding: .utf8)
    }

    /// Indented JSON with sorted keys; nil if it isn't valid JSON.
    public static func prettyJSON(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(data: out, encoding: .utf8)
    }

    public enum Level: Sendable { case error, warning }

    private static let errorLine = try! NSRegularExpression(
        pattern: "^.*\\b(error|err|fatal|fail|failed|failure|panic|exception|critical|crit|denied)\\b.*$",
        options: [.caseInsensitive, .anchorsMatchLines])
    private static let warningLine = try! NSRegularExpression(
        pattern: "^.*\\b(warn|warning|deprecated)\\b.*$", options: [.caseInsensitive, .anchorsMatchLines])

    /// What one line looks like: an error, a warning (an error wins), or neither.
    public static func level<S: StringProtocol>(of line: S) -> Level? {
        let s = String(line), all = NSRange(s.startIndex..., in: s)
        return errorLine.firstMatch(in: s, range: all) != nil ? .error : warningLine.firstMatch(in: s, range: all) != nil ? .warning : nil
    }

    /// Whole lines that look like errors or warnings (errors win when a line has both).
    public static func logLevels(in text: String) -> [(range: NSRange, level: Level)] {
        let all = NSRange(text.startIndex..., in: text)
        let errors = errorLine.matches(in: text, range: all).map { ($0.range, Level.error) }
        let errorStarts = Set(errors.map(\.0.location))
        let warnings = warningLine.matches(in: text, range: all).map(\.range)
            .filter { !errorStarts.contains($0.location) }.map { ($0, Level.warning) }
        return errors + warnings
    }
}

/// The viewer's & filter (less's &pattern): lines that contain `text`, case folded, or with `exclude` ("!text")
/// the ones that don't — and its `e`: only the lines that look like errors, or errors and warnings
/// (`TextFormat.level`, its colors aside). ponytail: plain text only; a "re:" regex like the panel filter's when one is missed.
public struct LineFilter: Sendable, Equatable {
    public let text: String, exclude: Bool
    /// `.error`: error lines only; `.warning`: errors and warnings; nil: any line.
    public var level: TextFormat.Level?

    /// "error": lines with it; "!error": lines without it; "" or "!" is no filter.
    public init?(_ spec: String) {
        exclude = spec.hasPrefix("!")
        text = exclude ? String(spec.dropFirst()) : spec
        if text.isEmpty { return nil }
    }

    /// Lines by their level alone.
    public init(level: TextFormat.Level) { (text, exclude, self.level) = ("", false, level) }

    public var spec: String { (exclude ? "!" : "") + text }

    /// By the line as the viewer shows it: terminal colors' codes aside.
    public func keeps(_ line: Substring) -> Bool {
        let shown = ANSI.strip(line)
        return (text.isEmpty || (shown.range(of: text, options: .caseInsensitive) != nil) != exclude) && keepsLevel(shown)
    }

    func keepsLevel(_ shown: String) -> Bool {
        guard let level else { return true }
        let l = TextFormat.level(of: shown)
        return level == .warning ? l != nil : l == .error
    }

    /// The kept lines of `rest` + `text`; what comes after the last "\n" (a line still being written) is left in
    /// `rest` for the next piece (follow).
    public func apply(_ text: String, rest: inout String) -> String {
        // "\r\n" is one Character: split on it too (a CRLF file would be one line). Kept lines end in "\n".
        var lines = (rest + text).split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        rest = String(lines.removeLast())
        return lines.filter(keeps).map { $0 + "\n" }.joined()
    }

    /// The kept lines of a whole text, its last line too.
    public func apply(_ text: String) -> String {
        var rest = ""
        let kept = apply(text, rest: &rest)
        return kept + (!rest.isEmpty && keeps(Substring(rest)) ? rest : "")
    }

    /// The kept lines of a memory-mapped file, at most `limit` bytes of them (`more`: it stopped there). Case is
    /// folded like the viewer's whole-file find (`BigFile.foldCase`), in UTF-8 and single-byte text.
    public func apply(_ d: Data, limit: Int) -> (Data, more: Bool) {
        var needle = Array(text.utf8), out = Data(), line = [UInt8]()
        needle.withUnsafeMutableBytes(BigFile.foldCase)
        let more = d.withUnsafeBytes { b -> Bool in
            guard let base = b.baseAddress else { return false }
            var pos = 0
            while pos < b.count {
                let end = memchr(base + pos, 10, b.count - pos).map { base.distance(to: UnsafeRawPointer($0)) + 1 } ?? b.count
                line.removeAll(keepingCapacity: true)
                line.append(contentsOf: UnsafeRawBufferPointer(rebasing: b[pos..<end]))
                // A line with terminal colors, or a level to look at, goes by its text as shown (decoded: slower, rarer).
                let shown = level != nil || line.contains(0x1B) ? ANSI.strip(String(decoding: line, as: UTF8.self)) : nil
                let hit = shown.map { text.isEmpty || $0.range(of: text, options: .caseInsensitive) != nil } ?? line.withUnsafeMutableBytes { l in
                    BigFile.foldCase(l)
                    return needle.isEmpty || memmem(l.baseAddress, l.count, needle, needle.count) != nil
                }
                if hit != exclude, shown.map(keepsLevel) ?? true {
                    // ponytail: `e` decodes each line for its regex — seconds on a GB log, only while it's on
                    if out.count + end - pos > limit { return true }
                    out.append(contentsOf: UnsafeRawBufferPointer(rebasing: b[pos..<end]))
                }
                pos = end
            }
            return false
        }
        return (out, more)
    }

    /// `apply` over the mapped file, through its descriptor, within what's mapped (see `BigFile.Mapped`: a mapping
    /// scanned while the log is truncated is SIGBUS, and its name may hold another file by now).
    public func apply(_ file: BigFile.Mapped, limit: Int, chunk: Int = 4 << 20) -> (Data, more: Bool) {
        apply(fd: file.fd, end: file.data.count, limit: limit, chunk: chunk)
    }

    /// The same over the file at `path`, to its end.
    public func apply(fileAt path: String, limit: Int, chunk: Int = 4 << 20) -> (Data, more: Bool) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return (Data(), false) }
        defer { close(fd) }
        return apply(fd: fd, end: .max, limit: limit, chunk: chunk)
    }

    /// Read in pieces cut at line ends. A line still going is grown in place, not copied again with every piece (a
    /// minified JSON is one line).
    func apply(fd: Int32, end: Int, limit: Int, chunk: Int) -> (Data, more: Bool) {
        var out = Data(), line = Data(), pos = 0
        while pos < end {
            let d = BigFile.read(fd, at: pos, count: min(chunk, end - pos))
            if d.isEmpty { break }   // the file is shorter now
            pos += d.count
            let from = line.count
            line.append(d)
            guard let nl = line[from...].lastIndex(of: 10) else { continue }
            let (kept, more) = apply(Data(line[...nl]), limit: limit - out.count)
            out.append(kept)
            if more { return (out, true) }
            line = Data(line[(nl + 1)...])
        }
        let (kept, more) = apply(line, limit: limit - out.count)
        out.append(kept)
        return (out, more)
    }
}
