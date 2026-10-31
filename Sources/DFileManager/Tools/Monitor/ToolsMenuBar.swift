import AppKit
import DFMCore

/// The menu bar while something is watched (monitor decisions 2, 10, 18; protocol §8.8): one item — a gauge, and how
/// many servers have a problem in the worst one's color, dimmed while notifications are snoozed — whose popover lists
/// every watched server as WATCHED does (problems first, each tool's summary), then Open Monitor, Open Kermo, Snooze
/// and Quit. Up to three watched servers pinned (Show in the Menu Bar) have an item each: their state and summary,
/// "web-01 42% · 61%" (protocol §8.8). Nothing watched: no item. With every window closed Kermo lives here alone — no
/// Dock icon, no ⌘Tab (`.accessory`), watching going on — and a running copy's progress shows here, as the Dock would.
@MainActor final class ToolsMenuBar: NSObject, NSPopoverDelegate {
    unowned let app: AppDelegate
    private(set) var item: NSStatusItem?
    let popover = NSPopover()
    private var click: AnyObject?
    /// Pinned servers' items, by saved server id, with their clicks.
    private var pins: [String: (item: NSStatusItem, click: AnyObject)] = [:]
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

    /// Watching changed: the item made or gone, its count and color, the popover's rows if it's open (`rows`: not
    /// for a copy's progress, which changes only the item).
    func update(rows: Bool = true) {
        let monitor = app.tools.monitor, watched = monitor.watched
        guard !watched.isEmpty else {
            updatePins([])
            popover.performClose(nil)
            item.map(NSStatusBar.system.removeStatusItem)
            item = nil
            return
        }
        let item = self.item ?? make()
        guard let b = item.button else { return }
        let states = watched.map { monitor.worst($0).state }, bad = states.filter { $0 == .critical || $0 == .warning }.count
        let color = states.contains(.critical) ? Palette.fail : Palette.warn
        let title = NSMutableAttributedString(string: bad > 0 ? " \(bad)" : "", attributes: [.foregroundColor: color, .font: NSFont.menuBarFont(ofSize: 0)])
        if NSApp.activationPolicy() == .accessory, let f = DockTile.fraction {   // no Dock to show a copy's progress (plan §7)
            title.append(NSAttributedString(string: " \(Int(f * 100))%", attributes: [.font: NSFont.menuBarFont(ofSize: 0)]))
        }
        b.attributedTitle = title
        b.appearsDisabled = monitor.snoozed != nil
        let (head, snoozed) = Self.head(monitor)
        b.setAccessibilityLabel("Kermo Monitor: " + head + (snoozed.map { ", " + $0 } ?? ""))
        b.toolTip = "Kermo Monitor — " + head
        if rows { updatePins(watched) }   // after the main item: pins come to its left
        if rows, popover.isShown { fill() }
    }

    /// A pinned watched server's words: its name and its tools' summary values, "web-01 42% · 61% · 27%".
    static func pinText(_ monitor: ToolMonitor, _ s: ToolMonitor.Server) -> String {
        let values = s.tools.values.filter(\.watched).sorted { $0.preset.id < $1.preset.id }.flatMap { t in monitor.summary(t, on: s).map(\.text) }
        return ([s.saved.title] + [values.joined(separator: " · ")].filter { !$0.isEmpty }).joined(separator: " ")
    }

    /// An item for each pinned server still watched, in the order pinned (added left of the ones before: newest first
    /// from the right); a click opens its page.
    private func updatePins(_ watched: [ToolMonitor.Server]) {
        let monitor = app.tools.monitor
        let want = app.tools.settings.pinned.prefix(ToolServers.pinnedMax).compactMap { id in watched.first { $0.saved.id.uuidString == id } }
        for (id, pin) in pins where !want.contains(where: { $0.saved.id.uuidString == id }) {
            NSStatusBar.system.removeStatusItem(pin.item)
            pins[id] = nil
        }
        for s in want {
            let id = s.saved.id.uuidString
            if pins[id] == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                pins[id] = (item, MenuAction.attach(to: item.button!) { [unowned self] in   // the server as it is then: an edit may move it
                    app.tools.monitor.open(app.tools.monitor.watched.first { $0.saved.id.uuidString == id }?.target)
                })
            }
            guard let b = pins[id]?.item.button else { continue }
            let (state, why) = monitor.worst(s)
            (b.image, b.imagePosition, b.title) = (state.mark(11), .imageLeading, Self.pinText(monitor, s))
            b.setAccessibilityLabel("Kermo: " + Self.pinText(monitor, s) + (why.isEmpty ? "" : ", " + why))
        }
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

    /// The head, a row a server — a click opens its page — and the buttons; tests read them without showing them.
    func fill() {
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
        let awake = NSButton(checkboxWithTitle: "Keep This Mac Awake on Power", target: nil, action: nil)   // Settings ▸ Monitor has it too
        awake.state = app.defaults.bool(forKey: "monitorKeepAwake") ? .on : .off
        awake.toolTip = "While it's on power and something is watched; closing the lid still puts it to sleep"
        actions.append(MenuAction.attach(to: awake) { [unowned self] in app.run("monitor.keepAwake") })
        let key = app.commands.first { $0.id == "app.monitor" }?.keys.first.map { "  " + $0.display } ?? ""   // as keymap.json has it
        views += [button("Open Monitor" + key, .monitor) { [unowned self] _ in popover.performClose(nil); monitor.open(monitor.watched.first?.target) },
                  button("Open Kermo", .folder) { [unowned self] _ in popover.performClose(nil); app.bringBack(app.window) },
                  button(snoozed == nil ? "Snooze Notifications ▾" : "Resume or Snooze ▾", .snooze) { [unowned self] b in
                      Self.snoozeMenu(monitor).popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height), in: b)
                      if popover.isShown { fill() }
                  },
                  awake,
                  button("Quit Kermo", .quit) { [unowned self] _ in   // asks first if anything would be lost: in front, so the question is seen
                      popover.performClose(nil)
                      NSApp.activate()
                      NSApp.terminate(nil)
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

extension ToolMonitor.State {
    /// Its shape and color (monitor §3.6): an octagon critical, a triangle a warning, a dot fine, a ring paused.
    func mark(_ size: CGFloat) -> NSImage {
        switch self {
        case .critical: Symbol.crit.image("critical", color: Palette.fail, size: size)
        case .warning: Symbol.warnFill.image("warning", color: Palette.warn, size: size)
        case .ok: Symbol.dot.image("fine", color: Palette.ok, size: size * 0.75)
        case .off: Symbol.ring.image("paused", color: .tertiaryLabelColor, size: size * 0.75)
        }
    }
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

extension ToolRunner {
    /// A deleted server's pin goes with it: else it would hold one of the three for good, with no page to take it off.
    func unpinFromMenuBar(_ s: SavedServer) {
        guard settings.pinned.contains(s.id.uuidString) else { return }
        settings.pin(s.id.uuidString, false)
        saveSettings()
    }
}
