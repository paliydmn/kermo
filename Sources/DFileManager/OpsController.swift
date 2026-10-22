import AppKit
import DFMCore

/// Queue of file jobs with a progress row per job, shown above the F-key bar. Jobs run one at a time per lane —
/// this Mac, or a server — and lanes run side by side, so a slow upload never holds up a local copy (or the other
/// way round). Start Now runs a queued job right away, next to whatever is running.
/// Workers block on our sheets for conflicts/errors via `ask`.
/// A finished job goes to `history` (the Activity list, ⌥⌘J): a copy or move shows "✓" in its row for a moment, one
/// with errors keeps a row saying so — Show, Retry Failed — until it's dismissed. Nothing blocks the window.
@MainActor
final class OpsController {
    let view = NSStackView()
    private weak var window: NSWindow?
    private var rows: [JobRow] = []
    /// Running and queued jobs.
    var pending: Int { rows.count }
    var jobRows: [JobRow] { rows }
    let history: ActivityHistory
    /// Retry Failed (`only`: these failures; nil: all of them) and Show: what they take is the app's (locks, the
    /// production question, the panels).
    var onRetry: (ActivityEntry, [FileJob.Failure]?) -> Void = { _, _ in }
    var onShow: (_ on: Endpoint, _ dir: String, _ select: String?) -> Void = { _, _, _ in }
    /// The toolbar's Activity button.
    let toolbarItem = NSToolbarItem(itemIdentifier: OpsController.toolbarID)
    static let toolbarID = NSToolbarItem.Identifier("activity")
    private lazy var activity = ActivityPopover(ops: self)
    /// Rows of finished jobs: "✓" for a moment, errors until dismissed.
    private var results: [(id: UUID, view: NSView)] = []
    private var running: [FileJob] = []
    private var timer: Timer?
    private var buttonKey = ""
    private let onFinished: (FileJob) -> Void

