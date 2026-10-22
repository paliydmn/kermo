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
            (fraction == nil ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
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
    static func files(_ job: FileJob) -> NSAttributedString {
        let p = job.progress
        let out = NSMutableAttributedString()
        func line(_ mark: String, _ color: NSColor, _ text: String, _ textColor: NSColor = .labelColor) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: mark + "  ", attributes: [.foregroundColor: color, .font: font]))
            out.append(NSAttributedString(string: text.bidiVisible, attributes: [.foregroundColor: textColor, .font: font]))
        }
        if p.doneFiles > p.recent.count { line("✓", .systemGreen, "\(p.doneFiles - p.recent.count) more done", .secondaryLabelColor) }
        for f in p.recent { line("✓", .systemGreen, (f as NSString).lastPathComponent) }
        // between two files (paused, say) `current` is still the one just done
        if !p.current.isEmpty, p.current != p.recent.last.map({ ($0 as NSString).lastPathComponent }) { line("▸", .controlAccentColor, p.current) }
        for f in p.failed.suffix(5) { line("✕", .systemRed, "\((f.path as NSString).lastPathComponent) — \(f.message)") }
        if p.failed.count > 5 { line("✕", .systemRed, "\(p.failed.count - 5) more failed", .secondaryLabelColor) }
        let left = job.sources.dropFirst(job.kind == .trash || job.kind == .delete ? p.doneFiles : p.topsBegun)   // those count items
        if p.state != .queued, !left.isEmpty {
            let names = left.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            line("○", .tertiaryLabelColor, "\(left.count) more to go: \(names)\(left.count > 3 ? ", …" : "")", .secondaryLabelColor)
        }
        if out.length == 0 { line("○", .tertiaryLabelColor, p.state == .queued ? "Waits for its turn" : "Looking at the items…", .secondaryLabelColor) }
        return out
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

/// ⌥⌘J, the toolbar's Activity button: running, queued and finished operations. A row opens to its files; a finished
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

    init(ops: OpsController) {
        self.ops = ops
        super.init()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
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
            c.files?.attributedStringValue = Activity.files(c.row.job)
        }
        let height = min(560, max(36, stack.fittingSize.height))
        if abs(popover.contentSize.height - height) > 1 { popover.contentSize = NSSize(width: 460, height: height) }
    }

    private func rebuild(_ rows: [JobRow], _ entries: [ActivityEntry]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards = []
        let running = rows.filter { $0.job.progress.state != .queued }, queued = rows.filter { $0.job.progress.state == .queued }
        if rows.isEmpty && entries.isEmpty {
            let l = Activity.label("No operations yet. Copies, moves and deletes show up here.", size: 12, color: .secondaryLabelColor)
            add(l)
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
        row.edgeInsets = NSEdgeInsets(top: 8, left: 2, bottom: 0, right: 2)
        return row
    }

    private func disclosure(_ isOpen: Bool, _ toggle: @escaping () -> Void) -> NSButton {
        let b = Activity.icon(isOpen ? "chevron.down" : "chevron.right", isOpen ? "Hide the files" : "Show the files", toggle)
        b.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        return b
    }

    private func card(_ row: JobRow) -> NSView {
        let id = ObjectIdentifier(row.job), isOpen = open.contains(id)
        let toggle = disclosure(isOpen) { [unowned self] in
            if open.contains(id) { open.remove(id) } else { open.insert(id) }
            refresh()
        }
        let title = Activity.label(row.title, size: 12, weight: .semibold)
        let controls = NSStackView(views: row.controls())
        controls.spacing = 2
        let head = NSStackView(views: [toggle, title, NSView(), controls])
        head.spacing = 6
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
        return box(views, indent: [bar, detail] + (files.map { [$0] } ?? []))
    }

    private func card(_ e: ActivityEntry) -> NSView {
        let isOpen = openEntries.contains(e.id)
        let toggle = disclosure(isOpen) { [unowned self] in
            if openEntries.contains(e.id) { openEntries.remove(e.id) } else { openEntries.insert(e.id) }
            refresh()
        }
        let (symbol, color): (String, NSColor) = switch e.result {
        case .done: ("checkmark.circle.fill", .systemGreen)
        case .errors: ("exclamationmark.triangle.fill", .systemRed)
        case .cancelled: ("xmark.circle", .secondaryLabelColor)
        }
        let mark = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: e.result.rawValue)!)
        mark.contentTintColor = color
        let title = Activity.label(e.title, size: 12, weight: .semibold)
        let remove = Activity.icon("xmark", "Remove from the list") { [unowned self] in ops.history.remove(e.id); ops.changed() }
        remove.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        let head = NSStackView(views: [toggle, mark, title, NSView(), remove])
        head.spacing = 6
        let detail = Activity.label(e.summary, color: e.result == .errors ? .systemRed : .secondaryLabelColor)
        var views: [NSView] = [head, detail], indent: [NSView] = [detail]
        if isOpen || e.result == .errors {
            for f in e.failed.prefix(isOpen ? ActivityEntry.failedLimit : 3) {
                let line = failedLine(e, f)
                views.append(line)
                indent.append(line)
            }
            let shown = isOpen ? e.failed.count : min(3, e.failed.count)
            var more = e.errorCount - shown - (isOpen ? e.notes.count : 0)
            if isOpen {
                for n in e.notes {
                    let l = Activity.label("•  " + n, color: .secondaryLabelColor)
                    l.lineBreakMode = .byTruncatingMiddle
                    views.append(l)
                    indent.append(l)
                }
                if e.result != .errors {
                    let what = Activity.label("\(e.sourceCount) item\(e.sourceCount == 1 ? "" : "s"): "
                        + e.sources.prefix(5).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                        + (e.sourceCount > 5 ? ", …" : ""), color: .secondaryLabelColor)
                    views.append(what)
                    indent.append(what)
                }
            }
            more = max(0, more)
            if more > 0 {
                let l = Activity.label("\(more) more — open to see\(isOpen ? " (only the first \(ActivityEntry.failedLimit) are kept)" : "")", color: .secondaryLabelColor)
                views.append(l)
                indent.append(l)
            }
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
                views.append(line)
                indent.append(line)
            }
        }
        return box(views, indent: indent)
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

    private func box(_ views: [NSView], indent: [NSView]) -> NSView {
        let v = NSStackView(views: views)
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 3
        v.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        for sub in views {
            let inset: CGFloat = indent.contains(where: { $0 === sub }) ? 22 : 0
            sub.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4 + inset).isActive = true
            sub.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4).isActive = true
        }
        return v
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
