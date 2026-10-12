import Foundation

public enum DirLister {
    /// Fast path: getattrlistbulk(2) returns hundreds of entries with their attributes per syscall.
    public static func list(_ path: String) throws -> [FileItem] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }

        var req = attrlist()
        req.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        req.commonattr = bits(ATTR_CMN_RETURNED_ATTRS) | bits(ATTR_CMN_NAME) | bits(ATTR_CMN_ERROR)
            | bits(ATTR_CMN_OBJTYPE) | bits(ATTR_CMN_MODTIME) | bits(ATTR_CMN_FNDRINFO) | bits(ATTR_CMN_OWNERID) | bits(ATTR_CMN_GRPID)
            | bits(ATTR_CMN_ACCESSMASK) | bits(ATTR_CMN_FLAGS)
        req.fileattr = bits(ATTR_FILE_DATALENGTH)

        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        var items: [FileItem] = []
        while true {
            let count = getattrlistbulk(fd, &req, buf, bufSize, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            var entry = UnsafeRawPointer(buf)
            for _ in 0..<count {
                items.append(parse(entry))
                entry += Int(entry.loadUnaligned(as: UInt32.self))
            }
        }
        return items
    }

    /// Entry layout (see `man getattrlistbulk`): length, returned-attrs set, then only the
    /// attributes actually returned, in bit order (ERROR comes first). All fields 4-byte aligned.
    private static func parse(_ entry: UnsafeRawPointer) -> FileItem {
        var p = entry + 4
        let ret = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size
        func has(_ group: attrgroup_t, _ bit: Int32) -> Bool { group & bits(bit) != 0 }

        if has(ret.commonattr, ATTR_CMN_ERROR) { p += 4 }
        var name = ""
        if has(ret.commonattr, ATTR_CMN_NAME) {
            let ref = p.loadUnaligned(as: attrreference_t.self)
            let bytes = UnsafeRawBufferPointer(start: p + Int(ref.attr_dataoffset), count: max(0, Int(ref.attr_length) - 1))
            name = String(decoding: bytes, as: UTF8.self)
            p += MemoryLayout<attrreference_t>.size
        }
        var type: UInt32 = 0
        if has(ret.commonattr, ATTR_CMN_OBJTYPE) { type = p.loadUnaligned(as: UInt32.self); p += 4 }
        var mtime = 0.0
        if has(ret.commonattr, ATTR_CMN_MODTIME) {
            let ts = p.loadUnaligned(as: timespec.self)
            mtime = Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
            p += MemoryLayout<timespec>.size
        }
        var label: UInt8 = 0
        if has(ret.commonattr, ATTR_CMN_FNDRINFO) {   // 32 bytes; Finder flags at 8–9 (big-endian), color in bits 1–3
            label = (p.load(fromByteOffset: 9, as: UInt8.self) >> 1) & 7
            p += 32
        }
        var uid = FileItem.unknown, gid = FileItem.unknown
        if has(ret.commonattr, ATTR_CMN_OWNERID) { uid = p.loadUnaligned(as: UInt32.self); p += 4 }
        if has(ret.commonattr, ATTR_CMN_GRPID) { gid = p.loadUnaligned(as: UInt32.self); p += 4 }
        var mode: UInt32 = 0
        if has(ret.commonattr, ATTR_CMN_ACCESSMASK) { mode = p.loadUnaligned(as: UInt32.self); p += 4 }
        var flags: UInt32 = 0
        if has(ret.commonattr, ATTR_CMN_FLAGS) { flags = p.loadUnaligned(as: UInt32.self); p += 4 }
        var size: Int64 = 0
        if has(ret.fileattr, ATTR_FILE_DATALENGTH) { size = p.loadUnaligned(as: Int64.self) }

        let kind: FileItem.Kind = switch type {   // enum vtype: VREG=1, VDIR=2, VBLK=3, VCHR=4, VLNK=5, VSOCK=6, VFIFO=7
        case 1: .file
        case 2: .dir
        case 5: .link
        default: .other
        }
        // ACCESSMASK promises only the permission bits (APFS happens to include the type); a special file keeps its
        // S_IFMT type either way, so the panel can say which it is.
        switch type {
        case 3: mode |= UInt32(S_IFBLK)
        case 4: mode |= UInt32(S_IFCHR)
        case 6: mode |= UInt32(S_IFSOCK)
        case 7: mode |= UInt32(S_IFIFO)
        default: break
        }
        return FileItem(name: name, kind: kind, size: size, mtime: mtime, mode: mode, flags: flags, label: label, uid: uid, gid: gid)
    }

    /// Reference implementation via FileManager — used by the benchmark as baseline and oracle.
    public static func listFoundation(_ path: String) throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys)
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let kind: FileItem.Kind = v?.isSymbolicLink == true ? .link
                : v?.isDirectory == true ? .dir
                : v?.isRegularFile == true ? .file : .other
            return FileItem(name: url.lastPathComponent, kind: kind, size: Int64(v?.fileSize ?? 0),
                            mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0, mode: 0, flags: 0)
        }
    }

    /// (file count, total bytes) of a tree. Symlinks are counted, never followed; mount points
    /// inside the tree are not crossed (so `/` doesn't double-count firmlinked /System/Volumes/Data).
    public static func measure(_ path: String, isCancelled: () -> Bool = { false }) -> (files: Int, bytes: Int64) {
        var root = stat()
        guard lstat(path, &root) == 0 else { return (0, 0) }
        guard root.st_mode & S_IFMT == S_IFDIR else { return (1, Int64(root.st_size)) }
        return measureDir(path, device: root.st_dev, isCancelled: isCancelled)
    }

    private static func measureDir(_ path: String, device: dev_t, isCancelled: () -> Bool) -> (files: Int, bytes: Int64) {
        var files = 0, bytes: Int64 = 0
        guard !isCancelled() else { return (0, 0) }   // a big folder's listing alone takes a while
        for item in (try? list(path)) ?? [] {
            if isCancelled() { break }
            if item.kind == .dir {
                let sub = (path as NSString).appendingPathComponent(item.name)
                var s = stat()
                guard lstat(sub, &s) == 0, s.st_dev == device else { continue }
                let (f, b) = measureDir(sub, device: device, isCancelled: isCancelled)
                files += f; bytes += b
            } else {
                files += 1; bytes += item.size
            }
        }
        return (files, bytes)
    }

    /// False on FAT, exFAT and some SMB shares: macOS keeps a file's xattrs there in a "._name" file beside it.
    public static func hasNativeXattrs(_ path: String) -> Bool {
        var req = attrlist()
        req.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        req.volattr = bits(ATTR_VOL_INFO) | bits(ATTR_VOL_CAPABILITIES)
        var buf = (UInt32(0), vol_capabilities_attr_t())   // length, then the capabilities
        guard getattrlist(path, &req, &buf, MemoryLayout.size(ofValue: buf), 0) == 0 else { return true }
        let i = Int(VOL_CAPABILITIES_INTERFACES), bit = UInt32(VOL_CAP_INT_EXTENDED_ATTR)
        let valid = withUnsafeBytes(of: buf.1.valid) { $0.load(fromByteOffset: i * 4, as: UInt32.self) }
        let caps = withUnsafeBytes(of: buf.1.capabilities) { $0.load(fromByteOffset: i * 4, as: UInt32.self) }
        return valid & bit == 0 || caps & bit != 0
    }

    private static func bits(_ v: Int32) -> attrgroup_t { attrgroup_t(truncatingIfNeeded: v) }
    private static func bits(_ v: UInt32) -> attrgroup_t { v }
    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
