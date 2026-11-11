import AppKit
import Charts
import DFMCore
import SwiftUI

// MARK: Charts

/// A `charts` block: small multiples of the tool's series, two to a row where each gets 300 pt, else one — a line per
/// series picked (the first six by name till you pick, six at most a chart, each keeping its color), never across a
/// gap; the gaps as bands saying why; the first metric's alert thresholds as lines; the window's events as marks at
/// the bottom of every chart — their level as a shape and a color, a faint line up, those closer than ~10 pt as one
/// with their count — and Events N ▾ listing them (review 4 PR 3); one time axis and one crosshair for the block. Under a chart of several series, a chip a series picked
/// with its value — "Now", the moment the tables show, or the time under the pointer, as the header says — a click
/// hides it, ⌥-click shows only it, "+N more…" lists the rest to pick; beside the pointer a tip with each series'
/// value, the gap, the events near and what a click does. Focus (⤢, a double-click on the header, F) shows one chart
/// big with all its series beside it, and its numbers as a table. Time (review 4 PR 2): a click is a moment — the
/// tables then (`ToolsLive.show`) on the last hour, a slot's numbers on the history —, a drag a stretch on every chart
/// with Zoom and its `log` under it; while you look the window holds still (new samples past its right edge, its scale
/// as it was) till Back to Live. Each gesture is a `Model` method the pointer, the keys (←/→, ⇧, ↩, F, ⎋ by
/// `ToolsLive.cancelOperation`) and the AX actions call alike. Swift Charts in an NSHostingView over an
/// ObservableObject the tab's update feeds (SwiftUI's @State is a macro the Command Line Tools haven't). The hour in
/// memory (15m its last quarter); `range`'s longer spans from the history on disk (`ToolSlots`): each 15-minute slot's
/// average with its min–max as a band round it, the gaps it wrote, "not watched" where it has nothing — and, watched,
/// the slot being filled (a ring at the line's end).
@MainActor final class ToolsCharts: NSView, ToolsBlock {
    /// What the charts draw: changed as one, so a sample draws the block once.
    struct Data {
        var charts: [Chart] = []
        var from = Date(), to = Date()
        /// The window's events, newest first: the tool's and watching's own — what Events N ▾ lists and the tip says.
        var events: [ToolEventRecord] = []
        /// What of them is drawn (decision 2026-11-10: the tool's but how things stood at the first sample, and watching's
        /// not answering and answers again), the close ones merged.
        var marks: [EventMark] = []
        /// What a click on a chart does, in words; nil: nothing.
        var click: String?
        /// On the history, in the window: the slot being filled, from its start to now — drawn past the slots written.
        var tail: ClosedRange<Date>?
    }
    struct Chart: Identifiable {
        let id: String, title: String, metric: ToolMetric, top: Double
        /// What's drawn: the series picked and not hidden, in their colors' order.
        var lines: [Line]
        /// Every series the chart has — its metrics in order, each one's keys by name — picked or not.
        var series: [Series] = []
        var bands: [ToolChart.Band]
        var warn, crit: Double?
        /// Its metrics' units differ: the axis is the first one's.
        var mixed = false
        /// The series picked — drawn, or hidden by a click on its chip — in their colors' order.
        var picked: [Series] { series.filter { $0.color != nil }.sorted { $0.color! < $1.color! } }
        /// Why `at` has no values: the gap it's in (maintenance has values; at its end they're back).
        func gap(at t: Date) -> ToolGap? { bands.first { $0.gap != .maintenance && $0.from <= t && t < $0.to }?.gap }
        /// Why there are none now: the gap every line is in.
        var gapNow: ToolGap? { lines.allSatisfy { $0.points.last?.gap != nil } ? lines.first?.points.last?.gap : nil }
    }
    /// One series a chart can draw: a metric's key — its line's id.
    struct Series: Identifiable {
        let id: String, name: String, metric: ToolMetric
        /// Its color's place in `OneChart.colors`: picked; nil: not.
        var color: Int?
        /// Picked, and hidden by a click on its chip.
        var hidden = false
        /// Its latest value: what the series list says beside it.
        var latest: Double?
    }
    /// Events drawn as one mark: the first one's time, the worst level, how many.
    struct EventMark: Equatable {
        let at: Date, level: String, count: Int
    }
    struct Line: Identifiable {
        let id: String, name: String
        let points: [ToolPoint]
        let chart: ToolChart
        var color = 0
        /// Its own metric, for its values' words: a chart's metrics may differ in unit.
        let metric: ToolMetric
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
        /// Room for two charts a row: Focus puts its series list beside the chart, not under it.
        @Published var wide = true
        /// The chart shown alone and big (Focus); nil: all of them.
        @Published var focus: String?
        /// Focus shows its chart's numbers as a table.
        @Published var showData = false
        /// The chart whose "+N more…" list is open.
        @Published var choosing: String?
        /// The series list's search.
        @Published var query = ""
        var every: TimeInterval = 5
        /// The window that stands while you look — a moment, a selection, Zoom: new samples come past its right edge
        /// and its scale stays (§6.3); nil: live, the latest at the right.
        @Published var held: ClosedRange<Date>?
        /// The stretch dragged across: on every chart of the block, its Zoom and log under the chart dragged on.
        @Published var selection: ClosedRange<Date>?
        /// The window held is a Zoom's: ⎋ on a selection keeps it.
        private(set) var zoomed = false
        /// The chart last clicked or dragged on: the selection's bar is under it, F focuses it.
        var active: String?
        /// The moment shows tables then (`ToolsLive.showsMoments`).
        var tables = false
        /// The moment to the tables (`ToolsLive.show`): the band it fell in, on the history its slot in words.
        var shown: (Date?, ToolGap?, String?) -> Void = { _, _, _ in }
        /// A click or a drag on a chart: the block takes the keys.
        var touched: () -> Void = {}
        /// Log for This Time: its title, and the run over a stretch; nil: the block has no `log`.
        var log: (title: String, run: (ClosedRange<Date>) -> Void)?
        /// Copy Summary… — the status row's, the selection's, the AX action's.
        var summarize: () -> Void = {}
        /// The longest stretch Log for This Time runs over (decision 2026-11-09): past it, zoom in first.
        static let longestLog: TimeInterval = 86400
        /// The last time under the pointer: the context menu's, should the hover have ended as it opened.
        var lastHover: Date?
        /// Days on the axis: the week's.
        var days: Bool { data.to.timeIntervalSince(data.from) > 2 * 86400 }
        /// The slots on disk (24h, 7d), not the hour's samples.
        var history = false
        /// Each chart's picks — a series' id → its color — as you made them; none (or none there now): the first six
        /// by name. Kept in the defaults under `keep`.
        private(set) var picks: [String: [String: Int]] = [:]
        /// Each chart's series hidden by a click on their chips: this window's, not kept.
        private(set) var hidden: [String: Set<String>] = [:]
        /// Where the picks are kept: "<server id> <tool id>"; nil (a test's model): nowhere. A color out of range (a
        /// hand edit) drops that pick.
        // ponytail: read once a block; two windows on one server and tool don't see each other's picks till rebuilt.
        var keep: String? {
            didSet {
                guard let keep else { return }
                for (k, v) in UserDefaults.standard.dictionary(forKey: Self.defaultsKey) ?? [:] where k.hasPrefix(keep + " ") {
                    if let v = v as? [String: Int] { picks[String(k.dropFirst(keep.count + 1))] = v.filter { (0..<ToolsCharts.most).contains($0.value) } }
                }
            }
        }
        /// ponytail: one dictionary for every server's picks; a server deleted leaves its few lines there.
        static let defaultsKey = "toolsChartSeries"
        /// The block's update, again: after a pick or a hide.
        var reload: () -> Void = {}
        /// The charts' height as laid out: the block takes it.
        var sized: (CGFloat) -> Void = { _ in }
        /// A chart's plot as wide as the grid lays it out (`layout()`): marks closer than 10 pt of it are one. Not
        /// published — a resize merges them anew on the next sample.
        // ponytail: the grid's width — Focus's wider plot merges as the grid does.
        var plotWidth: CGFloat = 400

