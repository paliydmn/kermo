import AppKit
import DFMCore

// Send to Terminal (⌃↩ in the editor) and Execute in Terminal (⌃⇧↩): text into the embedded terminal's line editor on
// the text's own machine — typed, or typed and run. One way in (`toTerminal`) with every rule on it, for whatever hands
// the terminal a command: the editor now.

extension EmbeddedTerminal.Tab {
    /// A line editor holds the terminal and takes text: a local shell at its prompt (the kernel's word: the shell is
    /// the terminal's foreground group); in an SSH tab, the remote side asked for bracketed paste and shows no full-screen
    /// program — the only sign the server gives: a shell or a REPL (mysql) does, vim, less, sudo's password prompt and a
    /// running command don't. Which shell it is (after a `sudo -i` or an `ssh` onward) it doesn't tell.
    var takesText: Bool {
        guard isRunning else { return false }
        if host == nil { return isAtPrompt }
        let t = view.getTerminal()
        return t.bracketedPasteMode && !t.isCurrentBufferAlternate
    }
    var bracketed: Bool { view.getTerminal().bracketedPasteMode }
}

extension EmbeddedTerminal {
    /// What goes into a tab, as bytes (tests: what was typed where, without a shell to read it).
    static var typing: @MainActor (Tab, [UInt8]) -> Void = { $0.view.send(data: $1[...]) }

    /// Till `t` takes text (`takesText`; a local shell: its line editor up too, if it asks for bracketed paste at all)
    /// or `seconds` pass, or it's gone. True: it takes text now.
    func waitForText(_ t: Tab, seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, tabs.contains(where: { $0 === t }), t.exitStatus == nil, !(t.takesText && (t.host != nil || t.bracketed)) {   // not started yet (a lock, a login): wait
            try? await Task.sleep(for: .milliseconds(50))
        }
        return tabs.contains { $0 === t } && t.takesText
    }
}

extension AppDelegate {
    /// What `toTerminal` came to, for the caller's status line.
    enum ToTerminal: Equatable { case sent(String), notSent(String), cancelled }

    /// Each caller's tab (an editor's document), one in its folder: its text goes on there while it takes text — a
    /// script's own `cd` holds from line to line.
    static let ownTabs = NSMapTable<AnyObject, NSUUID>.weakToStrongObjects()

    /// Send to Terminal (`run` false: the text waits in the line, nothing runs) or Execute in Terminal (`run`: ^U, the
    /// text, ↩). Only into a line editor on the text's machine: `target`'s SSH as its user (a root file's too — never a
    /// root shell), else this Mac's shell; never into a program that holds the terminal; never a control character;
    /// several lines only as one bracketed paste. The tab: `owner`'s own (one in `folder`) while it takes text; else
    /// the terminal's current one of that machine (a local shell at its prompt — Execute `cd`s it to `folder` first; an
    /// SSH one for Send only: its remote state is just a sign); else a new one in `folder`. A new SSH tab is never
    /// typed into before its shell takes text (a password prompt is in the tab): Execute starts it with the text as its
    /// command, Send waits for the prompt. Execute asks Touch ID for a locked server, asks on production every time
    /// (↩ = Cancel, on `askOn`) and goes into its production log (`path`: the file it came from). `say`: words meanwhile.
    func toTerminal(_ text: String, run: Bool, on target: SFTPTarget?, folder: String?, path: String?, owner: AnyObject,
                    askOn: NSWindow?, say: @escaping @MainActor (String) -> Void = { _ in }) async -> ToTerminal {
        let body: String
        switch TerminalText.checked(text) {
        case .failure(let r): return .notSent(r.words)
        case .success(let t): body = t
        }
        let user = target?.asUser, name = user.map { SavedServer.name(for: $0) } ?? "this Mac"
        let dir = folder ?? (user == nil ? active.plainFolder ?? panels.lazy.compactMap(\.plainFolder).first ?? NSHomeDirectory() : ".")
        let mine = { (t: EmbeddedTerminal.Tab) in t.target == user && t.takesText }
        let own = { [unowned self] in Self.ownTabs.object(forKey: owner).flatMap { id in terminal.tabs.first { $0.id == id as UUID } }.flatMap { mine($0) ? $0 : nil } }
        if run, let target {
            if await !ServerLock.authorize(target, "run “\(String(body.prefix(60)).bidiVisible)” on") { return .notSent("\(target.host) stays locked") }
            if SavedServer.isProd(target) {
                var c = Confirm("Run this in the terminal on \(name)?", on: user!, action: "Run")
                c.runs = own() != nil ? "In the SSH tab on \(name) it ran in before — as whoever is logged in there now."   // a `sudo -i` there isn't seen
                    : "In a new SSH tab on \(name), as its user" + (target.sudo ? " — not root" : "") + ", in \(dir)."
                c.command = body
                guard await confirm(c, on: askOn) == 0 else { return .cancelled }   // ↩ = Cancel
            }
        }
        // The tab, chosen now (a question may have stood a while): the owner's, the current one, else a new one.
        let mineNow = own()
        var tab = mineNow ?? terminal.current.flatMap { mine($0) && (user == nil || !run) ? $0 : nil }, new = false
        if tab == nil {
            if let user {
                if run {   // it runs the text itself: nothing typed while ssh may ask for a password in the tab — shown, the keys in it
                    terminal.newSSH(user, command: TerminalText.command(body, in: dir))
                    AuditLog.write(user, "command", paths: [path].compactMap { $0 }, command: body, exit: nil)   // its end is the terminal's
                    guard let t = terminal.current else { return .notSent("No terminal tab") }
                    Self.ownTabs.setObject(t.id as NSUUID, forKey: owner)
                    show(t, keys: true, askOn: askOn)
                    return .sent("Started in a new SSH tab on \(name) — it runs once logged in" + (target!.sudo ? ", as its user, not root" : ""))
                }
                terminal.newSSH(user, command: SSHCommand.shell(in: dir))
                say("Waiting for \(name)'s prompt…")
            } else {
                terminal.newShell(cwd: dir)
            }
            guard let t = terminal.current else { return .notSent("No terminal tab") }
            if !run { show(t, keys: true, askOn: askOn) }   // Send: the keys go there now (a password too), not after the wait
            guard await terminal.waitForText(t, seconds: user == nil ? 3 : 30) else {
                return .notSent(user == nil ? "The new shell didn't come up — nothing sent" : "\(name)'s shell didn't ask for text (bracketed paste) — nothing typed")
            }
            (tab, new) = (t, true)
        }
        let t = tab!
        let bytes: [UInt8]
        switch TerminalText.bytes(body, bracketed: t.bracketed, run: run, clear: run) {
        case .failure(let r): return .notSent(r.words)
        case .success(let b): bytes = b
        }
        // Execute in a shell of this Mac's that isn't this text's yet, elsewhere: its folder first.
        if run, user == nil, t !== mineNow, t.shellCwd != EmbeddedTerminal.real(dir) {
            guard let cd = ShellContext.typedCd(dir) else { return .notSent("A control character in the folder's name — nothing sent") }
            EmbeddedTerminal.typing(t, Array(cd.utf8))
        }
        EmbeddedTerminal.typing(t, bytes)
        if run, let user { AuditLog.write(user, "command", paths: [path].compactMap { $0 }, command: body, exit: nil) }
        if run || new { Self.ownTabs.setObject(t.id as NSUUID, forKey: owner) }   // in its folder now: a Send into another tab isn't
        if run || !new { show(t, keys: !run, askOn: askOn) }   // a new tab's Send has the keys there already
        return .sent((run ? "Ran in" : "Typed into") + (new ? " a new tab: " : " ") + t.label + (run ? "" : " — ↩ there runs it"))
    }

