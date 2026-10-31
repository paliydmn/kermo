import AppKit
import DFMCore

// What watching tells you (protocol §8.7, monitor decisions 13–14): a watched tool's critical alert, critical event or
// a script's critical `_event`, and a watched server not answering, come as a macOS notification — Open, Snooze 1 Hour
// and, for an alert, Mute This Alert on This Server — and run your `on_alert`. A warning stays in the menu bar, the
// Dock's badge and the window; "back to normal" is an event in the window, not a notification. Nothing goes out while
// snoozed (everything) or muted (one alert on one server).
extension ToolMonitor {
    /// Snoozed till then (the menu bar's Snooze, a notification's Snooze 1 Hour); the menu bar and the window still show
    /// every problem. In `monitorSnooze`, so "until 9:00" outlives a relaunch.
    var snoozed: Date? { (app.defaults.object(forKey: "monitorSnooze") as? Date).flatMap { $0 > Date() ? $0 : nil } }

    func snooze(until: Date?) {
        if let until { app.defaults.set(until, forKey: "monitorSnooze") } else { app.defaults.removeObject(forKey: "monitorSnooze") }
        changed()
    }

    /// A critical thing on `s` — `tool`'s, or the server's own (not answering): the notification and `on_alert`, unless
    /// it isn't watched, notifications are snoozed or the alert is muted there. `id`: one notification per alert and
    /// series, a newer one in its place.
    func deliver(_ s: Server, tool: Tool?, alert: String? = nil, id: String, _ message: String) {
        guard tool?.watched ?? s.watched, snoozed == nil else { return }
        if let tool, let alert, app.tools.settings.mutes(alert, of: tool.preset.id, on: s.saved.id.uuidString) { return }
        var info = ["server": s.key]
        (info["tool"], info["alert"]) = (tool?.preset.id, alert)
        let title = s.saved.title + (s.saved.prod ? " · production" : ""), body = (tool.map { $0.preset.title + ": " } ?? "") + message
        let notices = ToolJobs.notices
        Task { if await notices.allowed() == true { notices.post("watch " + id, title, body, info) } }   // not allowed: the menu bar and the Dock say it
        guard let command = app.defaults.string(forKey: "onAlert"), !command.isEmpty else { return }
        let env = ["KERMO_LEVEL": "critical", "KERMO_MESSAGE": message, "KERMO_SERVER": s.saved.title, "KERMO_TOOL": tool?.preset.id ?? ""]
        Task { [weak self] in
            let said = await Self.onAlert(command, env: env)
            self?.note(s, said)
            self?.changed()
        }
    }

    /// Your `on_alert` (Settings ▸ Monitor; never a tool's, §8.3) on this Mac, in your login shell — so it finds what
    /// your Terminal finds (curl, ntfy) — with what happened in its environment only, never in its words. Not waited
    /// for past 30 s. Its end, as the server's events say it.
    nonisolated static func onAlert(_ command: String, env: [String: String]) async -> String {
        await Blocking.run(.utility) { () -> String in
            let p = Process(), ended = DispatchSemaphore(value: 0)
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            (p.standardInput, p.standardOutput, p.standardError) = (FileHandle.nullDevice, FileHandle.nullDevice, FileHandle.nullDevice)
            p.terminationHandler = { _ in ended.signal() }
            do { try p.run() } catch { return "on_alert couldn't run: \(error.localizedDescription)" }
            guard ended.wait(timeout: .now() + 30) == .success else {
                p.terminate()
                return "on_alert still running after 30 s: stopped"
            }
            return p.terminationStatus == 0 ? "on_alert ran" : "on_alert failed: exit \(p.terminationStatus)"
        }
    }

    /// Settings ▸ Monitor's word on notifications, as macOS has it now (S1: not what the request's answer said).
    func notificationsSaid() async -> String {
        switch await ToolJobs.notices.allowed() {
        case true?: "On: a critical alert comes as a notification, once, and a warning shows in the menu bar only"
        case false?: "Notifications are off for Kermo: turn them on in System Settings. Problems still show in the menu bar and the Dock"
        case nil: "Not asked yet: Kermo asks when you first watch a server"
        }
    }

    /// Send Test: a notification as a critical alert's, and `on_alert` with made-up values — what it did, in Settings.
    func test() {
        tested = "Sending…"
        let notices = ToolJobs.notices, command = app.defaults.string(forKey: "onAlert") ?? ""
        Task {
            let allowed = await notices.allowed() == true
            if allowed { notices.post("watch test", "Kermo · test", "This is how a critical alert looks.", [:]) }
            let ran = command.isEmpty ? "no command set"
                : await Self.onAlert(command, env: ["KERMO_LEVEL": "critical", "KERMO_MESSAGE": "A test from Kermo", "KERMO_SERVER": "test", "KERMO_TOOL": "test"])
            tested = (allowed ? "Notification sent" : "No notification (they're off)") + " · " + ran + " · " + Date().formatted(date: .omitted, time: .shortened)
            SettingsWindow.refreshShown()
        }
    }

    /// Open System Settings: Kermo's page under Notifications.
    static func notificationSettings() {
        let id = Bundle.main.bundleIdentifier.map { "?id=" + $0 } ?? ""
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension" + id).map { _ = NSWorkspace.shared.open($0) }
    }

    /// A notification's button or click (`ToolJobs.Clicks`): Snooze 1 Hour, Mute This Alert on This Server, or Open —
    /// the server's page on the tool's tab.
    func clicked(_ action: String, _ info: [String: String]) {
        guard let key = info["server"], let s = servers[key] else { return open(nil) }
        switch action {
        case ToolJobs.Notices.snooze: snooze(until: Date().addingTimeInterval(3600))
        case ToolJobs.Notices.mute:
            guard let tool = info["tool"], let alert = info["alert"] else { return }
            app.tools.settings.mute(alert, of: tool, on: s.saved.id.uuidString, true)
            app.tools.saveSettings()
            changed()
        default: open(s.target, tool: info["tool"])
        }
    }

    /// Open Monitor (the menu bar, ⌥⌘M, a notification): Kermo in front with the Tools window — on `t`'s page and
    /// `tool`'s tab when given, else where it was (WATCHED comes first). Once, though a click brings a reopen too (S1).
    func open(_ t: SFTPTarget?, tool: String? = nil) {
        ToolsWindow.show(app, server: t)
        if let tool { ToolsWindow.main?.page?.select(tool) }
        if let w = ToolsWindow.main?.window { app.bringBack(w) }
    }
}