        /// `t` as the charts say it: a sample's time to the second; the 15 minutes of its slot on the history.
        func time(_ t: Date) -> String {
            guard history else { return t.formatted(.dateTime.hour().minute().second()) }
            let t = Date(timeIntervalSince1970: ToolSlots.slot(t))
            return t.formatted(days ? .dateTime.weekday().hour().minute() : .dateTime.hour().minute()) + "–"
                + (t == data.tail?.lowerBound ? "now" : t.addingTimeInterval(ToolSlots.length).formatted(.dateTime.hour().minute()))
        }

        /// A chip's click: the series hidden or shown; `only`, every other picked one hidden — or, if it's that way
        /// already, all shown again.
        func toggle(_ id: String, in chart: Chart, only: Bool) {
            var h = hidden[chart.id] ?? []
            let picked = chart.picked.map(\.id)
            if only { h = picked.allSatisfy { ($0 == id) != h.contains($0) } ? [] : Set(picked.filter { $0 != id }) }
            else if h.contains(id) { h.remove(id) } else { h.insert(id) }
            hidden[chart.id] = h
            reload()
        }

        func showAll(in chart: Chart) {
            hidden[chart.id] = nil
            reload()
        }

        /// The series list's checkbox: `id` drawn in the first color free — six at most — or not drawn; one stays.
        /// Kept for this server and tool.
        func pick(_ id: String, in chart: Chart, _ on: Bool) {
            var p = Dictionary(uniqueKeysWithValues: chart.picked.map { ($0.id, $0.color!) })
            if on {
                guard p[id] == nil, p.count < ToolsCharts.most else { return }
                p[id] = (0...).first { c in !p.values.contains(c) }
            } else {
                guard p.count > 1 else { return }
                p[id] = nil
                hidden[chart.id]?.remove(id)
            }
            picks[chart.id] = p
            if let keep {
                var all = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) ?? [:]
                all["\(keep) \(chart.id)"] = p
                UserDefaults.standard.set(all, forKey: Self.defaultsKey)
            }
            reload()
        }

        /// Focus on a chart, or (nil) back to all of them.
        func show(focus id: String?) {
            (focus, showData, choosing, query) = (id, false, nil, "")
        }

        // MARK: Time — the pointer, the keys, the AX actions and the tests call these alike

        /// A stretch as the charts say it: to the second on the hour's samples, the slots' edges on the history.
        func words(_ r: ClosedRange<Date>) -> String {
            let f: Date.FormatStyle = !history ? .dateTime.hour().minute().second() : days ? .dateTime.weekday().hour().minute() : .dateTime.hour().minute()
            return r.lowerBound.formatted(f) + "–" + r.upperBound.formatted(f)
        }

        /// The times in the window with a value drawn, oldest first: what ←/→ step through.
        var samples: [Date] {   // on the history the slots' starts: a slot filled again after a sleep is one step
            Set(data.charts.flatMap(\.lines).flatMap { $0.points.compactMap { p in
                p.value != nil && data.from <= p.at && p.at <= data.to ? history ? Date(timeIntervalSince1970: ToolSlots.slot(p.at)) : p.at : nil
            } }).sorted()
        }

        /// ⇧←/⇧→: a minute's samples, on the history an hour's slots.
        var minute: Int { max(1, Int((history ? 3600 : 60) / every)) }

        /// The window as it is now, held: new samples come past its right edge.
        private func hold() { if held == nil { held = data.from...data.to } }

        private func put(_ m: Date?, _ gap: ToolGap? = nil) {
            moment = m
            shown(m, gap, m.flatMap { history ? time($0) : nil })
        }

        /// A moment — a click, a key, an AX action: the window held; the tables as they were then on the last hour,
        /// on the history the slot's numbers; `gap`: the band the click fell in.
        func inspect(at t: Date, gap: ToolGap? = nil) {
            hold()
            if selection != nil { selection = nil }   // a key press publishes once
            put(history ? Date(timeIntervalSince1970: ToolSlots.slot(t)) : t, gap)
        }

        /// `n` samples on from the moment (none: from the latest), slots on the history; over a gap to the next sample
        /// with values; at the window's edge it stays (decision 2026-11-09).
        func step(_ n: Int) {
            let times = samples
            guard let last = times.last, n != 0 else { return }
            let m = moment ?? last
            let i = n > 0 ? (times.firstIndex { $0 > m } ?? times.count) + n - 1 : (times.lastIndex { $0 < m } ?? -1) + n + 1
            inspect(at: times[min(max(i, 0), times.count - 1)])
        }

        /// A drag from `a` to `b` (either way): the stretch on every chart, the window held.
        func select(from a: Date, to b: Date) {
            hold()
            selection = min(a, b)...max(a, b)
            reload()
        }

        /// The selection gone — the window let go too, unless a moment or a Zoom holds it.
        func unselect() {
            selection = nil
            if moment == nil, !zoomed { held = nil }
            reload()
        }

        /// A click on `chart` at `raw`, `t` as the tip says it (on the history a slot's edge): a mark within `d` of `raw` —
        /// ≈6 pt (decision 2026-11-10) — is the moment at its time, its slot on the history; else `t`.
        func click(at t: Date, raw: Date, within d: TimeInterval, on chart: Chart) {
            let m = data.marks.map(\.at).filter { abs($0.timeIntervalSince(raw)) <= d }.min { abs($0.timeIntervalSince(raw)) < abs($1.timeIntervalSince(raw)) } ?? t
            inspect(at: m, gap: chart.gap(at: m))
        }

        /// The selection as the window: what was recorded there, no finer (a slot stays a slot); the moment let go.
        func zoom() {
            guard let s = selection else { return }
            (held, zoomed, selection) = (s, true, nil)
            put(nil)
        }

        /// Back to Live: the window follows the latest again; the moment, the selection and the Zoom let go.
        func backToLive() {
            if held != nil { held = nil }
            if selection != nil { selection = nil }
            zoomed = false
            put(nil)
        }

        /// ⎋, one step back: the series list, else the selection, else Focus, else Back to Live; false: nothing to undo.
        @discardableResult func escape() -> Bool {
            if choosing != nil { choosing = nil }
            else if selection != nil { unselect() }
            else if focus != nil { show(focus: nil) }
            else if held != nil || moment != nil { backToLive() }
            else { return false }
            return true
        }

        /// The time a log covers for `t`: its slot on the history, else five minutes round it.
        func around(_ t: Date) -> ClosedRange<Date> {
            guard history else { return t.addingTimeInterval(-ToolsLive.around)...t.addingTimeInterval(ToolsLive.around) }
            let s = Date(timeIntervalSince1970: ToolSlots.slot(t))
            return s...s.addingTimeInterval(ToolSlots.length)
        }

        /// The `log` over `r`; false: no `log`, no stretch, or one over a day.
        @discardableResult func runLog(_ r: ClosedRange<Date>?) -> Bool {
            guard let log, let r, r.upperBound.timeIntervalSince(r.lowerBound) <= Self.longestLog else { return false }
            log.run(r)
            return true
        }

        /// ↩, the AX action: the selection's log, else the moment's.
        @discardableResult func logNow() -> Bool { runLog(selection ?? moment.map(around)) }

