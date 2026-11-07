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
        /// The moment the tables show (`ToolsLive.moment`): a line across each chart.
        @Published var moment: Date?
        var every: TimeInterval = 5
        /// A click at that time, in the clicked chart's band if it fell in one.
        var clicked: (Date, ToolGap?) -> Void = { _, _ in }
        /// The context menu's Log for This Time: its title, and the run; nil: the block has no `log`.
        var log: (title: String, run: (Date) -> Void)?
        /// The last time under the pointer: the context menu's, should the hover have ended as it opened.
        var lastHover: Date?
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
        // On the last hour, with tables to show it in, a click is the moment; else (24h, 7d: no rows kept) its log.
        model.clicked = { [weak self, unowned live] at, gap in
            if (self?.span ?? 3600) <= 3600, live.showsMoments { live.show(moment: at, gap: gap) } else { live.log(block.log, at: at) }
        }
        if let id = block.log, let a = live.tool.preset.actions?.first(where: { $0.spec.id == id }) {
            model.log = (a.spec.title ?? id, { [unowned live] at in live.log(id, at: at) })
        }
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

    /// The span the range control picked: the last hour unless longer.
    var span: Double { block.range.flatMap { $0.indices.contains(range.selectedSegment) ? $0[range.selectedSegment].seconds : nil } ?? 3600 }

    func update(_ live: ToolsLive) {
        let p = live.tool.preset, t = live.known, now = live.now, alerts = live.alerts, span = span
        if model.moment != live.moment { model.moment = live.moment }
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
        model.every = slots == nil ? (p.watch?.every ?? 60) * (live.app.tools.monitor.slow ? 3 : 1) : ToolSlots.length
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
                    .annotation(position: .overlay, alignment: .topLeading) {   // a week's nights are too narrow for words: the hover says them
                        if b.to.timeIntervalSince(b.from) >= model.data.to.timeIntervalSince(model.data.from) / 10 {
                            Text(Self.word(b.gap)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize().padding(2)
                        }
                    }
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
            if let m = model.moment, model.data.from <= m {   // the moment the tables show
                RuleMark(x: .value("Moment", m)).foregroundStyle(Color(nsColor: Palette.accent)).lineStyle(StrokeStyle(lineWidth: 1.5))
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
                            if model.hover != at { (model.hover, model.lastHover) = (at, at) }
                        case .ended: if model.hover != nil { model.hover = nil }
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { v in
                        guard let f = proxy.plotFrame, let d = proxy.value(atX: v.location.x - g[f].origin.x, as: Date.self) else { return }
                        model.clicked(d, chart.bands.first { $0.gap != .maintenance && $0.from <= d && d <= $0.to }?.gap)
                    })
                    .contextMenu {   // the hovered time's log, wherever a click goes
                        if let log = model.log, let h = model.hover ?? model.lastHover { Button("\(log.title) · \(h.formatted(date: .omitted, time: .standard))") { log.run(h) } }
                    }
            }
        }
    }
}

// MARK: Table

