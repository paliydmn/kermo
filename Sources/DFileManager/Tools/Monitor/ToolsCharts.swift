import AppKit
import Charts
import DFMCore
import SwiftUI

// MARK: Charts

/// A `charts` block: small multiples of the tool's series, two to a row where each gets 300 pt, else one — a line per
/// series key (six a metric, the first by name: "6 of 18" says the rest), never across a gap; the gaps as bands saying
/// why; the first metric's alert thresholds as lines; the events of the hour on the time axis; one time axis and one
/// crosshair for the block, the values under it in each chart's header — "Now", the moment the tables show, or the
/// time under the pointer — and beside it in the chart under the pointer, a tip with each series' name and value, the
/// gap, the events near and what a click does. On the last hour a click shows the tables then (`ToolsLive.show`),
/// else runs the `log` action with `{from}` / `{to}` five minutes around that moment. Swift Charts in an
/// NSHostingView over an ObservableObject the tab's update feeds (SwiftUI's @State is a macro the Command Line Tools
/// haven't). The hour in memory; `range`'s longer spans from the history on disk (`ToolSlots`): each 15-minute slot's
/// average with its min–max as a band round it, the gaps it wrote, "not watched" where it has nothing.
@MainActor final class ToolsCharts: NSView, ToolsBlock {
    /// What the charts draw: changed as one, so a sample draws the block once.
    struct Data {
        var charts: [Chart] = []
        var from = Date(), to = Date()
        var events: [ToolEventRecord] = []
        /// What a click on a chart does, in words; nil: nothing.
        var click: String?
    }
    struct Chart: Identifiable {
        let id: String, title: String, metric: ToolMetric, top: Double
        var lines: [Line]
        var bands: [ToolChart.Band]
        var warn, crit: Double?
        /// The series there are, drawn or not: more than `lines` past six a metric.
        var of = 0
        /// Why `at` has no values: the gap it's in (maintenance has values; at its end they're back).
        func gap(at t: Date) -> ToolGap? { bands.first { $0.gap != .maintenance && $0.from <= t && t < $0.to }?.gap }
        /// Why there are none now: the gap every line is in.
        var gapNow: ToolGap? { lines.allSatisfy { $0.points.last?.gap != nil } ? lines.first?.points.last?.gap : nil }
    }
    struct Line: Identifiable {
        let id: String, name: String
        let points: [ToolPoint]
        let chart: ToolChart
    }
    @MainActor final class Model: ObservableObject {
        @Published var data = Data()
        @Published var hover: Date?
        /// The chart under the pointer: the one with the tip.
        @Published var hovered: String?
        /// The moment the tables show (`ToolsLive.moment`): a line across each chart.
        @Published var moment: Date?
        /// Charts to a row: two where each gets `ToolsCharts.narrowest`.
        @Published var columns = 2
        var every: TimeInterval = 5
        /// A click at that time, in the clicked chart's band if it fell in one.
        var clicked: (Date, ToolGap?) -> Void = { _, _ in }
        /// The context menu's Log for This Time: its title, and the run; nil: the block has no `log`.
        var log: (title: String, run: (Date) -> Void)?
        /// The last time under the pointer: the context menu's, should the hover have ended as it opened.
        var lastHover: Date?
        /// Days on the axis: the week's.
        var days: Bool { data.to.timeIntervalSince(data.from) > 2 * 86400 }
        /// The slots on disk (24h, 7d), not the hour's samples.
        var history: Bool { every == ToolSlots.length }

        /// `t` as the charts say it: a sample's time to the second; the 15 minutes of its slot on the history.
        func time(_ t: Date) -> String {
            guard history else { return t.formatted(.dateTime.hour().minute().second()) }
            let t = Date(timeIntervalSince1970: ToolSlots.slot(t))
            return t.formatted(days ? .dateTime.weekday().hour().minute() : .dateTime.hour().minute()) + "–"
                + t.addingTimeInterval(ToolSlots.length).formatted(.dateTime.hour().minute())
        }
    }

    /// The narrowest a chart is drawn two to a row.
    static let narrowest: CGFloat = 300
    /// A row of charts: its header, its plot, the space under it.
    static let row: CGFloat = 176
    let block: ToolBlock
    let model = Model()
    /// The charts, while this block is on screen (`viewDidMoveToWindow`).
    private(set) var hosting: NSHostingView<ChartsView>?
    private let place = NSView()
    private let height: NSLayoutConstraint
    let range = NSSegmentedControl()
    /// The longer span's lines as last read, and the slot they were read in: a new slot may be on disk since.
    private var disk: (span: Double, slot: Double, lines: [ToolSlots.Line])?
    private var kept: AnyObject?

