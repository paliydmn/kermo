import AppKit
import DFMCore

/// A finished operation, as the Activity list (⌥⌘J) keeps it — across launches too, in activity.json: what it did and
/// what it left out, enough to show that and retry it. Never the `FileJob` itself: that holds all its lists.
struct ActivityEntry: Codable, Equatable {
    enum Result: String, Codable { case done, errors, cancelled }
    var id = UUID()
    let title: String
    let kind: FileJob.Kind
    let from: Endpoint, to: Endpoint
    let sources: [String], sourceCount: Int   // the first `limit` picked
    let destDir: String?, targetName: String?
    let started: Date, finished: Date
    let files: Int, bytes: Int64
    let result: Result
    let errorCount: Int
    let failed: [FileJob.Failure]   // the first `failedLimit`: what Retry Failed takes
    let notes: [String]   // the other lines ("kept", "mode and date not kept" …), the first `failedLimit`
    var seen: Bool
    var retried = false

    /// Entries kept, and lines in each: 100 × 50 is about 1 MB at worst, a few KB as a rule.
    static let limit = 100, failedLimit = 50

    init(_ job: FileJob, title: String, started: Date, finished: Date = Date()) {
        let p = job.progress
        self.title = title
        kind = job.kind
        from = job.from
        to = job.to
        sources = Array(job.sources.prefix(Self.limit))
        sourceCount = job.sources.count
        destDir = job.destDir
        targetName = job.targetName
        self.started = started
        self.finished = finished
        files = p.doneFiles
        bytes = p.doneBytes
        errorCount = p.errors.count
        failed = Array(p.failed.prefix(Self.failedLimit))
        let lines = Set(p.failed.map { "\($0.path): \($0.message)" })
        notes = Array(p.errors.filter { !lines.contains($0) }.prefix(Self.failedLimit))
        result = p.state == .cancelled ? .cancelled : p.errors.isEmpty ? .done : .errors
        seen = result != .errors
    }

    /// A copy or move into a folder (Synchronize's pairs are run again from its window).
    var canRetry: Bool { (kind == .copy || kind == .move) && destDir != nil && failed.contains { $0.dst != nil } }

    /// "Copied 300 files · 3.1 GB · took 1:42 · 12:04"; "2 failed · 46 files done · 12:04".
    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let time = DateFormatter.localizedString(from: finished, dateStyle: Calendar.current.isDateInToday(finished) ? .none : .short, timeStyle: .short)
        let n = "\(files) file\(files == 1 ? "" : "s")"
        switch result {
        case .done:
            let did = switch kind {
            case .copy: "Copied \(n) · \(size)"
            case .move: "Moved \(n) · \(size)"
            case .trash: "Moved \(sourceCount) item\(sourceCount == 1 ? "" : "s") to the Trash"
            case .delete: "Deleted \(sourceCount) item\(sourceCount == 1 ? "" : "s")"
            }
            return "\(did) · took \(Activity.duration(finished.timeIntervalSince(started))) · \(time)"
        case .errors: return "\(errorCount) error\(errorCount == 1 ? "" : "s") · \(n) done · \(time)\(retried ? " · retried" : "")"
        case .cancelled: return "Cancelled · \(n) done · \(time)"
        }
    }

    /// What Retry Failed queues: one job per destination folder, of the failed items' sources; a single item keeps
    /// the name it was to have (⇧F5 "as"). A failure with no destination (a trash, a delete) isn't one.
    static func retryGroups(_ failures: [FileJob.Failure]) -> [(dir: String, sources: [String], name: String?)] {
        let groups = Dictionary(grouping: failures.filter { $0.dst != nil }) { ($0.dst! as NSString).deletingLastPathComponent }
        return groups.sorted { $0.key < $1.key }.map { dir, items in
            (dir, items.map(\.src), items.count == 1 ? (items[0].dst! as NSString).lastPathComponent : nil)
        }
    }

    /// Each failure as a line, then the notes: what Copy Errors puts on the clipboard.
    var errorLines: String { (failed.map { "\($0.path): \($0.message)" } + notes).joined(separator: "\n") }
}

/// The finished operations, newest first. `dir` nil: kept for this run only (tests); otherwise written off the main
/// thread on each change.
@MainActor final class ActivityHistory {
    static let file = "activity.json"
    private let dir: String?
    private(set) lazy var entries: [ActivityEntry] = dir.map { Config.loadEach(Self.file, as: ActivityEntry.self, in: $0).value } ?? []