/// A `table` block (§6.3): a row set as the latest sample that carried it, in the block's columns (§5.2's formats, a
/// `bar` as one) — a list's ways (review 3): one row is the cursor, kept on its key through a sample or a sort; its row
/// gone, no cursor (a neighbour is another process). A header click sorts. The row's menu — a right-click, ⌃↩, ⇧F10,
/// its ⋯ — and its keys as its actions have them; ↩ and a double-click its `return` one; ⌘C the row as shown, Copy
/// Table all of it. Every action of a row goes down the one path (`ToolListSource.action`: the lock, production's
/// question, red for what can't be undone) with the row as it was shown when pressed. Under the pointer or a menu the
/// rows hold still: values change in place; a new order or set waits. Buttons only on the cursor's row and the one
/// under the pointer: two that can be undone, ⋯ the rest. The alerts' thresholds on its bars and cells; by its heading,
/// how often its rows come and when they came — dimmed once stale. Its sort and your columns (shown, order, widths)
/// kept per tool and table, as its height: as tall as its rows, or as you drag its grip (a double-click: its rows).
@MainActor final class ToolsTable: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, ToolsBlock {
    let block: ToolBlock
    let table = ToolsTableView()
    /// As shown: sorted, held while the pointer or a menu is over them.
    private(set) var rows: [ToolRow] = []
    /// As the latest sample has them, in its order.
    private var latest: [ToolRow] = []
    private let view: ToolListView
    private let source: ToolListSource
    private let heading = NSTextField(labelWithString: "")
    /// By the heading: how often its rows come, when they came; held, or stale.
    let note = NSTextField(labelWithString: "")
    private let height: NSLayoutConstraint
    /// The header and the rows; a legacy horizontal scroller adds its height (`layout`).
    private var fit: CGFloat = 48
    /// Under the table: its height as you drag it.
    let grip = ToolsGrip()
    /// "<tool>.<table>": what its height, sort and columns are kept by.
    private let name: String
    /// The height you dragged it to; nil: as tall as its rows.
    private var chosen: CGFloat?
    /// The height when the press began.
    private var dragFrom: CGFloat = 0
    /// The legacy scroller's height under a table wider than the block, the last layout.
    private var bar: CGFloat = 0
    private var tasks: [String: Task<Void, Never>] = [:]
    private var kept: [AnyObject] = []
    /// The cursor's row, by key.
    private var cursor: String?
    /// The pointer is over the rows (a test sets it): they hold still.
    var pointerInside = false {
        didSet {
            if !pointerInside { hover = nil }
            if oldValue != pointerInside { show() }
        }
    }
    private var menuOpen = false
    /// The row under the pointer: its buttons show.
    var hover: Int? { didSet { if hover != oldValue { redrawButtons() } } }
    /// The rows whose buttons show.
    private var buttoned = IndexSet()
    /// Rows came that wait for the pointer or the menu to go.
    private(set) var holding = false
    /// Held, rows changed under buttons left as drawn: they're drawn again once it lets go.
    private var buttonsBehind = false
    /// The alerts with your thresholds, and how they stand: the bars' and the cells' colors.
    private var alerts: [ToolAlert] = []
    private var standing = ToolAlerts()
    /// A column's metric — the preset's over these rows at that field — whose alert colors it.
    private let metricOf: [String: (id: String, metric: ToolMetric)]
    /// When its rows came, and how long after the rows before.
    private var at: Date?, every: TimeInterval?, stale = false
    /// A moment shows (`ToolsLive.moment`): its rows then — when they came, nil: nothing recorded — read only.
    private var past: (moment: Date, at: Date?)?
    private weak var live: ToolsLive?
    /// A moment shows rows of its own: some sample had them then.
    var recorded: Bool { past?.at != nil }
    /// Where ⌘C and Copy Table put the text.
    var pasteboard = NSPasteboard.general
    /// Its rows' cells drawn so far (tests: a sample draws only the rows it changed).
    private(set) var drawn = 0
    private var area: NSTrackingArea?

    private static let numbers: Set<String> = ["%", "bytes", "kbytes", "ms", "days"]

