import AppKit
import Carbon.HIToolbox

// The editor from any app: the global shortcut, the Dock menu, kermo://new and kermo://show, `fm --new`. They all go
// through `AppDelegate.editorFromOutside`.

/// The global shortcut for a new editor document: a Carbon hot key — no Accessibility or Input Monitoring, nothing
/// that sees any other key. The defaults key `editorHotKey` holds its spec ("ctrl+cmd+e"); none: off.
@MainActor
enum GlobalKey {
    /// What the switch turns on before another is recorded (decision 10: free in Kermo).
    static let proposed = Shortcut("ctrl+cmd+e")!
    /// Registered with macOS now (nil: off or refused). Kermo lives on with no windows while it's set.
    private(set) static var current: Shortcut?
    /// Why the last try didn't take: said under the Settings row.
    private(set) static var refused: String?

    /// Tests: Carbon's register and unregister — a test registers for real only an odd key, never the user's.
    nonisolated(unsafe) static var system: (register: @MainActor (Shortcut) -> OSStatus, unregister: @MainActor () -> Void) = (carbonRegister, carbonUnregister)

    /// At launch, after the keymap: the key saved, if any, checked as Record… checks it (a `defaults write`, a new
    /// Kermo whose command took it). Refused, or taken by another Kermo: off till set again, said in Settings.
    static func start(_ app: AppDelegate, _ defaults: UserDefaults = .standard) {
        guard let k = saved(defaults) else { return }
        if let why = unusable(k) ?? taken(k, app) { refused = why } else { take(k) }
    }

    /// The switch, Record… or ⌫: what's wrong before macOS is asked, else registered and saved. A refusal keeps the
    /// key there was (or none) — never on and not working. nil: done; else what to say.
    @discardableResult static func use(_ k: Shortcut?, _ app: AppDelegate, _ defaults: UserDefaults = .standard) -> String? {
        guard let k else {
            system.unregister()
            (current, refused) = (nil, nil)
            defaults.removeObject(forKey: "editorHotKey")
            return nil
        }
        if k == current { resume(); return nil }
        if let why = unusable(k) ?? taken(k, app) {
            resume()   // back from Record…'s pause
            refused = why
            return why
        }
        let old = current
        guard take(k) else {
            var why = refused ?? ""
            if let old, !take(old) { why += " \(old.display), the one before, couldn't be taken back: it's off." }   // grabbed during Record…
            refused = why
            return why
        }
        defaults.set(k.spec, forKey: "editorHotKey")
        return nil
    }

    /// The one set in Settings, registered or not.
    static func saved(_ defaults: UserDefaults) -> Shortcut? { defaults.string(forKey: "editorHotKey").flatMap(Shortcut.init) }

    /// Off while Settings records a key: else pressing the one set now would run it instead.
    static func pause() { system.unregister() }
    static func resume() { if let k = current { take(k) } }

    /// Registered: `current`; refused: off, `refused` says why.
    @discardableResult private static func take(_ k: Shortcut) -> Bool {
        system.unregister()
        let status = system.register(k)
        current = status == noErr ? k : nil
        refused = status == noErr ? nil : status == eventHotKeyExistsErr ? "macOS refused \(k.display): another app has it."
            : "macOS refused \(k.display) (error \(status))."
        return status == noErr
    }

    /// Never a shortcut for every app: without ⌃ or ⌘ (⌥ or ⌥⇧ alone is what keyloggers would use, and macOS 15 began
    /// refusing it; a bare key would leave every app without it), or one macOS takes first.
    static func unusable(_ k: Shortcut) -> String? {
        if !k.flags.contains(.control) && !k.flags.contains(.command) { return "\(k.display) can't be used: macOS needs ⌃ or ⌘ in a shortcut for every app." }
        return k.takenByMacOS.map { "\(k.display) can't be used: macOS takes it first (\($0))." }
    }

