import AppKit
import Charts
import DFMCore
import SwiftUI

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
