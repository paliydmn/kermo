import AppKit
import DFMCore

/// One result of the search (⇧⌘P).
struct SearchHit: Equatable {
    enum Target: Equatable {
        case command(String)
        case folder(String)
        case server(String)        // its address (`ServerRow.address`)
        case place(server: String, row: String)   // a row of a server's place: "Services" of "web-01"
        case file(String)          // in the active panel
        case disk(String)          // "Search “q” on disk…" → ⌘F dialog

        /// How the search history keeps it ("folder:/var/log"); nil for a name in the panel — gone once the panel moves on.
        var key: String? {
            switch self {
            case .command(let id): "command:" + id
            case .folder(let p): "folder:" + p
            case .server(let s): "server:" + s
            case .place(let s, let row): "place:" + s + " " + row   // an address has no space
            case .disk(let q): "disk:" + q
            case .file: nil
            }
        }

        /// A bare id is a command: the history kept nothing else before.
        init(key: String) {
            guard let i = key.firstIndex(of: ":") else { self = .command(key); return }
            let rest = String(key[key.index(after: i)...])
            switch key[..<i] {
            case "command": self = .command(rest)
            case "folder": self = .folder(rest)
            case "server": self = .server(rest)
            case "place":
                let (s, row) = rest.firstIndex(of: " ").map { (String(rest[..<$0]), String(rest[rest.index(after: $0)...])) } ?? (rest, "")
                self = .place(server: s, row: row)
            case "disk": self = .disk(rest)
            default: self = .command(key)
            }
        }
    }
    let title: String
    var subtitle = ""
    var detail = ""                // a command's first key (its capsule); "favorite", "volume": a folder's kind
    let target: Target
    var removable = false          // a Recent row: ✕ and ⌘⌫ take it out of the history
}

/// Commands (by title, key label and aliases: "zip" → Compress), servers, rows of servers' places ("Services —
/// web-01"), folders, then files in the active panel. Fuzzy-ranked inside each group; equal scores keep source order
/// (favorites before frecency before volumes…).
enum HeaderSearchModel {
    static let perGroup = 8
    static let recentMax = 10

    /// `recent`: history keys, the most used and lately first. `cancel`: a query typed on since stops ranking a big
    /// folder's names (looked at every 1024).
    static func results(_ query: String, commands: [Command], folders: [SearchHit], servers: [SearchHit] = [], places: [SearchHit] = [],
                        files: [String], recent: [String], cancel: CancelFlag? = nil) -> [(group: String, hits: [SearchHit])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let cmds = commands.filter { $0.id != "app.palette" && !$0.hidden }
        func hit(_ c: Command) -> SearchHit {   // one key: the menu's; F1 and the row's tooltip have the rest
            SearchHit(title: c.title, subtitle: c.menu?.replacingOccurrences(of: "/", with: " ▸ ") ?? "", detail: c.keys.first?.display ?? "", target: .command(c.id))
        }
        func disk(_ q: String) -> SearchHit { SearchHit(title: "Search “\(q)” on disk…", detail: "⌘F", target: .disk(q)) }
        if q.isEmpty {
            // Folders and servers come back as the search lists them now; what it no longer lists (a gone command) is left out.
            let r = recent.map(SearchHit.Target.init(key:)).compactMap { t -> SearchHit? in
                switch t {
                case .command(let id): cmds.first { $0.id == id }.map(hit)
                case .disk(let q): disk(q)
                default: (folders + servers + places).first { $0.target == t }
                }
            }.prefix(recentMax).map { var h = $0; h.removable = true; return h }
            let fav = folders.filter { f in f.detail == "favorite" && !r.contains { $0.target == f.target } }
            let srv = servers.filter { s in !r.contains { $0.target == s.target } }.prefix(perGroup)
            return [("Recent", Array(r)), ("Favorites", fav), ("Servers", Array(srv))].filter { !$0.1.isEmpty }
        }
        func ranked<T>(_ items: [T], _ score: (T) -> Int?) -> [T] {
            var hits: [(Int, Int, T)] = []
            for (i, it) in items.enumerated() {
                if i & 1023 == 0, cancel?.isCancelled == true { return [] }
                if let s = score(it) { hits.append((s, i, it)) }
            }
            return hits.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.prefix(perGroup).map(\.2)
        }
        let groups: [(String, [SearchHit])] = [
            ("Commands", ranked(cmds) { c in [c.title, c.short, c.aliases].compactMap { Fuzzy.score(q, $0) }.max() }.map(hit)),
            ("Servers", ranked(servers) { Fuzzy.score(q, $0.title).map { $0 + 50 } ?? Fuzzy.score(q, $0.subtitle) }),
            ("On Servers", ranked(places) { Fuzzy.score(q, $0.title) }),
            ("Folders", ranked(folders) { Fuzzy.score(q, $0.title).map { $0 + 50 } ?? Fuzzy.score(q, $0.subtitle) }),
            ("In This Panel", ranked(files) { Fuzzy.score(q, $0) }.map { SearchHit(title: $0, target: .file($0)) }),
        ]
        let found = groups.filter { !$0.1.isEmpty }
        var last = disk(q)
        if found.isEmpty { last.subtitle = "Nothing matches “\(q)”" }
        return found + [("", [last])]
    }
}

/// The search (⌘⇧P, F9, the toolbar's button): the palette — a Picker, narrower, its rows in groups ranked off the
/// main thread once typing pauses. ↑↓ choose, ↩ runs / opens, ⌘↩ opens a folder, a server's files or its list in the
/// other panel, ⇥ goes into a server, its lists, a row's actions; ⌫ (on an empty field) and ⎋ come back, ⎋ on top
/// closes. Empty, it lists what's chosen most and lately; ✕ or ⌘⌫ takes a row out of that.
@MainActor
final class HeaderSearch: NSObject {
    let item = NSToolbarItem(itemIdentifier: .init("search"))
    /// The rows for what's typed (`HeaderSearchModel`): the ranking itself runs off the main thread, until the flag
    /// says another query took its place.
    var results: (String, CancelFlag) async -> [Picker.Item] = { _, _ in [] }
    /// ⌘↩ on a list it went into (⇥): those rows in the other panel, as they are.
    var listInOther: (@MainActor (ListSource, String, String?, [Picker.Item]) -> Void)?

    override init() {
        super.init()
        let font = NSFont.systemFont(ofSize: 12)
        let title = NSMutableAttributedString(string: "Search or jump to…  ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        title.append(KeyCap.text("⇧⌘P", font: font))
        let button = NSButton(title: "", image: Symbol.search.image("Search"), target: self, action: #selector(clicked))
        button.attributedTitle = title
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.bezelStyle = .accessoryBarAction
        button.setAccessibilityLabel("Search or jump to")
        button.widthAnchor.constraint(equalToConstant: 230).isActive = true
        item.view = button
        item.label = "Search"
        item.toolTip = "Search commands, folders, servers and files  ⇧⌘P · F9"
    }

    @objc private func clicked(_ sender: NSButton) { sender.window.map(focus) }

    /// The palette over `window`.
    @discardableResult
    func focus(over window: NSWindow) -> Picker {
        Picker.show(over: window, placeholder: "Search commands, folders, servers, files", items: [], width: 560, results: results,
                    listInOther: listInOther ?? { _, _, _, _ in })
    }
}
