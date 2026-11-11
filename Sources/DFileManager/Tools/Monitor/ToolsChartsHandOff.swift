import AppKit
import DFMCore
import SwiftUI

// MARK: Hand it on (review 4 PR 4)

/// What the charts hand on to a ticket or a colleague, only on a click — nothing is kept or worked out beforehand:
/// Copy Summary… (a text you can edit first; only Copy puts it on the clipboard), Export CSV… (the numbers, into a file
/// you name, written whole or not at all), Copy Image of the Charts. Each takes what's drawn (`Model.handed`); none
/// has a process row, a command line, a log or anything else the server said beside the series and their events.
extension ToolsCharts {
    /// Tests: where Export CSV… writes, given the file's name — nil: Cancel —, in place of the save panel.
    static var saving: ((String) -> URL?)?
    /// Tests: what Copy Summary's sheet gives back — the text as edited, nil: Cancel.
    static var editing: ((String) -> String?)?

    func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuAction.item("Export CSV…") { [weak self] in self?.exportCSV() })
        menu.addItem(MenuAction.item("Copy Image of the Charts") { [weak self] in self?.copyImage() })
        return menu
    }

    /// The page's result line under the tab.
    private func say(_ text: String, failed: Bool = false) { ToolsWindow.pages.first { $0.window === window }?.say(text, failed: failed) }

    // MARK: Copy Summary…

    /// The text, then the sheet to edit it; Copy puts it on the clipboard as edited — Cancel, ⎋: nothing.
    func copySummary() {
        guard let window, let live else { return }
        let text = Self.summary(model, server: live.server.title, production: live.server.prod, tool: live.tool.preset.title), r = model.handed.range
        Task {
            let edited = if let editing = Self.editing { editing(text) } else { await Self.summarySheet(text, on: window) }
            guard let edited else { return }
            pasteboard.clearContents()
            pasteboard.setString(edited, forType: .string)
            say("Copy Summary: copied · \(Self.length(r.upperBound.timeIntervalSince(r.lowerBound)))")
        }
    }

    /// What the charts show, as a person would say it: where and when, where the numbers come from; a line a chart —
    /// each series drawn with its average and highest, and when — ; the gaps, the events. No reasons made up.
    static func summary(_ m: Model, server: String, production: Bool, tool: String) -> String {
        let (r, charts) = m.handed
        var out = ["\(server)\(production ? " (production)" : "") · \(tool) · \(r.lowerBound.formatted(date: .abbreviated, time: .omitted)) \(m.words(r)) (\(zone(r.upperBound)))",
                   "Source: Kermo on this Mac, " + (m.history ? "15-minute slots: each one's average, lowest and highest; recorded only while watched."
                                                    : "a sample every \(Int(m.every)) s; recorded only while open or watched."), ""]
        for c in charts where !c.lines.isEmpty {
            out.append("\(c.title): " + c.lines.map { l in
                let name = c.series.count > 1 ? OneChart.short(l.name) + " " : "", text = l.metric.text
                guard let s = ToolExport.stats(within(l.points, r)) else { return name + "nothing recorded" }
                return name + (text(s.lowest) == text(s.highest) ? text(s.average)   // flat: one value
                               : "average \(text(s.average)), highest \(text(s.highest)) \(m.history ? "in" : "at") \(m.time(s.highestAt))")
            }.joined(separator: "; "))
        }
        var gaps: [String] = []
        for b in charts.flatMap(\.bands).sorted(by: { $0.from < $1.from }) where b.gap != .maintenance && b.from < r.upperBound && r.lowerBound < b.to {
            let g = "\(OneChart.word(b.gap)) \(m.words(max(b.from, r.lowerBound)...min(b.to, r.upperBound)))"
            if !gaps.contains(g) { gaps.append(g) }   // each chart has the tool's gaps
        }
        out += ["", "Gaps: " + (gaps.isEmpty ? "none" : gaps.joined(separator: "; "))]
        let events = m.data.events.filter { r.contains($0.at) }.reversed()
        out.append("Events:" + (events.isEmpty ? " none in this time (a tool keeps its last 40)" : ""))
        out += events.map { "  \($0.at.formatted(m.days ? .dateTime.weekday().hour().minute().second() : .dateTime.hour().minute().second())) \($0.level == "ok" ? "recovery" : $0.level) · \($0.message)" }
        return out.joined(separator: "\n")
    }

    private static func summarySheet(_ text: String, on window: NSWindow) async -> String? {
        let alert = AppDelegate.alert("Copy Summary", info: "What goes to the clipboard. Edit it first if a name shouldn't leave this Mac: server, mount and address "
                                      + "names are in it. Process rows, command lines and logs are never added.", ["Copy", "Cancel"])
        alert.alertStyle = .informational
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 240)
        scroll.borderType = .bezelBorder
        let tv = scroll.documentView as! NSTextView
        (tv.isRichText, tv.allowsUndo, tv.font, tv.textContainerInset) = (false, true, .monospacedSystemFont(ofSize: 11, weight: .regular), NSSize(width: 4, height: 6))
        // names as they are: no quotes curled, no word corrected
        (tv.isAutomaticQuoteSubstitutionEnabled, tv.isAutomaticDashSubstitutionEnabled, tv.isAutomaticTextReplacementEnabled) = (false, false, false)
        (tv.isAutomaticSpellingCorrectionEnabled, tv.isContinuousSpellCheckingEnabled) = (false, false)
        tv.string = text
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = tv
        return await AppDelegate.sheet(alert, on: window) == 0 ? tv.string : nil
    }

    // MARK: Export CSV…

    /// The numbers drawn into a file the save panel names — in Downloads unless you choose —, written whole or not
    /// at all (a temporary file, then renamed); "saved" only once it is, else why not.
    func exportCSV() {
        guard let window, let live else { return }
        let (r, charts) = model.handed, text = Self.csv(model), n = charts.reduce(0) { $0 + $1.lines.count }
        let name = Self.fileName(server: live.server.title, tool: live.tool.preset.title, at: r.lowerBound)
        Task {
            let url = if let saving = Self.saving { saving(name) } else { await Self.savePanel(name, on: window) }
            guard let url else { return }
            do { try Foundation.Data(text.utf8).write(to: url, options: .atomic) } catch { live.app.showError(error, on: window); return }
            say("Export CSV: saved \(url.lastPathComponent) · \(Self.length(r.upperBound.timeIntervalSince(r.lowerBound))) · \(n) series")
        }
    }

    /// Where to save `name`: in Downloads unless you choose; the panel asks before it replaces a file. nil: Cancel.
    private static func savePanel(_ name: String, on window: NSWindow) async -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        (panel.nameFieldStringValue, panel.allowedContentTypes) = (name, [.commaSeparatedText])
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }

    /// The CSV of what's drawn (`ToolExport.csv`): a line's metric and key from its id, "<metric> <key>".
    static func csv(_ m: Model, zone: TimeZone = .current) -> String {
        let (r, charts) = m.handed
        return ToolExport.csv(charts.flatMap { c in c.lines.map { l in
            let metric = l.id.prefix { $0 != " " }
            return ToolExport.Series(chart: c.title, metric: String(metric), key: String(l.id.dropFirst(metric.count + 1)), unit: l.metric.unit ?? "", points: within(l.points, r))
        } }, slot: m.history ? ToolSlots.length : nil, zone: zone)
    }

    /// "web-01-System-20261110-1400.csv": the server, the tool, where the time starts; no "/" or ":".
    static func fileName(server: String, tool: String, at: Date) -> String {
        let f = DateFormatter()
        (f.locale, f.dateFormat) = (Locale(identifier: "en_US_POSIX"), "yyyyMMdd-HHmm")
        return "\(server)-\(tool)-\(f.string(from: at)).csv".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    // MARK: Copy Image of the Charts

    /// The charts as a PNG and a TIFF on the clipboard — as wide as the block, at the screen's scale, in its appearance;
    /// none drawn: nothing copied. The image isn't kept.
    func copyImage() {
        guard let window, let live else { return }
        let d = model.data, n = model.handed.charts.count
        let about = "\(live.tool.preset.title) · \(d.from.formatted(date: .abbreviated, time: .omitted)) \(model.words(d.from...d.to)) · \(Self.zone(d.to))"
        guard let image = Self.picture(model, server: live.server.title, production: live.server.prod, about: about, width: bounds.width,
                                       scale: window.backingScaleFactor, appearance: effectiveAppearance),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation else {
            say("Copy Image: the charts couldn't be drawn — nothing copied", failed: true)
            return
        }
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(tiff, forType: .tiff)
        say("Copy Image: copied · \(Self.length(d.to.timeIntervalSince(d.from))) · \(n) chart\(n == 1 ? "" : "s")")
    }

    /// The charts drawn off screen from a copy of `m` with no pointer — no crosshair, no tip, no list open —; the
    /// moment and the selection stay: they were set on purpose.
    static func picture(_ m: Model, server: String, production: Bool, about: String, width: CGFloat, scale: CGFloat, appearance: NSAppearance) -> CGImage? {
        let still = Model()
        (still.data, still.every, still.history, still.focus, still.columns, still.wide) = (m.data, m.every, m.history, m.focus, m.columns, m.wide)
        (still.held, still.moment, still.selection) = (m.held, m.moment, m.selection)
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {   // Palette's and the system's colors as the window has them
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let r = ImageRenderer(content: ChartsPicture(model: still, server: server, production: production, about: about)
                .frame(width: width).environment(\.colorScheme, dark ? .dark : .light))
            (r.scale, r.proposedSize) = (scale, ProposedViewSize(width: width, height: nil))
            image = r.cgImage
        }
        return image
    }
}

/// Copy Image's charts: a line of where and when over them, a row of `columns` each (a stack, not the lazy grid: off
/// screen that draws nothing), each chart with its chips; the window's background behind, not clear.
struct ChartsPicture: View {
    let model: ToolsCharts.Model
    let server: String, production: Bool, about: String

    var body: some View {
        let charts = model.handed.charts, columns = charts.count == 1 ? 1 : max(1, model.columns)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Text(server).fontWeight(.semibold)
                if production { Text(" production").foregroundStyle(Color(nsColor: Palette.prod)) }
                Text(" · " + about).foregroundStyle(.secondary)
            }
            .font(.callout).lineLimit(1)
            ForEach(Array(stride(from: 0, to: charts.count, by: columns)), id: \.self) { i in
                HStack(alignment: .top, spacing: 14) {
                    ForEach(charts[i..<min(i + columns, charts.count)]) { OneChart(chart: $0, model: model, big: $0.id == model.focus, still: true).frame(maxWidth: .infinity) }
                    if charts.count - i < columns { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }   // the last row's one: half, as in the grid
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
