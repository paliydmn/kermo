import AppKit
import DFMCore

/// A watched tool's tab on a server's page (§6.3, monitor decision 7): the strip that says whether it's live while
/// open or watched in the background (Watch in Background… / Stop Watching), a banner on how the server is doing —
/// not answering, no answer yet, connecting, needs login, locked: metrics only — the dashboard's `stat` tiles with
/// their thresholds, and a line on the last sample. Made once a tab and updated in place as samples come
/// (`ToolMonitor.changed`): nothing is rebuilt every 5 s.
/// ponytail: charts, tables, events and counts of the dashboard come with the next PR; a tile shows the number now.
@MainActor final class ToolsLive: NSView {
    unowned let app: AppDelegate
    let tool: LoadedTool
    let server: SavedServer
    let target: SFTPTarget
    let strip = NSTextField(wrappingLabelWithString: "")
    let watchButton = NSButton(title: "Watch in Background…", target: nil, action: nil)
    let banner = NSTextField(wrappingLabelWithString: "")
    let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    let foot = NSTextField(labelWithString: "")
    private(set) var tiles: [Tile] = []
    private var kept: [AnyObject] = []

    /// One `stat` block: its metrics (two for `["rx", "tx"]`), `of` over rows, `also` under it.
    @MainActor struct Tile {
        let metrics: [String], of: String?, also: String?
        let value = NSTextField(labelWithString: "—"), detail = NSTextField(labelWithString: "")
        let bar: NSLevelIndicator?
        init(metrics: [String], of: String?, also: String?, bar: NSLevelIndicator?) { (self.metrics, self.of, self.also, self.bar) = (metrics, of, also, bar) }
    }

