import AppKit
import DFMCore

/// A bookmarks.json entry: a local folder ("/…"), or a folder on a server written scp-style — "me@web:/var/log",
/// "me@web:2222:/srv", "[fe80::1]:/etc" — which ServerAddress.parse reads back.
enum Bookmark {
    static func entry(_ t: SFTPTarget, _ dir: String) -> String {
        let at = t.host.lastIndex(of: "@")
        let user = at.map { String(t.host[...$0]) } ?? "", host = at.map { String(t.host[t.host.index(after: $0)...]) } ?? t.host
        return user + (host.contains(":") ? "[\(host)]" : host) + (t.port.map { ":\($0)" } ?? "") + ":" + dir
    }

    /// The server and folder of a server entry; nil for a local one (or anything without an absolute folder).
    static func remote(_ entry: String) -> (target: SFTPTarget, dir: String)? {
        guard !entry.hasPrefix("/"), case let .sftp(t, dir?)? = ServerAddress.parse(entry), dir.hasPrefix("/") else { return nil }
        return (t, dir)
    }

    /// "log" for /var/log on a server too.
    static func title(_ entry: String) -> String {
        let p = remote(entry)?.dir ?? entry
        return p == "/" ? "/" : (p as NSString).lastPathComponent
    }
}

/// A row in the sidebar.
enum Place: Equatable {
    case folder(String)                                        // Favorites, Frequent
    case serverFolder(String)                                  // a Favorite on a server (its Bookmark entry)
    case volume(path: String, name: String, free: String, ejectable: Bool)
    case server(ServerRow)
    case connect                                               // "Connect…": the picker with every server
    case tagColors                                             // Finder's 7 colors as one row of dots
    case tag(String)

    var path: String? {
        switch self {
        case .folder(let p), .volume(let p, _, _, _): p
        default: nil
        }
    }

    /// What bookmarks.json keeps for it.
    var bookmark: String? {
        switch self {
        case .folder(let p), .serverFolder(let p): p
        default: nil
        }
    }

    /// Whether this row is where the active panel / terminal tab is: its folder, or the server of its session.
    func stands(for key: String?) -> Bool {
        guard let key else { return false }
        if case .server(let r) = self { return r.sessions.contains { $0.id.uuidString == key } }
        return path == key
    }

    var selectable: Bool { if case .server(let r) = self { !r.sessions.isEmpty } else { bookmark != nil || path != nil } }
}

enum HostStatus: Equatable { case idle, connecting, failed(String) }

/// An SSH terminal tab or a file tab on a server.
struct ServerSession: Equatable {
    enum Kind: Equatable { case ssh, sftp }
    let id: UUID
    let kind: Kind
    let target: SFTPTarget
    var dir = ""           // SFTP folder
    var host: String { target.host }
    var running = true     // SSH: false once ssh has ended
}

/// Everything the Servers section is built from.
struct ServerList: Equatable {
    var saved: [SavedServer] = []
    var recents: [String] = []          // as typed in the Connect picker, newest first
    var config: [String] = []           // ~/.ssh/config aliases
    var pins: [String] = []             // addresses (ServerRow.address), in pin order
    var sessions: [ServerSession] = []
    var connecting: Set<String> = []    // SFTP hosts
    var errors: [String: String] = [:]  // SFTP host → last error
    var tunnels: [String: [String]] = [:]   // ServerRow.key → its tunnels listening
}

/// One server in the Servers list — saved, a ~/.ssh/config host, or an address as typed — with its open sessions.
struct ServerRow: Equatable {
    let target: SFTPTarget
    var saved: SavedServer?
    var title: String
    var pinned = false
    var sessions: [ServerSession] = []   // SSH tabs and SFTP panel tabs
    var status: HostStatus = .idle       // SFTP's last attempt
    var tunnels: [String] = []           // listening now

    /// user@host:port: pins, recents, sessions and saved servers all go by it (no port = 22, like the Keychain).
    static func key(_ t: SFTPTarget) -> String { "\(t.host):\(t.port ?? 22)" }
    var key: String { Self.key(target) }

