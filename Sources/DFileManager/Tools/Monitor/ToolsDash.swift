import AppKit
import Charts
import DFMCore
import SwiftUI

// The dashboard's blocks beyond `stat` (protocol §6.3): charts, tables with their row actions, events and counts.
// Each is made once for a watched tool's tab and updated in place as samples come (`ToolsLive.update`), reading
// what the monitor knows through its tab.

@MainActor protocol ToolsBlock: NSView {
    func update(_ live: ToolsLive)
}

// MARK: Charts

/// A `charts` block: small multiples of the tool's series, two to a row — a line per series key, never across a
/// gap; the gaps as bands saying why; the alert's thresholds as lines; the events of the hour on the time axis; one
/// time axis and one crosshair for the block, the values under it in each chart's header; a click runs the `log`
/// action with `{from}` / `{to}` five minutes around that moment. Swift Charts in an NSHostingView over an
/// ObservableObject the tab's update feeds (SwiftUI's @State is a macro the Command Line Tools haven't). The hour
/// in memory; `range`'s longer spans from the history on disk (`ToolSlots`): each 15-minute slot's average, the
/// gaps it wrote, "not watched" where it has nothing.
@MainActor final class ToolsCharts: NSView, ToolsBlock {
    /// What the charts draw: changed as one, so a sample draws the block once.
    struct Data {
        var charts: [Chart] = []
        var from = Date(), to = Date()
        var events: [ToolEventRecord] = []
    }
    struct Chart: Identifiable {
        let id: String, title: String, metric: ToolMetric, top: Double
        var lines: [Line]
        var bands: [ToolChart.Band]
        var warn, crit: Double?
    }
    struct Line: Identifiable {
        let id: String, name: String
        let points: [ToolPoint]
        let chart: ToolChart
    }
    @MainActor final class Model: ObservableObject {
        @Published var data = Data()
        @Published var hover: Date?
        var every: TimeInterval = 5
        var clicked: (Date) -> Void = { _ in }
        /// Days on the axis: the week's.
        var days: Bool { data.to.timeIntervalSince(data.from) > 2 * 86400 }
    }

    let block: ToolBlock
    let model = Model()
    /// The charts, while this block is on screen (`viewDidMoveToWindow`).
    private(set) var hosting: NSHostingView<ChartsView>?
    private let place = NSView()
    let range = NSSegmentedControl()
    /// The longer span's lines as last read, and the slot they were read in: a new slot may be on disk since.
    private var disk: (span: Double, slot: Double, lines: [ToolSlots.Line])?
    private var kept: AnyObject?