    init(_ live: ToolsLive, _ block: ToolBlock) {
        self.block = block
        height = place.heightAnchor.constraint(equalToConstant: CGFloat(((block.charts?.count ?? 0) + 1) / 2) * Self.row)
        super.init(frame: .zero)
        height.isActive = true
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
                range.setToolTip((r.seconds ?? 0) <= 3600 ? "The last hour, as watched" : "From the history on this Mac: 15-minute averages with their lowest and highest, while watched", forSegment: i)
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

    /// Two charts to a row where each gets `narrowest`, else one — one alone takes the row; as tall as its rows.
    /// The width comes from the page, never from the height: one more pass at most.
    override func layout() {
        super.layout()
        let n = block.charts?.count ?? 0, columns = n > 1 && bounds.width >= 2 * Self.narrowest + 14 ? 2 : 1
        if model.columns != columns { model.columns = columns }
        let tall = CGFloat((n + columns - 1) / columns) * Self.row
        if height.constant != tall { height.constant = tall }
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
            var lines: [Line] = [], of = 0
            for (id, m) in metrics {
                // ponytail: a line per series key, six a metric, the first by name (a set and colors that hold still)
                // — "6 of 18" says the rest; picking which, a design pass after 2.0 (D-191).
                let keys = slots.map { ToolSlots.keys($0, metric: id) } ?? t?.history.series[id]?.keys.sorted() ?? []
                of += max(1, keys.count)
                for key in (keys.isEmpty ? [""] : keys).prefix(6) {
                    let pts = slots.map { ToolSlots.points($0, metric: id, key: key, from: d.from) } ?? t?.history.points(id, key) ?? []
                    let name = key.isEmpty ? m.title ?? id : metrics.count > 1 ? "\(m.title ?? id) \(key)" : key   // two metrics' same key: two names
                    lines.append(Line(id: "\(id) \(key)", name: name, points: pts, chart: ToolChart(pts, now: now)))
                }
            }
            let alert = alerts.first { $0.metric == first.id && $0.below != true }   // the first metric's: CPU's beside I/O wait
            return Chart(id: ids.joined(separator: "+"), title: metrics.map { $0.metric.title ?? $0.id }.joined(separator: " · "), metric: first.metric,
                         top: ToolChart.top(lines.flatMap { $0.points.flatMap { [$0.value, $0.high].compactMap { $0 } } },
                                            max: first.metric.max ?? (first.metric.unit == "%" ? 100 : nil)),
                         lines: lines, bands: (lines.map(\.chart.bands).max { $0.count < $1.count } ?? []) + maintenance, warn: alert?.warn, crit: alert?.crit,
                         of: of)
        }
        d.events = ((t?.events ?? []) + (live.state?.events ?? [])).filter { $0.at >= d.from && $0.level != "ok" }
        d.click = span <= 3600 && live.showsMoments ? "Click: the tables at this time" : model.log.map { "Click: \($0.title)" }
        model.every = slots == nil ? (p.watch?.every ?? 60) * (live.app.tools.monitor.slow ? 3 : 1) : ToolSlots.length
        model.data = d
    }
}

struct ChartsView: View {
    @ObservedObject var model: ToolsCharts.Model

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: model.columns), alignment: .leading, spacing: 10) {
            ForEach(model.data.charts) { OneChart(chart: $0, model: model) }
        }
    }
}