    /// The tab in the main window's terminal. `keys`: in front with the keys in the tab (Send: the next thing to do is
    /// there; a new SSH tab: a password may be asked there); else under the caller's window, whose keys they stay.
    private func show(_ t: EmbeddedTerminal.Tab, keys: Bool, askOn: NSWindow?) {
        terminal.select(t.id)
        _ = terminal.show()
        if window.isMiniaturized { window.deminiaturize(nil) }
        if keys {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(t.view)   // `watchFocus` tells the key bar and the menu
        } else if let askOn, askOn.isVisible {
            window.order(.below, relativeTo: askOn.windowNumber)
        } else {
            window.orderFront(nil)
        }
    }

    /// Documents whose text is on its way (a question, a new tab's wait): pressed again meanwhile, nothing goes twice.
    static var sending = Set<ObjectIdentifier>()

    /// Edit ▸ Send to Terminal (⌃↩) / Execute in Terminal (⌃⇧↩) in the editor window: its shown tab's selection, else
    /// the caret's line. Execute without a selection then moves the caret to the next line with something on it.
    func editorToTerminal(run: Bool) {
        guard let h = editorKey, let e = h.active else { return NSSound.beep() }
        guard e.cover == nil else { NSSound.beep(); return e.flash("Its text isn't here yet") }
        guard let place = e.terminalPlace else { NSSound.beep(); return e.flash("Where this copy's file is isn't known — nothing sent") }
        let v = e.current!, sel = v.text.selectedRange(), text = e.storage.mutableString
        guard v.text.selectedRanges.count == 1 else { NSSound.beep(); return e.flash("One selection at a time — nothing sent") }   // a column's pieces aren't one line
        let line = sel.length > 0 ? sel : text.lineRange(for: NSRange(location: sel.location, length: 0))
        let picked = text.substring(with: line), id = ObjectIdentifier(e)
        guard Self.sending.insert(id).inserted else { return NSSound.beep() }
        Task {
            defer { Self.sending.remove(id) }
            let r = await toTerminal(picked, run: run, on: place.target, folder: place.folder, path: place.path, owner: e, askOn: h.window) { e.flash($0) }
            switch r {
            case .sent(let words):
                e.flash(words)
                if run, sel.length == 0, v.text.selectedRange() == sel { e.step(v, after: line) }
            case .notSent(let why):
                NSSound.beep()
                e.flash(why)
            case .cancelled: break
            }
        }
    }
}

extension Editor {
    /// After Execute of the caret's line: the caret to the start of the next line with something on it (step by step,
    /// as RStudio's ⌘↩) — at the end, where it is.
    func step(_ v: DocView, after line: NSRange) {
        let text = storage.mutableString
        var at = NSMaxRange(line)
        while at < text.length {
            let next = text.lineRange(for: NSRange(location: at, length: 0))
            if !text.substring(with: next).allSatisfy(\.isWhitespace) {
                v.text.setSelectedRange(NSRange(location: next.location, length: 0))
                v.text.scrollRangeToVisible(next)
                return
            }
            at = NSMaxRange(next)
        }
    }
}
