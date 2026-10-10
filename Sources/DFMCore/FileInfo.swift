import Foundation

/// Low-level details for the Info window: stat, flags, xattrs, ACL. All lstat-based (links not followed).
public enum FileInfo {
    /// Why `path` (through links) can't be read as a file's bytes — a FIFO blocks the reader for good, a device or a
    /// socket has none to read — or nil for a regular file (or nothing there: the open says why).
    public static func notRegular(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return nil
        case S_IFDIR: return "a folder"
        case S_IFIFO: return "a FIFO"
        case S_IFSOCK: return "a socket"
        default: return "a device"
        }
    }

    /// "-rwxr-xr-x", with s/S and t/T for setuid/setgid/sticky, like ls -l.
    public static func modeString(_ mode: mode_t) -> String {
        let type: Character = switch mode & S_IFMT {
        case S_IFDIR: "d"
        case S_IFLNK: "l"
        case S_IFCHR: "c"
        case S_IFBLK: "b"
        case S_IFIFO: "p"
        case S_IFSOCK: "s"
        default: "-"
        }
        var s = String(type)
        let bits: [(mode_t, Character)] = [(S_IRUSR, "r"), (S_IWUSR, "w"), (S_IXUSR, "x"),
                                           (S_IRGRP, "r"), (S_IWGRP, "w"), (S_IXGRP, "x"),
                                           (S_IROTH, "r"), (S_IWOTH, "w"), (S_IXOTH, "x")]
        for (i, (bit, ch)) in bits.enumerated() {
            var c: Character = mode & bit != 0 ? ch : "-"
            if i == 2, mode & S_ISUID != 0 { c = c == "x" ? "s" : "S" }
            if i == 5, mode & S_ISGID != 0 { c = c == "x" ? "s" : "S" }
            if i == 8, mode & S_ISVTX != 0 { c = c == "x" ? "t" : "T" }
            s.append(c)
        }
        return s
    }

    public static func octal(_ mode: mode_t) -> String { String(mode & 0o7777, radix: 8) }

    /// chmod of the item itself: a symlink's own mode, never its target's (a private key behind a link stays private).
    public static func setMode(_ path: String, _ mode: mode_t) -> Bool { lchmod(path, mode) == 0 }

    /// Names of the chflags(2) bits that are set ("hidden", "uchg", ...).
    public static func flagNames(_ flags: UInt32) -> [String] {
        let known: [(Int32, String)] = [(UF_NODUMP, "nodump"), (UF_IMMUTABLE, "uchg"), (UF_APPEND, "uappnd"),
                                        (UF_OPAQUE, "opaque"), (UF_COMPRESSED, "compressed"), (UF_HIDDEN, "hidden"),
                                        (SF_ARCHIVED, "arch"), (SF_IMMUTABLE, "schg"), (SF_APPEND, "sappnd"),
                                        (SF_RESTRICTED, "restricted"), (SF_NOUNLINK, "sunlnk"),
                                        (SF_DATALESS, "dataless")]
        return known.filter { flags & UInt32($0.0) != 0 }.map(\.1)
    }

    /// Extended attribute names with their sizes.
    public static func xattrs(_ path: String) -> [(name: String, size: Int)] {
        let len = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard len > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: len)
        guard listxattr(path, &buf, len, XATTR_NOFOLLOW) == len else { return [] }
        return buf.split(separator: 0).map { chunk in
            let name = String(decoding: chunk.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return (name, getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW))
        }
    }

    public static func xattrString(_ path: String, _ name: String) -> String? {
        let len = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard getxattr(path, name, &buf, len, 0, XATTR_NOFOLLOW) == len else { return nil }
        return String(bytes: buf, encoding: .utf8)
    }

    /// Like `xattr -dr com.apple.quarantine`: the item and, for folders/bundles, everything inside. Returns how many had it.
    public static func removeQuarantine(_ path: String, cancel: CancelFlag = CancelFlag()) -> Int {
        var removed = removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 ? 1 : 0
        guard let e = FileManager.default.enumerator(atPath: path) else { return removed }
        while !cancel.isCancelled, let rel = e.nextObject() as? String {
            if removexattr((path as NSString).appendingPathComponent(rel), "com.apple.quarantine", XATTR_NOFOLLOW) == 0 { removed += 1 }
        }
        return removed
    }

    /// Extended ACL as text (ls -le style entries), or nil if there is none.
    public static func acl(_ path: String) -> String? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(text) }
        let lines = String(cString: text).split(separator: "\n").dropFirst()   // first line is "!#acl 1"
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    public static func userName(_ uid: uid_t) -> String {
        getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "\(uid)"
    }

    public static func groupName(_ gid: gid_t) -> String {
        getgrgid(gid).map { String(cString: $0.pointee.gr_name) } ?? "\(gid)"
    }
}
