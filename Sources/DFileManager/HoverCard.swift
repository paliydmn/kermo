import AppKit

/// A card beside a sidebar row while the mouse is over it: a server's name in full, its state and its actions, so the
/// row itself keeps its name and state at any width. A borderless child panel that never takes the keys (they stay with
/// the panels) and moves with its window. It opens `delay` after the mouse comes onto a row and only if it's still
/// there, goes to the next row at once while shown, and stays `grace` after the mouse leaves: the way into it.
/// A press comes through only from `arm` after it showed (or moved to another row): one meant for a file under where it
/// just appeared does nothing rather than connect to a server.
@MainActor
final class HoverCard {
    /// A row key's card content; nil: no card (the row is gone).
    var content: (String) -> NSView? = { _ in nil }
    /// A row key's row view, to stand beside; nil: not on screen.
    var anchor: (String) -> NSView? = { _ in nil }
    private(set) var key: String?        // whose card is shown
    private var pending: String?
    private var timer: Timer?
    let delay: TimeInterval = 0.15, grace: TimeInterval = 0.25, arm: TimeInterval = 0.3

    private(set) lazy var panel: CardPanel = {
        let p = CardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        (p.isOpaque, p.backgroundColor, p.hasShadow, p.isReleasedWhenClosed) = (false, .clear, true, false)
        p.hidesOnDeactivate = false   // `hide` does it, for good: AppKit would bring it back with the app
        p.arm = arm
        let box = CardView()
        box.material = .popover
        box.state = .active
        box.maskImage = Self.rounded(8)
        box.onEnter = { [weak self] in self?.timer?.invalidate() }
        box.onExit = { [weak self] in self?.leave() }
        p.contentView = box
        return p
    }()

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        // Another window of the app, ⌘M: not over it, with a state that stopped changing.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            let gone = (n.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                if let self, self.shown, let p = self.panel.parent, ObjectIdentifier(p) == gone { self.hide() }
            }
        }
    }

    var shown: Bool { key != nil }

    /// The mouse is on `key`'s row.
    func over(_ key: String) {
        if self.key == key { timer?.invalidate(); return place() }
        if shown { return show(key) }
        guard pending != key else { return }
        pending = key
        schedule(delay) { [weak self] in
            guard let self, let k = pending else { return }
            pending = nil
            show(k)
        }
    }

    /// The mouse is on no server row (it may be on the card).
    func leave() {
        pending = nil
        timer?.invalidate()
        // On the card, or back on its row before the card's exit came (two windows' events come in no set order).
        guard let k = key, !panel.frame.contains(NSEvent.mouseLocation), !onScreen(anchor(k)).contains(NSEvent.mouseLocation) else { return }
        schedule(grace) { [weak self] in self?.hide() }
    }

    func hide() {
        timer?.invalidate()
        (pending, key) = (nil, nil)
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// After the sidebar is rebuilt: the shown card's content again (its row's state may have changed), or no card.
    func reload() {
        guard let k = key, NSEvent.pressedMouseButtons == 0 else { return }   // not under a press on its button
        key = nil
        show(k, keepArmed: true)
    }

    private func show(_ key: String, keepArmed: Bool = false) {
        timer?.invalidate()
        guard NSEvent.pressedMouseButtons == 0, let row = anchor(key), let w = row.window, let view = content(key) else { return hide() }
        // The mouse left the row while the delay ran: no card where it is now.
        guard self.key != nil || keepArmed || onScreen(row).contains(NSEvent.mouseLocation) else { return hide() }
        let box = panel.contentView!
        box.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
                                     view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
                                     view.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
                                     view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8)])
        panel.appearance = row.effectiveAppearance
        panel.setContentSize(box.fittingSize)
        if !keepArmed { panel.shownAt = ProcessInfo.processInfo.systemUptime }
        self.key = key
        if panel.parent !== w {
            panel.parent?.removeChildWindow(panel)
            w.addChildWindow(panel, ordered: .above)
        }
        place()
        panel.invalidateShadow()
    }

    private func place() {
        guard let k = key, let row = anchor(k), let w = row.window else { return hide() }
        let rect = onScreen(row)
        let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? rect
        panel.setFrameOrigin(Self.origin(beside: rect, size: panel.frame.size, in: screen))
    }

    private func onScreen(_ row: NSView?) -> NSRect {
        guard let row, let w = row.window else { return .zero }
        return w.convertToScreen(row.convert(row.bounds, to: nil))
    }

    /// Right of the row (left of it where the screen ends: never over it), its top a little above the row's, within the screen.
    nonisolated static func origin(beside row: NSRect, size: NSSize, in screen: NSRect) -> NSPoint {
        let right = row.maxX + 4, left = row.minX - 4 - size.width
        return NSPoint(x: right + size.width <= screen.maxX || left < screen.minX ? max(screen.minX, min(right, screen.maxX - size.width)) : left,
                       y: max(screen.minY, min(row.maxY + 4 - size.height, screen.maxY - size.height)))
    }

    /// In the default run loop mode only: not while a menu from the card (or the row's) is open.
    private func schedule(_ after: TimeInterval, _ run: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { _ in MainActor.assumeIsolated { run() } }
    }

    private static func rounded(_ r: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        (image.capInsets, image.resizingMode) = (NSEdgeInsets(top: r, left: r, bottom: r, right: r), .stretch)
        return image
    }

    /// Drops a press that comes within `arm` of the card's showing (or moving to another row): the click is checked when
    /// it starts, as a button acts on its release.
    final class CardPanel: NSPanel {
        var shownAt: TimeInterval = 0, arm: TimeInterval = 0
        override func sendEvent(_ event: NSEvent) {
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), event.timestamp - shownAt < arm { return }
            super.sendEvent(event)
        }
    }

    /// Tells when the mouse comes onto the card and leaves it: it's never key, so its tracking is always on.
    private final class CardView: NSVisualEffectView {
        var onEnter: (() -> Void)?, onExit: (() -> Void)?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { onEnter?() }
        override func mouseExited(with event: NSEvent) { onExit?() }
    }
}
