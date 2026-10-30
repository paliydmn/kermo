import AppKit
import DFMCore

/// The New / Edit / Duplicate / Save server sheet's form (R-56): Connection · Sign in · Safety · Open, the ssh command
/// it makes as you type (`SSHCommand.line`, the password never), and what's wrong with a field under that field.
/// Production is a switch here, the same `prod` the sidebar's Mark as Production sets. What it reads back: `typed`.
@MainActor final class ServerForm: NSObject, NSTextFieldDelegate {
    let host = NSTextField(), user = NSTextField(), port = NSTextField(), name = NSTextField(), key = NSTextField(),
        password = NSSecureTextField(), shown = NSTextField(), start = NSTextField()
    let choose = NSButton(title: "Choose…", target: nil, action: nil)
    let eye = NSButton(image: Symbol.show.image("Show the password"), target: nil, action: nil)
    /// Only where there's one saved.
    let forget: NSButton?, forgetSudo: NSButton?
    let prod = NSSwitch(), lock = NSSwitch(), readOnly = NSSwitch()
    let preview = NSTextField(wrappingLabelWithString: "")
    let grid: NSGridView
    /// Safety's rows: a row added here (Tools: "Allow installs") goes in without the rest moving.
    static func safety(_ f: ServerForm) -> [(label: String, control: NSView, hint: String)] {
        [("Production", f.prod, "Purple everywhere; changes on it ask first and go into the production log."),
         ("Lock", f.lock, "Touch ID or the Mac password before connecting, editing, duplicating or deleting."),
         ("Read-only", f.readOnly, "Tools run only actions that change nothing.")]
    }
    /// Something changed: the sheet re-lays itself out, its Save buttons follow `typed.issue`.
    var onChange: (() -> Void)?
    private let server: SavedServer, hasPassword: Bool
    private var errors: [SavedServer.Field: NSTextField] = [:]
    private let revealed = NSMutableString()   // the saved password, once shown
    private var actions: [MenuAction] = []

    static let fieldWidth: CGFloat = 300

    init(_ server: SavedServer, hasPassword: Bool, hasSudo: Bool) {
        self.server = server
        self.hasPassword = hasPassword
        forget = hasPassword ? NSButton(checkboxWithTitle: "Forget the saved password", target: nil, action: nil) : nil
        forgetSudo = hasSudo ? NSButton(checkboxWithTitle: "Forget the saved sudo password", target: nil, action: nil) : nil
        forgetSudo?.toolTip = "The one a root panel saved in the Keychain (“Kermo sudo”); the next root panel asks again"
        for (f, value, hint) in [(host, server.host, "address or ~/.ssh/config host"), (user, server.user ?? "", "ssh's default"),
                                 (port, server.port.map(String.init) ?? "", "22"), (name, server.name, "shown in the sidebar; empty = the address"),
                                 (key, server.identityFile ?? "", "ssh's own: agent, config"),
                                 (password, "", hasPassword ? "••••••••" : "ask each time; saved in the Keychain"),
                                 (start, server.startDir ?? "", "for SFTP; empty = the login folder")] {
            f.stringValue = value
            f.placeholderString = hint
        }
        if hasPassword { password.toolTip = "Saved in the Keychain — type to replace" }
        shown.placeholderString = password.placeholderString
        shown.isHidden = true
        eye.bezelStyle = .accessoryBarAction
        eye.toolTip = "Show the password (a saved one asks for Touch ID or the Mac password)"
        prod.state = server.prod ? .on : .off
        lock.state = server.locked ? .on : .off
        readOnly.state = server.readOnly ? .on : .off
        preview.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        preview.textColor = .secondaryLabelColor
        preview.isSelectable = true
        preview.preferredMaxLayoutWidth = 400
        grid = NSGridView(numberOfColumns: 2, rows: 0)
        super.init()
        build()
        for f in [host, user, port, name, key, password, shown, start] { f.delegate = self }
        for s in [prod, lock, readOnly] { actions.append(MenuAction.attach(to: s) { [weak self] in self?.changed() }) }
        actions.append(MenuAction.attach(to: choose) { [weak self] in self?.chooseKey() })
        actions.append(MenuAction.attach(to: eye) { [weak self] in self?.reveal() })
        changed(layout: false)
    }

