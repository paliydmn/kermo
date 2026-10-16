import Foundation
import DFMCore

/// What a restart brings back (`panelSession` in defaults): each panel's tabs, a server tab as its server and folder
/// (shown not connected till ↩: `PanelViewController.parked`), the cursor by name, the active panel and the dividers.
struct Session: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var path: String   // the local folder; a server tab goes back to it when it leaves the server
        var cursor: String? = nil
        var server: SFTPTarget? = nil
        /// A root panel's: `SFTPTarget` never decodes root, so it's said here — and only ↩ on the tab connects as root.
        var root = false
        var dir: String? = nil   // on `server`
    }
    struct Panel: Codable, Equatable {
        var tabs: [Tab]
        var index: Int
    }
    var panels: [Panel]
    var active = 0
    /// Each divider's place, a fraction of the panels' width.
    var dividers: [Double] = []

    /// The saved one; before it, `panelTabs` / `panelTabIndex` (local folders only), before them `panelPaths`.
    static func load(_ d: UserDefaults) -> Session {
        if let data = d.data(forKey: "panelSession"), let s = try? JSONDecoder().decode(Session.self, from: data), !s.panels.isEmpty { return s }
        let legacy = d.stringArray(forKey: "panelPaths")?.map { [$0] }
        let tabs = (d.array(forKey: "panelTabs") as? [[String]]) ?? legacy ?? [[NSHomeDirectory()], ["/"]]
        let indices = d.array(forKey: "panelTabIndex") as? [Int] ?? [0, 0]
        return Session(panels: tabs.enumerated().map { i, t in
            Panel(tabs: t.map { Tab(path: $0) }, index: indices.indices.contains(i) ? indices[i] : 0)
        })
    }

    func save(_ d: UserDefaults) {
        d.set(try? JSONEncoder().encode(self), forKey: "panelSession")
        // As before too: an older Kermo started after this one finds its folders.
        d.set(panels.map { $0.tabs.map(\.path) }, forKey: "panelTabs")
        d.set(panels.map(\.index), forKey: "panelTabIndex")
    }

    /// Where `count` panels' dividers go: as saved if that's a sane set for them, else evenly.
    static func dividers(_ saved: [Double], panels count: Int) -> [Double] {
        let even = (1..<count).map { Double($0) / Double(count) }
        guard saved.count == count - 1, zip([0] + saved, saved + [1]).allSatisfy({ $1 - $0 >= 0.05 }) else { return even }
        return saved
    }
}