    init(_ live: ToolsLive, _ block: ToolBlock) {
        self.block = block
        // ponytail: a table with no `key` names its rows by their record, so a row's id changes with its numbers; System's say `{pid}` / `{mount}`.
        view = ToolListView(columns: block.columns, key: block.key)
        source = ToolListSource(live.app, live.tool, live.server, live.target)
        source.table = block.table
        self.live = live
        name = live.tool.preset.id + "." + (block.table ?? "")
        metricOf = Dictionary((live.tool.preset.metrics ?? [:]).compactMap { id, m in
            m.rows == block.table && m.key != nil ? m.path.map { ($0, (id: id, metric: m)) } : nil
        }) { a, _ in a }
        chosen = (UserDefaults.standard.dictionary(forKey: "toolsTableHeights")?[name] as? Double).map { CGFloat($0) }
        let scroll = NSScrollView()
        height = scroll.heightAnchor.constraint(equalToConstant: 48)
        super.init(frame: .zero)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.stringValue = block.title ?? block.table ?? ""
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        table.columnAutoresizingStyle = .noColumnAutoresizing   // before the columns: the first takes the slack (`layout`); past the width, it scrolls
        for c in block.columns ?? [] {
            let (field, format) = c.field, number = Self.numbers.contains(format ?? "")
            let col = NSTableColumn(identifier: .init(field))
            let fits = ["bytes", "kbytes"].contains(format ?? "") ? 72 : number ? 56 : format == "bar" ? 100 : 64   // "502.39 GB" whole
            (col.title, col.width, col.minWidth) = (c.title, c.width ?? Double(fits), table.tableColumns.isEmpty ? 80 : 40)   // the first names the row
            if number { col.headerCell.alignment = .right }
            col.headerToolTip = c.object?.help
            col.sortDescriptorPrototype = NSSortDescriptor(key: field, ascending: !(number || ["bar", "ago"].contains(format ?? "")))   // a number: the most first, as %CPU in Activity Monitor
            table.addTableColumn(col)
        }
        restoreColumns()
        if !actions.isEmpty {   // as wide as the two widest buttons a row shows, and ⋯
            let probe = NSButton(title: "", target: nil, action: nil)
            (probe.controlSize, probe.font) = (.small, .systemFont(ofSize: 11))
            func width(_ title: String) -> CGFloat { probe.title = title; return probe.intrinsicContentSize.width + 4 }
            let two = actions.filter { $0.spec.dangerous != true }.map { width($0.spec.title ?? $0.spec.id) }.sorted(by: >).prefix(2)
            let col = NSTableColumn(identifier: .init("actions"))
            col.title = ""
            col.width = two.reduce(6, +) + (actions.count > two.count ? width("⋯") : 0)
            col.minWidth = col.width
            table.addTableColumn(col)
        }
        if let saved = (UserDefaults.standard.dictionary(forKey: "toolsTableSort")?[name] as? String)?.split(separator: ":"), saved.count == 2,
           table.column(withIdentifier: .init(String(saved[0]))) >= 0 {   // a field the preset has no more: as the rows come
            table.sortDescriptors = [NSSortDescriptor(key: String(saved[0]), ascending: saved[1] == "1")]
        }
        table.dataSource = self
        table.delegate = self
        table.style = .plain   // no inset: the columns fill the block exactly; a scroller shows only for a table wider than it
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel(heading.stringValue)
        table.menu = NSMenu()   // a row's, made as it opens (`menuNeedsUpdate`)
        table.headerView?.menu = NSMenu()
        table.menu?.delegate = self
        table.headerView?.menu?.delegate = self
        (table.target, table.doubleAction) = (self, #selector(doubleClicked))
        table.onKey = { [unowned self] in key($0) }
        table.onCopy = { [unowned self] in copyRow() }
        table.onShowMenu = { [unowned self] in   // after the request's answer: an open menu holds the main thread
            guard rows.indices.contains(table.selectedRow) else { return false }
            let row = rows[table.selectedRow]   // the row as it is now, not whatever sits there by then
            DispatchQueue.main.async { [weak self] in self?.popUpMenu(row) }
            return true
        }
        scroll.documentView = table
        scroll.hasVerticalScroller = false   // the dashboard scrolls; the table only when dragged shorter than its rows (`layout`)
        scroll.hasHorizontalScroller = true   // a narrow window: the buttons stay reachable
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        // In the key window only: a pointer left over the window while you work elsewhere holds nothing.
        area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        scroll.addTrackingArea(area!)
        grip.began = { [unowned self] in dragFrom = height.constant }
        grip.drag = { [unowned self] by, done in
            chosen = max(oneRow, dragFrom + by)
            if done { keep() }
            needsLayout = true
        }
        grip.reset = { [unowned self] in
            chosen = nil
            keep()
            needsLayout = true
        }
        grip.setAccessibilityLabel("\(heading.stringValue) height")
        var top = [heading, ToolsWindow.spacer(), note]
        if let title = block.list {   // the tool's list, all its rows: All Processes…
            let all = NSButton(title: title, target: nil, action: nil)
            (all.controlSize, all.font) = (.small, .systemFont(ofSize: 11))
            let tool = live.tool, server = live.server, target = live.target, app = live.app
            kept.append(MenuAction.attach(to: all) { [weak self] in
                ToolListSource(app, tool, server, target).pick(over: self?.window ?? app.window)
            })
            top.insert(all, at: 1)
        }
        let head = NSStackView(views: top)
        let stack = NSStackView(views: [head, scroll, grip])
        (stack.orientation, stack.alignment, stack.spacing) = (.vertical, .leading, 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     head.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                                     grip.widthAnchor.constraint(equalTo: stack.widthAnchor), height])
        stack.setCustomSpacing(0, after: scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The first column as wide as the block leaves it, the others as set; a legacy scroller under a table wider
    /// than the block gets its height, so it hides no row. Your height, if you dragged one.
    override func layout() {
        super.layout()
        guard let first = table.tableColumns.first, let scroll = table.enclosingScrollView else { return }
        let shown = table.tableColumns.filter { !$0.isHidden }
        let rest = shown.dropFirst().reduce(0) { $0 + $1.width } + CGFloat(shown.count) * table.intercellSpacing.width
        let width = max(first.minWidth, scroll.contentView.bounds.width - rest)
        if abs(first.width - width) > 0.5 { first.width = width }
        bar = width + rest > scroll.contentView.bounds.width + 0.5 && scroll.scrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let want = chosen ?? fit + bar
        scroll.hasVerticalScroller = want < fit + bar - 0.5
        if abs(height.constant - want) > 0.5 { height.constant = want }
    }

    /// The least a drag leaves: the header and one row, and a scroller under them where one shows.
    private var oneRow: CGFloat { (table.headerView?.frame.height ?? 23) + table.rowHeight + table.intercellSpacing.height + 2 + bar }

    /// The dragged height kept for the next time (once, as the drag ends), or dropped.
    private func keep() {
        var all = UserDefaults.standard.dictionary(forKey: "toolsTableHeights") ?? [:]
        all[name] = chosen.map(Double.init)
        UserDefaults.standard.set(all, forKey: "toolsTableHeights")
    }

    private var actions: [ToolAction] { (block.actions ?? []).compactMap { id in source.preset.actions?.first { $0.spec.id == id } } }

    /// Its window no longer key: the rows don't hold for a window you've left.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window { NotificationCenter.default.addObserver(self, selector: #selector(left), name: NSWindow.didResignKeyNotification, object: window) }
    }
    @objc private func left() { pointerInside = false }

    // Its own area's only: a button's or a row's own come up the responder chain too.
    override func mouseEntered(with e: NSEvent) { if e.trackingArea === area { mouseMoved(with: e) } }
    override func mouseExited(with e: NSEvent) { if e.trackingArea === area { pointerInside = false } }
    /// The pointer over the rows: they hold — a move says so too, as no entry comes for a pointer already there when
    /// the window became key — and the row under it shows its buttons. By where it is: a move's event names no area.
    override func mouseMoved(with e: NSEvent) {
        guard let scroll = table.enclosingScrollView, scroll.bounds.contains(scroll.convert(e.locationInWindow, from: nil)) else { return }
        pointerInside = true
        let r = table.row(at: table.convert(e.locationInWindow, from: nil))
        hover = r >= 0 ? r : nil
    }

    // MARK: Rows

    func update(_ live: ToolsLive) {
        let scope = live.app.tools.scope(live.tool.preset, on: live.server, live.target), now = live.now, path = block.table ?? "", history = live.known?.history
        let was = past?.moment
        let then: ToolSample? = if let m = live.moment { history?.carried(path, at: m) } else { history?.carried(path) }
        past = live.moment.map { ($0, then?.at) }
        latest = (then?.rows(path) ?? []).map { record -> ToolRow in
            var r = view.row(record, scope, now: now)
            r.title = r.cells.first?.text ?? r.title   // the first column names the row in a question ("sleep"), its record is its key
            return r
        }
        // A new time is new rows: the time since the rows before, how often they come (procs every 15 s, disks 30 s) —
        // unknown after a gap (the Mac asleep, the tab away) till the next rows say it again.
        let came = history?.carried(path)?.at
        if came == nil { (at, every) = (nil, nil) }   // no rows since watching started again: no time to tell
        if let came, came != at {
            let since = at.map { came.timeIntervalSince($0) }
            every = since.flatMap { s in every.map { s <= 3 * $0 } ?? true ? s : nil }
            at = came
        }
        stale = live.state?.down != nil || (at.flatMap { a in every.map { now.timeIntervalSince(a) > 3 * $0 } } ?? false)
        let alerts = live.alerts, standing = live.known?.alerts ?? ToolAlerts()
        func marks(_ s: ToolAlerts) -> [String] { s.standing.map { "\($0.alert) \($0.key) \($0.state.level?.rawValue ?? 0)" } }
        let recolor = alerts != self.alerts || marks(standing) != marks(self.standing)
        (self.alerts, self.standing) = (alerts, standing)
        let moved = was != past?.moment   // to a moment or back: its rows now, under the pointer too, every row's buttons drawn again
        if moved { buttoned = [] }
        show(recolor: recolor || moved, thaw: moved)
        if moved { redrawButtons() }
    }

    /// The latest rows, sorted, into the table. Held — the pointer or a menu over them — the rows shown get their new
    /// values in place, the order and the set stay (a row gone keeps its last values: its action finds it ended);
    /// `thaw`: a sort you chose goes now anyway. Only what changed is drawn again.
    private func show(recolor: Bool = false, thaw: Bool = false) {
        let fresh = Self.sorted(latest, by: table.sortDescriptors.first)
        var next = fresh
        let held = !thaw && (pointerInside || menuOpen) && !rows.isEmpty
        if held {
            let now = Dictionary(fresh.map { ($0.key, $0) }) { a, _ in a }
            next = rows.map { now[$0.key] ?? $0 }
        }
        holding = next != fresh
        say()
        if next.map(\.key) == rows.map(\.key) {
            let changed = IndexSet(rows.indices.filter { recolor || rows[$0] != next[$0] })
            rows = next
            // Held, the buttons under the pointer stay as drawn — the same row's — so a press isn't lost to a sample.
            var columns = IndexSet(integersIn: 0..<table.numberOfColumns), buttons = table.column(withIdentifier: .init("actions"))
            if held, buttons >= 0 {
                columns.remove(buttons)
                buttonsBehind = buttonsBehind || !changed.isEmpty
            }
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: columns) }
            if !held, buttonsBehind, buttons >= 0 {
                buttonsBehind = false
                table.reloadData(forRowIndexes: buttoned, columnIndexes: [buttons])
            }
            return
        }
        let was = cursor
        (rows, buttoned, buttonsBehind) = (next, [], false)
        table.reloadData()
        let i = was.flatMap { k in rows.firstIndex { $0.key == k } }
        table.selectRowIndexes(i.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)   // its row gone: no cursor — a neighbour is another process
        cursor = i.map { rows[$0].key }
        redrawButtons()
        fit = (table.headerView?.frame.height ?? 23) + CGFloat(max(1, rows.count)) * (table.rowHeight + table.intercellSpacing.height) + 2
        needsLayout = true
    }

    /// `rows` by the field `d` sorts on: numbers by value, then text with no number as Finder sorts names, then nothing —
    /// those two after the numbers either way; equal ones by key, so the order doesn't flicker from sample to sample. No
    /// sort: as the stream sent them.
    static func sorted(_ rows: [ToolRow], by d: NSSortDescriptor?) -> [ToolRow] {
        guard let d, let field = d.key else { return rows }
        func cell(_ r: ToolRow) -> ToolRow.Cell? { r.cells.first { $0.field == field } }
        func rank(_ c: ToolRow.Cell?) -> Int { (c?.text ?? "").isEmpty ? 2 : c?.value?.number == nil ? 1 : 0 }
        return rows.sorted { a, b in
            let (x, y) = (cell(a), cell(b))
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            let c: ComparisonResult = if let p = x?.value?.number, let q = y?.value?.number { p < q ? .orderedAscending : p > q ? .orderedDescending : .orderedSame }
                else { (x?.text ?? "").localizedStandardCompare(y?.text ?? "") }
            return c == .orderedSame ? a.key.localizedStandardCompare(b.key) == .orderedAscending : d.ascending == (c == .orderedAscending)
        }
    }

    /// By the heading: "every 15 s · 11:31:05", "… · held under the pointer"; stale — no rows for three times their
    /// interval, or the server not answering — "as of 11:31:05", and the rows dimmed.
    private func say() {
        if let past {   // a moment: when its rows came, or that none did
            note.stringValue = past.at.map { "as of " + $0.formatted(date: .omitted, time: .standard) } ?? "nothing recorded at " + past.moment.formatted(date: .omitted, time: .standard)
            table.enclosingScrollView?.alphaValue = 1
            return
        }
        let time = at?.formatted(date: .omitted, time: .standard)
        note.stringValue = time.map { t in stale ? "as of \(t)" : [every.map { "every " + ToolAlerts.minutes($0.rounded()) }, t, holding ? (menuOpen ? "held while its menu is open" : "held under the pointer") : nil].compactMap { $0 }.joined(separator: " · ") } ?? ""
        table.enclosingScrollView?.alphaValue = stale ? 0.5 : 1
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, rows.indices.contains(row) else { return nil }
        let r = rows[row], id = column.identifier
        if id.rawValue == "actions" { return buttoned.contains(row) ? buttons(r) : nil }
        drawn += 1
        let cell = r.cells.first { $0.field == id.rawValue }, level = level(id.rawValue, r)
        let color = level == .critical ? Palette.fail : level == .warning ? Palette.warn : NSColor.labelColor
        if cell?.format == "bar" {
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? ToolsBarCell ?? ToolsBarCell(id)
            v.bar.isHidden = cell?.value?.number == nil
            v.bar.doubleValue = cell?.value?.number ?? 0
            ToolsLive.thresholds(metricOf[id.rawValue].flatMap { m in alerts.first { $0.metric == m.id && $0.below != true } }, on: v.bar)   // as a tile's: yours, as Thresholds… set them
            (v.text.stringValue, v.text.textColor) = (Self.shown(cell), color)
            return v
        }
        let l = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? label(id, right: column.headerCell.alignment == .right)
        (l.stringValue, l.textColor) = (Self.display(cell), color)
        l.toolTip = cell?.tip ?? cell?.text   // the column's `tip` (a process's command line): never copied
        return l
    }

    private func label(_ id: NSUserInterfaceItemIdentifier, right: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.identifier = id
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        l.lineBreakMode = .byTruncatingTail
        l.alignment = right ? .right : .left
        return l
    }

    /// A cell's text in its label: a number column with no value, "—" — not blank, not 0 (inodes on btrfs).
    static func display(_ c: ToolRow.Cell?) -> String {
        let text = c?.text ?? ""
        return text.isEmpty && numbers.contains(c?.format ?? "") ? "—" : text
    }

    /// A cell's text as shown: a bar's, its number.
    static func shown(_ c: ToolRow.Cell?) -> String {
        if c?.format == "bar", let n = c?.value?.number { return ToolTemplate.show(.number(n), "%") }
        return c?.text ?? ""
    }

    /// How the alert on `field`'s metric stands for row `r` — by the series its key names — as the tiles and events
    /// judge it (`below` too).
    private func level(_ field: String, _ r: ToolRow) -> ToolLevel? {
        guard let m = metricOf[field], let k = m.metric.key, let key = r.record[k]?.text else { return nil }
        return standing.level(metric: m.id, key: key, alerts: alerts)
    }

    // MARK: The cursor, buttons, menus and keys

    /// One row is the cursor, as in a list.
    func tableViewSelectionDidChange(_ notification: Notification) {
        cursor = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].key : nil
        redrawButtons()
    }

    /// Buttons on the cursor's row and the one under the pointer; only the rows that gain or lose them are drawn again.
    private func redrawButtons() {
        let col = table.column(withIdentifier: .init("actions"))
        guard col >= 0 else { return }
        let now = IndexSet([table.selectedRow, hover ?? -1].filter(rows.indices.contains))
        guard now != buttoned else { return }
        let redraw = now.symmetricDifference(buttoned).filteredIndexSet { $0 < rows.count }
        buttoned = now
        table.reloadData(forRowIndexes: redraw, columnIndexes: [col])
    }

    /// The row's actions, as `row` has them — the one source of its buttons, its menu and its keys: each runs down the
    /// path every action takes with this row's fields. An action this version doesn't run is greyed, saying so; one
    /// that's running, greyed till it's done.
    func rowActions(_ row: ToolRow) -> [ListAction] {
        guard past == nil else { return [] }   // a moment's rows are what was: no place for a signal
        let p = source.preset, id = source.rowID(row.key), known = source.app.tools.answers[ServerRow.key(source.target)]?.answer, monitor = source.app.tools.monitor
        return actions.filter { $0.offered(on: row.record) }.map { a in
            let title = a.spec.title ?? a.spec.id
            if a.spec.check == true, let s = monitor.server(source.target), let t = s.tools[p.id] {   // Check Now: the checks, at once
                return ListAction(title: title, key: a.spec.key.flatMap(Shortcut.init), group: 0, closes: false, why: nil,
                                  note: "Check every address now, from this Mac") { [weak s, weak t] _ in
                    if let s, let t { monitor.check(t, on: s) }
                    return nil
                }
            }
            guard ToolRunner.runs(a, of: p) else { return ListAction(title: title, group: 0, closes: false, why: "\(title): this version doesn't run it yet") { _ in nil } }
            var x = source.action(a, row: row, onRow: true, id: id, group: 0, keyed: known?.has(a, of: p) ?? (a.spec.requires == nil))
            if tasks[id + title] != nil { x.why = "\(title) is running" }
            return x
        }
    }

    /// `a` on `row` — the row as shown when its button, item or key was pressed. What can't run now beeps; what runs
    /// keeps its button greyed till it's done.
    private func run(_ a: ListAction, _ row: ToolRow) {
        guard a.why == nil, past == nil else { return NSSound.beep() }   // a moment's rows: whatever was drawn before it, nothing runs
        let k = source.rowID(row.key) + a.title
        guard let task = a.run(false) else { return }
        tasks[k] = task
        DispatchQueue.main.async { [weak self] in self?.redraw(row.key) }   // not under the pressed button's own action
        Task { [weak self] in
            await task.value
            self?.tasks[k] = nil
            self?.redraw(row.key)
        }
    }

    /// The buttons of row `key` again: one of its actions started or ended.
    private func redraw(_ key: String) {
        let col = table.column(withIdentifier: .init("actions"))
        guard col >= 0, let i = rows.firstIndex(where: { $0.key == key }), buttoned.contains(i) else { return }
        table.reloadData(forRowIndexes: [i], columnIndexes: [col])
    }

    /// The row's buttons: its first two actions that can be undone; ⋯ the rest — its menu — when there are more.
    private func buttons(_ row: ToolRow) -> NSView {
        let all = rowActions(row), shown = all.filter { !$0.dangerous }.prefix(2)
        let v = ToolsButtons()
        v.spacing = 4
        func button(_ title: String) -> NSButton {
            let b = NSButton(title: title, target: nil, action: nil)
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            v.addArrangedSubview(b)
            return b
        }
        for a in shown {
            let b = button(a.title)
            b.isEnabled = a.why == nil
            b.toolTip = a.why ?? a.command ?? a.note
            v.kept.append(MenuAction.attach(to: b) { [weak self] in self?.run(a, row) })
        }
        if all.count > shown.count {
            let more = button("⋯")
            more.toolTip = "More actions"
            more.setAccessibilityLabel("More actions")
            v.kept.append(MenuAction.attach(to: more) { [weak self, weak more] in
                guard let self, let more else { return }
                rowMenu(row).popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
            })
        }
        return v
    }

    /// The row's menu — ⋯'s, ⌃↩'s: its actions, then Copy and Copy Table.
    func rowMenu(_ row: ToolRow) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        fill(menu, row)
        return menu
    }

    /// A row's actions as a list's menu has them (`AppDelegate.actionItems`), then Copy and Copy Table; no row: Copy Table.
    private func fill(_ menu: NSMenu, _ row: ToolRow?) {
        menu.autoenablesItems = false
        if let row {
            let all = rowActions(row)
            AppDelegate.actionItems(all, key: \.key) { [weak self] in self?.run($0, row) }.forEach(menu.addItem)
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let copy = MenuAction.item("Copy") { [weak self] in self?.copy([row], header: false) }
            if !all.contains(where: { $0.key == Shortcut("cmd+c") }) { (copy.keyEquivalent, copy.keyEquivalentModifierMask) = ("c", .command) }
            menu.addItem(copy)
        }
        menu.addItem(MenuAction.item("Copy Table") { [weak self] in self?.copyTable() })
        if past != nil {
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("Back to Live") { [weak self] in self?.live?.show(moment: nil) })
        }
    }

    /// The header's menu: each column but the first (it names the row) to show or hide, then Copy Table.
    func fillHeader(_ menu: NSMenu) {
        menu.autoenablesItems = false
        for c in table.tableColumns.dropFirst() where c.identifier.rawValue != "actions" {
            let item = MenuAction.item(c.title) { [weak self] in
                c.isHidden.toggle()
                self?.keepColumns()
                self?.needsLayout = true
            }
            item.state = c.isHidden ? .off : .on
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(MenuAction.item("Copy Table") { [weak self] in self?.copyTable() })
    }

    /// A right-click's menu, on the row clicked — the cursor goes there — or the header's.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === table.menu {
            menu.removeAllItems()
            let r = table.clickedRow
            if rows.indices.contains(r) { table.selectRowIndexes([r], byExtendingSelection: false) }
            fill(menu, rows.indices.contains(r) ? rows[r] : nil)
        } else if menu === table.headerView?.menu {
            menu.removeAllItems()
            fillHeader(menu)
        }
    }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        show()
    }

    /// A key on the cursor's row: ⌃↩ or ⇧F10 its menu; ↩ its `return` action; another action's key that action; the
    /// rest the table's own (↑↓). A question over the window: nothing.
    private func key(_ e: NSEvent) -> Bool {
        if window?.attachedSheet != nil { return true }
        let k = Shortcut(event: e), r = table.selectedRow
        guard rows.indices.contains(r) else { return false }
        if Picker.menuKeys.contains(k) { popUpMenu(rows[r]); return true }
        if k == Shortcut("return") { open(r, beep: true); return true }
        // ↑↓ held down: no row's actions made for each repeat
        guard actions.contains(where: { $0.spec.key.flatMap(Shortcut.init) == k }), let a = rowActions(rows[r]).first(where: { $0.key == k }) else { return false }
        run(a, rows[r])
        return true
    }

    /// `row`'s menu, by the row — ⌃↩'s, VoiceOver's Show Menu — not wherever the pointer is; its row gone, none.
    private func popUpMenu(_ row: ToolRow) {
        guard let r = rows.firstIndex(where: { $0.key == row.key }) else { return }
        let rect = table.rect(ofRow: r)
        rowMenu(row).popUp(positioning: nil, at: NSPoint(x: rect.minX + 12, y: rect.maxY), in: table)
    }

    @objc private func doubleClicked() { open(table.clickedRow, beep: false) }

    /// ↩ or a double-click on row `r`: its `return` action; none — ↩ beeps, a click does nothing.
    func open(_ r: Int, beep: Bool) {
        guard rows.indices.contains(r), let a = rowActions(rows[r]).first(where: { $0.key == Shortcut("return") }) else { return beep ? NSSound.beep() : () }
        run(a, rows[r])
    }

    // MARK: Copy

    /// ⌘C: the cursor row's `cmd+c` action if it has one, as a list's; else the row as shown.
    private func copyRow() {
        guard rows.indices.contains(table.selectedRow) else { return NSSound.beep() }
        let row = rows[table.selectedRow]
        if let a = rowActions(row).first(where: { $0.key == Shortcut("cmd+c") }) { return run(a, row) }
        copy([row], header: false)
    }

    func copyTable() { copy(rows, header: true) }

    /// `rows` as shown — the columns shown, in their order, no buttons; a field no column shows never — tab-separated;
    /// `header`: the columns' titles above.
    func copy(_ rows: [ToolRow], header: Bool) {
        let cols = table.tableColumns.filter { !$0.isHidden && $0.identifier.rawValue != "actions" }
        let lines = (header ? [cols.map(\.title)] : []) + rows.map { r in cols.map { c in Self.shown(r.cells.first { $0.field == c.identifier.rawValue }) } }
        pasteboard.clearContents()
        pasteboard.setString(ListPanel.tsv(lines), forType: .string)
    }

    // MARK: Columns

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        var all = UserDefaults.standard.dictionary(forKey: "toolsTableSort") ?? [:]
        all[name] = tableView.sortDescriptors.first.map { "\($0.key ?? ""):\($0.ascending ? 1 : 0)" }
        UserDefaults.standard.set(all, forKey: "toolsTableSort")
        show(thaw: true)   // the order you chose, now — under the pointer too
    }

    /// The first column names the row and stays first; the buttons stay last.
    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        let end = table.column(withIdentifier: .init("actions")) >= 0 ? table.numberOfColumns - 1 : table.numberOfColumns
        return columnIndex > 0 && columnIndex < end && newColumnIndex != 0 && newColumnIndex < end
    }

    func tableViewColumnDidMove(_ notification: Notification) { keepColumns() }
    func tableViewColumnDidResize(_ notification: Notification) {
        guard notification.userInfo?["NSTableColumn"] as? NSTableColumn !== table.tableColumns.first else { return }   // the first's is what the others leave (`layout`)
        keepColumns()
        needsLayout = true
    }

    /// Your columns kept, a moment after the last change (a drag resizes many times).
    private func keepColumns() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveColumns), object: nil)
        perform(#selector(saveColumns), with: nil, afterDelay: 0.5)
    }

    /// Per tool and table (`toolsTableColumns`), after the first: in their order, "-cpu:56" — hidden, 56 pt.
    @objc private func saveColumns() {
        var all = UserDefaults.standard.dictionary(forKey: "toolsTableColumns") ?? [:]
        all[name] = table.tableColumns.dropFirst().filter { $0.identifier.rawValue != "actions" }.map { ($0.isHidden ? "-" : "") + $0.identifier.rawValue + ":\(Int($0.width))" }
        UserDefaults.standard.set(all, forKey: "toolsTableColumns")
    }

    /// Your columns as kept; a field the preset has no more is left out, a new one stays where the preset put it.
    private func restoreColumns() {
        var at = 1
        for s in UserDefaults.standard.dictionary(forKey: "toolsTableColumns")?[name] as? [String] ?? [] {
            let hidden = s.hasPrefix("-"), parts = s.dropFirst(hidden ? 1 : 0).split(separator: ":")
            let i = table.column(withIdentifier: .init(String(parts.first ?? "")))
            guard i > 0, at < table.numberOfColumns else { continue }
            let c = table.tableColumns[i]
            c.isHidden = hidden
            if parts.count > 1, let w = Double(parts[1]) { c.width = max(c.minWidth, w) }
            table.moveColumn(i, toColumn: at)
            at += 1
        }
    }
}