        /// F: Focus on the chart under the pointer, else the one last clicked, else the first — or back to all of them.
        func focusKey() {
            let id = [hovered, active].compactMap { $0 }.first { id in data.charts.contains { $0.id == id } } ?? data.charts.first?.id
            show(focus: focus == nil ? id : nil)
        }

        /// What Copy Summary…, Export CSV… and Copy Image hand on (decision 2026-11-11: what's drawn): the selection,
        /// else the window; in Focus its chart alone, else all of them — each with its series drawn (`lines`).
        var handed: (range: ClosedRange<Date>, charts: [Chart]) {
            let focused = data.charts.filter { $0.id == focus }
            return (selection ?? data.from...data.to, focused.isEmpty ? data.charts : focused)
        }

        /// The chart the selection's bar is under: the one shown in Focus, the one dragged on, or the first.
        var barChart: String? { focus ?? (data.charts.contains { $0.id == active } ? active : data.charts.first?.id) }
    }

    /// The narrowest a chart is drawn two to a row.
    static let narrowest: CGFloat = 300
    /// A chart's plot: in the grid, in Focus.
    static let plotHeight: CGFloat = 150, focusHeight: CGFloat = 320
    /// The series a chart draws at most: more lines than this can't be told apart.
    static let most = 6
    let block: ToolBlock
    let model = Model()
    /// The charts, while this block is on screen (`viewDidMoveToWindow`).
    private(set) var hosting: NSHostingView<ChartsView>?
    private let place = NSView()
    private let height: NSLayoutConstraint
    let range = NSSegmentedControl()
    /// The range control's spans: the preset's, and 15m before its 1h — the hour's last quarter, no new data.
    let ranges: [ToolDuration]
    /// Live or inspecting, beside the range; Back to Live while inspecting; under them the window's length, what's
    /// recorded when, the zone.
    let status = NSTextField(labelWithString: "")
    private let dot = NSTextField(labelWithString: "●")
    let liveButton = NSButton(title: "Back to Live", target: nil, action: nil)
    /// At the right of the status: the window's events as a list.
    let eventsButton = NSButton(title: "Events 0", target: nil, action: nil)
    private let events = ToolsEventList()
    /// At the right: Copy Summary… and ⋯ (Export CSV…, Copy Image of the Charts).
    let summaryButton = NSButton(title: "Copy Summary…", target: nil, action: nil)
    let moreButton = NSButton(title: "", target: nil, action: nil)
    /// Where Copy Summary and Copy Image put what they copy (tests: their own).
    var pasteboard = NSPasteboard.general
    /// Its tab: the server, the tool, the page's result line.
    private(set) weak var live: ToolsLive?
    let sub = NSTextField(labelWithString: "")
    /// The longer span's lines as last read — from `from`, in the server's slot they were read in, with the slot being
    /// filled then: past either, a line may be on disk since.
    private var disk: (from: Date, slot: Double, under: Double?, lines: [ToolSlots.Line])?
    /// The hour as it was when you began to look at it: a held window keeps what the hour in memory trims meanwhile
    /// (≈1 MB, only while inspecting).
    private var frozen: ToolHistory?
    private var kept: [AnyObject] = []

    init(_ live: ToolsLive, _ block: ToolBlock) {
        self.block = block
        self.live = live
        var ranges = block.range ?? []
        if let i = ranges.firstIndex(where: { $0.seconds == 3600 }), !ranges.contains(where: { ($0.seconds ?? 3600) < 3600 }) { ranges.insert(.text("15m"), at: i) }
        self.ranges = ranges
        // Till the charts say how tall they are: a row of header, plot and chips each two charts.
        height = place.heightAnchor.constraint(equalToConstant: CGFloat(((block.charts?.count ?? 0) + 1) / 2) * (Self.plotHeight + 46))
        super.init(frame: .zero)
        height.isActive = true
        model.shown = { [unowned live] at, gap, slot in live.show(moment: at, gap: gap, slot: slot) }
        if let id = block.log, let a = live.tool.preset.actions?.first(where: { $0.spec.id == id }) {
            model.log = (a.spec.title ?? id, { [unowned live] r in live.log(id, from: r.lowerBound, to: r.upperBound) })
        }
        model.keep = "\(live.server.id.uuidString) \(live.tool.preset.id)"
        model.reload = { [weak self, unowned live] in self?.update(live) }
        model.touched = { [weak self] in if let self { window?.makeFirstResponder(self) } }
        model.sized = { [weak self] tall in   // the content's own height: chips may wrap, Focus is taller
            if let self, abs(height.constant - tall) > 0.5 { height.constant = tall }
        }
        if ranges.count > 1 {
            range.segmentCount = ranges.count
            for (i, r) in ranges.enumerated() {
                let s = r.seconds ?? 0
                range.setLabel(Self.label(r), forSegment: i)
                range.setToolTip(s < 3600 ? "The last \(ToolAlerts.minutes(s)) of the hour, as watched" : s == 3600 ? "The last hour, as watched"
                                 : "From the history on this Mac: 15-minute averages with their lowest and highest, while watched", forSegment: i)
            }
            range.selectedSegment = ranges.firstIndex { $0.seconds == 3600 } ?? 0
            range.controlSize = .small
            kept.append(MenuAction.attach(to: range) { [weak self] in self?.model.backToLive() })   // another range starts live (decision 2026-11-09)
        }
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        liveButton.controlSize = .small
        liveButton.toolTip = "The latest again, at the right (⎋)"
        kept.append(MenuAction.attach(to: liveButton) { [weak self] in self?.model.backToLive() })
        eventsButton.controlSize = .small
        eventsButton.image = Symbol.collapse.image().withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        eventsButton.imagePosition = .imageTrailing
        eventsButton.toolTip = "The events in this time — a click on one: the charts at that time"
        kept.append(MenuAction.attach(to: eventsButton) { [weak self, unowned live] in
            if let self { events.show(model.data.events, empty: "No events in this time", under: eventsButton, live: live, charts: self) }
        })
        summaryButton.controlSize = .small
        summaryButton.toolTip = "A short text of what the charts show — the selection's, else this time's — to edit, then copy"
        kept.append(MenuAction.attach(to: summaryButton) { [weak self] in self?.copySummary() })
        model.summarize = { [weak self] in self?.copySummary() }
        moreButton.controlSize = .small
        moreButton.image = Symbol.more.image("More")
        moreButton.toolTip = "Export CSV…, Copy Image of the Charts"
        moreButton.menu = moreMenu()   // AXShowMenu's too
        kept.append(MenuAction.attach(to: moreButton) { [weak self] in
            if let self, let menu = moreButton.menu { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 4), in: moreButton) }
        })
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = .tertiaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.font = .systemFont(ofSize: 9)
        dot.setAccessibilityElement(false)
        let head = NSStackView(views: (ranges.count > 1 ? [range] : []) + [dot, status, liveButton, ToolsWindow.spacer(), eventsButton, summaryButton, moreButton])
        head.setCustomSpacing(3, after: dot)
        let views: [NSView] = [head, sub, place]
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
            (model.hover, model.hovered, model.choosing) = (nil, nil, nil)   // gone with the pointer over it: no hover's end comes
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

    /// Two charts to a row where each gets `narrowest`, else one — one alone takes the row. The width comes from the
    /// page; the height from what the charts lay out (`model.sized`).
    override func layout() {
        super.layout()
        let wide = bounds.width >= 2 * Self.narrowest + 14, columns = (block.charts?.count ?? 0) > 1 && wide ? 2 : 1
        if model.wide != wide { model.wide = wide }
        if model.columns != columns { model.columns = columns }
        model.plotWidth = max(100, (bounds.width - CGFloat(columns - 1) * 14) / CGFloat(columns) - 60)   // the y axis's labels: ~60 pt
        if window?.firstResponder === self { noteFocusRingMaskChanged() }
    }

    // MARK: Keys — only while the block is first responder (a click on a chart, Tab); none global

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { convert(place.bounds, from: place) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill() }

    /// ←/→ a sample, ⇧ a minute (an hour on the history), ↩ Log for This Time, F Focus; the rest up the chain — ⎋ to
    /// `ToolsLive.cancelOperation`, its one owner.
    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift]), c = e.charactersIgnoringModifiers?.lowercased()
        if [123, 124].contains(e.keyCode), mods.isEmpty || mods == .shift { model.step((e.keyCode == 123 ? -1 : 1) * (mods.isEmpty ? 1 : model.minute)) }
        else if [36, 76].contains(e.keyCode), mods.isEmpty { if !model.logNow() { NSSound.beep() } }
        else if mods.isEmpty, c == "f" || (c?.first?.isASCII != true && e.keyCode == 3) { model.focusKey() }   // F in another script: its key
        else { super.keyDown(with: e) }
    }

    /// A range's segment: "15m", "1h", "24h".
    static func label(_ r: ToolDuration) -> String { switch r { case .text(let s): s; case .seconds(let s): ToolAlerts.minutes(s) } }

    /// The span the range control picked: the last hour unless another.
    var span: Double { ranges.indices.contains(range.selectedSegment) ? ranges[range.selectedSegment].seconds ?? 3600 : 3600 }

    /// A window's length in words: "45 s", "15 min", "1 h 50 min", "7 d".
    static func length(_ s: TimeInterval) -> String {
        let m = Int((s / 60).rounded())
        return s < 60 ? "\(Int(s.rounded())) s" : m < 60 ? "\(m) min" : s >= 2 * 86400 ? "\(Int((s / 86400).rounded())) d"
            : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// The zone the charts' times are in, with its offset then (decision 6: this Mac's, no switch): "UTC+02:00".
    static func zone(_ at: Date) -> String {
        let s = TimeZone.current.secondsFromGMT(for: at)
        return String(format: "UTC%@%02d:%02d", s < 0 ? "−" : "+", abs(s) / 3600, abs(s) % 3600 / 60)
    }

    /// `points` in the window, and the gap the window opens in at its start — its band and its "why" reach in.
    static func within(_ points: [ToolPoint], _ w: ClosedRange<Date>) -> [ToolPoint] {
        let i = points.firstIndex { $0.at >= w.lowerBound } ?? points.endIndex
        let gap = i > 0 && points[i - 1].gap != nil && points[i...].first?.at != w.lowerBound ? points[i - 1].gap : nil
        return (gap.map { [ToolPoint(at: w.lowerBound, gap: $0)] } ?? []) + points[i...].prefix { $0.at <= w.upperBound }
    }

    func update(_ live: ToolsLive) {
        let p = live.tool.preset, t = live.known, now = live.now, alerts = live.alerts, span = span
        if model.moment != live.moment { model.moment = live.moment }
        model.tables = live.showsMoments
        var d = Data()
        // The window: held while you look; else up to now — the hour in memory (15m its last quarter), or the history.
        (d.from, d.to) = model.held.map { ($0.lowerBound, $0.upperBound) } ?? (now.addingTimeInterval(-(span < 3600 ? span : max(span, t?.history.keep ?? 3600))), now)
        let window = d.from...d.to
        if model.held == nil || span > 3600 { frozen = nil } else if frozen == nil { frozen = t?.history }
        let hour = frozen ?? t?.history
        // Past the hour: the slots on disk from the range's start or the held window's, read again once a slot has passed.
        let written: [ToolSlots.Line]? = span <= 3600 ? nil : {
            let since = min(d.from, now.addingTimeInterval(-span))
            if let disk, disk.slot == ToolSlots.slot(now), disk.under == t?.slots.current?.t, disk.from <= since {   // 7d's lines serve 24h: from its start only
                let first = floor(since.timeIntervalSince1970 / ToolSlots.length) - 1   // as `read` keeps them: a slot's lines together
                return Array(disk.lines.drop { floor($0.t / ToolSlots.length) < first })
            }
            let lines = live.app.tools.monitor.written(live.server.id, tool: p.id, from: since)
            disk = (since, ToolSlots.slot(now), t?.slots.current?.t, lines)
            return lines
        }()
        // and the slot being filled, past the ones written, as its line will be (D-191 (8))
        var tail = written == nil ? nil : t?.slots.current
        if let c = tail, let last = written?.last, ToolSlots.slot(Date(timeIntervalSince1970: last.t)) > c.t { tail = nil }   // the server's clock went back past it
        let slots = written.map { lines in tail.map { lines + [$0] } ?? lines }
        d.tail = tail.map { Date(timeIntervalSince1970: $0.t) }.flatMap { window.contains($0) ? $0...max($0, now) : nil }
        // Maintenance over the values: by the server's clock, as the series are.
        let maintenance = live.state?.maintenance.flatMap { m -> [ToolChart.Band] in
            let skew = live.state?.skew ?? 0, from = max(m.from.addingTimeInterval(skew), d.from), to = min(m.until.addingTimeInterval(skew), d.to)
            return from < to ? [ToolChart.Band(from: from, to: to, gap: .maintenance)] : []
        } ?? []
        var since = 0   // samples with values past a held window's right edge
        d.charts = (block.charts ?? []).compactMap { ids -> Chart? in
            let metrics = ids.compactMap { id in p.metrics?[id].map { (id: id, metric: $0) } }
            guard let first = metrics.first else { return nil }
            let chartID = ids.joined(separator: "+")
            // Every series there is — a metric's keys by name; a metric with none, one line of its own.
            var series: [Series] = [], source: [String: (metric: String, key: String)] = [:]
            for (id, m) in metrics {
                let keys = slots.map { ToolSlots.keys($0, metric: id) } ?? hour?.series[id]?.keys.sorted() ?? []
                for key in keys.isEmpty ? [""] : keys where source["\(id) \(key)"] == nil {   // a metric named twice: once
                    let name = key.isEmpty ? m.title ?? id : metrics.count > 1 ? "\(m.title ?? id) \(key)" : key   // two metrics' same key: two names
                    series.append(Series(id: "\(id) \(key)", name: name, metric: m))
                    source["\(id) \(key)"] = (id, key)
                }
            }
            // The picks there are now; none: the first six by name, their colors by place.
            let saved = (model.picks[chartID] ?? [:]).filter { source[$0.key] != nil }
            let colors = saved.isEmpty ? Dictionary(uniqueKeysWithValues: series.prefix(Self.most).enumerated().map { ($1.id, $0) }) : saved
            let hidden = model.hidden[chartID] ?? []
            var lines: [Line] = []
            for i in series.indices {
                let s = series[i], (metric, key) = source[s.id]!
                series[i].color = colors[s.id]
                series[i].hidden = colors[s.id] != nil && hidden.contains(s.id)
                guard let color = series[i].color, !series[i].hidden else {   // not drawn: its latest only, for the list
                    series[i].latest = slots.map { $0.last { $0.v?[metric]?[key]?.count == 3 }?.v?[metric]?[key]?[1] }
                        ?? t?.history.series[metric]?[key]?.last { $0.value != nil }?.value
                    continue
                }
                // now's, and what the window shows: on a held hour the hour as it was
                let fresh = slots.map { ToolSlots.points($0, metric: metric, key: key, from: d.from) } ?? t?.history.points(metric, key) ?? []
                let pts = Self.within(slots == nil ? hour?.points(metric, key) ?? [] : fresh, window)
                series[i].latest = fresh.last { $0.value != nil }?.value
                if let held = model.held { since = max(since, fresh.count(where: { held.upperBound < $0.at && $0.value != nil })) }
                lines.append(Line(id: s.id, name: s.name, points: pts, chart: ToolChart(pts, now: d.to), color: color, metric: s.metric))
            }
            lines.sort { $0.color < $1.color }
            let alert = alerts.first { $0.metric == first.id && $0.below != true }   // the first metric's: CPU's beside I/O wait
            return Chart(id: chartID, title: metrics.map { $0.metric.title ?? $0.id }.joined(separator: " · "), metric: first.metric,
                         // by the window's averages: a burst's high would flatten every line; its band is cut at the top, the tip says it
                         top: ToolChart.top(lines.flatMap { $0.points.compactMap(\.value) },
                                            max: first.metric.max ?? (first.metric.unit == "%" ? 100 : nil)),
                         lines: lines, series: series, bands: (lines.map(\.chart.bands).max { $0.count < $1.count } ?? []) + maintenance,
                         warn: alert?.warn, crit: alert?.crit, mixed: Set(metrics.map { $0.metric.unit ?? "" }).count > 1)
        }
        let tool = (t?.events ?? []).filter { window.contains($0.at) }, server = (live.state?.events ?? []).filter { window.contains($0.at) }
        d.events = (tool + server).sorted { $0.at > $1.at }
        d.marks = Self.marks(tool.filter { !$0.found } + server.filter { $0.level == "critical" || $0.level == "ok" },
                             within: d.to.timeIntervalSince(d.from) * 10 / model.plotWidth)
        d.click = (slots != nil ? "Click: this slot's numbers" : live.showsMoments ? "Click: the tables at this time" : "Click: the values at this time") + " · drag: a stretch"
        model.every = slots == nil ? (p.watch?.every ?? 60) * (live.app.tools.monitor.slow ? 3 : 1) : ToolSlots.length
        model.history = slots != nil
        model.data = d
        say(since: model.zoomed ? 0 : since, running: live.running)
        let n = "Events \(d.events.count)"
        if eventsButton.title != n { eventsButton.title = n }
    }

    /// The marks `events` make: oldest first, each one closer than `within` to the first of a mark merged into it.
    static func marks(_ events: [ToolEventRecord], within: TimeInterval) -> [EventMark] {
        var groups: [[ToolEventRecord]] = []
        for e in events.sorted(by: { $0.at < $1.at }) {
            if let first = groups.last?.first, e.at.timeIntervalSince(first.at) < within { groups[groups.count - 1].append(e) } else { groups.append([e]) }
        }
        return groups.map { g in EventMark(at: g[0].at, level: ["critical", "warning", "ok"].first { l in g.contains { $0.level == l } } ?? "info", count: g.count) }
    }

    /// The status beside the range — live, or what's inspected and the samples come since — and under it the window's
    /// length, what's recorded when, and the zone the times are in.
    private func say(since: Int, running: Bool) {
        let m = model, d = m.data, inspecting = m.held != nil || m.moment != nil, text: String
        if inspecting {
            text = "Inspecting " + (m.moment.map { "at " + m.time($0) } ?? m.words(d.from...d.to))
                + (since > 0 ? " · \(since) new \(m.history ? "slot" : "sample")\(since == 1 ? "" : "s") since" : "")
        } else {
            text = (running ? "Live · " : "Paused · ") + (m.history ? "15-minute slots from this Mac's history" : "a sample every \(Int(m.every)) s")
        }
        // set only when changed: a label set each sample lays the page out again
        let (mark, color) = inspecting ? ("◼", Palette.accent) : ("●", running ? Palette.ok : NSColor.tertiaryLabelColor)
        if dot.stringValue != mark { dot.stringValue = mark }
        if dot.textColor != color { dot.textColor = color }
        if status.stringValue != text { status.stringValue = text }
        if liveButton.isHidden == inspecting { liveButton.isHidden = !inspecting }
        let below = [Self.length(d.to.timeIntervalSince(d.from)), m.history ? "each point a slot's average, the band its lowest to highest" + (d.tail == nil ? "" : ", the last one so far") : nil,
                     m.history ? "recorded only while watched" : "recorded only while open or watched", Self.zone(d.to)].compactMap { $0 }.joined(separator: " · ")
        if sub.stringValue != below { sub.stringValue = below }
    }
}

