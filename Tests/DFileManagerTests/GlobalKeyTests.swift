import AppKit
import Carbon.HIToolbox
import Testing
@testable import DFileManager
@testable import DFMCore

// The editor from any app: the global shortcut, the Dock menu, kermo://, `fm --new`, life with no windows, and a
// question on the hidden main window. In the serialized suite: they share the editor window, the shortcut and the
// activation seam with the editor's and the Monitor's tests.

/// Odd keys only: the shortcut's defaults are a test suite's, yet a real registration would take the key from every app.
private let odd = Shortcut("ctrl+opt+shift+cmd+f11")!, odd2 = Shortcut("ctrl+opt+cmd+f11")!

/// The hot key's and the activation's stand-ins: what's registered, how Kermo came forward.
@MainActor private final class Outside {
    var registered: Shortcut?, refuse: [Shortcut: OSStatus] = [:]
    var activations: [(NSApplication.ActivationPolicy, NSWindow?)] = []
    let defaults: UserDefaults, suite = "kermo-e5-" + UUID().uuidString
    private let was = (keys: GlobalKey.system, activation: AppDelegate.activation)
    init() {
        defaults = UserDefaults(suiteName: suite)!
        GlobalKey.system = ({ [weak self] k in
            if let s = self?.refuse[k] { return s }
            self?.registered = k
            return noErr
        }, { [weak self] in self?.registered = nil })
        AppDelegate.activation = { [weak self] in self?.activations.append(($0, $1)) }
    }
    func done(_ app: AppDelegate) {
        GlobalKey.use(nil, app, defaults)
        (GlobalKey.system, AppDelegate.activation) = was
        defaults.removePersistentDomain(forName: suite)
    }
}

/// The editor window gone, as at a crash: nothing written, its documents out of the lookups.
@MainActor private func noEditor() {
    guard let h = EditorHost.shared else { return }
    for e in h.docs { e.closed(); e.host = nil }
    h.drafts?.release()
    h.window?.orderOut(nil)
    EditorHost.shared = nil
}

@MainActor private func typeIn(_ e: Editor, _ s: String) {
    e.textView.insertText(s, replacementRange: NSRange(location: (e.textView.string as NSString).length, length: 0))
}

@MainActor private func until(_ what: String, _ cond: () -> Bool) async throws {
    for _ in 0..<250 where !cond() { try await Task.sleep(for: .milliseconds(20)) }
    #expect(cond(), "\(what)")
}

private func scratch() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/kermo-e5-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

