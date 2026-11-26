import AppKit
import DFMCore

extension AppDelegate {
    // MARK: - Search (⌘F / ⌥F7): results replace the panel listing, ⌫ returns

    /// `name` prefills the name field (toolbar search's "Search … on disk").
    func searchDialog(name prefill: String? = nil) {
        if let hint = active.parkedHint { return active.flash(hint) }   // ⇧⌘P's "on disk" comes here directly
        if let prefill { defaults.set(prefill, forKey: "searchName") }
        let name = NSTextField(string: defaults.string(forKey: "searchName") ?? "")
        name.placeholderString = "name: text, *.glob;*.glob or re:regex — empty = any"
        let text = NSTextField(string: defaults.string(forKey: "searchText") ?? "")
        text.placeholderString = "containing text (optional)"
        let caseBox = NSButton(checkboxWithTitle: "Case-sensitive text", target: nil, action: nil)
        let hiddenBox = NSButton(checkboxWithTitle: "Include hidden files and folders", target: nil, action: nil)
        let tag = NSTextField(string: defaults.string(forKey: "searchTag") ?? "")
        tag.placeholderString = "with Finder tag (optional)"
        let spotBox = NSButton(checkboxWithTitle: "Use Spotlight index (fast, skips what Spotlight doesn't index)", target: nil, action: nil)
        caseBox.state = defaults.bool(forKey: "searchCase") ? .on : .off
        hiddenBox.state = defaults.bool(forKey: "searchHidden") ? .on : .off
        spotBox.state = defaults.bool(forKey: "searchSpotlight") ? .on : .off
        let remote = active.remote
        tag.isHidden = remote != nil   // on a server: find and grep there, no tags or Spotlight
        spotBox.isHidden = remote != nil
        let form = NSStackView(views: [name, text, tag, caseBox, hiddenBox, spotBox])
        form.orientation = .vertical
        form.alignment = .leading
        for f in [name, text, tag] { f.widthAnchor.constraint(equalToConstant: 440).isActive = true }
        form.setFrameSize(form.fittingSize)   // a server's has no tag or Spotlight rows: no empty strip in their place

        let alert = NSAlert()
        alert.messageText = "Search in " + DirSync.place(active.endpoint, active.currentDir)
        alert.addButton(withTitle: "Search")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = form
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [unowned self] r in
            window.makeFirstResponder(active.table)
            guard r == .alertFirstButtonReturn else { return }
            var q = SearchQuery(root: remote?.dir ?? active.path)
            q.name = name.stringValue.trimmingCharacters(in: .whitespaces)
            q.contains = text.stringValue
            q.caseSensitive = caseBox.state == .on
            q.includeHidden = hiddenBox.state == .on
            q.spotlight = spotBox.state == .on
            q.tag = tag.stringValue.trimmingCharacters(in: .whitespaces)
            defaults.set(q.tag, forKey: "searchTag")
            defaults.set(q.name, forKey: "searchName")
            defaults.set(q.contains, forKey: "searchText")
            defaults.set(q.caseSensitive, forKey: "searchCase")
            defaults.set(q.includeHidden, forKey: "searchHidden")
            defaults.set(q.spotlight, forKey: "searchSpotlight")
            if remote != nil { (q.spotlight, q.tag) = (false, "") }
            if q.name.isEmpty && q.contains.isEmpty { q.name = "*" }
            runSearch(q)
        }
    }

    /// Sidebar tag: every file with it under the home folder, via Spotlight.
    func searchTag(_ name: String) {
        // Spotlight and Finder tags are this Mac's: a server panel would run it there, in a folder named like ~.
        guard active.remote == nil else { NSSound.beep(); return active.flash("Finder tags are on this Mac — search them from a local panel") }
        var q = SearchQuery(root: NSHomeDirectory())
        q.tag = name
        q.spotlight = true
        runSearch(q)
    }

    private func runSearch(_ q: SearchQuery) {
        let panel = active
        if let t = panel.remote?.target, ServerLock.needsUnlock(t) {   // unlocked, it no longer needs it: runs below
            Task { if await unlock([.sftp(t)]) { runSearch(q) } }
            return
        }
        var title = q.name.isEmpty ? "*" : q.name
        if !q.contains.isEmpty { title += " containing “\(q.contains)”" }
        if !q.tag.isEmpty { title += " tagged “\(q.tag)”" }
        let server = panel.remote?.target, env = SSHAskpass.env   // a server panel searches there
        let flag = panel.beginSearch(title, in: DirSync.place(server.map(Endpoint.sftp) ?? .local, q.root), root: server == nil ? q.root : nil)
        DispatchQueue.global(qos: .userInitiated).async {
            var batch: [FileItem] = []
            var lastFlush = Date()
            func flush() {
                let items = batch
                batch = []
                lastFlush = Date()
                DispatchQueue.main.async { MainActor.assumeIsolated { panel.addSearchResults(items, from: flag) } }
            }
            func add(_ item: FileItem) {
                batch.append(item)
                if batch.count >= 500 || Date().timeIntervalSince(lastFlush) > 0.25 { flush() }
            }
            var note: String?, failed = false
            if let server {
                do { try FileSearch.runRemote(q, on: server, env: env, cancel: flag, onMatch: add) } catch {
                    if !(error is CancellationError) { (note, failed) = (error.localizedDescription, true) }
                }
            } else {
                let skipped = FileSearch.run(q, isCancelled: { flag.isCancelled }, onMatch: add)
                if skipped > 0 { note = "\(skipped) file\(skipped == 1 ? "" : "s") not downloaded (iCloud / Dropbox): not searched" }
            }
            flush()
            DispatchQueue.main.async { [note, failed] in MainActor.assumeIsolated { panel.finishSearch(flag, note: note, error: failed) } }
        }
    }
}
