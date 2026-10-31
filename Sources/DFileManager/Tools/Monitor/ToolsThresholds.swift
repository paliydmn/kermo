import AppKit
import DFMCore

// Thresholds… (protocol §8.3, monitor decisions 7 and 31): your own warning and critical for the watched tools' alerts,
// for all servers or only one over those — an empty field leaves it to the value under it, shown in grey — and, on
// one server, whether each alert notifies (a notification's Mute unticks it). Only thresholds: notifications,
// `on_alert` and the rest are Settings › Monitor, a button away. Kept in tools/servers.json by the alert's id, so a
// new version of the tool keeps them.
extension ToolRunner {
    /// Tests: the sheet's answer in its place — what it gets (`Edit` — scope nil: all servers), what it gives back.
    nonisolated(unsafe) static var thresholding: (@MainActor ([Edit]) async -> [Edit]?)?

    /// One alert in one scope: your values (nil: left to the one under it) and, on a server, whether it notifies.
    struct Edit: Equatable {
        var tool: String, alert: String, scope: String?
        var mine: ToolServers.Threshold
        var notify = true
    }

    /// Thresholds… on `t`'s server for the tools it shows (saved: both scopes; else all servers only), over `window`;
    /// Done keeps them.
    func thresholds(on t: SFTPTarget, window: NSWindow?) async {
        let id = serverID(t), title = app.savedServer(at: t)?.title ?? t.shown
        let watched = (here(t)?.tools ?? tools).filter { $0.preset.watchable && !($0.preset.alerts ?? []).isEmpty }   // the server's
        let scopes: [String?] = [nil] + (id.map { [$0] } ?? [])
        let edits = watched.flatMap { tool in
            (tool.preset.alerts ?? []).flatMap { a in
                let key = a.id ?? a.metric ?? "", tid = tool.preset.id
                return scopes.map { scope in
                    Edit(tool: tid, alert: key, scope: scope, mine: settings.threshold(key, of: tid, on: scope), notify: scope.map { !settings.mutes(key, of: tid, on: $0) } ?? true)
                }
            }
        }
        let got = if let answer = Self.thresholding { await answer(edits) } else { await thresholdsSheet(watched, edits, server: id.map { ($0, title) }, window: window ?? app.window) }
        guard let got else { return }
        for e in got {
            settings.setThreshold(e.mine, alert: e.alert, of: e.tool, on: e.scope)
            if let scope = e.scope { settings.mute(e.alert, of: e.tool, on: scope, !e.notify) }
        }
        saveSettings()
        monitor.changed()
    }

