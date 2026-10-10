import Foundation
import Testing
@testable import DFMCore

@Test func fuzzyMatchesSubsequences() {
    #expect(Fuzzy.score("dwn", "Downloads") != nil)
    #expect(Fuzzy.score("xyz", "Downloads") == nil)
    #expect(Fuzzy.score("", "anything") == 0)
    #expect(Fuzzy.score("копі", "Копіювати файли") != nil)
}

@Test func fuzzyPrefersWordStartsAndRuns() {
    // "cp" should rank "Copy Path" (two word starts) above "Compress" (scattered).
    #expect(Fuzzy.score("cp", "Copy Path")! > Fuzzy.score("cp", "Compress")!)
    // A contiguous run beats the same letters spread out.
    #expect(Fuzzy.score("log", "/var/log")! > Fuzzy.score("log", "/usr/local/opt/go")!)
}

@Test func frecencyPrefersRecentAndFrequent() {
    var f = Frecency()
    let now = 1_000_000_000.0
    f.visit("/old", now: now - 30 * 86400)
    for _ in 0..<3 { f.visit("/old", now: now - 30 * 86400) }
    f.visit("/new", now: now - 60)
    #expect(f.ranked(now: now) == ["/new", "/old"])   // 1 visit × 4 beats 4 visits × 0.25
    for _ in 0..<20 { f.visit("/old", now: now - 30 * 86400) }
    #expect(f.ranked(now: now).first == "/old")
    f.remove("/old")
    #expect(f.ranked(now: now) == ["/new"])
}

@Test func frecencyAgesOutRareEntries() {
    var f = Frecency()
    f.visit("/rare", now: 0)
    for _ in 0..<5001 { f.visit("/hot", now: 0) }
    #expect(f.entries["/rare"] == nil)
    #expect(f.entries["/hot"] != nil)
}

@Test func fuzzyScoringDetails() {
    #expect(Fuzzy.score("c p", "Copy Path") == Fuzzy.score("cp", "Copy Path"))   // spaces in the query are ignored
    #expect(Fuzzy.score("CP", "copy path") == Fuzzy.score("cp", "Copy Path"))   // case-insensitive both ways
    #expect(Fuzzy.score("abcd", "abc") == nil)
    #expect(Fuzzy.score("a", "") == nil)
    #expect(Fuzzy.score("ab", "ab")! > Fuzzy.score("ab", "abc")!)               // shorter candidate wins
    #expect(Fuzzy.score("ba", "ab") == nil)                                    // order matters
    for sep in ["/", " ", "_", "-", "."] {
        #expect(Fuzzy.score("b", "a\(sep)b")! > Fuzzy.score("b", "ab")!, "word start after \(sep)")
    }
    // Picks the best placement, not the first: "do" in "d.../Downloads" should use the word start.
    #expect(Fuzzy.score("do", "d/Downloads")! > Fuzzy.score("do", "d/xDoxwnloads")!)
}

@Test func frecencyWeightsAndPersistence() throws {
    var f = Frecency()
    let now = 1_000_000.0
    f.visit("/a", now: now)
    #expect(f.rank("/a", now: now) == 4)
    #expect(f.rank("/a", now: now + 3600) == 2)
    #expect(f.rank("/a", now: now + 86400) == 0.5)
    #expect(f.rank("/a", now: now + 604800) == 0.25)
    #expect(f.rank("/never", now: now) == 0)
    f.visit("/a", now: now + 10)
    #expect(f.entries["/a"]?.count == 2 && f.entries["/a"]?.last == now + 10)

    let data = try JSONEncoder().encode(f)   // what frecency.json holds
    let back = try JSONDecoder().decode(Frecency.self, from: data)
    #expect(back.ranked(now: now) == ["/a"] && back.entries["/a"]?.count == 2)
    #expect(Frecency().ranked().isEmpty)
}
