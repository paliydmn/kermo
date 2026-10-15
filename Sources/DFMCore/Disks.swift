import DiskArbitration
import Foundation

/// A volume on a disk Kermo may mount and unmount: as DiskArbitration describes it.
public struct Disk: Equatable, Sendable {
    public let bsd: String          // "disk4s1"
    public let name: String
    public let format: String       // "MS-DOS (FAT32)", "APFS"
    public let size: Int64          // its partition's (an APFS volume's: its container's)
    public let mountPath: String?   // where it's mounted; nil: it isn't

    public init(bsd: String, name: String, format: String, size: Int64, mountPath: String?) {
        (self.bsd, self.name, self.format, self.size, self.mountPath) = (bsd, name, format, size, mountPath)
    }
}

public enum Disks {
    /// macOS's own volumes, there on an external macOS disk too.
    static let serviceRoles: Set = ["Preboot", "Recovery", "VM", "Update", "xART", "Hardware"]
    /// The EFI partition (FAT32, on every GPT disk) and an HFS+ disk's Recovery HD.
    static let serviceContent: Set = ["C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "EFI", "426F6F74-0000-11AA-AA11-00306543ECAC", "Apple_Boot"]

    /// A volume of an external or removable disk with a file system macOS mounts — never this Mac's own disk, a disk
    /// image, a network share, the EFI partition or macOS's service volumes. `description`: DADiskCopyDescription's;
    /// `roles`: its APFS roles (the IORegistry's "Role", which the description doesn't carry).
    public static func disk(_ description: [String: Any], roles: [String] = []) -> Disk? {
        func key(_ k: CFString) -> Any? { description[k as String] }
        let image = [kDADiskDescriptionDeviceModelKey, kDADiskDescriptionDeviceProtocolKey].contains { key($0) as? String == "Disk Image" }
            || key(kDADiskDescriptionDeviceProtocolKey) as? String == "Virtual Interface"
        let outside = key(kDADiskDescriptionDeviceInternalKey) as? Bool == false || key(kDADiskDescriptionMediaRemovableKey) as? Bool == true
        guard key(kDADiskDescriptionVolumeMountableKey) as? Bool == true, key(kDADiskDescriptionVolumeNetworkKey) as? Bool != true,
              !image, outside, let bsd = key(kDADiskDescriptionMediaBSDNameKey) as? String,
              !serviceContent.contains(key(kDADiskDescriptionMediaContentKey) as? String ?? ""),
              serviceRoles.isDisjoint(with: roles) else { return nil }
        let name = (key(kDADiskDescriptionVolumeNameKey) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        return Disk(bsd: bsd, name: name, format: key(kDADiskDescriptionVolumeTypeKey) as? String ?? key(kDADiskDescriptionVolumeKindKey) as? String ?? "",
                    size: (key(kDADiskDescriptionMediaSizeKey) as? NSNumber)?.int64Value ?? 0,
                    mountPath: (key(kDADiskDescriptionVolumePathKey) as? URL).map { $0.path })
    }
}

extension Disks {
    /// A DiskArbitration status in words, for "Couldn't mount “X”: …" (its own text, when it has one, comes first).
    public static func why(_ status: Int32) -> String {
        switch UInt32(bitPattern: status) {
        case 0xF8DA_0002: return "it's in use"
        case 0xF8DA_0004: return "another app has it to itself"
        case 0xF8DA_0006: return "it's gone"
        case 0xF8DA_0007: return "it isn't mounted"
        case 0xF8DA_0008, 0xF8DA_0009: return "macOS doesn't allow it"
        case 0xF8DA_000A: return "the disk isn't ready"
        case 0xF8DA_000B: return "the disk is read-only"
        case 0xF8DA_000C: return "macOS can't mount this kind of volume"
        case let s where s & 0xFC00_0000 == 0x0C00_0000: return String(cString: strerror(Int32(s & 0x3FFF)))   // unix_err(errno)
        default: return String(format: "DiskArbitration error 0x%08X", UInt32(bitPattern: status))
        }
    }

    /// The processes `lsof -F c` names (a "c" line each; "p" lines are their ids), each once, in its order.
    public static func holders(lsof: String) -> [String] {
        var seen = Set<String>()
        return lsof.split(separator: "\n").compactMap { $0.first == "c" ? String($0.dropFirst()) : nil }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// "in use by Preview, zsh", three at most, then "…".
    public static func inUse(by names: [String]) -> String? {
        names.isEmpty ? nil : "in use by " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? "…" : "")
    }

    /// Who has files open on the volume mounted at `mount` — asked only when it wouldn't unmount; lsof stopped after
    /// `timeout` (it reads every process's files).
    public static func holders(of mount: String, timeout: TimeInterval = 3) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["+c", "0", "-F", "c", "+f", "--", mount]   // +c 0: the whole name; +f: a file system's every file
        let out = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let kill = DispatchWorkItem { p.terminate() }
        Timeouts.queue.asyncAfter(deadline: .now() + timeout, execute: kill)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        kill.cancel()
        return holders(lsof: String(decoding: data, as: UTF8.self))
    }
}