    /// The other way round: a command given the shortcut (Keys, keymap.json) never gets it — the hot key takes it first.
    static func clash(_ keys: [Shortcut]) -> String? {
        current.flatMap { g in keys.contains(g) ? "\(g.display) is Kermo's New editor document from any app: pick another or change that one in Settings ▸ General." : nil }
    }

    /// Kermo's own: a command's key (Keys can move it), or a menu item's.
    static func taken(_ k: Shortcut, _ app: AppDelegate) -> String? {
        if let c = app.keymap[k] { return "\(k.display) is Kermo's \(c.title.replacingOccurrences(of: "…", with: "")): pick another or change that one in Keys." }
        return AppDelegate.fixedKeys(NSApp.mainMenu ?? app.makeMenu())[k].map { "\(k.display) stays \($0): pick another." }
    }

    // MARK: Carbon

    private static var refs: [EventHotKeyRef] = []
    private static var handler: EventHandlerRef?

    private static func carbonRegister(_ k: Shortcut) -> OSStatus {
        if handler == nil {   // else a key registered with nothing to answer it
            var press = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.editorFromOutside(new: true) }
                return noErr
            }, 1, &press, nil, &handler)
            guard status == noErr else { return status }
        }
        let flags = k.flags
        let mods = [(NSEvent.ModifierFlags.command, cmdKey), (.shift, shiftKey), (.option, optionKey), (.control, controlKey)]
            .reduce(0) { flags.contains($1.0) ? $0 | $1.1 : $0 }
        // ISO keyboards: Kermo takes § and ` as one key (`Shortcut(event:)`), so the shortcut is both.
        for code in k.keyCode == 50 ? [50, 10] : [Int(k.keyCode)] {
            var ref: EventHotKeyRef?
            // Exclusive: a second Kermo asking for the same key is refused (eventHotKeyExistsErr), not given it quietly.
            let status = RegisterEventHotKey(UInt32(code), UInt32(mods), EventHotKeyID(signature: 0x4B524D4F, id: 1),   // "KRMO"
                                             GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            guard status == noErr, let ref else { carbonUnregister(); return status }
            refs.append(ref)
        }
        return noErr
    }

    private static func carbonUnregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }
}

extension AppDelegate {
    /// From outside Kermo — the global shortcut, the Dock menu, kermo://new, `fm --new` (`new`); kermo://show and the
    /// Dock's Show Editor (not `new`): the editor window in front, Kermo active, the text in focus. `new` makes an
    /// Untitled unless the tab shown is one with nothing in it yet (a page opening kermo://new again and again adds no
    /// tabs, a second press while the window comes up neither). The main window stays as it was.
    /// Nothing new under a question (app-modal — Quit's too —, or a sheet on the editor): Kermo comes forward with it;
    /// nor while Kermo quits (the last drafts are being written: a tab made now would be lost).
    func editorFromOutside(new: Bool) {
        if let asking = NSApp.modalWindow ?? EditorHost.shared?.window.flatMap({ $0.attachedSheet != nil ? $0 : nil }) { return bringBack(asking) }
        if quitting {
            if let h = EditorHost.shared, h.window?.isVisible == true { h.active?.flash("Writing the drafts before Kermo quits…") }
            return
        }
        let h = EditorHost.tabs
        if new, !(h.active.map { $0.url == nil && !$0.isEdited && $0.textView.string.isEmpty } ?? false) {
            Editor.untitled()
        } else {
            h.showEditor()
            if let a = h.active { h.window?.makeFirstResponder(a.focus) }   // out of the find bar
        }
        h.window.map(bringBack)
    }

    /// kermo://new or kermo://show, in any case, and nothing more: any page or app can open the scheme, so it carries
    /// no path, text or setting, and anything else does nothing (nor is it logged). True: new.
    static func kermoAction(_ url: URL) -> Bool? {
        switch url.absoluteString.lowercased() {
        case "kermo://new": true
        case "kermo://show": false
        default: nil
        }
    }

