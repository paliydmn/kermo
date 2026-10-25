import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// PR 12b: Locations — used / free, disks not mounted, Mount / Unmount, a spinner and who holds a disk.

@MainActor private func volumeView(_ v: VolumeRow, in c: SidebarController = SidebarController()) throws -> NSStackView {
    try #require(c.outlineView(NSOutlineView(), viewFor: nil, item: SidebarController.Node(place: .volume(v))) as? NSStackView)
}

/// Its line with the name and the buttons; the bar, when there is one, goes under it.
@MainActor private func volumeRow(_ v: VolumeRow, in c: SidebarController = SidebarController()) throws -> NSStackView {
    let view = try volumeView(v, in: c)
    return view.orientation == .vertical ? try #require(view.arrangedSubviews.first as? NSStackView) : view
}

/// V1: under a volume's name, a bar of how full it is and "350 GB free" — "350 GB", then the bar alone in a narrow
/// column; white on a focused selection's accent. No figures, no gauge.
@MainActor @Test func aVolumeRowShowsFreeOverABar() throws {
    let r = try volumeView(VolumeRow(path: "/Volumes/USB", name: "USB", used: "110 GB", free: "350 GB", total: "460 GB", fraction: 0.24, ejectable: true))
    let g = try #require(r.arrangedSubviews.compactMap { $0 as? VolumeGauge }.first, "under the name")
    let top = try #require(r.arrangedSubviews.first as? NSStackView)
    #expect(top.arrangedSubviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "USB" })
    #expect(g.text.string == "350 GB free" && g.accessibilityLabel() == "350 GB free" && g.accessibilityValue() as? Int == 24)
    func color() -> NSColor? { g.text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor }
    #expect(color() == Palette.secondary)
    g.frame.size.width = 140
    #expect(g.shown == "350 GB free")
    g.frame.size.width = 70
    #expect(g.shown == "350 GB", "short of room: the figure")
    g.frame.size.width = 40
    #expect(g.shown == "", "less: the bar alone")
    #expect(r.toolTip == "/Volumes/USB · 110 GB used of 460 GB · 350 GB free")

    let row = HoverRowView()
    row.addSubview(r)
    row.isEmphasized = true
    row.isSelected = true
    #expect(color() == .alternateSelectedControlTextColor, "white on the accent")
    row.isSelected = false
    #expect(color() == Palette.secondary)

    let none = try volumeRow(VolumeRow(path: "/Volumes/S", name: "S", ejectable: true))
    #expect(!none.arrangedSubviews.contains { $0 is VolumeGauge } && none.toolTip == "/Volumes/S")
}

/// The bar turns amber at 85 % full and red at 95 %: red only once it's trouble.
@Test func aVolumeBarTurnsAmberThenRed() {
    #expect(VolumeGauge.tone(0) == nil && VolumeGauge.tone(0.849) == nil)
    #expect(VolumeGauge.tone(0.85) == Palette.warn && VolumeGauge.tone(0.949) == Palette.warn)
    #expect(VolumeGauge.tone(0.95) == Palette.fail && VolumeGauge.tone(1) == Palette.fail)
    #expect(SidebarModel.row(Volume(path: "/", name: "HD", free: 30, total: 200, ejectable: false)).fraction == 0.85)
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

/// V3–V5: one not mounted has Mount (button and menu); a disk's mounted volume Unmount and Eject; a disk image's or a
/// share's Eject alone (unmounted, it couldn't be mounted again here); while one is under way, a spinner in the
/// button's place and nothing to choose.
@MainActor @Test func aVolumeRowOffersMountUnmountEject() throws {
    let stick = Disk(bsd: "disk9s2", name: "STICK", format: "ExFAT", size: 0, mountPath: nil)
    let usb = Disk(bsd: "disk7s1", name: "USB", format: "APFS", size: 0, mountPath: "/Volumes/USB")
    let c = SidebarController()
    var asked: [(String, VolumeAction)] = []
    c.onVolume = { asked.append(($0.name, $1)) }
    let vols = [Volume(path: "/", name: "HD", free: 1, total: 2, ejectable: false),
                Volume(path: "/Volumes/USB", name: "USB", free: 1, total: 2, ejectable: true),
                Volume(path: "/Volumes/IMG", name: "IMG", free: 1, total: 2, ejectable: true)]
    func rows(busy: Set<String> = []) -> [VolumeRow] {
        let s = SidebarModel.sections(bookmarks: [], frecent: [], volumes: vols, disks: [stick, usb], busy: busy, servers: ServerList(), tags: [])
        c.show(s)
        return s[2].places.compactMap { if case .volume(let v) = $0 { v } else { nil } }
    }
    let r = rows()
    #expect(r.map(\.actions) == [[], [.unmount, .eject], [.eject], [.mount]])
    func button(_ v: VolumeRow) throws -> NSButton? { try volumeRow(v, in: c).arrangedSubviews.compactMap { $0 as? NSButton }.first }
    #expect(try button(r[0]) == nil)
    let mount = try #require(try button(r[3]))
    #expect(mount.image?.accessibilityDescription == "Mount" && mount.toolTip == "Mount “STICK”")
    func click(_ b: NSButton) { NSApp.sendAction(b.action!, to: b.target, from: b) }
    click(mount)
    let eject = try #require(try button(r[1]))
    #expect(eject.image?.accessibilityDescription == "Eject")
    click(eject)
    #expect(asked.map(\.0) == ["STICK", "USB"] && asked.map(\.1) == [.mount, .eject])

    let busy = rows(busy: ["/Volumes/USB", "disk9s2"])
    #expect(busy[1].busy && busy[3].busy && !busy[2].busy)
    #expect(busy[1].actions.isEmpty && busy[3].actions.isEmpty)
    for v in [busy[1], busy[3]] {
        let view = try volumeRow(v)
        #expect(view.arrangedSubviews.contains { $0 is NSProgressIndicator } && !view.arrangedSubviews.contains { $0 is NSButton })
    }
    // A button drawn before the work began asks nothing while it's under way.
    click(eject)
    #expect(asked.count == 2)
}

/// ⌘⇧P has Unmount next to Eject; behind a server panel neither acts on the local folder there.
@MainActor @Test func unmountIsACommandForThisMac() {
    let c = AppDelegate().makeCommands().first { $0.id == "file.unmount" }
    #expect(c?.title == "Unmount Volume" && c?.menu == "File")
    #expect(AppDelegate.localOnly.isSuperset(of: ["file.unmount", "file.eject"]))
}
