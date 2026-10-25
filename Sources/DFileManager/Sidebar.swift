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
    case volume(VolumeRow)
    case server(ServerRow)
    case connect                                               // "Connect…": the picker with every server
    case tagColors                                             // Finder's 7 colors as one row of dots
    case tag(String)

    var path: String? {
        switch self {
        case .folder(let p): p
        case .volume(let v): v.path.isEmpty ? nil : v.path
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
    var failedTunnels: [String: [String]] = [:]   // ServerRow.key → "Postgres: why" for each whose last connection failed
    var forwarded: [SFTPTarget] = []    // servers with temporary tunnels (Forward Port): listed, as those with sessions are
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
    var failedTunnels: [String] = []     // "Postgres: why": the last connection failed, or it can't listen

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

/// The Git section, pinned under the list: the active panel's work tree (here or on a server), from the `git status`
/// the panel already runs for its Git column — no git of its own.
struct GitRow: Equatable {
    let status: GitStatus
    var server: String? = nil   // the host of a server panel: the state shows there, the actions are this Mac's

    var repo: String { (status.root as NSString).lastPathComponent }
    /// The count shown: conflicts if any, else changes — in the panel's folder, as its Git column (`git status -- .`).
    var changed: Int { status.conflicts > 0 ? status.conflicts : status.changes.count }
    var arrows: String { [status.behind > 0 ? "↓\(status.behind)" : nil, status.ahead > 0 ? "↑\(status.ahead)" : nil].compactMap { $0 }.joined(separator: " ") }
    /// A branch no remote has yet: ⟳ becomes Publish.
    var publishes: Bool { server == nil && status.upstream == nil && !status.detached }

    func tip(now: Date = Date()) -> String {
        let st = status, here = st.subdir.isEmpty ? "" : " in this folder"
        let place = server.map { "\($0):\(st.root)" } ?? (st.root as NSString).abbreviatingWithTildeInPath
        let upstream = st.detached ? "detached HEAD" : st.upstream.map { $0 + (st.gone ? " is gone" : arrows.isEmpty ? " · up to date" : " · " + arrows) }
            ?? "not on a remote yet"
        let changes = st.conflicts > 0 ? "\(st.conflicts) file\(st.conflicts == 1 ? "" : "s") in conflict\(here)"
            : st.changes.isEmpty ? "no changes\(here)" : "\(st.changes.count) change\(st.changes.count == 1 ? "" : "s")\(here), \(st.staged) staged"
        let fetched = st.fetched.map { "fetched " + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now) }
        return ([place, upstream, changes] + (fetched.map { [$0] } ?? [])).joined(separator: " · ") + "\n"
            + (server == nil ? "Click: switch branch · ⋯ or right-click: everything else" : "Git actions work in this Mac's folders · ⋯: copy the branch name")
    }
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
    var total: Int64? = nil
    let ejectable: Bool
    var device = ""   // "/dev/disk4s1"
}

/// A Locations row: its volume's figures as shown ("" where the volume doesn't say). `disk`: DiskArbitration's, for
/// one Kermo may mount and unmount; with no `path`, it isn't mounted.
struct VolumeRow: Equatable {
    let path: String
    let name: String
    var used = "", free = "", total = ""
    var fraction: Double? = nil   // how full, 0…1
    let ejectable: Bool
    var disk: Disk? = nil
    var busy = false   // being mounted, unmounted or ejected

    var mounted: Bool { !path.isEmpty }
    /// What `busy` holds for it.
    var key: String { mounted ? path : disk?.bsd ?? "" }
    /// Its menu's: Mount when it isn't; Unmount for one Kermo can mount again; Eject. Nothing while one is under way.
    var actions: [VolumeAction] { busy ? [] : !mounted ? [.mount] : (disk != nil ? [.unmount] : []) + (ejectable ? [.eject] : []) }

    var tip: String {
        if !mounted, let d = disk { return "Not mounted · " + [d.format, d.size > 0 ? SidebarModel.sizes.string(fromByteCount: d.size) : ""].filter { !$0.isEmpty }.joined(separator: " · ") }
        return used.isEmpty ? path : "\(path) · \(used) used of \(total) · \(free) free"
    }
}

/// What the sidebar shows, from data the app already keeps.
enum SidebarModel {
    static func sections(bookmarks: [String], frecent: [String], volumes: [Volume], disks: [Disk] = [], busy: Set<String> = [], servers: ServerList,
                         tags: [String]) -> [SidebarSection] {
        [
            SidebarSection(id: "fav", title: "Favorites", command: "go.bookmark",
                           places: bookmarks.map { Bookmark.remote($0) == nil ? .folder($0) : .serverFolder($0) }),
            SidebarSection(id: "freq", title: "Frequent", command: "go.jump",
                           places: frecent.filter { !bookmarks.contains($0) }.prefix(5).map(Place.folder)),
            SidebarSection(id: "loc", title: "Locations", command: "go.volumes", places: locations(volumes, disks).map {
                var v = $0
                v.busy = busy.contains(v.key)
                return .volume(v)
            }),
            SidebarSection(id: "servers", title: "Servers", command: "ssh.new", places: serverRows(servers).map(Place.server) + [.connect]),
            SidebarSection(id: "tags", title: "Tags", command: "tag.edit", places: [.tagColors] + tags.map(Place.tag)),
        ]
    }

    /// The shortest sizes: "110 GB", "0 KB", never "bytes". Set up once, then only read (formatters are thread-safe).
    nonisolated(unsafe) static let sizes = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB, .usePB]
        f.isAdaptive = false
        f.allowsNonnumericFormatting = false
        return f
    }()

    /// Used = total − free (free as Finder counts it for a local disk: with what macOS would clear for an important
    /// file), when the volume knows both; a share's kernel figures of 0 / 0 say nothing.
    static func row(_ v: Volume, disks: [Disk] = []) -> VolumeRow {
        let disk = disks.first { $0.mountPath == v.path || "/dev/" + $0.bsd == v.device }
        guard let free = v.free, let total = v.total, total > 0 else { return VolumeRow(path: v.path, name: v.name, ejectable: v.ejectable, disk: disk) }
        let used = max(0, total - free)
        return VolumeRow(path: v.path, name: v.name, used: sizes.string(fromByteCount: used), free: sizes.string(fromByteCount: free),
                         total: sizes.string(fromByteCount: total), fraction: Double(used) / Double(total), ejectable: v.ejectable, disk: disk)
    }

    /// Mounted volumes, then the disks' volumes that aren't (not one the kernel has mounted already, which
    /// DiskArbitration may not have told yet).
    static func locations(_ volumes: [Volume], _ disks: [Disk]) -> [VolumeRow] {
        let devices = Set(volumes.map(\.device))
        return volumes.map { row($0, disks: disks) }
            + disks.filter { $0.mountPath == nil && !devices.contains("/dev/" + $0.bsd) }.map { VolumeRow(path: "", name: $0.name, ejectable: true, disk: $0) }
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
                             status: hostStatus(target.host, list), tunnels: list.tunnels[key] ?? [],
                             failedTunnels: list.failedTunnels[key] ?? [])
        }
        var rows: [ServerRow] = [], seen = Set<String>()
        func add(_ t: SFTPTarget, if keep: (ServerRow) -> Bool = { _ in true }) {
            let r = row(t)
            if !seen.contains(r.key), keep(r) { seen.insert(r.key); rows.append(r) }
        }
        list.pins.compactMap(parse).forEach { add($0) }
        let room = max(places, rows.count + 1)
        (list.recents.compactMap(parse) + list.sessions.map(\.target)).forEach { add($0) { rows.count < room || !$0.sessions.isEmpty } }
        list.forwarded.forEach { add($0) }
        (list.saved.map(\.target) + configTargets).forEach { add($0) { _ in rows.count < room } }
        let order = (list.pins.compactMap(parse) + list.saved.map(\.target) + configTargets).map(ServerRow.key)
        func rank(_ r: ServerRow) -> Int { order.firstIndex(of: r.key) ?? order.count }
        return rows.sorted { (rank($0), $0.key) < (rank($1), $1.key) }
    }

    /// A mounted volume as the kernel last knew it (MNT_NOWAIT): a dead network mount isn't asked, so it can't hang.
    struct Mount: Sendable { let path: String, type: String, local: Bool, free: Int64, total: Int64; var device = "" }

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
            return Mount(path: str(&s.f_mntonname), type: str(&s.f_fstypename), local: s.f_flags & UInt32(MNT_LOCAL) != 0, free: free, total: total,
                         device: str(&s.f_mntfromname))
        }
    }

    /// Mounted volumes. Local disks are read for name and free space (off the main thread: a stuck disk can block);
    /// network shares come from the kernel's figures alone, since a statfs on a dead one never returns.
    static func volumes(_ mounts: [Mount] = mounts()) -> [Volume] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeIsEjectableKey]
        return mounts.map { m in
            guard m.local else { return Volume(path: m.path, name: (m.path as NSString).lastPathComponent, free: m.free, total: m.total, ejectable: true, device: m.device) }
            let v = try? URL(fileURLWithPath: m.path).resourceValues(forKeys: keys)
            return Volume(path: m.path, name: v?.volumeName ?? (m.path as NSString).lastPathComponent,
                          free: v?.volumeAvailableCapacityForImportantUsage, total: v?.volumeTotalCapacity.map(Int64.init), ejectable: v?.volumeIsEjectable == true,
                          device: m.device)
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

/// SSH / SFTP / tunnels on a server row: a rounded fill says "button" without a bezel's width (the narrow sidebar needs
/// it for the name); the one under the mouse fills more. It takes clicks on at least `minSide` square around the fill:
/// a 10 pt icon alone is a hard target.
class PillButton: NSButton {
    private var over = false { didSet { if over != oldValue { needsDisplay = true } } }
    var minSide: CGFloat = 22 { didSet { invalidateIntrinsicContentSize() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)   // a shorter row (small sidebar icons): a shorter target
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override var intrinsicContentSize: NSSize {   // 4 pt of fill each side of the title
        let s = super.intrinsicContentSize
        return NSSize(width: max(s.width + 8, minSide), height: max(s.height, minSide))
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
        let fill = bounds.insetBy(dx: 0, dy: max(1, (bounds.height - super.intrinsicContentSize.height) / 2 + 1))   // as tall as the title
        NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
        super.draw(dirtyRect)
    }
}

/// A server row's state at rest: what's open there and its tunnels listening (green, a count from 2; a tunnel red when
/// one failed). `ServerToolbar` stands in its place while the mouse is over the row.
final class ServerChips: NSStackView {}

/// A server row's actions, under the mouse: SSH, SFTP, Tunnels ▸ and ⋯ (the row's whole menu).
final class ServerToolbar: NSStackView {}

/// A server row's name: cut in the middle at rest; under the mouse, where the actions leave it little room, its start
/// stays ("k13…" rather than "…").
final class ServerName: NSTextField {}

/// What a server row's click or button asks for.
enum ServerAction: String { case row, ssh, sftp }
enum VolumeAction: String { case mount = "Mount", unmount = "Unmount", eject = "Eject" }

/// Swaps a server row's state for its actions while the mouse is over the row. Not for being selected: that's the
/// current server, whose name and state matter most, and a click always comes with a hover.
class HoverRowView: NSTableRowView {
    private var hovering = false { didSet { update() } }
    override var isSelected: Bool { didSet { update() } }
    override var isEmphasized: Bool { didSet { update() } }

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
            if v is ServerToolbar { v.isHidden = !hovering }
            else if v is ServerChips { v.isHidden = hovering }
            else if let name = v as? ServerName { name.lineBreakMode = hovering ? .byTruncatingTail : .byTruncatingMiddle }
            else if let g = v as? VolumeGauge { g.onAccent = isSelected && isEmphasized }
            else { v.subviews.forEach(walk) }
        }
        walk(self)
    }
}