    /// The Dock icon's menu: the same two as kermo://.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        for (id, new) in [("editor.new", true), ("editor.show", false)] {
            let it = NSMenuItem(title: commands.first { $0.id == id }?.title ?? id, action: #selector(dockEditor(_:)), keyEquivalent: "")
            it.target = self
            it.tag = new ? 1 : 0
            m.addItem(it)
        }
        return m
    }

    @objc func dockEditor(_ sender: NSMenuItem) { editorFromOutside(new: sender.tag == 1) }
}

/// Settings ▸ General's row: the switch (on: ⌃⌘E till another is recorded), the key, Record… — the next key pressed in
/// the window is it, ⎋ cancels, ⌫ turns it off. What went wrong: in red under the row's note.
@MainActor
final class GlobalKeyRecorder: NSObject {
    let toggle = NSSwitch(), key = NSTextField(labelWithString: ""), record = NSButton(title: "Record…", target: nil, action: nil)
    let error = NSTextField(wrappingLabelWithString: "")
    lazy var controls: NSView = {
        let h = NSStackView(views: [key, record, toggle])
        h.spacing = 8
        h.setHuggingPriority(.required, for: .horizontal)
        return h
    }()
    private unowned let app: AppDelegate
    private let defaults: UserDefaults
    private var monitor: Any?, leaving: Any?
    var recording: Bool { monitor != nil }

    init(app: AppDelegate, defaults: UserDefaults = .standard) {
        self.app = app
        self.defaults = defaults
        super.init()
        (toggle.target, toggle.action) = (self, #selector(switched))
        (record.target, record.action) = (self, #selector(startRecording))
        record.setAccessibilityLabel("Record a shortcut — New editor document from any app")
        key.font = .systemFont(ofSize: 12)
        error.font = .systemFont(ofSize: 11.5)
        error.textColor = .systemRed
        error.preferredMaxLayoutWidth = 330
        refresh()
    }

    func refresh() {
        toggle.state = GlobalKey.current != nil ? .on : .off
        let shown = GlobalKey.current ?? GlobalKey.saved(defaults) ?? GlobalKey.proposed
        key.attributedStringValue = recording ? NSAttributedString(string: "Type a shortcut… ⎋", attributes: [.foregroundColor: Palette.accent, .font: NSFont.systemFont(ofSize: 11.5)])
            : KeyCap.text(shown.display, font: .systemFont(ofSize: 12))
        key.alphaValue = GlobalKey.current == nil && !recording ? 0.5 : 1   // off: what the switch would use
        error.stringValue = GlobalKey.refused ?? ""
        error.isHidden = GlobalKey.refused == nil
    }

    @objc private func switched() {
        let on = toggle.state == .on   // before `stop`, whose refresh sets the switch back
        stop(resuming: false)   // switched while recording: no key there was to put back first
        GlobalKey.use(on ? GlobalKey.saved(defaults) ?? GlobalKey.proposed : nil, app, defaults)
        refresh()
    }

    @objc func startRecording() {
        guard !recording else { return }
        GlobalKey.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.record.window else { return e }
            self.pressed(Shortcut(event: e))
            return nil   // neither the menu nor the hot key sees it
        }
        leaving = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: record.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }   // closed or left: the key there was comes back
        }
        refresh()
    }

    /// A key pressed while recording (the monitor's; tests call it).
    func pressed(_ k: Shortcut) {
        stop(resuming: false)
        if k.flags.isEmpty, k.name == "esc" { GlobalKey.resume() }
        else if k.flags.isEmpty, k.name == "backspace" { GlobalKey.use(nil, app, defaults) }
        else if k.name.isEmpty { GlobalKey.resume(); NSSound.beep() }   // a key keymap.json has no name for
        else { GlobalKey.use(k, app, defaults) }
        refresh()
    }

    func stop(resuming: Bool = true) {
        guard recording else { return }
        monitor.map(NSEvent.removeMonitor)
        leaving.map(NotificationCenter.default.removeObserver)
        (monitor, leaving) = (nil, nil)
        if resuming { GlobalKey.resume() }
        refresh()
    }
}
