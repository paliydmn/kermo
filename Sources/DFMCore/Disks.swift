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
