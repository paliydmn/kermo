import AppKit
import DFMCore
import Quartz
import UniformTypeIdentifiers

@MainActor
final class PanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private(set) var path: String
    var showHidden: Bool { didSet { applyView(select: currentName) } }
    /// Permissions, Owner and Group columns (View ▸ Permissions & Owner); in a narrow panel they stay longer than Size and Modified.
    var showPerms = false { didSet { if isViewLoaded { fitColumns() } } }
    /// Only names git reports as changed (or folders with changes inside). Per panel, kept across folders.
    var gitOnly = false { didSet { applyView(select: currentName) } }
    var inGitRepo: Bool { git != nil }
    var isActive = false { didSet { styleHeader() } }
    /// With 3–4 panels: where F5/F6 from the active panel go — its path bar says "→ F5".
    var isTarget = false { didSet { styleHeader() } }

    /// The active panel: a line under its path bar in its place's color (`placeTint`), its path in full contrast; the
    /// others' path dimmed. Before the path: the place's chip — `Mac`, a server by its name with its chips, an archive,
    /// search results.
    private func styleHeader() {
        let place = remote ?? parked ?? list.map { ($0.source.target, "") }
        let chips = searchTitle == nil && archive == nil ? place.map { Chip.of($0.target) } ?? [] : []
        headerChips = chips
        if let l = list { pathBar.showPlace(.server, SavedServer.name(for: l.source.target.asUser), chips: chips, scp: nil, copy: false) }
        else if searchTitle != nil { pathBar.showPlace(.search, "", chips: [], scp: nil) }
        else if archive != nil { pathBar.showPlace(.archive, "", chips: [], scp: nil) }
        else if let p = place { pathBar.showPlace(.server, SavedServer.name(for: p.target.asUser), chips: chips, scp: Self.scpPath(p.target, p.dir)) }
        else { pathBar.showPlace(.mac, "Mac", chips: [], scp: nil) }
        pathBar.style(text: isActive ? theme.text : theme.hidden, dim: theme.hidden, mono: theme.mono)
        pathBar.line = isActive ? placeTint : nil
        targetMark.isHidden = !isTarget || list != nil   // a list takes no F5
        if isTarget { targetMark.image = Self.targetMark(placeTint) }
    }
    var targetMarkShown: Bool { !targetMark.isHidden }   // tests

    /// A server folder as scp and rsync take it: `deploy@web-01:/var/www/site` — the user's, also from a root panel.
    static func scpPath(_ t: SFTPTarget, _ dir: String) -> String { "\(t.asUser.host):\(dir)" }

    /// "→ F5" outlined in `color`: drawn each time it shows, so it follows light and dark.
    private static func targetMark(_ color: NSColor) -> NSImage {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let text = NSAttributedString(string: "→ F5", attributes: [.font: font, .foregroundColor: color])
        let image = NSImage(size: NSSize(width: ceil(text.size().width + 10), height: 15), flipped: false) { r in
            color.setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
            text.draw(at: NSPoint(x: 5, y: (r.height - font.capHeight) / 2 + font.descender))
            return true
        }
        image.cacheMode = .never
        image.accessibilityDescription = "F5 and F6 go here"
        return image
    }
    /// Where the panel is, by color: production's purple, a root panel's orange (a production one's purple), else the
    /// theme's accent.
    private var placeTint: NSColor { Chip.tint((remote?.target ?? parked?.target ?? list?.source.target).map { Chip.of($0) } ?? []) ?? theme.accent }
    var headerLine: NSColor? { pathBar.line }   // tests
    var onFocus: (() -> Void)?
    var onCommandKey: ((NSEvent) -> Bool)?
    var onCommand: ((String) -> Void)?
    var onTransfer: ((TransferItems, Endpoint, String, Bool) -> Void)?   // (what, destination side, destination dir, move)
    var onPathChange: (() -> Void)?
    /// A folder failed to list with "no such file" (a stale Favorite, a folder deleted from Finder).
    var onGone: ((String) -> Void)?
    var onCursorChange: (() -> Void)?
    let table = PanelTableView()
    private let scroll = NSScrollView()
    private let corner = PanelHeaderCorner()
    private var systemCorner: NSView?
    private var quickView: QLPreviewView?
    private var textPeek: TextPeek?   // over `quickView`, for a text Quick Look shows as an icon
    private var peekGen = 0
    private var peeked: URL?   // the file `textPeek` shows: shown again (a re-list), it keeps its scroll
    var peekedText: String? { textPeek?.isHidden == false ? textPeek?.textView.string : nil }   // tests

    let tabBar = NSStackView()   // one button per tab, each with a close × (internal: tests read it)
    let pathBar = PathBar()   // internal: tests click its crumbs
    private var pathField: NSTextField { pathBar.field }
    /// With 3–4 panels, at the end of the path bar of the one F5/F6 go to (`isTarget`).
    private var targetMark: NSImageView { pathBar.targetMark }
    private(set) var headerChips: [Chip] = []
    /// What the path bar says, as one line: "web1:/etc/nginx", "~/Projects/site", search results' title (tests).
    private(set) var headerText = ""
    /// ⌥-click on a crumb: that folder in the other panel — here, or on this panel's server.
    var onOpenInOther: ((String, SFTPTarget?) -> Void)?
    let filterField = NSTextField(string: "")   // internal: tests type into it
    private let statusLabel = NSTextField(labelWithString: "")
    private let errorIcon = NSImageView(image: Symbol.warnFill.image("Error"))
    /// The status line says what failed: red behind a warning sign, in an inactive panel too. The next status clears it.
    private(set) var statusError = false {
        didSet {
            statusLabel.textColor = statusError ? Palette.fail : theme.hidden
            errorIcon.isHidden = !statusError
        }
    }
    private let spinner = NSProgressIndicator()
    /// Next to a busy message that ⎋ cancels: the same for the mouse.
    lazy var cancelButton = Self.pill("⎋", "Cancel", target: self, action: #selector(cancelClicked))
    /// Next to search results' count: ⌫'s way back to the folder, for the mouse.
    lazy var backButton = Self.pill("⌫", "Back", target: self, action: #selector(backClicked))
    /// The status line's right end: what just is there — the branch, free space, SFTP, an archive's read-only.
    private let statusChips = NSTextField(labelWithString: "")
    private(set) var statusChipWords: [String] = []   // tests
    /// What the panel says in its middle when there's nothing to list (`empty`).
    private let emptyView = EmptyStateView()
    /// The keys there: the registry's, as the keymap has them (the app sets it).
    var keyFor: ((String) -> String?)?
    /// Shown in the status line with a spinner while a listing, connection or download is in flight.
    var busyMessage: String? {
        didSet {
            guard busyMessage != oldValue else { return }
            if oldValue == nil { busySince = Date() } else if busyMessage == nil { busySince = nil }
            updateStatus()
        }
    }
    /// Since when something is on its way: the middle says so only after a moment, so a quick listing doesn't flash it.
    private var busySince: Date?
    static let busyShows: TimeInterval = 0.4
    /// The place shown couldn't be listed, and nothing of it is: its error, for the middle. Internal: tests.
    var loadError: String? { didSet { if loadError != oldValue { updateEmpty() } } }
    /// A listing has landed: before that, no rows doesn't mean an empty folder.
    private var listedOnce = false

    private var all: [FileItem] = [] { didSet { sortedAll = nil; sorting = nil; sortGen += 1; pendingSelect = nil } }   // as listed
    /// `all` in the current sort order, cached: filtering and toggling hidden files reuse it instead of
    /// re-sorting (1M names take ~1 s to sort, 80 ms to filter).
    private var sortedAll: [FileItem]? { didSet { folded = nil } }
    private var sortedBy: (key: SortKey, ascending: Bool)?
    /// `sortedAll`'s names as masks see them, folded once a filter needs them: typing in the filter folded every name on every key.
    private var folded: Mask.Folded?
    /// What a big listing is being sorted (and folded) for off the main thread, and which listing that is (`all` changes it).
    private var sorting: (key: SortKey, ascending: Bool, fold: Bool)?
    private var sortGen = 0
    /// The name the cursor goes to once a new place's sort is back (its rows are empty till then): a tab switch keeps it.
    private var pendingSelect: String?
    /// Sorting more than this many waits for the main thread no more: it goes off it (5k names take ~4 ms).
    static let sortOnMain = 5000
    private var loadedGen = 0
    private var lastLoadSeconds = 0.0
    private var rows: [FileItem] = [] { didSet { rowIndex = nil } }   // filtered + sorted; ".." is not stored here
    /// `rows`' names to their place, built on the first lookup after they change: a folder's size coming in was a scan of them.
    private var rowIndex: [String: Int]?
    private var marked = ExactNames()   // byte for byte: two names alike in Unicode are two files
    private var filter: Mask?
    private(set) var dirSizes: [String: Int64] = [:]
    /// Server folders du couldn't read all of: their size is "at least".
    private(set) var partialSizes = Set<String>()
    /// Servers (root apart) where du doesn't count (BSD's has no -b, no shell, sudo that won't run it): their folders
    /// are walked, till quit.
    static var noDu = Set<SFTPTarget>()
    /// What asks a server's du (tests: a stand-in).
    nonisolated(unsafe) static var measureRemote: @Sendable ([String], String, SFTPTarget, [String: String], CancelFlag) throws -> [String: ServerSizes.Size]? = {
        try ServerSizes.measure($0, in: $1, on: $2, env: $3, cancel: $4)
    }
    /// What counts a local folder's bytes, looking at `isCancelled` as it goes (tests: one that waits).
    nonisolated(unsafe) static var measureLocal: @Sendable (String, () -> Bool) -> Int64 = { DirLister.measure($0, isCancelled: $1).bytes }
    private var sizeGen = 0
    /// Server folders waiting to be counted, and the walk counting them (one at a time, over one connection).
    private var sizeQueue: [String] = []
    private var sizeWalk: CancelFlag?
    /// Where each symlink of the local folder points, and the errno following it gave (0: it resolves).
    private var links: [String: (target: String, error: Int32)] = [:]
    private var totalSize: Int64 = 0
    private var freeSpace = ""
    /// What's free where the server panel is ("120 GB"), when its server tells; nil: it doesn't.
    private var remoteFree: String?
    /// `DirSync.mtimeTolerance` of the folder, read with the listing: off the main thread, where a hung mount can't freeze the UI.
    private(set) var mtimeTolerance: Double = 1
    private(set) var sortKey = SortKey.name
    private(set) var ascending = true
    private var suppressSortCallback = false
    private var loadGen = 0 { didSet { remoteFlag?.cancel(); remoteFlag = nil; moves += 1 } }   // a superseded server listing stops its ssh too
    /// `loadGen`, but a re-list of the same place (`reload`) doesn't count: ↩ or ⌘L that looked at the disk off the
    /// main thread is dropped if the user went elsewhere meanwhile, not because the folder changed.
    private var moves = 0
    /// The server listing in flight; ⎋ cancels it.
    private var remoteFlag: CancelFlag?
    /// The SFTP session this panel's listings of its server share, while it shows that server.
    private(set) var kept: KeptSession?
    /// The server calls `busy` shows, the latest last; ⎋ cancels them all.
    private var busyOps: [(flag: CancelFlag, message: String)] = []
    private var flashed: (text: String, error: Bool, until: Date)?   // until the user marks or goes elsewhere
    var flashTime: TimeInterval = 2.5   // tests on a busy Mac: longer than a re-list can take
    private var watcher: DispatchSourceFileSystemObject?
    /// The folder the watcher's fd is on: a folder replaced under the same path (`rm -rf build && mkdir build`, a
    /// swapped symlink, a branch switch) is another one, and the watcher must move to it.
    private var watchedID: FolderID?
    /// Re-stats the files on screen now and then: a growing log changes nothing the folder watcher sees.
    private var statTimer: Timer?
    private var statting: String?   // the folder being stat'ed: one stuck on a hung mount doesn't stop the next folder's
    private var reloadScheduled = false
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var quickLook: QLPreviewPanel?   // while it previews this panel's items
    private var quickLooked: [URL] = []      // what it last loaded
    private var lookCopies: [URL: URL] = [:]  // a text it would show as an icon → its `.txt` copy (`TextCopies`)
    private var lookGen = 0
    private var lookTicket = 0       // the copies' `TextCopies.ticket`
    private var lookAsked: Set<URL> = []   // past the first `TextCopies.most`: copied when Quick Look shows them
    private var previewFor: PreviewKey?   // the cursor's file last asked for: on its way, here, too big or failed (asked again once the cursor comes back)
    private var previewFlag: CancelFlag?
    struct PreviewKey: Equatable { let path: String, size: Int64, mtime: Double, link: Bool }
    private(set) var searchTitle: String?   // non-nil: showing search results (names are paths relative to `path`)
    private var searchFlag: CancelFlag?
    private var searchWhat = ""
    /// The server folder ⌘L ⇥ last listed, while the path is typed.
    private var completions: (dir: String, items: [FileItem])?
    private var completing: CancelFlag?   // the ⇥ still listing
    private var searching = false
    /// Browsing inside an archive (read-only). `path` stays the folder that contains the archive file.
    private(set) var archive: (index: ArchiveIndex, inner: String)?
    /// Browsing an SFTP server. `path` stays the local folder the panel returns to.
    private(set) var remote: (target: SFTPTarget, dir: String)? {
        didSet {
            if remote != nil { parked = nil }
            if oldValue?.target != remote?.target { styleHeader() }   // a server's colors and chips come and go
            if let k = kept, k.target != remote?.target { k.close(); kept = nil }   // left that server (another tab too)
            guard oldValue?.target != remote?.target || oldValue?.dir != remote?.dir else { return }
            stopPreview()
            onSessionsChange?()
        }
    }
    /// A server tab back from a restart, not connected: the header says where, its one row that ↩ connects (as
    /// Connect does: a locked server asks first). Nothing is asked of the server till then, and it isn't an open
    /// session (`remoteTabs`); any other way out goes to `path`, the tab's local folder.
    private(set) var parked: (target: SFTPTarget, dir: String)? { didSet { styleHeader() } }
    /// What a parked panel says to whatever would act on its files: the server by its saved name, else its address.
    var parkedHint: String? {
        parked.map { "Not connected — ↩ Connect to \(SavedServer.name(for: $0.target))".bidiVisible }
    }

    /// A list in place of the folder (`showList`): a server's services, containers, ports — its rows, its columns, its
    /// keys. Nothing of the folder behind it is on screen, nor acted on.
    private(set) var list: ListPanel?
    /// The server's place (`onPlace`): ⌫ from a list or a server's `/`, a click on the path bar's chip, a restart.
    var isPlace: Bool { list?.source is PlaceSource }
    /// Its server's place in this panel, the cursor on a row (the list ⌫ came back from: "Services"; "/").
    var onPlace: ((SFTPTarget, String?) -> Void)?
    /// What a list says to whatever would act on files: it isn't a folder.
    var listHint: String? { list.map { "\($0.source.title) isn't a folder — ↩ acts on a row, ⌫ goes back" } }
    /// The server the panel is on: a server folder's, a list's or a parked tab's.
    var server: SFTPTarget? { remote?.target ?? list?.source.target ?? parked?.target }
    /// A list's ↩, ⌘C and the like by the mouse (a double-click, Edit ▸ Copy): what the app runs for the key.
    var onListKey: ((Shortcut) -> Void)?
    /// A list row's menu (⌃↩, ⇧F10, a right-click), filled by the app.
    var onListMenu: ((NSMenu) -> Void)?
    /// A list's rows or marks changed: the menu's keys, the key bar.
    var onListChange: (() -> Void)?
    /// A server being connected to (first listing still running), for the sidebar.
    private(set) var connecting: SFTPTarget? { didSet { if connecting != oldValue { onSessionsChange?() } } }
    var onSessionsChange: (() -> Void)?
    var onRemoteResult: ((SFTPTarget, String?) -> Void)?   // a listing came back: nil, or the error
    /// The folder's `git status`: the column, the branch in the status line, the sidebar's Git section.
    private(set) var git: GitStatus?
    var onGitChange: (() -> Void)?
    private var theme = Theme.current

    /// `path` is the local folder; with `remote` set the tab is on a server and returns to `path` when it leaves.
    struct Tab {
        let id = UUID()   // the sidebar finds an SFTP session by it
        var path: String
        var cursor: String? = nil
        var back: [String] = []
        var forward: [String] = []
        var remote: (target: SFTPTarget, dir: String)? = nil
        var parked: (target: SFTPTarget, dir: String)? = nil   // a server tab restored, not connected
        var marked = ExactNames()
        var filter = ""
        var list: ListPanel? = nil   // a list shown in the tab (`showList`)
        var place: SFTPTarget? = nil   // a server's place back from a restart, shown once the tab is
    }
    private var tabs: [Tab]
    private(set) var tabIndex: Int

    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let fileIcon = NSWorkspace.shared.icon(for: .data)
    private static let execIcon = NSWorkspace.shared.icon(for: .unixExecutable)   // as Finder: told by shape, in any theme
    private static let linkIcon = NSWorkspace.shared.icon(for: .symbolicLink)
    /// Today and yesterday as of the last listing; the stat timer moves it on at midnight.
    private(set) var dates = DateColumn()

    convenience init(tabs paths: [String], index: Int, showHidden: Bool) {
        self.init(session: paths.map { Session.Tab(path: $0) }, index: index, showHidden: showHidden)
    }

    /// Server tabs come back parked: nothing connects till ↩.
    init(session saved: [Session.Tab], index: Int, showHidden: Bool) {
        tabs = (saved.isEmpty ? [Session.Tab(path: NSHomeDirectory())] : saved).map { t in
            Tab(path: t.path, cursor: t.cursor, parked: t.server.flatMap { s in t.dir.map { (s.asRoot(t.root), $0) } }, place: t.place == true ? t.server : nil)
        }
        tabIndex = min(max(index, 0), tabs.count - 1)
        path = tabs[tabIndex].path
        self.showHidden = showHidden
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Row mapping & targets

    private var hasParent: Bool { parked == nil && list == nil && (remote != nil || archive != nil || searchTitle != nil || path != "/") }   // ".." leaves results/archives
    func item(at row: Int) -> FileItem? {     // nil == ".." (and a parked tab's one row; a list's rows aren't files)
        guard parked == nil, list == nil else { return nil }
        return hasParent ? (row == 0 ? nil : rows[row - 1]) : rows[row]
    }
    private func row(named name: String) -> Int? {
        if rowIndex == nil { rowIndex = Dictionary(rows.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a }) }
        return rowIndex![name].map { $0 + (hasParent ? 1 : 0) }
    }
    private func url(of item: FileItem) -> URL {
        URL(fileURLWithPath: (itemsDir as NSString).appendingPathComponent(item.name), isDirectory: item.kind == .dir)
    }
    /// What the rows' names are relative to: the folder, or a search's root — a tag search's is ~ wherever the panel
    /// is, and its hits' names (`Documents/x.pdf`) went onto `path`: ⇧F8 there deleted another folder's file.
    var itemsDir: String { searchTitle != nil ? searchRoot ?? path : path }
    private var searchRoot: String?
    var currentName: String? {
        let r = table.selectedRow
        return r >= 0 && r < table.numberOfRows ? item(at: r)?.name : nil
    }

    /// The item under the cursor (nil on "..", and inside archives, where nothing is a real file).
    /// The folder shown, when it's a plain one of this Mac's (not a server's, an archive or search results): only
    /// then is `path` what's on screen.
    var plainFolder: String? { remote == nil && parked == nil && archive == nil && searchTitle == nil && list == nil ? path : nil }

    /// What ⌘I shows: the cursor's file or the folder; inside an archive, the archive itself; nothing on a server.
    var infoURL: URL? {
        guard remote == nil, list == nil else { return nil }
        if let a = archive { return URL(fileURLWithPath: a.index.file) }
        return (forFolder ? nil : cursorURL) ?? URL(fileURLWithPath: path)
    }

    var cursorURL: URL? {
        guard archive == nil, remote == nil else { return nil }
        let r = table.selectedRow
        guard r >= 0, r < table.numberOfRows, let it = item(at: r) else { return nil }
        return url(of: it)
    }

    /// Marked items, or the cursor item if nothing is marked.
    var targetItems: [FileItem] {
        guard archive == nil, remote == nil else { return [] }
        if !marked.isEmpty { return rows.filter { marked.contains($0.name) } }
        let r = table.selectedRow
        return r >= 0 && r < table.numberOfRows ? item(at: r).map { [$0] } ?? [] : []
    }

    /// Items as a question lists them: a mark, the name, the size as the Size column shows it (a folder's once counted).
    func listed(_ items: [FileItem]) -> [Confirm.Item] {
        items.map { Confirm.Item(name: $0.name, symbol: $0.kind == .dir ? .folder : .doc,
                                 size: Self.sizeText($0, measured: dirSizes[$0.name], partial: partialSizes.contains($0.name))) }
    }
    /// `targetURLs` that way: one this panel lists has its size, any other (the folder itself) only its name.
    func listed(_ urls: [URL]) -> [Confirm.Item] {
        urls.map { u in
            row(named: u.lastPathComponent).flatMap(item(at:)).flatMap { url(of: $0).path == u.path ? listed([$0])[0] : nil }
                ?? Confirm.Item(name: u.lastPathComponent)
        }
    }

    /// `targetItems` with the code the git column shows for each (nil: unchanged, or not in a repo).
    var gitTargets: [(url: URL, code: String?)] { targetItems.map { (url(of: $0), git?.marks[$0.name]) } }

    /// This Mac, or the server the panel is on.
    var endpoint: Endpoint { remote.map { .sftp($0.target) } ?? .local }
    /// The folder shown, on the panel's side: where copies into this panel land.
    var currentDir: String { remote?.dir ?? path }

    /// The marked items (or the cursor's) as paths on the panel's side, for copy and move.
    var transferItems: TransferItems? {
        if let sel = remoteSelection {
            return TransferItems(from: .sftp(sel.target), paths: sel.items.map { (sel.dir as NSString).appendingPathComponent($0.name) })
        }
        let urls = targetURLs
        return urls.isEmpty ? nil : TransferItems(from: .local, paths: urls.map(\.path))
    }

    /// What an operation acts on: the marked items, or the cursor item if nothing is marked.
    /// Copy Path / Copy Name: `targetURLs`' paths; on a server, the paths there (the folder's from its menu).
    var targetPaths: [String] {
        guard let r = remote else { return targetURLs.map(\.path) }
        if forFolder { return [r.dir] }
        return (remoteSelection?.items ?? []).map { (r.dir as NSString).appendingPathComponent($0.name) }
    }

    var targetURLs: [URL] {
        guard archive == nil, remote == nil else { return [] }
        if forFolder { return [URL(fileURLWithPath: path)] }
        return marked.isEmpty ? (cursorURL.map { [$0] } ?? []) : rows.filter { marked.contains($0.name) }.map(url(of:))
    }

    // MARK: - View

    override func loadView() {
        // Name starts narrow: a table wider than its clip view at first layout never tracks the panel's width, so
        // Size and Modified would stay cut off in a narrow panel. Name grows to fill (firstColumnOnlyAutoresizingStyle).
        for (id, title, width) in [("name", "Name", 60.0), ("git", "Git", 26), ("size", "Size", 80), ("mtime", "Modified", 125),
                                   ("mode", "Permissions", 72), ("owner", "Owner", 60), ("group", "Group", 60)] {
            let col = NSTableColumn(identifier: .init(id))
            col.headerCell = PanelHeaderCell()
            col.title = title
            col.width = width
            col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "name")
            if id != "name" { col.headerCell.alignment = .right }
            if id == "git" {
                col.sortDescriptorPrototype = nil
                col.headerCell.alignment = .center
                col.isHidden = true   // shown only inside a git work tree
            }
            if Self.permColumns.contains(id) {
                col.sortDescriptorPrototype = nil
                col.isHidden = true
            }
            table.addTableColumn(col)
        }
        let fit = Self.widths(font: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular))
        table.tableColumn(withIdentifier: .init("size"))?.width = fit.size
        table.tableColumn(withIdentifier: .init("mtime"))?.width = fit.date
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true   // only used transiently for drags; see selectionIndexesForProposedSelection
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onKey = { [unowned self] in handleKey($0) }
        table.onFocusChange = { [unowned self] in if $0 { onFocus?() } }
        table.onMarkClick = { [unowned self] row, mods in markClick(row, mods) }
        table.onSelectAll = { [unowned self] in markAll() }
        table.onFind = { [unowned self] in onCommand?("search") }
        table.dragRows = { [unowned self] row in
            guard let it = item(at: row), marked.contains(it.name), marked.count > 1 else { return nil }
            return IndexSet(rows.indices.filter { marked.contains(rows[$0].name) }.map { $0 + (hasParent ? 1 : 0) })
        }
        table.registerForDraggedTypes([.fileURL, TransferItems.remoteType])
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        table.menu = NSMenu()
        table.menu?.delegate = self

        systemCorner = table.cornerView
        corner.frame = systemCorner?.frame ?? .zero
        scroll.documentView = table
        scroll.verticalScroller = ThemeScroller()
        scroll.hasVerticalScroller = true

        tabBar.distribution = .fillEqually
        tabBar.spacing = 2

        for f in [pathField, filterField] {
            f.isBordered = false
            f.isBezeled = false
            f.drawsBackground = f === filterField
            f.focusRingType = .none
            f.cell?.usesSingleLineMode = true
            f.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            f.delegate = self
        }
        filterField.placeholderString = "Filter: text, *.log or re:regex"
        filterField.isHidden = true
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.setContentHuggingPriority(.init(1), for: .horizontal)   // the chips at the right end
        statusLabel.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        statusChips.lineBreakMode = .byTruncatingHead   // narrow, the chips give way before what's on the left
        statusChips.setContentCompressionResistancePriority(.init(260), for: .horizontal)

        pathBar.onEdit = { [unowned self] in beginPathEditing() }
        pathBar.onCrumb = { [unowned self] in goTo($0, otherPanel: $1.contains(.option)) }
        pathBar.onCopy = { [unowned self] in copyPath(scp: $0) }
        pathBar.onFilter = { [unowned self] in beginFilter() }
        pathBar.onPlace = { [unowned self] in   // the server's chip: its place
            guard let t = server, !isPlace, parked == nil else { return }
            view.window?.makeFirstResponder(table)   // the keys come here, as a click in the list
            onPlace?(t.asUser, list?.source.title ?? (remote?.dir == "/" ? "/" : nil))
        }
        pathBar.validateDrop = { [unowned self] crumb, info in
            guard archive == nil, parked == nil, searchTitle == nil, list == nil, let dir = crumb.path, let items = Self.dropped(info) else { return [] }
            return Self.dragOperation(info, items: items, to: endpoint, target: dir)
        }
        pathBar.acceptDrop = { [unowned self] crumb, info in   // as a drop on a folder's row
            guard archive == nil, parked == nil, searchTitle == nil, list == nil, let dir = crumb.path, let items = Self.dropped(info) else { return false }
            let operation = Self.dragOperation(info, items: items, to: endpoint, target: dir)
            guard !operation.isEmpty else { return false }
            onTransfer?(items, endpoint, dir, operation == .move)
            return true
        }
        header = Self.column([tabBar, pathBar])
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        errorIcon.contentTintColor = Palette.fail
        errorIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        errorIcon.isHidden = true
        footer = Self.column([filterField, NSStackView(views: [spinner, errorIcon, statusLabel, cancelButton, backButton, statusChips])])
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        for sub in [header, scroll, footer] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
            NSLayoutConstraint.activate([sub.leadingAnchor.constraint(equalTo: v.leadingAnchor), sub.trailingAnchor.constraint(equalTo: v.trailingAnchor)])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 3),
            footer.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4),
        ])
        emptyView.place(over: scroll, in: v)
        emptyView.onKey = { [unowned self] in emptyKey($0) }
        view = v
        isActive = false
        updateTabBar()
        applyTheme()
    }

    func applyTheme() {
        theme = Theme.current
        list?.theme = theme
        table.usesAlternatingRowBackgroundColors = theme.background == nil
        table.backgroundColor = theme.background ?? .controlBackgroundColor
        scroll.backgroundColor = table.backgroundColor
        table.gridStyleMask = theme.grid == nil ? [] : .solidVerticalGridLineMask
        table.gridColor = theme.grid ?? .gridColor
        for c in table.tableColumns { (c.headerCell as? PanelHeaderCell)?.fill = theme.background }
        corner.cell.fill = theme.background
        table.cornerView = theme.background == nil ? systemCorner : corner
        (scroll.verticalScroller as? ThemeScroller)?.fill = theme.background
        table.headerView?.needsDisplay = true
        scroll.tile()
        corner.needsDisplay = true
        scroll.verticalScroller?.needsDisplay = true
        filterField.backgroundColor = theme.cursor ?? .controlBackgroundColor
        filterField.textColor = theme.text
        if statusError { statusLabel.textColor = Palette.fail } else { updateStatus() }   // the marks' color, the middle's
        styleHeader()
        let r = table.selectedRow
        table.reloadData()   // drops the selection: the cursor stays where it was
        if r >= 0 { moveCursor(to: r, scroll: false) }
    }

    /// Vertical stack whose (visible) children span its full width with a small side inset.
    private static func column(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.spacing = 3
        s.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        for v in views {
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.widthAnchor.constraint(equalTo: s.widthAnchor, constant: -12).isActive = true
        }
        return s
    }

    /// Over the rows and under them: a list's line about itself and how its actions went join these (`show`).
    private var header: NSStackView!
    private var footer: NSStackView!

    private static let permColumns: Set<String> = ["mode", "owner", "group"]
    /// A server folder's owner and group per name, as its listing printed them (names, or the server's numbers).
    private var remoteOwners: [String: (String, String)] = [:]

    override func viewDidLayout() {
        super.viewDidLayout()
        fitColumns()
    }

    /// Name keeps a readable width: in a narrow panel (4 panels side by side) Modified makes room first, then Size;
    /// both come back when the panel widens. Dragged widths count, so a widened column gives way sooner.
    private func fitColumns() {
        if let list { return list.fit(scroll.contentSize.width) }
        let gap = table.intercellSpacing.width
        var room = scroll.contentSize.width - 120 - gap
        // Asked for, the permission columns keep their room before Size and Modified.
        let (perms, rest) = (table.tableColumns.filter { Self.permColumns.contains($0.identifier.rawValue) },
                             table.tableColumns.filter { !Self.permColumns.contains($0.identifier.rawValue) })
        for col in perms + rest where col.identifier.rawValue != "name" {
            if col.identifier.rawValue == "git" {   // shown by git status, not by width
                if !col.isHidden { room -= col.width + gap }
                continue
            }
            if !showPerms && Self.permColumns.contains(col.identifier.rawValue) {
                col.isHidden = true
                continue
            }
            room -= col.width + gap
            if col.isHidden != (room < 0) { col.isHidden = room < 0 }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadSort(for: path)
        if let p = tabs[tabIndex].parked { park(p) }
        else if let pt = tabs[tabIndex].place {   // a restart's place: nothing asked — once the app is up (its terminal, its sidebar)
            let cursor = tabs[tabIndex].cursor
            DispatchQueue.main.async { [weak self] in
                guard let self, tabs[tabIndex].place == pt else { return }
                if let onPlace { onPlace(pt, cursor) } else { navigate(to: path, history: .none) }
            }
        } else { navigate(to: path, select: tabs[tabIndex].cursor, history: .none) }
        statTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view.window?.occlusionState.contains(.visible) == true,
                      !self.view.isHiddenOrHasHiddenAncestor else { return }
                self.rollDates()
                self.refreshStats()
            }
        }
    }

    // MARK: - Loading

    enum History { case push, back, forward, none }

    /// A tab's own marks and filter, put back once its listing is on screen (not before: they'd act on the old rows).
    typealias TabMarks = (marked: ExactNames, filter: String)

    /// `keep`: a tab switch brings back that tab's marks and filter instead of starting clean.
    func navigate(to newPath: String, select: String? = nil, history: History = .push, keep: TabMarks? = nil) {
        loadGen += 1
        connecting = nil   // a pending server listing is dropped too
        let gen = loadGen
        let started = Date()
        // Set before the sort: the rows come from it (`sortedAll`), and the resolve after finds nothing to change.
        let linkDirs = newPath == path && watcher != nil ? Set(all.filter(\.linkDir).map(\.name)) : []
        // A re-list (the watcher's, mostly) that finds what's shown: told off the main thread, so it costs it nothing.
        let shown = newPath == path && watcher != nil && select == nil && keep == nil ? all : nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.loadGen, self.loadedGen < gen else { return }
                self.busyMessage = "Loading \((newPath as NSString).abbreviatingWithTildeInPath)…"
            }
        }
        Task { [weak self] in
            // Disk work and sorting off the main thread: a hung network volume or a 1M-file folder must never freeze the UI.
            let result = await Self.listings.run(newPath, .userInitiated) {
                Result {
                    let items = try DirLister.list(newPath).keepingLinkDirs(linkDirs)
                    let order = Self.savedSort(for: newPath)
                    return (items, Self.freeSpace(newPath), items.sortedForPanel(by: order.key, ascending: order.ascending), order,
                            DirSync.mtimeTolerance([newPath]), FolderID(path: newPath))
                }
            }
            // Not in the listing's work: another panel's call may have run that one, against its own rows.
            // Names byte for byte: `==` takes "é" and "e\u{301}" (a rename from one to the other) for the same.
            var same = false
            if let shown, case .success(let r) = result {
                same = await Blocking.run(.userInitiated) { r.0 == shown && zip(r.0, shown).allSatisfy { $0.name.utf8.elementsEqual($1.name.utf8) } }
            }
            guard let self, gen == loadGen else { return }
            loadedGen = gen
            busyMessage = busyOps.last?.message
            lastLoadSeconds = Date().timeIntervalSince(started)
            loadError = nil
            switch result {
            case .success(let (items, free, _, _, tolerance, folder)) where same && newPath == path && watcher != nil:
                // Nothing changed: the rows, marks, cursor and sort stay; the free space, git status and links may have.
                freeSpace = free
                mtimeTolerance = tolerance
                if folder != watchedID { watch() }
                updateStatus()
                refreshGit()
                resolveLinks(items, in: newPath, gen: gen)
            case .success(let (items, free, sorted, order, tolerance, folder)):
                var old = path, history = history
                let changed = newPath != old || watcher == nil
                if changed, remote != nil, history == .push {
                    // A local place (sidebar, ⌘P, Home…) from a server tab opens in a tab of its own: the server's stays.
                    // Leaving the server (`..` at its root, the tab's ×) comes with `.none`.
                    saveTab()
                    tabs.insert(Tab(path: newPath), at: tabIndex + 1)
                    tabIndex += 1
                    (backStack, forwardStack, old, history) = ([], [], newPath, .none)
                }
                path = newPath
                all = items   // a re-list's links to folders: as known before (`keepingLinkDirs`), resolved again below
                (sortedAll, sortedBy) = (sorted, order)
                freeSpace = free
                mtimeTolerance = tolerance
                var select = select
                if changed {
                    leaveList()
                    archive = nil
                    remote = nil
                    parked = nil
                    if searchTitle != nil {
                        searchFlag?.cancel()
                        searchTitle = nil
                        searching = false
                    }
                    marked.removeAll()
                    if filter != nil { clearFilter(apply: false) }
                    clearSizes()
                    links.removeAll()
                    git = nil   // the old folder's marks would filter this one until its status arrives
                    switch history {
                    case .push: backStack.append(old); forwardStack.removeAll()
                    case .back: forwardStack.append(old)
                    case .forward: backStack.append(old)
                    case .none: break
                    }
                    // Coming up out of a subfolder: land the cursor on it.
                    if select == nil, old.hasPrefix(newPath == "/" ? "/" : newPath + "/") {
                        select = String(old.dropFirst(newPath == "/" ? 1 : newPath.count + 1).split(separator: "/").first ?? "")
                    }
                    if pathField.currentEditor().map({ $0 === view.window?.firstResponder }) == true { styleHeader() } else { showPath() }   // typed in: kept
                    loadSort(for: newPath)
                    watch()
                    updateTabBar()
                    onPathChange?()
                } else {
                    select = select ?? currentName   // where the cursor is now, not when the reload started
                    if !marked.isEmpty { marked.formIntersection(items.map(\.name)) }
                    if folder != watchedID { watch() }
                }
                if let keep { restore(keep, in: items) }
                applyView(select: select, newFolder: changed)
                refreshGit()
                resolveLinks(items, in: newPath, gen: gen)
            case .failure(let error):
                NSSound.beep()
                if newPath == path && all.isEmpty && parked == nil { loadError = error.localizedDescription }   // nothing of it shown: the middle says so too
                statusLabel.stringValue = "\((newPath as NSString).abbreviatingWithTildeInPath): \(error.localizedDescription)"
                statusError = true
                if (error as? POSIXError)?.code == .ENOENT { onGone?(newPath) }
                if newPath == path && hasParent && history == .none && !all.isEmpty && remote == nil, archive == nil, searchTitle == nil {
                    // The folder shown vanished or became unreadable: up to the nearest one still there — its parent
                    // may be gone too (an unplugged disk: /Volumes).
                    let m = moves
                    Task { [weak self] in
                        let up = await Blocking.run(.userInitiated) { Self.nearestFolder(above: newPath) }
                        guard let self, m == moves else { return }
                        navigate(to: up)
                    }
                } else if all.isEmpty && parked == nil && newPath != NSHomeDirectory() {   // parked: it stays, the error said
                    navigate(to: NSHomeDirectory(), history: .none)   // e.g. restored path no longer exists
                }
            }
        }
    }

    /// The closest folder above `path` that is there (off the main thread: a share that stopped answering).
    nonisolated static func nearestFolder(above path: String) -> String {
        var p = (path as NSString).deletingLastPathComponent
        while p != "/" {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return p }
            p = (p as NSString).deletingLastPathComponent
        }
        return "/"
    }

    /// All panels and tabs: on a dead mount the listing hangs for good, and each reload would hang another thread.
    static let listings = Coalesced<Result<([FileItem], String, [FileItem], (key: SortKey, ascending: Bool), Double, FolderID?), Error>>()

    /// Stops background work before the panel is removed.
    func shutdown() {
        watcher?.cancel()
        watcher = nil
        statTimer?.invalidate()
        searchFlag?.cancel()
        completing?.cancel()
        sizeWalk?.cancel()
        stopPreview()
    }

    /// Search results and archives stay as they are: re-listing `path` would replace them with the folder.
    func reload(select: String? = nil) {
        guard archive == nil, searchTitle == nil, parked == nil, list == nil else { return }   // a list: ⌘R reads it (`readList`)
        let m = moves
        defer { moves = m }
        if let r = remote { return loadRemote(r.target, dir: r.dir, select: select) }
        navigate(to: path, select: select, history: .none)
    }

    private nonisolated static func freeSpace(_ path: String) -> String {
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return freeText(important: v?.volumeAvailableCapacityForImportantUsage, available: v?.volumeAvailableCapacity)
    }

    /// "Important usage" counts what APFS would purge; FAT32 and exFAT (fskit) say 0 there: then the plain figure.
    nonisolated static func freeText(important: Int64?, available: Int?) -> String {
        let free = important.flatMap { $0 > 0 ? $0 : nil } ?? available.map(Int64.init)
        return free.map { ByteCountFormatter.short($0) } ?? "?"
    }

    /// `newFolder`: without `name` the cursor starts on the first row instead of keeping its row number.
    private func applyView(select name: String?, newFolder: Bool = false) {
        guard list == nil else { return }   // its rows are the list's
        if newFolder { flashed = nil }
        let oldRow = table.selectedRow, oldName = currentName
        let cursorShown = NSLocationInRange(oldRow, table.rows(in: table.visibleRect))
        let fresh = sortedAll != nil && sortedBy?.key == sortKey && sortedBy?.ascending == ascending
        if !fresh || filter != nil && folded == nil {
            // A search still running sorts and folds here, as each batch arrives: one off the main thread would be
            // outdated by the next batch before it's back.
            guard all.count <= Self.sortOnMain || searching else { return sortOffMain(select: name, newFolder: newFolder) }
            if !fresh { (sortedAll, sortedBy) = (all.sortedForPanel(by: sortKey, ascending: ascending), (sortKey, ascending)) }
            if filter != nil { folded = Mask.Folded(sortedAll!.lazy.map(\.name)) }
        }
        // Results already went through the search's (or git's) own idea of hidden; ⌘⇧. would drop .gitignore.
        // All in locals: a property of `self` read per row is a main-actor check per row (a third of a 1M filter).
        let sorted = sortedAll!, changed = gitOnly ? git?.marks : nil, mask = filter, names = folded, hidden = showHidden || searchTitle != nil
        rows = sorted.indices.filter { i in
            let it = sorted[i]
            return (hidden || !it.isHidden) && (mask.map { $0.matches(i, of: names!, name: it.name) } ?? true)
                && (changed?[it.name] != nil || changed == nil)
        }.map { sorted[$0] }
        totalSize = bytes(of: rows)
        listedOnce = true
        guard isViewLoaded else { return }
        dates = DateColumn()
        table.reloadData()   // drops the selection: Quick Look is told once the cursor is back
        let r = name.flatMap(row(named:)) ?? (newFolder ? 0 : max(0, oldRow))
        // Scrolled away from the cursor (to watch a log grow): a re-list that leaves it on the same row doesn't scroll back.
        moveCursor(to: r, scroll: newFolder || cursorShown || name != oldName || r != oldRow)
        reloadQuickLook()
        updateStatus()
    }

    /// A big listing in another order (a header click, search results done, links to folders found): sorted off the
    /// main thread, the rows on screen staying as they are till it's back; the cursor stays on its name. Rows of
    /// another place (an archive's folder) go at once: they mustn't pass for these. One sort per order at a time.
    private func sortOffMain(select name: String?, newFolder: Bool) {
        let key = sortKey, asc = ascending, fold = filter != nil, items = all, gen = sortGen
        let done = sortedBy?.key == key && sortedBy?.ascending == asc ? sortedAll : nil   // only the names to fold
        // The cursor where it is when the sort is back (it may move on the rows meanwhile), unless sent to a name.
        let keepCursor = !newFolder && name == currentName
        if newFolder { rows = []; totalSize = 0; pendingSelect = name; table.reloadData(); updateStatus() }
        // On its way: it shows what's asked by then.
        guard sorting.map({ $0.key != key || $0.ascending != asc || fold && !$0.fold }) ?? true else { return }
        sorting = (key, asc, fold)
        if done == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, gen == self.sortGen, self.sorting != nil, self.busyMessage == nil else { return }
                    self.busyMessage = "Sorting…"
                }
            }
        }
        Task { [weak self] in
            let (sorted, names) = await Blocking.run(.userInitiated) { () -> ([FileItem], Mask.Folded?) in
                let sorted = done ?? items.sortedForPanel(by: key, ascending: asc)
                return (sorted, fold ? Mask.Folded(sorted.lazy.map(\.name)) : nil)
            }
            guard let self else { return }
            if gen == sortGen, sorting.map({ $0.key == key && $0.ascending == asc && $0.fold == fold }) == true { sorting = nil }
            if sorting == nil, busyMessage == "Sorting…" { busyMessage = busyOps.last?.message }
            guard gen == sortGen, key == sortKey && asc == ascending else { return }   // clicked again: that sort shows
            (sortedAll, sortedBy) = (sorted, (key, asc))
            folded = names
            let select = keepCursor ? currentName : name ?? pendingSelect
            pendingSelect = nil
            applyView(select: select, newFolder: newFolder)
        }
    }

    /// Kernel tells us when the directory changes; coalesce bursts into one reload.
    private func watch() {
        watcher?.cancel()
        watcher = nil
        watchedID = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedID = FolderID(fd: fd)
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleReload() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    /// A local folder's files on screen whose size or date changed (or the folder replaced under its path) re-list
    /// it. Off the main thread; never for a server, an archive or search results.
    /// Past midnight, "Today" is yesterday (and `isoDates` may have changed): the Modified column says so without a re-list.
    func rollDates() {
        let now = DateColumn()
        guard now != dates else { return }
        dates = now
        let col = table.column(withIdentifier: .init("mtime"))
        if col >= 0 { table.reloadData(forRowIndexes: IndexSet(0..<table.numberOfRows), columnIndexes: [col]) }
    }

    func refreshStats() {
        guard watcher != nil, remote == nil, archive == nil, searchTitle == nil, loadedGen == loadGen,
              statting != path, !reloadScheduled, !scroll.isHidden else { return }
        let range = table.rows(in: table.visibleRect)
        let shown = (range.lowerBound..<range.upperBound).compactMap(item(at:)).filter { $0.kind == .file }
        let dir = path, folder = watchedID
        statting = dir
        Task { [weak self] in
            let stale = await Blocking.run(.utility) {
                FolderID(path: dir) != folder || shown.contains { f in
                    var s = stat()
                    guard lstat((dir as NSString).appendingPathComponent(f.name), &s) == 0 else { return false }
                    return s.st_size != f.size || Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9 != f.mtime
                }
            }
            guard let self else { return }
            if statting == dir { statting = nil }
            if stale, dir == path, watcher != nil { scheduleReload() }
        }
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        // A folder that takes seconds to list (huge, or on the network) is re-listed less often.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.15, lastLoadSeconds * 2)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadScheduled = false
                self.reload()
            }
        }
    }

    /// The status line (R-28): on the left what matters while you work — the marked ones in the marks' color, else how
    /// many there are; what the list is (filtered, git changes, found); on the right what just is there, as chips. No
    /// keys: ⎋ and ⌫ are the pills beside it, F5 in an archive says Extract in the key bar.
    private func updateStatus() {
        defer { updateEmpty() }
        let busy = busyMessage != nil || searching
        spinner.isHidden = !busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        statusError = false
        let cancellable = busyMessage?.hasSuffix(" ⎋ cancels") == true
        cancelButton.isHidden = !cancellable
        backButton.isHidden = searchTitle == nil
        showFilterChip()
        if let busyMessage { return say(cancellable ? String(busyMessage.dropLast(" ⎋ cancels".count)) : busyMessage) }
        // A message just flashed stays its time through a re-list, a git status or a folder size coming in.
        if let f = flashed, f.until > Date() { statusError = f.error; return say(f.text) }
        if parked != nil { return say("Not connected", chips: [("SFTP", nil)]) }
        if let l = list {   // the rows, or the marked ones; what the filter left; the connection it's on
            var parts = [l.marked.isEmpty ? Self.countText(l.shown.count, "rows", 0) : Self.countText(l.marked.count, "marked", 0)]
            if !l.filter.isEmpty { parts.append("filtered: \(l.shown.count) of \(l.count)") }
            return say(parts.joined(separator: " · "), lead: l.marked.isEmpty ? 0 : parts[0].count,
                       chips: AppDelegate.connected(l.source.target) ? [("SSH", nil)] : [])   // the connection it's on, when there's one
        }
        var parts: [String] = []
        if !marked.isEmpty { parts.append(Self.countText(marked.count, "marked", bytes(of: rows.filter { marked.contains($0.name) }))) }
        if searchTitle != nil { parts.append("\(searchWhat): " + (searching ? "searching… " : "") + "\(all.count) found") }
        else if marked.isEmpty { parts.append(Self.countText(rows.count, "items", remote == nil ? totalSize : 0)) }
        if filter != nil { parts.append("filtered: \(rows.count) of \(all.count)") }
        if gitOnly && git != nil { parts.append("git changes: \(rows.count) of \(all.count)") }
        var chips: [(String, Symbol?)] = []
        if let g = git { chips.append((g.branch + (g.ahead > 0 ? " ↑\(g.ahead)" : "") + (g.behind > 0 ? " ↓\(g.behind)" : ""), .branch)) }
        if remote == nil { chips.append(("\(freeSpace) free", nil)) } else if let f = remoteFree { chips.append(("\(f) free", nil)) }
        if remote != nil { chips.append(("SFTP", nil)) }
        if let a = archive { chips.append(("\(a.index.format) · read-only", nil)) }
        say(parts.joined(separator: " · "), lead: marked.isEmpty ? 0 : parts[0].count, chips: chips)
    }

    /// The status line's words, the first `lead` characters (the marked count) bold in the marks' color, and its chips.
    private func say(_ text: String, lead: Int = 0, chips: [(words: String, symbol: Symbol?)] = []) {
        let font = statusLabel.font ?? .systemFont(ofSize: 11)
        let s = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: statusError ? Palette.fail : theme.hidden])
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        if lead > 0 { s.addAttributes([.font: bold, .foregroundColor: theme.marked], range: NSRange(location: 0, length: (text.prefix(lead) as Substring).utf16.count)) }
        statusLabel.attributedStringValue = s
        statusChipWords = chips.map(\.words)
        let c = NSMutableAttributedString()
        for (w, symbol) in chips {
            if c.length > 0 { c.append(NSAttributedString(string: "  ")) }
            c.append(Chip.plain(w.bidiVisible, symbol: symbol))
        }
        statusChips.attributedStringValue = c
        statusChips.setAccessibilityLabel(statusChipWords.joined(separator: ", "))
    }

    /// "7 items · 1.2 MB" — or "7 items" with nothing to add up (folders count once measured, on Space): "Zero KB" said nothing.
    static func countText(_ n: Int, _ noun: String, _ bytes: Int64) -> String {
        "\(n) \(n == 1 && ["items", "rows"].contains(noun) ? String(noun.dropLast()) : noun)" + (bytes > 0 ? " · " + ByteCountFormatter.short(bytes) : "")
    }

    // MARK: - The middle, when there's nothing to list (R-26)

    /// What the panel says in its middle, from what it knows already.
    struct Empty: Equatable {
        var symbol: Symbol?   // nil: a spinner
        var title: String
        var detail = ""
        var keys: [KeySlot] = []
    }

    var empty: Empty? {
        func slot(_ id: String, _ label: String, _ key: String) -> KeySlot { KeySlot(key: keyFor?(id) ?? key, label: label, id: id) }
        let cancel = KeySlot(key: "⎋", label: "Cancel", id: "cancel")
        guard quickBox == nil, list?.shown.isEmpty ?? rows.isEmpty else { return nil }
        if let b = busyMessage, let since = busySince, Date().timeIntervalSince(since) >= Self.busyShows {
            let cancellable = b.hasSuffix(" ⎋ cancels")
            return Empty(title: cancellable ? String(b.dropLast(" ⎋ cancels".count)) : b, keys: cancellable ? [cancel] : [])
        }
        if let p = parked {
            return Empty(symbol: .server, title: "Not connected", detail: "\(SavedServer.name(for: p.target)):\(p.dir) — nothing is sent until you ask".bidiVisible,
                         keys: [slot("open", "Connect", "↩"), slot("admin.rootPanel", "As Root", "⌃⌘R"), slot("go.up", "This Mac", "⌘↑")])
        }
        if let l = list {   // couldn't read it (Retry), nothing there, or what's typed hides every row
            if let e = loadError {
                let retry = slot("view.refresh", "Retry", "⌘R")
                return Empty(symbol: .warn, title: "Can't read \(l.source.title.lowercased())", detail: e, keys: [retry])
            }
            guard let c = l.content, busyMessage == nil else { return nil }
            return c.rows.isEmpty ? Empty(symbol: .server, title: c.empty) : Empty(symbol: .filter, title: "No matches", keys: [slot("view.filter", "Filter", "/")])
        }
        if let e = loadError {
            let refresh = slot("view.refresh", "Refresh", "⌘R")
            return Empty(symbol: .warn, title: "Can't read this folder", detail: e, keys: [refresh])
        }
        guard listedOnce, busyMessage == nil, sorting == nil, searchTitle == nil, filter == nil, !(gitOnly && git != nil) else { return nil }
        if archive != nil { return Empty(symbol: .archive, title: "Empty folder", detail: "Archives are read-only here") }
        let make = [slot("file.mkdir", "New Folder", "F7"), slot("file.new", "New File", "⇧F4"), KeySlot(key: "⌘V", label: "Paste", id: "paste")]
        guard all.isEmpty else {   // all hidden
            return Empty(symbol: .hide, title: all.count == 1 ? "1 hidden item" : "\(all.count) hidden items", keys: [slot("view.hidden", "Show Hidden Files", "⇧⌘.")] + make)
        }
        return Empty(symbol: .folder, title: "Empty folder", keys: make)
    }

    var emptyShown: Empty? { emptyView.shown }   // tests: what the middle shows now
    var emptyKeysShown: [KeySlot] { emptyView.keys.shownSlots }   // tests: its keys that fit

    private func updateEmpty() {
        let e = empty
        emptyView.show(e, theme: theme)
        // The middle's spinner waits a moment: asked again once it's due (once: past it, nil means nothing to say).
        if e == nil, rows.isEmpty, busyMessage != nil, let since = busySince, Date().timeIntervalSince(since) < Self.busyShows {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.busyShows - Date().timeIntervalSince(since) + 0.01) { [weak self] in
                MainActor.assumeIsolated { self?.updateEmpty() }
            }
        }
    }

    /// A key of the middle clicked: as pressing it in this panel.
    private func emptyKey(_ id: String) {
        view.window?.makeFirstResponder(table)   // this panel, as a click in it
        switch id {
        case "paste": paste(nil)
        case "cancel": cancelBusy()
        default: onCommand?(id)
        }
    }
    private func bytes(of items: [FileItem]) -> Int64 { Self.bytes(of: items, dirSizes: dirSizes) }   // not `self`'s per item (see `applyView`)
    nonisolated static func bytes(of items: [FileItem], dirSizes: [String: Int64]) -> Int64 {
        items.reduce(0) { $0.saturatingAdd($1.kind == .dir ? dirSizes[$1.name] ?? 0 : $1.size) }
    }

    /// The Size column: a file's size, a folder's once measured; else nothing — a folder not measured, a special file
    /// (its kind is in the row's tooltip, `specialKind`). `partial`: du couldn't read all of the folder — "≥ 1.2 GB".
    static func sizeText(_ it: FileItem, measured: Int64?, partial: Bool = false) -> String {
        switch it.kind {
        case .dir: measured.map { (partial ? "≥ " : "") + ByteCountFormatter.short($0) } ?? ""
        case .link where it.linkDir: ""
        case .other: ""
        default: ByteCountFormatter.short(it.size)
        }
    }

    /// What a special file is, which the Size column doesn't say.
    static func specialKind(_ it: FileItem) -> String? {
        guard it.kind == .other else { return nil }
        return switch mode_t(truncatingIfNeeded: it.mode) & S_IFMT {
        case S_IFIFO: "Named pipe (FIFO)"
        case S_IFSOCK: "Socket"
        case S_IFCHR: "Character device"
        case S_IFBLK: "Block device"
        default: "Special file"
        }
    }

    /// The Size column as wide as its widest text in this Mac's locale ("999.99 GB", "≥ 999.9 MB"), the Modified
    /// column as its widest date ("Yesterday 23:59", "Sep 28 23:59", "2026-12-31 23:59").
    private static func widths(font: NSFont) -> (size: CGFloat, date: CGFloat) {
        func w(_ s: String) -> CGFloat { ceil(NSAttributedString(string: s, attributes: [.font: font]).size().width) + 10 }
        let sizes = [999, 999_900, 999_990_000, 999_990_000_000].map { "≥ " + ByteCountFormatter.short($0) }
        let late = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 59))!
        let months = (1...12).map { Calendar.current.date(from: DateComponents(year: 2026, month: $0, day: 28, hour: 23, minute: 59))! }
        let dates = months.map { DateColumn(late).text($0) } + [DateColumn(late).text(late.addingTimeInterval(-3600 * 24)), DateColumn(late, iso: true).text(late)]
        return (sizes.map(w).max()!, dates.map(w).max()!)
    }

    /// This Mac's user or group name for an id (the number if it has none), looked up once.
    private static var idNames: [String: String] = [:]
    static func idName(_ id: UInt32, user: Bool) -> String {
        let key = (user ? "u" : "g") + String(id)
        if let name = idNames[key] { return name }
        let name = user ? FileInfo.userName(id) : FileInfo.groupName(id)
        idNames[key] = name
        return name
    }

    /// "→ target", and why it doesn't resolve: "(dangling)" for a missing target, "(loop)" for a cycle.
    static func linkNote(_ target: String, _ error: Int32) -> String {
        let why = switch error {
        case 0: ""
        case ELOOP: " (loop)"
        case ENOENT, ENOTDIR: " (dangling)"
        default: " (" + String(cString: strerror(error)) + ")"
        }
        return "→ \(target.listed)\(why)"
    }

    /// Reads the folder's symlinks off the main thread: following one into a share that stopped answering stalls
    /// only these notes, never the listing. The listing is `gen`; a later one drops the result.
    private func resolveLinks(_ items: [FileItem], in dir: String, gen: Int) {
        let names = items.filter { $0.kind == .link }.map(\.name)
        guard !names.isEmpty else { return }
        Task { [weak self] in
            let found = await Self.linkResolves.run(dir, .utility) {
                var r: [String: (target: String, error: Int32, dir: Bool)] = [:]
                for name in names {
                    let full = (dir as NSString).appendingPathComponent(name)
                    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: full) else { continue }
                    var s = stat()
                    let ok = stat(full, &s) == 0
                    r[name] = (target, ok ? 0 : errno, ok && s.st_mode & S_IFMT == S_IFDIR)
                }
                return r
            }
            guard let self, gen == loadGen else { return }
            links = found.mapValues { ($0.target, $0.error) }
            // A link to a folder sorts with the folders: the rows move once, now that that's known.
            if all.contains(where: { $0.kind == .link && found[$0.name]?.dir != $0.linkDir }) {
                all = all.map { var it = $0; if it.kind == .link { it.linkDir = found[it.name]?.dir ?? false }; return it }
                return applyView(select: currentName)
            }
            table.reloadData(forRowIndexes: linkRows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))   // the whole row turns red
        }
    }

    /// One resolve per folder at a time, across panels: a link into a share that stopped answering hangs its stat for
    /// good, and every watcher reload would take another thread (P9 again). A link made meanwhile gets its note on the reload after.
    static let linkResolves = Coalesced<[String: (target: String, error: Int32, dir: Bool)]>()

    /// The rows wearing a link note: the resolve and a Name column resize rebuild only these.
    private var linkRows: IndexSet { IndexSet((0..<table.numberOfRows).filter { item(at: $0)?.kind == .link }) }

    /// "→ target" fits or not per cell: the cells on screen decide again when the Name column changes width.
    func tableViewColumnDidResize(_ notification: Notification) {
        guard (notification.userInfo?["NSTableColumn"] as? NSTableColumn)?.identifier.rawValue == "name", !links.isEmpty else { return }
        table.reloadData(forRowIndexes: linkRows, columnIndexes: [table.column(withIdentifier: .init("name"))])
    }

    /// Runs `work` off the main thread with `message` and a spinner in the status line; ⎋ cancels it (`work` gets
    /// the flag). Cancelled, it comes back as `CancellationError`, whatever `work` threw.
    /// ⎋: stops a server listing being made and every `busy` wait.
    func cancelBusy() {
        remoteFlag?.cancel()
        busyOps.forEach { $0.flag.cancel() }
        if let l = list, remoteFlag != nil {   // a list's read: done waiting now (a login or Touch ID may go on by itself)
            remoteFlag = nil
            busyMessage = busyOps.last?.message
            flash("Stopped looking at \(l.source.title.lowercased())")
        }
    }

    @objc private func cancelClicked() { cancelBusy() }
    @objc private func backClicked() { goUp() }   // ⌫'s (`go.up`) on results: back to the folder

    /// A key and what it does, beside the status line (phase 3's grammar: the key as a symbol, then a verb).
    static func pill(_ key: String, _ verb: String, target: AnyObject, action: Selector) -> PillButton {
        let b = PillButton(title: "", target: target, action: action)
        b.isBordered = false
        b.minSide = 0   // the status line keeps its height
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let t = NSMutableAttributedString(attributedString: KeyCap.text(key, font: font))
        t.append(NSAttributedString(string: " " + verb, attributes: [.font: font, .foregroundColor: Palette.secondary]))   // not a failure, nor for good
        b.attributedTitle = t
        b.contentTintColor = Palette.secondary
        b.setAccessibilityLabel("\(verb), \(key)")
        b.isHidden = true
        return b
    }

    /// `after`: the message waits that long (⎋ doesn't), so quick work doesn't flash it.
    func busy<T: Sendable>(_ message: String, after: Double = 0, flag: CancelFlag = CancelFlag(),
                           _ work: @escaping @Sendable (CancelFlag) throws -> T) async -> Result<T, Error> {
        let mine = message + " ⎋ cancels"
        busyOps.append((flag, mine))
        if after == 0 { busyMessage = mine } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                MainActor.assumeIsolated { if let self, let op = self.busyOps.first(where: { $0.flag === flag }) { self.busyMessage = op.message } }
            }
        }
        // Back on ⎋ at once, even while `work` sits in a call that can't be stopped (a share that stopped
        // answering): it's left to finish on its own. `work` hooking ⎋ itself (killing its process) keeps this
        // hook until it returns.
        let r: Result<T, Error> = await withCheckedContinuation { c in
            let once = Once()
            flag.onCancel { once.run { c.resume(returning: .failure(CancellationError())) } }
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Result { try work(flag) }
                once.run { c.resume(returning: r) }
            }
        }
        let shown = busyOps.first { $0.flag === flag }?.message ?? mine
        busyOps.removeAll { $0.flag === flag }
        if busyMessage == shown { busyMessage = busyOps.last?.message }   // one still running says so again
        return flag.isCancelled ? .failure(CancellationError()) : r
    }

    /// What the `busy` running with `flag` says from now on: a step ⎋ no longer stops, say. Gone already: nothing.
    func busy(_ flag: CancelFlag, says message: String) {
        guard let i = busyOps.firstIndex(where: { $0.flag === flag }) else { return }
        if busyMessage == busyOps[i].message { busyMessage = message }
        busyOps[i].message = message
    }

    /// Briefly shows a message in the status line; `error`: one saying what failed.
    func flash(_ message: String, error: Bool = false) {
        flashed = (message, error, Date() + flashTime)
        statusLabel.stringValue = message
        statusError = error
        DispatchQueue.main.asyncAfter(deadline: .now() + flashTime) { [weak self] in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
    }

    // MARK: - Git (column + branch in the status line, only inside a work tree — here or on the server)

    private func refreshGit() {
        guard gitApplies else { return setGit(nil) }
        gitRuns.request(key: remote.map { "\($0.target.host):\($0.target.port ?? 0):\($0.dir)" } ?? path)
    }

    private var gitApplies: Bool { archive == nil && searchTitle == nil && parked == nil }

    /// One `git status` per panel at a time: reloads in a busy repo would otherwise pile them up.
    /// `git status` at most once a second, or twice its last run's time apart: one taking 4 s in a repo that a build
    /// keeps changing would keep git busy most of the time.
    private lazy var gitRuns = SingleFlight(timesLastRun: 2) { [weak self] in await self?.loadGit() }

    private func loadGit() async {   // not inline: Swift 6.4 rejects a lazy initializer that awaits `Blocking.run`
        guard gitApplies else { return }
        let dir = currentDir, target = remote?.target, env = SSHAskpass.env
        let st = await Blocking.run(.utility) {   // on a server: over its ssh connection
            target.map { t in GitStatus.remote(dir) { SSHCommand.output(t, $0, env: env) } } ?? GitStatus.load(dir)
        }
        guard dir == currentDir, target == remote?.target, gitApplies else { return }
        setGit(st)
    }

    private func setGit(_ st: GitStatus?) {
        let col = table.column(withIdentifier: .init("git"))
        if col >= 0, table.tableColumns[col].isHidden != (st == nil) {   // also after a folder change set `git` to nil directly
            table.tableColumns[col].isHidden = st == nil
            fitColumns()
        }
        guard st != git else { return }
        git = st
        onGitChange?()
        if gitOnly { return applyView(select: currentName) }
        if col >= 0 { table.reloadData(forRowIndexes: IndexSet(0..<table.numberOfRows), columnIndexes: [col]) }
        updateStatus()
    }

    /// The git column's mark: "M" (and R, C, T) amber, "A" green, "?" untracked and "D" grey, "U" — a conflict — red,
    /// "•" changes inside amber; staged in bold. The letter, its color, what they say in words (VoiceOver reads neither).
    static func gitCell(_ code: String) -> (letter: String, color: NSColor, word: String, staged: Bool) {   // internal for tests
        if code == "•" { return ("•", Palette.warn, "changes inside", false) }
        if code == "??" { return ("?", .secondaryLabelColor, "untracked", false) }
        if code == "!!" { return ("!", .tertiaryLabelColor, "ignored", false) }
        if GitStatus.isConflict(code) { return ("U", Palette.fail, "conflict", false) }
        let x = code.first ?? " ", y = code.last ?? " ", staged = x != " "
        let letter = staged ? x : y
        let word = ["M": "modified", "A": "added", "D": "deleted", "R": "renamed", "C": "copied", "T": "type changed"][String(letter)] ?? "changed"
        let color = letter == "A" ? Palette.ok : letter == "D" ? .secondaryLabelColor : Palette.warn
        return (String(letter), color, word + (staged ? ", staged" : ""), staged)
    }

    /// The mark as drawn: bold when staged, "D" struck through, a conflict after a warning sign.
    static func gitText(_ mark: (letter: String, color: NSColor, word: String, staged: Bool), size: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: mark.staged ? .heavy : .regular)
        let s = NSMutableAttributedString()
        if mark.word == "conflict" { s.append(Symbol.warnFill.text(mark.color, font: font)) }
        s.append(NSAttributedString(string: mark.letter, attributes: [.font: font, .foregroundColor: mark.color,
                                                                    .strikethroughStyle: mark.letter == "D" ? NSUnderlineStyle.single.rawValue : 0]))
        let center = NSMutableParagraphStyle()
        (center.alignment, center.lineBreakMode) = (.center, .byClipping)   // one line, the sign and the letter
        s.addAttribute(.paragraphStyle, value: center, range: NSRange(location: 0, length: s.length))
        return s
    }

    // MARK: - Sorting (remembered per folder)

    private nonisolated static func savedSort(for p: String) -> (key: SortKey, ascending: Bool) {
        sortOrder(UserDefaults.standard.dictionary(forKey: "folderSort")?[p] as? String)
    }

    /// `"size:0"` → by size, descending. Anything else (`defaults write`, a damaged plist) → by name, ascending.
    nonisolated static func sortOrder(_ saved: String?) -> (key: SortKey, ascending: Bool) {
        let parts = saved?.split(separator: ":") ?? []
        return (parts.first.flatMap { SortKey(rawValue: String($0)) } ?? .name, parts.count < 2 || parts[1] == "1")
    }

    private func loadSort(for p: String) {
        (sortKey, ascending) = Self.savedSort(for: p)
        suppressSortCallback = true
        table.sortDescriptors = [NSSortDescriptor(key: sortKey.rawValue, ascending: ascending)]
        suppressSortCallback = false
    }

    private func saveSort() {
        var d = UserDefaults.standard.dictionary(forKey: "folderSort") ?? [:]
        d[path] = sortKey == .name && ascending ? nil : "\(sortKey.rawValue):\(ascending ? 1 : 0)"
        UserDefaults.standard.set(d, forKey: "folderSort")
    }

    /// Sort By (the folder menu, ⇧⌘P): as a click on that column's header, in its first direction.
    func sort(by key: SortKey) {
        if key != sortKey { table.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: key == .name)] }
    }
    func reverseSort() { table.sortDescriptors = [NSSortDescriptor(key: sortKey.rawValue, ascending: !ascending)] }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !suppressSortCallback, let d = tableView.sortDescriptors.first, let key = d.key.flatMap(SortKey.init) else { return }
        sortKey = key
        ascending = d.ascending
        saveSort()
        applyView(select: currentName)
    }

    // MARK: - Navigation

    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (e.keyCode, mods) {
        case (115, []): moveCursor(to: 0)                                // Home
        case (119, []): moveCursor(to: table.numberOfRows - 1)           // End
        case (116, []): moveCursor(to: table.selectedRow - pageRows)     // PgUp
        case (121, []): moveCursor(to: table.selectedRow + pageRows)     // PgDn
        case (53, []) where remoteFlag != nil || !busyOps.isEmpty:       // ⎋ stops connecting to a server
            cancelBusy()
        default: return onCommandKey?(e) ?? false
        }
        return true
    }

    private var pageRows: Int {
        max(1, Int(table.visibleRect.height / (table.rowHeight + table.intercellSpacing.height)) - 1)
    }

    /// ↩ or ↓ in the quick filter: back to the list, the cursor on the first match if it was on ".." (MC, TC).
    func confirmFilter() {
        view.window?.makeFirstResponder(table)
        showFilterChip()
        if !rows.isEmpty, item(at: max(table.selectedRow, 0)) == nil { moveCursor(to: hasParent ? 1 : 0) }
    }

    func moveCursor(to r: Int, scroll: Bool = true) {
        guard table.numberOfRows > 0 else { return }
        let r = min(max(r, 0), table.numberOfRows - 1)
        table.selectRowIndexes([r], byExtendingSelection: false)
        if scroll { table.scrollRowToVisible(r) }
    }

    /// The header search's file hits: search results and archive entries can't be re-listed to select one.
    func moveCursor(toName name: String) {
        if let r = row(named: name) { moveCursor(to: r) }
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        openCursor(intoPackage: false)
    }

    func openCursor(intoPackage: Bool) {
        if parked != nil { return connectParked() }
        if list != nil { return onListKey?(Shortcut("return")!) ?? () }   // a double-click: the row's ↩
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard r >= 0, r < table.numberOfRows else { return }
        guard let it = item(at: r) else { return goUp() }
        if let rem = remote {
            let full = (rem.dir as NSString).appendingPathComponent(it.name)
            if searchTitle != nil, it.kind != .dir {   // a hit: its folder, the cursor on it
                return loadRemote(rem.target, dir: (full as NSString).deletingLastPathComponent, select: (full as NSString).lastPathComponent)
            }
            switch it.kind {
            case .dir: loadRemote(rem.target, dir: full, select: nil)
            case .link:   // link to a file
                loadRemote(rem.target, dir: full, select: nil) { [weak self] in   // not when cancelled or the server is down
                    if !($0 is CancellationError), ($0 as? SFTPError)?.connection != true { self?.onCommand?("remote.open") }
                }
            default: onCommand?(RemoteArchive.isArchive(it.name) ? "remote.archive" : "remote.open")
            }
            return
        }
        if let a = archive {
            if it.kind == .dir { archive!.inner = a.inner.isEmpty ? it.name : a.inner + "/" + it.name; showArchive(select: nil) }
            else { onCommand?("archive.open") }
            return
        }
        let full = (itemsDir as NSString).appendingPathComponent(it.name)
        guard it.kind == .dir || it.kind == .link else { return openItem(it, full, dirLike: false, folder: false) }
        // Off the main thread: a link into a share that stopped answering hangs this, not the app. Dropped if the
        // panel went elsewhere meanwhile.
        let gen = moves
        Task { [weak self] in
            let (dirLike, folder) = await Blocking.run(.userInitiated) { () -> (Bool, Bool) in
                var isDir: ObjCBool = false
                let dirLike = it.kind == .dir || FileManager.default.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue
                return (dirLike, dirLike && (intoPackage || !NSWorkspace.shared.isFilePackage(atPath: full)))
            }
            guard let self, gen == moves else { return }
            openItem(it, full, dirLike: dirLike, folder: folder)
        }
    }

    private func openItem(_ it: FileItem, _ full: String, dirLike: Bool, folder: Bool) {
        if folder {
            navigate(to: full)
        } else if !dirLike && searchTitle == nil && ArchiveIndex.isArchive(it.name) {
            enterArchive(full)
        } else if searchTitle != nil {
            // In results, ↩ goes to the file in its folder (F3/F4/⌘Y still act on it right here).
            navigate(to: (full as NSString).deletingLastPathComponent, select: (full as NSString).lastPathComponent)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: full))
        }
    }

    /// `..` at a server's root asks before it closes the connection (a test answers instead of the alert).
    /// Not a change on the server: no strip, ↩ Disconnect.
    static var confirmLeaving: @MainActor (SFTPTarget, _ back: String, NSWindow?) async -> Bool = { target, back, window in
        var c = Confirm("Disconnect SFTP from \(SavedServer.name(for: target.asUser))?", action: "Disconnect")
        c.note = "This tab goes back to \((back as NSString).abbreviatingWithTildeInPath)."
        guard let window else { return AppDelegate.modal(c.alert()) == 0 }
        return await AppDelegate.sheet(c.alert(), on: window) == 0
    }

    /// ⌫ in a server's overview while a connection to it is up: off the server, which may close it (a test answers).
    static var confirmLeavingPlace: @MainActor (SFTPTarget, _ back: String, NSWindow?) async -> Bool = { target, back, window in
        var c = Confirm("Leave \(SavedServer.name(for: target.asUser))?", action: "Leave")
        c.note = "Its connection closes unless something else uses it. This tab goes back to \((back as NSString).abbreviatingWithTildeInPath)."
        guard let window else { return AppDelegate.modal(c.alert()) == 0 }
        return await AppDelegate.sheet(c.alert(), on: window) == 0
    }

    func goUp() {
        if parked != nil { return navigate(to: path, history: .none) }
        if let l = list {   // a list: back to its server's place; the place: off the server, asked as from its `/`
            guard isPlace else { return onPlace?(l.source.target, l.source.title) ?? navigate(to: path, history: .none) }
            guard AppDelegate.connected(l.source.target) else { return navigate(to: path, history: .none) }   // nothing to close: no question
            Task {
                guard await Self.confirmLeavingPlace(l.source.target, path, view.window), list === l else { return }
                navigate(to: path, history: .none)
            }
            return
        }
        if let r = remote {
            if searchTitle != nil { return loadRemote(r.target, dir: r.dir, select: nil) }   // leave search results
            if r.dir == "/", let onPlace { return onPlace(r.target.asUser, "/") }   // up to its place: nothing closes
            if r.dir == "/" {   // leave the server
                Task {
                    guard await Self.confirmLeaving(r.target, path, view.window),
                          remote?.target == r.target, remote?.dir == "/" else { return }   // still there once answered
                    navigate(to: path, history: .none)
                }
                return
            }
            return loadRemote(r.target, dir: (r.dir as NSString).deletingLastPathComponent, select: (r.dir as NSString).lastPathComponent)
        }
        if let a = archive {
            if a.inner.isEmpty { return navigate(to: path, select: (a.index.file as NSString).lastPathComponent, history: .none) }
            archive!.inner = (a.inner as NSString).deletingLastPathComponent
            return showArchive(select: (a.inner as NSString).lastPathComponent)
        }
        if searchTitle != nil { return navigate(to: path, history: .none) }   // leave search results
        guard hasParent else { return }
        navigate(to: (path as NSString).deletingLastPathComponent)
    }

    func goBack() {
        guard let p = backStack.popLast() else { return NSSound.beep() }
        navigate(to: p, history: .back)
    }

    func goForward() {
        guard let p = forwardStack.popLast() else { return NSSound.beep() }
        navigate(to: p, history: .forward)
    }

    // MARK: - SFTP (system OpenSSH; see DFMCore.SFTP)

    /// Lists `dir` (or the login folder if nil) on the server. A server that can't be reached is reported in an
    /// alert; other errors run `onFailure` instead of being reported, if given (so does ⎋).
    func loadRemote(_ target: SFTPTarget, dir: String?, select: String?, keep: TabMarks? = nil, onFailure: ((Error) -> Void)? = nil) {
        // The server shown here already, typed as it was before `ServerLock.locking` shortened its linger: the same.
        let target = remote.map { $0.target.persisting(target.persist) == target ? $0.target : target } ?? target
        loadGen += 1
        let gen = loadGen
        let flag = CancelFlag()
        remoteFlag = flag
        let opening = remote?.target != target   // not a folder of the server already open here
        if kept?.target != target { kept?.close(); kept = KeptSession(target) }
        let session = kept, order = (key: sortKey, ascending: ascending)
        if opening {
            busyMessage = "Connecting to \(target.host)… ⎋ cancels"
            connecting = target
        }
        Task { [weak self] in
            if opening, await !ServerLock.authorize(target) {
                guard let self, gen == loadGen else { return }
                remoteFlag = nil
                connecting = nil
                busyMessage = busyOps.last?.message
                flash("\(target.host) stays locked")
                return
            }
            // A locked server reached by another spelling: its connection lingers as the saved one's (just unlocked:
            // asked again, it doesn't ask).
            if opening, ServerLock.locking(target) != target {
                guard let self, gen == loadGen else { return }
                return loadRemote(ServerLock.locking(target), dir: dir, select: select, keep: keep, onFailure: onFailure)
            }
            let result = await Blocking.run(.userInitiated) { () -> Result<(String, [FileItem], [FileItem], [String: (String, String)], [String: (target: String, error: Int32)], Int64?), Error> in
                Result {
                    let d = try dir ?? SFTP.home(target, env: SSHAskpass.env, cancel: flag, on: session)
                    var owners: [String: (String, String)] = [:], links: [String: (target: String, error: Int32)] = [:], free: Int64?
                    let items = try SFTP.list(target, d, env: SSHAskpass.env, cancel: flag, owners: { owners[$0] = ($1, $2) },
                                              links: { links[$0] = ($1, $2) }, free: { free = $0 }, on: session)
                    return (d, items, items.sortedForPanel(by: order.key, ascending: order.ascending), owners, links, free)
                }
            }
            guard let self, gen == loadGen else { return }
            remoteFlag = nil
            // Connected: not until the panel shows it — a moment with neither made it look unused, and its connection
            // was stopped right after the first listing (the next session logged in again).
            if case .failure = result { connecting = nil }
            busyMessage = busyOps.last?.message
            switch result {
            case .success(let (d, items, sorted, owners, found, free)):
                onRemoteResult?(target, nil)
                remoteOwners = owners
                links = found
                remoteFree = free.map { ByteCountFormatter.short($0) }
                enterRemote(target, d, items, sorted: (sorted, order), select: select, keep: keep)
                connecting = nil
            case .failure(let error as SFTPError) where error.connection:
                onRemoteResult?(target, error.message)
                if let window = view.window, let change = error.hostKey {
                    Task { [weak self] in
                        guard await AppDelegate.sheet(Self.hostKeyQuestion(change, on: target).alert(), on: window) == 0 else { return }
                        self?.removeOldKey(change, then: { $0.loadRemote(target, dir: dir, select: select, keep: keep, onFailure: onFailure) })
                    }
                } else if let window = view.window {
                    let alert = NSAlert()
                    alert.messageText = "Can't connect to \(target.host)"
                    alert.informativeText = error.message
                    alert.beginSheetModal(for: window) { _ in }
                }
                onFailure?(error)
            case .failure(let error):
                if error is CancellationError { flash("Stopped connecting to \(target.host)") }
                else { onRemoteResult?(target, error.localizedDescription) }
                if let onFailure { return onFailure(error) }
                if !(error is CancellationError) { NSSound.beep(); flash("\(target.host): \(error.localizedDescription)", error: true) }
            }
        }
    }

    /// ↩ on a parked tab: connects as Connect does (a locked server asks first), the cursor back on its name; `target`:
    /// another way in (⌃⌘R: as root). Failing, the tab stays parked.
    func connectParked(_ target: SFTPTarget? = nil) {
        guard let p = parked else { return }
        loadRemote(target ?? p.target, dir: p.dir, select: tabs[tabIndex].cursor) { [weak self] error in
            // Still parked (its folder gone, say): no session kept for it either.
            guard let self, parked != nil else { return }
            kept?.close()
            kept = nil
            if !(error is CancellationError), (error as? SFTPError)?.connection != true { NSSound.beep(); flash("\(p.target.host): \(error.localizedDescription)", error: true) }
        }
    }

    /// Shows a server tab parked: whatever was on screen goes, and nothing is listed.
    private func park(_ p: (target: SFTPTarget, dir: String)) {
        loadGen += 1   // a listing on its way doesn't land over it
        connecting = nil
        busyMessage = busyOps.last?.message   // that listing's "Connecting…" too
        watcher?.cancel()
        watcher = nil
        if searchTitle != nil { searchFlag?.cancel(); searchTitle = nil; searching = false }
        leaveList()
        archive = nil
        remote = nil
        parked = p
        loadError = nil
        all = []
        (sortedAll, sortedBy) = ([], (sortKey, ascending))
        marked.removeAll()
        if filter != nil { clearFilter(apply: false) }
        clearSizes()
        links.removeAll()
        setGit(nil)
        showPath()
        applyView(select: nil, newFolder: true)
        updateTabBar()
    }

    // MARK: - A list in place of the folder (Р7): Services, Containers, Ports

    /// Shows `source`'s list in this tab in place of what's there: read first if nothing of it was (a Picker's rows
    /// come along with ⌘↩). Nothing of the folder behind stays on screen or is acted on; ⌫ goes back.
    func showList(_ source: ListSource, content: ListContent? = nil, filter text: String = "", select: String? = nil) {
        show(ListPanel(source, content: content, filter: text, select: select))
    }

    /// `l` — a tab's again, or a new one — on the table.
    func show(_ l: ListPanel) {
        if list !== l { leaveList() }
        list = l   // first: its server is in use before the folder's lets it go (`remote = nil` below)
        tabs[tabIndex].place = nil
        loadGen += 1   // a listing on its way doesn't land over it
        connecting = nil
        busyMessage = busyOps.last?.message
        watcher?.cancel()
        watcher = nil
        if searchTitle != nil { searchFlag?.cancel(); searchTitle = nil; searching = false }
        (archive, remote, parked, loadError) = (nil, nil, nil, nil)
        all = []
        (sortedAll, sortedBy, rows) = ([], (sortKey, ascending), [])
        marked.removeAll()
        clearSizes()
        links.removeAll()
        setGit(nil)
        filter = nil
        (filterField.stringValue, filterField.isHidden) = (l.filter, l.filter.isEmpty)
        l.theme = theme
        l.onChange = { [unowned self] in updateStatus(); onListChange?() }
        l.onCursor = { [unowned self] in onCursorChange?() }
        l.attach(to: table)
        fitColumns()
        for (v, stack, at) in [(l.headerView, header!, header.arrangedSubviews.count), (l.resultView, footer!, 0)] where v.superview == nil {
            stack.insertArrangedSubview(v, at: at)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
        }
        showPath()
        updateTabBar()
        updateStatus()
        onSessionsChange?()   // its server's connection is in use
        onPathChange?()       // the session, the prompt, the key bar
        if l.content == nil { readList() }
    }

    /// The list goes, its table's columns back to the files' (before anything else shows in the tab).
    private func leaveList() {
        guard let l = list else { return }
        l.detach()
        l.headerView.removeFromSuperview()
        l.resultView.removeFromSuperview()
        (l.onChange, l.onCursor) = (nil, nil)
        list = nil
        if !filterField.stringValue.isEmpty { clearFilter(apply: false) }
        loadSort(for: path)
        loadError = nil
        for c in table.tableColumns { (c.headerCell as? PanelHeaderCell)?.fill = theme.background }   // a theme picked meanwhile
        table.reloadData()
    }

    /// Reads the list again (⌘R in the menu, Retry, a first show): "Looking at services…" with a spinner — ⎋ stops it.
    /// What fails says why in the middle with Retry, or, over rows already shown, in the status line ("Nothing here"
    /// isn't a row: it would stay, as if the list were empty).
    func readList() {
        guard let l = list else { return }
        let flag = CancelFlag()
        remoteFlag?.cancel()
        remoteFlag = flag
        loadError = nil
        busyMessage = "Looking at \(l.source.title.lowercased())… ⎋ cancels"
        Task { [weak self] in
            let r: Result<ListContent, Error>
            do { r = .success(try await l.source.read(flag)) } catch { r = .failure(error) }
            guard let self, list === l, remoteFlag === flag else { return }
            remoteFlag = nil
            busyMessage = busyOps.last?.message
            switch r {
            case .success(let c): l.set(c)
            case .failure(is CancellationError): break
            case .failure(let e) where l.content?.rows.isEmpty != false: loadError = e.localizedDescription
            case .failure(let e): flash(e.localizedDescription, error: true)
            }
            updateStatus()
        }
    }

    /// A changed host key (R-52, mockup hostkey-dlg): a red line on what it may be, the new key as ssh gave it, where the old
    /// one is kept, on production who to ask first. ↩ is Cancel: the old key goes only when asked (`removeOldKey`), and the
    /// next login asks about the new one. The old key's fingerprint isn't shown: ssh doesn't say it.
    static func hostKeyQuestion(_ change: HostKeyChange, on target: SFTPTarget) -> Confirm {
        var c = Confirm("\(SavedServer.name(for: target.asUser))'s host key has changed", on: target, action: "Remove Old Key…")
        c.alarm = "Either the server was reinstalled, or someone is intercepting the connection."
        (c.runs, c.command) = ("Its new \(change.keyType) key:", change.fingerprint)
        c.note = "The old one is kept in \((change.file as NSString).abbreviatingWithTildeInPath), line \(change.line)."
            + (SavedServer.isProd(target) ? " Production: check the new fingerprint with the server's admin first." : "")
        c.returnCancels = true
        return c
    }

    /// "Remove Old Key…": the server's old host key out of known_hosts, then `then` (connect again: ssh asks about the new one).
    func removeOldKey(_ change: HostKeyChange, then: @escaping @MainActor (PanelViewController) -> Void) {
        Task {
            switch await Blocking.run(.userInitiated, { Result { try change.remove() } }) {
            case .success: then(self)
            case .failure(let e):
                NSSound.beep()
                flash(e.localizedDescription, error: true)
            }
        }
    }

    private func enterRemote(_ target: SFTPTarget, _ dir: String, _ items: [FileItem], sorted: ([FileItem], (key: SortKey, ascending: Bool)),
                             select: String?, keep: TabMarks? = nil) {
        let sameDir = remote?.target == target && remote?.dir == dir
        let select = select ?? (sameDir ? currentName : nil)   // a reload keeps the cursor where it is now
        watcher?.cancel()
        watcher = nil
        archive = nil
        if searchTitle != nil { searchFlag?.cancel(); searchTitle = nil; searching = false }
        remote = (target, dir)   // before the list goes: its server's connection stays in use
        leaveList()
        loadError = nil
        all = items
        (sortedAll, sortedBy) = sorted
        if sameDir {
            if !marked.isEmpty { marked.formIntersection(items.map(\.name)) }
        } else {
            marked.removeAll()
            clearSizes()
            if filter != nil { clearFilter(apply: false) }
        }
        if let keep { restore(keep, in: items) }
        if !sameDir { setGit(nil) }   // the old folder's marks; a reload keeps them until the new status
        showPath()
        applyView(select: select, newFolder: !sameDir)
        refreshGit()
        updateTabBar()
        onPathChange?()
    }

    /// Marked items (or the cursor's) in the current server folder.
    var remoteSelection: (target: SFTPTarget, dir: String, items: [FileItem])? {
        guard let r = remote, case let items = selectedItems, !items.isEmpty else { return nil }
        return (r.target, r.dir, items)
    }

    /// The marked items, or the cursor's (in the order of `targetURLs`).
    var selectedItems: [FileItem] {
        if !marked.isEmpty { return rows.filter { marked.contains($0.name) } }
        let row = table.selectedRow
        guard row >= 0, row < table.numberOfRows, let it = item(at: row) else { return [] }
        return [it]
    }

    var remoteCursor: (target: SFTPTarget, dir: String, item: FileItem)? {
        guard let r = remote else { return nil }
        let row = table.selectedRow
        guard row >= 0, row < table.numberOfRows, let it = item(at: row) else { return nil }
        return (r.target, r.dir, it)
    }

    // MARK: - Archives: browse like folders (read-only)

    func enterArchive(_ file: String) {
        loadGen += 1
        let gen = moves   // a re-list of the folder meanwhile (the watcher) doesn't drop it; going elsewhere does
        busyMessage = "Reading “\((file as NSString).lastPathComponent)”…"
        Task { [weak self] in
            let result = await Blocking.run(.userInitiated) { Result { try ArchiveIndex.read(file) } }
            guard let self, gen == moves else { return }
            busyMessage = busyOps.last?.message
            switch result {
            case .success(let index):
                loadGen += 1   // that re-list, still on its way, mustn't land over the archive
                watcher?.cancel()
                watcher = nil
                path = (file as NSString).deletingLastPathComponent
                leaveList()
                archive = (index, "")
                loadError = nil
                setGit(nil)
                showArchive(select: nil)
                onPathChange?()   // the key bar's F5 extracts now
            case .failure(let error):
                NSSound.beep()
                flash("Can't open archive: \(error.localizedDescription)", error: true)
            }
        }
    }

    private func showArchive(select: String?) {
        guard let a = archive else { return }
        marked.removeAll()
        clearSizes()
        if filter != nil { clearFilter(apply: false) }
        all = a.index.list(a.inner) ?? []
        showPath()
        applyView(select: select, newFolder: true)
    }

    /// Marked names (or the cursor's) inside the current archive folder.
    var archiveSelection: (index: ArchiveIndex, inner: String, names: [String])? {
        guard let a = archive else { return nil }
        if !marked.isEmpty { return (a.index, a.inner, rows.filter { marked.contains($0.name) }.map(\.name)) }
        let r = table.selectedRow
        guard r >= 0, r < table.numberOfRows, let it = item(at: r) else { return nil }
        return (a.index, a.inner, [it.name])
    }

    // MARK: - Search results ("panelize"): fed in batches by the search runner

    /// `what` was searched for, `place` where (the title is both; the footer shows `what`).
    func beginSearch(_ what: String, in place: String? = nil, root: String? = nil) -> CancelFlag {
        searchFlag?.cancel()
        searchRoot = root
        let flag = CancelFlag()
        searchFlag = flag
        loadGen += 1   // drop any listing still in flight
        flashed = nil
        busyMessage = busyOps.last?.message
        watcher?.cancel()
        watcher = nil
        searchTitle = place.map { "\(what) in \($0)" } ?? what
        parked = nil   // its ".." goes to the tab's folder
        leaveList()
        loadError = nil
        searchWhat = what
        searching = true
        all = []
        marked.removeAll()
        clearSizes()
        if filter != nil { clearFilter(apply: false) }
        setGit(nil)   // marks are by folder entry, not by result path
        showPath()
        applyView(select: nil)
        return flag
    }

    func addSearchResults(_ items: [FileItem], from flag: CancelFlag) {
        guard flag === searchFlag, searchTitle != nil else { return }
        // To the end as found, sorted once when the search ends: re-sorting every batch made 100 000 hits a minute's work.
        var sorted = sortedAll, names = folded
        all += items
        sorted?.append(contentsOf: items)
        names?.append(items.lazy.map(\.name))
        sortedAll = sorted
        folded = names
        applyView(select: currentName)
    }

    func finishSearch(_ flag: CancelFlag, note: String? = nil, error: Bool = false) {
        guard flag === searchFlag, searchTitle != nil else { return }
        searching = false
        sortedAll = nil
        applyView(select: currentName)
        if let note { flash(note, error: error) }
    }

    /// Every git change in this folder and below as one list, like search results. Run it again to refresh.
    func showGitChanges() {
        guard remote == nil, archive == nil, list == nil else { return flash("Git Changes works in a local folder") }
        let dir = path, gen = moves
        guard GitStatus.available else { return flash("Git needs the Command Line Tools (xcode-select --install)") }
        Task { [weak self] in
            // Off the main thread, as everything below: the folder may be on a share that stopped answering.
            let repo = await Blocking.run(.userInitiated) { GitStatus.repoRoot(dir) != nil }
            guard let self, gen == moves else { return }
            guard repo else { return flash("Not a git work tree") }
            let flag = beginSearch("git changes", in: (dir as NSString).abbreviatingWithTildeInPath)
            let found = await Blocking.run(.userInitiated) { () -> (GitStatus, [FileItem], Int)? in
                guard let st = GitStatus.load(dir, allUntracked: true) else { return nil }
                let (items, deleted) = st.changedItems(in: dir)
                return (st, items, deleted)
            }
            guard flag === searchFlag, searchTitle != nil else { return }
            addSearchResults(found?.1 ?? [], from: flag)
            if var st = found?.0 {
                st.marks = st.changes   // the column looks rows up by name, and here a name is the relative path
                setGit(st)
            }
            finishSearch(flag)
            if found == nil { flash("Git status didn't finish (failed, ran over 30 s, or this repo's config can run commands)", error: true) }
            else if let deleted = found?.2, deleted > 0 { flash("\(deleted) deleted not shown (not on disk)") }
        }
    }

    // MARK: - Quick View (⌃Q): this panel shows the other panel's cursor item — Preview, Info, Git (R-48)

    enum QuickTab: Int { case preview, info, git }
    /// The tab chosen last, for the session (⌘I chooses Info).
    static var quickTab = QuickTab.preview

    /// What Quick View shows of the other panel's cursor item: its name, the file Quick Look previews, and for Info a
    /// file here (or the folder, on ".."), or a server's file as its listing knew it; for Git, its state there.
    struct Peek {
        var name = ""
        var preview: URL?
        var local: URL?
        var server: [(String, String)]?
        var inRepo = false
        var git: String?   // the Git column's code; nil: unchanged
    }

    /// The cursor's item for Quick View next door. `fetch`: Preview shows it, so a server's file is fetched first.
    func peek(fetch: Bool) -> Peek {
        if let l = list { return Peek(name: l.cursor?.title ?? "") }   // not the folder behind it
        var p = Peek(inRepo: git != nil, git: currentName.flatMap { git?.marks[$0] })
        if let (target, dir, it) = remoteCursor {
            p.name = it.name
            p.preview = fetch ? previewURL() : nil
            p.server = InfoView.serverRows(server: SavedServer.name(for: target), path: (dir as NSString).appendingPathComponent(it.name), item: it,
                                           owner: remoteOwners[it.name], link: links[it.name]?.target)
        } else if remote == nil {
            p.preview = previewURL()
            p.local = infoURL   // the cursor's, or the folder on ".."; inside an archive, the archive
            p.name = p.local.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent } ?? ""
        }
        return p
    }

    private var quickBox: NSStackView?
    private let quickTitle = NSTextField(labelWithString: "")
    private let quickTabs = NSSegmentedControl(labels: ["Preview", "Info", "Git"], trackingMode: .selectOne, target: nil, action: nil)
    private var infoView: InfoView?
    private let gitState = NSTextField(wrappingLabelWithString: "")
    private let gitKeys = KeyBarView(chips: false)
    private var gitBox: NSStackView?
    private var peekShown = Peek()
    /// A tab chosen: the app asks the other panel again (Preview fetches a server's file).
    var onQuickTab: (() -> Void)?
    var quickTabShown: QuickTab? { quickBox == nil ? nil : QuickTab(rawValue: quickTabs.selectedSegment) }   // tests
    var quickTabLabels: [String] { (0..<quickTabs.segmentCount).map { quickTabs.label(forSegment: $0) ?? "" } }   // tests
    var infoRows: [(String, String)] { infoView?.rows ?? [] }   // tests
    var gitShown: (state: String, keys: [KeySlot])? { gitBox?.isHidden == false ? (gitState.stringValue, gitKeys.list ?? []) : nil }   // tests

    func setQuickView(_ on: Bool) {
        if on, quickView == nil, let qv = QLPreviewView(frame: scroll.frame, style: .normal) {
            let peek = TextPeek(), info = InfoView()
            peek.isHidden = true
            info.isHidden = true
            info.onCommand = { [unowned self] in onCommand?($0) }
            gitKeys.onRun = { [unowned self] in onCommand?($0) }   // as the key, on the other panel's item
            let git = NSStackView(views: [gitState, gitKeys])
            git.orientation = .vertical
            git.alignment = .leading
            git.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            gitKeys.heightAnchor.constraint(equalToConstant: 30).isActive = true
            gitKeys.widthAnchor.constraint(equalTo: git.widthAnchor, constant: -20).isActive = true
            gitState.font = .systemFont(ofSize: 13)
            git.isHidden = true
            let body = NSView()
            for v in [qv, peek, info, git] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                body.addSubview(v)
                NSLayoutConstraint.activate([
                    v.leadingAnchor.constraint(equalTo: body.leadingAnchor), v.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                    v.topAnchor.constraint(equalTo: body.topAnchor),
                    v === git ? v.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor) : v.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                ])
            }
            quickTitle.font = .systemFont(ofSize: 12.5, weight: .semibold)
            quickTitle.lineBreakMode = .byTruncatingMiddle
            quickTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            quickTitle.setContentHuggingPriority(.init(1), for: .horizontal)   // the switch at the bar's right end
            quickTabs.controlSize = .small
            quickTabs.target = self
            quickTabs.action = #selector(quickTabClicked)
            let bar = NSStackView(views: [quickTitle, quickTabs])
            bar.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 4, right: 6)
            let box = NSStackView(views: [bar, body])
            box.orientation = .vertical
            box.spacing = 0
            box.distribution = .fill
            bar.setHuggingPriority(.required, for: .vertical)
            body.setContentHuggingPriority(.init(1), for: .vertical)
            box.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(box)
            NSLayoutConstraint.activate([
                box.topAnchor.constraint(equalTo: scroll.topAnchor), box.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
                box.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), box.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
                bar.widthAnchor.constraint(equalTo: box.widthAnchor), body.widthAnchor.constraint(equalTo: box.widthAnchor),
            ])
            scroll.isHidden = true
            quickView = qv
            textPeek = peek
            infoView = info
            gitBox = git
            quickBox = box
            updateEmpty()
        } else if !on, let qv = quickView {
            peekGen += 1
            stopLog()
            qv.close()
            infoView?.stop()   // a folder's size, a hash on its way
            quickBox?.removeFromSuperview()
            quickView = nil
            textPeek = nil
            infoView = nil
            gitBox = nil
            quickBox = nil
            scroll.isHidden = false
            updateEmpty()
        }
    }

    @objc private func quickTabClicked() {
        Self.quickTab = QuickTab(rawValue: quickTabs.selectedSegment) ?? .preview
        if let onQuickTab { onQuickTab() } else { preview(peekShown) }
    }

    /// As before the tabs: a file to preview, here, on the Preview tab whatever was chosen (tests).
    func preview(_ url: URL?) { preview(Peek(name: url?.lastPathComponent ?? "", preview: url, local: url), tab: .preview) }

    /// Shows `p` on the tab chosen (`quickTab`, unless `tab`): Preview, Info, or Git where the item is in a work tree
    /// (else there's no Git tab).
    func preview(_ p: Peek, tab chosen: QuickTab? = nil) {
        guard quickView != nil else { return }
        stopLog()
        quickTabs.isHidden = false
        peekShown = p
        quickTitle.stringValue = p.name.bidiVisible
        quickTabs.segmentCount = p.inRepo ? 3 : 2
        if p.inRepo { quickTabs.setLabel("Git", forSegment: 2) }   // a segment taken away and back comes without its word
        let want = chosen ?? Self.quickTab
        let tab = want == .git && !p.inRepo ? .info : want
        quickTabs.selectedSegment = tab.rawValue
        infoView?.isHidden = tab != .info
        gitBox?.isHidden = tab != .git
        switch tab {
        case .preview:
            showPreview(p.preview)
        case .info:
            hidePreview()
            if let rows = p.server { infoView?.show(server: rows) }
            else if let u = p.local { infoView?.show(local: u.path) }
            else { infoView?.show(server: []) }   // ".." on a server: nothing to say
        case .git:
            hidePreview()
            gitState.stringValue = "Git: " + (p.git.map { Self.gitCell($0).word } ?? "unchanged")
            gitState.textColor = theme.text
            // Its actions are this Mac's only (`localOnly`): on a server, its state alone.
            gitKeys.list = p.server != nil ? [] : [("git.diff", "Git Diff", "⌃D"), ("git.log", "Git Log", "⌃L"), ("git.stage", "Stage", "⌃⇧A"),
                                                   ("git.unstage", "Unstage", "⌃⇧U")].map { KeySlot(key: keyFor?($0.0) ?? $0.2, label: $0.1, id: $0.0) }
            gitKeys.isHidden = p.server != nil
        }
    }

    /// Quick View of a list's row next door (`ListPeek`): no tabs, a row isn't a file — its lines as Info shows them,
    /// or a text read once the cursor rests a moment ("Looking…" till then); a row before it still on its way is dropped.
    func preview(list title: String, _ peek: ListPeek?) {
        guard quickView != nil else { return }
        hidePreview()
        listPeekFlag?.cancel()
        stopLog()
        quickTitle.stringValue = title.bidiVisible
        quickTabs.isHidden = true
        gitBox?.isHidden = true
        guard case .text(let read)? = peek else {
            infoView?.isHidden = false
            if case .rows(let rows)? = peek { infoView?.show(server: rows) } else { infoView?.show(server: []) }
            return
        }
        infoView?.isHidden = true
        textPeek?.isHidden = false
        textPeek?.show(Viewer.Painted(text: "Looking…"), numbers: false)
        let gen = peekGen, flag = CancelFlag()
        listPeekFlag = flag
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.peekRest))   // passing over rows asks nothing
            guard let self, gen == peekGen, !flag.isCancelled else { return }
            let text = await Blocking.run(.userInitiated) { () -> String in
                do { return try read(flag) } catch { return "Couldn't look: \(error.localizedDescription)" }
            }
            guard gen == peekGen, !flag.isCancelled else { return }
            textPeek?.show(Viewer.Painted(text: text), numbers: false)
        }
    }
    private var listPeekFlag: CancelFlag?

    /// A list row's log as it goes, next door (⌘L in the list): an output window's text, its window never shown;
    /// started once the cursor rests on the row, the one before stopped at once.
    func preview(log title: String, command: String, on server: SFTPTarget?) {
        guard quickView != nil, let body = textPeek?.superview else { return }
        hidePreview()
        listPeekFlag?.cancel()
        stopLog()
        quickTitle.stringValue = "\(title) — log".bidiVisible
        quickTabs.isHidden = true
        gitBox?.isHidden = true
        infoView?.isHidden = true
        let gen = peekGen
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.peekRest))   // passing over rows starts nothing
            guard let self, gen == peekGen, quickView != nil else { return }
            let w = OutputWindow.embedded(command, on: server, follow: true)
            guard let text = w.text else { return w.close() }
            text.removeFromSuperview()
            text.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(text)
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: body.leadingAnchor), text.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                                         text.topAnchor.constraint(equalTo: body.topAnchor), text.bottomAnchor.constraint(equalTo: body.bottomAnchor)])
            followed = (w, text)
        }
    }
    private var followed: (window: OutputWindow, text: NSScrollView)?
    /// The log next door stops: its command as an output window's closing stops it.
    private func stopLog() {
        guard let f = followed else { return }
        followed = nil
        f.text.removeFromSuperview()
        f.window.close()
    }
    var logShown: String? { (followed?.text.documentView as? NSTextView)?.string }   // tests
    /// How long the cursor rests on a list's row before Quick View asks the server about it (ms).
    static var peekRest = 350
    var quickTitleShown: String? { quickBox == nil ? nil : quickTitle.stringValue }   // tests
    var quickTabsShown: Bool { quickBox != nil && !quickTabs.isHidden }   // tests

    private func hidePreview() {
        peekGen += 1
        textPeek?.isHidden = true
        quickView?.isHidden = true
        quickView?.previewItem = nil   // a video there doesn't play on behind it
    }

    /// Quick Look's preview, or our own of a text it would show as an icon (read off the main thread; the one shown
    /// stays till the next is ready, so passing over files doesn't flicker).
    private func showPreview(_ url: URL?) {
        guard let quickView, let textPeek else { return }
        peekGen += 1
        func quickLook() {
            textPeek.isHidden = true
            quickView.isHidden = false
            quickView.previewItem = url as NSURL?
        }
        guard let url, !TextFormat.quickLookShows(url.lastPathComponent) else { return quickLook() }
        let gen = peekGen
        Task { [weak self] in
            let text = await Blocking.run(.userInitiated) { TextPeek.read(url) }
            guard let self, gen == peekGen else { return }
            guard let text else { return quickLook() }
            let top = peeked != url || textPeek.isHidden
            textPeek.isHidden = false   // first: laid out while shown
            quickView.isHidden = true
            textPeek.show(text, numbers: UserDefaults.standard.bool(forKey: "viewerLineNumbers"), top: top)
            peeked = url
            quickView.previewItem = nil   // a video there doesn't play on behind it
        }
    }

    // MARK: - Tabs (each keeps its own path, cursor and history)

    var tabPaths: [String] {
        var t = tabs
        t[tabIndex].path = path
        return t.map(\.path)
    }

    /// The tabs as a restart brings them back.
    var sessionTabs: [Session.Tab] {
        tabs.indices.map { i in
            let t = tabs[i], now = i == tabIndex
            // A list or a place comes back as its server's place, the cursor on that list's row: nothing asked till ↩.
            if let l = now ? list : t.list {
                let row = l.source is PlaceSource ? l.cursor.map { String($0.id.dropFirst("place ".count)) } : l.source.title
                return Session.Tab(path: now ? path : t.path, cursor: row, server: l.source.target, place: true)
            }
            if let pt = t.place { return Session.Tab(path: t.path, cursor: t.cursor, server: pt, place: true) }
            let server = now ? remote ?? parked : t.remote ?? t.parked
            // The cursor's name; none yet (its listing is on its way): the one it came with.
            return Session.Tab(path: now ? path : t.path, cursor: now && parked == nil ? currentName ?? pendingSelect ?? t.cursor : t.cursor,
                               server: server?.target, root: server?.target.sudo == true, dir: server?.dir)
        }
    }

    func newTab() {
        saveTab()
        if let l = list {   // the same list again, as it is now: no read
            tabs.insert(Tab(path: path), at: tabIndex + 1)
            tabIndex += 1
            (backStack, forwardStack) = ([], [])
            return show(ListPanel(l.source, content: l.content, select: l.cursorID))
        }
        tabs.insert(Tab(path: path, cursor: parked != nil ? tabs[tabIndex].cursor : currentName, remote: remote, parked: parked), at: tabIndex + 1)
        tabIndex += 1
        backStack = []
        forwardStack = []
        marked.removeAll()   // the new tab starts clean; the old one keeps its own
        if filter != nil { clearFilter(apply: false) }
        applyView(select: currentName)
        updateTabBar()
        onPathChange?()
    }

    /// ⌘W closes the current tab; a tab's × closes that one.
    func closeTab(at i: Int? = nil) {
        let i = i ?? tabIndex
        guard tabs.count > 1, tabs.indices.contains(i) else { return NSSound.beep() }
        guard i != tabIndex else {
            tabs.remove(at: i)
            tabIndex = min(tabIndex, tabs.count - 1)
            return loadTab()
        }
        saveTab()
        let wasRemote = tabs[i].remote != nil || tabs[i].list != nil
        tabs.remove(at: i)
        if i < tabIndex { tabIndex -= 1 }
        updateTabBar()
        onPathChange?()   // saves the session
        if wasRemote { onSessionsChange?() }
    }

    func switchTab(by delta: Int) {
        guard tabs.count > 1 else { return }
        switchTab(to: (tabIndex + delta + tabs.count) % tabs.count)
    }

    private func switchTab(to i: Int) {
        guard i != tabIndex, tabs.indices.contains(i) else { return }
        saveTab()
        tabIndex = i
        loadTab()
    }

    @objc private func tabClicked(_ sender: NSButton) {
        switchTab(to: sender.tag)
        updateTabBar()   // clicking the current tab toggled its button off
        view.window?.makeFirstResponder(table)
    }

    @objc private func closeTabClicked(_ sender: NSButton) {
        closeTab(at: sender.tag)
        view.window?.makeFirstResponder(table)
    }

    private func saveTab() {
        tabs[tabIndex].path = path
        // A parked tab's is its own; a tab whose listing isn't in yet keeps the one it came with.
        if parked == nil { tabs[tabIndex].cursor = currentName ?? pendingSelect ?? tabs[tabIndex].cursor }
        tabs[tabIndex].parked = parked
        tabs[tabIndex].back = backStack
        tabs[tabIndex].forward = forwardStack
        tabs[tabIndex].remote = remote
        tabs[tabIndex].list = list
        // Marks in an archive or in search results name entries there, not the files of `path`: they aren't kept.
        let real = archive == nil && searchTitle == nil
        tabs[tabIndex].marked = real ? marked : ExactNames()
        tabs[tabIndex].filter = real && filter != nil ? filterField.stringValue : ""
    }

    private func restore(_ keep: TabMarks, in items: [FileItem]) {
        marked = keep.marked.intersection(items.map(\.name))
        filterField.stringValue = keep.filter
        filterField.isHidden = keep.filter.isEmpty
        filter = keep.filter.isEmpty ? nil : Mask(filter: keep.filter)
    }

    private func loadTab() {
        let t = tabs[tabIndex]
        backStack = t.back
        forwardStack = t.forward
        // Marks and filter are the tab's own, also in another tab of the same folder. They come back with the tab's
        // listing; until then the old rows stay on screen with the old marks.
        let keep = (t.marked, t.filter)
        if let r = t.remote {
            // Take the tab's server now, not when the listing arrives: switching again before then must save this tab as it is.
            path = t.path
            leaveList()
            remote = r
            watcher?.cancel()   // also makes the fallback navigate() below count as a change, clearing `remote`
            watcher = nil
            marked.removeAll()   // `remote` is already the tab's: old rows must not pass for its files
            clearSizes()
            if filter != nil { clearFilter(apply: false) }
            busyMessage = "Connecting to \(r.target.host)… ⎋ cancels"
            loadRemote(r.target, dir: r.dir, select: t.cursor, keep: keep) { [weak self] _ in   // server gone: the tab falls back to its folder
                self?.navigate(to: t.path, history: .none)
            }
        } else if let p = t.parked {
            path = t.path
            park(p)
        } else if let l = t.list {
            path = t.path
            show(l)   // as it was left: nothing read
        } else if let pt = t.place, let onPlace {   // back from a restart: its place, as nothing is asked
            path = t.path
            onPlace(pt, t.cursor)
        } else {
            // Off a parked tab or a list: this tab's own at once — switching again before the listing is back saves it, not that one.
            if parked != nil { (parked, path) = (nil, t.path) }
            if list != nil { leaveList(); path = t.path }
            navigate(to: t.path, select: t.cursor, history: .none, keep: keep)
        }
        updateTabBar()
        onPathChange?()
    }

    // MARK: - SFTP sessions (one per tab on a server; the sidebar lists them)

    struct RemoteTab {
        let id: UUID
        let target: SFTPTarget
        let dir: String
        let isCurrent: Bool
    }

    /// The server tabs the sidebar lists as sessions: a server's files.
    var remoteTabs: [RemoteTab] {
        tabs.enumerated().compactMap { i, t in
            (i == tabIndex ? remote : t.remote).map { RemoteTab(id: t.id, target: $0.target, dir: $0.dir, isCurrent: i == tabIndex) }
        }
    }

    /// Every tab on a server: its files, a list of it, its overview — what Disconnect closes.
    var serverTabs: [RemoteTab] {
        remoteTabs + tabs.enumerated().compactMap { i, t in
            (i == tabIndex ? list : t.list).map { RemoteTab(id: t.id, target: $0.source.target, dir: $0.source.title, isCurrent: i == tabIndex) }
        }
    }

    /// The servers whose connection this panel keeps, if one is up: its sessions', and a place's — ↩ there needs no
    /// login again (`AppDelegate.idleServers`).
    var heldServers: [SFTPTarget] { serverTabs.map(\.target) }

    /// Shows the tab with this id; false if it isn't one of ours.
    @discardableResult
    func showTab(_ id: UUID) -> Bool {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return false }
        switchTab(to: i)
        return true
    }

    /// The tab leaves its server for its local folder; the tab itself stays.
    func closeRemote(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        if i == tabIndex {
            if list != nil {   // at once: its server is being let go
                leaveList()
                onSessionsChange?()
                navigate(to: path, history: .none)
            } else if remote != nil { navigate(to: path, history: .none) }
        } else {
            (tabs[i].remote, tabs[i].list) = (nil, nil)
            updateTabBar()
            onPathChange?()
            onSessionsChange?()
        }
    }

    private func updateTabBar() {
        tabBar.isHidden = tabs.count < 2
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, t) in tabs.enumerated() {
            if let l = i == tabIndex ? list : t.list {
                let chips = Chip.of(l.source.target)
                tabBar.addArrangedSubview(Self.tabButton("\(SavedServer.name(for: l.source.target.asUser)) · \(l.source.title)".bidiVisible, lead: Chip.text(chips),
                                                         tint: Chip.tint(chips), tip: "\(l.source.title) of \(l.source.target.shown)", index: i, current: i == tabIndex,
                                                         target: self, action: #selector(tabClicked(_:)), close: #selector(closeTabClicked(_:))))
                continue
            }
            if let r = i == tabIndex ? remote ?? parked : t.remote ?? t.parked {
                let name = r.dir == "/" ? "/" : (r.dir as NSString).lastPathComponent.bidiVisible, chips = Chip.of(r.target)
                tabBar.addArrangedSubview(Self.tabButton("SFTP · \(r.target.shown) · \(name)", lead: Chip.text(chips), tint: Chip.tint(chips), tip: "\(r.target.shown):\(r.dir)",
                                                         index: i, current: i == tabIndex, target: self, action: #selector(tabClicked(_:)), close: #selector(closeTabClicked(_:))))
                continue
            }
            let p = i == tabIndex ? path : t.path
            tabBar.addArrangedSubview(Self.tabButton(p == "/" ? "/" : (p as NSString).lastPathComponent.bidiVisible, tip: (p as NSString).abbreviatingWithTildeInPath, index: i,
                                                     current: i == tabIndex, target: self, action: #selector(tabClicked(_:)), close: #selector(closeTabClicked(_:))))
        }
    }

    /// A tab: `action` on click, `close` on its × (both get the button with `tag` = index). The terminal's tabs use it too.
    /// The current tab: bold title and an accent line under it; the others' titles are dimmed. `dot`: a state mark before the title.
    static func tabButton(_ title: String, lead: NSAttributedString? = nil, tint: NSColor? = nil, tip: String, index i: Int, current: Bool,
                          target: AnyObject, action: Selector, close: Selector, closeTip: String = "Close Tab  ⌘W") -> NSButton {
        tabButton([(lead, title)], tint: tint, tip: tip, index: i, current: current, target: target, action: action, close: close, closeTip: closeTip)
    }

    /// A tab of several terminal panes: their titles side by side, each after its `lead` (its state, its chips). `tint`:
    /// the line's color (production's, root's) instead of the accent.
    static func tabButton(_ parts: [(NSAttributedString?, String)], tint: NSColor? = nil, tip: String, index i: Int, current: Bool,
                          target: AnyObject, action: Selector, close: Selector, closeTip: String = "Close Tab  ⌘W") -> NSButton {
        let b = NSButton(title: "", target: target, action: action)
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .accessoryBarAction
        b.controlSize = .small
        let size = NSFont.smallSystemFontSize
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let text = NSMutableAttributedString(string: "     ")   // padding keeps the title clear of the ×
        let font = current ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        for (n, (lead, title)) in parts.enumerated() {
            if n > 0 { text.append(NSAttributedString(string: "  │  ", attributes: [.foregroundColor: NSColor.tertiaryLabelColor])) }
            if let lead { text.append(lead); text.append(NSAttributedString(string: " ")) }
            text.append(NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: current ? NSColor.labelColor : NSColor.secondaryLabelColor]))
        }
        text.append(NSAttributedString(string: "     "))
        text.addAttributes([.paragraphStyle: style], range: NSRange(location: 0, length: text.length))
        text.addAttribute(.font, value: NSFont.systemFont(ofSize: size), range: NSRange(location: 0, length: 5))
        b.attributedTitle = text
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.refusesFirstResponder = true
        b.state = current ? .on : .off
        b.tag = i
        b.toolTip = tip
        let x = NSButton(image: Symbol.close.image("Close Tab")
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))!, target: target, action: close)
        x.isBordered = false
        x.refusesFirstResponder = true
        x.contentTintColor = .secondaryLabelColor
        x.tag = i
        x.toolTip = closeTip
        x.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(x)
        NSLayoutConstraint.activate([
            x.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -6),
            x.centerYAnchor.constraint(equalTo: b.centerYAnchor),
        ])
        if current {
            let line = NSBox()
            line.boxType = .custom
            line.borderWidth = 0
            line.fillColor = tint ?? Palette.accent
            line.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 4),
                line.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -4),
                line.bottomAnchor.constraint(equalTo: b.bottomAnchor),
                line.heightAnchor.constraint(equalToConstant: 2),
            ])
        }
        return b
    }

    // MARK: - Marking

    func toggleMark(move: Int) {
        if let list {
            flashed = nil
            return list.toggleMark(move: move)
        }
        let r = table.selectedRow
        guard r >= 0 else { return }
        if let it = item(at: r) {
            if marked.insert(it.name).inserted {
                if it.kind == .dir && dirSizes[it.name] == nil { computeSizes([it.name]) }
            } else {
                marked.remove(it.name)
            }
            table.reloadData(forRowIndexes: [r], columnIndexes: IndexSet(0..<table.numberOfColumns))
            reloadQuickLook()
        }
        moveCursor(to: r + move)
        flashed = nil
        updateStatus()
    }

    /// Visible items (after hidden/filter), for cross-panel features like Compare Folders.
    var listedItems: [FileItem] { rows }
    var markedNames: Set<String> { Set(marked.names) }
    var statusText: String { statusLabel.stringValue }
    var statusAttributed: NSAttributedString { statusLabel.attributedStringValue }   // tests

    /// How many got marked: only what's shown can be (a filter, hidden files).
    @discardableResult
    func setMarks(_ names: Set<String>) -> Int { marked = ExactNames(names).intersection(rows.map(\.name)); refreshMarks(); return marked.count }

    func markAll() { if let list { return list.markAll() }; marked = ExactNames(rows.map(\.name)); refreshMarks() }
    func unmarkAll() { if let list { return list.unmarkAll() }; marked.removeAll(); refreshMarks() }
    func invertMarks() { if let list { return list.invertMarks() }; marked = marked.complement(in: rows.map(\.name)); refreshMarks() }

    /// "+" / "-" (MC/TC): (un)mark files — not folders — whose names match the mask.
    func mark(matching mask: Mask, _ on: Bool) {
        for it in rows where it.kind != .dir && mask.matches(it.name) {
            if on { marked.insert(it.name) } else { marked.remove(it.name) }
        }
        refreshMarks()
    }

    private func refreshMarks() {
        flashed = nil
        table.reloadData(forRowIndexes: IndexSet(0..<table.numberOfRows), columnIndexes: IndexSet(0..<table.numberOfColumns))
        reloadQuickLook()
        updateStatus()
    }

    /// ⌘-click toggles one row, ⇧-click marks the range from the cursor.
    private func markClick(_ row: Int, _ mods: NSEvent.ModifierFlags) {
        if let list { return list.markClick(row, mods) }
        if mods.contains(.shift) {
            let from = max(table.selectedRow, 0)
            for r in min(from, row)...max(from, row) {
                if let it = item(at: r) { marked.insert(it.name) }
            }
        } else if let it = item(at: row) {
            if !marked.insert(it.name).inserted { marked.remove(it.name) }
        }
        moveCursor(to: row)
        refreshMarks()
    }

    // MARK: - Folder sizes (Space on a folder, or all at once)

    func computeAllDirSizes() {
        computeSizes(rows.filter { $0.kind == .dir && dirSizes[$0.name] == nil }.map(\.name))
    }

    /// The folder's sizes are another folder's now: the ones on their way are dropped, a server walk stops.
    private func clearSizes() {
        dirSizes.removeAll()
        partialSizes.removeAll()
        sizeGen += 1
        sizeQueue.removeAll()
        sizeWalk?.cancel()
        sizeWalk = nil
    }

    /// One walk at a time (on a server, over one connection), folders asked for meanwhile (Space down a list) next;
    /// the status line says so and ⎋ stops it, as does leaving the folder (`clearSizes`). On a server its du counts them
    /// (one command for them all, no SFTP session); one without a du that counts bytes, and names du can't be given, walk.
    private func computeSizes(_ names: [String]) {
        guard archive == nil else { return }
        sizeQueue += names.filter { !sizeQueue.contains($0) }
        guard sizeWalk == nil else { return }   // the walk running takes them next
        let flag = CancelFlag(), gen = sizeGen, env = SSHAskpass.env, r = remote, base = path
        let duKey = r?.target
        sizeWalk = flag
        // Sizes reach the main thread in bunches: one hop, one redraw and one status for all that came meanwhile.
        let inbox = SizeInbox()
        let found: @Sendable (String, Int64, Bool) -> Void = { [weak self] name, bytes, partial in
            guard inbox.add((name, bytes, partial)) else { return }   // a hop is on its way already
            DispatchQueue.main.async { MainActor.assumeIsolated { let s = inbox.take(); if self?.sizeGen == gen { self?.setSizes(s) } } }
        }
        Task { [weak self] in
            while let self, sizeWalk === flag {
                let names = sizeQueue.filter { dirSizes[$0] == nil }
                sizeQueue.removeAll()
                guard !names.isEmpty else { sizeWalk = nil; return }
                let du = duKey.map { !Self.noDu.contains($0) } ?? false
                // On this Mac most walks take a moment: Space down a list would flash the message on every folder.
                let result = await busy("Counting folder sizes…", after: r == nil ? 0.4 : 0, flag: flag) { flag -> Bool in
                    func each(_ names: [String], _ measure: (String) throws -> Int64) rethrows { for name in names { found(name, try measure(name), false) } }
                    guard let r else {
                        try each(names) {
                            let bytes = Self.measureLocal((base as NSString).appendingPathComponent($0)) { flag.isCancelled }
                            if flag.isCancelled { throw CancellationError() }   // a part of it: no size
                            return bytes
                        }
                        return false
                    }
                    var walk = names, noDu = false
                    if du {
                        if let sizes = try Self.measureRemote(names, r.dir, r.target, env, flag) {
                            for (name, s) in sizes { found(name, s.bytes, s.partial) }
                            walk = names.filter { sizes[$0] == nil }
                        } else {
                            noDu = true
                        }
                    }
                    if !walk.isEmpty {
                        try SFTPClient.session(r.target, env: env, cancel: flag) { c in
                            try each(walk) { try c.measure((r.dir as NSString).appendingPathComponent($0), cancel: flag) }
                        }
                    }
                    return noDu
                }
                if case .success(true) = result, let duKey { Self.noDu.insert(duKey) }
                if case .failure(let error) = result {
                    if sizeWalk === flag { sizeWalk = nil; sizeQueue.removeAll() }
                    if !(error is CancellationError) { flash("Can't count folder sizes: \(error.localizedDescription)", error: true) }
                    return
                }
            }
        }
    }

    private func setSizes(_ sizes: [(name: String, bytes: Int64, partial: Bool)]) {
        var shown = IndexSet()
        for (name, bytes, partial) in sizes {
            if let r = row(named: name) {
                totalSize = totalSize.saturatingAdd(bytes - (dirSizes[name] ?? 0))   // only what's listed counts, as in `bytes(of: rows)`
                shown.insert(r)
            }
            dirSizes[name] = bytes
            if partial { partialSizes.insert(name) } else { partialSizes.remove(name) }
        }
        table.reloadData(forRowIndexes: shown, columnIndexes: [table.column(withIdentifier: .init("size"))])
        updateStatus()
    }

    /// Folder sizes counted off the main thread, waiting for it.
    private final class SizeInbox: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [(name: String, bytes: Int64, partial: Bool)] = []
        /// True when the inbox was empty: the caller sends the hop that takes it.
        func add(_ s: (String, Int64, Bool)) -> Bool { lock.withLock { sizes.append(s); return sizes.count == 1 } }
        func take() -> [(name: String, bytes: Int64, partial: Bool)] { lock.withLock { defer { sizes = [] }; return sizes } }
    }

    // MARK: - Path field (⌘L) and quick filter (/)

    /// The header: search results' title, "archive/inner", "host:/dir" on a server ("root@host:/dir" on a root panel), else the
    /// local folder — after a symbol of the place and its chips (`styleHeader`). Also what ⎋ in the path field brings back.
    func showPath() {
        headerText = if let l = list { "\(l.source.target.shown) › \(l.source.title)" }
            else if let t = searchTitle { t }
            else if let a = archive { (a.index.file as NSString).abbreviatingWithTildeInPath + (a.inner.isEmpty ? "" : "/" + a.inner) }
            else if let r = remote ?? parked { "\(r.target.shown):\(r.dir)" }
            else { (path as NSString).abbreviatingWithTildeInPath }
        pathBar.crumbs = if let l = list { [PathBar.Crumb(title: l.source.title, path: nil)] }   // after the server's chip
            else if let t = searchTitle { [PathBar.Crumb(title: t, path: nil)] }
            else if let a = archive {   // the archive is its root; the folders inside it after
                [PathBar.Crumb(title: (a.index.file as NSString).lastPathComponent, path: "")] + Self.crumbs(a.inner, inside: true)
            } else if let p = parked { Self.crumbs(p.dir).map { PathBar.Crumb(title: $0.title, path: nil) } }   // nothing sent till ↩
            else { Self.crumbs(remote?.dir ?? path, home: remote == nil) }
        pathBar.editing = false
        styleHeader()
    }

    /// A path's crumbs, each with where it goes: "/", "etc", "nginx"; a local one under the home folder from "~".
    /// `inside`: an archive's inner path, relative ("" its root).
    static func crumbs(_ path: String, home: Bool = false, inside: Bool = false) -> [PathBar.Crumb] {
        let tilde = home ? (path as NSString).abbreviatingWithTildeInPath : path
        var out: [PathBar.Crumb] = []
        var at = inside ? "" : tilde.hasPrefix("~") ? NSHomeDirectory() : "/"
        if !inside { out.append(.init(title: tilde.hasPrefix("~") ? "~" : "/", path: at)) }
        for part in tilde.split(separator: "/").dropFirst(tilde.hasPrefix("~") ? 1 : 0) {
            at = at.isEmpty ? String(part) : (at as NSString).appendingPathComponent(String(part))
            out.append(.init(title: String(part), path: at))
        }
        return out
    }

    /// A crumb clicked: that folder here — the cursor on where you came from — or (⌥) in the other panel.
    func goTo(_ crumb: PathBar.Crumb, otherPanel: Bool) {
        guard let dir = crumb.path else { return }
        if otherPanel, archive == nil { return onOpenInOther?(dir, remote?.target) ?? () }
        onFocus?()
        func child(of dir: String, in here: String) -> String? {
            let prefix = dir.isEmpty || dir == "/" ? dir : dir + "/"
            return here.hasPrefix(prefix) && here != dir ? here.dropFirst(prefix.count).split(separator: "/").first.map(String.init) : nil
        }
        if let a = archive {
            archive!.inner = dir
            return showArchive(select: child(of: dir, in: a.inner))
        }
        if let r = remote { return loadRemote(r.target, dir: dir, select: child(of: dir, in: r.dir)) }
        navigate(to: dir)   // coming up, it lands on the folder it came from
    }

    /// Copy at the path bar's end: the folder's full path — here `/Users/…`, not `~`; on a server its path there, or
    /// (`scp`) `user@host:path`. What ⇧⌘C copies for the folder, one line.
    func copyPath(scp: Bool, to pasteboard: NSPasteboard = .general) {
        let text: String
        if let r = remote, scp { text = Self.scpPath(r.target, r.dir) }
        else { text = archive?.index.file ?? remote?.dir ?? parked?.dir ?? path }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func beginPathEditing() {
        guard list == nil else { return }   // a list has no path to type: its chip goes to the server
        completions = nil
        onFocus?()
        pathBar.editing = true
        view.window?.makeFirstResponder(pathField)
        pathField.stringValue = remote.map { $0.dir == "/" ? "/" : $0.dir + "/" } ?? (path as NSString).abbreviatingWithTildeInPath + (hasParent ? "/" : "")
        pathField.currentEditor()?.selectAll(nil)   // typing replaces the path; End, then a name, goes below it
    }

    func beginFilter() {
        filterField.isHidden = false
        view.window?.makeFirstResponder(filterField)
        showFilterChip()
    }

    /// A filter kept after ↩ is a chip at the path bar's right end; while it's typed, the field says it.
    private func showFilterChip() { pathBar.filter = filtering && !filterFocused ? filterField.stringValue : nil }
    /// A filter is on: the folder's mask, or what a list's rows are filtered by.
    private var filtering: Bool { filter != nil || list.map { !$0.filter.isEmpty } == true }

    /// Applies a filter as if typed and confirmed (Filter Presets).
    func applyFilter(_ text: String) {
        filterField.stringValue = text
        filterField.isHidden = false
        filter = Mask(filter: text)
        applyView(select: currentName)
        Self.rememberFilter(text)
    }

    /// Recent filters for the presets picker (newest first).
    static func rememberFilter(_ text: String) {
        guard !text.isEmpty else { return }
        let recent = UserDefaults.standard.stringArray(forKey: "recentFilters") ?? []
        UserDefaults.standard.set(Array(([text] + recent.filter { $0 != text }).prefix(20)), forKey: "recentFilters")
    }

    private func clearFilter(apply: Bool = true) {
        filterField.stringValue = ""
        filterField.isHidden = true
        filter = nil
        list?.filter("")
        showFilterChip()
        if apply { applyView(select: currentName) }
    }

    func controlTextDidBeginEditing(_ obj: Notification) { onFocus?() }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === filterField else { return }
        if let list { return list.filter(filterField.stringValue) }   // its rows by title, subtitle, detail
        filter = filterField.stringValue.isEmpty ? nil : Mask(filter: filterField.stringValue)
        applyView(select: currentName)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === pathField {
            completing?.cancel()
            showPath()   // the crumbs back
        } else if !filtering {
            filterField.isHidden = true
        } else {
            showFilterChip()
        }
    }

    /// The quick filter's keys, as `control(_:textView:doCommandBy:)` takes them: the key bar while it has the focus.
    /// A slot's click runs `filterKey`, as the key.
    static let filterKeys = [KeySlot(key: "↩", label: "Keep", id: "filter.keep"), KeySlot(key: "↓", label: "Back to List", id: "filter.list"),
                             KeySlot(key: "⎋", label: "Clear", id: "filter.clear")]

    var filterFocused: Bool { filterField.currentEditor().map { $0 === view.window?.firstResponder } ?? false }

    /// What a key of the quick filter does — pressed there, or its slot clicked.
    func filterKey(_ id: String) {
        switch id {
        case "filter.keep":
            if list == nil { Self.rememberFilter(filterField.stringValue) }   // Filter Presets' recent: masks of files
            confirmFilter()
        case "filter.list": confirmFilter()
        case "filter.clear":
            clearFilter()
            view.window?.makeFirstResponder(table)
        default: break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if control === filterField {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)): filterKey("filter.keep")
            case #selector(NSResponder.moveDown(_:)): filterKey("filter.list")
            case #selector(NSResponder.cancelOperation(_:)): filterKey("filter.clear")
            default: return false
            }
            return true
        }
        let key: String? = switch sel {
        case #selector(NSResponder.insertNewline(_:)): "path.go"
        case #selector(NSResponder.cancelOperation(_:)): "path.back"
        case #selector(NSResponder.insertTab(_:)): "path.complete"
        default: nil
        }
        guard let key else { return false }
        pathKey(key, textView)
        return true
    }

    /// The path field's keys (⌘L, a click on an empty spot of the path bar), as `control(_:textView:doCommandBy:)` takes
    /// them: the key bar while it has the focus. A slot's click runs `pathKey`, as the key.
    static let pathKeys = [KeySlot(key: "↩", label: "Go", id: "path.go"), KeySlot(key: "⇥", label: "Complete", id: "path.complete"),
                           KeySlot(key: "⎋", label: "Back to Panel", id: "path.back")]

    var pathFocused: Bool { pathField.currentEditor().map { $0 === view.window?.firstResponder } ?? false }

    /// What a key of the quick filter or the path field does — pressed there, or its slot clicked.
    func fieldKey(_ id: String) {
        if id.hasPrefix("filter.") { return filterKey(id) }
        if let tv = pathField.currentEditor() as? NSTextView { pathKey(id, tv) }
    }

    private func pathKey(_ id: String, _ textView: NSTextView) {
        switch id {
        case "path.go" where remote != nil:   // a path on the server
            let r = remote!, typed = textView.string
            let dir = ((typed.hasPrefix("/") ? typed : (r.dir as NSString).appendingPathComponent(typed)) as NSString).standardizingPath
            view.window?.makeFirstResponder(table)
            loadRemote(r.target, dir: dir, select: nil) { [weak self] in self?.flash($0.localizedDescription, error: true) }
        case "path.go":
            let target = resolve(textView.string), gen = moves
            Task { [weak self] in
                let isDir = await Blocking.run(.userInitiated) { () -> Bool? in   // off the main thread, as ↩ on a link
                    var d: ObjCBool = false
                    return FileManager.default.fileExists(atPath: target, isDirectory: &d) ? d.boolValue : nil
                }
                guard let self, gen == moves else { return }
                guard let isDir else {
                    NSSound.beep()
                    return flash("No such folder: \((target as NSString).abbreviatingWithTildeInPath)", error: true)
                }
                if isDir { navigate(to: target) }
                else { navigate(to: (target as NSString).deletingLastPathComponent, select: (target as NSString).lastPathComponent) }
                view.window?.makeFirstResponder(table)
            }
        case "path.back": view.window?.makeFirstResponder(table)
        case "path.complete": complete(textView)
        default: break
        }
    }

    private func resolve(_ input: String) -> String {
        let p = (input as NSString).expandingTildeInPath
        return ((p.hasPrefix("/") ? p : (path as NSString).appendingPathComponent(p)) as NSString).standardizingPath
    }

    /// Shell-like completion: extend to the longest common prefix of matching folders.
    private func complete(_ tv: NSTextView) {
        let typed = tv.string, server = remote
        let full = server == nil ? (typed as NSString).expandingTildeInPath : typed
        let endsWithSlash = full.hasSuffix("/")
        let dir = endsWithSlash ? full : (full as NSString).deletingLastPathComponent
        let prefix = endsWithSlash ? "" : (full as NSString).lastPathComponent
        // A server tab completes from the server's folders (relative to its folder), not this Mac's.
        let listed = server.map { r in ((dir.hasPrefix("/") ? dir : (r.dir as NSString).appendingPathComponent(dir)) as NSString).standardizingPath }
            ?? resolve(dir)
        let hidden = showHidden, cached = completions?.dir == listed ? completions?.items : nil
        // A server that took the connection and stopped answering (its sftp-server stuck on NFS) held a thread a ⇥:
        // the next ⇥, leaving the field or a few seconds end it, and then ⇥ does nothing — no beep, nothing kept.
        completing?.cancel()
        let flag = CancelFlag()
        completing = flag
        if server != nil, cached == nil { Timeouts.queue.asyncAfter(deadline: .now() + 5) { flag.cancel() } }
        Task { [weak self] in
            // Off the main thread: a share that stopped answering, a far server. A server's folder is listed once while typing.
            let items = if let cached { cached } else {
                await Blocking.run(.userInitiated) {
                    server.map { (try? SFTP.list($0.target, listed, env: SSHAskpass.env, cancel: flag)) ?? [] } ?? (try? DirLister.list(listed)) ?? []
                }
            }
            guard !flag.isCancelled else { return }
            if server != nil, cached == nil { self?.completions = (listed, items) }
            let names = items.filter { ($0.kind == .dir || $0.kind == .link) && $0.name.lowercased().hasPrefix(prefix.lowercased()) && (hidden || !$0.isHidden) }
                .map(\.name)
            guard self != nil, tv.string == typed else { return }   // typed on meanwhile
            Self.complete(tv, typed: typed, dir: dir, names: names)
        }
    }

    private static func complete(_ tv: NSTextView, typed: String, dir: String, names: [String]) {
        guard let first = names.first else { return NSSound.beep() }
        var common = first
        for n in names.dropFirst() {
            common = String(common.prefix(zip(common.lowercased(), n.lowercased()).prefix { $0 == $1 }.count))
        }
        var result = (dir as NSString).appendingPathComponent(common)
        if typed.hasPrefix("~") { result = (result as NSString).abbreviatingWithTildeInPath }
        if names.count == 1 { result += "/" } else { NSSound.beep() }
        tv.string = result
        tv.selectedRange = NSRange(location: tv.string.utf16.count, length: 0)
    }

    // MARK: - Quick Look (⌘Y). The panel finds us through the responder chain.

    /// What ⌘Y shows: the marks or the cursor; on a server the cursor's file, once its copy is here (`fetchPreview`).
    var quickLookURLs: [URL] { remote == nil ? targetURLs : previewCopy.map { [$0] } ?? [] }

    /// The cursor's file for ⌃Q next door; on a server its copy, fetched first (`onCursorChange` again once here).
    func previewURL() -> URL? {
        guard remote != nil else { return cursorURL }
        fetchPreview()
        return previewCopy
    }

    /// Fetched by any panel: the copies are the app's (`ServerCopies`), kept until quit.
    private var previewCopy: URL? {
        guard let r = remote, let k = previewKey else { return nil }
        return ServerCopies.preview(of: r.target, k.path, size: k.size, mtime: k.mtime)
    }

    private var previewKey: PreviewKey? {
        guard let (_, dir, it) = remoteCursor, it.kind == .file || it.kind == .link && !it.linkDir else { return nil }
        return PreviewKey(path: (dir as NSString).appendingPathComponent(it.name), size: it.size, mtime: it.mtime, link: it.kind == .link)
    }

    // ponytail: fixed; a setting if someone previews bigger files over a fast link.
    static let previewLimit: Int64 = 64 << 20    // a server file over this isn't fetched just to be previewed

    /// Fetches the cursor's server file once the cursor rests on it a moment; the one on its way before stops.
    /// Only while a preview is open (⌃Q next door, ⌘Y): each copy is a write to this Mac's disk.
    private func fetchPreview() {
        let want = previewKey
        guard want != previewFor else { return }
        previewFor = want
        previewFlag?.cancel()
        previewFlag = nil
        guard let want, let r = remote, previewCopy == nil else { return }
        let name = (want.path as NSString).lastPathComponent
        let flag = CancelFlag(), env = SSHAskpass.env, limit = Self.previewLimit
        previewFlag = flag
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))   // passing by, it's not wanted
            guard !flag.isCancelled else { return }
            guard want.size <= limit else { self?.flash("“\(name)” is too big to preview (over \(limit >> 20) MB)"); return }
            let result = await Blocking.run(.userInitiated) {
                Result { try ServerCopies.download(r.target, want.path, look: want.link, limit: limit, env: env, cancel: flag) }
            }
            guard let self, !flag.isCancelled, case .success(let (local, attrs)?) = result else {
                if case .success(let got?) = result { TempCopies.remove(got.url.deletingLastPathComponent().path) }   // ⎋ just now
                if case .failure(let e) = result, !flag.isCancelled { self?.flash("Can't preview “\(name)”: \(e.localizedDescription)", error: true) }
                return
            }
            previewFlag = nil
            ServerCopies.add(.init(local, r.target, want.path, listed: (want.size, want.mtime), baseline: attrs, preview: true))
            reloadQuickLook()
            onCursorChange?()
        }
    }

    /// The fetch on its way stops with the folder (and the panel); the copies stay (`ServerCopies`).
    private func stopPreview() {
        previewFlag?.cancel()
        previewFlag = nil
        previewFor = nil
    }

    func toggleQuickLook() {
        guard let ql = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && ql.isVisible { ql.orderOut(nil) } else { ql.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    // Declared nonisolated by QuickLookUI, but AppKit always calls them on the main thread.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
            quickLook = panel
            fetchPreview()
            quickLooked = quickLookURLs
            copyTexts()
        }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            quickLook = nil
            if !lookCopies.isEmpty {   // closed: its copies go
                lookGen += 1
                lookCopies = [:]
                let ticket = TextCopies.ticket()
                Task { await Blocking.run { _ = TextCopies.make([], ticket: ticket) } }
            }
        }
    }

    // MARK: - Clipboard (Edit ▸ Copy / Paste act on files when the panel has focus)

    @objc func copy(_ sender: Any?) {
        if list != nil { return onListKey?(Shortcut("cmd+c")!) ?? () }   // the row's ⌘C: its name, its address
        guard let items = transferItems else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items.pasteboardWriters)
    }

    @objc func paste(_ sender: Any?) {
        guard archive == nil else { return flash("Archives are read-only here") }
        if let listHint { return flash(listHint) }
        if let parkedHint { return flash(parkedHint) }
        guard let items = TransferItems(NSPasteboard.general) else { return NSSound.beep() }
        onTransfer?(items, endpoint, currentDir, false)
    }

    // MARK: - Context menu

    /// The file the context menu's "Open With" lists apps for.
    private var openWith: URL?
    /// The row a menu opened from the keyboard is for (`clickedRow` is −1 then).
    private var menuRow: Int?
    /// A folder menu's command is running: it acts on this folder, not on the cursor's item.
    private var forFolder = false

    /// The Menu key, ⇧F10: the cursor's item's menu by its row (not by the mouse); on ".." or nothing, the folder's.
    func showContextMenu() {
        guard let menu = table.menu else { return }
        let r = table.selectedRow
        if r >= 0 { table.scrollRowToVisible(r) }
        let rect = r >= 0 ? table.rect(ofRow: r) : NSRect(x: 0, y: table.visibleRect.minY, width: 0, height: 0)
        menuRow = r
        defer { menuRow = nil }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + 24, y: rect.maxY), in: table)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu !== table.menu {   // "Open With", opening
            if let openWith { fillOpenWith(menu, for: openWith) }
            return
        }
        let r = menuRow ?? table.clickedRow
        onFocus?()   // the menu's commands act on the active panel: make it this one
        if let list {   // a row's actions, as ⌃↩; a click elsewhere than the cursor's row moves it there first
            if menuRow == nil, list.shown.indices.contains(r), !list.marked.contains(list.shown[r].id) {   // as Finder, as files
                if !list.marked.isEmpty { list.unmarkAll() }
                list.moveCursor(to: r)
            }
            return onListMenu?(menu) ?? ()
        }
        // Like Finder: a click outside the marked set acts on the clicked item alone, never on marks elsewhere. The
        // keyboard's acts as the F-keys do: on the marks, or the cursor's.
        if menuRow == nil, r >= 0, let it = item(at: r), !marked.contains(it.name) {
            if !marked.isEmpty { unmarkAll() }
            moveCursor(to: r)
        }
        fillMenu(menu, row: r)
    }

    /// The context menu of `row`'s item; of the folder for ".." and empty space (−1). Each item is a command.
    func fillMenu(_ menu: NSMenu, row: Int) {   // internal for tests
        func add(_ title: String, _ id: String) {
            let mi = menu.addItem(withTitle: title, action: #selector(contextCommand(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = id
        }
        if parked != nil { return add("Connect", "open") }   // its folder's menu would act on the local one behind it
        guard row >= 0, let it = item(at: row) else { return fillFolderMenu(menu) }
        add("Open", "open")
        // Its apps and their icons are looked up when it opens, not on every right-click.
        let apps = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        apps.submenu = NSMenu()
        apps.submenu?.delegate = self
        openWith = url(of: it)
        menu.addItem(apps)
        menu.addItem(.separator())
        add("Quick Look", "file.quicklook")
        add("View", "file.view")
        add("Edit", "file.edit")
        add("Get Info", "file.info")
        add("Reveal in Finder", "file.reveal")
        add("Open in Terminal", "file.terminal")
        menu.addItem(.separator())
        add("Copy Path", "edit.copyPath")
        add("Copy Name", "edit.copyName")
        menu.addItem(.separator())
        add("New File…", "file.new")
        add("Rename…", "file.rename")
        add("Copy Here As…", "file.copyAs")
        add("Copy To…", "file.copy")
        add("Move To…", "file.move")
        add(remote != nil ? "Delete…" : "Move to Trash", "file.trash")
    }

    private func fillFolderMenu(_ menu: NSMenu) {
        @discardableResult func add(_ title: String, _ id: String, to m: NSMenu? = nil, on: Bool = false) -> NSMenuItem {
            let mi = (m ?? menu).addItem(withTitle: title, action: #selector(contextCommand(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = id
            mi.tag = 1   // for the folder
            mi.state = on ? .on : .off
            return mi
        }
        add("New File…", "file.new")
        add("New Folder…", "file.mkdir")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        add(remote != nil ? "SSH Here" : "Open in Terminal", "file.terminal")
        if archive == nil { add("Copy Path", "edit.copyPath") }
        if remote == nil, archive == nil {   // this Mac's folder
            add("Reveal in Finder", "file.reveal")
            add("Get Info", "file.info")
        }
        menu.addItem(.separator())
        add("Show Hidden Files", "view.hidden", on: showHidden)
        let sort = NSMenu()
        for (title, key) in [("Name", SortKey.name), ("Size", .size), ("Modified", .mtime)] {
            add(title, "view.sort." + key.rawValue, to: sort, on: sortKey == key)
        }
        sort.addItem(.separator())
        add("Reverse", "view.sort.reverse", to: sort, on: ascending != (sortKey == .name))
        menu.addItem(withTitle: "Sort By", action: nil, keyEquivalent: "").submenu = sort
        add("Calculate Folder Sizes", "view.dirsizes")
        if git != nil || remote != nil { menu.addItem(.separator()) }
        if git != nil { add("Git Changes", "git.changes") }
        if remote != nil {
            add("Services…", "server.services")
            add("Containers…", "server.containers")
        }
    }

    private func fillOpenWith(_ m: NSMenu, for url: URL) {
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url) {
            let mi = m.addItem(withTitle: FileManager.default.displayName(atPath: app.path), action: #selector(openWith(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            mi.image = icon
        }
    }

    @objc private func contextCommand(_ sender: NSMenuItem) {
        forFolder = sender.tag == 1
        defer { forFolder = false }
        onCommand?(sender.representedObject as! String)
    }

    @objc private func openWith(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(targetURLs, withApplicationAt: sender.representedObject as! URL, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int { parked != nil ? 0 : rows.count + (hasParent ? 1 : 0) }   // parked: the middle says it

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column else { return nil }
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? PanelCell
            ?? makeCell(column.identifier)
        let it = item(at: row)
        let tf = cell.textField!
        let isMarked = it.map { marked.contains($0.name) } ?? false
        let link = it?.kind == .link && archive == nil && searchTitle == nil ? links[it!.name] : nil   // the folder's, here or on the server
        switch column.identifier.rawValue {
        case "name":
            tf.stringValue = it?.displayName ?? ".."
            cell.imageView?.image = switch it?.kind {
            case nil, .dir: Self.folderIcon
            case .link: Self.linkIcon
            case .file where it!.mode & 0o111 != 0: Self.execIcon
            default: Self.fileIcon
            }
            tf.font = theme.mono ? .monospacedSystemFont(ofSize: 12, weight: isMarked ? .bold : .regular)
                : isMarked ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
            cell.toolTip = link.map { Self.linkNote($0.target, $0.error) } ?? it.flatMap(Self.specialKind)
            cell.check.isHidden = !isMarked   // a mark is a shape too, not only a color
            tf.setAccessibilityLabel(isMarked ? "marked" : nil)
        case "git":
            let mark = it.flatMap { git?.marks[$0.name] }.map(Self.gitCell)
            tf.alignment = .center
            tf.stringValue = ""
            cell.text = mark.map { Self.gitText($0, size: NSFont.systemFontSize - 1) }
            tf.setAccessibilityLabel(mark?.word)
            return cell
        case "size":
            tf.stringValue = it.map { Self.sizeText($0, measured: dirSizes[$0.name], partial: partialSizes.contains($0.name)) } ?? ""
        case "mode":
            tf.stringValue = it.flatMap { archive == nil ? Perms.string($0.mode) : nil } ?? ""
        case "owner", "group":
            let owner = column.identifier.rawValue == "owner", id = it.map { owner ? $0.uid : $0.gid } ?? FileItem.unknown
            tf.stringValue = remote != nil ? it.flatMap { remoteOwners[$0.name] }.map { owner ? $0.0 : $0.1 } ?? ""
                : id == FileItem.unknown ? "" : Self.idName(id, user: owner)
        default:
            tf.stringValue = it.map { dates.text(Date(timeIntervalSince1970: $0.mtime)) } ?? ""
        }
        cell.text = nil
        cell.color = isMarked ? theme.marked : (link?.error ?? 0) != 0 ? Palette.fail : it?.isHidden == true ? theme.hidden
            : it == nil || it?.kind == .dir || it?.linkDir == true ? theme.dir : it!.kind == .file && it!.mode & 0o111 != 0 ? theme.exec : theme.text
        if column.identifier.rawValue == "name", let it, it.label != 0 || link != nil {   // Finder tag color, a link's target
            let base: [NSAttributedString.Key: Any] = [.font: tf.font!, .foregroundColor: cell.color]
            let s = NSMutableAttributedString(string: it.displayName, attributes: base)
            if let link {   // dimmed, and only if it fits beside the name (26 pt: icon and margins)
                let note = NSAttributedString(string: "  " + Self.linkNote(link.target, link.error), attributes: [.font: tf.font!, .foregroundColor: theme.hidden])
                if s.size().width + note.size().width <= column.width - 26 { s.append(note) }
            }
            if it.label != 0 {
                s.append(NSAttributedString(string: " "))
                s.append(Symbol.dot.text(NSWorkspace.shared.fileLabelColors[Int(it.label)], font: tf.font!, label: NSWorkspace.shared.fileLabels[Int(it.label)]))
            }
            cell.text = s
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> PanelCell {
        let cell = PanelCell()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(tf)
        cell.textField = tf
        var c = [tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                 tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]
        if id.rawValue == "name" {
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            cell.imageView = iv
            cell.check.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(cell.check)
            c += [cell.check.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1),
                  cell.check.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                  cell.check.widthAnchor.constraint(equalToConstant: 10),
                  iv.leadingAnchor.constraint(equalTo: cell.check.trailingAnchor, constant: 2),
                  iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                  iv.widthAnchor.constraint(equalToConstant: 16),
                  iv.heightAnchor.constraint(equalToConstant: 16),
                  tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4)]
        } else {
            tf.alignment = .right
            tf.font = id.rawValue == "mode" ? .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
                : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
            c.append(tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(c)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = PanelRowView()
        (v.cursor, v.outline) = (theme.cursor, theme.outline)
        return v
    }

    /// Selection is the cursor: always one row, except transiently while starting a drag of marked items.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        table.allowMultiSelection || proposed.count <= 1 ? proposed : IndexSet(integer: proposed.last!)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        reloadQuickLook()
        onCursorChange?()
    }

    /// What Quick Look shows (the marks, or the cursor) may have changed. The same items again (a re-list every 3 s
    /// while a download grows next door) leave the preview alone: a reload starts a video over.
    private func reloadQuickLook() {
        guard let quickLook else { return }
        fetchPreview()
        guard quickLookURLs != quickLooked else { return }
        quickLooked = quickLookURLs
        quickLook.reloadData()
        copyTexts()
    }

    /// Texts Quick Look would show as an icon get a `.txt` copy it shows as text (made off the main thread; till
    /// then, the file itself).
    private func copyTexts() {
        lookGen += 1
        let gen = lookGen, urls = quickLooked.prefix(TextCopies.most).filter { !TextFormat.quickLookShows($0.lastPathComponent) }
        let wanted = Set(urls)
        lookCopies = lookCopies.filter { wanted.contains($0.key) }
        lookAsked = []
        guard quickLooked.contains(where: { !TextFormat.quickLookShows($0.lastPathComponent) }) else { return }
        let ticket = TextCopies.ticket()
        lookTicket = ticket
        Task { [weak self] in
            let made = await Blocking.run(.userInitiated) { TextCopies.make(urls, ticket: ticket) }
            guard let self, gen == lookGen, let quickLook else { return }
            lookCopies = made
            if !made.isEmpty { quickLook.reloadData() }
        }
    }

    /// Native type-to-jump: typing "rea" moves the cursor to README.
    func tableView(_ tableView: NSTableView, typeSelectStringFor column: NSTableColumn?, row: Int) -> String? {
        column?.identifier.rawValue == "name" ? (item(at: row)?.name ?? "..") : nil
    }

    // MARK: - Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard archive == nil, let it = item(at: row) else { return nil }
        if let r = remote { return TransferItems.pasteboardItem(r.target, (r.dir as NSString).appendingPathComponent(it.name)) }
        return url(of: it) as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard archive == nil, parked == nil, let items = Self.dropped(info) else { return [] }
        let target = dropTarget(row: row, op: op)
        if target == currentDir { tableView.setDropRow(-1, dropOperation: .on) }
        return Self.dragOperation(info, items: items, to: endpoint, target: target)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        let target = dropTarget(row: row, op: op)
        guard let items = Self.dropped(info) else { return false }
        let operation = Self.dragOperation(info, items: items, to: endpoint, target: target)
        guard !operation.isEmpty else { return false }
        onTransfer?(items, endpoint, target, operation == .move)
        return true
    }

    /// What a drop carries: the pasteboard's items, which name a server's user, never root. Dragged from a root panel of
    /// this app, they're that panel's again — known from the drag's source in this process, not from the pasteboard —
    /// so a move inside it stays a move, and a drag out of it reads as root.
    private static func dropped(_ info: NSDraggingInfo) -> TransferItems? {
        TransferItems(info.draggingPasteboard).map { dropped($0, from: ((info.draggingSource as? NSTableView)?.delegate as? PanelViewController)?.remote?.target) }
    }

    static func dropped(_ items: TransferItems, from source: SFTPTarget?) -> TransferItems {
        guard let source, source.sudo, case .sftp(let t) = items.from, t == source.asRoot(false) else { return items }
        var items = items
        items.from = .sftp(source)
        return items
    }

    private func dropTarget(row: Int, op: NSTableView.DropOperation) -> String {
        guard op == .on, row >= 0, row < table.numberOfRows, let it = item(at: row), it.kind == .dir else { return currentDir }
        return (currentDir as NSString).appendingPathComponent(it.name)
    }

    static func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    static func dragOperation(_ info: NSDraggingInfo, items: TransferItems, to side: Endpoint, target: String) -> NSDragOperation {
        let drag = info.draggingSequenceNumber
        return dragOperation(mask: info.draggingSourceOperationMask, items: items, to: side, target: target) { DragVolumes.same($0, $1, drag: drag) }
    }

    /// Finder rules: same volume (or the same server) moves, anywhere else copies; ⌥ forces copy, ⌘ forces move.
    /// Nothing for a drop into the folder the items already live in, or onto one of them.
    static func dragOperation(mask: NSDragOperation, items: TransferItems, to side: Endpoint, target: String,
                              sameVolume: (String, String) -> Bool = FileJob.sameVolume) -> NSDragOperation {
        if items.paths.isEmpty { return [] }
        let sameSide = items.from.isSameFilesystem(as: side)
        if sameSide && items.paths.contains(where: { ($0 as NSString).deletingLastPathComponent == target || $0 == target }) { return [] }
        if mask == .copy { return .copy }
        if mask == .generic || mask == .move { return .move }
        guard sameSide else { return .copy }
        guard side == .local else { return .move }
        return sameVolume(items.paths[0], target) ? .move : .copy
    }
}

/// Whether a drag's items and the folder under the mouse share a volume, asked off the main thread: a drop is
/// validated on every mouse move, and a share that stopped answering hung the drag. Not known yet: no (a copy, as
/// Finder does across volumes) until the answer comes; the next move uses it. Forgotten when another drag starts.
@MainActor enum DragVolumes {
    private static var drag = -1, known: [String: Bool] = [:], asked: Set<String> = []

    static func same(_ path: String, _ dir: String, drag d: Int) -> Bool {
        if d != drag { (drag, known, asked) = (d, [:], []) }
        let key = path + "\0" + dir
        if let k = known[key] { return k }
        if asked.insert(key).inserted {
            Task {
                let k = await Blocking.run(.userInitiated) { FileJob.sameVolume(path, dir) }
                if drag == d { known[key] = k }
            }
        }
        return false
    }
}

extension PanelViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }
    /// The panel may still ask for an index of the listing it last counted (a re-list or unmarking meanwhile).
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = quickLookURLs
        guard urls.indices.contains(index) else { return nil }
        let url = urls[index]
        if let copy = lookCopies[url] { return TextCopies.Item(copy, title: url.lastPathComponent) }
        if index >= TextCopies.most, !TextFormat.quickLookShows(url.lastPathComponent), lookAsked.insert(url).inserted {
            let gen = lookGen, ticket = lookTicket
            Task { [weak self] in   // past the first ones: its copy now it's shown
                let copy = await Blocking.run(.userInitiated) { TextCopies.one(url, ticket: ticket) }
                guard let self, gen == lookGen, let copy, let quickLook else { return }
                lookCopies[url] = copy
                quickLook.refreshCurrentPreviewItem()
            }
        }
        return url as NSURL
    }
    /// Arrow keys in the Quick Look window move our cursor, so previews follow along.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode != 53 else { return false }   // Esc closes Quick Look
        table.keyDown(with: event)
        return true
    }
}

