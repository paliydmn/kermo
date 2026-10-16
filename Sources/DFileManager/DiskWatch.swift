import DFMCore
import DiskArbitration
import Foundation
import IOKit

/// DiskArbitration's volumes Kermo may mount (`Disks.disk`), followed as they appear, go, mount and unmount — on a
/// queue of its own. The list goes to the main thread only when it changed, at most every 0.2 s (at start every disk
/// appears at once).
final class DiskWatch: @unchecked Sendable {
    private let session = DASessionCreate(kCFAllocatorDefault)!
    private let queue = DispatchQueue(label: "kermo.disks")
    private var disks: [String: Disk] = [:]   // on `queue`, by BSD name
    private var pending = false
    /// The whole disk the Mac started from (for APFS its container): none of its volumes is listed, external or not.
    private lazy var boot: String? = Self.bsd(DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: "/") as CFURL).flatMap(DADiskCopyWholeDisk))

    /// Its BSD name, read while the disk is alive (the C string is the disk's own).
    static func bsd(_ disk: DADisk?) -> String? {
        guard let disk else { return nil }
        return withExtendedLifetime(disk) { DADiskGetBSDName(disk).map { String(cString: $0) } }
    }
    private let changed: @MainActor @Sendable ([Disk]) -> Void

    /// Lives as long as the app: the callbacks hold it unretained.
    init(changed: @escaping @MainActor @Sendable ([Disk]) -> Void) {
        self.changed = changed
        let me = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, me in Unmanaged<DiskWatch>.fromOpaque(me!).takeUnretainedValue().update(disk) }, me)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, me in Unmanaged<DiskWatch>.fromOpaque(me!).takeUnretainedValue().update(disk) }, me)
        DARegisterDiskDisappearedCallback(session, nil, { disk, me in Unmanaged<DiskWatch>.fromOpaque(me!).takeUnretainedValue().update(disk, gone: true) }, me)
        DASessionSetDispatchQueue(session, queue)
    }

    private func update(_ disk: DADisk, gone: Bool = false) {
        guard let bsd = Self.bsd(disk) else { return }
        let found = gone ? nil : (DADiskCopyDescription(disk) as? [String: Any]).flatMap { d in
            Disks.disk(d).flatMap { _ in   // the registry only for what passed
                Disks.disk(d, roles: Self.roles(disk), boot: boot != nil && Self.bsd(DADiskCopyWholeDisk(disk)) == boot)
            }
        }
        guard disks[bsd] != found else { return }
        disks[bsd] = found
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 0.2) { [self] in
            pending = false
            let list = disks.values.sorted { $0.bsd < $1.bsd }
            Task { @MainActor in changed(list) }
        }
    }

    /// Mounts the volume where macOS would: its mount point, or why not (DiskArbitration's words).
    func mount(_ bsd: String) async -> Result<String, MountError> {
        await withCheckedContinuation { (c: CheckedContinuation<Result<String, MountError>, Never>) in
            queue.async { [self] in
                guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else { return c.resume(returning: .failure(MountError("it's gone"))) }
                DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { disk, dissenter, done in
                    let c = Unmanaged<Done>.fromOpaque(done!).takeRetainedValue().c
                    if let dissenter {
                        let text = DADissenterGetStatusString(dissenter) as String?
                        return c.resume(returning: .failure(MountError(text.flatMap { $0.isEmpty ? nil : $0 } ?? Disks.why(DADissenterGetStatus(dissenter)))))
                    }
                    let path = ((DADiskCopyDescription(disk) as? [String: Any])?[kDADiskDescriptionVolumePathKey as String] as? URL)?.path
                    c.resume(returning: path.map { .success($0) } ?? .failure(MountError("macOS didn't say where")))
                }, Unmanaged.passRetained(Done(c)).toOpaque())
            }
        }
    }

    /// The physical disk under the volume mounted at `path`: for APFS the one its container lives on (the topmost
    /// whole IOMedia), not the container's synthesized disk.
    func device(of path: String) async -> String? {
        await withCheckedContinuation { c in
            queue.async { [self] in
                var entry = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: path) as CFURL).map(DADiskCopyIOMedia) ?? 0
                var found: String?
                while entry != 0 {
                    if IOObjectConformsTo(entry, "IOMedia") != 0, IORegistryEntryCreateCFProperty(entry, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool == true {
                        found = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                    }
                    var parent: io_registry_entry_t = 0
                    let r = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
                    IOObjectRelease(entry)
                    entry = r == KERN_SUCCESS ? parent : 0
                }
                c.resume(returning: found)
            }
        }
    }

    /// Ejects the disk `bsd` if it's still there and an external or removable one: an APFS stick stays plugged in
    /// after macOS unmounts its volumes and "ejects" the container. Nil when done or gone; else why not.
    func eject(_ bsd: String) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            queue.async { [self] in
                guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd), let d = DADiskCopyDescription(disk) as? [String: Any],
                      d[kDADiskDescriptionMediaEjectableKey as String] as? Bool == true,
                      d[kDADiskDescriptionDeviceInternalKey as String] as? Bool != true || d[kDADiskDescriptionMediaRemovableKey as String] as? Bool == true
                else { return c.resume(returning: nil) }
                DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, done in
                    let c = Unmanaged<Ejected>.fromOpaque(done!).takeRetainedValue().c
                    c.resume(returning: dissenter.map { (DADissenterGetStatusString($0) as String?).flatMap { $0.isEmpty ? nil : $0 } ?? Disks.why(DADissenterGetStatus($0)) })
                }, Unmanaged.passRetained(Ejected(c)).toOpaque())
            }
        }
    }

    private final class Ejected { let c: CheckedContinuation<String?, Never>; init(_ c: CheckedContinuation<String?, Never>) { self.c = c } }

    struct MountError: Error { let text: String; init(_ text: String) { self.text = text } }
    private final class Done { let c: CheckedContinuation<Result<String, MountError>, Never>; init(_ c: CheckedContinuation<Result<String, MountError>, Never>) { self.c = c } }

    /// An APFS volume's roles (Preboot, VM…): in the IORegistry, not in DiskArbitration's description.
    private static func roles(_ disk: DADisk) -> [String] {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return [] }
        defer { IOObjectRelease(media) }
        return IORegistryEntryCreateCFProperty(media, "Role" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String] ?? []
    }
}