    init(_ live: ToolsLive, _ block: ToolBlock) {
        self.block = block
        super.init(frame: .zero)
        let n = block.charts?.count ?? 0
        place.heightAnchor.constraint(equalToConstant: CGFloat((n + 1) / 2) * 176).isActive = true
        model.clicked = { [unowned live] at in live.log(block.log, at: at) }
        var views: [NSView] = [place]
        if let ranges = block.range, ranges.count > 1 {
            range.segmentCount = ranges.count
            for (i, r) in ranges.enumerated() {
                let text: String = switch r { case .text(let s): s; case .seconds(let s): ToolAlerts.minutes(s) }
                range.setLabel(text, forSegment: i)
                range.setToolTip((r.seconds ?? 0) <= 3600 ? "The last hour, as watched" : "From the history on this Mac: 15-minute averages, while watched", forSegment: i)
            }
            range.selectedSegment = 0
            range.controlSize = .small
            kept = MenuAction.attach(to: range) { [weak self, unowned live] in self?.update(live) }
            let head = NSStackView(views: [ToolsWindow.spacer(), range])
            views.insert(head, at: 0)
        }
        let stack = NSStackView(views: views)
        (stack.orientation, stack.alignment, stack.spacing) = (.vertical, .leading, 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        setAccessibilityLabel("Charts")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shown: the charts into the tree; hidden — another tab, the window closed — out of it (spike S4: charts left
    /// in the tree of a closed window cost 2 % CPU). The model keeps the data, so they come back as they were.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hosting?.removeFromSuperview()
            hosting = nil
        } else if hosting == nil {
            let h = NSHostingView(rootView: ChartsView(model: model))
            h.sizingOptions = []
            h.translatesAutoresizingMaskIntoConstraints = false
            place.addSubview(h)
            NSLayoutConstraint.activate([h.leadingAnchor.constraint(equalTo: place.leadingAnchor), h.trailingAnchor.constraint(equalTo: place.trailingAnchor),
                                         h.topAnchor.constraint(equalTo: place.topAnchor), h.bottomAnchor.constraint(equalTo: place.bottomAnchor)])
            hosting = h
        }
    }

    func update(_ live: ToolsLive) {
        let p = live.tool.preset, t = live.known, now = live.now, alerts = live.alerts
        let span = block.range.flatMap { $0.indices.contains(range.selectedSegment) ? $0[range.selectedSegment].seconds : nil } ?? 3600
        var d = Data()
        (d.to, d.from) = (now, now.addingTimeInterval(-max(span, t?.history.keep ?? 3600)))
        // Past the hour: the slots on disk, read again once a slot has passed since.
        let slots: [ToolSlots.Line]? = span <= 3600 ? nil : {
            if let disk, disk.span == span, disk.slot == ToolSlots.slot(Date()) { return disk.lines }
            let lines = ToolSlots.read(ToolMonitor.history(live.server.id), tool: p.id, from: d.from)
            disk = (span, ToolSlots.slot(Date()), lines)
            return lines
        }()
        // Maintenance over the values: by the server's clock, as the series are.
        let maintenance = live.state?.maintenance.flatMap { m -> [ToolChart.Band] in
            let skew = live.state?.skew ?? 0, from = max(m.from.addingTimeInterval(skew), d.from), to = min(m.until.addingTimeInterval(skew), now)
            return from < to ? [ToolChart.Band(from: from, to: to, gap: .maintenance)] : []
        } ?? []
        d.charts = (block.charts ?? []).compactMap { ids -> Chart? in
            let metrics = ids.compactMap { id in p.metrics?[id].map { (id: id, metric: $0) } }
            guard let first = metrics.first else { return nil }
            var lines: [Line] = []
            for (id, m) in metrics {
                // ponytail: a line per series key, six a chart (disks by mount) — `per` isn't read, it would say the same;
                // more lines and a legend that scrolls wait for a design pass.
                let keys = slots.map { ToolSlots.keys($0, metric: id) } ?? t?.history.series[id]?.keys.sorted() ?? []
                for key in (keys.isEmpty ? [""] : keys).prefix(6) {
                    let pts = slots.map { ToolSlots.points($0, metric: id, key: key, from: d.from) } ?? t?.history.points(id, key) ?? []
                    lines.append(Line(id: "\(id) \(key)", name: key.isEmpty ? m.title ?? id : key, points: pts, chart: ToolChart(pts, now: now)))
                }
            }
            let alert = metrics.count == 1 ? alerts.first { $0.metric == first.id && $0.below != true } : nil
            return Chart(id: ids.joined(separator: "+"), title: metrics.map { $0.metric.title ?? $0.id }.joined(separator: " · "), metric: first.metric,
                         top: ToolChart.top(lines.flatMap { $0.points.compactMap(\.value) }, max: first.metric.max ?? (first.metric.unit == "%" ? 100 : nil)),
                         lines: lines, bands: (lines.map(\.chart.bands).max { $0.count < $1.count } ?? []) + maintenance, warn: alert?.warn, crit: alert?.crit)
        }
        d.events = ((t?.events ?? []) + (live.state?.events ?? [])).filter { $0.at >= d.from && $0.level != "ok" }
        model.every = slots == nil ? p.watch?.every ?? 60 : ToolSlots.length
        model.data = d
    }
}

struct ChartsView: View {
    @ObservedObject var model: ToolsCharts.Model

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 10) {
            ForEach(model.data.charts) { OneChart(chart: $0, model: model) }
        }
    }
}

