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