    /// `historyDir`: where activity.json is (nil: this run only — tests).
    init(window: NSWindow, historyDir: String? = nil, onFinished: @escaping (FileJob) -> Void) {
        self.window = window
        self.onFinished = onFinished
        history = ActivityHistory(dir: historyDir)
        view.orientation = .vertical
        view.spacing = 4
        view.setHuggingPriority(.defaultHigh, for: .vertical)   // as tall as its rows: the panels take the rest
        view.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 2, right: 8)
        view.isHidden = true
        toolbarItem.label = "Activity"
        toolbarItem.isBordered = true
        toolbarItem.target = self
        toolbarItem.action = #selector(toolbarButton)
        updateButton()
    }

    func enqueue(_ job: FileJob, title: String) {
        let side = job.to, local = job.from == .local && job.to == .local   // not `job`: it holds these closures
        job.resolveConflict = { [weak self] c in
            Self.ask((.cancel, false)) { done in
                if let self { self.askConflict(c, on: side, done) } else { done((.cancel, false)) }
            }
        }
        job.resolveError = { [weak self] path, message in
            Self.ask((.abort, false)) { done in
                if let self { self.askError(path, message, local: local, done) } else { done((.abort, false)) }
            }
        }
        job.onFinish = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(job) } }
        }
        let row = JobRow(job: job, title: title, onCancel: { [weak self] in self?.cancel(job) },
                         onStartNow: { [weak self] in self?.start(job) })
        rows.append(row)
        view.insertArrangedSubview(row.view, at: rows.count - 1)   // above the finished ones
        row.view.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -16).isActive = true
        startNext()
        changed()
    }

    /// The server a job talks to (its source's, server to server), or this Mac.
    static func lane(_ job: FileJob) -> Endpoint { job.from != .local ? job.from : job.to }

    private func startNext() {
        var busy = Set(running.map(Self.lane))
        for row in rows where row.job.progress.state == .queued && !running.contains(where: { $0 === row.job }) {
            if busy.insert(Self.lane(row.job)).inserted { start(row.job) }
        }
    }

    private func start(_ job: FileJob) {
        guard !running.contains(where: { $0 === job }), job.progress.state == .queued else { return }
        running.append(job)
        rows.first { $0.job === job }?.started = Date()
        job.start()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func tick() {
        rows.forEach { $0.update() }
        if activity.isShown { activity.refresh() }
        updateButton()
    }

    private func cancel(_ job: FileJob) {
        job.cancel()
        if !running.contains(where: { $0 === job }) { remove(job) }   // queued, never started
        changed()
    }

    private func finished(_ job: FileJob) {
        running.removeAll { $0 === job }
        let row = rows.first { $0.job === job }
        var entry = ActivityEntry(job, title: row?.title ?? "", started: row?.started ?? Date())
        if activity.isShown { entry.seen = true }
        remove(job)
        onFinished(job)
        history.add(entry)
        showResult(entry)
        startNext()
        changed()
    }

    private func remove(_ job: FileJob) {
        job.onFinish = {}   // it held the job: every job ever run stayed in memory, its lists and errors with it
        guard let i = rows.firstIndex(where: { $0.job === job }) else { return }
        rows.remove(at: i).view.removeFromSuperview()
        if rows.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Something came, went or changed: the rows, the button, the open list.
    func changed() {
        view.isHidden = rows.isEmpty && results.isEmpty
        updateButton()
        if activity.isShown { activity.refresh() }
    }

    // MARK: - Finished rows

    private func showResult(_ e: ActivityEntry) {
        let line: NSStackView
        switch e.result {
        case .done:
            guard e.kind == .copy || e.kind == .move else { return }   // a Trash or a delete is done at once: no row
            let mark = Activity.label("✓  " + e.title, size: 12, weight: .semibold, color: .systemGreen)
            line = NSStackView(views: [mark, Activity.label(e.summary, color: .secondaryLabelColor), NSView()])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.dismiss(e.id) }
        case .errors:
            let n = e.errorCount
            let mark = Activity.label("⚠  \(e.title) — finished with \(n) error\(n == 1 ? "" : "s")", size: 12, weight: .semibold, color: .systemRed)
            var views: [NSView] = [mark, NSView(), Activity.button("Show") { [unowned self] in dismiss(e.id); showActivity(entry: e.id) }]
            if e.canRetry { views.append(Activity.button("Retry Failed") { [unowned self] in dismiss(e.id); retry(e, nil) }) }
            views.append(Activity.icon("xmark", "Dismiss") { [unowned self] in
                history.change(e.id) { $0.seen = true }
                dismiss(e.id)
            })
            line = NSStackView(views: views)
        case .cancelled: return
        }
        line.spacing = 8
        results.append((e.id, line))
        view.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -16).isActive = true
    }

    private func dismiss(_ id: UUID) {
        guard let i = results.firstIndex(where: { $0.id == id }) else { return }
        results.remove(at: i).view.removeFromSuperview()
        changed()
    }

    // MARK: - Activity

    func retry(_ e: ActivityEntry, _ only: [FileJob.Failure]?) {
        activity.popover.close()
        onRetry(e, only)
    }

    /// Where the entry put things (`f` nil: its destination), or where the item that failed is.
    func showPlace(_ e: ActivityEntry, _ f: FileJob.Failure?) {
        activity.popover.close()
        if let f {
            let p = f.dst == nil ? f.path : f.src   // a failed copy isn't at its destination: its source is
            onShow(e.from, (p as NSString).deletingLastPathComponent, (p as NSString).lastPathComponent)
        } else if let dir = e.destDir {
            onShow(e.to, dir, e.targetName ?? e.sources.first.map { ($0 as NSString).lastPathComponent })
        }
    }

    @objc private func toolbarButton() { toggleActivity() }

    /// ⌥⌘J.
    func toggleActivity() {
        if activity.isShown { return activity.popover.close() }
        if Date().timeIntervalSince(activity.closedAt) > 0.3 { showActivity(entry: nil) }   // not the button's own click closing it
    }

    /// From the toolbar button; with the toolbar hidden, from the top of the window.
    func showActivity(entry: UUID?) {
        activity.prepare(entry: entry)
        if let toolbar = window?.toolbar, toolbar.isVisible, toolbar.items.contains(where: { $0 === toolbarItem }) {
            activity.popover.show(relativeTo: toolbarItem)
        } else if let content = window?.contentView {
            activity.popover.show(relativeTo: NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 4, width: 1, height: 1),
                                  of: content, preferredEdge: .minY)
        }
        history.markSeen()
        changed()
    }

    private func updateButton() {
        var total: Int64 = 0, done: Int64 = 0
        for r in rows {
            let p = r.job.progress
            if p.totalBytes > 0 { total += p.totalBytes; done += min(p.doneBytes, p.totalBytes) }
        }
        let fraction = rows.isEmpty ? nil : total > 0 ? Double(done) / Double(total) : 0
        let unseen = history.unseen > 0
        let key = "\(fraction.map { Int($0 * 60) } ?? -1) \(rows.count) \(unseen)"
        guard key != buttonKey else { return }
        buttonKey = key
        toolbarItem.image = Activity.image(fraction: fraction, count: rows.count, alert: unseen)
        let going = rows.filter { $0.job.progress.state != .queued }.count
        toolbarItem.toolTip = "Activity  ⌥⌘J — " + (rows.isEmpty ? "nothing running" : "\(going) running, \(rows.count - going) queued")
            + (unseen ? " · finished with errors" : "")
    }

    // MARK: - Questions from the worker thread

    /// Runs `body` on the main thread and blocks the calling (worker) thread until it answers.
    private nonisolated static func ask<T: Sendable>(_ fallback: T, _ body: @escaping @MainActor (@escaping @Sendable (T) -> Void) -> Void) -> T {
        let box = Box(fallback)
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { body { box.value = $0; sem.signal() } }
        }
        sem.wait()
        return box.value
    }

    private func askConflict(_ c: FileJob.Conflict, on side: Endpoint, _ done: @escaping @Sendable ((FileJob.ConflictChoice, Bool)) -> Void) {
        guard let window else { return done((.cancel, false)) }
        let fmt = ByteCountFormatter()
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func describe(_ size: Int64, _ mtime: Double) -> String {
            "\(fmt.string(fromByteCount: size)), \(date.string(from: Date(timeIntervalSince1970: mtime)))"
        }
        let alert = NSAlert()
        let name = (c.dst as NSString).lastPathComponent
        let parent = (c.dst as NSString).deletingLastPathComponent
        let dir = DirSync.place(side, parent)
        alert.messageText = "“\(name)” already exists in \(dir)".bidiVisible
        let choices: [(String, FileJob.ConflictChoice)]
        if c.replacesFolder {
            alert.alertStyle = .critical
            alert.messageText = "Replace the folder “\(name)” in \(dir) with a file?".bidiVisible
            alert.informativeText = side == .local ? "The folder and everything in it go to the Trash."
                : "The folder and everything in it are deleted on the server. This can't be undone."
            choices = [("Skip", .skip), ("Keep Both", .keepBoth), ("Replace Folder", .overwrite), ("Cancel", .cancel)]
        } else if c.bothDirs {
            alert.informativeText = "Both are folders. Merge keeps existing files and asks about each clash inside."
            choices = [("Merge", .overwrite), ("Skip", .skip), ("Keep Both", .keepBoth), ("Cancel", .cancel)]
        } else {
            let newer = c.srcMtime > c.dstMtime ? "  ← newer" : ""
            alert.informativeText = "New:       \(describe(c.srcSize, c.srcMtime))\(newer)\nExisting:  \(describe(c.dstSize, c.dstMtime))"
            choices = [("Overwrite", .overwrite), ("Skip", .skip), ("Keep Both", .keepBoth),
                       ("Overwrite if Newer", .overwriteIfNewer), ("Cancel", .cancel)]
            if c.createdByThisJob {   // never "apply to all": one source would replace another
                alert.informativeText = "This operation just put it there — two of the items get the same name here "
                    + "(this folder doesn't tell “Makefile” from “makefile”).\n\n" + alert.informativeText
            } else {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Apply to all remaining conflicts"
            }
        }
        choices.forEach { alert.addButton(withTitle: $0.0) }
        alert.beginSheetModal(for: window) { response in
            let i = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let choice = choices.indices.contains(i) ? choices[i].1 : .cancel
            done((choice, alert.suppressionButton?.state == .on))
        }
    }

    private func askError(_ path: String, _ message: String, local: Bool, _ done: @escaping @Sendable ((FileJob.ErrorChoice, Bool)) -> Void) {
        guard let window else { return done((.abort, false)) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\((path as NSString).lastPathComponent)”: \(message)".bidiVisible
        alert.informativeText = (path as NSString).abbreviatingWithTildeInPath.bidiVisible
        if local && (message.contains("Permission denied") || message.contains("not permitted")) {
            alert.informativeText += "\n\nNeeds root? Admin ▸ Copy / Move / Delete as Administrator."
        }
        let choices: [(String, FileJob.ErrorChoice)] = [("Skip", .skip), ("Retry", .retry), ("Abort", .abort)]
        choices.forEach { alert.addButton(withTitle: $0.0) }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Skip all further errors"
        alert.beginSheetModal(for: window) { response in
            let i = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let choice = choices.indices.contains(i) ? choices[i].1 : .abort
            done((choice, choice == .skip && alert.suppressionButton?.state == .on))
        }
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// One job's progress line: ▸ · title · bar · details · start now (queued) · pause · cancel. ▸ opens the job's files
/// under it (`Activity.files`).
@MainActor
final class JobRow {   // internal for tests
    let job: FileJob
    let title: String
    let view: NSStackView
    var started: Date?
    private let detail = NSTextField(labelWithString: "Queued")
    let bar = NSProgressIndicator()
    let pause: NSButton   // internal for tests
    private let startNow: NSButton
    private let disclose: NSButton
    let files = NSTextField(wrappingLabelWithString: "")   // internal for tests
    private(set) var detailText = "Queued"
    private var lastBytes: Int64 = 0
    private var lastTime = Date()
    private var speed = 0.0
    private let onCancel: () -> Void
    private let onStartNow: () -> Void

    init(job: FileJob, title: String, onCancel: @escaping () -> Void, onStartNow: @escaping () -> Void) {
        self.job = job
        self.title = title
        self.onCancel = onCancel
        self.onStartNow = onStartNow
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        pause = NSButton(image: NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")!, target: nil, action: nil)
        let cancel = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")!, target: nil, action: nil)
        startNow = NSButton(image: NSImage(systemSymbolName: "forward.fill", accessibilityDescription: "Start Now")!, target: nil, action: nil)
        disclose = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Show the files")!, target: nil, action: nil)
        disclose.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        startNow.toolTip = "Start Now — run alongside the jobs already running"
        pause.toolTip = "Pause"
        cancel.toolTip = "Cancel"
        disclose.toolTip = "Show the files"
        for b in [disclose, startNow, pause, cancel] {
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.refusesFirstResponder = true
        }
        let line = NSStackView(views: [disclose, titleLabel, bar, detail, startNow, pause, cancel])
        line.orientation = .horizontal
        line.spacing = 8
        files.isSelectable = true
        files.isHidden = true
        files.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)   // wraps: never widens the window
        view = NSStackView(views: [line, files])
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 2
        line.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        files.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28).isActive = true
        files.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor).isActive = true
        pause.target = self
        pause.action = #selector(togglePause)
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        startNow.target = self
        startNow.action = #selector(startNowTapped)
        disclose.target = self
        disclose.action = #selector(toggleFiles)
    }

    /// The same buttons for the Activity list: Start Now (queued), Pause or Resume, Cancel.
    func controls() -> [NSButton] {
        var b: [NSButton] = []
        let state = job.progress.state
        if state == .queued { b.append(Activity.icon("forward.fill", "Start Now — run alongside the jobs already running") { [unowned self] in startNowTapped() }) }
        if state != .queued && (job.kind == .copy || job.kind == .move) {
            b.append(job.isPaused ? Activity.icon("play.fill", "Resume") { [unowned self] in togglePause() }
                                  : Activity.icon("pause.fill", "Pause") { [unowned self] in togglePause() })
        }
        b.append(Activity.icon("xmark", "Cancel") { [unowned self] in cancelTapped() })
        return b
    }

    @objc func toggleFiles() {
        files.isHidden.toggle()
        let (symbol, tip) = files.isHidden ? ("chevron.right", "Show the files") : ("chevron.down", "Hide the files")
        disclose.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        disclose.toolTip = tip
        update()
    }

    @objc private func startNowTapped() { onStartNow(); update() }

    @objc private func togglePause() {
        job.isPaused.toggle()
        let (symbol, label) = job.isPaused ? ("play.fill", "Resume") : ("pause.fill", "Pause")
        pause.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        pause.toolTip = label
        update()
    }

    @objc private func cancelTapped() { onCancel() }

    func update() {
        let p = job.progress
        let fmt = ByteCountFormatter()
        startNow.isHidden = p.state != .queued
        if !files.isHidden { files.attributedStringValue = Activity.files(job) }
        switch p.state {
        case .queued:
            detailText = "Queued"
        case .scanning:
            bar.isIndeterminate = true
            bar.startAnimation(nil)
            detailText = "Scanning…"
        default:
            bar.isIndeterminate = p.counting   // copying already, the totals still being counted
            if p.counting { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
            let fraction = p.totalBytes > 0 ? Double(p.doneBytes) / Double(p.totalBytes)
                : p.totalFiles > 0 ? Double(p.doneFiles) / Double(p.totalFiles) : 0
            bar.doubleValue = fraction

            let now = Date()
            let dt = now.timeIntervalSince(lastTime)
            if dt > 0 {
                let inst = Double(p.doneBytes - lastBytes) / dt
                speed = speed == 0 ? inst : speed * 0.7 + inst * 0.3
            }
            lastBytes = p.doneBytes
            lastTime = now

            var s = "\(p.doneFiles)/\(p.totalFiles)"
            if p.counting {
                s = "\(p.doneFiles) · \(fmt.string(fromByteCount: p.doneBytes)) · counting…"
            } else if p.totalBytes > 0 {
                s += " · \(fmt.string(fromByteCount: p.doneBytes)) of \(fmt.string(fromByteCount: p.totalBytes))"
                if speed > 1, !job.isPaused {
                    let eta = Int(Double(max(0, p.totalBytes - p.doneBytes)) / speed)
                    s += " · \(fmt.string(fromByteCount: Int64(speed)))/s · \(eta / 60):\(String(format: "%02d", eta % 60))"
                }
            }
            if job.isPaused { s += " · paused" }
            if !p.current.isEmpty { s += " · \(p.current)" }
            detailText = s
        }
        detail.stringValue = detailText
    }
}