/// A dashboard table's own keys, and Edit ▸ Copy (`ToolsTable`).
@MainActor final class ToolsTableView: NSTableView {
    /// A key: true, it was the row's.
    var onKey: ((NSEvent) -> Bool)?
    var onCopy: (() -> Void)?
    /// VoiceOver's Show Menu on the table (its rows have none of their own): the cursor row's, by it; true, it was.
    var onShowMenu: (() -> Bool)?
    override func keyDown(with e: NSEvent) { if onKey?(e) != true { super.keyDown(with: e) } }
    @objc func copy(_ sender: Any?) { onCopy?() }
    override func accessibilityPerformShowMenu() -> Bool { onShowMenu?() == true || super.accessibilityPerformShowMenu() }
}


/// A row's buttons, holding what they run while they live.
@MainActor final class ToolsButtons: NSStackView {
    var kept: [AnyObject] = []
}

/// A `bar` cell: the level in its thresholds' colors, the number by it.
@MainActor final class ToolsBarCell: NSStackView {
    let bar = NSLevelIndicator(), text = NSTextField(labelWithString: "")

    init(_ id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        bar.levelIndicatorStyle = .continuousCapacity
        (bar.minValue, bar.maxValue) = (0, 100)
        bar.controlSize = .mini
        bar.isEditable = false
        bar.widthAnchor.constraint(equalToConstant: 44).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 8).isActive = true
        text.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        text.alignment = .right
        spacing = 4
        [bar, text].forEach(addArrangedSubview)
    }

    required init?(coder: NSCoder) { fatalError() }
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

