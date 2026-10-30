import AppKit
import DFMCore

// What Tools ask (protocol §7.3, §12): the question before a run, the payload as it's sent, and "Use the tool…?" for a
// tool of yours that's new or changed. All of them `Confirm`s.
extension ToolRunner {
    /// Tests: the "Don't ask again … for 10 minutes" box, ticked (the question itself `AppDelegate.answering` answers).
    nonisolated(unsafe) static var ticks = false

    /// The question (§7.3): what runs with its values, how and where, the production strip, the action's `message`;
    /// "Show Exactly What Runs" shows the payload, then asks again. `quietFor`: the server it may stop asking on for 10
    /// minutes — production's question only, never one that always asks. nil: Cancel; else whether that box was ticked.
    func ask(_ a: ToolAction, verb: String, row: String?, on t: SFTPTarget, mac: Bool, sudo: Bool, willRun: String, payload: ToolPayload?,
             message: String?, quietFor: String?, window: NSWindow?) async -> Bool? {
        let place = mac ? "this Mac" : SavedServer.name(for: t.asUser)
        var c = Confirm("\(verb) on \(place)?", on: mac ? nil : t.asRoot(sudo), action: verb)
        if let row { c.items = [Confirm.Item(name: row)] }
        (c.runs, c.command) = (mac ? "Runs on this Mac." : AppDelegate.runs(on: t.asRoot(sudo)), willRun)
        c.note = [message, a.spec.long == true ? Self.longNote : nil].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
        if payload != nil { c.others = ["Show Exactly What Runs"] }
        c.irreversible = a.spec.dangerous == true
        let box = quietFor.map { NSButton(checkboxWithTitle: "Don't ask again for this tool on \($0) for 10 minutes", target: nil, action: nil) }
        c.extra = box
        while true {
            switch await app.confirm(c, on: window) {
            case 0: return AppDelegate.answering != nil ? Self.ticks && box != nil : box?.state == .on
            case 1 where payload != nil: await exactly(payload!.shown, on: place, window: window)
            default: return nil
            }
        }
    }

    /// The payload as it's sent, its secrets as •••: mono, scrolling past 8 lines.
    func exactly(_ shown: String, on place: String, window: NSWindow?) async {
        let title = "Exactly what runs on \(place)"
        if let answer = AppDelegate.answering { AppDelegate.answeredInfo = shown; _ = answer(title, ["OK"], nil); return }
        let alert = AppDelegate.alert(title, info: "", ["OK"])
        alert.accessoryView = Confirm.stack([Confirm.label("This goes to sh -s as its input. Each value is a variable set before the command, never part of it.",
                                                           color: .secondaryLabelColor, size: 11), Confirm.commandBox(shown)])
        _ = await AppDelegate.sheet(alert, on: window ?? app.window)
    }

    /// "Use the tool …?" (§12) for a tool of yours that's new, or changed since you said to use it: what it runs by
    /// itself (with no question, maybe as root) and what it runs when you choose, root marked; a `readonly` action
    /// whose command looks destructive, warned of; Open File shows the file and its scripts. True: trusted now, and
    /// kept so (`tools/trust.json`). Built-ins are trusted.
    func trustAsk(_ tool: LoadedTool, window: NSWindow?) async -> Bool {
        guard !trust.trusts(tool) else { return true }
        let p = tool.preset, file = (tool.path as NSString).lastPathComponent
        var c = Confirm("Use the tool “\(p.tool.map { "\(p.title) (\($0))" } ?? p.title)”?", action: "Use This Tool")
        c.runs = "\(file) " + (trust.hashes[p.id] == nil ? "is new here." : "changed since you said to use it.") + " Here is everything it can run:"
        c.command = tool.runs.text
        let long = p.allActions.contains { $0.action.spec.long == true }
        c.note = (Self.cautions(tool) + ["Kermo asks once for each new or changed tool. A value goes into a command as a variable, scripts go on stdin, and nothing is left on the server"
            + (long ? " but a long job's: it runs on after Kermo quits, and its log stays in ~/.cache/kermo/ there for 7 days." : ".")]).joined(separator: "\n")
        c.others = ["Open File"]
        c.cancel = "Don't Use"
        c.returnCancels = false
        while true {
            switch await app.confirm(c, on: window) {
            case 0:
                trust.trust(tool)
                if let dir = Self.own?.path { Config.save("trust.json", trust, in: dir) }
                return true
            case 1:
                Viewer.show(URL(fileURLWithPath: tool.path))
                for s in tool.scripts.keys.sorted() { Viewer.show(URL(fileURLWithPath: ((tool.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(s))) }
            default: return false
            }
        }
    }

    /// What a long job leaves (§7.6, Q10), said by its question and the trust sheet.
    static let longNote = "It runs on after Kermo quits; its log stays in ~/.cache/kermo/ on the server for 7 days."

    /// What the trust sheet warns of: a `readonly` action whose command looks destructive (§3.3).
    static func cautions(_ tool: LoadedTool) -> [String] {
        tool.preset.allActions.compactMap { _, a in
            guard a.spec.readonly == true, let words = ToolSchema.destructive(a.run.command?.all ?? []) else { return nil }
            return "⚠ “\(a.spec.title ?? a.spec.id)” says it changes nothing, but it \(words)."
        }
    }
}

private extension Collection {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
