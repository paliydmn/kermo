import Foundation
import Testing
@testable import DFileManager

// Task 22: a config file that can't be written is said, kept and tried again — not dropped without a word.

private func said() async { Config.flush(); await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }

@MainActor @Test func aConfigFileThatCannotBeWrittenIsSaidAndTriedAgain() async throws {
    // The config folder is made owner-only by each save: locked (uchg) it takes no new file, and shows what's in it.
    let home = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t22-" + UUID().uuidString, dir = home + "/config"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func writable(_ on: Bool) { chflags(dir, on ? 0 : UInt32(UF_IMMUTABLE)) }
    writable(false)
    var heard: [String] = []
    let was = Config.failed
    Config.failed = { if $0.contains(dir) { heard.append($0) } }
    defer { Config.failed = was; writable(true); try? FileManager.default.removeItem(atPath: home) }
    func mine() -> [String] { Config.unsaved.filter { $0.contains(dir) } }
    func read(_ name: String) -> [String: Int]? { (try? Data(contentsOf: URL(fileURLWithPath: dir + "/" + name))).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } }

    Config.save("servers.json", ["v": 1], in: dir)
    await said()
    #expect(heard.count == 1 && heard[0].contains("servers.json"), "\(heard)")
    #expect(mine().count == 1, "what quitting would lose")
    Config.save("servers.json", ["v": 2], in: dir)
    await said()
    #expect(heard.count == 1 && mine().count == 1, "said once, until it's written again")

    writable(true)
    Config.save("other.json", ["x": 1], in: dir)   // any save tries the kept one again: its latest
    await said()
    #expect(read("servers.json") == ["v": 2] && read("other.json") == ["x": 1] && mine().isEmpty)

    writable(false)
    Config.save("servers.json", ["v": 3], in: dir)
    await said()
    #expect(heard.count == 2 && mine().count == 1, "said again after a good write")
    writable(true)
    #expect(mine().isEmpty && read("servers.json") == ["v": 3], "the look before quitting tries once more")

    // Edited by hand since it failed: the user's, not written over by what was kept.
    writable(false)
    Config.save("servers.json", ["v": 4], in: dir)
    await said()
    writable(true)
    try Data(#"{"v":5}"#.utf8).write(to: URL(fileURLWithPath: dir + "/servers.json"))
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: dir + "/servers.json")
    #expect(mine().isEmpty && read("servers.json") == ["v": 5])
}