/// A volume's "350 GB free" over a bar of how full it is — neutral, amber from 85 %, red from 95 % (`tone`): red only
/// once it's trouble. In what room the name leaves, else gone (the tooltip has the figures); white on the accent of a
/// focused selection.
final class VolumeGauge: NSView {
    private let free: String, fraction: Double
    var onAccent = false { didSet { if onAccent != oldValue { needsDisplay = true } } }

    init(free: String, fraction: Double) {
        (self.free, self.fraction) = (free, min(max(fraction, 0), 1))
        super.init(frame: .zero)
        setContentCompressionResistancePriority(.init(200), for: .horizontal)   // below the name's: the name keeps its room
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("\(free) free")
        setAccessibilityValue(Int((self.fraction * 100).rounded()))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The bar's color at `fraction` full; nil: neutral.
    static func tone(_ fraction: Double) -> NSColor? { fraction >= 0.95 ? Palette.fail : fraction >= 0.85 ? Palette.warn : nil }

    var text: NSAttributedString {
        NSAttributedString(string: free + " free", attributes: [.font: NSFont.systemFont(ofSize: 10),
                                                                .foregroundColor: onAccent ? NSColor.alternateSelectedControlTextColor : Palette.secondary])
    }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(text.size().width), height: 18) }
    /// All of the text, or nothing.
    var shown: Bool { bounds.width >= intrinsicContentSize.width }

    override func draw(_ dirtyRect: NSRect) {
        guard shown else { return }
        let t = text, h = ceil(t.size().height)
        let bar = NSRect(x: 0, y: (bounds.height - h - 5) / 2, width: bounds.width, height: 3)
        t.draw(at: NSPoint(x: bounds.width - t.size().width, y: bar.maxY + 2))
        (onAccent ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.35) : NSColor.quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        (onAccent ? NSColor.alternateSelectedControlTextColor : Self.tone(fraction) ?? .secondaryLabelColor).setFill()
        NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(3, bar.width * fraction), height: bar.height), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// The Git section's row, outside the outline: a click (not on one of its buttons) and a right-click of its own.
