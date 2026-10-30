import AppKit
import DFMCore

/// ssh's questions (`Askpass`) and the sudo password, in Kermo's style (R-52): the server's name in the title and its
/// strip, one sentence on where the answer goes and what for, the field, Cancel · Continue. One at a time, on the
/// window in front (a Picker that stays open while it asks, else the main window); a question whose ssh is gone goes.
@MainActor enum AskpassSheet {
    private static var queue: Task<Void, Never>?

    static func ask(_ r: Askpass.Request, gone: CancelFlag) async -> String? {
        let before = queue
        let mine = Task { @MainActor () -> String? in
            await before?.value
            guard !gone.isCancelled else { return nil }
            let q = question(r)
            let alert = q.confirm.alert()
            let over = window()
            gone.onCancel { DispatchQueue.main.async { over.endSheet(alert.window, returnCode: .cancel) } }   // ssh is gone
            defer { gone.onCancel(nil) }
            if let f = q.field { alert.window.initialFirstResponder = f }
            return await AppDelegate.sheet(alert, on: over) == 0 && !gone.isCancelled ? q.field?.stringValue ?? "yes" : nil
        }
        queue = Task { _ = await mine.value }
        return await mine.value
    }

    /// Where a secret is asked: a Picker that stays open while it asks (a restart from Services…), else the window in
    /// front, not a panel that closes then; the main window. The Dock icon bounces when the app is behind.
    static func window() -> NSWindow {
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        let main = (NSApp.delegate as? AppDelegate)?.window ?? NSApp.mainWindow!
        return Picker.current.flatMap { $0.isHolding ? $0.window : nil } ?? NSApp.keyWindow.flatMap { $0 is NSPanel || $0.isSheet ? nil : $0 } ?? main
    }

    /// The question for ssh's `prompt`: a password, a key's passphrase, "continue connecting (yes/no)?", or anything
    /// else ssh or git asks (a code, a user name). The server: whose login it is (`$DFM_ASKPASS_TARGET`), else the
    /// user@host in the prompt.
    static func question(_ r: Askpass.Request) -> (confirm: Confirm, field: NSTextField?) {
        let lines = r.prompt.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let ask = lines.last ?? r.prompt
        let login = r.target.isEmpty ? Self.login(in: ask) : r.target
        let t = login.map(Self.target)
        let name = t.map { SavedServer.name(for: $0) } ?? login ?? "the server"
        let why = r.why.isEmpty ? "" : " " + r.why + "."
        var c = Confirm(ask, on: t, action: "Continue")
        c.returnCancels = false
        var field: NSTextField? = NSSecureTextField()
        if ask.contains("(yes/no") {   // a server not in known_hosts yet
            c.title = "Continue connecting to \(name)?"
            c.command = lines.dropLast().joined(separator: "\n")
            c.note = "This Mac hasn't seen this server before: its key goes into known_hosts. Check the fingerprint with the server's admin if you can." + why
            c.returnCancels = nil   // on production ↩ is Cancel
            field = nil
        } else if ask.hasPrefix("Enter passphrase for key '"), let end = ask.range(of: "'", options: .backwards), end.lowerBound > ask.index(ask.startIndex, offsetBy: 26) {
            let key = String(ask[ask.index(ask.startIndex, offsetBy: 26)..<end.lowerBound])
            c.title = "Passphrase for the key “\((key as NSString).lastPathComponent)”"
            c.note = "It unlocks \((key as NSString).abbreviatingWithTildeInPath) for ssh\(t == nil ? "" : " to \(name)") and goes nowhere else." + why
        } else if ask.lowercased().hasSuffix("password:"), let login = Self.login(in: ask) {
            c.title = "Password for \(login)"
            c.note = "It goes to ssh, for \(name), and nowhere else." + why
        } else {   // a one-time code, git's user name or password
            c.title = ask.hasSuffix(":") ? String(ask.dropLast()) : ask
            c.note = (lines.count > 1 ? lines.dropLast().joined(separator: " ") + " " : "") + (r.why.isEmpty ? "ssh asks it." : r.why + ".")
            if ask.hasPrefix("Username") { field = NSTextField() }
        }
        if let field {
            field.widthAnchor.constraint(equalToConstant: Confirm.width).isActive = true
            c.extra = field
        }
        return (c, field)
    }

    /// "user@host" in ssh's prompts: "user@host's password:", "(user@host) Password:".
    static func login(in prompt: String) -> String? {
        if prompt.hasPrefix("("), let close = prompt.firstIndex(of: ")") { return String(prompt[prompt.index(after: prompt.startIndex)..<close]) }
        if let end = prompt.range(of: "'s password:") { return String(prompt[..<end.lowerBound]) }
        return nil
    }

    /// "user@host", a tab and the port (`$DFM_ASKPASS_TARGET`), or "user@host" from a prompt, as a target.
    static func target(_ login: String) -> SFTPTarget {
        let parts = login.split(separator: "\t", maxSplits: 1)
        return SFTPTarget(host: String(parts.first ?? ""), port: parts.count > 1 ? Int(parts[1]) : nil)
    }

    /// A root panel's sudo password (`SudoPasswords`): the same question, with Save in Keychain.
    static func sudo(_ t: SFTPTarget, wrong: Bool) -> (confirm: Confirm, field: NSSecureTextField, save: NSButton) {
        var c = Confirm((wrong ? "Sorry, try again: " : "") + "sudo password on \(SavedServer.name(for: t.asUser))", on: t, action: "Continue")
        c.returnCancels = false
        c.note = "For root there: a root panel, a reload, a restart, a tool. It goes to sudo there, through ssh, and nowhere else."
        let field = NSSecureTextField(), save = NSButton(checkboxWithTitle: "Save in Keychain", target: nil, action: nil)
        save.toolTip = "Kept as “Kermo sudo” in the login keychain, apart from the ssh password; gone once sudo refuses it, or with the saved server"
        field.widthAnchor.constraint(equalToConstant: Confirm.width).isActive = true
        c.extra = Confirm.stack([field, save])
        return (c, field, save)
    }
}
