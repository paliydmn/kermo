import Foundation
import Testing
@testable import DFileManager

// Editor E6 PR 2: one rename on this Mac for the panel's ⇧F6 and an editor tab's — never over anything there.

/// A taken name is said and nothing moves; a file appearing between the look and the rename stays, nothing renamed;
/// a name in another case is the item itself; "/", ".", "..", NUL aren't names; a link is renamed itself; a folder
/// that isn't ours to write says so.
@Test func aRenameOnThisMacNeverReplacesAnything() throws {
    let fm = FileManager.default
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-rename-" + UUID().uuidString
    try fm.createDirectory(atPath: dir + "/ro", withIntermediateDirectories: true)
    defer { chmod(dir + "/ro", 0o755); try? fm.removeItem(atPath: dir) }
    func put(_ s: String, _ name: String) { fm.createFile(atPath: dir + "/" + name, contents: Data(s.utf8)) }
    func text(_ name: String) -> String? { fm.contents(atPath: dir + "/" + name).map { String(decoding: $0, as: UTF8.self) } }
    func why(_ name: String, from: String = "a.conf", willRename: (String) -> Void = { _ in }) -> String? {
        do { _ = try AppDelegate.rename(dir + "/" + from, to: name, willRename: willRename); return nil } catch { return error.localizedDescription }
    }
    put("a", "a.conf")
    put("b", "b.conf")

    #expect(why("b.conf") == "“b.conf” already exists — nothing was renamed." && text("a.conf") == "a" && text("b.conf") == "b")
    #expect(why("c.conf") { _ in put("other", "c.conf") } == "“c.conf” appeared there meanwhile — nothing was renamed.")
    #expect(text("a.conf") == "a" && text("c.conf") == "other", "the one that appeared stays as it came")
    for bad in ["x/y", ".", "..", "a\0b"] { #expect(why(bad) != nil && text("a.conf") == "a", "\(bad)") }

    #expect(try AppDelegate.rename(dir + "/a.conf", to: "d.conf") == dir + "/d.conf" && text("d.conf") == "a" && text("a.conf") == nil)
    #expect(try AppDelegate.rename(dir + "/d.conf", to: "D.conf") == dir + "/D.conf", "only its case")
    #expect(try fm.contentsOfDirectory(atPath: dir).contains("D.conf") && text("D.conf") == "a")

    link(dir + "/D.conf", dir + "/hard")
    #expect(why("hard", from: "D.conf") == "“hard” already exists — nothing was renamed.", "a hard link of it is another name, not itself")
    try fm.createSymbolicLink(atPath: dir + "/link", withDestinationPath: "D.conf")
    _ = try AppDelegate.rename(dir + "/link", to: "link2")
    #expect(try fm.destinationOfSymbolicLink(atPath: dir + "/link2") == "D.conf" && text("D.conf") == "a", "the link, not what it points to")

    put("r", "ro/f")
    chmod(dir + "/ro", 0o555)
    #expect(why("g", from: "ro/f") == "No permission to rename “f” in “ro”." && text("ro/f") == "r")
    #expect(why("h", from: "gone") != nil)
}
