import AppKit

/// Is there a newer Kermo? One GET to GitHub's latest release: once a day by itself, and from Check for Updates….
/// The daily check never opens anything: a newer version shows once in the status line and stays in the Kermo menu.
enum Updates {
    struct Release: Decodable {
        let tag_name: String
        let body: String?
    }

    static let api = URL(string: "https://api.github.com/repos/paliydmn/kermo/releases/latest")!
    static let page = URL(string: "https://github.com/paliydmn/kermo/releases/latest")!
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// "v1.10" is newer than "1.9.2" and "1.2.0" isn't newer than "1.2": numbers one by one, a leading "v" dropped.
    static func isNewer(_ tag: String, than version: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingPrefix("v").split(separator: ".").map { Int($0) ?? 0 } }
        let (a, b) = (parts(tag), parts(version))
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The version to offer: `latest` when it is newer than `current` and wasn't skipped.
    static func offered(latest: String?, skipped: String?, current: String) -> String? {
        guard let latest, latest != skipped, isNewer(latest, than: current) else { return nil }
        return String(latest.trimmingPrefix("v"))
    }

    /// No cache on disk, no cookies: the request carries nothing but Kermo's own version (in User-Agent).
    static func fetch() async throws -> Release {
        var request = URLRequest(url: api, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Kermo/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// The release notes (GitHub Markdown) as the alert shows them: headings bold, list items with bullets.
    static func notes(_ markdown: String) -> NSAttributedString {
        let text = markdown
            .replacingOccurrences(of: #"(?m)^#+\s*(.+)$"#, with: "**$1**", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^(\s*)[-*] "#, with: "$1• ", options: .regularExpression)
        let s = NSMutableAttributedString(attributedString: (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                                          .map(NSAttributedString.init) ?? NSAttributedString(string: markdown))
        s.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: s.length))
        s.enumerateAttribute(.inlinePresentationIntent, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            let bold = (v as? Int).map { InlinePresentationIntent(rawValue: UInt($0)).contains(.stronglyEmphasized) } ?? false
            s.addAttribute(.font, value: bold ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 12), range: r)
        }
        return s
    }
}

extension AppDelegate {
    /// The newer version the last check found (not skipped): the Kermo menu names it.
    var updateOffered: String? {
        Updates.offered(latest: defaults.string(forKey: "updateLatest"), skipped: defaults.string(forKey: "updateSkipped"), current: Updates.current)
    }

    /// At launch and every hour after: a check once the last one is a day old.
    func startUpdateChecks() {
        checkForUpdatesIfDue()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.checkForUpdatesIfDue() }
        }
    }

    func checkForUpdatesIfDue() {
        let last = defaults.object(forKey: "updateChecked") as? Date ?? .distantPast
        guard !defaults.bool(forKey: "updateCheckOff"), Date().timeIntervalSince(last) > 86_400 else { return }
        Task { await checkForUpdates(byHand: false) }
    }

    /// By itself: silent when GitHub can't be reached (offline, a closed network), and a newer version is said once.
    /// By hand: an alert either way.
    func checkForUpdates(byHand: Bool) async {
        let release: Updates.Release
        do { release = try await Updates.fetch() } catch {
            if byHand { _ = await Self.sheet(Self.alert("Couldn't check for updates", info: error.localizedDescription, ["OK"]), on: window) }
            return
        }
        let was = defaults.string(forKey: "updateLatest")
        defaults.set(Date(), forKey: "updateChecked")
        defaults.set(release.tag_name, forKey: "updateLatest")
        if byHand { return await showUpdate(release) }
        if release.tag_name != was, let v = updateOffered { active.flash("Kermo \(v) is available: Kermo ▸ Kermo \(v) Available…") }
    }

    private func showUpdate(_ release: Updates.Release) async {
        let current = Updates.current
        guard let v = Updates.offered(latest: release.tag_name, skipped: nil, current: current) else {
            _ = await Self.sheet(Self.alert("Kermo \(current) is the latest version", info: "", ["OK"]), on: window)
            return
        }
        let alert = Self.alert("Kermo \(v) is available", info: "You have \(current). Download it, then replace Kermo in Applications.",
                               ["Download", "Later", "Skip This Version"])
        alert.alertStyle = .informational
        alert.buttons[1].keyEquivalent = "\u{1b}"   // ⎋: Later
        if let body = release.body, !body.isEmpty {
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 440, height: 220)
            scroll.borderType = .bezelBorder
            let text = scroll.documentView as! NSTextView
            text.isEditable = false
            text.textContainerInset = NSSize(width: 4, height: 6)
            text.textStorage?.setAttributedString(Updates.notes(body))
            alert.accessoryView = scroll
        }
        switch await Self.sheet(alert, on: window) {
        case 0: NSWorkspace.shared.open(Updates.page)
        case 2: defaults.set(release.tag_name, forKey: "updateSkipped")
        default: break
        }
    }

    func toggleUpdateChecks() {
        let off = !defaults.bool(forKey: "updateCheckOff")
        defaults.set(off, forKey: "updateCheckOff")
        active.flash(off ? "Kermo won't check for updates by itself" : "Kermo checks for updates once a day")
        checkForUpdatesIfDue()
    }
}