extension EditorWindowTests {
    /// Only ⌃ or ⌘ shortcuts, none macOS or Kermo takes first; macOS's refusal keeps the shortcut there was, saved as
    /// it was, and says why — never on and not working.
    @Test func theGlobalKeyNeedsControlOrCommandAndAKeyOfItsOwn() throws {
        let (app, _, _, done) = try toolsApp()
        let o = Outside()
        defer { o.done(app); done() }
        #expect(GlobalKey.use(odd, app, o.defaults) == nil && GlobalKey.current == odd && o.registered == odd)
        #expect(o.defaults.string(forKey: "editorHotKey") == odd.spec)
        for spec in ["opt+e", "opt+shift+e", "shift+f6", "f5"] {
            let k = Shortcut(spec)!
            #expect(GlobalKey.use(k, app, o.defaults) == "\(k.display) can't be used: macOS needs ⌃ or ⌘ in a shortcut for every app.")
            #expect(GlobalKey.current == odd && o.registered == odd, "\(spec): the one before stays")
        }
        #expect(GlobalKey.use(Shortcut("ctrl+cmd+space")!, app, o.defaults) == "⌃⌘Space can't be used: macOS takes it first (emoji).")
        let connect = try #require(GlobalKey.use(Shortcut("ctrl+cmd+k")!, app, o.defaults))
        #expect(connect.hasPrefix("⌃⌘K is Kermo's Connect to Server") && connect.hasSuffix(": pick another or change that one in Keys."), "\(connect)")
        let copy = try #require(GlobalKey.use(Shortcut("cmd+c")!, app, o.defaults))
        #expect(copy.hasPrefix("⌘C stays Edit ▸ Copy's"), "\(copy)")

        o.refuse[odd2] = OSStatus(eventHotKeyExistsErr)
        #expect(GlobalKey.use(odd2, app, o.defaults) == "macOS refused ⌃⌥⌘F11: another app has it.")
        #expect(GlobalKey.current == odd && o.registered == odd && o.defaults.string(forKey: "editorHotKey") == odd.spec)
        #expect(GlobalKey.refused == "macOS refused ⌃⌥⌘F11: another app has it.", "said in Settings")
        o.refuse[odd2] = -50
        #expect(GlobalKey.use(odd2, app, o.defaults) == "macOS refused ⌃⌥⌘F11 (error -50).")
        o.refuse[odd] = OSStatus(eventHotKeyExistsErr)   // and the one before taken meanwhile (during Record…)
        o.refuse[odd2] = OSStatus(eventHotKeyExistsErr)
        #expect(GlobalKey.use(odd2, app, o.defaults) == "macOS refused ⌃⌥⌘F11: another app has it. ⌃⌥⇧⌘F11, the one before, couldn't be taken back: it's off.")
        #expect(GlobalKey.current == nil && o.registered == nil)
        (o.refuse[odd], o.refuse[odd2]) = (nil, nil)
        #expect(GlobalKey.use(odd2, app, o.defaults) == nil && GlobalKey.current == odd2 && GlobalKey.refused == nil)

        #expect(GlobalKey.use(nil, app, o.defaults) == nil && GlobalKey.current == nil && o.registered == nil)
        #expect(o.defaults.object(forKey: "editorHotKey") == nil, "off: no key saved")
    }