/// The charts' height as laid out, for the block's constraint.
private struct ChartsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ChartsView: View {
    @ObservedObject var model: ToolsCharts.Model

    var body: some View {
        charts
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in Color.clear.preference(key: ChartsHeight.self, value: g.size.height) })
            .onPreferenceChange(ChartsHeight.self) { tall in MainActor.assumeIsolated { model.sized(tall) } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var charts: some View {
        if let id = model.focus, let chart = model.data.charts.first(where: { $0.id == id }) {
            FocusView(chart: chart, model: model)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: model.columns), alignment: .leading, spacing: 10) {
                ForEach(model.data.charts) { OneChart(chart: $0, model: model) }
            }
        }
    }
}

/// One chart alone and big, its series beside it (under it where the block is narrow); Data: its numbers.
struct FocusView: View {
    let chart: ToolsCharts.Chart
    @ObservedObject var model: ToolsCharts.Model

    var body: some View {
        if model.wide {
            HStack(alignment: .top, spacing: 12) { OneChart(chart: chart, model: model, big: true); Divider(); side.frame(width: 220) }
        } else {
            VStack(alignment: .leading, spacing: 10) { OneChart(chart: chart, model: model, big: true); side }
        }
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SwiftUI.Picker("Show", selection: $model.showData) { Text("Chart").tag(false); Text("Data").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text("\(chart.picked.count) of \(chart.series.count) drawn").font(.caption).foregroundStyle(.secondary)
            }
            SeriesList(id: chart.id, model: model)
        }
        .frame(height: model.wide ? ToolsCharts.focusHeight + 22 : 260, alignment: .top)
    }
}

