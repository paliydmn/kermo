import Foundation
import Testing
@testable import DFMCore
@testable import DFileManager

// servers.json: keys this Kermo doesn't know stay (D-118); a hand edit while Kermo runs is read before its next save,
// and one that can't be read isn't saved over (D-044).

@Test func keysKermoDoesntKnowStay() throws {
    let file = #"[{"host": "web", "prod": true, "future": {"a": [1, "x"]}, "tools.x": "y"}]"#
    var kept = try JSONDecoder().decode([KeptServer].self, from: Data(file.utf8))
    #expect(kept[0].unknown == ["future": .object(["a": .array([.number(1), .string("x")])]), "tools.x": .string("y")])
    kept[0].server.prod = false
    kept[0].server.port = 2222
    let back = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(kept)) as? [[String: Any]])
    #expect(back[0]["tools.x"] as? String == "y" && (back[0]["future"] as? [String: Any])?["a"] as? [AnyHashable] == [1, "x"])
    #expect(back[0]["prod"] as? Bool == false && back[0]["port"] as? Int == 2222 && back[0]["host"] as? String == "web")   // Kermo's own win
}

@Test func aFileChangedOutsideKermoIsSeen() throws {
    let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("kermo-outside-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    #expect(!Config.changedOutside("s.json", in: dir))   // none there, none known
    Config.save("s.json", [1], in: dir)
    #expect(!Config.changedOutside("s.json", in: dir))
    try Data("[2]".utf8).write(to: URL(fileURLWithPath: dir + "/s.json"))
    #expect(Config.changedOutside("s.json", in: dir))
    _ = Config.loadKeeping("s.json", as: [Int].self, in: dir)
    #expect(!Config.changedOutside("s.json", in: dir))
    chmod(dir, 0o500)   // a write that fails: the file is still what Kermo saw, not a hand edit to read back
    Config.save("s.json", [3], in: dir)
    #expect(!Config.changedOutside("s.json", in: dir))
    chmod(dir, 0o700)
    Config.save("s.json", [2], in: dir)   // written: nothing left to try again
    #expect(!Config.changedOutside("s.json", in: dir))
    Config.distrust("s.json", in: dir)
    #expect(Config.changedOutside("s.json", in: dir))
    try FileManager.default.removeItem(atPath: dir + "/s.json")
    #expect(!Config.changedOutside("s.json", in: dir), "gone: Kermo writes it again")
}

/// With no unknown keys the file is what Kermo wrote before, byte for byte — what a downgraded Kermo reads.
@MainActor @Test func aServerWithNothingUnknownIsWrittenAsBefore() throws {
    let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("kermo-kept-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var s = SavedServer(address: "deploy@web:2222/srv")!
    (s.name, s.identityFile, s.locked, s.prod, s.readOnly, s.installs) = ("Web", "~/.ssh/id", true, true, true, false)
    (s.tunnels, s.sites) = ([Tunnel(name: "DB", localPort: 15432, port: 5432, url: "http://x", on: true)], ["https://example.com"])
    Config.save("a.json", [s], in: dir)
    Config.save("b.json", [KeptServer(server: s, unknown: [:])], in: dir)
    Config.flush()
    let a = try Data(contentsOf: URL(fileURLWithPath: dir + "/a.json")), b = try Data(contentsOf: URL(fileURLWithPath: dir + "/b.json"))
    let back = try JSONDecoder().decode([SavedServer].self, from: b)
    #expect(a == b && back == [s])
}

/// No await in it: no other test's save of the same file comes in between.
@MainActor @Test func aHandEditWhileKermoRunsIsntSavedOver() throws {
    let path = Config.path("servers.json"), url = URL(fileURLWithPath: path)
    defer { ["", ".broken"].forEach { try? FileManager.default.removeItem(atPath: path + $0) } }
    func saved() throws -> [[String: Any]] {
        Config.flush()
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    }
    let app = AppDelegate(), a = SavedServer(address: "a")!
    app.editServers { $0 = [a] }
    Config.flush()   // its folder made
    try Data(#"[{"id": "\#(a.id)", "host": "a"}, {"host": "b", "note": "mine"}]"#.utf8).write(to: url)   // by hand
    app.editServers { all in all.indices.forEach { all[$0].prod = all[$0].host == "a" } }
    var file = try saved()
    #expect(file.map { $0["host"] as? String } == ["a", "b"] && file[0]["prod"] as? Bool == true && file[1]["note"] as? String == "mine")

    try Data("[{".utf8).write(to: url)   // half typed
    #expect(!app.editServers { $0.removeAll() })
    Config.flush()
    #expect(try Data(contentsOf: url) == Data("[{".utf8))
    #expect(app.savedServers.map(\.host) == ["a", "b"], "nothing changed in Kermo either")

    try Data(#"[{"host": "u"}]"#.utf8).write(to: url)
    chmod(path, 0o000)   // root's after a sudo edit, say: not read, not saved over
    #expect(!app.editServers { $0.removeAll() })
    Config.flush()
    chmod(path, 0o600)
    #expect(try Data(contentsOf: url) == Data(#"[{"host": "u"}]"#.utf8))

    try Data(#"[{"host": "c"}]"#.utf8).write(to: url)   // fixed: read again before the next change, and saved
    app.editServers { all in all.indices.forEach { all[$0].prod = true } }
    file = try saved()
    #expect(app.savedServers.map(\.host) == ["c"] && file.count == 1 && file[0]["prod"] as? Bool == true)
}

/// A file with an error at launch isn't saved over either: its servers that read are shown, nothing is written.
@MainActor @Test func aFileWithAnErrorAtLaunchIsntSavedOver() throws {
    let path = Config.path("servers.json"), url = URL(fileURLWithPath: path), bad = Data(#"[{"host": "a"}, {"port": 1}]"#.utf8)
    defer { ["", ".broken"].forEach { try? FileManager.default.removeItem(atPath: path + $0) } }
    try FileManager.default.createDirectory(atPath: Config.dir, withIntermediateDirectories: true)
    try bad.write(to: url)
    let app = AppDelegate()
    #expect(app.savedServers.map(\.host) == ["a"])
    #expect(!app.editServers { $0.removeAll() })
    Config.flush()
    #expect(try Data(contentsOf: url) == bad)
}