    /// Carbon for real, with an odd key: registered and let go; one this process already holds exclusively — as another
    /// Kermo would — is refused and said; the ISO key's second code refused lets the first go too. At launch a saved
    /// key comes back; an unusable one, or Kermo's own, isn't asked for.
    @Test func theRealHotKeyIsExclusive() throws {
        let (app, _, _, done) = try toolsApp()
        let suite = "kermo-e5-" + UUID().uuidString, d = UserDefaults(suiteName: suite)!
        defer { GlobalKey.use(nil, app, d); d.removePersistentDomain(forName: suite); done() }
        #expect(GlobalKey.use(odd, app, d) == nil && GlobalKey.current == odd)
        GlobalKey.use(nil, app, d)
        var ref: EventHotKeyRef?
        #expect(RegisterEventHotKey(UInt32(odd.keyCode), UInt32(controlKey | optionKey | shiftKey | cmdKey), EventHotKeyID(signature: 0x54455354, id: 9),
                                    GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref) == noErr)
        #expect(GlobalKey.use(odd, app, d) == "macOS refused ⌃⌥⇧⌘F11: another app has it." && GlobalKey.current == nil)
        ref.map { _ = UnregisterEventHotKey($0) }

        let mods = UInt32(controlKey | optionKey | shiftKey | cmdKey), grave = Shortcut("ctrl+opt+shift+cmd+`")!
        #expect(RegisterEventHotKey(10, mods, EventHotKeyID(signature: 0x54455354, id: 10), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref) == noErr)
        #expect(GlobalKey.use(grave, app, d) == "macOS refused ⌃⌥⇧⌘`: another app has it.", "§ (code 10) held")
        ref.map { _ = UnregisterEventHotKey($0) }
        var fifty: EventHotKeyRef?
        #expect(RegisterEventHotKey(50, mods, EventHotKeyID(signature: 0x54455354, id: 50), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &fifty) == noErr,
                "` (code 50) let go with it")
        fifty.map { _ = UnregisterEventHotKey($0) }

        d.set(odd.spec, forKey: "editorHotKey")
        GlobalKey.start(app, d)
        #expect(GlobalKey.current == odd && GlobalKey.refused == nil)
        GlobalKey.use(nil, app, d)
        for (spec, said) in [("opt+e", "⌥E can't be used"), ("ctrl+cmd+k", "⌃⌘K is Kermo's Connect to Server")] {
            d.set(spec, forKey: "editorHotKey")
            GlobalKey.start(app, d)
            #expect(GlobalKey.current == nil && GlobalKey.refused?.hasPrefix(said) == true, "\(spec)")
        }
    }

    /// Settings ▸ General: Record… takes the shortcut off while it waits (else pressing it would run it), ⎋ and leaving
    /// put it back, ⌫ turns it off, a refused key leaves the one before and says why in red. The switch turns ⌃⌘E on.
    @Test func recordingTakesTheKeyOffTillItEnds() throws {
        let (app, _, _, done) = try toolsApp()
        let o = Outside()
        defer { o.done(app); done() }
        GlobalKey.use(odd, app, o.defaults)
        let r = GlobalKeyRecorder(app: app, defaults: o.defaults)
        #expect(r.toggle.state == .on && r.error.isHidden)
        r.startRecording()
        #expect(o.registered == nil && r.recording)
        r.pressed(Shortcut("esc")!)
        #expect(o.registered == odd && !r.recording && GlobalKey.current == odd)
        r.startRecording()
        r.pressed(Shortcut("opt+e")!)
        #expect(o.registered == odd && !r.error.isHidden && r.error.stringValue.hasPrefix("⌥E can't be used"))
        r.startRecording()
        r.pressed(odd2)
        #expect(o.registered == odd2 && r.error.isHidden && o.defaults.string(forKey: "editorHotKey") == odd2.spec)
        r.startRecording()
        r.stop()   // the window closed or went to the back
        #expect(o.registered == odd2 && !r.recording)
        r.startRecording()
        r.pressed(Shortcut("backspace")!)
        #expect(o.registered == nil && r.toggle.state == .off && o.defaults.object(forKey: "editorHotKey") == nil)
        GlobalKey.use(odd, app, o.defaults)
        r.startRecording()
        r.toggle.state = .off   // flipped while it waits for a key
        (r.toggle.target as? NSObject)?.perform(r.toggle.action)
        #expect(o.registered == nil && !r.recording && GlobalKey.current == nil && r.toggle.state == .off)
        r.toggle.state = .on
        (r.toggle.target as? NSObject)?.perform(r.toggle.action)
        #expect(o.registered == GlobalKey.proposed && GlobalKey.proposed.display == "⌃⌘E")
        GlobalKey.use(nil, app, o.defaults)
    }

    /// The other way round: a command given the shortcut in Keys or keymap.json is refused in the same words — the
    /// hot key would take it first; a command moved off it says nothing; Reset doesn't give a command's own key back
    /// while the shortcut has it.
    @Test func keysRefuseTheGlobalKey() throws {
        let (app, _, _, done) = try toolsApp()
        let o = Outside()
        defer { o.done(app); done() }
        GlobalKey.use(odd, app, o.defaults)
        let said = "⌃⌥⇧⌘F11 is Kermo's New editor document from any app: pick another or change that one in Settings ▸ General."
        #expect(AppDelegate.keymapProblems("go.home", [odd], was: [], fixed: [:]) == ["keymap.json: go.home: " + said])
        #expect(AppDelegate.keymapProblems("go.home", [odd2], was: [odd], fixed: [:]).isEmpty, "moved off it: no problem")
        #expect(app.newKeyProblems("go.home", [odd], old: [], defaults: []) == [said])
        GlobalKey.use(nil, app, o.defaults)
        #expect(app.newKeyProblems("go.home", [odd], old: [], defaults: []).isEmpty)

        // Connect to Server moved off ⌃⌘K, ⌃⌘K the shortcut: Keys' reset of Connect says so and keeps the move.
        let connect = try #require(app.commands.first { $0.keys.contains(Shortcut("ctrl+cmd+k")!) })
        app.writeKeymap([connect.id: [odd2.spec]])
        #expect(GlobalKey.use(Shortcut("ctrl+cmd+k")!, app, o.defaults) == nil)
        let keys = KeysPane(app: app)
        keys.reset(connect.id)
        #expect(keys.said == "⌃⌘K is Kermo's New editor document from any app: pick another or change that one in Settings ▸ General.")
        #expect(try AppDelegate.readKeymap()[connect.id] == [odd2.spec])
        app.writeKeymap([:])   // its entry deleted by hand: Reload Config says so
        #expect(app.configProblems.contains("keymap.json: \(connect.id): ⌃⌘K is Kermo's New editor document from any app: pick another or change that one in Settings ▸ General."),
                "\(app.configProblems)")
        GlobalKey.use(nil, app, o.defaults)
        app.writeKeymap([:])
    }

    /// From outside: a new Untitled, the editor in front through `activation`, the text in focus; again on an empty one
    /// never typed in — the same tab; under a sheet or an app-modal question only Kermo comes forward; Show Editor
    /// makes none.
    @Test func fromOutsideAnEmptyUntitledIsReused() throws {
        _ = NSApplication.shared
        noEditor()
        let (app, _, _, done) = try toolsApp()
        let o = Outside()
        defer { o.done(app); done(); noEditor() }
        app.editorFromOutside(new: true)
        let h = EditorHost.tabs
        let u = try #require(h.active)
        #expect(h.docs.count == 1 && u.url == nil && h.window?.firstResponder === u.textView)
        #expect(o.activations.last?.0 == .regular && o.activations.last?.1 === h.window)
        app.editorFromOutside(new: true)
        #expect(h.docs.count == 1 && h.active === u && o.activations.count == 2, "pressed again while it comes up: the same tab")
        typeIn(u, "x")
        app.editorFromOutside(new: true)
        #expect(h.docs.count == 2 && h.active !== u)
        app.editorFromOutside(new: false)
        #expect(h.docs.count == 2, "Show Editor")

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        h.window?.beginSheet(sheet) { _ in }
        let n = o.activations.count
        app.editorFromOutside(new: true)
        #expect(h.docs.count == 2 && o.activations.count == n + 1 && o.activations.last?.1 === h.window, "a question up: just in front with it")
        h.window?.endSheet(sheet)

        let modal = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let session = NSApp.beginModalSession(for: modal)
        app.editorFromOutside(new: true)
        NSApp.endModalSession(session)
        modal.orderOut(nil)
        #expect(h.docs.count == 2 && o.activations.last?.1 === modal)
        h.docs.forEach { $0.close() }
    }

    /// While Quit writes the last drafts nothing new is made: it would be lost.
    @Test func nothingFromOutsideWhileQuitting() async throws {
        _ = NSApplication.shared
        noEditor()
        let dir = try scratch()
        let (app, _, _, done) = try toolsApp()
        let o = Outside()
        var replies: [Bool] = []
        defer { o.done(app); done(); noEditor(); AppDelegate.replyToQuit = { NSApp.reply(toApplicationShouldTerminate: $0) }
                try? FileManager.default.removeItem(atPath: dir) }
        EditorHost.restore(dir, onServer: { _, _, _, _ in ({ _ in }, {}) })
        AppDelegate.replyToQuit = { replies.append($0) }
        AppDelegate.answering = { _, _, _ in 0 }
        let h = EditorHost.tabs, u = Editor.untitled()
        typeIn(u, "kept")
        #expect(app.applicationShouldTerminate(NSApp) == .terminateLater)
        app.editorFromOutside(new: true)
        #expect(h.docs.count == 1 && o.activations.isEmpty)
        try await until("answered") { replies == [true] }
        u.close()
    }

    /// With the shortcut on, closing the main window hides it — unasked, the quit question not answered for nothing —
    /// and the last window closed leaves Kermo in the Dock; ⌘Q still asks. Off: as before.
    @Test func theGlobalKeyKeepsKermoWithNoWindows() throws {
        _ = NSApplication.shared
        noEditor()
        let (app, _, _, done) = try toolsApp()
        let o = Outside()
        var asked = 0
        defer { o.done(app); done(); noEditor() }
        let u = Editor.untitled()   // no drafts here: its text is unsaved, so Quit asks
        typeIn(u, "unsaved")
        let shown = NSApp.windows.filter { AppDelegate.keepsAlive($0, besides: app.window) }
        shown.forEach { $0.orderOut(nil) }   // the editor too: nothing else keeps Kermo
        AppDelegate.answering = { _, _, _ in asked += 1; return 1 }   // Cancel
        #expect(app.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        #expect(!app.windowShouldClose(app.window) && asked == 1, "off: closing the main window is Quit, which asks")
        GlobalKey.use(odd, app, o.defaults)
        #expect(app.windowShouldClose(app.window) && asked == 1, "on: it hides, unasked")
        #expect(!app.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        #expect(app.applicationShouldTerminate(NSApp) == .terminateCancel && asked == 2, "⌘Q later still asks")
        shown.forEach { $0.orderFront(nil) }
        u.close()
    }

    /// The Dock icon's menu: New Editor Document and Show Editor, run as from outside.
    @Test func theDockMenuHasTheEditor() throws {
        noEditor()
        let (app, _, _, done) = try toolsApp()
        let o = Outside()
        defer { o.done(app); done(); noEditor() }
        let m = try #require(app.applicationDockMenu(NSApp))
        #expect(m.items.map(\.title) == ["New Editor Document", "Show Editor"])
        for it in m.items { _ = (it.target as? NSObject)?.perform(it.action, with: it) }
        #expect(EditorHost.tabs.docs.count == 1 && o.activations.count == 2 && o.activations.allSatisfy { $0.1 === EditorHost.tabs.window })
        EditorHost.tabs.docs.forEach { $0.close() }
    }

    /// kermo://new and kermo://show in any case, nothing else: no path, query, part or user; never to the panels or the
    /// main window. A file beside it goes to the panels as before. At launch they wait for the editor's restore.
    @Test func kermoURLsOpenTheEditorAndNothingElse() async throws {
        noEditor()
        let dir = try scratch()
        let (app, a, _, done) = try toolsApp()
        let o = Outside()
        defer { o.done(app); done(); noEditor(); try? FileManager.default.removeItem(atPath: dir) }
        for bogus in ["kermo://new?x=y", "kermo://other", "kermo:new", "kermo://new/", "kermo://u@new", "kermo://new#a", "kermo://show/x", "kermo://new:1",
                      "kermo://new/../etc", "kermo://n%65w"] {
            app.application(NSApp, open: [URL(string: bogus)!])
        }
        #expect(EditorHost.shared == nil && o.activations.isEmpty)
        app.application(NSApp, open: [URL(string: "KERMO://NEW")!])
        #expect(EditorHost.tabs.docs.count == 1 && o.activations.count == 1 && o.activations[0].1 === EditorHost.tabs.window)
        app.application(NSApp, open: [URL(string: "kermo://show")!])
        #expect(EditorHost.tabs.docs.count == 1 && o.activations.count == 2)
        app.application(NSApp, open: [URL(fileURLWithPath: dir), URL(string: "kermo://new")!])
        #expect(o.activations.suffix(2).map { $0.1 } == [app.window, EditorHost.tabs.window], "the panels' window, then the editor's")
        try await until("the panel there") { a.path == dir }
        EditorHost.tabs.docs.forEach { $0.close() }
        noEditor()

        // A cold launch: a draft "Untitled 1" comes back, kermo://new adds "Untitled 2" after it.
        EditorHost.restore(dir + "/drafts", onServer: { _, _, _, _ in ({ _ in }, {}) })
        let u = Editor.untitled()
        typeIn(u, "draft")
        _ = await EditorHost.tabs.commit(durable: true)
        noEditor()
        let panels = app.panels
        app.panels = []
        app.application(NSApp, open: [URL(string: "kermo://new")!])
        #expect(EditorHost.shared == nil, "waits for the launch")
        app.panels = panels
        EditorHost.restore(dir + "/drafts", onServer: { _, _, _, _ in ({ _ in }, {}) })
        app.openPending()
        let h = EditorHost.tabs
        #expect(h.docs.map(\.name) == ["Untitled 1", "Untitled 2"] && h.active === h.docs.last)
        try await until("the draft read") { h.docs.first?.textView.string == "draft" }
        h.docs.forEach { $0.close() }
    }

    /// D-179: a question that falls back to the main window while it's out of sight brings it back first — a sheet on a
    /// window not shown isn't put up at all, and whatever waits on its answer waits for good. Kermo not in front (a save
    /// in another app): the window shows and the Dock icon comes back to bounce, without taking the keys.
    @Test func aQuestionOnTheHiddenMainWindowBringsItBack() async throws {
        let (app, _, _, done) = try toolsApp()
        let o = Outside()
        defer { o.done(app); app.window?.orderOut(nil); done() }
        AppDelegate.activation = { [weak o] in o?.activations.append(($0, $1)); $1?.orderFront(nil) }   // as it does: the window shows
        #expect(!app.window.isVisible)
        func answered() async throws {
            try await until("a sheet") { app.window.attachedSheet != nil }
            #expect(o.activations.count == 1 && o.activations[0].0 == .regular && app.window.isVisible)
            #expect(NSApp.isActive ? o.activations[0].1 === app.window : o.activations[0].1 == nil, "in front only if Kermo is")
            o.activations = []
            if let s = app.window.attachedSheet { app.window.endSheet(s, returnCode: .alertSecondButtonReturn) }
            try await until("gone") { app.window.attachedSheet == nil }
            app.window.orderOut(nil)
        }
        Task { _ = await app.choose("Upload?", info: "", ["Upload", "Cancel"]) }
        try await answered()
        Task { _ = await app.confirm(Confirm("Replace?", action: "Replace")) }
        try await answered()
        app.showError(JobErrorMessage("It failed"))
        try await answered()
    }

    /// Open Kermo at Login moved to General, beside the shortcut; Monitor has it no more.
    @Test func openAtLoginIsInGeneral() throws {
        let (app, _, _, done) = try toolsApp()
        defer { done() }
        func rows(_ tab: String) -> [String] { app.settingsTabs.first { $0.title == tab }?.groups.flatMap(\.rows).map(\.title) ?? [] }
        #expect(rows("General").prefix(2) == ["New editor document from any app", "Open Kermo at login"])
        #expect(!rows("Monitor").contains("Open Kermo at login"))
    }
}