/// ⌘Y's `.txt` copies of texts Quick Look would show as an icon, in one owner-only folder per launch: the ones before
/// go with each new preview, all of them at quit (a crash's, with the launch sweep: `TempCopies.prefixes`).
enum TextCopies {
    static let dir = NSTemporaryDirectory() + "dfm-text-" + UUID().uuidString
    /// Copied together, at once; the marked past them are copied as Quick Look comes to each.
    static let most = 50

    private static let lock = NSLock()   // one at a time: each removes the copies before it
    @MainActor private static var issued = 0
    nonisolated(unsafe) private static var latest = 0   // under `lock`
    nonisolated(unsafe) private static var folder: String?   // the latest `make`'s, under `lock`

    /// The order `make`s were asked for in, taken on the main thread: one asked for earlier, running later, mustn't
    /// remove a newer one's copies.
    @MainActor static func ticket() -> Int { issued += 1; return issued }

    /// The copies of those of `urls` that read as text; each in a folder of its own (two marked search hits may share
    /// a name), the ones before removed. With an older `ticket` than one already made: nothing.
    static func make(_ urls: [URL], ticket: Int? = nil) -> [URL: URL] {
        lock.lock()
        defer { lock.unlock() }
        if let ticket {
            guard ticket > latest else { return [:] }
            latest = ticket
        }
        let fm = FileManager.default, mine = (dir as NSString).appendingPathComponent(UUID().uuidString)
        mkdir(dir, 0o700)
        for old in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] { TempCopies.remove((dir as NSString).appendingPathComponent(old)) }
        guard mkdir(mine, 0o700) == 0 else { return [:] }
        folder = mine
        var made: [URL: URL] = [:]
        for url in urls.prefix(most) { made[url] = copy(url, in: mine) }
        return made
    }

    /// One more copy, with the latest `make`'s (`ticket`): nil once a newer one came, or for what isn't text.
    static func one(_ url: URL, ticket: Int) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard ticket == latest, let folder else { return nil }
        return copy(url, in: folder)
    }

    /// In a folder of its own there: two marked search hits may share a name.
    private static func copy(_ url: URL, in folder: String) -> URL? {
        guard FileInfo.notRegular(url.path) == nil, let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        let head = (try? h.read(upToCount: TextFormat.previewSniff)) ?? Data()
        try? h.close()
        let own = (folder as NSString).appendingPathComponent(UUID().uuidString)
        guard TextFormat.previewsAsText(url.lastPathComponent, head: head), mkdir(own, 0o700) == 0,
              let copy = try? TextFormat.textCopy(of: url.path, in: own) else { return nil }
        return URL(fileURLWithPath: copy)
    }

    /// A copy shown under its file's own name.
    final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(_ url: URL, title: String) { (previewItemURL, previewItemTitle) = (url, title) }
    }
}