    init(dir: String?) { self.dir = dir }

    var unseen: Int { entries.filter { !$0.seen }.count }

    func add(_ e: ActivityEntry) {
        entries.insert(e, at: 0)
        if entries.count > ActivityEntry.limit { entries.removeLast(entries.count - ActivityEntry.limit) }
        save()
    }
    func change(_ id: UUID, _ f: (inout ActivityEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        f(&entries[i])
        save()
    }
    /// nil: all of them.
    func remove(_ id: UUID?) {
        entries.removeAll { id == nil || $0.id == id }
        save()
    }
    func markSeen() {
        guard unseen > 0 else { return }
        for i in entries.indices { entries[i].seen = true }
        save()
    }
    private func save() { if let dir { Config.save(Self.file, entries, in: dir) } }
}

/// Drawing and text shared by the rows above the key bar and the Activity popover.
@MainActor enum Activity {
    nonisolated static func duration(_ s: Double) -> String {
        let s = max(0, Int(s.rounded())), h = s / 3600, m = s % 3600 / 60
        return h > 0 ? "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s % 60))" : "\(m):\(String(format: "%02d", s % 60))"
    }

    /// The toolbar button's picture: a ring of all the work done so far (nil: nothing running), how many jobs when
    /// there's more than one, and a red dot for a finished one with errors not looked at yet.
    static func image(fraction: Double?, count: Int, alert: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            let c = NSPoint(x: 9, y: 9), r: CGFloat = 7
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.8
            (fraction == nil ? NSColor.secondaryLabelColor : NSColor.secondaryLabelColor.withAlphaComponent(0.45)).setStroke()
            track.stroke()
            if let fraction, fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(fraction, 1)), clockwise: true)
                arc.lineWidth = 2.2
                arc.lineCapStyle = .round
                NSColor.controlAccentColor.setStroke()
                arc.stroke()
            }
            let arrow = NSBezierPath()   // ↓
            arrow.move(to: NSPoint(x: 9, y: 12.5)); arrow.line(to: NSPoint(x: 9, y: 5.5))
            arrow.move(to: NSPoint(x: 6.3, y: 8.2)); arrow.line(to: NSPoint(x: 9, y: 5.5)); arrow.line(to: NSPoint(x: 11.7, y: 8.2))
            arrow.lineWidth = 1.4
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            NSColor.labelColor.setStroke()
            arrow.stroke()
            if count > 1 {
                let s = "\(count)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: NSColor.white]
                let w = max(10, s.size(withAttributes: attrs).width + 4)
                let badge = NSRect(x: 22 - w, y: 18 - 10, width: w, height: 10)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
                s.draw(at: NSPoint(x: badge.midX - s.size(withAttributes: attrs).width / 2, y: badge.minY), withAttributes: attrs)
            } else if alert {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 15, y: 11, width: 6, height: 6)).fill()
            }
            return true
        }
        img.accessibilityDescription = "Activity"
        return img
    }

    /// A running job's files: the last few done, the one going now, what failed, and the picked items not begun.
    /// `sizesAt`: a right tab there puts the sizes in a column (the popover); nil: after the name (the rows).
    static func files(_ job: FileJob, sizesAt: CGFloat? = nil) -> NSAttributedString {
        let p = job.progress
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        if let sizesAt { para.tabStops = [NSTextTab(textAlignment: .right, location: sizesAt)] }
        para.lineBreakMode = .byTruncatingMiddle
        func line(_ mark: String, _ color: NSColor, _ text: String, _ textColor: NSColor = .labelColor, size: String? = nil) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: mark + "  ", attributes: [.foregroundColor: color, .font: font, .paragraphStyle: para]))
            out.append(NSAttributedString(string: text.bidiVisible, attributes: [.foregroundColor: textColor, .font: font, .paragraphStyle: para]))
            if let size {
                out.append(NSAttributedString(string: (sizesAt == nil ? "  " : "\t") + size,
                                              attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: sizeFont, .paragraphStyle: para]))
            }
        }
        let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        if p.doneFiles > p.recent.count { line("✓", .systemGreen, "\(p.doneFiles - p.recent.count) more done", .secondaryLabelColor) }
        for f in p.recent { line("✓", .systemGreen, (f.path as NSString).lastPathComponent, size: bytes(f.size)) }
        // between two files (paused, say) `current` is still the one just done
        if !p.current.isEmpty, p.current != p.recent.last.map({ ($0.path as NSString).lastPathComponent }) {
            let pct = p.currentSize > 0 ? "\(Int(Double(min(p.currentDone, p.currentSize)) / Double(p.currentSize) * 100))% of \(bytes(p.currentSize))" : nil
            line("▸", .controlAccentColor, p.current, size: pct)
        }
        for f in p.failed.suffix(5) { line("✕", .systemRed, "\((f.path as NSString).lastPathComponent) — \(f.message)") }
        if p.failed.count > 5 { line("✕", .systemRed, "\(p.failed.count - 5) more failed", .secondaryLabelColor) }
        let left = Array(job.sources.dropFirst(job.kind == .trash || job.kind == .delete ? p.doneFiles : p.topsBegun))   // those count items
        if p.state != .queued, !left.isEmpty {
            for f in left.prefix(3) { line("○", .tertiaryLabelColor, (f as NSString).lastPathComponent, .secondaryLabelColor) }
            if left.count > 3 { line("○", .tertiaryLabelColor, "\(left.count - 3) more to go", .secondaryLabelColor) }
        }
        if out.length == 0 { line("○", .tertiaryLabelColor, p.state == .queued ? "Waits for its turn" : "Looking at the items…", .secondaryLabelColor) }
        return out
    }

    static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// What a card calls the job: the item's name, or "4 items".
    static func name(_ sources: [String], count: Int) -> String {
        count == 1 ? (sources.first.map { ($0 as NSString).lastPathComponent } ?? "") : "\(count) items"
    }

    /// "web-01:/var/log → ~/Downloads", a production server's name in its color. nil: no one folder to name (a
    /// Synchronize's pairs).
    /// `short`: a long folder as its last two names ("…/gui19/dst"); the tooltip has it whole.
    static func route(_ kind: FileJob.Kind, from: Endpoint, to: Endpoint, sources: [String], destDir: String?, short: Bool = true) -> NSAttributedString? {
        guard let first = sources.first else { return nil }
        let out = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        func place(_ e: Endpoint, _ whole: String) {
            var path = e == .local ? (whole as NSString).abbreviatingWithTildeInPath : whole
            let names = path.split(separator: "/")
            if short, path.count > 28, names.count > 2 { path = "…/" + names.suffix(2).joined(separator: "/") }
            if case .sftp(let t) = e {
                let prod = SavedServer.isProd(t)
                out.append(NSAttributedString(string: t.host.bidiVisible, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: prod ? .semibold : .regular),
                                                                                      .foregroundColor: prod ? SavedServer.color : NSColor.labelColor]))
                out.append(NSAttributedString(string: ":" + path.bidiVisible, attributes: plain))
            } else {
                out.append(NSAttributedString(string: path.bidiVisible, attributes: plain))
            }
        }
        let parent = (first as NSString).deletingLastPathComponent
        switch kind {
        case .trash:
            place(from, parent)
            out.append(NSAttributedString(string: " → Trash", attributes: plain))
        case .delete:
            out.append(NSAttributedString(string: "from ", attributes: plain))
            place(from, parent)
        case .copy, .move:
            guard let destDir else { return nil }
            place(from, parent)
            out.append(NSAttributedString(string: " → ", attributes: plain))
            place(to, destDir)
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// The kind of job, in a tinted square: ↓ from a server, ↑ to one, a copy, a move, the Trash; a finished one by its
    /// result instead.
    static func badge(_ kind: FileJob.Kind, from: Endpoint, to: Endpoint, result: ActivityEntry.Result? = nil) -> NSView {
        let (symbol, tint): (String, NSColor) = switch result {
        case .done?: ("checkmark", .systemGreen)
        case .errors?: ("exclamationmark.triangle.fill", .systemRed)
        case .cancelled?: ("xmark", .secondaryLabelColor)
        case nil:
            switch kind {
            case .trash, .delete: ("trash", .controlAccentColor)
            case .copy, .move:
                from != .local && to == .local ? ("arrow.down", .controlAccentColor)
                    : from == .local && to != .local ? ("arrow.up", .controlAccentColor)
                    : kind == .move ? ("arrow.right", .controlAccentColor) : ("doc.on.doc", .controlAccentColor)
            }
        }
        let box = Tile(fill: tint.withAlphaComponent(0.15), radius: 6)
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: result?.rawValue ?? kind.rawValue)!)
        image.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        image.contentTintColor = tint
        image.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(image)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 26), box.heightAnchor.constraint(equalToConstant: 26),
            image.centerXAnchor.constraint(equalTo: box.centerXAnchor), image.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    static let font = NSFont.systemFont(ofSize: 11)

    static func label(_ s: String = "", size: CGFloat = 11, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s.bidiVisible)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingMiddle
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    static func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.bezelStyle = .push
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return b
    }

    static func icon(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, action: action)
        b.bezelStyle = .accessoryBarAction
        b.isBordered = false
        b.refusesFirstResponder = true
        b.toolTip = tip
        return b
    }
}

