import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

/// I4: Permissions, Owner and Group columns — hidden until View ▸ Show Permissions & Owner, then kept before Size and
/// Modified when the panel is narrow; a server's owners as its listing printed them.
@MainActor @Test func permissionColumnsShowWhenAskedFor() async throws {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-i4-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/f", contents: Data())
    chmod(dir + "/f", 0o640)

    let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentViewController = panel
    defer { panel.shutdown(); window.close() }
    for _ in 0..<500 where panel.listedItems.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
    window.contentView?.layoutSubtreeIfNeeded()
    let columns = ["mode", "owner", "group"].compactMap { id in panel.table.tableColumns.first { $0.identifier.rawValue == id } }
    #expect(columns.count == 3 && columns.allSatisfy { $0.isHidden })

    panel.showPerms = true
    #expect(columns.allSatisfy { !$0.isHidden })
    func cell(_ col: NSTableColumn) -> String {
        (panel.tableView(panel.table, viewFor: col, row: 1) as? NSTableCellView)?.textField?.stringValue ?? "?"   // row 0 is ".."
    }
    var st = stat()
    lstat(dir + "/f", &st)
    #expect(cell(columns[0]) == "rw-r-----" && cell(columns[1]) == NSUserName())
    #expect(cell(columns[2]) == String(cString: getgrgid(st.st_gid).pointee.gr_name))

    panel.loadRemote(.local(), dir: dir, select: nil)
    for _ in 0..<500 where panel.remote == nil { try await Task.sleep(for: .milliseconds(10)) }
    let group = String(cString: getgrgid(st.st_gid).pointee.gr_name)
    #expect(cell(columns[0]) == "rw-r-----", "from the listing's letters (it used to say mode 0)")
    #expect([NSUserName(), String(getuid())].contains(cell(columns[1])) && [group, String(st.st_gid)].contains(cell(columns[2])),
            "as the server's listing printed them: its names, or its numbers — never this Mac's names for its numbers")

    panel.showPerms = false
    #expect(columns.allSatisfy { $0.isHidden })
}