    private func build() {
        func field(_ f: NSTextField, _ width: CGFloat = Self.fieldWidth) -> NSTextField {
            f.widthAnchor.constraint(equalToConstant: width).isActive = true
            return f
        }
        func row(_ views: [NSView]) -> NSStackView {
            let r = NSStackView(views: views)
            r.spacing = 6
            return r
        }
        func header(_ s: String) {
            let h = NSTextField(labelWithString: s)
            h.font = .systemFont(ofSize: 11, weight: .semibold)
            h.textColor = .secondaryLabelColor
            grid.addRow(with: [h, NSGridCell.emptyContentView])
            let r = grid.row(at: grid.numberOfRows - 1)
            r.mergeCells(in: NSRange(location: 0, length: 2))
            r.cell(at: 0).xPlacement = .leading   // the label column is trailing
            r.topPadding = grid.numberOfRows > 1 ? 10 : 0
        }
        func line(_ label: String, _ view: NSView) { grid.addRow(with: [NSTextField(labelWithString: label), view]) }
        func error(_ f: SavedServer.Field) {
            let e = NSTextField(wrappingLabelWithString: "")
            e.textColor = Palette.fail
            e.font = .systemFont(ofSize: 11)
            e.preferredMaxLayoutWidth = Self.fieldWidth
            errors[f] = e
            grid.addRow(with: [NSGridCell.emptyContentView, e])
        }
        func hint(_ s: String) -> NSTextField {
            let h = NSTextField(wrappingLabelWithString: s)
            h.font = .systemFont(ofSize: 11)
            h.textColor = .secondaryLabelColor
            h.preferredMaxLayoutWidth = Self.fieldWidth - 50
            return h
        }
        let eyeWidth = eye.fittingSize.width + 6
        for f in [password, shown] { f.widthAnchor.constraint(equalToConstant: Self.fieldWidth - eyeWidth).isActive = true }
        header("Connection")
        line("Host", field(host)); error(.host)
        line("User · Port", row([field(user, Self.fieldWidth - 76), field(port, 70)])); error(.user); error(.port)
        line("Name", field(name))
        header("Sign in")
        line("Key", row([field(key, Self.fieldWidth - choose.fittingSize.width - 6), choose])); error(.key)
        line("Password", row([password, shown, eye]))
        for box in [forget, forgetSudo].compactMap({ $0 }) { grid.addRow(with: [NSGridCell.emptyContentView, box]) }
        header("Safety")
        for s in Self.safety(self) { line(s.label, row([s.control, hint(s.hint)])) }
        header("Open")
        line("Start folder", field(start))
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 6
        grid.addRow(with: [NSGridCell.emptyContentView, NSGridCell.emptyContentView])   // the preview's, across both
        let last = grid.row(at: grid.numberOfRows - 1)
        last.mergeCells(in: NSRange(location: 0, length: 2))
        last.topPadding = 12
        last.cell(at: 0).contentView = preview
        last.cell(at: 0).xPlacement = .leading
    }

    /// The server as typed (the tunnels as they were: the sheet doesn't show them).
    var typed: SavedServer {
        var s = server
        let v = { (f: NSTextField) in f.stringValue.trimmingCharacters(in: .whitespaces) }
        s.name = v(name)
        s.host = v(host)
        s.user = v(user).isEmpty ? nil : v(user)
        s.port = v(port).isEmpty ? nil : Int(v(port)) ?? 0   // 0: not a port, `issue` says so
        s.identityFile = v(key).isEmpty ? nil : v(key)
        s.startDir = v(start).isEmpty ? nil : v(start)
        s.prod = prod.state == .on
        s.locked = lock.state == .on
        s.readOnly = readOnly.state == .on
        return s
    }
    /// The password to store: as typed (spaces count); a saved one shown and left as it was isn't stored again (so it
    /// never follows a changed Host; see `storePassword`).
    var newPassword: String {
        let t = shown.isHidden ? password.stringValue : shown.stringValue
        return t == revealed as String ? "" : t
    }

    func controlTextDidChange(_ obj: Notification) { changed() }

    /// The preview and the errors as typed now; nothing said for an empty Host, only no Save.
    private func changed(layout: Bool = true) {
        let s = typed, issue = s.issue
        preview.stringValue = s.host.isEmpty ? "ssh …" : SSHCommand.line(s.target)
        for (f, e) in errors {
            let say = issue?.field == f && !(f == .host && s.host.isEmpty) ? issue!.message : ""
            e.stringValue = say
            grid.cell(for: e)?.row?.isHidden = say.isEmpty
        }
        if layout { onChange?() }
    }

    /// Key file: typed, or chosen in ~/.ssh (hidden, and a pain to type) — a sheet over this one.
    private func chooseKey() {
        let open = NSOpenPanel()
        open.showsHiddenFiles = true
        open.directoryURL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".ssh"))
        open.message = "The private key (not the .pub one)"
        guard let over = key.window else { return }
        open.beginSheetModal(for: over) { [weak self] r in
            guard let self, r == .OK, let url = open.url else { return }
            key.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            changed()
        }
    }

    /// The eye: as text, or dots; the saved password after Touch ID or the Mac password, every time.
    private func reveal() {
        let show = { [self] (on: Bool) in
            (password.isHidden, shown.isHidden) = (on, !on)
            eye.image = (on ? Symbol.hide : .show).image(on ? "Hide the password" : "Show the password")
            password.window?.makeFirstResponder(on ? shown : password)
        }
        guard shown.isHidden else {
            password.stringValue = shown.stringValue
            return show(false)
        }
        guard password.stringValue.isEmpty, hasPassword else {
            shown.stringValue = password.stringValue
            return show(true)
        }
        Task {
            guard await ServerLock.authenticate("show the saved password for “\(server.title)”") else { return }
            guard let p = SSHPasswords.get(server.target) else { return NSSound.beep() }
            revealed.setString(p)
            shown.stringValue = p
            show(true)
        }
    }
}