/// A button that runs a closure.
final class ClosureButton: NSButton {
    private var run: () -> Void = {}
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        configure(action)
    }
    convenience init(image: NSImage, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.image = image
        imagePosition = .imageOnly
        configure(action)
    }
    private func configure(_ action: @escaping () -> Void) {
        run = action
        target = self
        self.action = #selector(fire)
    }
    @objc private func fire() { run() }
}

/// ⌥⌘J, the toolbar's Activity button: running, queued and finished operations. A card opens to its files; a finished
/// one with errors shows them with Retry and Show.
@MainActor final class ActivityPopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private unowned let ops: OpsController
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    /// Jobs and entries opened to their files.
    private var open = Set<ObjectIdentifier>(), openEntries = Set<UUID>()
    private var shape = ""
    private var cards: [(row: JobRow, bar: NSProgressIndicator, detail: NSTextField, files: NSTextField?)] = []
    /// A click on the toolbar button closes a transient popover on mouse-down, before the button's action: that
    /// click meant "close", not "open again".
    private(set) var closedAt = Date.distantPast
    static let width: CGFloat = 460
    /// Where a card's text starts (after ▸ and the badge), and the right tab of the files' sizes.
    private static let indent: CGFloat = 52, sizesAt = width - 52 - 40

    init(ops: OpsController) {
        self.ops = ops
        super.init()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let vc = NSViewController()
        vc.view = scroll
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    /// Before it's shown: built afresh, `entry` opened to its files.
    func prepare(entry: UUID?) {
        if let entry { openEntries.insert(entry) }
        shape = ""
        refresh()
    }

    func popoverDidClose(_ notification: Notification) {
        cards = []
        closedAt = Date()
    }

    /// The list again when something came, went or opened; otherwise each running job's bar and lines.
    func refresh() {
        let rows = ops.jobRows, entries = ops.history.entries
        let now = rows.map { "\(ObjectIdentifier($0.job).hashValue)\($0.job.progress.state)\($0.job.isPaused)\(open.contains(ObjectIdentifier($0.job)))" }
            + entries.map { "\($0.id)\($0.retried)\(openEntries.contains($0.id))" }
        let key = now.joined(separator: "|")
        if key != shape {
            shape = key
            rebuild(rows, entries)
        }
        for c in cards {   // what the rows' own tick worked out: updating them here again would skew their speed
            c.bar.isIndeterminate = c.row.bar.isIndeterminate
            if c.bar.isIndeterminate { c.bar.startAnimation(nil) }
            c.bar.doubleValue = c.row.bar.doubleValue
            c.detail.stringValue = c.row.detailText
            c.files?.attributedStringValue = Activity.files(c.row.job, sizesAt: Self.sizesAt)
        }
        let height = min(560, max(36, stack.fittingSize.height))
        if abs(popover.contentSize.height - height) > 1 { popover.contentSize = NSSize(width: Self.width, height: height) }
    }

    private func rebuild(_ rows: [JobRow], _ entries: [ActivityEntry]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards = []
        let title = Activity.label("Activity", size: 13, weight: .bold)
        let keys = Activity.label("⌥⌘J", size: 11, color: .secondaryLabelColor)
        let head = NSStackView(views: [title, keys, NSView()])
        head.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 2, right: 4)
        add(head)
        let running = rows.filter { $0.job.progress.state != .queued }, queued = rows.filter { $0.job.progress.state == .queued }
        if rows.isEmpty && entries.isEmpty {
            let l = Activity.label("No operations yet. Copies, moves and deletes show up here.", size: 12, color: .secondaryLabelColor)
            add(NSStackView(views: [l]))
            return
        }
        for (name, list) in [("RUNNING", running), ("QUEUED", queued)] where !list.isEmpty {
            add(section(name))
            list.forEach { add(card($0)) }
        }
        guard !entries.isEmpty else { return }
        let clear = Activity.button("Clear") { [unowned self] in ops.history.remove(nil); ops.changed() }
        clear.isBordered = false
        clear.contentTintColor = .controlAccentColor
        add(section("FINISHED", clear))
        entries.forEach { add(card($0)) }
    }

    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
    }

    private func section(_ title: String, _ accessory: NSView? = nil) -> NSView {
        let l = Activity.label(title, size: 10.5, weight: .semibold, color: .secondaryLabelColor)
        let row = NSStackView(views: [l, NSView()] + (accessory.map { [$0] } ?? []))
        row.edgeInsets = NSEdgeInsets(top: 8, left: 4, bottom: 0, right: 4)
        return row
    }

    private func disclosure(_ isOpen: Bool, _ toggle: @escaping () -> Void) -> NSButton {
        let b = Activity.icon(isOpen ? "chevron.down" : "chevron.right", isOpen ? "Hide the files" : "Show the files", toggle)
        b.symbolConfiguration = .init(pointSize: 10, weight: .bold)
        b.contentTintColor = .labelColor
        b.widthAnchor.constraint(equalToConstant: 14).isActive = true
        return b
    }

    /// ▸ · badge · name over the route · buttons; a click anywhere on it but a button opens it.
    private func header(_ isOpen: Bool, toggle: @escaping () -> Void, badge: NSView, name: String, route: NSAttributedString?,
                        whole: String?, buttons: [NSView]) -> NSView {
        let title = Activity.label(name, size: 13, weight: .semibold)
        var lines: [NSView] = [title]
        if let route {
            let r = NSTextField(labelWithAttributedString: route)
            r.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            r.toolTip = whole
            lines.append(r)
        }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let controls = NSStackView(views: buttons)
        controls.spacing = 2
        let h = ClickStack(views: [disclosure(isOpen, toggle), badge, text, NSView(), controls], onClick: toggle)
        h.spacing = 8
        return h
    }

    private func card(_ row: JobRow) -> NSView {
        let job = row.job, id = ObjectIdentifier(job), isOpen = open.contains(id)
        let toggle = { [unowned self] in
            if open.contains(id) { open.remove(id) } else { open.insert(id) }
            refresh()
        }
        let route = Activity.route(job.kind, from: job.from, to: job.to, sources: job.sources, destDir: job.destDir)
        let whole = Activity.route(job.kind, from: job.from, to: job.to, sources: job.sources, destDir: job.destDir, short: false)?.string
        let head = header(isOpen, toggle: toggle, badge: Activity.badge(job.kind, from: job.from, to: job.to),
                          name: route == nil ? row.title : Activity.name(job.sources, count: job.sources.count), route: route, whole: whole,
                          buttons: row.controls())
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.maxValue = 1
        bar.controlSize = .small
        let detail = Activity.label(color: .secondaryLabelColor)
        detail.lineBreakMode = .byTruncatingTail
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        var views: [NSView] = [head, bar, detail]
        var files: NSTextField?
        if isOpen {
            let f = NSTextField(wrappingLabelWithString: "")
            f.isSelectable = true
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            files = f
            views.append(f)
        }
        cards.append((row, bar, detail, files))
        return box(views, indent: [bar, detail] + (files.map { [$0] } ?? []), highlighted: isOpen)
    }

    private func card(_ e: ActivityEntry) -> NSView {
        let isOpen = openEntries.contains(e.id)
        let toggle = { [unowned self] in
            if openEntries.contains(e.id) { openEntries.remove(e.id) } else { openEntries.insert(e.id) }
            refresh()
        }
        let remove = Activity.icon("xmark", "Remove from the list") { [unowned self] in ops.history.remove(e.id); ops.changed() }
        remove.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        let route = Activity.route(e.kind, from: e.from, to: e.to, sources: e.sources, destDir: e.destDir)
        let whole = Activity.route(e.kind, from: e.from, to: e.to, sources: e.sources, destDir: e.destDir, short: false)?.string
        let head = header(isOpen, toggle: toggle, badge: Activity.badge(e.kind, from: e.from, to: e.to, result: e.result),
                          name: route == nil ? e.title : Activity.name(e.sources, count: e.sourceCount), route: route, whole: whole, buttons: [remove])
        let detail = Activity.label(e.summary, color: e.result == .errors ? .systemRed : .secondaryLabelColor)
        var views: [NSView] = [head, detail], indent: [NSView] = [detail]
        func add(_ v: NSView) { views.append(v); indent.append(v) }
        if isOpen || e.result == .errors {
            for f in e.failed.prefix(isOpen ? ActivityEntry.failedLimit : 3) { add(failedLine(e, f)) }
            let shown = isOpen ? e.failed.count : min(3, e.failed.count)
            if isOpen {
                for n in e.notes { add(Activity.label("•  " + n, color: .secondaryLabelColor)) }
                let done = NSMutableAttributedString()
                for s in e.sources.prefix(5) {
                    if done.length > 0 { done.append(NSAttributedString(string: "\n")) }
                    done.append(NSAttributedString(string: "✓  ", attributes: [.foregroundColor: NSColor.systemGreen, .font: Activity.font]))
                    done.append(NSAttributedString(string: (s as NSString).lastPathComponent.bidiVisible, attributes: [.font: Activity.font, .foregroundColor: NSColor.labelColor]))
                }
                if e.sourceCount > 5 { done.append(NSAttributedString(string: "\n✓  \(e.sourceCount - 5) more", attributes: [.font: Activity.font, .foregroundColor: NSColor.secondaryLabelColor])) }
                if e.result != .errors, done.length > 0 { add(NSTextField(labelWithAttributedString: done)) }
            }
            let more = max(0, e.errorCount - shown - (isOpen ? e.notes.count : 0))
            if more > 0 { add(Activity.label("\(more) more — open to see\(isOpen ? " (only the first \(ActivityEntry.failedLimit) are kept)" : "")", color: .secondaryLabelColor)) }
            var acts: [NSView] = []
            if e.canRetry && !e.retried {
                let r = Activity.button("Retry Failed (\(e.failed.filter { $0.dst != nil }.count))") { [unowned self] in ops.retry(e, nil) }
                r.bezelColor = .controlAccentColor
                acts.append(r)
            }
            if e.destDir != nil { acts.append(Activity.button("Show in Panel") { [unowned self] in ops.showPlace(e, nil) }) }
            if e.errorCount > 0 {
                acts.append(Activity.button("Copy Errors") { [unowned self] in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(e.errorLines, forType: .string)
                    popover.close()
                })
            }
            if !acts.isEmpty {
                let line = NSStackView(views: acts)
                line.spacing = 6
                add(line)
            }
        }
        return box(views, indent: indent, highlighted: isOpen)
    }

    private func failedLine(_ e: ActivityEntry, _ f: FileJob.Failure) -> NSView {
        let mark = Activity.label("✕", color: .systemRed)
        let name = Activity.label(((f.dst ?? f.path) as NSString).lastPathComponent)
        let why = Activity.label(f.message, size: 10.5, color: .systemRed)
        why.lineBreakMode = .byTruncatingTail
        why.toolTip = "\(f.path): \(f.message)".bidiVisible
        let text = NSStackView(views: [name, why])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        var buttons: [NSView] = []
        if e.canRetry && f.dst != nil { buttons.append(Activity.button("Retry") { [unowned self] in ops.retry(e, [f]) }) }
        buttons.append(Activity.button("Show") { [unowned self] in ops.showPlace(e, f) })
        let row = NSStackView(views: [mark, text, NSView()] + buttons)
        row.alignment = .top
        row.spacing = 6
        return row
    }

    /// A card: its lines under the header, from where the name starts; a soft background while it's open.
    private func box(_ views: [NSView], indent: [NSView], highlighted: Bool) -> NSView {
        let v = NSStackView(views: views)
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 4
        v.edgeInsets = NSEdgeInsets(top: 7, left: 6, bottom: 7, right: 6)
        for sub in views {
            let inset: CGFloat = indent.contains(where: { $0 === sub }) ? Self.indent - 6 : 0
            sub.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6 + inset).isActive = true
            sub.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6).isActive = true
        }
        let card = Tile(fill: highlighted ? Self.openFill : nil, radius: 8)
        v.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: card.topAnchor), v.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: card.leadingAnchor), v.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    private static let openFill = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.045)
    }
}

/// A row that takes a click on itself (not on a button in it) as `onClick`: a card's header opens the card.
private final class ClickStack: NSStackView {
    private var onClick: () -> Void = {}
    convenience init(views: [NSView], onClick: @escaping () -> Void) {
        self.init(views: views)
        self.onClick = onClick
    }
    override func mouseDown(with event: NSEvent) { onClick() }
}

/// A rounded, filled background (`fill` nil: none) behind what's in it, sized by their constraints.
final class Tile: NSView {
    private let fill: NSColor?, radius: CGFloat
    init(fill: NSColor?, radius: CGFloat) {
        self.fill = fill
        self.radius = radius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
