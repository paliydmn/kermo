import Foundation
@testable import DFMCore
import Testing

// I4: permissions and owners — shown in the panel, changed with chmod / chown locally and over SFTP.

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-i4-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir + "/f", contents: Data("x".utf8))
    return dir
}

private func lstatMode(_ p: String) -> (mode: UInt32, uid: UInt32, gid: UInt32) {
    var s = stat()
    lstat(p, &s)
    return (UInt32(s.st_mode) & 0o7777, s.st_uid, s.st_gid)
}

@Test func permissionLettersLikeLs() {
    let cases: [(UInt32, String)] = [(0o755, "rwxr-xr-x"), (0o644, "rw-r--r--"), (0o4755, "rwsr-xr-x"), (0o2644, "rw-r-Sr--"),
                                     (0o1777, "rwxrwxrwt"), (0o1000, "--------T"), (0o40750, "rwxr-x---")]
    for (mode, text) in cases {
        #expect(Perms.string(mode) == text)
    }
}

@Test func attributesTextParses() {
    func parsed(_ s: String) -> String { let p = Perms.parse(s); return (p.mode.map { String($0, radix: 8) } ?? "-") + "|" + p.owner }
    #expect(parsed("644 dmn:staff") == "644|dmn:staff" && parsed(" 0755 ") == "755|" && parsed(":wheel") == "-|:wheel")
    #expect(parsed("644 dmn:domain users") == "644|dmn:domain users", "an AD group's name has spaces")
    #expect(parsed("") == "-|" && parsed("dmn") == "-|dmn" && parsed("999") == "-|999", "not octal: an owner")

    #expect(Perms.ids("501:20", names: false).map { [$0.uid, $0.gid] } == [501, 20])
    #expect(Perms.ids("root", names: true).map { [$0.uid, $0.gid] } == [0, nil])
    #expect(Perms.ids(":wheel", names: true).map { [$0.uid, $0.gid] } == [nil, 0])
    #expect(Perms.ids("root", names: false) == nil, "a server's names aren't this Mac's")
    #expect(Perms.ids("dfm-no-such-user", names: true) == nil)
    #expect(Perms.ids("\(FileItem.unknown)", names: false) == nil, "-1 means leave as is: not an id to type")
}

@Test func localListingCarriesOwners() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let s = lstatMode(dir + "/f")
    let f = try #require(try DirLister.list(dir).first { $0.name == "f" })
    #expect(f.uid == s.uid && f.gid == s.gid && f.mode & 0o7777 == s.mode)
}

@Test func chmodChownLocallyNeverThroughALink() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir + "/f")
    chmod(dir + "/f", 0o644)
    #expect(Perms.apply([dir + "/link"], mode: 0o600, uid: nil, gid: nil).isEmpty)
    #expect(lstatMode(dir + "/f").mode == 0o644, "the link changed, not its target")
    #expect(Perms.apply([dir + "/f"], mode: 0o640, uid: getuid(), gid: nil).isEmpty)
    #expect(lstatMode(dir + "/f").mode == 0o640)
    if getuid() != 0 {
        let errors = Perms.apply([dir + "/f"], mode: nil, uid: 0, gid: nil)
        #expect(errors.count == 1 && errors[0].hasPrefix("“f”: "), "giving a file away needs root")
    }
}

@Test func chmodChownOverSFTP() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let c = try SFTPClient(.local())
    defer { c.close() }
    let me = lstatMode(dir + "/f")
    try c.setAttrs(dir + "/f", mtime: nil, mode: 0o604, owner: (me.uid, me.gid))
    #expect(lstatMode(dir + "/f") == (0o604, me.uid, me.gid))
    try c.setAttrs(dir + "/f", mtime: nil, mode: nil, owner: (FileItem.unknown, FileItem.unknown))   // unknown: left as is
    #expect(lstatMode(dir + "/f") == (0o604, me.uid, me.gid))
    var owner = ""
    let listed = try #require(try SFTP.list(.local(), dir) { name, o, _ in if name == "f" { owner = o } }.first { $0.name == "f" })
    #expect(listed.mode & 0o7777 == 0o604)
    #expect([NSUserName(), String(me.uid)].contains(owner) && [me.uid, FileItem.unknown].contains(listed.uid))
}
