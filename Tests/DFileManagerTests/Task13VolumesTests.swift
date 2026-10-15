import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// PR 12b: Locations — used / free, disks not mounted, Mount / Unmount, a spinner and who holds a disk.

@MainActor private func volumeRow(_ v: VolumeRow) throws -> NSStackView {
    try #require(SidebarController().outlineView(NSOutlineView(), viewFor: nil, item: SidebarController.Node(place: .volume(v))) as? NSStackView)
}

/// V1: "110 GB / 350 GB" right of the name — used red, free green — giving way to the name in a narrow column;
/// white on a focused selection's accent. No figures, no label.
@MainActor @Test func aVolumeRowShowsUsedRedAndFreeGreen() throws {
    let r = try volumeRow(VolumeRow(path: "/Volumes/USB", name: "USB", used: "110 GB", free: "350 GB", total: "460 GB", ejectable: true))
    let f = try #require(r.arrangedSubviews.compactMap { $0 as? VolumeFigures }.first)
    let name = try #require(r.arrangedSubviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "USB" })
    let s = f.attributedStringValue
    #expect(s.string == "110 GB / 350 GB")
    func color(_ at: Int) -> NSColor? { s.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor }
    #expect(color(0) == .systemRed && color(s.length - 1) == .systemGreen)
    #expect(f.contentCompressionResistancePriority(for: .horizontal) < name.contentCompressionResistancePriority(for: .horizontal))
    #expect(f.lineBreakMode == .byTruncatingTail)
    #expect(r.toolTip == "/Volumes/USB · 110 GB used of 460 GB · 350 GB free")

    let row = HoverRowView()
    row.addSubview(r)
    row.isEmphasized = true
    row.isSelected = true
    #expect(color(0) != f.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, "white on the accent")
    row.isSelected = false
    #expect(f.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed)

    let none = try volumeRow(VolumeRow(path: "/Volumes/S", name: "S", ejectable: true))
    #expect(!none.arrangedSubviews.contains { $0 is VolumeFigures } && none.toolTip == "/Volumes/S")
}

/// V3: a disk's volume that isn't mounted comes after the mounted ones, gray, no path to open, no eject; one the
/// kernel has mounted already (DiskArbitration not caught up) isn't listed twice; a mounted one knows its disk.
@MainActor @Test func aVolumeNotMountedIsListedGray() throws {
    let stick = Disk(bsd: "disk9s2", name: "STICK", format: "ExFAT", size: 31_000_000_000, mountPath: nil)
    let card = Disk(bsd: "disk8s1", name: "CARD", format: "MS-DOS (FAT32)", size: 0, mountPath: nil)
    let usb = Disk(bsd: "disk7s1", name: "USB", format: "APFS", size: 0, mountPath: "/Volumes/USB")
    let vols = [Volume(path: "/", name: "Macintosh HD", free: 1, total: 2, ejectable: false, device: "/dev/disk3s1s1"),
                Volume(path: "/Volumes/USB", name: "USB", free: 1, total: 2, ejectable: true, device: "/dev/disk7s1"),
                Volume(path: "/Volumes/CARD", name: "CARD", free: 1, total: 2, ejectable: true, device: "/dev/disk8s1")]
    let rows = SidebarModel.locations(vols, [card, stick, usb])
    #expect(rows.map(\.name) == ["Macintosh HD", "USB", "CARD", "STICK"])
    #expect(rows[0].disk == nil && rows[1].disk == usb && rows[2].disk == card, "by its mount point, or by its device")
    let s = try #require(rows.last)
    #expect(!s.mounted && Place.volume(s).path == nil && !Place.volume(s).selectable)
    #expect(s.tip == "Not mounted · ExFAT · \(SidebarModel.sizes.string(fromByteCount: 31_000_000_000))")

    let view = try volumeRow(s)
    let name = try #require(view.arrangedSubviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "STICK" })
    #expect(name.textColor == .secondaryLabelColor)
    #expect(!view.arrangedSubviews.contains { ($0 as? NSButton)?.image?.accessibilityDescription == "Eject" })
    #expect(try volumeRow(rows[1]).arrangedSubviews.contains { ($0 as? NSButton)?.image?.accessibilityDescription == "Eject" })
}
