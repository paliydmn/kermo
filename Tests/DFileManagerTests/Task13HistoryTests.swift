import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 13: server file history and diff with a server.

/// Saves keep versions in ~/.config/dfilemanager/history.noindex (Spotlight stays out by the name) unless
/// `defaults write com.dmn.dfilemanager serverHistory -bool false`.
@MainActor @Test func serverHistoryCanBeTurnedOff() {
    let app = AppDelegate()
    let was = UserDefaults.standard.object(forKey: "serverHistory")
    defer { UserDefaults.standard.set(was, forKey: "serverHistory") }
    UserDefaults.standard.removeObject(forKey: "serverHistory")
    #expect(app.serverHistory?.root == AppDelegate.historyRoot && AppDelegate.historyRoot == Config.path("history.noindex"))
    UserDefaults.standard.set(false, forKey: "serverHistory")
    #expect(app.serverHistory == nil)
}

/// Compare Files' pair, three rules in order: two marked files; the cursor's and the same name in the other panel's
/// folder, if it's there; the cursor's and the other panel's cursor's.
@MainActor @Test func diffPairRules() async {
    var asked: [String] = []
    func pair(_ marked: [String], _ cursor: String?, _ same: String?, _ other: String?, there: Bool = true) async -> [String]? {
        await AppDelegate.diffPair(marked: marked, cursor: cursor, sameName: same, otherCursor: other) { asked.append($0); return there }.map { [$0, $1] }
    }
    #expect(await pair(["m1", "m2"], "c", "s", "o") == ["m1", "m2"] && asked.isEmpty, "two marked: nothing looked at")
    #expect(await pair(["m1", "m2", "m3"], "c", "s", "o") == ["c", "s"] && asked == ["s"], "three: the cursor's rules")
    #expect(await pair(["c"], "c", "s", "o", there: false) == ["c", "o"], "no such name next door: the other cursor")
    #expect(await pair([], "c", nil, "o") == ["c", "o"], "the other panel isn't a folder here")
    asked = []
    #expect(await pair([], nil, nil, "o") == nil && asked.isEmpty, "no file under the cursor")
    #expect(await pair(["c"], "c", "s", nil, there: false) == nil)
}
