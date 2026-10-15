import AppKit
import DFMCore

/// Queue of file jobs with a progress row per job, shown above the F-key bar. Jobs run one at a time per lane —
/// this Mac, or a server — and lanes run side by side, so a slow upload never holds up a local copy (or the other
/// way round). Start Now runs a queued job right away, next to whatever is running.
/// Workers block on our sheets for conflicts/errors via `ask`.
@MainActor
final class OpsController {
    let view = NSStackView()
    private weak var window: NSWindow?
    private var rows: [JobRow] = []
    /// Running and queued jobs.
    var pending: Int { rows.count }
    private var running: [FileJob] = []
    private var timer: Timer?
    private let onFinished: (FileJob) -> Void

    init(window: NSWindow, onFinished: @escaping (FileJob) -> Void) {
        self.window = window
        self.onFinished = onFinished
        view.orientation = .vertical
        view.spacing = 4
        view.setHuggingPriority(.defaultHigh, for: .vertical)   // as tall as its rows: the panels take the rest
        view.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 2, right: 8)
        view.isHidden = true
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
        view.addArrangedSubview(row.view)
        row.view.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -16).isActive = true
        view.isHidden = false
        startNext()
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
        job.start()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.rows.forEach { $0.update() } }
            }
        }
    }

    private func cancel(_ job: FileJob) {
        job.cancel()
        if !running.contains(where: { $0 === job }) { remove(job) }   // queued, never started
    }

    private func finished(_ job: FileJob) {
        running.removeAll { $0 === job }
        let errors = job.progress.errors
        remove(job)
        onFinished(job)
        if !errors.isEmpty, let window {
            let alert = NSAlert()
            alert.messageText = "Finished with \(errors.count) error\(errors.count == 1 ? "" : "s")"
            alert.informativeText = errors.prefix(10).joined(separator: "\n").bidiVisible + (errors.count > 10 ? "\n…" : "")
            alert.beginSheetModal(for: window)
        }
        startNext()
    }

    private func remove(_ job: FileJob) {
        job.onFinish = {}   // it held the job: every job ever run stayed in memory, its lists and errors with it
        guard let i = rows.firstIndex(where: { $0.job === job }) else { return }
        rows.remove(at: i).view.removeFromSuperview()
        if rows.isEmpty {
            view.isHidden = true
            timer?.invalidate()
            timer = nil
        }
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

/// One job's progress line: title · bar · details · start now (queued) · pause · cancel.
@MainActor
final class JobRow {   // internal for tests
    let job: FileJob
    let view: NSStackView
    private let detail = NSTextField(labelWithString: "Queued")
    private let bar = NSProgressIndicator()
    let pause: NSButton   // internal for tests
    private let startNow: NSButton
    private var lastBytes: Int64 = 0
    private var lastTime = Date()
    private var speed = 0.0
    private let onCancel: () -> Void
    private let onStartNow: () -> Void

    init(job: FileJob, title: String, onCancel: @escaping () -> Void, onStartNow: @escaping () -> Void) {
        self.job = job
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
        startNow.toolTip = "Start Now — run alongside the jobs already running"
        pause.toolTip = "Pause"
        cancel.toolTip = "Cancel"
        for b in [startNow, pause, cancel] {
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.refusesFirstResponder = true
        }
        view = NSStackView(views: [titleLabel, bar, detail, startNow, pause, cancel])
        view.orientation = .horizontal
        view.spacing = 8
        pause.target = self
        pause.action = #selector(togglePause)
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        startNow.target = self
        startNow.action = #selector(startNowTapped)
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
        switch p.state {
        case .queued:
            detail.stringValue = "Queued"
        case .scanning:
            bar.isIndeterminate = true
            bar.startAnimation(nil)
            detail.stringValue = "Scanning…"
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
            detail.stringValue = s
        }
    }
}
