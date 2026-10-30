import AppKit
import DFMCore

/// An action's form (protocol §7.4): its inputs' values, each checked as you type — empty where it may not be, its
/// `pattern` (the whole value), a value that would be an option — and what will run with them ("Will run:", a secret
/// as •••). A `choice-from` input's choices are read as the form opens: loading, then them, or why not.
@MainActor
final class ToolForm {
    enum Choices { case loading, ready([String]), failed(String) }
    let action: ToolAction, tool: LoadedTool, scope: ToolTemplate.Scope
    var inputs: [ToolInput] { action.spec.inputs ?? [] }
    private(set) var values: [String: String] = [:]
    private(set) var choices: [String: Choices] = [:]
    /// The choices' reads; done, they've said.
    private(set) var loading: Task<Void, Never>?
    private let reads = CancelFlag()
    var onChange: (() -> Void)?

    /// `scope`: the names around it (the row's, the tool's); an input's `default` may use them. `filled`: values to
    /// start from instead (Retry's; never a secret).
    init(_ a: ToolAction, of tool: LoadedTool, _ scope: ToolTemplate.Scope, filled: [String: String]? = nil) {
        (action, self.tool, self.scope) = (a, tool, scope)
        for i in inputs {
            switch i.info.type {
            case .choice: values[i.info.name] = i.info.default ?? i.info.options?.first ?? ""
            case .choiceFrom: (values[i.info.name], choices[i.info.name]) = ("", .loading)
            default: values[i.info.name] = i.info.default.map { ToolTemplate.text($0, scope) } ?? ""
            }
            if i.info.type != .secret, let v = filled?[i.info.name] { values[i.info.name] = v }
        }
    }

    func set(_ name: String, _ value: String) {
        values[name] = value
        onChange?()
    }

    /// Why `i`'s value won't do, or nil.
    func problem(_ i: ToolInput) -> String? {
        let v = values[i.info.name] ?? ""
        switch choices[i.info.name] {
        case .failed(let why)?: return why
        case .loading?: return "reading the choices…"
        default: break
        }
        if v.isEmpty { return i.info.optional == true ? nil : "\(i.info.title ?? i.info.name) is empty" }
        if let p = i.info.pattern, (try? Regex(p)).flatMap({ try? $0.wholeMatch(in: v) }) == nil {
            return "doesn't look right" + (i.info.placeholder.map { ": like \($0)" } ?? "")
        }
        return ToolTemplate.refusal(v, pattern: i.info.pattern)
    }

    var ready: Bool { inputs.allSatisfy { problem($0) == nil } }
    var secret: Set<String> { Set(inputs.filter { $0.info.type == .secret }.map(\.info.name)) }
    var filled: ToolTemplate.Scope {
        var s = scope
        s.levels[0] = values.mapValues { .string($0) }
        return s
    }

    /// The command with what's typed, a secret as •••; a terminal's line as it'll be typed there.
    var willRun: String {
        do {
            if action.spec.output == .terminal { return try ToolPayload.terminal(action.run, in: tool.preset, scope: filled, scripts: tool.scripts).willRun }
            return try ToolPayload.of(action.run, in: tool.preset, scope: filled, scripts: tool.scripts, secret: secret).willRun
        } catch { return "\(error)" }
    }