/// Files handed over by drag, ⌘C / ⌘V or F5: which side they're on, and their paths there.
struct TransferItems: Equatable {
    var from: Endpoint
    var paths: [String]

    /// A server's item on a pasteboard: the panel's own type (Finder has no file to take, so it refuses the drop).
    static let remoteType = NSPasteboard.PasteboardType("com.dfilemanager.sftp-item")
    private struct RemoteItem: Codable { let target: SFTPTarget; let path: String }

    static func pasteboardItem(_ target: SFTPTarget, _ path: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(RemoteItem(target: target, path: path)) { item.setData(data, forType: remoteType) }
        return item
    }

    var pasteboardWriters: [NSPasteboardWriting] {
        switch from {
        case .local: paths.map { URL(fileURLWithPath: $0) as NSURL }
        case .sftp(let t): paths.map { Self.pasteboardItem(t, $0) }
        }
    }

    init(from: Endpoint, paths: [String]) {
        self.from = from
        self.paths = paths
    }

    /// A server's items (all from the first one's server), else local files; nil when it holds neither.
    init?(_ pb: NSPasteboard) {
        let remote = (pb.pasteboardItems ?? []).compactMap { $0.data(forType: Self.remoteType).flatMap { try? JSONDecoder().decode(RemoteItem.self, from: $0) } }
        if let first = remote.first {
            self.init(from: .sftp(first.target), paths: remote.filter { $0.target.isSameServer(as: first.target) }.map(\.path))
            return
        }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return nil }
        self.init(from: .local, paths: urls.map(\.path))
    }
}