/// `fm --new` gives `open` the fixed URL and nothing else; the old forms are as they were; another `--` flag is a
/// usage line and code 2, nothing opened.
@Test func fmNewOpensOnlyTheFixedURL() throws {
    let fm = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin/fm").path
    let stub = try scratch()
    defer { try? FileManager.default.removeItem(atPath: stub) }
    try Data("#!/bin/sh\necho \"$@\"\n".utf8).write(to: URL(fileURLWithPath: stub + "/open"))
    chmod(stub + "/open", 0o755)
    func run(_ args: [String]) throws -> (out: String, code: Int32) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [fm] + args
        p.environment = ["PATH": stub + ":/usr/bin:/bin"]
        (p.standardOutput, p.standardError) = (out, FileHandle.nullDevice)
        try p.run()
        p.waitUntilExit()
        return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), p.terminationStatus)
    }
    #expect(try run(["--new"]) == ("-b com.dmn.dfilemanager kermo://new\n", 0))
    #expect(try run(["/a", "/b"]) == ("-b com.dmn.dfilemanager /a /b\n", 0))
    #expect(try run([]) == ("-b com.dmn.dfilemanager .\n", 0))
    #expect(try run(["--new", "x"]) == ("", 2))
    #expect(try run(["--show"]) == ("", 2))
    #expect(try run(["-n"]) == ("", 2), "none of open's options: -n would start a second Kermo")
    #expect(try run(["/a", "--new"]) == ("", 2))
}