    /// What Connect takes back (and the pins keep): "me@nas", or "ssh://me@nas:2222" with a port.
    static func address(_ t: SFTPTarget) -> String {
        guard let port = t.port else { return t.host }
        let at = t.host.lastIndex(of: "@")
        let user = at.map { String(t.host[..<$0]) + "@" } ?? ""
        let host = at.map { String(t.host[t.host.index(after: $0)...]) } ?? t.host
        return "ssh://\(user)\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }
    var address: String { Self.address(target) }

    var ssh: [ServerSession] { sessions.filter { $0.kind == .ssh } }
    var sftp: [ServerSession] { sessions.filter { $0.kind == .sftp } }
}

struct SidebarSection: Equatable {
    let id: String
    let title: String
    let command: String   // its header shows this command's key
    let places: [Place]
}

struct Volume: Equatable, Sendable {
    let path: String
    let name: String
    let free: Int64?
    let ejectable: Bool
}

/// What the sidebar shows, from data the app already keeps.
enum SidebarModel {
    static func sections(bookmarks: [String], frecent: [String], volumes: [Volume], servers: ServerList,
                         tags: [String]) -> [SidebarSection] {
        let fmt = ByteCountFormatter()
        return [
            SidebarSection(id: "fav", title: "Favorites", command: "go.bookmark",
                           places: bookmarks.map { Bookmark.remote($0) == nil ? .folder($0) : .serverFolder($0) }),
            SidebarSection(id: "freq", title: "Frequent", command: "go.jump",
                           places: frecent.filter { !bookmarks.contains($0) }.prefix(5).map(Place.folder)),
            SidebarSection(id: "loc", title: "Locations", command: "go.volumes", places: volumes.map {
                .volume(path: $0.path, name: $0.name, free: $0.free.map(fmt.string(fromByteCount:)) ?? "", ejectable: $0.ejectable)
            }),
            SidebarSection(id: "servers", title: "Servers", command: "ssh.new", places: serverRows(servers).map(Place.server) + [.connect]),
            SidebarSection(id: "tags", title: "Tags", command: "tag.edit", places: [.tagColors] + tags.map(Place.tag)),
        ]
    }

    /// SFTP's last attempt at a host: connecting, failed, or neither.
    static func hostStatus(_ host: String, _ list: ServerList) -> HostStatus {
        list.connecting.contains(host) ? .connecting : list.errors[host].map(HostStatus.failed) ?? .idle
    }

    /// Pinned ones; then the latest used (recents, open sessions), so that the list has 5 rows, or one more than the pins
    /// — there's always room for the newest. A server with open sessions is always there. Rows still free go to saved
    /// servers, then ~/.ssh/config hosts. One row per server (user@host:port); smb/nfs aren't listed.
    /// Shown in a fixed order, whatever was used last (a row that moved under the pointer once opened a root shell on
    /// the wrong server): pins in pin order, saved servers as in servers.json, ~/.ssh/config hosts as there, then
    /// addresses as typed, by name.
    static func serverRows(_ list: ServerList, places: Int = 5) -> [ServerRow] {
        func parse(_ address: String) -> SFTPTarget? {
            if case let .sftp(t, _)? = ServerAddress.parse(address) { t } else { nil }
        }
        let configTargets = list.config.compactMap(parse)
        /// A saved server's row wherever its address turns up; else a config host's; else as typed.
        func row(_ t: SFTPTarget) -> ServerRow {
            let key = ServerRow.key(t)
            let saved = list.saved.first { ServerRow.key($0.target) == key }
            let target = saved?.target ?? t
            return ServerRow(target: target, saved: saved, title: saved?.title ?? target.host,
                             pinned: list.pins.contains { parse($0).map(ServerRow.key) == key },
                             sessions: list.sessions.filter { ServerRow.key($0.target) == key },
                             status: hostStatus(target.host, list), tunnels: list.tunnels[key] ?? [])
        }
        var rows: [ServerRow] = [], seen = Set<String>()
        func add(_ t: SFTPTarget, if keep: (ServerRow) -> Bool = { _ in true }) {
            let r = row(t)
            if !seen.contains(r.key), keep(r) { seen.insert(r.key); rows.append(r) }
        }
        list.pins.compactMap(parse).forEach { add($0) }
        let room = max(places, rows.count + 1)
        (list.recents.compactMap(parse) + list.sessions.map(\.target)).forEach { add($0) { rows.count < room || !$0.sessions.isEmpty } }
        (list.saved.map(\.target) + configTargets).forEach { add($0) { _ in rows.count < room } }
        let order = (list.pins.compactMap(parse) + list.saved.map(\.target) + configTargets).map(ServerRow.key)
        func rank(_ r: ServerRow) -> Int { order.firstIndex(of: r.key) ?? order.count }
        return rows.sorted { (rank($0), $0.key) < (rank($1), $1.key) }
    }

