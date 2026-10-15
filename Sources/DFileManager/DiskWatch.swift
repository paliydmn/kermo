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
        guard let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        let found = gone ? nil : (DADiskCopyDescription(disk) as? [String: Any]).flatMap { d in
            Disks.disk(d).flatMap { _ in Disks.disk(d, roles: Self.roles(disk)) }   // the registry only for what passed
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

    /// An APFS volume's roles (Preboot, VM…): in the IORegistry, not in DiskArbitration's description.
    private static func roles(_ disk: DADisk) -> [String] {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return [] }
        defer { IOObjectRelease(media) }
        return IORegistryEntryCreateCFProperty(media, "Role" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String] ?? []
    }
}
