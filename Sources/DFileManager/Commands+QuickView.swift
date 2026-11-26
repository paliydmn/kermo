import AppKit
import DFMCore

extension AppDelegate {
    // MARK: - Quick View (⌃Q)

    func toggleQuickView() {
        quickViewOn.toggle()
        if !quickViewOn { quickLog = false }
        other.setQuickView(quickViewOn)
        if quickViewOn { showQuickView() }
    }

    /// Quick View next door, on the active panel's cursor item, on the tab chosen.
    func showQuickView() {
        if let l = active.list {   // a row's, its source says what — or its log as it goes (⌘L)
            if quickLog, let row = l.cursor, let a = row.listActions?().first(where: { $0.follow != nil || $0.followWindow != nil }) {
                if let f = a.follow { return other.preview(log: row.title, start: { OutputWindow.embedded(f.command, on: f.on, follow: true) }) }
                if let start = a.followWindow { return other.preview(log: row.title, start: start) }
            }
            return other.preview(list: l.cursor?.title ?? "", l.cursor.flatMap(l.source.peek))
        }
        other.preview(active.peek(fetch: PanelViewController.quickTab == .preview))
    }

    /// ⌘I: Quick View next door, on its Info tab (R-48) — a file here or on a server.
    func showInfo() {
        PanelViewController.quickTab = .info
        if quickViewOn { showQuickView() } else { toggleQuickView() }
    }

    func openTerminal() {
        if let r = active.remote { return openSSH(r.target, command: SSHCommand.shell(in: r.dir)) }
        guard let app = terminalAppURL() else { return NSSound.beep() }
        NSWorkspace.shared.open([URL(fileURLWithPath: active.path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func copyToPasteboard(_ lines: [String]) {
        guard !lines.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func pasteFiles(move: Bool) {
        guard active.archive == nil else { return readOnly() }
        guard active.searchTitle == nil else { return active.flash("Search results aren't a folder: paste in one") }   // not into the one behind them
        guard let items = TransferItems(NSPasteboard.general) else { return NSSound.beep() }
        enqueueTransfer(items.paths, from: items.from, to: active.currentDir, on: active.endpoint, name: nil, move: move)
    }
}