    /// A mounted volume as the kernel last knew it (MNT_NOWAIT): a dead network mount isn't asked, so it can't hang.
    struct Mount: Sendable { let path: String, type: String, local: Bool, free: Int64, total: Int64 }

    /// Blocks × block size, capped: an exotic volume's figures could overflow Int64 (a trap, not a wrong number).
    static func bytes(_ blocks: UInt64, _ size: UInt32) -> Int64 {
        let (n, over) = blocks.multipliedReportingOverflow(by: UInt64(size))
        return over ? .max : Int64(clamping: n)
    }

    /// Browsable mounts (not MNT_DONTBROWSE: the same set as `mountedVolumeURLs(… .skipHiddenVolumes)`).
    static func mounts() -> [Mount] {
        var p: UnsafeMutablePointer<statfs>?
        let n = getmntinfo_r_np(&p, MNT_NOWAIT)
        defer { free(p) }
        return UnsafeBufferPointer(start: p, count: Int(max(n, 0))).filter { $0.f_flags & UInt32(MNT_DONTBROWSE) == 0 }.map { s -> Mount in
            var s = s
            func str<T>(_ t: inout T) -> String { withUnsafeBytes(of: &t) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
            let free = bytes(s.f_bavail, s.f_bsize), total = bytes(s.f_blocks, s.f_bsize)
            return Mount(path: str(&s.f_mntonname), type: str(&s.f_fstypename), local: s.f_flags & UInt32(MNT_LOCAL) != 0, free: free, total: total)
        }
    }

    /// Mounted volumes. Local disks are read for name and free space (off the main thread: a stuck disk can block);
    /// network shares come from the kernel's figures alone, since a statfs on a dead one never returns.
    static func volumes(_ mounts: [Mount] = mounts()) -> [Volume] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsEjectableKey]
        return mounts.map { m in
            guard m.local else { return Volume(path: m.path, name: (m.path as NSString).lastPathComponent, free: m.free, ejectable: true) }
            let v = try? URL(fileURLWithPath: m.path).resourceValues(forKeys: keys)
            return Volume(path: m.path, name: v?.volumeName ?? (m.path as NSString).lastPathComponent,
                          free: v?.volumeAvailableCapacityForImportantUsage, ejectable: v?.volumeIsEjectable == true)
        }
    }

    /// Finder's color order for ⌃1…⌃7 and the dots: red, orange, yellow, green, blue, purple, gray.
    static let tagColors = [6, 7, 5, 2, 4, 3, 1]
}

/// Lets the sidebar see keys first while it has the focus.
private final class SidebarOutline: NSOutlineView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

final class SessionCloseButton: NSButton {}

/// SSH / SFTP on a server row: a rounded fill says "button" without a bezel's width (the narrow sidebar needs it for
/// the name); the one under the mouse fills more.
class PillButton: NSButton {
    private var over = false { didSet { if over != oldValue { needsDisplay = true } } }
    override var intrinsicContentSize: NSSize {   // 4 pt of fill each side of the title
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + 8, height: s.height)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { over = true }
    override func mouseExited(with event: NSEvent) { over = false }
    override func viewDidHide() { over = false }
    override func draw(_ dirtyRect: NSRect) {
        (contentTintColor ?? .labelColor).withAlphaComponent(over ? 0.22 : 0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill()
        super.draw(dirtyRect)
    }
}

/// Shown only while the mouse is over the row (or it's selected): the name gets the narrow sidebar's width otherwise.
final class HoverButton: PillButton {}

/// What a server row's click or button asks for.
enum ServerAction: String { case row, ssh, sftp, edit, close }

/// Fades a session row's × in while the mouse is over the row or the row is selected (the current session).
/// Faded, not hidden: the stack view would reflow, and a click always comes with a hover anyway.
final class HoverRowView: NSTableRowView {
    private var hovering = false { didSet { update() } }
    override var isSelected: Bool { didSet { update() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        update()
    }

    private func update() {
        func walk(_ v: NSView) {
            if let b = v as? SessionCloseButton { b.alphaValue = hovering || isSelected ? 1 : 0 }
            else if let b = v as? HoverButton { b.isHidden = !(hovering || isSelected) }
            else { v.subviews.forEach(walk) }
        }
        walk(self)
    }
}

/// A menu item that runs a closure (it keeps its own target alive).
final class MenuAction: NSObject {
    private let run: @MainActor () -> Void
    private init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    @MainActor @objc private func fire() { run() }