    init(_ app: AppDelegate, _ tool: LoadedTool, _ server: SavedServer, _ target: SFTPTarget) {
        (self.app, self.tool, self.server, self.target) = (app, tool, server, target)
        super.init(frame: .zero)
        let p = tool.preset
        strip.font = .systemFont(ofSize: 11)
        strip.textColor = .secondaryLabelColor
        watchButton.controlSize = .small
        banner.font = .systemFont(ofSize: 12)
        connectButton.controlSize = .small
        foot.font = .systemFont(ofSize: 11)
        foot.textColor = .secondaryLabelColor
        foot.lineBreakMode = .byTruncatingTail
        kept = [MenuAction.attach(to: watchButton) { [unowned self] in Task { await app.tools.toggleWatch(tool, on: server, target, window: window) } },
                MenuAction.attach(to: connectButton) { [unowned self] in app.tools.monitor.connect(target) }]
        // The dashboard's stat blocks, else the summary's metrics.
        let blocks = (p.dashboard ?? []).flatMap { $0.row ?? [$0] }.filter { $0.stat != nil }
        let specs: [(metrics: [String], of: String?, also: String?)] = blocks.isEmpty ? (p.summary ?? []).map { ([$0.metric], $0.of, nil) } : blocks.map { ($0.stat!.all, $0.of, $0.also) }
        tiles = specs.map { spec in
            let m = p.metrics?[spec.metrics[0]]
            var bar: NSLevelIndicator?
            if spec.metrics.count == 1, let m, m.unit == "%" || m.max != nil {
                let b = NSLevelIndicator()
                b.levelIndicatorStyle = .continuousCapacity
                (b.minValue, b.maxValue) = (0, m.max ?? 100)
                if let a = (p.alerts ?? []).first(where: { $0.metric == spec.metrics[0] && $0.below != true }) {
                    b.warningValue = a.warn ?? b.maxValue + 1
                    b.criticalValue = a.crit ?? b.maxValue + 1
                }
                b.isEditable = false
                bar = b
            }
            return Tile(metrics: spec.metrics, of: spec.of, also: spec.also, bar: bar)
        }
        let cells = tiles.map { t -> NSView in
            let title = (t.metrics.count > 1 ? t.metrics.compactMap { p.metrics?[$0]?.title } : [p.metrics?[t.metrics[0]]?.title ?? t.metrics[0]]).joined(separator: " · ")
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            t.value.font = .monospacedDigitSystemFont(ofSize: t.metrics.count > 1 ? 14 : 22, weight: .semibold)
            t.detail.font = .systemFont(ofSize: 11)
            t.detail.textColor = .secondaryLabelColor
            t.detail.lineBreakMode = .byTruncatingTail
            let cell = NSStackView(views: [label, t.value] + (t.bar.map { [$0] } ?? []) + [t.detail])
            (cell.orientation, cell.alignment, cell.spacing) = (.vertical, .leading, 3)
            cell.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true   // five tiles fit a 900-pt window; wider ones stay readable
            t.bar?.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            t.detail.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            cell.setAccessibilityLabel(title)
            return cell
        }
        let grid = NSStackView(views: cells)
        (grid.spacing, grid.alignment, grid.distribution) = (14, .top, .fillEqually)
        let stripRow = NSStackView(views: [strip, watchButton]), bannerRow = NSStackView(views: [banner, connectButton])
        strip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        banner.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [stripRow, bannerRow, grid, foot])
        (stack.orientation, stack.alignment, stack.spacing) = (.vertical, .leading, 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for v in [stripRow, bannerRow, foot] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        grid.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var state: ToolMonitor.Server? { app.tools.monitor.server(target) }
    private var known: ToolMonitor.Tool? { app.tools.monitor.tool(tool.preset.id, on: target) }

    /// What the monitor knows now, into the strip, the banner, the tiles and the line.
    func update() {
        let p = tool.preset, s = state, t = known, every = Int(p.watch?.every ?? 60), saved = app.tools.serverID(target) != nil
        let watched = t?.watched == true
        strip.stringValue = watched ? "Watched in the background · every \(every) s · alerts on"
            : "Live while open: nothing runs on \(server.title) after you leave this tab, no alerts."
        watchButton.title = watched ? "Stop Watching" : "Watch in Background…"
        watchButton.isEnabled = saved
        watchButton.toolTip = saved ? nil : "Save the server to watch it"
        let locked = ServerLock.server(for: target)?.locked == true
        let (text, color): (String, NSColor) = if let s, s.needsLogin {
            (s.connecting ? "Logging in to \(server.title)…" : "\(server.title) needs login — a key or a saved password would connect without asking. " + (s.error ?? ""), Palette.warn)
        } else if let s, let down = s.down {
            ("Not answering since \(down.formatted(date: .omitted, time: .shortened)) · \(s.missed) checks in a row · last data "
             + (s.lastLine?.formatted(date: .omitted, time: .standard) ?? "—") + ". This Mac is online.", Palette.fail)
        } else if let s, s.channel == nil, s.retryAt != nil {
            ("Connecting…" + (s.error.map { " (\($0))" } ?? ""), NSColor.secondaryLabelColor)
        } else if let s, s.channel != nil, s.missed > 0 {
            ("No answer for \(s.missed * Int(s.every)) s — Kermo calls it down after \(s.downAfter) checks in a row.", NSColor.secondaryLabelColor)
        } else if let s, s.channel == nil, s.retryAt == nil, let why = s.error {
            ("\(server.title): \(why)", Palette.warn)
        } else if !app.tools.monitor.online {
            ("This Mac has no network: nothing counts as down.", NSColor.secondaryLabelColor)
        } else if locked {
            ("\(server.title) is locked: watching reads metrics only; any action asks Touch ID.", NSColor.secondaryLabelColor)
        } else { ("", NSColor.labelColor) }
        banner.stringValue = text
        banner.textColor = color
        banner.isHidden = text.isEmpty
        connectButton.isHidden = s?.needsLogin != true || s?.connecting == true
        let record = t?.history.last?.record ?? [:]
        let scope = ToolTemplate.Scope(rows: [record])
        for tile in tiles {
            let texts = tile.metrics.map { id -> String in   // two in one tile, in the label's order ("In · Out")
                guard let m = p.metrics?[id], let v = ToolMetric.one(t?.history.latest(id) ?? [:], of: tile.of) else { return "—" }
                return m.text(v)
            }
            tile.value.stringValue = texts.joined(separator: " · ")
            let m = p.metrics?[tile.metrics[0]]
            let level = t?.alerts.worst(metric: tile.metrics[0], alerts: p.alerts ?? [])
            tile.value.textColor = level == .critical ? Palette.fail : level == .warning ? Palette.warn : .labelColor
            if let bar = tile.bar { bar.doubleValue = ToolMetric.one(t?.history.latest(tile.metrics[0]) ?? [:], of: tile.of) ?? 0 }
            var detail = m?.detail.map { ToolTemplate.text($0, scope) } ?? ""
            if let also = tile.also, let am = p.metrics?[also], let v = ToolMetric.one(t?.history.latest(also) ?? [:], of: nil) {
                detail = [detail, "\(am.title?.lowercased() ?? also) \(am.text(v))"].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            if let m, m.rows != nil, tile.metrics.count == 1, let (key, _) = (t?.history.latest(tile.metrics[0]) ?? [:]).max(by: { $0.value < $1.value }) {
                detail = [key, detail].filter { !$0.isEmpty }.joined(separator: " · ")   // the fullest disk
            }
            tile.detail.stringValue = detail
        }
        let last = t?.history.last.map { "last sample " + $0.at.formatted(date: .omitted, time: .standard) } ?? "no sample yet"
        foot.stringValue = (s?.channel == nil ? "Paused" : "Live") + " · \(last) · every \(every) s · " + (p.stream?.run.sudo ?? p.sudo ?? false ? "over SSH as root" : "over SSH · read-only")
    }

}

extension ToolRunner {
    /// Watch in Background…, or Stop Watching (decision 7): the sheet says what goes to the server and how often, the
    /// preset's rules, and that the connection stays open — on a locked server the lock guards actions, not the
    /// connection (decision 23). A tool of yours not in use yet asks "Use the tool…?" first. False: nothing changed.
    @discardableResult
    func toggleWatch(_ tool: LoadedTool, on s: SavedServer, _ t: SFTPTarget, window: NSWindow?) async -> Bool {
        let p = tool.preset
        guard let id = serverID(t) else { app.active.flash("\(s.title) isn't saved: only a saved server is watched", error: true); return false }
        if settings.watches(p.id, on: id) {
            monitor.watch(tool, on: t, false)
            return true
        }
        guard await trustAsk(tool, window: window) else { return false }
        if let ask = Self.watching { guard await ask(tool, s) else { return false } } else {
            var c = Confirm("Watch \(p.title) on \(s.title) in the background?", action: "Watch")
            c.chips = s.chips
            c.place = s.title
            let every = Int(p.watch?.every ?? 60)
            c.runs = "Every \(every) s, over the connection Kermo keeps for watching, while this Mac is awake:"
            c.command = tool.runs.background.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            let rules = (p.alerts ?? []).map { a -> String in
                let unit = a.metric.flatMap { p.metrics?[$0]?.unit } ?? ""
                var at: [String] = []
                if let w = a.warn { at.append("warning at \(ToolValue.number(w).text)\(unit)") }
                if let c = a.crit { at.append("critical at \(ToolValue.number(c).text)\(unit)") }
                var held = ""
                if let s = (a.for?.crit ?? a.for?.warn)?.seconds { held = " for " + ToolAlerts.minutes(s) } else if let n = a.checks { held = " \(n) checks in a row" }
                return "• \(a.id ?? a.metric ?? ""): " + at.joined(separator: ", ") + held
            }
            c.note = ((rules.isEmpty ? [] : ["Alerts, as the tool sets them:"] + rules)
                      + ["The connection stays open while \(s.title) is watched — it shows in w and last there. "
                         + (s.locked ? "\(s.title) is locked: watching resumes by itself after the Mac sleeps or locks, without Touch ID — the lock guards actions in Kermo, not the connection."
                                     : "Alerts show in the Tools window; notifications come with a later release.")]).joined(separator: "\n")
            guard await app.confirm(c, on: window) == 0 else { return false }
        }
        monitor.watch(tool, on: t, true)
        return true
    }

    /// Tests: the Watch sheet's answer.
    nonisolated(unsafe) static var watching: (@MainActor (LoadedTool, SavedServer) async -> Bool)?
}
