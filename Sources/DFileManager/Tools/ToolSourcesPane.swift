import AppKit
import DFMCore

/// Settings → Tools (Tools PR 8): the catalogs Kermo takes tools from (`tools/catalogs.json`) — each on or off, one
/// added by its address and the key it signs with, one removed. None is fetched from here: only when the Catalog opens,
/// or by Check for Updates….
@MainActor
final class ToolSourcesPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let app: AppDelegate
    let table = NSTableView()
    private var kept: [AnyObject] = []

    init(app: AppDelegate) {
        self.app = app
        super.init(frame: NSRect(origin: .zero, size: SettingsWindow.size))
        for (id, title, width) in [("on", "On", 34.0), ("name", "Catalog", 150), ("url", "Address", 360)] {
            let c = NSTableColumn(identifier: .init(id))
            (c.title, c.width) = (title, width)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Catalogs")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let add = NSButton(title: "Add…", target: nil, action: nil), remove = NSButton(title: "Remove…", target: nil, action: nil)
        kept += [MenuAction.attach(to: add) { [unowned self] in Task { await addAsked() } }, MenuAction.attach(to: remove) { [unowned self] in Task { await removeSelected() } }]
        let about = NSTextField(wrappingLabelWithString: "Where Tools ▸ Catalog takes tools from. Kermo fetches a catalog only when you open the Catalog "
                                + "or choose Check for Updates…, and takes it only signed with its key. A team's own: the https:// address of its folder, "
                                + "or a folder on a disk (file://), and its Ed25519 public key.")
        about.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [about, scroll, NSStackView(views: [add, remove])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for v in [about, scroll] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var catalogs: ToolCatalogs { app.tools.catalogs }

    /// Why `s` won't do — no name, an address that isn't https:// or file://, a key that isn't one, a catalog that's
    /// there already — or nil: added, and saved.
    func add(_ s: ToolCatalog.Source) -> String? {
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { return "A catalog needs a name." }
        guard let base = s.base else { return "Its address starts with https:// (or file:// for a folder on a disk)." }
        if s.publicKey == nil { return "Its key is the catalog's Ed25519 public key: 32 bytes, base64." }
        if catalogs.sources.contains(where: { $0.base == base }) { return "That catalog is in the list already." }
        catalogs.sources.append(s)
        catalogs.saveSources()
        table.reloadData()
        return nil
    }

    func setOn(_ row: Int, _ on: Bool) {
        catalogs.sources[row].off = on ? nil : true
        catalogs.saveSources()
    }

    private func addAsked() async {
        let fields = ["Name", "Address", "Public key"].map { placeholder -> NSTextField in
            let f = NSTextField(string: "")
            f.placeholderString = placeholder
            f.frame.size.width = 380
            return f
        }
        let box = NSStackView(views: fields)
        (box.orientation, box.spacing) = (.vertical, 6)
        box.frame.size = NSSize(width: 380, height: 84)
        var said = ""
        while true {
            let alert = AppDelegate.alert("Add a Catalog", info: said.isEmpty ? "Its tools come in only signed with this key." : said, ["Add", "Cancel"])
            alert.accessoryView = box
            alert.window.initialFirstResponder = fields[0]
            guard let w = window, await AppDelegate.sheet(alert, on: w) == 0 else { return }
            let s = ToolCatalog.Source(name: fields[0].stringValue.trimmingCharacters(in: .whitespaces), url: fields[1].stringValue.trimmingCharacters(in: .whitespaces),
                                       key: fields[2].stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let why = add(s) else { return }
            said = why
        }
    }

    private func removeSelected() async {
        let r = table.selectedRow
        guard catalogs.sources.indices.contains(r) else { return NSSound.beep() }
        let s = catalogs.sources[r]
        var c = Confirm("Remove the catalog “\(s.name)”?", action: "Remove")
        c.runs = "Tools you got from it stay, and keep working; Kermo just won't look there for updates."
        guard await app.confirm(c, on: window) == 0 else { return }
        catalogs.sources.remove(at: r)
        catalogs.saveSources()
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { catalogs.sources.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let s = catalogs.sources[row]
        switch tableColumn?.identifier.rawValue {
        case "on":
            let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            box.state = s.off == true ? .off : .on
            box.setAccessibilityLabel("\(s.name) on")
            kept.append(MenuAction.attach(to: box) { [unowned self, unowned box] in setOn(row, box.state == .on) })
            return box
        case "name": return NSTextField(labelWithString: s.name)
        default:
            let l = NSTextField(labelWithString: s.url)
            l.lineBreakMode = .byTruncatingMiddle
            l.toolTip = s.url + "\nkey " + s.key
            return l
        }
    }
}
