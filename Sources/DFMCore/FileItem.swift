import Foundation

public struct FileItem: Sendable {
    public enum Kind: UInt8, Sendable { case file, dir, link, other }

    public let name: String
    public let kind: Kind
    public let size: Int64      // logical size; 0 for dirs
    public let mtime: Double    // seconds since 1970
    public let mode: UInt32     // permission bits (st_mode & 07777 style); an `.other` carries its S_IFMT type too (FIFO, socket, device)
    public let flags: UInt32    // chflags(2): UF_HIDDEN, UF_IMMUTABLE, ...
    public let label: UInt8     // Finder color label 0–7 (see FinderTags.Tag.color)
    public let uid: UInt32, gid: UInt32   // owner and group, `unknown` where the lister can't say (archives); a server's own numbers
    /// A symlink to a folder (once its target is known): it sorts with the folders and reads <DIR>, as in MC.
    public var linkDir = false

    public static let unknown = UInt32.max   // chown(2)'s "leave as is", never a real id

    public init(name: String, kind: Kind, size: Int64, mtime: Double, mode: UInt32, flags: UInt32, label: UInt8 = 0,
                uid: UInt32 = FileItem.unknown, gid: UInt32 = FileItem.unknown) {
        self.name = name; self.kind = kind; self.size = size
        self.mtime = mtime; self.mode = mode; self.flags = flags; self.label = label
        self.uid = uid; self.gid = gid
    }

    public var isHidden: Bool { name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0 }
    /// An iCloud / Dropbox placeholder: reading it downloads the whole file first.
    public var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }

    /// The name as listed (`String.listed`). Never for text we read back or act on.
    public var displayName: String { name.listed }
}

extension String {
    /// For a list cell: bidi controls shown (`bidiVisible`), a newline as ␤ and other control characters as ?
    /// (like `ls -q`), so the row stays one line. Names, and a link's target beside one.
    public var listed: String {
        let s = bidiVisible
        guard s.contains(where: Self.isControl) else { return s }
        return String(s.map { $0.isNewline ? "␤" : Self.isControl($0) ? "?" : $0 })
    }
    private static func isControl(_ c: Character) -> Bool {
        c.isNewline || c.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
    }

    /// Bidi controls shown as ⟨U+202E⟩ instead of applied, so "rtl-\u{202E}txt.exe" can't pass for "rtl-exe.txt";
    /// a server name's byte that isn't UTF-8 (`WireName`) as \xE9.
    /// For names in lists, titles and dialogs; never for text the user edits and we read back.
    public var bidiVisible: String {
        guard unicodeScalars.contains(where: { Self.isBidiControl($0) || WireName.isEscape($0) }) else { return self }
        return unicodeScalars.map {
            Self.isBidiControl($0) ? String(format: "⟨U+%04X⟩", $0.value)
                : WireName.isEscape($0) ? String(format: "\\x%02X", $0.value - WireName.base) : String($0)
        }.joined()
    }
    private static func isBidiControl(_ c: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(c.value) || (0x2066...0x2069).contains(c.value) || [0x200E, 0x200F, 0x061C].contains(c.value)
    }
}

/// The Permissions / Owner / Group columns and Attributes… (chmod / chown).
public enum Perms {
    /// "rwxr-xr-x", with s / S / t / T for setuid, setgid and sticky, like ls.
    public static func string(_ mode: UInt32) -> String {
        let m = mode & 0o7777
        func trio(_ who: UInt32, _ special: UInt32, _ on: String) -> String {
            let x = m & who & 0o111 != 0
            return (m & who & 0o444 != 0 ? "r" : "-") + (m & who & 0o222 != 0 ? "w" : "-")
                + (m & special != 0 ? (x ? on : on.uppercased()) : (x ? "x" : "-"))
        }
        return trio(0o700, 0o4000, "s") + trio(0o070, 0o2000, "s") + trio(0o007, 0o1000, "t")
    }

    /// "644 dmn:staff" → the mode (3–4 octal digits first) and the rest as the owner spec — `user`, `user:group` or
    /// `:group`, spaces and all ("domain users"); either one left out.
    public static func parse(_ text: String) -> (mode: UInt32?, owner: String) {
        let t = text.trimmingCharacters(in: .whitespaces), first = t.prefix { !$0.isWhitespace }
        guard (3...4).contains(first.count), let mode = UInt32(first, radix: 8) else { return (nil, t) }
        return (mode, t.dropFirst(first.count).trimmingCharacters(in: .whitespaces))
    }