final class GitRowView: HoverRowView {
    var onClick: (() -> Void)?
    var menuItems: (() -> [NSMenuItem])?
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        (menuItems?() ?? []).forEach(m.addItem)
        return m.items.isEmpty ? nil : m
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
    var onVolume: ((VolumeRow, VolumeAction) -> Void)?
    var onServer: ((ServerRow, ServerAction, NSEvent.ModifierFlags) -> Void)?   // a server row's buttons
    var serverMenu: ((Place) -> [NSMenuItem])?        // context menu of a server row
    var sectionMenu: ((String) -> [NSMenuItem])?       // context menu of a section header, by section id
    var keyFor: (String) -> String = { _ in "" }       // command id → its first key, for section headers
    var onLeave: (() -> Void)?                         // ⎋ while focused: the keys go back to the panel
    var onCommandKey: ((NSEvent) -> Bool)?             // any other key while focused: the panels' shortcuts
    var onGitCommand: ((String) -> Void)?              // the Git row's click and buttons: a command id
    var gitMenu: (() -> [NSMenuItem])?                 // its ⋯ and right-click

    private let outline = SidebarOutline()
    private let scroll = NSScrollView()
    private let gitBlock = NSStackView()   // pinned under the list: always in the same place, however long the list
    private var gitRow: GitRow?
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
        scroll.documentView = outline
        scroll.verticalScroller = ThemeScroller()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        gitBlock.orientation = .vertical
        gitBlock.spacing = 0
        gitBlock.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        gitBlock.wantsLayer = true
        gitBlock.isHidden = true
        let column = NSStackView(views: [scroll, gitBlock])   // a hidden block gives the list its height back
        column.orientation = .vertical
        column.spacing = 0
        for v in [scroll, gitBlock] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        view = column
        applyTheme()
    }

    /// System theme: the native source list. Others: their background, text and folder colors.
    func applyTheme() {
        theme = Theme.current
        scroll.drawsBackground = theme.background != nil
        scroll.backgroundColor = theme.background ?? .clear
        (scroll.verticalScroller as? ThemeScroller)?.fill = theme.background
        scroll.verticalScroller?.needsDisplay = true
        gitBlock.layer?.backgroundColor = theme.background?.cgColor
        buildGit()
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
        (expanded ? Symbol.collapse : .expand).image(expanded ? "Collapse" : "Expand")
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
            return placeRow(favorite ? .folder : .recent, p == "/" ? "/" : (p as NSString).lastPathComponent, (p as NSString).abbreviatingWithTildeInPath)
        case .serverFolder(let e):
            return placeRow(.server, Bookmark.title(e), e + "  ·  ⌘-click: in a new tab, ⌥-click: in the other panel",
                            detail: Bookmark.remote(e)?.target.host ?? "")
        case .volume(let v):
            let (name, ejectable) = (v.name, v.ejectable)
            let r = placeRow(ejectable ? .externalDisk : .internalDisk, name, v.tip, dim: !v.mounted)
            r.addArrangedSubview(spacer())   // the buttons in one column at the right, figures or not
            if let f = v.fraction { r.addArrangedSubview(VolumeGauge(free: v.free, fraction: f)) }
            func button(_ symbol: Symbol, _ action: VolumeAction) {
                let b = NSButton(image: symbol.image(action.rawValue), target: self, action: #selector(volumeButton(_:)))
                b.isBordered = false
                b.identifier = .init("\(action.rawValue) \(v.key)")
                b.toolTip = "\(action.rawValue) “\(name)”"
                r.addArrangedSubview(b)
            }
            if v.busy { r.addArrangedSubview(Self.spinner()) }   // in the button's place: one thing at a time
            else if !v.mounted { button(.add, .mount) }
            else if ejectable { button(.eject, .eject) }
            return r
        case .server(let server):
            return serverRow(server)
        case .connect:
            let r = placeRow(.add, "Connect…", "Every server, or a new one: \(keyFor("ssh.new")) SSH, \(keyFor("go.connect")) SFTP")
            (r.arrangedSubviews.first as? NSImageView)?.contentTintColor = theme.background == nil ? Palette.accent : theme.dir   // an action, not a place
            return r
        case .tag(let name):
            return placeRow(.tag, name, "Every file tagged “\(name)”")
        case .tagColors:
            let names = NSWorkspace.shared.fileLabels, colors = NSWorkspace.shared.fileLabelColors
            let dots = SidebarModel.tagColors.map { c -> NSView in
                let dot = Symbol.dot.image(names[c])
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

    /// `dim`: a volume not mounted, in gray. Places' icons are quiet (secondary): color is for state — the theme's own
    /// folder color in a theme.
    private func placeRow(_ symbol: Symbol, _ title: String, _ tip: String, detail: String = "", dim: Bool = false) -> NSStackView {
        let icon = NSImageView(image: symbol.image())
        icon.contentTintColor = dim ? .tertiaryLabelColor : theme.background == nil ? Palette.secondary : theme.dir
        let label = NSTextField(labelWithString: title)
        label.textColor = dim ? .secondaryLabelColor : theme.text
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let d = NSTextField(labelWithString: detail)
        d.font = .systemFont(ofSize: 10)
        d.textColor = .secondaryLabelColor
        let r = row(detail.isEmpty ? [icon, label] : [icon, label, spacer(), d])
        r.toolTip = tip
        return r
    }

    /// Icon (production's color; a lock cut into its corner; a spinner while connecting), name and production's chip,
    /// then a red ◆ when its last connection failed (its tooltip says why) and what's open: SSH, SFTP and tunnels
    /// listening (green, a count from 2; tunnels red when one failed). Under the mouse that gives way to SSH, SFTP, Tunnels ▸ and ⋯ (the row's whole menu); the tooltip
    /// says all of it. A narrow column cuts the name, never the icons.
    private func serverRow(_ server: ServerRow) -> NSStackView {
        let prod = server.saved?.prod == true, locked = server.saved?.locked == true
        let failed: String? = if case .failed(let m) = server.status { m } else { nil }
        let icon: NSView
        if server.status == .connecting {
            icon = Self.spinner()
        } else {
            let tint = prod ? Palette.prod : theme.background == nil ? Palette.secondary : theme.dir
            icon = NSImageView(image: Self.serverIcon(tint, locked: locked))
        }
        let name = ServerName(labelWithString: server.title)
        name.textColor = theme.text
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.init(1), for: .horizontal)   // it takes the room, not a spacer and its gap

        let ssh = server.ssh.filter(\.running).count, sftp = server.sftp.count   // an SSH tab whose ssh ended (`exit`, Disconnect) isn't open
        let open = [ssh > 0 ? "SSH \(ssh)" : nil, sftp > 0 ? "SFTP \(sftp)" : nil].compactMap { $0 }.joined(separator: ", ")
        let tunnels = (server.tunnels.isEmpty ? [] : ["Tunnels listening: " + server.tunnels.joined(separator: ", ")]) + server.failedTunnels
        let tunnelColor: NSColor = !server.failedTunnels.isEmpty ? Palette.fail : server.tunnels.isEmpty ? .secondaryLabelColor : Palette.ok
        /// An action is a pill; a state just its icon and count, so it takes less of the name's width.
        func pill(_ symbol: Symbol, _ count: Int, _ color: NSColor, _ action: String, _ label: String, _ tip: String, state: Bool = false) -> NSButton {
            let image = symbol.image().withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))!
            let b = state ? NSButton(title: count > 1 ? "\(count)" : "", image: image, target: self, action: #selector(serverButton(_:)))
                : PillButton(title: count > 1 ? "\(count)" : "", image: image, target: self, action: #selector(serverButton(_:)))
            b.imagePosition = count > 1 ? .imageLeading : .imageOnly
            b.imageHugsTitle = true
            b.isBordered = false
            b.font = .systemFont(ofSize: 10, weight: .semibold)
            b.contentTintColor = color
            b.identifier = .init("\(action) \(server.key)")
            b.toolTip = tip
            b.setAccessibilityLabel(label)
            return b
        }
        let failedMark = failed.map { why -> NSView in
            let v = NSImageView(image: StateMark.failed.image("Its last connection failed", size: 9))
            v.toolTip = "Last connection failed: " + why
            return v
        }
        let chips = ServerChips(views: [
            failedMark,
            ssh == 0 ? nil : pill(.ssh, ssh, Palette.ok, "ssh", "\(ssh) SSH session\(ssh == 1 ? "" : "s") open", "\(ssh) SSH session\(ssh == 1 ? "" : "s") open", state: true),
            sftp == 0 ? nil : pill(.folder, sftp, Palette.ok, "sftp", "\(sftp) SFTP panel\(sftp == 1 ? "" : "s") open", "\(sftp) SFTP panel\(sftp == 1 ? "" : "s") open", state: true),
            tunnels.isEmpty ? nil : pill(.tunnel, server.tunnels.count, tunnelColor, "tunnels",
                                         "\(server.tunnels.count) tunnel\(server.tunnels.count == 1 ? "" : "s") listening" + (server.failedTunnels.isEmpty ? "" : ", one failed"),
                                         tunnels.joined(separator: "\n"), state: true),
        ].compactMap { $0 })
        let more = PillButton(image: Symbol.more.image("Server menu")
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))!, target: self, action: #selector(serverButton(_:)))
        more.isBordered = false
        more.contentTintColor = .secondaryLabelColor
        more.identifier = .init("menu \(server.key)")
        more.toolTip = "Everything for “\(server.title)”: Edit, Pin, Tunnels, Disconnect…"
        let toolbar = ServerToolbar(views: [
            pill(.ssh, ssh, ssh > 0 ? Palette.ok : .secondaryLabelColor, "ssh", "SSH",
                 ssh > 0 ? "\(ssh) open — click to go there  ·  ⌘-click: another one" : "Open an SSH session  ·  ⌘-click: another one"),
            pill(.folder, sftp, sftp > 0 ? Palette.ok : .secondaryLabelColor, "sftp", "SFTP",
                 sftp > 0 ? "\(sftp) open — click to go there  ·  ⌘-click: another one" : "Open over SFTP  ·  ⌘-click: in a new tab, ⌥-click: in the other panel"),
        ] + (server.saved?.tunnels.isEmpty == false || !server.tunnels.isEmpty || !server.failedTunnels.isEmpty
             ? [pill(.tunnel, server.tunnels.count, tunnelColor, "tunnels", "Tunnels", (tunnels + ["Click: its tunnels"]).joined(separator: "\n"))] : [])
          + [more])
        chips.spacing = 4
        toolbar.spacing = 2
        toolbar.isHidden = true

        let chip = prod ? NSImageView(image: Chip.prod.image) : nil
        chip?.setContentCompressionResistancePriority(.required, for: .horizontal)   // the name gives way, not the chip
        let r = row([icon, name, chip, chips, toolbar].compactMap { $0 })
        r.spacing = 4
        let port = server.target.port.map { ":\($0)" } ?? ""
        let about = ["\(server.target.host)\(port)", locked ? "locked" : nil, prod ? "production" : nil, open.isEmpty ? nil : open + " open"]
        r.toolTip = ([about.compactMap { $0 }.joined(separator: " · ")] + (server.status == .connecting ? ["Connecting…"] : [])
                     + (failed.map { [$0] } ?? []) + tunnels + ["Click: its session · double-click: SSH · ⋯ or right-click: everything else"])
            .joined(separator: "\n")
        return r
    }

    static func spinner() -> NSProgressIndicator {
        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.startAnimation(nil)
        return spin
    }

    /// The server's rack in `tint`, with a lock (locked) in its corner — cut out of it, so it reads over any background,
    /// the selection's included — within its size: no width taken from the name.
    static func serverIcon(_ tint: NSColor, locked: Bool) -> NSImage {
        let rack = Symbol.server.image().withSymbolConfiguration(.init(paletteColors: [tint]))!
        let lock = Symbol.lock.image()
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .bold).applying(.init(paletteColors: [.labelColor])))!
        let size = rack.size
        let image = NSImage(size: size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.beginTransparencyLayer(auxiliaryInfo: nil)   // the cut-outs clear the icon only, not what's under it
            rack.draw(in: NSRect(origin: .zero, size: size))
            func badge(_ r: NSRect, _ draw: () -> Void) {
                cg.setBlendMode(.clear)
                cg.fillEllipse(in: r.insetBy(dx: -1.5, dy: -1.5))
                cg.setBlendMode(.normal)
                draw()
            }
            if locked {
                badge(NSRect(x: size.width - lock.size.width, y: 0, width: lock.size.width, height: lock.size.height)) {
                    lock.draw(in: NSRect(x: size.width - lock.size.width, y: 0, width: lock.size.width, height: lock.size.height))
                }
            }
            cg.endTransparencyLayer()
            return true
        }
        image.accessibilityDescription = "Server" + (locked ? ", locked" : "")
        return image
    }

    @objc private func serverButton(_ sender: NSButton) {
        guard let parts = sender.identifier?.rawValue.split(separator: " ", maxSplits: 1), parts.count == 2 else { return }
        if parts[0] == "menu" || parts[0] == "tunnels" {
            for case let .server(r)? in roots.flatMap(\.children).map(\.place) where r.key == parts[1] { popMenu(r, tunnels: parts[0] == "tunnels", from: sender) }
            return
        }
        guard let action = ServerAction(rawValue: String(parts[0])) else { return }
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        for case let .server(r)? in roots.flatMap(\.children).map(\.place) where r.key == parts[1] {
            // Next turn: what it runs rebuilds the sidebar, this button's row included.
            DispatchQueue.main.async { [weak self] in self?.onServer?(r, action, mods) }
        }
    }

    /// ⋯: the row's whole menu, as a right-click shows it; ⇄: its Tunnels submenu — the same items either way.
    private func popMenu(_ r: ServerRow, tunnels: Bool, from button: NSButton) {
        let items = serverMenu?(.server(r)) ?? []
        let menu: NSMenu
        if tunnels, let it = items.first(where: { $0.title == "Tunnels" }), let sub = it.submenu {
            it.submenu = nil   // a menu pops up on its own, not as another item's submenu
            menu = sub
        } else {
            menu = NSMenu()
            items.forEach(menu.addItem)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), in: button)
    }

    // MARK: - Git, pinned under the list

    /// The Git section for the active panel's work tree; nil: it isn't in one (or its config can run commands) — no
    /// section, and the list gets the room.
    func showGit(_ row: GitRow?) {
        loadViewIfNeeded()
        guard row != gitRow else { return }
        gitRow = row
        buildGit()
    }

    private func buildGit() {
        gitBlock.arrangedSubviews.forEach { $0.removeFromSuperview() }
        gitBlock.isHidden = gitRow == nil
        guard let r = gitRow else { return }
        let line = NSBox()   // the list scrolls under the section: a line where it ends
        line.boxType = .separator
        for v in [line, gitHeader(r), gitView(r)] {
            gitBlock.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: gitBlock.widthAnchor).isActive = true
        }
    }

    /// "GIT  kermo           ⌃B", as the outline's section headers.
    private func gitHeader(_ r: GitRow) -> NSView {
        let title = NSTextField(labelWithString: "GIT")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let repo = NSTextField(labelWithString: r.repo)
        repo.font = .systemFont(ofSize: 11)
        repo.textColor = .tertiaryLabelColor
        repo.lineBreakMode = .byTruncatingTail
        repo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let key = NSTextField(labelWithString: r.server == nil ? keyFor("git.switch") : "")
        key.font = .systemFont(ofSize: 10)
        key.textColor = .tertiaryLabelColor
        let h = row([title, repo, spacer(), key])
        h.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 4, right: 25)   // in line with the outline's headers and their keys
        h.toolTip = r.server.map { "\($0):\(r.status.root)" } ?? r.status.root
        return h
    }

    /// Branch icon and name, then what there is to tell: changes (conflicts, red), ↓↑ to pull and push, a cloud for a
    /// branch no remote has yet. Under the mouse: Git Changes, Commit, Sync (or Publish) and ⋯ — on a server panel
    /// only ⋯. A click switches branch. As the server row: the row never reflows, a narrow column cuts the name.
    func gitView(_ r: GitRow) -> GitRowView {
        let st = r.status, local = r.server == nil
        let icon = NSImageView(image: Symbol.branch.image("Branch"))
        icon.contentTintColor = theme.background == nil ? Palette.secondary : theme.dir
        let name = ServerName(labelWithString: st.branch)
        name.textColor = theme.text
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.init(1), for: .horizontal)

        func chip(_ symbol: Symbol?, _ title: String, _ color: NSColor, _ id: String?, _ label: String) -> NSButton {
            let image = symbol.map { $0.image().withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))! }
            let b = id == nil ? NSButton(title: title, target: nil, action: nil) : PillButton(title: title, target: self, action: #selector(gitButton(_:)))
            b.image = image
            b.imagePosition = image == nil ? .noImage : title.isEmpty ? .imageOnly : .imageLeading
            b.imageHugsTitle = true
            b.isBordered = false
            b.font = .systemFont(ofSize: 10, weight: .semibold)
            b.contentTintColor = color
            b.identifier = id.map { .init($0) }
            b.toolTip = label
            b.setAccessibilityLabel(label)
            return b
        }
        let conflicts = st.conflicts > 0, n = r.changed
        let changeSymbol: Symbol = conflicts ? .warnFill : .changes, changeColor: NSColor = conflicts ? Palette.fail : .secondaryLabelColor
        let changeLabel = conflicts ? "\(n) file\(n == 1 ? "" : "s") in conflict" : "\(n) change\(n == 1 ? "" : "s")"
        let chips = ServerChips(views: [
            n == 0 ? nil : chip(changeSymbol, "\(n)", changeColor, nil, changeLabel),
            r.arrows.isEmpty ? nil : chip(nil, r.arrows, .secondaryLabelColor, nil, "\(st.behind) to pull, \(st.ahead) to push"),
            r.publishes ? chip(.notPublished, "", .secondaryLabelColor, nil, "Not on a remote yet") : nil,
        ].compactMap { $0 })
        let more = PillButton(image: Symbol.more.image("Git menu")
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))!, target: self, action: #selector(gitButton(_:)))
        more.isBordered = false
        more.contentTintColor = .secondaryLabelColor
        more.identifier = .init("git.menu")
        more.toolTip = "Everything Git: Switch Branch, Commit, Pull, Push, Fetch…"
        let sync = st.detached || st.gone ? nil : r.publishes
            ? chip(.notPublished, "", .secondaryLabelColor, "git.publish", "Publish Branch: push it to origin")
            : chip(.sync, r.arrows, .secondaryLabelColor, "git.sync", "Sync: pull (fast-forward only), then push")
        let toolbar = ServerToolbar(views: !local ? [more] : [
            n == 0 ? nil : chip(changeSymbol, "\(n)", changeColor, "git.changes", "Git Changes"),
            st.changes.isEmpty || conflicts ? nil : chip(.check, "", .secondaryLabelColor, "git.commit", "Commit…"),
            sync, more,
        ].compactMap { $0 })
        chips.spacing = 4
        toolbar.spacing = 2
        toolbar.isHidden = true

        let line = row([icon, name, chips, toolbar])
        line.spacing = 6
        line.edgeInsets = NSEdgeInsets(top: 0, left: 19, bottom: 0, right: 8)   // the icon under the places' icons
        let v = GitRowView()
        v.backgroundColor = .clear
        v.toolTip = r.tip()
        v.setAccessibilityRole(.button)
        v.setAccessibilityLabel("Branch \(st.branch)")
        line.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: v.leadingAnchor), line.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            line.topAnchor.constraint(equalTo: v.topAnchor), line.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            v.heightAnchor.constraint(equalToConstant: 24),
        ])
        v.onClick = { [weak self, weak more] in
            if local { self?.onGitCommand?("git.switch") } else if let more { self?.popGitMenu(from: more) }
        }
        v.menuItems = { [weak self] in self?.gitMenu?() ?? [] }
        return v
    }

    @objc private func gitButton(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if id == "git.menu" { return popGitMenu(from: sender) }
        DispatchQueue.main.async { [weak self] in self?.onGitCommand?(id) }   // what it runs may rebuild this row
    }

    private func popGitMenu(from button: NSButton) {
        let menu = NSMenu()
        (gitMenu?() ?? []).forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), in: button)
    }

    @objc private func volumeButton(_ sender: NSButton) {
        guard let parts = sender.identifier?.rawValue.split(separator: " ", maxSplits: 1), parts.count == 2,
              let action = VolumeAction(rawValue: String(parts[0])) else { return }
        for case let .volume(v) in places where v.key == parts[1] && !v.busy { onVolume?(v, action) }
    }
    @objc private func tagDot(_ sender: NSButton) { sender.identifier.map { onTag?($0.rawValue) } }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        if let s = node.section { return sectionMenu?(s.id).forEach(menu.addItem) ?? () }
        guard let place = node.place else { return }
        contextItems(place, favorite: roots.first?.children.contains { $0 === node } == true).forEach(menu.addItem)
    }

    /// A row's right-click menu: Remove from Favorites, a volume's actions, then a server's — after a line if there's
    /// anything above it.
    func contextItems(_ place: Place, favorite: Bool) -> [NSMenuItem] {   // internal for tests
        var items: [NSMenuItem] = []
        if favorite, let p = place.bookmark {
            let it = NSMenuItem(title: "Remove from Favorites", action: #selector(removeFavorite(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p
            items.append(it)
        }
        if case .volume(let v) = place {
            items += v.actions.map { a in MenuAction.item(a.rawValue) { [weak self] in self?.onVolume?(v, a) } }
        }
        let server = serverMenu?(place) ?? []
        return items + (items.isEmpty || server.isEmpty ? [] : [.separator()]) + server
    }

    var places: [Place] { roots.flatMap(\.children).compactMap(\.place) }

    private var favorites: [String] { roots.first?.children.compactMap(\.place?.bookmark) ?? [] }

    @objc private func removeFavorite(_ sender: NSMenuItem) { onFavorites?(favorites.filter { $0 != sender.representedObject as? String }) }

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