    @MainActor static func item(_ title: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let a = MenuAction(run)
        let i = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        i.target = a
        i.representedObject = a
        return i
    }

    /// The same for a button; keep what it returns for as long as the button lives (a button doesn't hold its target).
    @MainActor static func attach(to button: NSButton, _ run: @escaping @MainActor () -> Void) -> MenuAction {
        let a = MenuAction(run)
        button.target = a
        button.action = #selector(fire)
        return a
    }
}

/// Auto-hide when the panels get cramped: below 360 pt per panel it hides, from 400 pt it comes back
/// (the gap keeps it from flickering at the edge). Only applies while the user wants it shown.
enum SidebarRule {
    static func autoHidden(windowWidth: CGFloat, sidebarWidth: CGFloat, panels: Int, hidden: Bool) -> Bool {
        let perPanel = (windowWidth - sidebarWidth) / CGFloat(panels)
        return perPanel < (hidden ? 400 : 360)
    }
}

/// Places: the collapsible column left of the panels (⌃⌘S). Click opens in the active panel,
/// ⌥-click in the other one, ⌘-click in a new tab. Folded sections are remembered.
@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    final class Node {
        let section: SidebarSection?
        let place: Place?
        var children: [Node] = []
        init(section: SidebarSection? = nil, place: Place? = nil) { self.section = section; self.place = place }
    }

    var onOpen: ((Place, NSEvent.ModifierFlags) -> Void)?
    var onTag: ((String) -> Void)?
    var onFavorites: (([String]) -> Void)?             // reordered / added / removed
    var onTransfer: ((TransferItems, String, Bool) -> Void)?   // files dropped on a place (what, folder, move)
    var onEject: ((String) -> Void)?
    var onServer: ((ServerRow, ServerAction, NSEvent.ModifierFlags) -> Void)?   // a server row's buttons
    var serverMenu: ((Place) -> [NSMenuItem])?        // context menu of a server row
    var sectionMenu: ((String) -> [NSMenuItem])?       // context menu of a section header, by section id
    var keyFor: (String) -> String = { _ in "" }       // command id → its first key, for section headers
    var onLeave: (() -> Void)?                         // ⎋ while focused: the keys go back to the panel
    var onCommandKey: ((NSEvent) -> Bool)?             // any other key while focused: the panels' shortcuts

    private let outline = SidebarOutline()
    private var theme = Theme.current
    private var roots: [Node] = []
    /// NSOutlineView doesn't retain its items, and around a reload (selection, group-row caches) it still asks about the
    /// ones it had: freed, they turned into other objects and `as! Node` aborted (refresh → highlight → isItemExpandable).
    /// The last generation stays alive until the next one replaces it.
    private var previousRoots: [Node] = []
    private var highlighted: String?
    private var folding = false
    private static let favoriteDrag = NSPasteboard.PasteboardType("com.dmn.dfilemanager.favorite")