/// One chart of the block; the crosshair and the time axis are the block's, the tip the chart's under the pointer.
struct OneChart: View {
    let chart: ToolsCharts.Chart
    @ObservedObject var model: ToolsCharts.Model
    /// Series colors in a fixed order (the first two: In · Out, read · write); red, orange, purple and green mean
    /// something else in Kermo.
    static let colors: [Color] = [.accentColor, Color(nsColor: .secondaryLabelColor), .teal, .indigo, .brown, .mint]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(chart.title).font(.caption.weight(.medium)).lineLimit(1)
                if chart.of > chart.lines.count {
                    Text("\(chart.lines.count) of \(chart.of)").font(.caption).foregroundStyle(.secondary)
                        .help("Lines for the first \(chart.lines.count) by name; the other \(chart.of - chart.lines.count) aren't drawn")
                }
                Spacer()
                Text(said).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            plot.frame(height: 150)
        }
        .accessibilityElement(children: .ignore)   // the marks and the tip aren't walked: an AX walk of them stalls
        .accessibilityLabel("\(chart.title): \(spoken)")
    }

    /// When the header's values are: under the pointer, the moment the tables show — or none, the latest.
    private var when: Date? { model.hover ?? model.moment }

    /// Each line's value at `t` (nil: the latest — on the history, the last slot's), as the metric says it.
    private func values(at t: Date?) -> [String] {
        chart.lines.map { line in
            let v = t.map { ToolChart.nearest(line.points, to: $0, within: model.every * 1.5)?.value }
                ?? (model.history ? line.points.last { $0.value != nil } : line.points.last)?.value
            return v.map(chart.metric.text) ?? "—"
        }
    }

    /// The header: the latest values "Now" — on the history, the last slot's, with its time —, else at the time under
    /// the pointer or "At" the moment the tables show; or why there are none (a gap).
    var said: String {
        if let t = when {
            let time = (model.hover == nil ? "At " : "") + model.time(t)
            return time + " · " + (chart.gap(at: t).map(Self.word) ?? values(at: t).joined(separator: " · "))
        }
        guard model.history else { return chart.gapNow.map { "Now · " + Self.word($0) } ?? "Now " + values(at: nil).joined(separator: " · ") }
        guard let last = chart.lines.compactMap({ $0.points.last { $0.value != nil }?.at }).max() else { return "—" }
        return model.time(last) + " · " + values(at: nil).joined(separator: " · ")
    }

    /// The header as VoiceOver says it: each value with its series' name.
    var spoken: String {
        let prefix = when.map { (model.hover == nil ? "At " : "") + model.time($0) } ?? (model.history ? "Last slot" : "Now")
        if let gap = when.map(chart.gap(at:)) ?? (model.history ? nil : chart.gapNow) { return prefix + ", " + Self.word(gap) }
        let v = values(at: when)
        return prefix + ", " + (chart.lines.count == 1 ? v.first ?? "—" : zip(chart.lines, v).map { "\($0.name) \($1)" }.joined(separator: ", "))
    }

    /// The tip at `t`: the time; a row a series — its color's index, name and value (on the history a slot's lowest,
    /// average and highest); notes: why there are none, the events near, the lines not drawn, what a click does.
    static func tip(_ chart: ToolsCharts.Chart, _ model: ToolsCharts.Model, at t: Date) -> (time: String, rows: [(color: Int, name: String, value: String)], notes: [String]) {
        let gap = chart.gap(at: t)
        var rows: [(color: Int, name: String, value: String)] = []
        for (i, line) in chart.lines.enumerated() where gap == nil {
            let p = ToolChart.nearest(line.points, to: t, within: model.every * 1.5), text = chart.metric.text
            if let p, let v = p.value, let lo = p.low, let hi = p.high { rows.append((i, line.name, "\(text(lo)) – \(text(v)) – \(text(hi))")) }
            else { rows.append((i, line.name, p?.value.map(text) ?? "—")) }
        }
        var notes: [String] = []
        if let gap { notes.append(word(gap).prefix(1).uppercased() + word(gap).dropFirst()) }
        if model.history, gap == nil { notes.append("Lowest – average – highest") }
        let near = max(model.every * 1.5, model.data.to.timeIntervalSince(model.data.from) / 100)
        let events = model.data.events.filter { abs($0.at.timeIntervalSince(t)) <= near }
        notes += events.prefix(3).map { "\($0.level.prefix(1).uppercased() + $0.level.dropFirst()) \($0.at.formatted(date: .omitted, time: .shortened)) · \($0.message)" }
        if events.count > 3 { notes.append("and \(events.count - 3) more events") }
        if chart.of > chart.lines.count { notes.append("\(chart.lines.count) of \(chart.of) drawn: the first by name") }
        if let click = model.data.click { notes.append(click) }
        return (model.time(t), rows, notes)
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

    private static func color(_ i: Int) -> Color { colors[i % colors.count] }

    private func tipView(_ t: Date) -> some View {
        let tip = Self.tip(chart, model, at: t)
        return VStack(alignment: .leading, spacing: 2) {
            Text(tip.time).fontWeight(.medium)
            ForEach(Array(tip.rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 4) {
                    Circle().fill(Self.color(r.color)).frame(width: 6, height: 6)
                    Text(r.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                    Spacer(minLength: 8)
                    Text(r.value).monospacedDigit()
                }
            }
            ForEach(Array(tip.notes.enumerated()), id: \.offset) { _, n in
                Text(n).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 260, alignment: .leading)
            }
        }
        .font(.caption)
        .fixedSize()
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }

    /// The gaps as bands, saying why where there's room.
    @ChartContentBuilder private var gapMarks: some ChartContent {
        ForEach(Array(chart.bands.enumerated()), id: \.offset) { _, b in
            RectangleMark(xStart: .value("From", b.from), xEnd: .value("To", b.to), yStart: .value("Bottom", 0), yEnd: .value("Top", chart.top))
                .foregroundStyle(Self.band(b.gap))
                .annotation(position: .overlay, alignment: .topLeading) {   // a week's nights are too narrow for words: the hover says them
                    if b.to.timeIntervalSince(b.from) >= model.data.to.timeIntervalSince(model.data.from) / 10 {
                        Text(Self.word(b.gap)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize().padding(2)
                    }
                }
        }
    }

    /// A slot's lowest to highest round its average (the history): under the lines, out of the legend.
    @ChartContentBuilder private var spreadMarks: some ChartContent {
        ForEach(Array(chart.lines.enumerated()), id: \.offset) { n, line in
            ForEach(Array(line.chart.runs.enumerated()), id: \.offset) { i, run in
                ForEach(Array(run.enumerated()), id: \.offset) { _, p in
                    if let lo = p.low, let hi = p.high {
                        AreaMark(x: .value("Time", p.at), yStart: .value("Lowest", min(lo, chart.top)), yEnd: .value("Highest", min(hi, chart.top)),
                                 series: .value("Band", "\(line.id) \(i) band"))
                            .foregroundStyle(Self.color(n).opacity(0.15))
                    }
                }
            }
        }
    }

    /// A line a run of each series; a lone value as a point.
    @ChartContentBuilder private var lineMarks: some ChartContent {
        ForEach(Array(chart.lines.enumerated()), id: \.offset) { n, line in
            ForEach(Array(line.chart.runs.enumerated()), id: \.offset) { i, run in
                if run.count == 1, let p = run.first {   // a lone value between gaps: a line of one point draws nothing
                    PointMark(x: .value("Time", p.at), y: .value(chart.title, min(p.value ?? 0, chart.top))).foregroundStyle(Self.color(n)).symbolSize(10)
                }
                ForEach(Array(run.enumerated()), id: \.offset) { _, p in   // by place: lines read together share one time
                    LineMark(x: .value("Time", p.at), y: .value(chart.title, min(p.value ?? 0, chart.top)), series: .value("Run", "\(line.id) \(i)"))
                        .foregroundStyle(by: .value("Series", line.name))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
        }
    }

    /// The thresholds, the events, the moment the tables show, the crosshair with its tip.
    @ChartContentBuilder private var ruleMarks: some ChartContent {
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
        if let h = model.hover {   // the tip on the side with room: the pointer on the line stays clear
            let right = h.timeIntervalSince(model.data.from) > model.data.to.timeIntervalSince(model.data.from) / 2
            RuleMark(x: .value("Time", h)).foregroundStyle(Color(nsColor: .secondaryLabelColor)).lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: right ? .leading : .trailing, alignment: .top, spacing: 6,
                            overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .fit(to: .chart))) {
                    if model.hovered == chart.id { tipView(h) }
                }
        }
    }

    private var plot: some View {
        Chart { gapMarks; spreadMarks; lineMarks; ruleMarks }
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
                                if model.hovered != chart.id { model.hovered = chart.id }
                            case .ended:   // into the next chart, its active may come first
                                if model.hovered == chart.id { (model.hover, model.hovered) = (nil, nil) }
                            }
                        }
                        .gesture(SpatialTapGesture().onEnded { v in
                            guard let f = proxy.plotFrame, let d = proxy.value(atX: v.location.x - g[f].origin.x, as: Date.self) else { return }
                            model.clicked(d, chart.gap(at: d))
                        })
                        .contextMenu {   // the hovered time's log, wherever a click goes
                            if let log = model.log, let h = model.hover ?? model.lastHover { Button("\(log.title) · \(h.formatted(date: .omitted, time: .standard))") { log.run(h) } }
                        }
                }
            }
    }
}