/// One chart of the block; the crosshair and the time axis are the block's.
struct OneChart: View {
    let chart: ToolsCharts.Chart
    @ObservedObject var model: ToolsCharts.Model
    /// Series colors in a fixed order (the first two: In · Out, read · write); red, orange, purple and green mean
    /// something else in Kermo.
    static let colors: [Color] = [.accentColor, Color(nsColor: .secondaryLabelColor), .teal, .indigo, .brown, .mint]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(chart.title).font(.caption.weight(.medium))
                Spacer()
                Text(said).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            plot.frame(height: 150)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chart.title): \(said)")
    }

    /// The last values; under the crosshair, the values then and the time — or why there are none.
    var said: String {
        func shown(_ v: Double?) -> String { v.map(chart.metric.text) ?? "—" }
        guard let h = model.hover else { return chart.lines.map { shown($0.points.last?.value) }.joined(separator: " · ") }
        let time = h.formatted(model.days ? .dateTime.weekday().hour().minute() : .dateTime.hour().minute().second())
        if let b = chart.bands.first(where: { $0.gap != .maintenance && $0.from <= h && h <= $0.to }) { return Self.word(b.gap) + " · " + time }
        return chart.lines.map { shown(ToolChart.nearest($0.points, to: h, within: model.every * 1.5)?.value) }.joined(separator: " · ") + " · " + time
    }

    static func word(_ g: ToolGap) -> String {
        switch g { case .asleep: "Mac asleep"; case .noAnswer: "no answer"; case .reconnecting: "reconnecting"; case .notWatched: "not watched"; case .maintenance: "maintenance" }
    }

    private static func band(_ g: ToolGap) -> Color {
        g == .noAnswer ? Color(nsColor: Palette.fail).opacity(0.1) : g == .maintenance ? Color(nsColor: Palette.accent).opacity(0.1) : Color(nsColor: .labelColor).opacity(0.08)
    }

    private static func level(_ s: String) -> Color {
        s == "critical" ? Color(nsColor: Palette.fail) : s == "warning" ? Color(nsColor: Palette.warn) : Color(nsColor: .secondaryLabelColor)
    }

    private var plot: some View {
        Chart {
            ForEach(Array(chart.bands.enumerated()), id: \.offset) { _, b in
                RectangleMark(xStart: .value("From", b.from), xEnd: .value("To", b.to), yStart: .value("Bottom", 0), yEnd: .value("Top", chart.top))
                    .foregroundStyle(Self.band(b.gap))
                    .annotation(position: .overlay, alignment: .topLeading) { Text(Self.word(b.gap)).font(.caption2).foregroundStyle(.secondary).padding(2) }
            }
            ForEach(chart.lines) { line in
                ForEach(Array(line.chart.runs.enumerated()), id: \.offset) { i, run in
                    ForEach(Array(run.enumerated()), id: \.offset) { _, p in   // by place: lines read together share one time
                        LineMark(x: .value("Time", p.at), y: .value(chart.title, min(p.value ?? 0, chart.top)), series: .value("Run", "\(line.id) \(i)"))
                            .foregroundStyle(by: .value("Series", line.name))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
            }
            if let w = chart.warn, w <= chart.top {
                RuleMark(y: .value("Warning", w)).foregroundStyle(Color(nsColor: Palette.warn)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let c = chart.crit, c <= chart.top {
                RuleMark(y: .value("Critical", c)).foregroundStyle(Color(nsColor: Palette.fail)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            ForEach(Array(model.data.events.enumerated()), id: \.offset) { _, e in
                PointMark(x: .value("Time", e.at), y: .value("Bottom", 0)).foregroundStyle(Self.level(e.level)).symbolSize(24)
            }
            if let h = model.hover {
                RuleMark(x: .value("Time", h)).foregroundStyle(Color(nsColor: .secondaryLabelColor)).lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: model.data.from...model.data.to)
        .chartYScale(domain: 0...chart.top)
        .chartForegroundStyleScale(domain: chart.lines.map(\.name), range: Array(Self.colors.prefix(max(1, chart.lines.count))))
        .chartLegend(chart.lines.count > 1 ? .visible : .hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, chart.top / 2, chart.top]) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(chart.metric.text(d)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: model.days ? .dateTime.weekday().hour() : .dateTime.hour().minute()) }
        }
        .chartOverlay { proxy in
            GeometryReader { g in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in   // snapped to a sample, published only when it moves to another: a move redraws the block
                        switch phase {
                        case .active(let p):
                            guard let f = proxy.plotFrame, let d = proxy.value(atX: p.x - g[f].origin.x, as: Date.self) else { return }
                            let at = Date(timeIntervalSince1970: (d.timeIntervalSince1970 / model.every).rounded() * model.every)
                            if model.hover != at { model.hover = at }
                        case .ended: if model.hover != nil { model.hover = nil }
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { v in
                        if let f = proxy.plotFrame, let d = proxy.value(atX: v.location.x - g[f].origin.x, as: Date.self) { model.clicked(d) }
                    })
            }
        }
    }
}

// MARK: Table

/// A `table` block: a row set as the latest sample that carried it, in the block's columns (§5.2's formats, a `bar`
/// as one), each row with the block's actions as buttons — down the one path every action takes
/// (`ToolListSource.action`: the lock, production's question, the line on the page, red for what can't be undone).
/// An action this version doesn't run (Biggest Folders: a level) is greyed, saying so.
@MainActor final class ToolsTable: NSView, NSTableViewDataSource, NSTableViewDelegate, ToolsBlock {
    let block: ToolBlock
    let table = NSTableView()
    private(set) var rows: [ToolRow] = []
    private let view: ToolListView
    private let source: ToolListSource
    private let heading = NSTextField(labelWithString: "")
    private let height: NSLayoutConstraint
    /// The header and the rows; a legacy horizontal scroller adds its height (`layout`).
    private var fit: CGFloat = 48
    private var kept: [AnyObject] = []
    private var tasks: [String: Task<Void, Never>] = [:]

    private static let numbers: Set<String> = ["%", "bytes", "kbytes", "ms", "days"]

    init(_ live: ToolsLive, _ block: ToolBlock) {
        self.block = block
        // ponytail: a table with no `key` names its rows by their record, so a row's id changes with its numbers; System's say `{pid}` / `{mount}`.
        view = ToolListView(columns: block.columns, key: block.key)
        source = ToolListSource(live.app, live.tool, live.server, live.target)
        let scroll = NSScrollView()
        height = scroll.heightAnchor.constraint(equalToConstant: 48)
        super.init(frame: .zero)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.stringValue = block.title ?? block.table ?? ""
        table.columnAutoresizingStyle = .noColumnAutoresizing   // before the columns: the first takes the slack (`layout`); past the width, it scrolls
        for c in block.columns ?? [] {
            let (field, format) = c.field, number = Self.numbers.contains(format ?? "")
            let col = NSTableColumn(identifier: .init(field))
            (col.title, col.width, col.minWidth) = (c.title, c.width ?? (number ? 56 : format == "bar" ? 100 : 64), table.tableColumns.isEmpty ? 80 : 40)   // the first names the row
            if number { col.headerCell.alignment = .right }
            table.addTableColumn(col)
        }
        if !actions.isEmpty {   // as wide as its buttons
            let probe = NSButton(title: "", target: nil, action: nil)
            (probe.controlSize, probe.font) = (.small, .systemFont(ofSize: 11))
            let col = NSTableColumn(identifier: .init("actions"))
            col.title = ""
            col.width = actions.reduce(6) { w, a in probe.title = a.spec.title ?? a.spec.id; return w + probe.intrinsicContentSize.width + 4 }
            col.minWidth = col.width
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.setAccessibilityLabel(heading.stringValue)
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = true   // a narrow window: the buttons stay reachable
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        let stack = NSStackView(views: [heading, scroll])
        (stack.orientation, stack.alignment, stack.spacing) = (.vertical, .leading, 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), height])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The first column as wide as the block leaves it, the others as set; a legacy scroller under a table wider
    /// than the block gets its height.
    override func layout() {
        super.layout()
        guard let first = table.tableColumns.first, let scroll = table.enclosingScrollView else { return }
        let rest = table.tableColumns.dropFirst().reduce(0) { $0 + $1.width } + CGFloat(table.tableColumns.count) * table.intercellSpacing.width
        let width = max(first.minWidth, scroll.contentView.bounds.width - rest)
        if abs(first.width - width) > 0.5 { first.width = width }
        let bar: CGFloat = width + rest > scroll.contentView.bounds.width + 0.5 && NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        if abs(height.constant - (fit + bar)) > 0.5 { height.constant = fit + bar }
    }

    private var actions: [ToolAction] { (block.actions ?? []).compactMap { id in source.preset.actions?.first { $0.spec.id == id } } }

    func update(_ live: ToolsLive) {
        let scope = live.app.tools.scope(live.tool.preset, on: live.server, live.target), now = live.now
        let fresh = (live.known?.history.rows(block.table ?? "") ?? []).map { record -> ToolRow in
            var r = view.row(record, scope, now: now)
            r.title = r.cells.first?.text ?? r.title   // the first column names the row in a question ("sleep"), its record is its key
            return r
        }
        guard fresh != rows else { return }
        rows = fresh
        kept = []
        table.reloadData()
        fit = (table.headerView?.frame.height ?? 23) + CGFloat(max(1, rows.count)) * (table.rowHeight + table.intercellSpacing.height) + 2
        needsLayout = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(row) else { return nil }
        let r = rows[row]
        if id == "actions" { return buttons(r) }
        let cell = r.cells.first { $0.field == id }
        if cell?.format == "bar", let v = cell?.value?.number {
            let bar = NSLevelIndicator()
            bar.levelIndicatorStyle = .continuousCapacity
            (bar.minValue, bar.maxValue, bar.doubleValue) = (0, 100, v)
            bar.controlSize = .mini
            bar.isEditable = false
            bar.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let s = NSStackView(views: [bar, label(ToolTemplate.show(.number(v), "%"), right: true)])
            s.spacing = 4
            return s
        }
        return label(cell?.text ?? "", right: Self.numbers.contains(cell?.format ?? ""))
    }

    private func label(_ text: String, right: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        l.lineBreakMode = .byTruncatingTail
        l.alignment = right ? .right : .left
        l.toolTip = text
        return l
    }

    /// The row's buttons: one an action; pressed, it waits for its run.
    private func buttons(_ row: ToolRow) -> NSView {
        let p = source.preset, id = source.rowID(row.key), known = source.app.tools.answers[ServerRow.key(source.target)]?.answer, monitor = source.app.tools.monitor
        let views = actions.map { a -> NSButton in
            let title = (a.spec.title ?? a.spec.id)
            let b = NSButton(title: title, target: nil, action: nil)
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            if a.spec.check == true, let s = monitor.server(source.target), let t = s.tools[p.id] {   // Check Now: the checks, at once
                b.toolTip = "Check every address now, from this Mac"
                kept.append(MenuAction.attach(to: b) { [weak s, weak t] in if let s, let t { monitor.check(t, on: s) } })
                return b
            }
            guard ToolRunner.runs(a, of: p) else {
                b.isEnabled = false
                b.toolTip = "\(title): levels of a list come with a later release"
                return b
            }
            let action = source.action(a, row: row, onRow: true, id: id, group: 0, keyed: known?.has(a, of: p) ?? (a.spec.requires == nil))
            b.isEnabled = action.why == nil && tasks[id + title] == nil
            b.toolTip = action.why ?? action.command
            if action.dangerous { b.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: Palette.fail]) }
            kept.append(MenuAction.attach(to: b) { [weak self, weak b] in
                guard let task = action.run(false) else { return }
                b?.isEnabled = false
                self?.tasks[id + title] = task
                Task { await task.value; self?.tasks[id + title] = nil; b?.isEnabled = true }
            })
            return b
        }
        let s = NSStackView(views: views)
        s.spacing = 4
        return s
    }
}

// MARK: Events

/// An `events` block: the tool's events and the server's own (watching started, not answering, answers again),
/// newest first, the last 14 — the time, the level as a shape with its color, the words, and the place it goes
/// (`goto`).
@MainActor final class ToolsEvents: NSView, ToolsBlock {
    private let list = NSStackView()
    /// nil till the first draw: an empty list says "Nothing yet".
    private var shown: [ToolEventRecord]?
    private var kept: [AnyObject] = []

    init() {
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: "Events")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        (list.orientation, list.alignment, list.spacing) = (.vertical, .leading, 3)
        let stack = NSStackView(views: [heading, list])
        (stack.orientation, stack.alignment, stack.spacing) = (.vertical, .leading, 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     list.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        setAccessibilityLabel("Events")
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ live: ToolsLive) {
        let all = Array(((live.known?.events ?? []) + (live.state?.events ?? [])).sorted { $0.at > $1.at }.prefix(14))
        guard all != shown else { return }
        shown = all
        kept = []
        list.setViews(all.isEmpty ? [ToolsWindow.small("Nothing yet")] : all.map { row($0, live) }, in: .top)
        for v in list.arrangedSubviews { v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
    }

    /// Red octagon critical, amber triangle warning, green dot back to normal, grey dot the rest.
    static func mark(_ level: String) -> NSImage {
        switch level {
        case "critical": Symbol.crit.image("critical", color: Palette.fail, size: 11)
        case "warning": Symbol.warnFill.image("warning", color: Palette.warn, size: 11)
        case "ok": Symbol.dot.image("back to normal", color: Palette.ok, size: 8)
        default: Symbol.dot.image("info", color: .tertiaryLabelColor, size: 8)
        }
    }

    private func row(_ e: ToolEventRecord, _ live: ToolsLive) -> NSView {
        let time = ToolsWindow.small(e.at.formatted(date: .omitted, time: .shortened))
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        let text = NSTextField(labelWithString: e.message)
        text.font = .systemFont(ofSize: 12)
        text.lineBreakMode = .byTruncatingTail
        text.toolTip = e.message
        text.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        var views: [NSView] = [time, NSImageView(image: Self.mark(e.level)), text, ToolsWindow.spacer()]
        if let g = e.goto.flatMap(ToolRunner.Goto.init) {
            let b = NSButton(title: g.title, target: nil, action: nil)
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            kept.append(MenuAction.attach(to: b) { [unowned live] in live.app.tools.go(g, on: live.target) })
            views.append(b)
        }
        let s = NSStackView(views: views)
        s.spacing = 6
        s.setAccessibilityLabel("\(e.level) \(e.message)")
        return s
    }
}

// MARK: Counts

/// A `counts` block: how many rows a row set has as the latest sample that carried it — "3 failed services" — and
/// the place in Kermo it goes to.
@MainActor final class ToolsCounts: NSView, ToolsBlock {
    let block: ToolBlock
    private(set) var numbers: [NSTextField] = []
    private var kept: [AnyObject] = []

    init(_ live: ToolsLive, _ block: ToolBlock) {
        self.block = block
        super.init(frame: .zero)
        let rows = (block.counts ?? []).map { c -> NSView in
            let n = NSTextField(labelWithString: "—")
            n.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
            n.alignment = .right
            n.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
            numbers.append(n)
            let title = NSTextField(labelWithString: c.title)
            title.font = .systemFont(ofSize: 12)
            title.lineBreakMode = .byTruncatingTail
            var views: [NSView] = [n, title, ToolsWindow.spacer()]
            if let g = c.goto.flatMap(ToolRunner.Goto.init) {
                let b = NSButton(title: g.title, target: nil, action: nil)
                b.controlSize = .small
                b.font = .systemFont(ofSize: 11)
                kept.append(MenuAction.attach(to: b) { [unowned live] in live.app.tools.go(g, on: live.target) })
                views.append(b)
            }
            let s = NSStackView(views: views)
            s.spacing = 6
            return s
        }
        let stack = NSStackView(views: rows)
        (stack.orientation, stack.alignment, stack.spacing) = (.vertical, .leading, 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for v in rows { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        setAccessibilityLabel("Counts")
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ live: ToolsLive) {
        for (n, c) in zip(numbers, block.counts ?? []) {
            n.stringValue = live.known?.history.carried(c.rows).map { "\($0.rows(c.rows).count)" } ?? "—"
        }
    }
}
