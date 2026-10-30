import AppKit
import DFMCore

// Where a tool is used and what it needs there (protocol §9; Tools PR 4): Use on Servers… — wherever it's found, or
// only on the servers checked — Hide on one server, and the values a tool asks for (`vars.ask`), kept with each saved
// server in tools/servers.json, never in the tool's file.
extension ToolRunner {
    /// Tests: answer the sheets in their place — the vars' values (nil: Cancel); Use on Servers…' choice (nil: Cancel).
    nonisolated(unsafe) static var settingUp: (@MainActor (LoadedTool, [String: String]) async -> [String: String]?)?
    nonisolated(unsafe) static var choosing: (@MainActor (LoadedTool, [SavedServer]) async -> (onlyChecked: Bool, checked: Set<String>)?)?

    /// The values `tool` asks for on `t`'s saved server (§9 `ask`), each checked as you type, over `window`; Save keeps
    /// them. False: Cancel, or a server not saved — there's nowhere to keep them.
    func setUp(_ tool: LoadedTool, on t: SFTPTarget, window: NSWindow?) async -> Bool {
        guard let s = app.savedServer(at: t) else { return false }
        let p = tool.preset, id = s.id.uuidString, asked = (p.vars ?? [:]).filter { $0.value.info.ask == true }.sorted { $0.key < $1.key }
        let saved = settings.vars(p.id, on: id)
        let start = Dictionary(uniqueKeysWithValues: asked.map { ($0.key, saved[$0.key] ?? $0.value.info.default ?? "") })
        let got = if let fill = Self.settingUp { await fill(tool, start) } else { await varsSheet(tool, asked, start, on: s, window: window ?? app.window) }
        guard let got, asked.allSatisfy({ $0.value.problem(got[$0.key] ?? "") == nil }) else { return false }
        settings.setVars(p.id, on: id, saved.merging(got.filter { start[$0.key] != nil }) { $1 })
        saveSettings()
        app.toolsKnown(on: nil)
        return true
    }

    private func varsSheet(_ tool: LoadedTool, _ asked: [(key: String, value: ToolVar)], _ start: [String: String], on s: SavedServer,
                           window: NSWindow) async -> [String: String]? {
        let alert = AppDelegate.alert("\(tool.preset.title) on \(s.title)", info: "", ["Save", "Cancel"])
        var values = start, views: [NSView] = [Confirm.label("What this tool needs on \(s.title). Kermo keeps it with the server (tools/servers.json); the tool's file has none of it.",
                                                             color: .secondaryLabelColor, size: 11)]
        var kept: [AnyObject] = [], check: [() -> Bool] = []
        for (name, v) in asked {
            let f = NSTextField(string: values[name] ?? ""), err = Confirm.label(" ", color: Palette.fail, size: 11)
            f.placeholderString = v.info.placeholder
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let refresh = { [unowned f] () -> Bool in
                values[name] = f.stringValue
                let why = v.problem(f.stringValue)
                err.stringValue = f.stringValue.isEmpty ? " " : why ?? " "   // an empty field isn't wrong yet
                return why == nil
            }
            let live = LiveField { alert.buttons[0].isEnabled = check.allSatisfy { $0() } }
            f.delegate = live
            (kept, check) = (kept + [live], check + [refresh])
            views += [Confirm.label(v.info.title ?? name, size: 12), f, err]
        }
        alert.accessoryView = Confirm.stack(views)
        alert.buttons[0].isEnabled = check.allSatisfy { $0() }
        let answer = await AppDelegate.sheet(alert, on: window)
        return withExtendedLifetime(kept) { answer == 0 ? values : nil }
    }

    /// Use on Servers… (§9): wherever its program is found (the default) — each saved server ticked shows it, one
    /// unticked has it hidden — or only on the servers ticked. Then, for those, what it asks for there. Untrusted: "Use
    /// the tool…?" first. Nothing changes on a server.
    func useOnServers(_ tool: LoadedTool, window: NSWindow?) async {
        guard await trustAsk(tool, window: window) else { return }
        let p = tool.preset, all = app.savedServers
        let chosen = if let choose = Self.choosing { await choose(tool, all) } else { await serversSheet(tool, all, window: window ?? app.window) }
        guard let (onlyChecked, checked) = chosen else { return }
        settings.assign(p.id, onlyChecked: onlyChecked, checked: checked, of: all.map(\.id.uuidString))
        saveSettings()
        app.toolsKnown(on: nil)
        guard onlyChecked else { return }
        for s in all where checked.contains(s.id.uuidString) && !toSetUp(tool, on: s.target).isEmpty {
            guard await setUp(tool, on: s.target, window: window) else { return }
        }
    }

    /// What Use on Servers… says of `tool` on `s`: found there, not, or not checked yet (it was never connected).
    func state(_ tool: LoadedTool, on s: SavedServer) -> String {
        guard let a = answer(s.target) else { return "not checked yet" }
        return a.answer.has(tool.preset) ? (tool.preset.tool.map { "\($0) found" } ?? "found") : "not there"
    }

    private func serversSheet(_ tool: LoadedTool, _ all: [SavedServer], window: NSWindow) async -> (onlyChecked: Bool, checked: Set<String>)? {
        let p = tool.preset, only = settings.only[p.id] != nil
        let alert = AppDelegate.alert("Use \(p.title) on…", info: "", ["Done", "Cancel"])
        let found = NSButton(radioButtonWithTitle: "Every server where \(p.tool ?? p.title) is found", target: nil, action: nil)
        let picked = NSButton(radioButtonWithTitle: "Only on the servers checked below", target: nil, action: nil)
        (found.state, picked.state) = only ? (.off, .on) : (.on, .off)
        let kept = [MenuAction.attach(to: found) { found.state = .on; picked.state = .off }, MenuAction.attach(to: picked) { picked.state = .on; found.state = .off }]
        var boxes: [(String, NSButton)] = []
        for s in all {
            let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            let title = NSMutableAttributedString(string: s.title, attributes: [.foregroundColor: s.prod ? Palette.prod : NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12)])
            title.append(NSAttributedString(string: "  " + state(tool, on: s), attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]))
            box.attributedTitle = title
            box.state = settings.uses(p.id, on: s.id.uuidString) ? .on : .off
            boxes.append((s.id.uuidString, box))
        }
        let none = all.isEmpty ? [Confirm.label("No saved servers yet: a tool shows wherever it's found.", color: .secondaryLabelColor, size: 11)] : []
        alert.accessoryView = Confirm.stack([found, picked] + boxes.map(\.1) + none + [
            Confirm.label("Kept with each saved server in tools/servers.json. Nothing changes on the servers.", color: .secondaryLabelColor, size: 11)])
        let answer = await AppDelegate.sheet(alert, on: window)
        return withExtendedLifetime(kept) { answer == 0 ? (picked.state == .on, Set(boxes.filter { $0.1.state == .on }.map(\.0))) : nil }
    }

    /// Hide `tool` on `t`'s saved server, or show it there again (`+`, Use on Servers…).
    func show(_ tool: LoadedTool, on t: SFTPTarget, _ shown: Bool) {
        guard let id = serverID(t) else { return }
        settings.use(tool.preset.id, on: id, shown)
        saveSettings()
        app.toolsKnown(on: nil)
    }
}