/// Which folder a path or an open fd is on (dev/ino).
struct FolderID: Equatable, Sendable {
    let dev: dev_t, ino: ino_t
    init?(path: String) {
        var s = stat()
        guard stat(path, &s) == 0 else { return nil }
        (dev, ino) = (s.st_dev, s.st_ino)
    }
    init?(fd: Int32) {
        var s = stat()
        guard fstat(fd, &s) == 0 else { return nil }
        (dev, ino) = (s.st_dev, s.st_ino)
    }
}

/// Runs its closure the first time only (a continuation resumed by whichever comes first).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        guard lock.withLock({ () -> Bool in defer { done = true }; return !done }) else { return }
        body()
    }
}

/// A panel's cell, its text in `color` (or `text`, attributed): on the cursor of the focused panel in the System theme
/// (the system's selection, in the accent) text and mark go white, as the system's labels do — a marked name in the
/// accent would vanish there. A name's cell has the mark's ✓ in a gutter of its own.
final class PanelCell: NSTableCellView {
    let check = NSImageView(image: Symbol.check.image())
    var color: NSColor = .labelColor { didSet { paint() } }
    var text: NSAttributedString? { didSet { paint() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        check.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        check.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { paint() } }

    private func paint() {
        let c = backgroundStyle == .emphasized ? NSColor.alternateSelectedControlTextColor : color
        check.contentTintColor = c
        guard let text else { textField?.textColor = c; return }
        let s = NSMutableAttributedString(attributedString: text)
        if backgroundStyle == .emphasized { s.addAttribute(.foregroundColor, value: c, range: NSRange(location: 0, length: s.length)) }
        textField?.attributedStringValue = s
    }
}

/// The Modified column: "Today 13:33", "Yesterday 09:10", this year's "Oct 14 13:32", older "2024-03-01" — one
/// format whatever the Mac's locale, in English as the rest of the app, 24-hour. `iso` (defaults `isoDates`): always
/// "2024-03-01 13:33". The day's and year's bounds are taken once, when it's made, not per row.
struct DateColumn: Equatable {
    let iso: Bool
    private let today: Date, tomorrow: Date, yesterday: Date, year: Date, nextYear: Date

