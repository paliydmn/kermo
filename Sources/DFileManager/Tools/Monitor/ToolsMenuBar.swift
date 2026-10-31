import AppKit
import DFMCore

/// The menu bar while something is watched (monitor decisions 2, 10, 18; protocol §8.8): one item — a gauge, and how
/// many servers have a problem in the worst one's color, dimmed while notifications are snoozed — whose popover lists
/// every watched server as WATCHED does (problems first, each tool's summary), then Open Monitor, Open Kermo and
/// Snooze. Nothing watched: no item. With every window closed Kermo lives here alone — no Dock icon, no ⌘Tab
/// (`.accessory`), watching going on — and a running copy's progress shows here, as the Dock would show it.
@MainActor final class ToolsMenuBar: NSObject, NSPopoverDelegate {
    unowned let app: AppDelegate
    private(set) var item: NSStatusItem?
    let popover = NSPopover()
    private var click: AnyObject?
    /// The popover's buttons' actions: replaced with its rows.
    private var kept: [AnyObject] = []

    init(_ app: AppDelegate) {
        self.app = app
        super.init()
        popover.behavior = .transient   // ⎋ or a click elsewhere closes it (S3)
        popover.delegate = self
    }

    /// The popover's head: "2 critical, 1 warning", "all good"; and "snoozed until 10:42".
    static func head(_ monitor: ToolMonitor) -> (text: String, snoozed: String?) {
        let states = monitor.watched.map { monitor.worst($0).state }
        let crit = states.filter { $0 == .critical }.count, warn = states.filter { $0 == .warning }.count
        let parts = [crit > 0 ? "\(crit) critical" : nil, warn > 0 ? "\(warn) warning" + (warn == 1 ? "" : "s") : nil].compactMap { $0 }
        return (parts.isEmpty ? "all good" : parts.joined(separator: ", "),
                monitor.snoozed.map { "snoozed until " + $0.formatted(date: .omitted, time: .shortened) })
    }

    /// Watching changed: the item made or gone, its count and color, the popover's rows if it's open.
    func update() {
        let monitor = app.tools.monitor, watched = monitor.watched
        guard !watched.isEmpty else {
            popover.performClose(nil)
            item.map(NSStatusBar.system.removeStatusItem)
            item = nil
            return
        }
        let item = self.item ?? make()
        guard let b = item.button else { return }
        let states = watched.map { monitor.worst($0).state }, bad = states.filter { $0 == .critical || $0 == .warning }.count
        let color = states.contains(.critical) ? Palette.fail : Palette.warn
        var title = NSMutableAttributedString(string: bad > 0 ? " \(bad)" : "", attributes: [.foregroundColor: color, .font: NSFont.menuBarFont(ofSize: 0)])
        if NSApp.activationPolicy() == .accessory, let f = DockTile.fraction {   // no Dock to show a copy's progress (plan §7)
            title.append(NSAttributedString(string: " \(Int(f * 100))%", attributes: [.font: NSFont.menuBarFont(ofSize: 0)]))
        }
        if title.length == 0 { title = NSMutableAttributedString() }
        b.attributedTitle = title
        b.appearsDisabled = monitor.snoozed != nil
        let (head, snoozed) = Self.head(monitor)
        b.setAccessibilityLabel("Kermo Monitor: " + head + (snoozed.map { ", " + $0 } ?? ""))
        b.toolTip = "Kermo Monitor — " + head
        if popover.isShown { fill() }
    }