    /// Reads each `choice-from` input's choices on `t`, off the main thread: its Run (as root if the tool is), its
    /// Parse (`lines` unless it says), each choice its `key` (`{line}`). The first one is chosen; a failure — or no
    /// choices with something on stderr — says why in its field, the first line the program said.
    func load(on t: SFTPTarget, env: [String: String]) {
        let ins = inputs.filter { $0.info.type == .choiceFrom }
        guard !ins.isEmpty else { return }
        let tool = tool, scope = scope, flag = reads
        loading = Task {
            for i in ins {
                let r = await Blocking.run { Result { try ToolRunner.exec(i.run, of: tool, scope, on: t, timeout: i.run.timeout ?? 30, env: env, cancel: flag).ran } }
                let name = i.info.name
                switch r {
                case .success(let ran) where ran.stopped == nil && i.run.succeeded(ran.status):
                    let list = i.parse.records(ran.out).rows.map { ToolTemplate.text(i.info.key ?? "{line}", ToolTemplate.Scope(rows: [$0])) }.filter { !$0.isEmpty }
                    let said = ran.errors.split(whereSeparator: \.isNewline).first.map { "✕ " + $0 }   // a pipeline's first command failed
                    let was = values[name] ?? ""   // Retry's choice, while it's still there
                    (choices[name], values[name]) = (list.isEmpty ? .failed(said ?? "nothing to choose from") : .ready(list), list.contains(was) ? was : list.first ?? "")
                case .success(let ran):
                    choices[name] = .failed("✕ " + (ran.stopped ?? ran.errors.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(ran.status)"))
                case .failure(let e):
                    choices[name] = .failed("✕ " + e.localizedDescription)
                }
                onChange?()
            }
        }
    }

    /// Done with it: reads still on their way stop.
    func close() { reads.cancel() }

    // MARK: - The sheet

    private var kept: [AnyObject] = []

    /// The form as a sheet over `window`: a field each — a popup for a choice, dots for a secret — what's wrong under
    /// it in red as you type, "Will run:" under them all; the action's button only while it all will do. The values,
    /// or nil for Cancel.
    func sheet(on window: NSWindow, place: String) async -> [String: String]? {
        let verb = (action.spec.title ?? action.spec.id).replacingOccurrences(of: "…", with: "")
        let alert = AppDelegate.alert("\(verb) — \(place)", info: "", [verb, "Cancel"])
        var views: [NSView] = [], fields: [String: NSTextField] = [:], pops: [String: NSPopUpButton] = [:], errors: [String: NSTextField] = [:]
        for i in inputs {
            let name = i.info.name
            views.append(Confirm.label(i.info.title ?? name, size: 12))
            switch i.info.type {
            case .choice, .choiceFrom:
                let pop = NSPopUpButton()
                pop.addItems(withTitles: i.info.options ?? [])
                pop.selectItem(withTitle: values[name] ?? "")
                kept.append(MenuAction.attach(to: pop) { [unowned self, unowned pop] in set(name, pop.titleOfSelectedItem ?? "") })
                (pops[name], views) = (pop, views + [pop])
            default:
                let f = i.info.type == .secret ? NSSecureTextField() : NSTextField()
                (f.stringValue, f.placeholderString) = (values[name] ?? "", i.info.placeholder)
                if i.info.type == .text { f.font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
                let live = LiveField { [unowned self, unowned f] in set(name, f.stringValue) }
                f.delegate = live
                kept.append(live)
                (fields[name], views) = (f, views + [f])
            }
            let err = Confirm.label(" ", color: Palette.fail, size: 11)   // a line kept for it: the alert doesn't grow
            (errors[name], views) = (err, views + [err])
        }
        let preview = NSTextField(wrappingLabelWithString: "")   // three lines kept for it, the whole command where it fits
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.font = mono
        preview.textColor = .secondaryLabelColor
        preview.maximumNumberOfLines = 3
        preview.cell?.truncatesLastVisibleLine = true
        preview.preferredMaxLayoutWidth = Confirm.width
        preview.heightAnchor.constraint(equalToConstant: (3 * NSLayoutManager().defaultLineHeight(for: mono)).rounded(.up) + 4).isActive = true   // + the cell's own inset
        views.append(preview)
        alert.accessoryView = Confirm.stack(views)
        alert.window.initialFirstResponder = inputs.first.flatMap { fields[$0.info.name] }
        let refresh = { [unowned self] in
            for i in inputs {
                let name = i.info.name, why = problem(i), empty = (values[name] ?? "").isEmpty
                if let pop = pops[name], case let state? = choices[name] {   // a choice read from the server
                    pop.removeAllItems()
                    switch state {
                    case .loading: pop.addItem(withTitle: "Reading…")
                    case .failed(let why): pop.addItem(withTitle: why)
                    case .ready(let list): pop.addItems(withTitles: list); pop.selectItem(withTitle: values[name] ?? "")
                    }
                    if case .ready = state { pop.isEnabled = true } else { pop.isEnabled = false }
                }
                let shows = why != nil && (!empty || choices[name] != nil)   // an empty field isn't wrong yet
                errors[name]?.stringValue = shows ? why! : " "
                fields[name]?.textColor = shows ? Palette.fail : .labelColor
            }
            preview.stringValue = "Will run: " + willRun
            preview.toolTip = preview.stringValue
            alert.buttons[0].isEnabled = ready
        }
        onChange = refresh
        refresh()
        return await AppDelegate.sheet(alert, on: window) == 0 ? values : nil
    }
}

extension ToolRunner {
    /// Tests: fills a form in place of its sheet — the values to run with, nil for Cancel.
    nonisolated(unsafe) static var filling: (@MainActor (ToolForm) async -> [String: String]?)?

    /// `a`'s form over `window` (§7.4), its choices read on `t` as it opens: the values, or nil for Cancel.
    func form(_ a: ToolAction, of tool: LoadedTool, _ scope: ToolTemplate.Scope, on t: SFTPTarget, window: NSWindow?,
              values: [String: String]? = nil) async -> [String: String]? {
        let f = ToolForm(a, of: tool, scope, filled: values)
        f.load(on: t, env: SSHAskpass.env)
        defer { f.close() }
        if let fill = Self.filling { return await fill(f) }
        return await f.sheet(on: window ?? app.window, place: SavedServer.name(for: t.asUser))
    }
}