/// The handle under a dashboard table: dragged up or down, the table's height goes with it — by how far the pointer
/// went since the press, so no step is lost however few layouts there are; a double-click, back to its rows (the
/// rest of that click drags nothing). A press that moves less than 3 pt is a click: it keeps nothing.
@MainActor final class ToolsGrip: NSView {
    /// A press: the height to drag from.
    var began: (() -> Void)?
    /// How much taller than at the press; `done`: let go.
    var drag: ((_ by: CGFloat, _ done: Bool) -> Void)?
    var reset: (() -> Void)?
    private var start: CGFloat?
    private var moved = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 16, y: bounds.midY - 1, width: 32, height: 2), xRadius: 1, yRadius: 1).fill()
    }

    override func mouseDown(with e: NSEvent) {
        (start, moved) = (e.clickCount >= 2 ? nil : e.locationInWindow.y, false)
        if e.clickCount >= 2 { reset?() } else { began?() }
    }
    override func mouseDragged(with e: NSEvent) {
        guard let start else { return }
        let by = start - e.locationInWindow.y   // the window's y grows up: down is taller
        guard moved || abs(by) >= 3 else { return }
        moved = true
        drag?(by, false)
    }
    override func mouseUp(with e: NSEvent) {
        if let start, moved { drag?(start - e.locationInWindow.y, true) }
        start = nil
    }
}