/// A chart's series to pick: a checkbox each with its color and latest value, found by a search past eight.
struct SeriesList: View {
    let id: String
    @ObservedObject var model: ToolsCharts.Model

    /// The series the search finds: all of them up to eight, where there's no search field.
    static func found(_ chart: ToolsCharts.Chart, _ q: String) -> [ToolsCharts.Series] {
        chart.series.count <= 8 || q.isEmpty ? chart.series : chart.series.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        if let chart = model.data.charts.first(where: { $0.id == id }) {
            let picked = chart.picked.count, q = model.query.trimmingCharacters(in: .whitespaces), found = Self.found(chart, q)
            VStack(alignment: .leading, spacing: 6) {
                if chart.series.count > 8 { TextField("Find among \(chart.series.count)", text: $model.query).textFieldStyle(.roundedBorder) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(found) { s in
                            Toggle(isOn: Binding(get: { s.color != nil }, set: { model.pick(s.id, in: chart, $0) })) {
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 1).fill(s.color.map(OneChart.color) ?? .clear).frame(width: 10, height: 3)
                                    Text(OneChart.short(s.name)).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text(s.hidden ? "hidden" : s.latest.map(s.metric.text) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(s.color == nil ? picked >= ToolsCharts.most : picked == 1)
                            .help(s.name)
                        }
                        if found.isEmpty { Text("No series match “\(q)”").foregroundStyle(.secondary) }
                    }
                }
                Text("Six drawn at most: uncheck one to draw another. One not drawn is still watched, and still alerts.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        }
    }
}

/// Chips side by side, onto the next line where the width ends.
struct Flow: Layout {
    var spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in rows(subviews, width: bounds.width) {   // centered in its row: a caption beside a button
            for (i, x, size) in row.items { subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: ProposedViewSize(size)) }
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(y: CGFloat, width: CGFloat, height: CGFloat, items: [(Int, CGFloat, CGSize)])] {
        var rows: [(y: CGFloat, width: CGFloat, height: CGFloat, items: [(Int, CGFloat, CGSize)])] = []
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, items: [(Int, CGFloat, CGSize)] = []
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(ProposedViewSize(width: width, height: nil))   // a long name is cut, not wider than the row
            if !items.isEmpty, x + size.width > width {
                rows.append((y, x - spacing, height, items))
                (x, y, height, items) = (0, y + height + spacing, 0, [])
            }
            items.append((i, x, size))
            (x, height) = (x + size.width + spacing, max(height, size.height))
        }
        if !items.isEmpty { rows.append((y, x - spacing, height, items)) }
        return rows
    }
}

/// One chart of the block; the crosshair and the time axis are the block's, the tip the chart's under the pointer.
struct OneChart: View {
    let chart: ToolsCharts.Chart
    @ObservedObject var model: ToolsCharts.Model
    /// In Focus: taller, its series in the list beside it, Data in place of the plot.
    var big = false
    /// Copy Image's: no buttons — ⤢, the selection's bar, "+N more…".
    var still = false
    /// Series colors in a fixed order (the first two: In · Out, read · write); red, orange, purple and green mean
    /// something else in Kermo.
    static let colors: [Color] = [.accentColor, Color(nsColor: .secondaryLabelColor), .teal, .indigo, .brown, .mint]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 2) {
                head
                if big && model.showData { DataTable(chart: chart, model: model).frame(height: ToolsCharts.focusHeight) }
                else { plot.frame(height: big ? ToolsCharts.focusHeight : ToolsCharts.plotHeight) }
            }
            .accessibilityElement(children: .ignore)   // the marks and the tip aren't walked: an AX walk of them stalls
            .accessibilityLabel("\(chart.title): \(spoken)" + { n in n == 0 ? "" : ", \(n) event\(n == 1 ? "" : "s")" }(model.data.events.count))
            .accessibilityActions {   // a chart's click and keys without the pointer (D-166 (6))
                Button(big ? "Show All Charts" : "Focus") { model.show(focus: big ? nil : chart.id) }
                Button("Previous Sample") { model.step(-1) }
                Button("Next Sample") { model.step(1) }
                if model.tables, !model.history, !chart.lines.isEmpty {
                    Button("Show Tables at This Time") {
                        if let t = model.hover ?? model.moment ?? model.samples.last { model.inspect(at: t, gap: chart.gap(at: t)) }
                    }
                }
                if model.log != nil, model.selection != nil || model.moment != nil { Button("Log for This Time") { model.logNow() } }
                Button("Copy Summary") { model.summarize() }
                if model.held != nil || model.moment != nil { Button("Back to Live") { model.backToLive() } }
            }
            if let s = model.selection, model.barChart == chart.id, !still { selected(s) }
            if chart.series.count > 1 { legend }
        }
    }

    /// Under the chart dragged on: the stretch and how long, Zoom, its log — a day at most —, Copy Summary…, ✕; onto a
    /// second line where the chart is narrow.
    private func selected(_ s: ClosedRange<Date>) -> some View {
        let long = s.upperBound.timeIntervalSince(s.lowerBound)
        return Flow(spacing: 6) {
            Text("\(model.words(s)) · \(ToolsCharts.length(long))").font(.caption.monospacedDigit()).lineLimit(1)
            Button("Zoom") { model.zoom() }.help("This stretch across the charts — as recorded, no finer")
            if let log = model.log {
                Button(log.title) { model.runLog(s) }.disabled(long > ToolsCharts.Model.longestLog)
                    .help(long > ToolsCharts.Model.longestLog ? "Zoom in to 24 hours or less" : "\(log.title) for this stretch")
            }
            Button("Copy Summary…") { model.summarize() }.help("A short text of what the charts show in this stretch, to edit, then copy")
            Button { model.unselect() } label: { Image(systemName: "xmark").font(.caption) }.buttonStyle(.borderless).help("Clear (⎋)")
                .accessibilityLabel("Clear Selection")
        }
        .controlSize(.small)
    }

    private var head: some View {
        HStack(spacing: 6) {
            Text(chart.title).font(.caption.weight(.medium)).lineLimit(1)
            if chart.series.count > chart.picked.count {
                Text("\(chart.picked.count) of \(chart.series.count)").font(.caption).foregroundStyle(.secondary)
                    .help("\(chart.picked.count) of \(chart.series.count) series drawn: “+\(chart.series.count - chart.picked.count) more…” under the chart picks others")
            }
            if chart.mixed {
                Text("units differ").font(.caption).foregroundStyle(.secondary)
                    .help("Its series aren't in one unit: the axis is \(chart.metric.title ?? "the first")'s; each value is said in its own")
            }
            Spacer()
            Text(said).font(.caption.monospacedDigit()).foregroundStyle(model.hover == nil && model.moment != nil ? Color.accentColor : .secondary).lineLimit(1)
            if !still {
                Button { model.show(focus: big ? nil : chart.id) } label: {
                    Image(systemName: big ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").font(.caption)
                }
                .buttonStyle(.borderless)
                .help(big ? "Back to all the charts" : "Focus: this chart big, with all its series")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.show(focus: big ? nil : chart.id) }
    }

    /// A chip a series picked — its color, name and value when the header says — then "+N more…" (Focus: its list beside).
    private var legend: some View {
        Flow {
            ForEach(chart.picked) { s in chip(s) }
            if chart.series.count > chart.picked.count, !big, !still {
                Button("+\(chart.series.count - chart.picked.count) more…") { (model.query, model.choosing) = ("", chart.id) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor).padding(.horizontal, 4)
            }
        }
        // On the legend, not the button: the last series ticked takes the button away, not the list under the pointer.
        .popover(isPresented: Binding(get: { model.choosing == chart.id && !big }, set: { if !$0, model.choosing == chart.id { model.choosing = nil } }),
                 arrowEdge: .bottom) {
            SeriesList(id: chart.id, model: model)
                .frame(width: 320, height: min(300, CGFloat(chart.series.count) * 24 + (chart.series.count > 8 ? 100 : 64))).padding(10)
        }
    }

    private func chip(_ s: ToolsCharts.Series) -> some View {
        let v = s.hidden ? "" : value(s)
        return Button { model.toggle(s.id, in: chart, only: NSEvent.modifierFlags.contains(.option)) } label: {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1).fill(Self.color(s.color ?? 0)).frame(width: 10, height: 3)
                Text(Self.short(s.name)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                if !s.hidden {   // as wide as the widest value it may say: the chips hold still as the pointer moves
                    ZStack(alignment: .leading) { Text(Self.widest(s.metric, chart.top)).hidden(); Text(v) }.monospacedDigit()
                }
            }
            .opacity(s.hidden ? 0.45 : 1)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption)
        .help(s.hidden ? "\(s.name): hidden — a click shows it" : "\(s.name) — a click hides it, ⌥-click shows only it")
        .contextMenu {
            Button("Only This") { model.toggle(s.id, in: chart, only: true) }
            Button("Show All") { model.showAll(in: chart) }
            if !big { Button("Choose Series…") { (model.query, model.choosing) = ("", chart.id) } }
        }
        .accessibilityLabel(s.hidden ? "\(s.name), hidden" : "\(s.name) \(v)")
    }

    /// A series' name where room is short: an address without its http(s)://; the whole in its tooltip.
    static func short(_ name: String) -> String {
        for scheme in ["https://", "http://"] where name.hasPrefix(scheme) { return String(name.dropFirst(scheme.count)) }
        return name
    }

    /// The widest text a value of `metric` under `top` may take, roughly: its top's, each digit an 8, one more.
    static func widest(_ metric: ToolMetric, _ top: Double) -> String {
        "8" + String(metric.text(top).map { $0.isNumber ? "8" : $0 })
    }

    /// When the header's values are: under the pointer, the moment the tables show — or none, the latest.
    private var when: Date? { model.hover ?? model.moment }

    /// `line`'s value at `t` (nil: the latest — on the history, or a window held, the last value in it), in its
    /// metric's words.
    private func value(_ line: ToolsCharts.Line, at t: Date?) -> String {
        let v = t.map { ToolChart.nearest(line.points, to: $0, within: model.every * 1.5)?.value }
            ?? (model.history || model.held != nil ? line.points.last { $0.value != nil } : line.points.last)?.value
        return v.map(line.metric.text) ?? "—"
    }

    /// A chip's value: its line's when the header says.
    func value(_ s: ToolsCharts.Series) -> String { chart.lines.first { $0.id == s.id }.map { value($0, at: when) } ?? "—" }

    /// The header's when — "Now", on the history or a window held its last value's time, the time under the pointer,
    /// "At" the moment the tables show — the time its values are at (nil: the latest), and the gap that has none.
    private var header: (when: String, at: Date?, gap: ToolGap?) {
        if let t = when { return ((model.hover == nil ? "At " : "") + model.time(t), t, chart.gap(at: t)) }
        guard model.history || model.held != nil else { return ("Now", nil, chart.gapNow) }
        return (chart.lines.compactMap { $0.points.last { $0.value != nil }?.at }.max().map(model.time) ?? "", nil, nil)
    }

    /// The header as shown: "Now 24%", "9:28:45 PM · Mac asleep" — a chart of several series, only when: its chips
    /// have the values.
    var said: String {
        let h = header, v = h.gap.map(Self.word) ?? (chart.series.count > 1 ? "" : chart.lines.map { value($0, at: h.at) }.joined(separator: " · "))
        return h.when == "Now" && h.gap == nil && !v.isEmpty ? "Now " + v : [h.when, v].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The header as VoiceOver says it: each value with its series' name.
    var spoken: String {
        let h = header
        let v = h.gap.map(Self.word) ?? (chart.lines.count == 1 ? chart.lines.first.map { value($0, at: h.at) } ?? "—"
                                         : chart.lines.map { "\($0.name) \(value($0, at: h.at))" }.joined(separator: ", "))
        return [h.when, v].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The tip at `t`: the time; a row a series drawn — its color, name and value (on the history a slot's lowest,
    /// average and highest); notes: why there are none, the events near, the series not drawn, what a click does.
    static func tip(_ chart: ToolsCharts.Chart, _ model: ToolsCharts.Model, at t: Date) -> (time: String, rows: [(color: Int, name: String, value: String)], notes: [String]) {
        let gap = chart.gap(at: t)
        var rows: [(color: Int, name: String, value: String)] = [], spread = false
        for line in chart.lines where gap == nil {
            let p = ToolChart.nearest(line.points, to: t, within: model.every * 1.5), text = line.metric.text
            if let p, let v = p.value, let lo = p.low, let hi = p.high { rows.append((line.color, line.name, "\(text(lo)) – \(text(v)) – \(text(hi))")); spread = true }
            else { rows.append((line.color, line.name, p?.value.map(text) ?? "—")) }
        }
        var notes: [String] = []
        if let gap { notes.append(word(gap).prefix(1).uppercased() + word(gap).dropFirst()) }
        if chart.bands.contains(where: { $0.gap == .maintenance && $0.from <= t && t < $0.to }) { notes.append("Maintenance") }
        if spread { notes.append("Lowest – average – highest") }
        let near = max(model.every * 1.5, model.data.to.timeIntervalSince(model.data.from) / 100)
        let events = model.data.events.filter { abs($0.at.timeIntervalSince(t)) <= near }
        notes += events.prefix(3).map { "\($0.level == "ok" ? "Recovery" : $0.level.prefix(1).uppercased() + $0.level.dropFirst()) \($0.at.formatted(date: .omitted, time: .shortened)) · \($0.message)" }
        if events.count > 3 { notes.append("and \(events.count - 3) more") }
        if chart.series.count > chart.picked.count { notes.append("\(chart.picked.count) of \(chart.series.count) drawn: “more…” under the chart picks others") }
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
        Color(nsColor: s == "critical" ? Palette.fail : s == "warning" ? Palette.warn : s == "ok" ? Palette.ok : .tertiaryLabelColor)
    }

    /// An event mark's shape — its level told without the color: ◆ critical, ▲ warning, ● info (✓ back to normal: a symbol).
    private static func shape(_ s: String) -> BasicChartSymbolShape { s == "critical" ? .diamond : s == "warning" ? .triangle : .circle }

    static func color(_ i: Int) -> Color { colors[i % colors.count] }

    private func tipView(_ t: Date) -> some View {
        let tip = Self.tip(chart, model, at: t)
        return VStack(alignment: .leading, spacing: 2) {
            Text(tip.time).fontWeight(.medium)
            ForEach(Array(tip.rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 4) {
                    Circle().fill(Self.color(r.color)).frame(width: 6, height: 6)
                    Text(Self.short(r.name)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
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
        ForEach(chart.lines) { line in
            ForEach(Array(line.chart.runs.enumerated()), id: \.offset) { i, run in
                ForEach(Array(run.enumerated()), id: \.offset) { _, p in
                    if let lo = p.low, let hi = p.high {
                        AreaMark(x: .value("Time", p.at), yStart: .value("Lowest", min(lo, chart.top)), yEnd: .value("Highest", min(hi, chart.top)),
                                 series: .value("Band", "\(line.id) \(i) band"))
                            .foregroundStyle(Self.color(line.color).opacity(0.15))
                    }
                }
            }
        }
    }

    /// A line a run of each series; a lone value as a point.
    @ChartContentBuilder private var lineMarks: some ChartContent {
        ForEach(chart.lines) { line in
            ForEach(Array(line.chart.runs.enumerated()), id: \.offset) { i, run in
                if run.count == 1, let p = run.first {   // a lone value between gaps: a line of one point draws nothing
                    PointMark(x: .value("Time", p.at), y: .value(chart.title, min(p.value ?? 0, chart.top))).foregroundStyle(Self.color(line.color)).symbolSize(10)
                }
                if let p = run.last, Date(timeIntervalSince1970: ToolSlots.slot(p.at)) == model.data.tail?.lowerBound {   // the slot being filled: a ring — it isn't over
                    PointMark(x: .value("Time", p.at), y: .value(chart.title, min(p.value ?? 0, chart.top)))
                        .symbol { Circle().strokeBorder(Self.color(line.color), lineWidth: 1.5).frame(width: 7, height: 7) }
                }
                ForEach(Array(run.enumerated()), id: \.offset) { _, p in   // by place: lines read together share one time
                    LineMark(x: .value("Time", p.at), y: .value(chart.title, min(p.value ?? 0, chart.top)), series: .value("Run", "\(line.id) \(i)"))
                        .foregroundStyle(by: .value("Series", line.name))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
        }
    }

    /// The events at the bottom, a faint line up from each; a merged mark's count beside it.
    @ChartContentBuilder private var eventMarks: some ChartContent {
        ForEach(Array(model.data.marks.enumerated()), id: \.offset) { _, m in
            RuleMark(x: .value("Event", m.at)).foregroundStyle(Self.level(m.level).opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            if m.level == "ok" {
                PointMark(x: .value("Event", m.at), y: .value("Bottom", 0))
                    .symbol { Image(systemName: Symbol.check.rawValue).font(.system(size: 8, weight: .heavy)).foregroundStyle(Self.level(m.level)) }
                    .offset(y: -5).count(m.count)
            } else {
                PointMark(x: .value("Event", m.at), y: .value("Bottom", 0))
                    .symbol(Self.shape(m.level)).symbolSize(m.level == "info" ? 16 : 40).foregroundStyle(Self.level(m.level))
                    .offset(y: -5).count(m.count)
            }
        }
    }

    /// The thresholds, the moment the tables show, the crosshair with its tip.
    @ChartContentBuilder private var ruleMarks: some ChartContent {
        if let w = chart.warn, w <= chart.top {
            RuleMark(y: .value("Warning", w)).foregroundStyle(Color(nsColor: Palette.warn)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        if let c = chart.crit, c <= chart.top {
            RuleMark(y: .value("Critical", c)).foregroundStyle(Color(nsColor: Palette.fail)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        if let s = model.selection {   // the stretch dragged across, on every chart
            RectangleMark(xStart: .value("From", max(s.lowerBound, model.data.from)), xEnd: .value("To", min(s.upperBound, model.data.to)),
                          yStart: .value("Bottom", 0), yEnd: .value("Top", chart.top))
                .foregroundStyle(Color(nsColor: Palette.accent).opacity(0.15))
        }
        if let m = model.moment, model.data.from <= m, m <= model.data.to {   // the moment the tables show
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
        Chart {
            gapMarks
            if model.history { spreadMarks }
            lineMarks
            eventMarks
            ruleMarks
        }
        .chartXScale(domain: model.data.from...model.data.to)
        .chartYScale(domain: 0...chart.top)
        .chartForegroundStyleScale(domain: chart.lines.map(\.name), range: chart.lines.map { Self.color($0.color) })
        .chartLegend(.hidden)   // the chips under it, or Focus's list
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, chart.top / 2, chart.top]) { v in
                AxisGridLine()
                // one width, so the charts one under another share their time axis; the top one under its line, clear of the title
                AxisValueLabel(anchor: v.index == v.count - 1 ? .topTrailing : nil) {
                    if let d = v.as(Double.self) { Text(chart.metric.text(d)).frame(minWidth: 50, alignment: .trailing) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: big ? 5 : 4)) { v in
                AxisGridLine()
                // none at the right edge (15m, a Zoom): there it's cut to "…"
                if let t = v.as(Date.self), model.data.to.timeIntervalSince(t) > model.data.to.timeIntervalSince(model.data.from) / 15 {
                    AxisValueLabel(format: model.days ? .dateTime.weekday().hour() : .dateTime.hour().minute())
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { g in
                // The time at `x`, in the window — snapped to a sample (a slot's edge on the history), or as it is.
                let at = { (x: CGFloat, snap: Bool) -> Date? in
                    guard let f = proxy.plotFrame, let d = proxy.value(atX: x - g[f].origin.x, as: Date.self) else { return nil }
                    let t = snap ? Date(timeIntervalSince1970: (d.timeIntervalSince1970 / model.every).rounded() * model.every) : d
                    return min(max(t, model.data.from), model.data.to)
                }
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in   // snapped to a sample, published only when it moves to another: a move redraws the block
                        switch phase {
                        case .active(let p):
                            guard let t = at(p.x, true) else { return }
                            if model.hover != t { (model.hover, model.lastHover) = (t, t) }
                            if model.hovered != chart.id { model.hovered = chart.id }
                        case .ended:   // into the next chart, its active may come first
                            if model.hovered == chart.id { (model.hover, model.hovered) = (nil, nil) }
                        }
                    }
                    // Under 4 pt a click — the moment; past it a drag — the stretch, published only as a snapped end moves.
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard abs(v.translation.width) >= 4, let a = at(v.startLocation.x, true), let b = at(v.location.x, true), a != b else { return }
                            model.active = chart.id
                            if model.selection != min(a, b)...max(a, b) { model.selection = min(a, b)...max(a, b) }
                        }
                        .onEnded { v in
                            model.active = chart.id
                            model.touched()
                            if abs(v.translation.width) >= 4, let a = at(v.startLocation.x, true), let b = at(v.location.x, true), a != b { model.select(from: a, to: b) }
                            else if let t = at(v.location.x, model.history), let raw = at(v.location.x, false) {   // a mark ≈6 pt off: its time
                                let perPoint = proxy.plotFrame.map { model.data.to.timeIntervalSince(model.data.from) / max(1, g[$0].width) } ?? 0
                                model.click(at: t, raw: raw, within: 6 * perPoint, on: chart)
                            }
                        })
                    .contextMenu {   // the hovered time's log, wherever a click goes
                        if let log = model.log, let h = model.hover ?? model.lastHover { Button("\(log.title) · \(model.time(h))") { log.run(model.around(h)) } }
                    }
            }
        }
    }
}

/// Focus's Data: the chart's numbers, newest first — a row a time any series drawn has a value or a gap at, a column a
/// series (on the history a slot's lowest – average – highest), and why there's none.
struct DataTable: View {
    let chart: ToolsCharts.Chart
    @ObservedObject var model: ToolsCharts.Model

    static func rows(_ chart: ToolsCharts.Chart, time: (Date) -> String) -> [(time: String, values: [String], note: String)] {
        let byTime = chart.lines.map { Dictionary($0.points.map { ($0.at, $0) }) { a, _ in a } }
        return Set(chart.lines.flatMap { $0.points.map(\.at) }).sorted(by: >).map { t in
            let pts = byTime.map { $0[t] }
            let values = zip(chart.lines, pts).map { line, p -> String in
                let text = line.metric.text
                guard let p, let v = p.value else { return "—" }
                if let lo = p.low, let hi = p.high { return "\(text(lo)) – \(text(v)) – \(text(hi))" }
                return text(v)
            }
            return (time(t), values, pts.compactMap { $0?.gap }.first.map(OneChart.word) ?? "")
        }
    }

    var body: some View {
        let rows = Self.rows(chart, time: model.time)
        ScrollView([.vertical, .horizontal]) {   // more series than the width holds: sideways
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                Section(header: row(model.history ? "15 minutes" : "Time", chart.lines.map { OneChart.short($0.name) }, "", head: true)) {
                    ForEach(rows.indices, id: \.self) { i in row(rows[i].time, rows[i].values, rows[i].note).background(i % 2 == 1 ? Color(nsColor: .alternatingContentBackgroundColors[1]) : .clear) }
                }
            }
        }
        .font(.caption.monospacedDigit())
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func row(_ time: String, _ values: [String], _ note: String, head: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(time).frame(width: model.history ? 150 : 90, alignment: .leading)
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                Text(v).lineLimit(1).truncationMode(.middle).frame(width: model.history ? 130 : 80, alignment: .trailing)
            }
            Text(note).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
        }
        .fontWeight(head ? .medium : .regular)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(head ? Color(nsColor: .windowBackgroundColor) : .clear)
    }
}

private extension ChartContent {
    /// Beside a mark of several events, how many; a mark of one has no annotation.
    @ChartContentBuilder func count(_ n: Int) -> some ChartContent {
        if n > 1 { annotation(position: .trailing, alignment: .center, spacing: 1) { Text("\(n)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) } }
        else { self }
    }
}
