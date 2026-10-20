import AppKit
import DFMCore

/// Is there a newer Kermo? One GET to GitHub's latest release: once a day by itself, and from Check for Updates….
/// The daily check never opens anything: a newer version shows once in the status line and stays in the Kermo menu.
enum Updates {
    struct Release: Decodable {
        let tag_name: String
        let body: String?
        var assets: [Asset]? = nil
    }
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }

    /// The release's zip of the app, which Install and Relaunch takes; nil for a release without one (1.3 and older).
    static func archive(_ release: Release) -> URL? {
        let name = "Kermo-\(release.tag_name.trimmingPrefix("v"))-universal.zip"
        return release.assets?.first { $0.name == name }?.browser_download_url
    }

    /// Is `app` signed to satisfy `requirement` (the running Kermo's designated requirement: Kermo's identifier and the
    /// release certificate), every file of it unchanged? The download is trusted only for that: GitHub, the release
    /// page or a checksum next to the file prove nothing that whoever could swap the file couldn't swap too.
    static func isSigned(_ app: URL, as requirement: SecRequirement) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// The running Kermo's designated requirement; nil when it has none (an unsigned build).
    static var ownRequirement: SecRequirement? {
        var me: SecCode?, code: SecStaticCode?, req: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess else { return nil }
        return req
    }

    static func text(_ requirement: SecRequirement) -> String? {
        var s: CFString?
        return SecRequirementCopyString(requirement, [], &s) == errSecSuccess ? s as String? : nil
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
        let zip = Updates.archive(release)
        let alert = zip == nil
            ? Self.alert("Kermo \(v) is available", info: "You have \(current). Download it, then replace Kermo in Applications.",
                         ["Download", "Later", "Skip This Version"])
            : Self.alert("Kermo \(v) is available", info: "You have \(current). Kermo downloads it, checks it's signed as this one is, "
                         + "puts it in place of this one and opens it again.", ["Install and Relaunch", "Later", "Skip This Version"])
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
        case 0: if let zip { await install(v, from: zip) } else { NSWorkspace.shared.open(Updates.page) }
        case 2: defaults.set(release.tag_name, forKey: "updateSkipped")
        default: break
        }
    }

    private static var installing = false

    /// Install and Relaunch: the zip into a temp folder, its app checked, put in place of this one (as root, after
    /// macOS asks for the password, when this one isn't the user's to replace: installed from the .pkg), then a quit
    /// and a shell that opens the new one once this process is gone. What can't be done here opens the release page.
    private func install(_ version: String, from zip: URL) async {
        guard !Self.installing else { return }
        Self.installing = true
        defer { Self.installing = false }
        let app = Bundle.main.bundleURL
        func byHand(_ why: String) async {
            if await Self.sheet(Self.alert("Kermo \(version) wasn't installed", info: why + " Download it, then replace Kermo in Applications.",
                                           ["Download", "Cancel"]), on: window) == 0 { NSWorkspace.shared.open(Updates.page) }
        }
        let readOnly = (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? true
        if readOnly || app.path.contains("/AppTranslocation/") {
            return await byHand("This Kermo runs from a disk image or a quarantined place, not from Applications.")
        }
        guard let requirement = Updates.ownRequirement, let requirementText = Updates.text(requirement) else {
            return await byHand("This copy of Kermo isn't signed, so a download can't be checked against it.")
        }
        active.flash("Downloading Kermo \(version)…")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kermo-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let new = tmp.appendingPathComponent("Kermo.app")
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let (file, response) = try await URLSession(configuration: .ephemeral).download(for: URLRequest(url: zip, timeoutInterval: 120))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: file, to: tmp.appendingPathComponent("Kermo.zip"))
            let unzip = try await Blocking.run { () throws -> Int32 in
                let p = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", "--noqtn", tmp.appendingPathComponent("Kermo.zip").path, tmp.path])
                p.waitUntilExit()
                return p.terminationStatus
            }
            guard unzip == 0 else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            return await byHand("The download failed: \(error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "."))).")
        }
        let got = Bundle(url: new)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard got == version, Updates.isSigned(new, as: requirement) else {
            return await byHand("The download isn't Kermo \(version) signed as this Kermo is (a build of your own isn't updated this way).")
        }
        let command = AdminCommand.replaceApp(new.path, at: app.path, requirement: requirementText)
        let parent = app.deletingLastPathComponent().path
        if access(parent, W_OK) == 0 && access(app.path, W_OK) == 0 && access(app.appendingPathComponent("Contents").path, W_OK) == 0 {
            let err = await Blocking.run { () -> String? in
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", command]
                p.standardError = pipe
                do { try p.run() } catch { return error.localizedDescription }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return p.terminationStatus == 0 ? nil : String(decoding: data, as: UTF8.self)
            }
            if let err { return await byHand(err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } else {
            switch await Admin.run(command) {
            case .ok: break
            case .cancelled: return active.flash("Kermo \(version) wasn't installed")
            case .failed(let err): return await byHand(err)
            }
        }
        // A detached shell waits for this process to end, then opens the new app; a quit that's cancelled (unsaved
        // text, running copies) just leaves it waiting.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                              "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? relaunch.run()
        active.flash("Kermo \(version) is installed: it opens when Kermo quits")
        NSApp.terminate(nil)
    }

    func toggleUpdateChecks() {
        let off = !defaults.bool(forKey: "updateCheckOff")
        defaults.set(off, forKey: "updateCheckOff")
        active.flash(off ? "Kermo won't check for updates by itself" : "Kermo checks for updates once a day")
        checkForUpdatesIfDue()
    }
}