    private func make() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Symbol.monitor.image("Kermo Monitor")
        item.button?.imagePosition = .imageLeading
        click = MenuAction.attach(to: item.button!) { [unowned self] in toggle() }
        self.item = item
        return item
    }

    private func toggle() {
        guard let b = item?.button else { return }
        if popover.isShown { return popover.performClose(nil) }
        fill()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()   // ⎋ reaches it without Kermo in front
    }

    /// The head, a row a server — a click opens its page — and the buttons.
    private func fill() {
        let monitor = app.tools.monitor, (head, snoozed) = Self.head(monitor)
        let title = NSTextField(labelWithString: "Monitor · " + head)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        var top: [NSView] = [title, ToolsWindow.spacer()]
        if let snoozed { top.append(ToolsWindow.small(snoozed)) }
        var views: [NSView] = [NSStackView(views: top)]
        var actions: [AnyObject] = []
        for s in monitor.watched {
            let row = ClickStack(views: [ToolsWindow.watchedRow(app, s.saved, s.target)]) { [unowned self] in
                popover.performClose(nil)
                monitor.open(s.target)
            }
            row.setAccessibilityRole(.button)
            views.append(row)
        }
        let line = NSBox()
        line.boxType = .separator
        views.append(line)
        func button(_ title: String, _ symbol: Symbol, _ run: @escaping @MainActor (NSButton) -> Void) -> NSButton {
            let b = NSButton(title: title, image: symbol.image(nil), target: nil, action: nil)
            (b.isBordered, b.imagePosition, b.alignment) = (false, .imageLeading, .left)
            actions.append(MenuAction.attach(to: b) { [unowned b] in run(b) })
            return b
        }
        views += [button("Open Monitor  ⌃⌘M", .monitor) { [unowned self] _ in popover.performClose(nil); monitor.open(monitor.watched.first?.target) },
                  button("Open Kermo", .folder) { [unowned self] _ in popover.performClose(nil); app.bringBack(app.window) },
                  button(snoozed == nil ? "Snooze Notifications ▾" : "Resume or Snooze ▾", .snooze) { [unowned self] b in
                      Self.snoozeMenu(monitor).popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height), in: b)
                      if popover.isShown { fill() }
                  }]
        let stack = NSStackView(views: views)
        (stack.orientation, stack.alignment, stack.spacing) = (.vertical, .leading, 6)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 320).isActive = true
        kept = actions
        // A new controller each time: a shown popover whose controller only changed its view shrank to the item's size.
        let vc = NSViewController()
        vc.view = stack
        vc.preferredContentSize = stack.fittingSize
        popover.contentViewController = vc
    }

    /// Snooze ▾ (decision 14): 15 minutes, an hour, till the morning; or Resume. The menu bar and the window still
    /// show every problem.
    static func snoozeMenu(_ monitor: ToolMonitor) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let nine = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 9, minute: 0), matchingPolicy: .nextTime) ?? Date()
        for (title, until) in [("For 15 Minutes", Date().addingTimeInterval(900)), ("For 1 Hour", Date().addingTimeInterval(3600)),
                               ("Until " + nine.formatted(date: .omitted, time: .shortened) + (Calendar.current.isDateInToday(nine) ? "" : " Tomorrow"), nine)] {
            menu.addItem(MenuAction.item(title) { monitor.snooze(until: until) })
        }
        let resume = MenuAction.item("Resume Notifications") { monitor.snooze(until: nil) }
        resume.isEnabled = monitor.snoozed != nil
        menu.addItem(resume)
        menu.addItem(.separator())
        menu.addItem(AppDelegate.note("The menu bar and Monitor still show every problem"))
        return menu
    }

    func popoverDidClose(_ notification: Notification) { popover.contentViewController = nil }   // its rows go till next time
}

extension AppDelegate {
    /// Tests: how the app goes to the menu bar alone, and back with `window` in front — the test runner's own policy
    /// mustn't change.
    nonisolated(unsafe) static var activation: @MainActor (NSApplication.ActivationPolicy, NSWindow?) -> Void = { policy, w in
        // An app already active in the menu bar alone keeps the previous app's menus after `.regular` unless activation
        // bounces off the Dock (S2); `deactivate()` first didn't help.
        let bounce = NSApp.isActive && NSApp.activationPolicy() != .regular
        NSApp.setActivationPolicy(policy)
        guard let w else { return }
        w.makeKeyAndOrderFront(nil)
        guard bounce else { return NSApp.activate() }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.activate(); w.makeKeyAndOrderFront(nil) }
    }

    /// `w` in front from the menu bar, a notification, the Dock or Finder: the Dock icon back first (S2).
    func bringBack(_ w: NSWindow) { Self.activation(.regular, w) }

    /// A window closing: if it was the last one and something is watched, Kermo stays — in the menu bar alone. Looked
    /// at once it's gone; tests give their own `windows`.
    func windowClosed(_ windows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows }) {
        DispatchQueue.main.async { [self] in
            guard !tools.monitor.watched.isEmpty, !windows().contains(where: { ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain }) else { return }
            Self.activation(.accessory, nil)
        }
    }
}
