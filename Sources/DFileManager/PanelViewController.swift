import AppKit
import DFMCore
import Quartz
import UniformTypeIdentifiers

@MainActor
final class PanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private(set) var path: String
    var showHidden: Bool { didSet { applyView(select: currentName) } }
    /// Permissions, Owner and Group columns (View ▸ Show Permissions & Owner); in a narrow panel they stay longer than Size and Modified.
    var showPerms = false { didSet { if isViewLoaded { fitColumns() } } }
    /// Only names git reports as changed (or folders with changes inside). Per panel, kept across folders.
    var gitOnly = false { didSet { applyView(select: currentName) } }
    var inGitRepo: Bool { git != nil }
    var isActive = false { didSet { styleHeader() } }
    /// With 3+ panels: this is where F5/F6 from the active panel go.
    var isTarget = false { didSet { styleHeader() } }

    /// The active panel: framed, its path bar filled, both in the theme's accent.
    private func styleHeader() {
        pathField.backgroundColor = isActive ? theme.accent : .clear
        pathField.textColor = isActive ? theme.onAccent : isTarget ? theme.accent : theme.hidden
        viewIfLoaded?.layer?.borderWidth = isActive ? Self.frameWidth : 0
        viewIfLoaded?.layer?.borderColor = theme.accent.cgColor
    }
    private static let frameWidth: CGFloat = 2
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

    private let tabBar = NSStackView()   // one button per tab, each with a close ×
    private let pathField = NSTextField(string: "")
    private let filterField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let errorIcon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")!)
    /// The status line says what failed: red behind a warning sign, in an inactive panel too. The next status clears it.
    private(set) var statusError = false {
        didSet {
            statusLabel.textColor = statusError ? .systemRed : theme.hidden
            errorIcon.isHidden = !statusError
        }
    }
    private let spinner = NSProgressIndicator()
    /// Shown in the status line with a spinner while a listing, connection or download is in flight.
    var busyMessage: String? { didSet { if busyMessage != oldValue { updateStatus() } } }

    private var all: [FileItem] = [] { didSet { sortedAll = nil } }   // as listed
    /// `all` in the current sort order, cached: filtering and toggling hidden files reuse it instead of
    /// re-sorting (1M names take ~1.6 s to sort, 80 ms to filter).
    private var sortedAll: [FileItem]?
    private var sortedBy: (key: SortKey, ascending: Bool)?
    private var loadedGen = 0
    private var lastLoadSeconds = 0.0
    private var rows: [FileItem] = []    // filtered + sorted; ".." is not stored here
    private var marked = Set<String>()
    private var filter: Mask?
    private(set) var dirSizes: [String: Int64] = [:]
    private var sizeGen = 0
    /// Server folders waiting to be counted, and the walk counting them (one at a time, over one connection).
    private var sizeQueue: [String] = []
    private var sizeWalk: CancelFlag?
    /// Where each symlink of the local folder points, and the errno following it gave (0: it resolves).
    private var links: [String: (target: String, error: Int32)] = [:]
    private var totalSize: Int64 = 0
    private var freeSpace = ""
    /// `DirSync.mtimeTolerance` of the folder, read with the listing: off the main thread, where a hung mount can't freeze the UI.
    private(set) var mtimeTolerance: Double = 1
    private var sortKey = SortKey.name
    private var ascending = true
    private var suppressSortCallback = false
    private var loadGen = 0 { didSet { remoteFlag?.cancel(); remoteFlag = nil; moves += 1 } }   // a superseded server listing stops its ssh too
    /// `loadGen`, but a re-list of the same place (`reload`) doesn't count: ↩ or ⌘L that looked at the disk off the
    /// main thread is dropped if the user went elsewhere meanwhile, not because the folder changed.
    private var moves = 0
    /// The server listing in flight; ⎋ cancels it.
    private var remoteFlag: CancelFlag?
    /// The server calls `busy` shows, the latest last; ⎋ cancels them all.
    private var busyOps: [(flag: CancelFlag, message: String)] = []
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
    private var previewFor: PreviewKey?   // the cursor's file last asked for: on its way, here, too big or failed (asked again once the cursor comes back)
    private var previewFlag: CancelFlag?
    struct PreviewKey: Equatable { let path: String, size: Int64, mtime: Double, link: Bool }
    private(set) var searchTitle: String?   // non-nil: showing search results (names are paths relative to `path`)
    private var searchFlag: CancelFlag?
    private var searchWhat = ""
    /// The server folder ⌘L ⇥ last listed, while the path is typed.
    private var completions: (dir: String, items: [FileItem])?
    private var searching = false
    /// Browsing inside an archive (read-only). `path` stays the folder that contains the archive file.
    private(set) var archive: (index: ArchiveIndex, inner: String)?
    /// Browsing an SFTP server. `path` stays the local folder the panel returns to.
    private(set) var remote: (target: SFTPTarget, dir: String)? {
        didSet {
            guard oldValue?.target != remote?.target || oldValue?.dir != remote?.dir else { return }
            stopPreview()
            onSessionsChange?()
        }
    }
    /// A server being connected to (first listing still running), for the sidebar.
    private(set) var connecting: SFTPTarget? { didSet { if connecting != oldValue { onSessionsChange?() } } }
    var onSessionsChange: (() -> Void)?
    var onRemoteResult: ((SFTPTarget, String?) -> Void)?   // a listing came back: nil, or the error
    private var git: GitStatus?
    private var theme = Theme.current

    /// `path` is the local folder; with `remote` set the tab is on a server and returns to `path` when it leaves.
    struct Tab {
        let id = UUID()   // the sidebar finds an SFTP session by it
        var path: String
        var cursor: String? = nil
        var back: [String] = []
        var forward: [String] = []
        var remote: (target: SFTPTarget, dir: String)? = nil
        var marked = Set<String>()
        var filter = ""
    }
    private var tabs: [Tab]
    private(set) var tabIndex: Int

    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let fileIcon = NSWorkspace.shared.icon(for: .data)
    private static let linkIcon = NSWorkspace.shared.icon(for: .symbolicLink)
    private static let sizeFmt = ByteCountFormatter()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    init(tabs paths: [String], index: Int, showHidden: Bool) {
        tabs = (paths.isEmpty ? [NSHomeDirectory()] : paths).map { Tab(path: $0) }
        tabIndex = min(max(index, 0), tabs.count - 1)
        path = tabs[tabIndex].path
        self.showHidden = showHidden
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Row mapping & targets

    private var hasParent: Bool { remote != nil || archive != nil || searchTitle != nil || path != "/" }   // ".." leaves results/archives
    func item(at row: Int) -> FileItem? {     // nil == ".."
        hasParent ? (row == 0 ? nil : rows[row - 1]) : rows[row]
    }
    private func row(named name: String) -> Int? {
        rows.firstIndex { $0.name == name }.map { $0 + (hasParent ? 1 : 0) }
    }
    private func url(of item: FileItem) -> URL {
        URL(fileURLWithPath: (path as NSString).appendingPathComponent(item.name), isDirectory: item.kind == .dir)
    }
    private var currentName: String? {
        let r = table.selectedRow
        return r >= 0 && r < table.numberOfRows ? item(at: r)?.name : nil
    }

    /// The item under the cursor (nil on "..", and inside archives, where nothing is a real file).
    /// The folder shown, when it's a plain one of this Mac's (not a server's, an archive or search results): only
    /// then is `path` what's on screen.
    var plainFolder: String? { remote == nil && archive == nil && searchTitle == nil ? path : nil }

    /// What ⌘I shows: the cursor's file or the folder; inside an archive, the archive itself; nothing on a server.
    var infoURL: URL? {
        guard remote == nil else { return nil }
        if let a = archive { return URL(fileURLWithPath: a.index.file) }
        return cursorURL ?? URL(fileURLWithPath: path)
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
    var targetURLs: [URL] {
        guard archive == nil, remote == nil else { return [] }
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
            f.drawsBackground = true
            f.focusRingType = .none
            f.cell?.usesSingleLineMode = true
            f.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            f.delegate = self
        }
        pathField.lineBreakMode = .byTruncatingHead
        filterField.placeholderString = "filter: text, *.glob or re:regex · ↩ keep · ⎋ clear"
        filterField.isHidden = true
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        let header = Self.column([tabBar, pathField])
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        errorIcon.contentTintColor = .systemRed
        errorIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        errorIcon.isHidden = true
        let footer = Self.column([filterField, NSStackView(views: [spinner, errorIcon, statusLabel])])
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        v.wantsLayer = true   // the active panel's frame
        for sub in [header, scroll, footer] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
            NSLayoutConstraint.activate([   // clear of the frame
                sub.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: Self.frameWidth),
                sub.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -Self.frameWidth),
            ])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 3),
            footer.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4),
        ])
        view = v
        isActive = false
        updateTabBar()
        applyTheme()
    }

    func applyTheme() {
        theme = Theme.current
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
        statusLabel.textColor = statusError ? .systemRed : theme.hidden
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
        navigate(to: path, history: .none)
        statTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view.window?.occlusionState.contains(.visible) == true,
                      !self.view.isHiddenOrHasHiddenAncestor else { return }
                self.refreshStats()
            }
        }
    }

    // MARK: - Loading

    enum History { case push, back, forward, none }

    /// A tab's own marks and filter, put back once its listing is on screen (not before: they'd act on the old rows).
    typealias TabMarks = (marked: Set<String>, filter: String)

    /// `keep`: a tab switch brings back that tab's marks and filter instead of starting clean.
    func navigate(to newPath: String, select: String? = nil, history: History = .push, keep: TabMarks? = nil) {
        loadGen += 1
        connecting = nil   // a pending server listing is dropped too
        let gen = loadGen
        let started = Date()
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
                    let items = try DirLister.list(newPath)
                    let order = Self.savedSort(for: newPath)
                    return (items, Self.freeSpace(newPath), items.sortedForPanel(by: order.key, ascending: order.ascending), order,
                            DirSync.mtimeTolerance([newPath]), FolderID(path: newPath))
                }
            }
            guard let self, gen == loadGen else { return }
            loadedGen = gen
            busyMessage = nil
            lastLoadSeconds = Date().timeIntervalSince(started)
            switch result {
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
                // A re-list keeps what's known of its links to folders (resolved again below): rows don't jump to the
                // files and back on every reload.
                let linkDirs = changed ? [] : Set(all.filter(\.linkDir).map(\.name))
                all = linkDirs.isEmpty ? items : items.map { var it = $0; it.linkDir = it.kind == .link && linkDirs.contains(it.name); return it }
                (sortedAll, sortedBy) = (sorted, order)
                freeSpace = free
                mtimeTolerance = tolerance
                var select = select
                if changed {
                    archive = nil
                    remote = nil
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
                    if view.window?.firstResponder !== pathField.currentEditor() {
                        pathField.stringValue = (newPath as NSString).abbreviatingWithTildeInPath
                    }
                    loadSort(for: newPath)
                    watch()
                    updateTabBar()
                    onPathChange?()
                } else {
                    select = select ?? currentName   // where the cursor is now, not when the reload started
                    marked.formIntersection(items.map(\.name))
                    if folder != watchedID { watch() }
                }
                if let keep { restore(keep, in: items) }
                applyView(select: select, newFolder: changed)
                refreshGit()
                resolveLinks(items, in: newPath, gen: gen)
            case .failure(let error):
                NSSound.beep()
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
                } else if all.isEmpty && newPath != NSHomeDirectory() {
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
        sizeWalk?.cancel()
        stopPreview()
    }

    /// Search results and archives stay as they are: re-listing `path` would replace them with the folder.
    func reload(select: String? = nil) {
        guard archive == nil, searchTitle == nil else { return }
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
        return free.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
    }

    /// `newFolder`: without `name` the cursor starts on the first row instead of keeping its row number.
    private func applyView(select name: String?, newFolder: Bool = false) {
        let oldRow = table.selectedRow, oldName = currentName
        let cursorShown = NSLocationInRange(oldRow, table.rows(in: table.visibleRect))
        if sortedAll == nil || sortedBy?.key != sortKey || sortedBy?.ascending != ascending {
            // ponytail: a header click on a huge folder still sorts on the main thread; move off-main if it bites.
            sortedAll = all.sortedForPanel(by: sortKey, ascending: ascending)
            sortedBy = (sortKey, ascending)
        }
        let changed = gitOnly ? git?.marks : nil
        // Results already went through the search's (or git's) own idea of hidden; ⌘⇧. would drop .gitignore.
        rows = sortedAll!.filter { (showHidden || searchTitle != nil || !$0.isHidden) && (filter?.matches($0.name) ?? true) && (changed?[$0.name] != nil || changed == nil) }
        totalSize = bytes(of: rows)
        guard isViewLoaded else { return }
        table.reloadData()   // drops the selection: Quick Look is told once the cursor is back
        let r = name.flatMap(row(named:)) ?? (newFolder ? 0 : max(0, oldRow))
        // Scrolled away from the cursor (to watch a log grow): a re-list that leaves it on the same row doesn't scroll back.
        moveCursor(to: r, scroll: newFolder || cursorShown || name != oldName || r != oldRow)
        reloadQuickLook()
        updateStatus()
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

    private func updateStatus() {
        let busy = busyMessage != nil || searching
        spinner.isHidden = !busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        statusError = false
        if let busyMessage { return statusLabel.stringValue = busyMessage }
        var s = Self.countText(rows.count, "items", totalSize) + " · \(freeSpace) free"
        if let r = remote { s = "🌐 sftp · \(r.target.host) · " + Self.countText(rows.count, "items", 0) }   // marks: below, as anywhere
        if let g = git {
            s += " · ⎇ \(g.branch)" + (g.ahead > 0 ? " ↑\(g.ahead)" : "") + (g.behind > 0 ? " ↓\(g.behind)" : "")
        }
        if let a = archive { s = "📦 \(a.index.format) · read-only · F5 extracts · " + s }
        if searchTitle != nil { s = "🔍 \(searchWhat): " + (searching ? "searching… \(all.count) found" : "\(all.count) found · ⌫ back") + " · " + s }
        if filter != nil { s = "filtered: \(rows.count) of \(all.count) · " + s }
        if gitOnly && git != nil { s = "git changes: \(rows.count) of \(all.count) · " + s }
        if !marked.isEmpty { s = Self.countText(marked.count, "marked", bytes(of: rows.filter { marked.contains($0.name) })) + " · " + s }
        statusLabel.stringValue = s
    }

    /// "7 items, 1.2 MB" — or "7 items" with nothing to add up (folders count once measured, on Space): "Zero KB" said nothing.
    static func countText(_ n: Int, _ noun: String, _ bytes: Int64) -> String {
        "\(n) \(n == 1 && noun == "items" ? "item" : noun)" + (bytes > 0 ? ", " + sizeFmt.string(fromByteCount: bytes) : "")
    }
    private func bytes(of items: [FileItem]) -> Int64 { items.reduce(0) { $0 + ($1.kind == .dir ? dirSizes[$1.name] ?? 0 : $1.size) } }

    /// The Size column: a folder's measured bytes or <DIR>; a special file's type, which has no size to show.
    static func sizeText(_ it: FileItem, measured: Int64?) -> String {
        switch it.kind {
        case .dir: measured.map { sizeFmt.string(fromByteCount: $0) } ?? "<DIR>"
        case .link where it.linkDir: "<DIR>"
        case .other:
            switch mode_t(truncatingIfNeeded: it.mode) & S_IFMT {
            case S_IFIFO: "<FIFO>"
            case S_IFSOCK: "<SOCKET>"
            case S_IFCHR, S_IFBLK: "<DEVICE>"
            default: "<SPECIAL>"
            }
        default: sizeFmt.string(fromByteCount: it.size)
        }
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
    }

    func busy<T: Sendable>(_ message: String, flag: CancelFlag = CancelFlag(), _ work: @escaping @Sendable (CancelFlag) throws -> T) async -> Result<T, Error> {
        let mine = message + " ⎋ cancels"
        busyOps.append((flag, mine))
        busyMessage = mine
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
        busyOps.removeAll { $0.flag === flag }
        if busyMessage == mine { busyMessage = busyOps.last?.message }   // one still running says so again
        return flag.isCancelled ? .failure(CancellationError()) : r
    }

    /// Briefly shows a message in the status line; `error`: one saying what failed.
    func flash(_ message: String, error: Bool = false) {
        statusLabel.stringValue = message
        statusError = error
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
    }

    // MARK: - Git (column + branch in the status line, only inside a work tree — here or on the server)

    private func refreshGit() {
        guard gitApplies else { return setGit(nil) }
        gitRuns.request(key: remote.map { "\($0.target.host):\($0.target.port ?? 0):\($0.dir)" } ?? path)
    }

    private var gitApplies: Bool { archive == nil && searchTitle == nil }

    /// One `git status` per panel at a time: reloads in a busy repo would otherwise pile them up.
    private lazy var gitRuns = SingleFlight { [weak self] in await self?.loadGit() }

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
        if gitOnly { return applyView(select: currentName) }
        if col >= 0 { table.reloadData(forRowIndexes: IndexSet(0..<table.numberOfRows), columnIndexes: [col]) }
        updateStatus()
    }

    /// "M" red = changed, green = staged, "?" grey = untracked, "U" purple = conflict, "•" = changes inside.
    /// The letter, its color, and what they say in words (VoiceOver reads neither).
    static func gitCell(_ code: String) -> (String, NSColor, String) {   // internal for tests
        if code == "•" { return ("•", .systemOrange, "changes inside") }
        if code == "??" { return ("?", .secondaryLabelColor, "untracked") }
        if code == "!!" { return ("!", .tertiaryLabelColor, "ignored") }
        let x = code.first ?? " ", y = code.last ?? " "
        if x == "U" || y == "U" || code == "AA" || code == "DD" { return ("U", .systemPurple, "conflict") }
        let letter = x != " " ? x : y
        let word = ["M": "modified", "A": "added", "D": "deleted", "R": "renamed", "C": "copied", "T": "type changed"][String(letter)] ?? "changed"
        return x != " " ? (String(x), .systemGreen, word + ", staged") : (String(y), .systemRed, word)
    }

    // MARK: - Sorting (remembered per folder)

    private nonisolated static func savedSort(for p: String) -> (key: SortKey, ascending: Bool) {
        let parts = (UserDefaults.standard.dictionary(forKey: "folderSort")?[p] as? String)?.split(separator: ":")
        return (parts.flatMap { SortKey(rawValue: String($0[0])) } ?? .name, parts.map { $0.count < 2 || $0[1] == "1" } ?? true)
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
        let full = (path as NSString).appendingPathComponent(it.name)
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
    static var confirmLeaving: @MainActor (SFTPTarget, _ back: String, NSWindow?) async -> Bool = { target, back, window in
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Disconnect SFTP from \(target.host)?".bidiVisible
        a.informativeText = "This tab goes back to \((back as NSString).abbreviatingWithTildeInPath).".bidiVisible
        a.addButton(withTitle: "Disconnect").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        guard let window else { return a.runModal() == .alertFirstButtonReturn }
        return await withCheckedContinuation { cont in a.beginSheetModal(for: window) { cont.resume(returning: $0 == .alertFirstButtonReturn) } }
    }

    func goUp() {
        if let r = remote {
            if searchTitle != nil { return loadRemote(r.target, dir: r.dir, select: nil) }   // leave search results
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
        loadGen += 1
        let gen = loadGen
        let flag = CancelFlag()
        remoteFlag = flag
        let opening = remote?.target != target   // not a folder of the server already open here
        if opening {
            busyMessage = "Connecting to \(target.host)… ⎋ cancels"
            connecting = target
        }
        Task { [weak self] in
            if opening, ServerLock.needsUnlock(target), await !ServerLock.authorize(target) {
                guard let self, gen == loadGen else { return }
                remoteFlag = nil
                connecting = nil
                busyMessage = nil
                flash("🔒 \(target.host) stays locked")
                return
            }
            let result = await Blocking.run(.userInitiated) { () -> Result<(String, [FileItem], [String: (String, String)], [String: (target: String, error: Int32)]), Error> in
                Result {
                    let d = try dir ?? SFTP.home(target, env: SSHAskpass.env, cancel: flag)
                    var owners: [String: (String, String)] = [:], links: [String: (target: String, error: Int32)] = [:]
                    let items = try SFTP.list(target, d, env: SSHAskpass.env, cancel: flag, owners: { owners[$0] = ($1, $2) },
                                              links: { links[$0] = ($1, $2) })
                    return (d, items, owners, links)
                }
            }
            guard let self, gen == loadGen else { return }
            remoteFlag = nil
            connecting = nil
            busyMessage = nil
            switch result {
            case .success(let (d, items, owners, found)):
                onRemoteResult?(target, nil)
                remoteOwners = owners
                links = found
                enterRemote(target, d, items, select: select, keep: keep)
            case .failure(let error as SFTPError) where error.connection:
                onRemoteResult?(target, error.message)
                if let window = view.window {
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

    private func enterRemote(_ target: SFTPTarget, _ dir: String, _ items: [FileItem], select: String?, keep: TabMarks? = nil) {
        let sameDir = remote?.target == target && remote?.dir == dir
        let select = select ?? (sameDir ? currentName : nil)   // a reload keeps the cursor where it is now
        watcher?.cancel()
        watcher = nil
        archive = nil
        if searchTitle != nil { searchFlag?.cancel(); searchTitle = nil; searching = false }
        remote = (target, dir)
        all = items
        if sameDir {
            marked.formIntersection(items.map(\.name))
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
            busyMessage = nil
            switch result {
            case .success(let index):
                loadGen += 1   // that re-list, still on its way, mustn't land over the archive
                watcher?.cancel()
                watcher = nil
                path = (file as NSString).deletingLastPathComponent
                archive = (index, "")
                setGit(nil)
                showArchive(select: nil)
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
    func beginSearch(_ what: String, in place: String? = nil) -> CancelFlag {
        searchFlag?.cancel()
        let flag = CancelFlag()
        searchFlag = flag
        loadGen += 1   // drop any listing still in flight
        busyMessage = nil
        watcher?.cancel()
        watcher = nil
        searchTitle = place.map { "\(what) in \($0)" } ?? what
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
        var sorted = sortedAll
        all += items
        sorted?.append(contentsOf: items)
        sortedAll = sorted
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
        guard remote == nil, archive == nil else { return flash("Git Changes works in a local folder") }
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

    // MARK: - Quick View (⌃Q): this panel previews the other panel's cursor item

    func setQuickView(_ on: Bool) {
        if on, quickView == nil, let qv = QLPreviewView(frame: scroll.frame, style: .normal) {
            qv.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(qv)
            NSLayoutConstraint.activate([
                qv.topAnchor.constraint(equalTo: scroll.topAnchor),
                qv.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
                qv.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
                qv.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            ])
            scroll.isHidden = true
            quickView = qv
        } else if !on, let qv = quickView {
            qv.close()
            qv.removeFromSuperview()
            quickView = nil
            scroll.isHidden = false
        }
    }

    func preview(_ url: URL?) { quickView?.previewItem = url as NSURL? }

    // MARK: - Tabs (each keeps its own path, cursor and history)

    var tabPaths: [String] {
        var t = tabs
        t[tabIndex].path = path
        return t.map(\.path)
    }

    func newTab() {
        saveTab()
        tabs.insert(Tab(path: path, cursor: currentName, remote: remote), at: tabIndex + 1)
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
        let wasRemote = tabs[i].remote != nil
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
        tabs[tabIndex].cursor = currentName
        tabs[tabIndex].back = backStack
        tabs[tabIndex].forward = forwardStack
        tabs[tabIndex].remote = remote
        // Marks in an archive or in search results name entries there, not the files of `path`: they aren't kept.
        let real = archive == nil && searchTitle == nil
        tabs[tabIndex].marked = real ? marked : []
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
        } else {
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

    var remoteTabs: [RemoteTab] {
        tabs.enumerated().compactMap { i, t in
            (i == tabIndex ? remote : t.remote).map { RemoteTab(id: t.id, target: $0.target, dir: $0.dir, isCurrent: i == tabIndex) }
        }
    }

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
            if remote != nil { navigate(to: path, history: .none) }
        } else {
            tabs[i].remote = nil
            updateTabBar()
            onPathChange?()
            onSessionsChange?()
        }
    }

    private func updateTabBar() {
        tabBar.isHidden = tabs.count < 2
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, t) in tabs.enumerated() {
            if let r = i == tabIndex ? remote : t.remote {
                let name = r.dir == "/" ? "/" : (r.dir as NSString).lastPathComponent.bidiVisible
                tabBar.addArrangedSubview(Self.tabButton("SFTP · \(r.target.host) · \(name)", tip: "\(r.target.host):\(r.dir)", index: i, current: i == tabIndex,
                                                         target: self, action: #selector(tabClicked(_:)), close: #selector(closeTabClicked(_:))))
                continue
            }
            let p = i == tabIndex ? path : t.path
            tabBar.addArrangedSubview(Self.tabButton(p == "/" ? "/" : (p as NSString).lastPathComponent.bidiVisible, tip: (p as NSString).abbreviatingWithTildeInPath, index: i,
                                                     current: i == tabIndex, target: self, action: #selector(tabClicked(_:)), close: #selector(closeTabClicked(_:))))
        }
    }

    /// A tab: `action` on click, `close` on its × (both get the button with `tag` = index). The terminal's tabs use it too.
    static func tabButton(_ title: String, tip: String, index i: Int, current: Bool, target: AnyObject, action: Selector, close: Selector) -> NSButton {
        let b = NSButton(title: "     \(title)     ", target: target, action: action)   // padding keeps the title clear of the ×
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .accessoryBarAction
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.lineBreakMode = .byTruncatingMiddle
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.refusesFirstResponder = true
        b.state = current ? .on : .off
        b.tag = i
        b.toolTip = tip
        let x = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")!
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))!, target: target, action: close)
        x.isBordered = false
        x.refusesFirstResponder = true
        x.contentTintColor = .secondaryLabelColor
        x.tag = i
        x.toolTip = "Close Tab  ⌘W"
        x.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(x)
        NSLayoutConstraint.activate([
            x.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -6),
            x.centerYAnchor.constraint(equalTo: b.centerYAnchor),
        ])
        return b
    }

    // MARK: - Marking

    func toggleMark(move: Int) {
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
        updateStatus()
    }

    /// Visible items (after hidden/filter), for cross-panel features like Compare Folders.
    var listedItems: [FileItem] { rows }
    var markedNames: Set<String> { marked }
    var headerText: String { pathField.stringValue }
    var statusText: String { statusLabel.stringValue }

    /// How many got marked: only what's shown can be (a filter, hidden files).
    @discardableResult
    func setMarks(_ names: Set<String>) -> Int { marked = names.intersection(rows.map(\.name)); refreshMarks(); return marked.count }

    func markAll() { marked = Set(rows.map(\.name)); refreshMarks() }
    func unmarkAll() { marked.removeAll(); refreshMarks() }
    func invertMarks() { marked = Set(rows.map(\.name)).subtracting(marked); refreshMarks() }

    /// "+" / "-" (MC/TC): (un)mark files — not folders — whose names match the mask.
    func mark(matching mask: Mask, _ on: Bool) {
        for it in rows where it.kind != .dir && mask.matches(it.name) {
            if on { marked.insert(it.name) } else { marked.remove(it.name) }
        }
        refreshMarks()
    }

    private func refreshMarks() {
        table.reloadData(forRowIndexes: IndexSet(0..<table.numberOfRows), columnIndexes: IndexSet(0..<table.numberOfColumns))
        reloadQuickLook()
        updateStatus()
    }

    /// ⌘-click toggles one row, ⇧-click marks the range from the cursor.
    private func markClick(_ row: Int, _ mods: NSEvent.ModifierFlags) {
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
        sizeGen += 1
        sizeQueue.removeAll()
        sizeWalk?.cancel()
        sizeWalk = nil
    }

    private func computeSizes(_ names: [String]) {
        guard archive == nil else { return }
        if remote != nil { return measureRemote(names) }
        let gen = sizeGen
        let base = path
        Task { [weak self] in
            for name in names {
                let full = (base as NSString).appendingPathComponent(name)
                // ponytail: an abandoned walk keeps running in the background until done; add cancellation if huge trees make it matter.
                let bytes = await Blocking.run(.utility) { DirLister.measure(full).bytes }
                guard let self, gen == sizeGen else { return }
                setSize(name, bytes)
            }
        }
    }

    /// On a server: one walk at a time over one connection, folders asked for meanwhile (Space down a list) next;
    /// the status line says so and ⎋ stops it, as does leaving the folder (`clearSizes`).
    private func measureRemote(_ names: [String]) {
        sizeQueue += names.filter { !sizeQueue.contains($0) }
        guard sizeWalk == nil, let r = remote else { return }   // the walk running takes them next
        let flag = CancelFlag(), gen = sizeGen, env = SSHAskpass.env
        sizeWalk = flag
        Task { [weak self] in
            while let self, sizeWalk === flag {
                let names = sizeQueue.filter { dirSizes[$0] == nil }
                sizeQueue.removeAll()
                guard !names.isEmpty else { sizeWalk = nil; return }
                let result = await busy("Counting folder sizes…", flag: flag) { [weak self] flag in
                    try SFTPClient.session(r.target, env: env, cancel: flag) { c in
                        for name in names {
                            let bytes = try c.measure((r.dir as NSString).appendingPathComponent(name), cancel: flag)
                            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.sizeGen == gen { self?.setSize(name, bytes) } } }
                        }
                    }
                }
                if case .failure(let error) = result {
                    if sizeWalk === flag { sizeWalk = nil; sizeQueue.removeAll() }
                    if !(error is CancellationError) { flash("Can't count folder sizes: \(error.localizedDescription)", error: true) }
                    return
                }
            }
        }
    }

    private func setSize(_ name: String, _ bytes: Int64) {
        dirSizes[name] = bytes
        totalSize = self.bytes(of: rows)
        if let r = row(named: name) { table.reloadData(forRowIndexes: [r], columnIndexes: [table.column(withIdentifier: .init("size"))]) }
        updateStatus()
    }

    // MARK: - Path field (⌘L) and quick filter (/)

    /// The header: "🔍 title" on search results, "📦 archive/inner", "🌐 host:/dir" on a server ("🔴 PROD host:/dir" on
    /// a production one), else the local folder. Also what ⎋ in the path field brings back.
    func showPath() {
        pathField.stringValue = if let t = searchTitle { "🔍 " + t }
            else if let a = archive { "📦 " + (a.index.file as NSString).abbreviatingWithTildeInPath + (a.inner.isEmpty ? "" : "/" + a.inner) }
            else if let r = remote { (SavedServer.isProd(r.target) ? "🔴 PROD " : "🌐 ") + "\(r.target.host):\(r.dir)" }
            else { (path as NSString).abbreviatingWithTildeInPath }
    }

    func beginPathEditing() {
        completions = nil
        onFocus?()
        view.window?.makeFirstResponder(pathField)
        pathField.stringValue = remote.map { $0.dir == "/" ? "/" : $0.dir + "/" } ?? (path as NSString).abbreviatingWithTildeInPath + (hasParent ? "/" : "")
        pathField.currentEditor()?.selectAll(nil)   // typing replaces the path; End, then a name, goes below it
    }

    func beginFilter() {
        filterField.isHidden = false
        view.window?.makeFirstResponder(filterField)
    }

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
        if apply { applyView(select: currentName) }
    }

    func controlTextDidBeginEditing(_ obj: Notification) { onFocus?() }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === filterField else { return }
        filter = filterField.stringValue.isEmpty ? nil : Mask(filter: filterField.stringValue)
        applyView(select: currentName)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === pathField {
            showPath()
        } else if filter == nil {
            filterField.isHidden = true
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if control === filterField {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)):
                if sel == #selector(NSResponder.insertNewline(_:)) { Self.rememberFilter(filterField.stringValue) }
                confirmFilter()
            case #selector(NSResponder.cancelOperation(_:)):
                clearFilter()
                view.window?.makeFirstResponder(table)
            default:
                return false
            }
            return true
        }
        switch sel {
        case #selector(NSResponder.insertNewline(_:)) where remote != nil:   // a path on the server
            let r = remote!, typed = textView.string
            let dir = ((typed.hasPrefix("/") ? typed : (r.dir as NSString).appendingPathComponent(typed)) as NSString).standardizingPath
            view.window?.makeFirstResponder(table)
            loadRemote(r.target, dir: dir, select: nil) { [weak self] in self?.flash($0.localizedDescription, error: true) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
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
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            view.window?.makeFirstResponder(table)
            return true
        case #selector(NSResponder.insertTab(_:)):
            complete(textView)
            return true
        default:
            return false
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
        Task { [weak self] in
            // Off the main thread: a share that stopped answering, a far server. A server's folder is listed once while typing.
            let items = if let cached { cached } else {
                await Blocking.run(.userInitiated) {
                    server.map { (try? SFTP.list($0.target, listed, env: SSHAskpass.env)) ?? [] } ?? (try? DirLister.list(listed)) ?? []
                }
            }
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
            let tmp = NSTemporaryDirectory() + "dfm-sftp-" + UUID().uuidString   // a leftover goes with the launch sweep
            mkdir(tmp, 0o700)
            let local = URL(fileURLWithPath: tmp).appendingPathComponent(name)   // named as there: Quick Look goes by the extension
            let result = await Blocking.run(.userInitiated) {
                Result {
                    try SFTPClient.session(r.target, env: env, cancel: flag) { c -> SFTPClient.Attrs? in
                        // A link's own size says nothing of what it points to: a big file, a folder.
                        if want.link, case let a = try c.stat(want.path), a.kind != .file || a.size > limit { return nil }
                        return try c.download(want.path, to: local.path)
                    }
                }
            }
            guard let self, !flag.isCancelled, case .success(let attrs?) = result else {
                TempCopies.remove(tmp)
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
        }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            quickLook = nil
        }
    }

    // MARK: - Clipboard (Edit ▸ Copy / Paste act on files when the panel has focus)

    @objc func copy(_ sender: Any?) {
        guard let items = transferItems else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items.pasteboardWriters)
    }

    @objc func paste(_ sender: Any?) {
        guard archive == nil else { return flash("Archives are read-only here") }
        guard let items = TransferItems(NSPasteboard.general) else { return NSSound.beep() }
        onTransfer?(items, endpoint, currentDir, false)
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = table.clickedRow
        guard r >= 0, let it = item(at: r) else { return }
        onFocus?()   // the menu's commands act on the active panel: make it this one
        // Like Finder: a click outside the marked set acts on the clicked item alone, never on marks elsewhere.
        if !marked.contains(it.name) {
            if !marked.isEmpty { unmarkAll() }
            moveCursor(to: r)
        }
        func add(_ title: String, _ id: String) {
            let mi = menu.addItem(withTitle: title, action: #selector(contextCommand(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = id
        }
        add("Open", "open")
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.submenu = openWithMenu(for: url(of: it))
        menu.addItem(openWith)
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
        add("Rename…", "file.rename")
        add("Copy To…", "file.copy")
        add("Move To…", "file.move")
        add("Move to Trash", "file.trash")
    }

    private func openWithMenu(for url: URL) -> NSMenu {
        let m = NSMenu()
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url) {
            let mi = m.addItem(withTitle: FileManager.default.displayName(atPath: app.path), action: #selector(openWith(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            mi.image = icon
        }
        return m
    }

    @objc private func contextCommand(_ sender: NSMenuItem) { onCommand?(sender.representedObject as! String) }

    @objc private func openWith(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(targetURLs, withApplicationAt: sender.representedObject as! URL, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count + (hasParent ? 1 : 0) }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column else { return nil }
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView
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
            default: Self.fileIcon
            }
            tf.font = theme.mono ? .monospacedSystemFont(ofSize: 12, weight: isMarked ? .bold : .regular)
                : isMarked ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
            cell.toolTip = link.map { Self.linkNote($0.target, $0.error) }
            tf.setAccessibilityLabel(isMarked ? "marked" : nil)   // a mark is a color otherwise
        case "git":
            let mark = it.flatMap { git?.marks[$0.name] }.map(Self.gitCell)
            tf.stringValue = mark?.0 ?? ""
            tf.alignment = .center
            tf.textColor = mark?.1 ?? .labelColor
            tf.setAccessibilityLabel(mark?.2)
            return cell
        case "size":
            tf.stringValue = it.map { Self.sizeText($0, measured: dirSizes[$0.name]) } ?? ""
        case "mode":
            tf.stringValue = it.flatMap { archive == nil ? Perms.string($0.mode) : nil } ?? ""
        case "owner", "group":
            let owner = column.identifier.rawValue == "owner", id = it.map { owner ? $0.uid : $0.gid } ?? FileItem.unknown
            tf.stringValue = remote != nil ? it.flatMap { remoteOwners[$0.name] }.map { owner ? $0.0 : $0.1 } ?? ""
                : id == FileItem.unknown ? "" : Self.idName(id, user: owner)
        default:
            tf.stringValue = it.map { Self.dateFmt.string(from: Date(timeIntervalSince1970: $0.mtime)) } ?? ""
        }
        tf.textColor = isMarked ? theme.marked : (link?.error ?? 0) != 0 ? .systemRed : it?.isHidden == true ? theme.hidden
            : it == nil || it?.kind == .dir || it?.linkDir == true ? theme.dir : it!.kind == .file && it!.mode & 0o111 != 0 ? theme.exec : theme.text
        if column.identifier.rawValue == "name", let it, it.label != 0 || link != nil {   // Finder tag color, a link's target
            let base: [NSAttributedString.Key: Any] = [.font: tf.font!, .foregroundColor: tf.textColor!]
            let s = NSMutableAttributedString(string: it.displayName, attributes: base)
            if let link {   // dimmed, and only if it fits beside the name (26 pt: icon and margins)
                let note = NSAttributedString(string: "  " + Self.linkNote(link.target, link.error), attributes: [.font: tf.font!, .foregroundColor: theme.hidden])
                if s.size().width + note.size().width <= column.width - 26 { s.append(note) }
            }
            if it.label != 0 { s.append(NSAttributedString(string: " ●", attributes: [.foregroundColor: NSWorkspace.shared.fileLabelColors[Int(it.label)]])) }
            tf.attributedStringValue = s
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
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
            c += [iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
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
        guard let c = theme.cursor else { return nil }
        let v = PanelRowView()
        v.cursor = c
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
        guard archive == nil, let items = TransferItems(info.draggingPasteboard) else { return [] }
        let target = dropTarget(row: row, op: op)
        if target == currentDir { tableView.setDropRow(-1, dropOperation: .on) }
        return Self.dragOperation(info, items: items, to: endpoint, target: target)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        let target = dropTarget(row: row, op: op)
        guard let items = TransferItems(info.draggingPasteboard) else { return false }
        let operation = Self.dragOperation(info, items: items, to: endpoint, target: target)
        guard !operation.isEmpty else { return false }
        onTransfer?(items, endpoint, target, operation == .move)
        return true
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
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
    /// Arrow keys in the Quick Look window move our cursor, so previews follow along.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode != 53 else { return false }   // Esc closes Quick Look
        table.keyDown(with: event)
        return true
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