    override func loadView() {
        let col = NSTableColumn(identifier: .init("place"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.refusesFirstResponder = true   // keys stay with the panels: a click or Tab never takes them (`focus` does)
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.onKey = { [unowned self] e in
            switch e.keyCode {
            case 36, 76: open(row: outline.selectedRow, clicks: 2, mods: e.modifierFlags)   // ↩: as deliberate as a double-click
            case 53: onLeave?()                                                              // ⎋
            default:
                // The panels' shortcuts only — ⌘⌃⌥, F-keys, ⇥ — not bare keys: ⌦, Space or ⌫ here would act on the panel's
                // file while the sidebar shows the focus.
                let fKey = e.specialKey.map { (NSEvent.SpecialKey.f1.rawValue...NSEvent.SpecialKey.f35.rawValue).contains($0.rawValue) } ?? false
                guard fKey || e.keyCode == 48 || !e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
                return onCommandKey?(e) ?? false
            }
            return true
        }
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.registerForDraggedTypes([.fileURL, Self.favoriteDrag, TransferItems.remoteType])
        outline.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.verticalScroller = ThemeScroller()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
        applyTheme()
    }

    /// System theme: the native source list. Others: their background, text and folder colors.
    func applyTheme() {
        theme = Theme.current
        (view as? NSScrollView)?.drawsBackground = theme.background != nil
        (view as? NSScrollView)?.backgroundColor = theme.background ?? .clear
        ((view as? NSScrollView)?.verticalScroller as? ThemeScroller)?.fill = theme.background
        (view as? NSScrollView)?.verticalScroller?.needsDisplay = true
        outline.style = theme.background == nil ? .sourceList : .plain
        outline.backgroundColor = theme.background ?? .clear
        outline.reloadData()
        let folded = Set(UserDefaults.standard.stringArray(forKey: "sidebarFolded") ?? [])
        for n in roots where !folded.contains(n.section!.id) { outline.expandItem(n) }
        highlight(highlighted)
    }

    func show(_ sections: [SidebarSection]) {
        let folded = Set(UserDefaults.standard.stringArray(forKey: "sidebarFolded") ?? [])
        previousRoots = roots
        roots = sections.map { s in
            let n = Node(section: s)
            n.children = s.places.map { Node(place: $0) }
            return n
        }
        loadViewIfNeeded()
        outline.reloadData()
        for n in roots where !folded.contains(n.section!.id) { outline.expandItem(n) }
        highlight(highlighted)
    }

    /// Selects the place the active panel is on, or its / the terminal's session (`Place.key`; none if it isn't one).
    func highlight(_ key: String?) {
        highlighted = key
        let row = roots.flatMap(\.children).first { $0.place?.stands(for: key) == true }.map { outline.row(forItem: $0) } ?? -1
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) } else { outline.deselectAll(nil) }
    }

    /// Focus Sidebar: the keys come here — ↑↓ choose a place, ↩ opens it, ⎋ goes back — with the selection
    /// highlighted as the focus ring. Only this way: a click leaves them with the panels.
    func focus() {
        outline.refusesFirstResponder = false   // keeps clicks and Tab out; it refuses this too
        view.window?.makeFirstResponder(outline)
        outline.refusesFirstResponder = true
    }
    var hasFocus: Bool { view.window?.firstResponder === outline }

    @objc private func clicked() {
        open(row: outline.clickedRow, clicks: NSApp.currentEvent?.clickCount ?? 1, mods: NSApp.currentEvent?.modifierFlags ?? [])
    }

