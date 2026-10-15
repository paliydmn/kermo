import Foundation
import Testing
@testable import DFMCore

// Task 13 §8.4: local long operations.

/// Firmlinks (`/Users`) aren't mount points, so a walk of `/` goes through them; /System/Volumes/Data is one
/// (with `/`'s own device, which is why it used to be counted twice), and so is /dev.
@Test func theListingSaysWhatIsMounted() throws {
    var root: [String: Bool?] = [:], volumes: [String: Bool?] = [:]
    try DirLister.each("/") { root[$0.name] = $1 }
    try DirLister.each("/System/Volumes") { volumes[$0.name] = $1 }
    #expect(root["Users"] == .some(false))
    #expect(root["dev"] == .some(true))
    #expect(volumes["Data"] == .some(true))
    #expect(try DirLister.list("/").count == root.count)
}

/// The RAM disk test.sh makes, if it's there: a mount point whose parent (/Volumes) is on this Mac's own volume.
/// Mounting an image for a test asks for Touch ID on macOS 27, so the tests use the one already mounted.
private let ramDisk = "/Volumes/KermoRAM"
private var ramDiskMounted: Bool {
    var mounted = false
    try? DirLister.each("/Volumes") { if $0.name == "KermoRAM" { mounted = $1 == true } }
    return mounted && access(ramDisk, W_OK) == 0
}

@Suite(.enabled(if: ramDiskMounted)) struct MountPointTests {
    /// A walk of /Volumes neither counts nor searches the volumes mounted there, as before.
    @Test func mountedVolumesAreNotCrossed() {
        #expect(DirLister.measure("/Volumes").bytes < 1 << 20)
        var found: [String] = []
        var q = SearchQuery(root: "/Volumes")
        q.includeHidden = true
        FileSearch.run(q, isCancelled: { found.count > 10_000 }) { found.append($0.name) }
        #expect(!found.contains { $0.hasPrefix("KermoRAM/") })
    }
}
