import DiskArbitration
import Foundation
import Testing
@testable import DFMCore

// PR 12b: which volumes Locations lists as not mounted, from DiskArbitration's descriptions (made-up, shaped as a
// USB stick's, this Mac's SSD's and a disk image's are).

private func stick(_ extra: [CFString: Any] = [:]) -> [String: Any] {
    var d: [CFString: Any] = [
        kDADiskDescriptionVolumeMountableKey: true, kDADiskDescriptionVolumeNetworkKey: false,
        kDADiskDescriptionDeviceInternalKey: false, kDADiskDescriptionDeviceProtocolKey: "USB", kDADiskDescriptionDeviceModelKey: "Storage Device",
        kDADiskDescriptionMediaRemovableKey: true, kDADiskDescriptionMediaEjectableKey: true, kDADiskDescriptionMediaWholeKey: false,
        kDADiskDescriptionMediaBSDNameKey: "disk9s2", kDADiskDescriptionMediaContentKey: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7",
        kDADiskDescriptionMediaSizeKey: NSNumber(value: 31_000_000_000), kDADiskDescriptionVolumeKindKey: "exfat",
        kDADiskDescriptionVolumeTypeKey: "ExFAT", kDADiskDescriptionVolumeNameKey: "STICK",
    ]
    d.merge(extra) { $1 }
    return Dictionary(uniqueKeysWithValues: d.map { ($0.key as String, $0.value) })
}

@Test func anExternalVolumeNotMountedIsListed() {
    #expect(Disks.disk(stick()) == Disk(bsd: "disk9s2", name: "STICK", format: "ExFAT", size: 31_000_000_000, mountPath: nil))
    // Mounted: its path (the sidebar has it from the kernel's list too).
    #expect(Disks.disk(stick([kDADiskDescriptionVolumePathKey: URL(fileURLWithPath: "/Volumes/STICK/")]))?.mountPath == "/Volumes/STICK")
    // A card in a Mac's own reader: internal, but removable.
    #expect(Disks.disk(stick([kDADiskDescriptionDeviceInternalKey: true])) != nil)
    // An external SSD: not removable, but not internal.
    #expect(Disks.disk(stick([kDADiskDescriptionMediaRemovableKey: false, kDADiskDescriptionMediaEjectableKey: false])) != nil)
    #expect(Disks.disk(stick([kDADiskDescriptionVolumeNameKey: ""]))?.name == "Untitled")
}

@Test func ownDisksImagesAndServiceVolumesAreNot() {
    // This Mac's SSD: internal, not removable.
    #expect(Disks.disk(stick([kDADiskDescriptionDeviceInternalKey: true, kDADiskDescriptionMediaRemovableKey: false])) == nil)
    // A disk image: no "internal" at all, removable — its model or protocol says what it is.
    var image = stick([kDADiskDescriptionDeviceModelKey: "Disk Image", kDADiskDescriptionDeviceProtocolKey: "Virtual Interface"])
    image[kDADiskDescriptionDeviceInternalKey as String] = nil
    #expect(Disks.disk(image) == nil)
    #expect(Disks.disk(stick([kDADiskDescriptionDeviceProtocolKey: "Disk Image"])) == nil)
    // The stick's own EFI partition (FAT32, mountable) and an old Recovery HD.
    #expect(Disks.disk(stick([kDADiskDescriptionMediaContentKey: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", kDADiskDescriptionVolumeNameKey: "EFI"])) == nil)
    #expect(Disks.disk(stick([kDADiskDescriptionMediaContentKey: "Apple_Boot"])) == nil)
    // An external macOS disk's service volumes; its Data or a Time Machine one stay.
    for role in ["Preboot", "Recovery", "VM", "Update", "xART", "Hardware"] { #expect(Disks.disk(stick(), roles: [role]) == nil, "\(role)") }
    #expect(Disks.disk(stick(), roles: ["Data"]) != nil && Disks.disk(stick(), roles: ["Backup"]) != nil)
    // Nothing to mount: the whole disk, a raw partition, a file system macOS doesn't know.
    #expect(Disks.disk(stick([kDADiskDescriptionVolumeMountableKey: false])) == nil)
    var raw = stick()
    raw[kDADiskDescriptionVolumeMountableKey as String] = nil
    #expect(Disks.disk(raw) == nil)
    #expect(Disks.disk(stick([kDADiskDescriptionVolumeNetworkKey: true])) == nil)
}

/// V5: who holds a volume, from `lsof -F c` (p, c and f lines; a name may have spaces): each once, three at most.
@Test func whoHoldsAVolumeFromLsof() {
    let out = "p501\nczsh\nfcwd\np502\ncPreview\nf12\np503\nczsh\nf3\np600\ncGoogle Chrome Helper\nftxt\np601\ncless\n"
    #expect(Disks.holders(lsof: out) == ["zsh", "Preview", "Google Chrome Helper", "less"])
    #expect(Disks.inUse(by: ["Preview", "zsh"]) == "in use by Preview, zsh")
    #expect(Disks.inUse(by: ["a", "b", "c", "d"]) == "in use by a, b, c…")
    #expect(Disks.inUse(by: []) == nil && Disks.holders(lsof: "") == [])
}

/// A dissenter's status in words; one carrying an errno says it as strerror does.
@Test func diskArbitrationStatusInWords() {
    #expect(Disks.why(Int32(bitPattern: 0xF8DA_0002)) == "it's in use")
    #expect(Disks.why(Int32(bitPattern: 0xF8DA_000C)) == "macOS can't mount this kind of volume")
    #expect(Disks.why(Int32(bitPattern: 0x0C00_0000 | UInt32(EPERM))) == String(cString: strerror(EPERM)))
    #expect(Disks.why(Int32(bitPattern: 0xF8DA_0001)) == "DiskArbitration error 0xF8DA0001")
}

/// lsof itself, on the volume this test's temporary folder is on, with a file of it held open here.
@Suite(.serialized) struct HoldersTests {
    @Test func lsofNamesWhoHoldsAFileThere() throws {
        let file = NSTemporaryDirectory() + "dfm-t13hold-" + UUID().uuidString
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: file) }
        let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
        defer { try? h.close() }
        let mount = try #require(try URL(fileURLWithPath: file).resourceValues(forKeys: [.volumeURLKey]).volume?.path)
        let me = String(cString: getprogname())
        #expect(Disks.holders(of: mount, timeout: 20).contains { me.hasPrefix($0) || $0.hasPrefix(me) }, "\(me) on \(mount)")
        #expect(Disks.holders(of: mount + "/no-such-folder-\(UUID().uuidString)") == [], "not a mount point: lsof says nothing")
    }
}