    init(_ now: Date = Date(), iso: Bool = UserDefaults.standard.bool(forKey: "isoDates"), calendar: Calendar = .current) {
        self.iso = iso
        today = calendar.startOfDay(for: now)
        tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        year = calendar.date(from: calendar.dateComponents([.year], from: now))!
        nextYear = calendar.date(byAdding: .year, value: 1, to: year)!
    }

    func text(_ d: Date) -> String {
        if iso { return Self.isoFull.string(from: d) }
        if d >= today && d < tomorrow { return "Today " + Self.time.string(from: d) }
        if d >= yesterday && d < today { return "Yesterday " + Self.time.string(from: d) }
        if d >= year && d < nextYear { return Self.monthDay.string(from: d) }
        return Self.isoDay.string(from: d)
    }

    private static func fmt(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    nonisolated(unsafe) private static let isoFull = fmt("yyyy-MM-dd HH:mm"), isoDay = fmt("yyyy-MM-dd"),
                                            time = fmt("HH:mm"), monthDay = fmt("MMM d HH:mm")
}

/// A row of views over a 2 pt line in `line`'s color along its foot (the active panel's path bar), drawn each time so
/// it follows light and dark.
class LinedStack: NSStackView {
    var line: NSColor? { didSet { if line != oldValue { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        line?.setFill()
        if line != nil { NSRect(x: bounds.minX, y: isFlipped ? bounds.maxY - 2 : bounds.minY, width: bounds.width, height: 2).fill() }
    }
}

/// A panel's middle when it has nothing to list (`PanelViewController.Empty`): a symbol (or a spinner), what's so, a
/// line on it, and what comes next as keys — the same bar as anywhere, a click doing what the key does.
final class EmptyStateView: NSStackView {
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    let keys = KeyBarView(chips: false)
    private var keysWidth: NSLayoutConstraint!
    var onKey: ((String) -> Void)?
    private(set) var shown: PanelViewController.Empty?   // tests

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        wantsLayer = true
        layer?.cornerRadius = 6
        icon.symbolConfiguration = .init(pointSize: 26, weight: .light)
        spinner.style = .spinning
        spinner.controlSize = .small
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 11.5)
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 320
        keys.onRun = { [unowned self] in onKey?($0) }
        keysWidth = keys.widthAnchor.constraint(equalToConstant: 0)
        keysWidth.priority = .defaultHigh   // a narrow panel: "+N" for the rest
        keysWidth.isActive = true
        keys.heightAnchor.constraint(equalToConstant: 30).isActive = true
        [icon, spinner, title, detail, keys].forEach(addArrangedSubview)
        setCustomSpacing(10, after: detail)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// In the middle of the list, never wider than it.
    func place(over list: NSView, in host: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: list.centerXAnchor), centerYAnchor.constraint(equalTo: list.centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor, constant: -16),
        ])
    }

    func show(_ e: PanelViewController.Empty?, theme: Theme) {
        shown = e
        isHidden = e == nil
        guard let e else { return spinner.stopAnimation(nil) }
        layer?.backgroundColor = theme.background?.cgColor   // a theme's grid lines don't cross the words
        icon.image = e.symbol?.image(e.title)
        icon.contentTintColor = theme.hidden
        icon.isHidden = e.symbol == nil
        spinner.isHidden = e.symbol != nil
        e.symbol == nil ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        title.stringValue = e.title.bidiVisible
        title.textColor = theme.text
        detail.stringValue = e.detail
        detail.textColor = theme.hidden
        detail.isHidden = e.detail.isEmpty
        keys.isHidden = e.keys.isEmpty
        if keys.list != e.keys { keys.list = e.keys }
        keysWidth.constant = keys.naturalWidth
    }
}

extension ByteCountFormatter {
    /// "310 B", "4 KB", "1.2 GB": one short unit everywhere (the formatter has no short one for bytes).
    static func short(_ bytes: Int64) -> String { bytes < 1000 ? "\(bytes) B" : string(fromByteCount: bytes, countStyle: .file) }
}