    /// `user:group` → ids, either one left out; names only if `names` (this Mac's — on a server, its own numbers).
    /// Nil if one doesn't resolve.
    public static func ids(_ owner: String, names: Bool) -> (uid: UInt32?, gid: UInt32?)? {
        let parts = owner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        func id(_ s: String, _ lookup: (String) -> UInt32?) -> UInt32?? {
            if s.isEmpty { return .some(nil) }
            if let n = UInt32(s), n != FileItem.unknown { return n }
            return names ? lookup(s).map { $0 } : nil
        }
        guard let u = id(parts[0], { getpwnam($0).map { $0.pointee.pw_uid } }),
              let g = id(parts.count > 1 ? parts[1] : "", { getgrnam($0).map { $0.pointee.gr_gid } }) else { return nil }
        return (u, g)
    }

    /// chmod / chown each path, never through a symlink (like `chmod -h`); a line for each that failed.
    public static func apply(_ paths: [String], mode: UInt32?, uid: UInt32?, gid: UInt32?) -> [String] {
        paths.compactMap { p in
            if let mode, !FileInfo.setMode(p, mode_t(mode & 0o7777)) { return failed(p) }
            if uid != nil || gid != nil, lchown(p, uid ?? FileItem.unknown, gid ?? FileItem.unknown) != 0 { return failed(p) }
            return nil
        }
    }
    private static func failed(_ p: String) -> String { "“\((p as NSString).lastPathComponent)”: \(String(cString: strerror(errno)))" }
}

public enum SortKey: String, Sendable { case name, size, mtime }

extension Array where Element == FileItem {
    /// Dirs first, then by key; ties broken by natural name order (file2 < file10).
    /// Name keys are precomputed once: ASCII names compare as bytes (fast path),
    /// anything else falls back to localizedStandardCompare (Finder order, ~10x slower).
    public func sortedForPanel(by key: SortKey, ascending: Bool) -> [FileItem] {
        let keys = map(NameKey.init)
        let order = indices.sorted { i, j in
            let a = self[i], b = self[j]
            let ad = a.kind == .dir || a.linkDir, bd = b.kind == .dir || b.linkDir
            if ad != bd { return ad }
            let r: Int
            switch key {
            case .size where a.size != b.size: r = a.size < b.size ? -1 : 1
            case .mtime where a.mtime != b.mtime: r = a.mtime < b.mtime ? -1 : 1
            default: r = NameKey.compare(keys[i], keys[j])
            }
            return ascending ? r < 0 : r > 0
        }
        return order.map { self[$0] }
    }
}

struct NameKey {
    let folded: [UInt8]?   // lowercased ASCII bytes; nil if name has non-ASCII
    let name: String

    init(_ item: FileItem) {
        name = item.name
        let utf8 = item.name.utf8
        folded = utf8.allSatisfy { $0 < 0x80 } ? utf8.map { $0 >= 65 && $0 <= 90 ? $0 | 0x20 : $0 } : nil
    }

    static func compare(_ a: NameKey, _ b: NameKey) -> Int {
        // Fast path decides almost every pair; ties ("a" vs "A", "07" vs "7") and non-ASCII go to ICU.
        if let x = a.folded, let y = b.folded {
            let r = natural(x, y)
            if r != 0 { return r }
        }
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    /// ASCII weights in ICU root collation order (what Finder uses): whitespace, punctuation, digits, letters.
    private static let weight: [UInt8] = {
        var w = [UInt8](repeating: 0, count: 128)
        for (i, c) in "\t\n\r _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789abcdefghijklmnopqrstuvwxyz".utf8.enumerated() {
            w[Int(c)] = UInt8(i + 1)
        }
        return w
    }()

    static func natural(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if isDigit(a[i]) && isDigit(b[j]) {
                // Compare digit runs numerically: skip leading zeros, longer run wins, then digit by digit.
                while i < a.count - 1 && a[i] == 48 && isDigit(a[i + 1]) { i += 1 }
                while j < b.count - 1 && b[j] == 48 && isDigit(b[j + 1]) { j += 1 }
                var ei = i, ej = j
                while ei < a.count && isDigit(a[ei]) { ei += 1 }
                while ej < b.count && isDigit(b[ej]) { ej += 1 }
                if ei - i != ej - j { return ei - i < ej - j ? -1 : 1 }
                while i < ei {
                    if a[i] != b[j] { return a[i] < b[j] ? -1 : 1 }
                    i += 1; j += 1
                }
            } else {
                let ca = a[i], cb = b[j]
                if ca != cb {
                    let wa = weight[Int(ca)], wb = weight[Int(cb)]
                    return wa != wb ? (wa < wb ? -1 : 1) : (ca < cb ? -1 : 1)
                }
                i += 1; j += 1
            }
        }
        return (a.count - i) == (b.count - j) ? 0 : (a.count - i < b.count - j ? -1 : 1)
    }
}
