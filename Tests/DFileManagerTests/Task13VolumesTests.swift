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
