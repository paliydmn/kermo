import CArchive
import Foundation

/// Read-only view of an archive (zip, tar.*, 7z, rar, iso, cpio, xar…) as a folder tree, via the
/// system libarchive. Extracting and creating go through /usr/bin/tar (bsdtar, same library).
public struct ArchiveIndex: Sendable {
    public let file: String
    public let format: String
    private let tree: [String: [FileItem]]   // folder inside the archive ("" = root) → its children
    private let entryPrefix: String           // "./" or "/" if entries are stored that way (`tar -cf x.tar .`, `tar -P`)
    let charset: String?                      // zip names stored without the UTF-8 flag: "CP866" or "CP1251"; nil = UTF-8
    var repeated: Set<String> = []            // paths stored more than once (`tar -r`): the listing shows the last one

    private static let extensions: Set<String> = ["zip", "jar", "war", "ear", "apk", "ipa", "tar", "tgz", "tbz", "tbz2",
                                                  "txz", "tzst", "7z", "rar", "iso", "cpio", "xar"]

    public static func isArchive(_ name: String) -> Bool {
        let n = name.lowercased()
        return [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz4"].contains(where: n.hasSuffix)
            || extensions.contains((n as NSString).pathExtension)
    }

    /// Children of a folder inside the archive ("" = top level); nil if there is no such folder.
    public func list(_ inner: String) -> [FileItem]? { tree[inner] }

    public static func read(_ file: String) throws -> ArchiveIndex { try read(file, charset: nil) }

    private static func read(_ file: String, charset: String?) throws -> ArchiveIndex {
        guard let a = archive_read_new() else { throw ArchiveError("libarchive unavailable") }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        if let charset { archive_read_set_options(a, "zip:hdrcharset=" + charset) }
        guard archive_read_open_filename(a, file, 1 << 16) == ARCHIVE_OK else {
            throw ArchiveError(archive_error_string(a).map { String(cString: $0) } ?? "can't open archive")
        }
        var folders: [String: [String: FileItem]] = ["": [:]]
        var explicit = Set<String>(), repeated = Set<String>()
        var entryPrefix = ""
        var legacy: [UInt8] = []   // names that aren't UTF-8 (a Windows zip): their bytes, to tell the code page

        func add(_ path: String, _ item: FileItem, isExplicit: Bool) {
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty && !explicit.contains(parent) && folders[parent] == nil {
                // Many zips have no entries for folders; make them up from the file paths.
                add(parent, FileItem(name: (parent as NSString).lastPathComponent, kind: .dir, size: 0, mtime: item.mtime, mode: 0, flags: 0),
                    isExplicit: false)
            }
            if isExplicit || folders[parent]?[item.name] == nil { folders[parent, default: [:]][item.name] = item }
            if isExplicit && !explicit.insert(path).inserted { repeated.insert(path) }
            if item.kind == .dir { folders[path, default: [:]] = folders[path] ?? [:] }
        }

        var entry: OpaquePointer?
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { break }
            guard r >= ARCHIVE_WARN, let entry else {
                throw ArchiveError(archive_error_string(a).map { String(cString: $0) } ?? "corrupt archive")
            }
            if charset == nil, let p = archive_entry_pathname(entry) {
                let bytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: strlen(p)))
                if String(bytes: bytes, encoding: .utf8) == nil { legacy += bytes }
            }
            let raw = (archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)).map { String(cString: $0) } ?? ""
            if entryPrefix.isEmpty && (raw.hasPrefix("./") || raw.hasPrefix("/")) { entryPrefix = raw.hasPrefix("/") ? "/" : "./" }
            let path = Self.normalize(raw)
            if !path.isEmpty {
                let type = archive_entry_filetype(entry) & S_IFMT
                let kind: FileItem.Kind = type == S_IFDIR ? .dir : type == S_IFLNK ? .link : type == S_IFREG ? .file : .other
                add(path, FileItem(name: (path as NSString).lastPathComponent, kind: kind,
                                   size: kind == .dir ? 0 : archive_entry_size(entry),
                                   mtime: Double(archive_entry_mtime(entry)), mode: kind == .other ? UInt32(type) : 0, flags: 0), isExplicit: true)
            }
            archive_read_data_skip(a)
        }
        let format = archive_format_name(a).map { String(cString: $0) } ?? "archive"
        if !legacy.isEmpty && format.hasPrefix("ZIP") { return try read(file, charset: legacyCharset(legacy)) }
        return ArchiveIndex(file: file, format: format, tree: folders.mapValues { Array($0.values) }, entryPrefix: entryPrefix,
                            charset: charset, repeated: repeated)
    }

    /// Windows zips keep names in the DOS code page (CP866 for Cyrillic), some tools in CP1251: the one whose
    /// decoding reads more like Russian / Ukrainian (letter frequencies; box drawing, „ † ‰ or a capital mid-word
    /// count against it), CP866 on a tie. Both decode any bytes, so a wrong guess still lists and extracts, just garbled.
    /// ponytail: a one-letter-table guess; a 2–3 letter name can still go wrong (CP1251 "Єва", CP866 "юр").
    static func legacyCharset(_ bytes: [UInt8]) -> String {
        let cp866 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosRussian.rawValue)))
        func score(_ e: String.Encoding) -> Double {
            guard let s = String(bytes: bytes, encoding: e) else { return -.infinity }
            var total = 0.0, prevLower = false
            for c in s {
                let low = Character(c.lowercased())
                if c.isASCII { prevLower = false; continue }   // ".", "/", " ", digits: a word ends
                guard let f = letterFrequency[low] else { total -= 12; prevLower = false; continue }   // box drawing, „, Serbian Ђ…
                total += log(f / 1000)
                if c != low { total -= prevLower ? 6 : 1 }
                prevLower = c == low
            }
            return total
        }
        return score(.windowsCP1251) > score(cp866) ? "CP1251" : "CP866"
    }

    /// Per mille, Russian text plus Ukrainian і ї є ґ.
    private static let letterFrequency: [Character: Double] = [
        "о": 110, "е": 85, "а": 80, "и": 74, "н": 67, "т": 63, "с": 55, "р": 47, "в": 45, "л": 44, "к": 35, "м": 32,
        "д": 30, "п": 28, "у": 26, "я": 20, "ы": 19, "ь": 17, "г": 17, "з": 17, "б": 16, "ч": 14, "й": 12, "х": 10,
        "ж": 9, "ш": 7, "ю": 6, "ц": 5, "щ": 4, "э": 3, "ф": 3, "ъ": 0.4, "ё": 0.4, "і": 30, "ї": 6, "є": 4, "ґ": 0.5]

    /// "./a//b/" → "a/b"; drops "." and ".." parts and leading "/" so nothing points outside the archive.
    static func normalize(_ raw: String) -> String {
        raw.split(separator: "/").filter { $0 != "." && $0 != ".." }.joined(separator: "/")
    }

    // MARK: - Extracting

    /// bsdtar arguments that extract `names` (children of folder `inner`, all of it if empty) into `dest`,
    /// without the `inner/` prefix. bsdtar refuses absolute paths and ".." by default (a stored leading "/" is
    /// stripped on extraction, and counts as one component, like "./").
    public func extractArguments(_ names: [String], from inner: String, to dest: String) -> [String] {
        // bsdtar decodes the names the same way, so they match the listed ones and land on disk as listed
        var args = ["-x"] + (charset.map { ["--options", "zip:hdrcharset=" + $0] } ?? []) + ["-f", file, "-C", dest]
        guard !names.isEmpty else { return args }
        let depth = (inner.isEmpty ? 0 : inner.split(separator: "/").count) + (entryPrefix.isEmpty ? 0 : 1)
        if depth > 0 { args += ["--strip-components", String(depth)] }
        let dir = inner.isEmpty ? "" : inner + "/"
        // One file: stop at it (-q) instead of reading the rest of the archive. Not a folder (its contents follow it),
        // nor a name stored twice (-q takes the first; the listing shows, and a full read leaves, the last).
        if names.count == 1, tree[inner]?.first(where: { $0.name == names[0] }).map({ $0.kind != .dir }) == true,
           !repeated.contains(dir + names[0]) {
            args.insert("-q", at: 1)
        }
        return args + ["--"] + names.map { entryPrefix + Self.literalPattern(dir + $0) }   // "--": a member named "--use-compress-program=…" is a name
    }

    /// bsdtar matches member names as patterns: make \ [ ] * ? literal.
    static func literalPattern(_ name: String) -> String {
        var out = ""
        for c in name {
            if "\\[]*?".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Extracts synchronously (call off the main thread).
    public func extract(_ names: [String], from inner: String, to dest: String) throws {
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        try Self.tar(extractArguments(names, from: inner, to: dest))
    }

    /// The tar family, compressed or not. It has no table of contents: listing one reads (and unpacks) all of it.
    public static func isTar(_ name: String) -> Bool {
        let n = name.lowercased()
        return [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz", ".tar.zst", ".tzst", ".tar.lz4"]
            .contains(where: n.hasSuffix)
    }

    /// Where a whole tar unpacks when `dest` has something in it already: a hidden folder inside `dest`, so what's at
    /// its top then moves out by rename (`moveExtracted`).
    public static func stagingFolder(in dest: String) -> String {
        (dest as NSString).appendingPathComponent(".kermo-extract-" + UUID().uuidString)
    }

    /// What's at the top of `staging` that `dest` has already.
    public static func clashes(_ staging: String, _ dest: String) -> [String] {
        ((try? DirLister.list(staging)) ?? []).map(\.name).filter { FileJob.lstat((dest as NSString).appendingPathComponent($0)) != nil }.sorted()
    }

    /// Moves what's at the top of `staging` into `dest` as bsdtar would have put it there: folders merge, a file
    /// that's there already stays (`keep`, bsdtar's -k) or is replaced. A folder an archive's file would replace
    /// stays, and so it's reported (bsdtar can't remove one that has something in it either). Then `staging` goes.
    /// Returns what couldn't be moved.
    public static func moveExtracted(_ staging: String, to dest: String, keep: Bool) -> [String] {
        let tops = ((try? DirLister.list(staging)) ?? []).map { (staging as NSString).appendingPathComponent($0.name) }
        let job = FileJob(.move, sources: tops, destDir: dest)
        job.resolveConflict = { [unowned job] c in
            if c.replacesFolder { job.update { $0.errors.append("\(c.dst): a folder is there, kept") }; return (.skip, false) }
            return (c.bothDirs || !keep ? .overwrite : .skip, false)
        }
        job.run()
        try? FileManager.default.removeItem(atPath: staging)
        return job.progress.errors
    }

    /// bsdtar arguments to create `archive` (format from its extension: .zip .tar.gz .tgz .tar.bz2 .tar.xz .7z)
    /// from `names` inside `dir`. Run with COPYFILE_DISABLE=1 so no "._*" AppleDouble files get added.
    public static func createArguments(_ archive: String, names: [String], in dir: String) -> [String] {
        ["-a", "-c", "-f", archive, "-C", dir] + names.map { $0.hasPrefix("-") ? "./" + $0 : $0 }
    }

    static func tar(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { $1 }
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let msg = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw ArchiveError(String(decoding: msg, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// An archive on a server, listed and unpacked there (tar, unzip), never downloaded: the tar family and zips.
public enum RemoteArchive {
    private static func isZip(_ name: String) -> Bool {
        ["zip", "jar", "war", "ear", "apk", "ipa"].contains((name as NSString).pathExtension.lowercased())
    }

    public static func isArchive(_ name: String) -> Bool {
        let n = name.lowercased()
        return isZip(n) || [".tar", ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz4", ".tgz", ".tbz", ".tbz2", ".txz", ".tzst"]
            .contains(where: n.hasSuffix)
    }

    /// For the viewer: `tar -tv`'s or `unzip -l`'s own table. `file` is absolute, so never taken for an option
    /// (or by GNU tar for host:file).
    public static func listCommand(_ file: String) -> String { (isZip(file) ? "unzip -l " : "tar -tvf ") + ShellContext.quote(file) }

    /// One member per line.
    public static func namesCommand(_ file: String) -> String { (isZip(file) ? "unzip -Z1 " : "tar -tf ") + ShellContext.quote(file) }

    /// All of it into `dest` (made if missing); `keep`: what's there already stays — quietly: GNU tar's -k reports
    /// each one as an error and exits 2, its --skip-old-files doesn't, but with -v says "skipping existing file" for
    /// each on stderr (red, as if failed): so no -v there (bsdtar's -k is quiet, and has no such option).
    public static func extractCommand(_ file: String, to dest: String, keep: Bool) -> String {
        let (f, d) = (ShellContext.quote(file), ShellContext.quote(dest))
        if isZip(file) { return "mkdir -p -- \(d) && unzip \(keep ? "-n" : "-o") \(f) -d \(d)" }
        let tar = { (k: String) in "tar -x \(k)-f \(f) -C \(d)" }
        guard keep else { return "mkdir -p -- \(d) && " + tar("-v ") }
        return "mkdir -p -- \(d) && if tar --version 2>/dev/null | grep -q GNU; then \(tar("--skip-old-files ")); else \(tar("-v -k ")); fi"
    }

    /// What `namesCommand` lists for `file` at the top: the names extracting lands in `dest`.
    public static func topNames(_ listing: String, of file: String) -> [String] {
        // unzip prints names as they are ("a\f.txt" is no form feed), and unpacks a Windows zip's "dir\f" into dir/:
        // a backslash counts as a folder there (a clash too many only asks).
        let zip = isZip(file)
        var seen = Set<String>()
        return listing.split(separator: "\n").compactMap { line in
            ArchiveIndex.normalize(zip ? line.replacingOccurrences(of: "\\", with: "/") : unescape(line)).split(separator: "/").first.map(String.init)
                .flatMap { seen.insert($0).inserted ? $0 : nil }
        }
    }

    /// GNU tar and bsdtar print names escaped: \\, \n, \t…, and bytes as \ooo (non-ASCII outside a UTF-8 locale).
    static func unescape(_ s: Substring) -> String {
        let named: [UInt8: UInt8] = [110: 10, 116: 9, 114: 13, 97: 7, 98: 8, 102: 12, 118: 11]   // n t r a b f v
        var out: [UInt8] = [], b = Array(s.utf8)[...]
        while let c = b.popFirst() {
            guard c == UInt8(ascii: "\\"), let e = b.first else { out.append(c); continue }
            let octal = b.prefix(3).prefix { (48...55).contains($0) }
            if octal.count == 3 {
                out.append(octal.reduce(0) { $0 &* 8 &+ ($1 - 48) })
                b = b.dropFirst(3)
            } else {
                out.append(named[e] ?? e)
                b = b.dropFirst()
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// One compressed file that isn't an archive (rotated logs: app.log.1.gz, .bz2, .xz, .zst), unpacked as a stream
/// through libarchive. zstd works only where libarchive can reach a `zstd` program.
public enum CompressedFile {
    public static func matches(_ name: String) -> Bool {
        ["gz", "bz2", "xz", "zst"].contains((name as NSString).pathExtension.lowercased()) && !ArchiveIndex.isArchive(name)
    }

    /// The first `limit` unpacked bytes, the compression's name ("gzip", "bzip2", "xz", "zstd"), whether more was
    /// left, and whether the stream broke off (a cut-off download, logrotate killed mid-compress): `data` is then
    /// what came before the break, possibly nothing. nil if the file isn't compressed or can't be unpacked at all.
    public static func read(_ file: String, limit: Int) -> (data: Data, compression: String, truncated: Bool, damaged: Bool)? {
        guard let a = archive_read_new() else { return nil }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_raw(a)
        archive_read_support_format_empty(a)   // `: | gzip`: an empty rotated log
        var entry: OpaquePointer?
        let opened = [ARCHIVE_OK, ARCHIVE_WARN].contains(archive_read_open_filename(a, file, 1 << 16))
        let header = opened ? archive_read_next_header(a, &entry) : ARCHIVE_FATAL
        guard [ARCHIVE_OK, ARCHIVE_WARN, ARCHIVE_EOF].contains(header) else {
            // libarchive unpacks 64 KB before it settles the format: a file cut off before that doesn't open at all
            return signature(file).map { (Data(), $0, false, true) }
        }
        guard archive_filter_count(a) > 1, let name = archive_filter_name(a, 0) else { return nil }   // filter 0 "none": not compressed
        var data = Data(), damaged = false, buf = [UInt8](repeating: 0, count: 1 << 16)
        while header != ARCHIVE_EOF && data.count <= limit {
            let n = archive_read_data(a, &buf, buf.count)
            damaged = n < 0
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return (data.prefix(limit), String(cString: name), data.count > limit, damaged)
    }

    /// The compression a file that doesn't open starts with. Not zstd: without a `zstd` program it never opens.
    private static func signature(_ file: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 6)) ?? Data()
        let magic: [(String, [UInt8])] = [("gzip", [0x1f, 0x8b]), ("bzip2", Array("BZh".utf8)), ("xz", [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0])]
        return magic.first { head.starts(with: $0.1) }?.0
    }
}

public struct ArchiveError: LocalizedError {
    public let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