    private func open(row: Int, clicks: Int, mods: NSEvent.ModifierFlags) {
        let item = outline.item(atRow: row) as? Node
        if let s = item?.section {   // header: fold / unfold
            folding = true
            outline.isItemExpanded(item) ? outline.collapseItem(item) : outline.expandItem(item)
            folding = false
            var folded = Set(UserDefaults.standard.stringArray(forKey: "sidebarFolded") ?? [])
            if outline.isItemExpanded(item) { folded.remove(s.id) } else { folded.insert(s.id) }
            UserDefaults.standard.set(Array(folded).sorted(), forKey: "sidebarFolded")
        } else if let p = item?.place, p != .tagColors {
            // A server with nothing open connects on a double-click only: rows shift as Frequent grows, and one stray
            // click must not open a root shell on the wrong (production) server.
            if case .server(let r) = p, r.sessions.isEmpty, clicks < 2 { return highlight(highlighted) }
            onOpen?(p, mods)
        }
        highlight(highlighted)   // the panel decides what's selected, after it navigates
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }
    // `as?`, not `as!`: should AppKit still hand over something stale, a row draws wrong instead of the app aborting.
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.section != nil }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? Node)?.section != nil }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? Node)?.place?.selectable == true }
    /// No system disclosure button: headers have their own chevron. But AppKit won't collapse a row without one,
    /// so it's "shown" for the moment of a header click.
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { folding }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { HoverRowView() }
    // A header's chevron follows its section (folded by a click, or unfolded when the sidebar is rebuilt).
    // Only the image changes: reloading the row from inside these notifications would undo the collapse.
    func outlineViewItemDidExpand(_ notification: Notification) { turnChevron(notification) }
    func outlineViewItemDidCollapse(_ notification: Notification) { turnChevron(notification) }

    private static let chevronID = NSUserInterfaceItemIdentifier("chevron")
    private static func chevron(expanded: Bool) -> NSImage {
        NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: expanded ? "Collapse" : "Expand")!
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))!
    }

    private func turnChevron(_ n: Notification) {
        guard let item = n.userInfo?["NSObject"] else { return }
        let row = outline.row(forItem: item)
        guard row >= 0, let header = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSStackView else { return }
        (header.arrangedSubviews.first { $0.identifier == Self.chevronID } as? NSImageView)?.image = Self.chevron(expanded: outline.isItemExpanded(item))
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if let s = node.section {
            let title = NSTextField(labelWithString: s.title.uppercased())
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = .secondaryLabelColor
            let key = NSTextField(labelWithString: keyFor(s.command))
            key.font = .systemFont(ofSize: 10)
            key.textColor = .tertiaryLabelColor
            let chevron = NSImageView(image: Self.chevron(expanded: outlineView.isItemExpanded(item)))
            chevron.identifier = Self.chevronID
            chevron.contentTintColor = .tertiaryLabelColor
            let r = row([title, spacer(), key, chevron])
            r.toolTip = "Click to collapse or expand"
            return r
        }
        switch node.place! {
        case .folder(let p):
            let favorite = roots.first?.children.contains { $0 === node } == true
            return placeRow(favorite ? "folder" : "clock", p == "/" ? "/" : (p as NSString).lastPathComponent, (p as NSString).abbreviatingWithTildeInPath)
        case .serverFolder(let e):
            return placeRow("server.rack", Bookmark.title(e), e + "  ·  ⌘-click: in a new tab, ⌥-click: in the other panel",
                            detail: Bookmark.remote(e)?.target.host ?? "")
        case let .volume(path, name, free, ejectable):
            let r = placeRow(ejectable ? "externaldrive" : "internaldrive", name, free.isEmpty ? path : "\(path) · \(free) free")   // narrow column: free space in the tooltip
            if ejectable {
                let b = NSButton(image: NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")!, target: self, action: #selector(eject(_:)))
                b.isBordered = false
                b.identifier = .init(path)
                b.toolTip = "Eject “\(name)”"
                r.addArrangedSubview(b)
            }
            return r
        case .server(let server):
            return serverRow(server)
        case .connect:
            return placeRow("plus.circle", "Connect…", "Every server, or a new one: \(keyFor("ssh.new")) SSH, \(keyFor("go.connect")) SFTP")
        case .tag(let name):
            return placeRow("tag", name, "Every file tagged “\(name)”")
        case .tagColors:
            let names = NSWorkspace.shared.fileLabels, colors = NSWorkspace.shared.fileLabelColors
            let dots = SidebarModel.tagColors.map { c -> NSView in
                let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: names[c])!
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))!
                let b = NSButton(image: dot, target: self, action: #selector(tagDot(_:)))
                b.isBordered = false
                b.contentTintColor = colors[c]
                b.identifier = .init(names[c])
                b.toolTip = "Every file tagged \(names[c])"
                return b
            }
            let r = row(dots)
            r.spacing = 3
            return r
        }
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 6
        s.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 4)
        return s
    }

    private func placeRow(_ symbol: String, _ title: String, _ tip: String, detail: String = "") -> NSStackView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = theme.background == nil ? .controlAccentColor : theme.dir
        let label = NSTextField(labelWithString: title)
        label.textColor = theme.text
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let d = NSTextField(labelWithString: detail)
        d.font = .systemFont(ofSize: 10)
        d.textColor = .secondaryLabelColor
        let r = row(detail.isEmpty ? [icon, label] : [icon, label, spacer(), d])
        r.toolTip = tip
        return r
    }

    private func withStatus(_ r: NSStackView, _ status: HostStatus) -> NSStackView {
        switch status {
        case .idle: break
        case .connecting:
            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .small
            spin.startAnimation(nil)
            r.addArrangedSubview(spacer())
            r.addArrangedSubview(spin)
            r.toolTip = "Connecting…"
        case .failed(let message):
            r.addArrangedSubview(spacer())
            r.addArrangedSubview(dot(.systemRed))
            r.toolTip = message
        }
        return r
    }

    private func dot(_ color: NSColor) -> NSView {
        let d = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 7, weight: .regular))!)
        d.contentTintColor = color
        return d
    }

    /// Icon, name (red for production), 📌, ✎ (servers you made), then [SSH] [SFTP]: buttons that also say what's open
    /// (green, with a count; shown on hover when nothing is), and × (on hover) closing all of it. A narrow column cuts
    /// the buttons' titles before the name.
    private func serverRow(_ server: ServerRow) -> NSStackView {
        let locked = server.saved?.locked == true, prod = server.saved?.prod == true
        let port = server.target.port.map { ":\($0)" } ?? ""
        let r = withStatus(placeRow(locked ? "lock" : "server.rack", server.title,
                                    "\(server.target.host)\(port)\(locked ? " · locked" : "")\(prod ? " · production" : "")  ·  click: its session · double-click: SSH"),
                           server.status)
        let name = r.arrangedSubviews[1] as? NSTextField
        // Narrow: the buttons' titles go first ("S…"), then the buttons, then the name: never past the row's end.
        name?.setContentCompressionResistancePriority(.defaultLow + 2, for: .horizontal)
        if prod {
            (r.arrangedSubviews[0] as? NSImageView)?.contentTintColor = .systemRed
            name?.textColor = .systemRed
        }
        if r.arrangedSubviews.count == 2 { r.addArrangedSubview(spacer()) }   // withStatus adds one before its spinner / dot
        func symbol(_ name: String, _ tip: String) -> NSImageView {
            let v = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: tip)!
                .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))!)
            v.contentTintColor = .tertiaryLabelColor
            v.toolTip = tip
            return v
        }
        if server.pinned { r.insertArrangedSubview(symbol("pin.fill", "Pinned"), at: 2) }
        func button(_ view: NSButton, _ action: ServerAction, _ tip: String) -> NSButton {
            view.target = self
            view.action = #selector(serverButton(_:))
            view.identifier = .init("\(action.rawValue) \(server.key)")
            view.toolTip = tip
            return view
        }
        if !server.tunnels.isEmpty {   // ports open on this Mac: always in sight
            let t = NSTextField(labelWithString: "⇄ \(server.tunnels.count)")
            t.font = .systemFont(ofSize: 10, weight: .semibold)
            t.textColor = .secondaryLabelColor
            t.toolTip = "Tunnels listening on this Mac: " + server.tunnels.joined(separator: ", ") + "  ·  its menu ▸ Tunnels"
            t.setAccessibilityLabel("\(server.tunnels.count) tunnel\(server.tunnels.count == 1 ? "" : "s") listening")
            r.addArrangedSubview(t)
        }
        if server.saved != nil {
            let b = NSButton(image: NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Edit")!
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))!, target: nil, action: nil)
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            r.addArrangedSubview(button(b, .edit, "Edit “\(server.title)”"))
        }
        for (kind, all) in [(ServerAction.ssh, server.ssh), (.sftp, server.sftp)] {
            let sessions = all.filter(\.running)   // an SSH tab whose ssh ended (`exit`, Disconnect) isn't open
            let name = kind == .ssh ? "SSH" : "SFTP"
            let open = sessions.count > 1 ? "\(name) \(sessions.count)" : name
            // Open: always there, green. Otherwise on hover only.
            let b = sessions.isEmpty ? HoverButton(title: open, target: nil, action: nil) : PillButton(title: open, target: nil, action: nil)
            b.isBordered = false   // the name needs the width more than a bezel does: PillButton draws a fill instead
            b.font = .systemFont(ofSize: 10, weight: .semibold)
            b.contentTintColor = sessions.isEmpty ? .secondaryLabelColor : .systemGreen
            b.lineBreakMode = .byTruncatingTail
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let least = b.widthAnchor.constraint(greaterThanOrEqualToConstant: min(18, b.intrinsicContentSize.width))
            least.priority = .defaultLow + 1
            least.isActive = true
            r.addArrangedSubview(button(b, kind, sessions.isEmpty
                ? (kind == .ssh ? "Open an SSH session  ·  ⌘-click: another one" : "Open over SFTP  ·  ⌘-click: in a new tab, ⌥-click: in the other panel")
                : "\(sessions.count) open — click to go there  ·  ⌘-click: another one"))
        }
        if !server.sessions.isEmpty {
            let x = SessionCloseButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Sessions")!
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))!, target: nil, action: nil)
            x.isBordered = false
            x.contentTintColor = .secondaryLabelColor
            r.addArrangedSubview(button(x, .close, "Close all \(server.title)'s sessions"))
        }
        r.spacing = 4
        return r
    }

    @objc private func serverButton(_ sender: NSButton) {
        guard let parts = sender.identifier?.rawValue.split(separator: " ", maxSplits: 1), parts.count == 2,
              let action = ServerAction(rawValue: String(parts[0])) else { return }
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        for case let .server(r)? in roots.flatMap(\.children).map(\.place) where r.key == parts[1] {
            // Next turn: what it runs rebuilds the sidebar, this button's row included.
            DispatchQueue.main.async { [weak self] in self?.onServer?(r, action, mods) }
        }
    }

    @objc private func eject(_ sender: NSButton) { sender.identifier.map { onEject?($0.rawValue) } }
    @objc private func tagDot(_ sender: NSButton) { sender.identifier.map { onTag?($0.rawValue) } }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        if let s = node.section { return sectionMenu?(s.id).forEach(menu.addItem) ?? () }
        guard let place = node.place else { return }
        if roots.first?.children.contains(where: { $0 === node }) == true, let p = place.bookmark {
            menu.addItem(withTitle: "Remove from Favorites", action: #selector(removeFavorite(_:)), keyEquivalent: "").representedObject = p
        }
        if case let .volume(path, _, _, true) = place {
            menu.addItem(withTitle: "Eject", action: #selector(ejectItem(_:)), keyEquivalent: "").representedObject = path
        }
        menu.items.forEach { $0.target = self }
        serverMenu?(place).forEach(menu.addItem)
    }

    var places: [Place] { roots.flatMap(\.children).compactMap(\.place) }

    private var favorites: [String] { roots.first?.children.compactMap(\.place?.bookmark) ?? [] }

    @objc private func removeFavorite(_ sender: NSMenuItem) { onFavorites?(favorites.filter { $0 != sender.representedObject as? String }) }
    @objc private func ejectItem(_ sender: NSMenuItem) { (sender.representedObject as? String).map { onEject?($0) } }

    // MARK: - Drag & drop: folders onto Favorites pin them (drag within to reorder); files onto a place copy / move there

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? Node, let p = node.place?.path ?? node.place?.bookmark else { return nil }
        let pb = NSPasteboardItem()
        if node.place?.path != nil { pb.setString(URL(fileURLWithPath: p).absoluteString, forType: .fileURL) }   // a server's: reorder only
        if roots.first?.children.contains(where: { $0 === node }) == true { pb.setString(p, forType: Self.favoriteDrag) }
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let node = item as? Node
        if node === roots.first {   // between favorites
            if info.draggingPasteboard.string(forType: Self.favoriteDrag) != nil { return .move }
            let urls = PanelViewController.droppedURLs(info)
            return !urls.isEmpty && urls.allSatisfy(\.hasDirectoryPath) ? .link : []
        }
        guard index == NSOutlineViewDropOnItemIndex, let target = node?.place?.path,
              let items = TransferItems(info.draggingPasteboard) else { return [] }
        return PanelViewController.dragOperation(info, items: items, to: .local, target: target)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let node = item as? Node
        if node === roots.first {
            var favs = favorites
            let at = index < 0 ? favs.count : index
            if let moved = info.draggingPasteboard.string(forType: Self.favoriteDrag), let from = favs.firstIndex(of: moved) {
                favs.remove(at: from)
                favs.insert(moved, at: from < at ? at - 1 : at)
            } else {
                let new = PanelViewController.droppedURLs(info).map(\.path).filter { !favs.contains($0) }
                favs.insert(contentsOf: new, at: min(at, favs.count))
            }
            onFavorites?(favs)
            return true
        }
        guard let target = node?.place?.path, let items = TransferItems(info.draggingPasteboard) else { return false }
        let operation = PanelViewController.dragOperation(info, items: items, to: .local, target: target)
        guard !operation.isEmpty else { return false }
        onTransfer?(items, target, operation == .move)
        return true
    }
}