    private func thresholdsSheet(_ tools: [LoadedTool], _ start: [Edit], server: (id: String, title: String)?, window: NSWindow) async -> [Edit]? {
        let alert = AppDelegate.alert("Thresholds", info: "", ["Done", "Cancel"])
        var edits = start, scope: String? = nil, kept: [AnyObject] = []
        var rows: [(index: (String?) -> Int?, warn: NSTextField?, crit: NSTextField?, notify: NSButton)] = []
        let grid = NSGridView(numberOfColumns: 5, rows: 0)
        (grid.rowSpacing, grid.columnSpacing) = (6, 10)
        func small(_ s: String, bold: Bool = false) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 11.5, weight: bold ? .semibold : .regular)
            return l
        }
        grid.addRow(with: ["When", "Warning", "Critical", "For", "Notify"].map { small($0, bold: true) })
        for tool in tools {
            let p = tool.preset
            grid.addRow(with: [small(p.title, bold: true)])
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 5), verticalRange: NSRange(location: grid.numberOfRows - 1, length: 1))
            for a in p.alerts ?? [] {
                let key = a.id ?? a.metric ?? "", m = a.metric.flatMap { p.metrics?[$0] }
                func field(_ preset: Double?) -> NSTextField? {
                    guard preset != nil else { return nil }   // the tool has none: nothing to change
                    let f = NSTextField()
                    f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                    f.widthAnchor.constraint(equalToConstant: 60).isActive = true
                    f.setAccessibilityLabel("\(m?.title ?? key) \(preset == a.warn ? "warning" : "critical")")
                    return f
                }
                let warn = field(a.warn), crit = field(a.crit), unit = m?.unit ?? ""
                func cell(_ f: NSTextField?) -> NSView {
                    guard let f else { return small("—") }
                    let h = NSStackView(views: [f, small(unit)])
                    h.spacing = 3
                    return h
                }
                let held = [(a.for?.warn, a.warn), (a.for?.crit, a.crit)].map { d, v in v == nil ? "—" : d?.seconds.map(ToolAlerts.minutes) ?? (a.checks.map { "\($0) checks" } ?? "at once") }
                let notify = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                notify.setAccessibilityLabel("Notify of \(m?.title ?? key)")
                grid.addRow(with: [small((m?.title ?? key) + (a.below == true ? " (below)" : "")), cell(warn), cell(crit), small(held.joined(separator: " / ")), notify])
                rows.append(({ s in edits.firstIndex { $0.tool == p.id && $0.alert == key && $0.scope == s } }, warn, crit, notify))
            }
            if let down = p.watch?.down {
                grid.addRow(with: [small("Not answering"), small("—"), small("\(down) checks"), small("every \(Int(p.watch?.every ?? 60)) s"), NSView()])
            }
        }
        let note = Confirm.label("", color: .secondaryLabelColor, size: 11)
        let done = alert.buttons[0]
        func number(_ f: NSTextField?) -> Double?? {   // nil: not a number; .some(nil): empty
            guard let f else { return .some(nil) }
            let text = f.stringValue.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? .some(nil) : Double(text).map { .some($0) }
        }
        // The fields into `edits` for this scope; Done only while each is a number or empty.
        func store() {
            var ok = true
            for r in rows {
                guard let i = r.index(scope) else { continue }
                let w = number(r.warn), c = number(r.crit)
                ok = ok && w != nil && c != nil
                edits[i].mine = ToolServers.Threshold(warn: w ?? nil, crit: c ?? nil)
                if scope != nil { edits[i].notify = r.notify.state == .on }
            }
            done.isEnabled = ok
        }
        // This scope's values; in grey, what an empty field leaves it to: on a server, all servers' (as set here), else the tool's.
        func load() {
            for r in rows {
                guard let i = r.index(scope) else { continue }
                let e = edits[i], tool = tools.first { $0.preset.id == e.tool }?.preset
                let preset = tool?.alerts?.first { ($0.id ?? $0.metric) == e.alert }
                let all = scope == nil ? nil : r.index(nil).map { edits[$0].mine }
                for (f, mine, under) in [(r.warn, e.mine.warn, all?.warn ?? preset?.warn), (r.crit, e.mine.crit, all?.crit ?? preset?.crit)] {
                    f?.stringValue = mine.map { ToolValue.number($0).text } ?? ""
                    f?.placeholderString = under.map { ToolValue.number($0).text }
                }
                r.notify.state = e.notify ? .on : .off
            }
            grid.column(at: 4).isHidden = scope == nil
            note.stringValue = scope == nil ? "From the tools; a value here is for every server." : "Only on \(server?.title ?? ""): a value here wins over all servers'. Notify unticked: it still shows, with no notification."
            done.isEnabled = true
        }
        for r in rows {
            for f in [r.warn, r.crit].compactMap({ $0 }) {
                let live = LiveField { store() }
                f.delegate = live
                kept.append(live)
            }
            kept.append(MenuAction.attach(to: r.notify) { store() })
        }
        var top: [NSView] = []
        if let server {
            let seg = NSSegmentedControl(labels: ["All Servers", "Only \(server.title)"], trackingMode: .selectOne, target: nil, action: nil)
            seg.selectedSegment = 0
            kept.append(MenuAction.attach(to: seg) {
                store()
                scope = seg.selectedSegment == 0 ? nil : server.id
                load()
            })
            top.append(seg)
        }
        let restore = NSButton(title: "Restore Defaults", target: nil, action: nil), settings = NSButton(title: "Notification Settings…", target: nil, action: nil)
        kept += [MenuAction.attach(to: restore) {
                     for r in rows { r.warn?.stringValue = ""; r.crit?.stringValue = "" }
                     store()
                 },
                 MenuAction.attach(to: settings) { [unowned self] in SettingsWindow.show(app, tab: "Monitor") }]
        let foot = NSStackView(views: [restore, settings])
        alert.accessoryView = Confirm.stack(top + [note, grid,
                                                   Confirm.label("Notifications, the command to run on critical alerts and the rest are app settings: Settings › Monitor.",
                                                                 color: .secondaryLabelColor, size: 11), foot], width: 470)
        load()
        let answer = await AppDelegate.sheet(alert, on: window)
        store()
        return withExtendedLifetime(kept) { answer == 0 && done.isEnabled ? edits : nil }
    }
}
