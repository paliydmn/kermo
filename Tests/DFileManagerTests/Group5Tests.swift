import AppKit
import Testing
@testable import DFileManager

/// What group 5's hand checks (2026-11-28) found in the running app.
@MainActor @Suite struct Group5Tests {
    /// D-200: the icon took a row's spare width, pushing the name to the right; deep rows went past the panel's edge;
    /// the panel was light over a dark Kermo.
    @Test func folderTreeRowsPutTheNameNextToItsIconAndStayInside() async throws {
        let top = ((NSTemporaryDirectory() as NSString).resolvingSymlinksInPath as NSString).appendingPathComponent("kermo-tree-\(UUID().uuidString.prefix(8))")
        let deep = top + (0..<4).map { "/a-folder-with-a-rather-long-name-at-level-\($0)" }.joined()
        try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: top) }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        defer { w.childWindows?.forEach { $0.orderOut(nil) }; w.orderOut(nil) }
        DirTree.show(in: w, over: try #require(w.contentView), at: deep, showHidden: true) { _ in }   // showHidden: /private is hidden in /
        let panel = try #require(w.childWindows?.last)
        #expect(panel.appearance?.name == .darkAqua)
        let outline = try #require((panel.contentView as? NSScrollView)?.documentView as? NSOutlineView)
        let levels = deep.split(separator: "/").count
        for _ in 0..<300 where (0..<outline.numberOfRows).allSatisfy({ outline.level(forRow: $0) < levels }) { try? await Task.sleep(for: .milliseconds(10)) }
        panel.contentView?.layoutSubtreeIfNeeded()
        let row = try #require((0..<outline.numberOfRows).last { outline.level(forRow: $0) == levels })   // the deepest
        let clip = try #require(outline.enclosingScrollView).contentView.bounds.width
        #expect((clip - 30...clip).contains(outline.tableColumns[0].width))   // the view's width, less the cell spacing
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        cell.layoutSubtreeIfNeeded()
        let icon = try #require(cell.imageView), name = try #require(cell.textField)
        #expect(icon.frame.width == 16)
        #expect((icon.frame.maxX...icon.frame.maxX + 6).contains(name.frame.minX))   // right after the icon
        #expect(cell.convert(name.frame, to: outline).maxX <= clip + 1)   // cut at the edge, not past it
    }

    /// D-074: FAT32 and exFAT say 0 for "important usage" free space; the sidebar showed "0 KB free" and a full red bar.
    @Test func aVolumeSayingZeroImportantFreeShowsTheKernelsFigure() {
        let m = SidebarModel.Mount(path: "/Volumes/STICK", type: "exfat", local: true, free: 62_000_000, total: 66_000_000)
        #expect(SidebarModel.freeSpace(important: 0, m) == 62_000_000)
        #expect(SidebarModel.freeSpace(important: nil, m) == 62_000_000)
        #expect(SidebarModel.freeSpace(important: 5_000, m) == 5_000)   // APFS: what it would purge counts
        let gone = SidebarModel.Mount(path: "/nonexistent-kermo-test", type: "msdos", local: true, free: 7, total: 9)
        #expect(SidebarModel.volumes([gone]).first?.free == 7)   // can't be read: the kernel's figures still
    }
}
