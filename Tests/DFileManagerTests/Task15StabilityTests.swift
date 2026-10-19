import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

/// Task 15 sss-6: small stability holes — bad saved state, hostile servers, endless output.

/// T-05: a `folderSort` value Kermo didn't write (empty, a lone colon) used to trap on every visit to that folder.
@Test func aDamagedFolderSortFallsBackToName() {
    for bad in ["", ":", "::", "x", "name:", ":1", "nope:0x"] {
        let order = PanelViewController.sortOrder(bad)
        #expect(order.key == .name, "\(bad)")
    }
    #expect(PanelViewController.sortOrder(nil) == (.name, true))
    #expect(PanelViewController.sortOrder("") == (.name, true))
    #expect(PanelViewController.sortOrder("size:0") == (.size, false))
    #expect(PanelViewController.sortOrder("mtime:1") == (.mtime, true))
    #expect(PanelViewController.sortOrder("mtime") == (.mtime, true))
}

/// T-04: a server can say any size; two files of `Int64.max` marked (or listed) trapped the status line's sum.
@Test func twoHugeSizesDontOverflowTheStatusLine() {
    let huge = FileItem(name: "a", kind: .file, size: .max, mtime: 0, mode: 0o644, flags: 0)
    let other = FileItem(name: "b", kind: .file, size: .max, mtime: 0, mode: 0o644, flags: 0)
    let dir = FileItem(name: "d", kind: .dir, size: 0, mtime: 0, mode: 0o755, flags: 0)
    #expect(PanelViewController.bytes(of: [huge, other], dirSizes: [:]) == .max)
    #expect(PanelViewController.bytes(of: [huge, dir], dirSizes: ["d": .max]) == .max)
    #expect(PanelViewController.bytes(of: [dir], dirSizes: ["d": 5]) == 5)
}
