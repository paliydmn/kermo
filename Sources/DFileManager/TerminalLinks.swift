import AppKit
import DFMCore
import SwiftTerm

/// A ⌘-click on a path or a web address the terminal shows (task 21 PR 4). The text is a program's — a server's too —,
/// so nothing it says runs: a path opens in the editor (a big file in the viewer, a folder in a panel) on the machine
/// the tab's shell is on, as its user; http(s) and mailto go to their apps after SwiftTerm's check; another scheme, an
/// OSC 8 link's hidden target (the gate's), a path with an invisible character: nothing.
enum TerminalLink: Equatable {
    case web(String)
    /// Where the path may end, longest first: SwiftTerm runs a path with spaces on to the line's end ("Saved to
    /// /tmp/out file.txt and more"). Absolute — an SSH tab's "~/…" is the server's home, read there.
    case path([Place])

    struct Place: Equatable {
        let path: String
        /// "42" or "42:5", as the editor's Go to Line takes it.
        let line: String?
    }

    /// What a click on it opens.
    enum Opening: Equatable {
        case editor(Place)
        case viewer(String)
        /// A panel at the folder (`into`), else at its folder with it under the cursor (⌥⌘-click).
        case panel(String, into: Bool)
    }

    /// The editor takes up to 32 MB; past that, the viewer.
    nonisolated static let editorLimit: Int64 = 32 << 20

    /// nil: nothing to open. `base`: where a relative path starts — a local tab's shell's folder (the kernel's word, not
    /// what any program printed), an SSH tab's as its shell told (OSC 7); nil: a relative path opens nothing. `home`:
    /// this Mac's for a local tab, nil for an SSH tab ("~/" kept for the server).
    nonisolated static func route(_ link: String, base: String?, home: String?) -> TerminalLink? {
        // Controls, format characters (bidi overrides, zero widths), line breaks: what's opened must be what shows.
        guard !link.isEmpty, !link.unicodeScalars.contains(where: {
            [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }) else { return nil }
        if let colon = link.firstIndex(of: ":"), link[..<colon].range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil {
            switch link[..<colon].lowercased() {
            case "http", "https", "mailto": return .web(link)
            case "file":   // as the path it names: on the server for an SSH tab
                guard let u = URL(string: link), u.query == nil, u.fragment == nil, [nil, "", "localhost"].contains(u.host),
                      let p = place(u.path, line: nil, base: nil, home: home) else { return nil }
                return .path([p])
            default: return nil   // ssh:, git://, tel:, magnet:…: another app started by a server's text
            }
        }
        var cuts = [Substring(link)]
        while cuts.count < 8, let space = cuts.last!.lastIndex(of: " ") { cuts.append(cuts.last![..<space]) }
        let places = cuts.compactMap { cut -> Place? in
            let s = String(cut).replacingOccurrences(of: #" +$"#, with: "", options: .regularExpression)
            // The first :line[:col] that ends the text or a word ("x.py:42: error", grep's "src/a.py:42:def f():").
            guard let r = s.range(of: #":[0-9]+(:[0-9]+)?(?=$|[: ])"#, options: .regularExpression) else { return place(s, line: nil, base: base, home: home) }
            return place(String(s[..<r.lowerBound]), line: String(s[r].dropFirst()), base: base, home: home)
        }
        return places.isEmpty ? nil : .path(places)
    }

    /// An absolute path, ".." and "." taken out; "~/…" kept where `home` is nil.
    private nonisolated static func place(_ path: String, line: String?, base: String?, home: String?) -> Place? {
        guard !path.isEmpty, !path.hasPrefix("$"), !path.contains("/$") else { return nil }   // $HOME/x: the server's variable, not ours
        var p = path, root = "/"
        if p.hasPrefix("~/") {
            if let home { p = home + p.dropFirst(1) } else { (root, p) = ("~/", String(p.dropFirst(2))) }
        } else if !p.hasPrefix("/") {
            guard let base else { return nil }
            p = base + "/" + p
        }
        var parts: [Substring] = []
        for c in p.split(separator: "/") where c != "." {
            if c == ".." { _ = parts.popLast() } else { parts.append(c) }
        }
        return Place(path: root + parts.joined(separator: "/"), line: line)
    }

    /// The first of `places` on this Mac, and what a click opens there; nil: none is.
    nonisolated static func here(_ places: [Place], reveal: Bool) -> Opening? {
        for p in places {
            var s = stat()   // follows a symlink, as F4 does
            guard stat(p.path, &s) == 0 else { continue }
            return opening(p, dir: s.st_mode & S_IFMT == S_IFDIR, size: Int64(s.st_size), reveal: reveal)
        }
        return nil
    }

    /// The same on a server, as the session's user: the places looked up together, "~/" from its home.
    nonisolated static func there(_ places: [Place], reveal: Bool, on s: SFTPClient) throws -> Opening? {
        let home = places.contains { $0.path.hasPrefix("~/") } ? try s.realpath(".") : ""
        let places = places.map { Place(path: $0.path.hasPrefix("~/") ? home + $0.path.dropFirst(1) : $0.path, line: $0.line) }
        for (p, r) in zip(places, s.lstat(places.map(\.path))) {
            guard case .success(var a?) = r else { continue }
            if a.kind == .link { a = try s.stat(p.path) }   // a dangling one fails: said
            guard a.kind != .other else { return nil }   // a FIFO, a device: nothing to read
            return opening(p, dir: a.kind == .dir, size: a.size, reveal: reveal)
        }
        return nil
    }

    private nonisolated static func opening(_ p: Place, dir: Bool, size: Int64, reveal: Bool) -> Opening {
        if reveal || dir { return .panel(p.path, into: dir && !reveal) }
        return size > editorLimit ? .viewer(p.path) : .editor(p)
    }
}

extension EmbeddedTerminal.Tab {
    /// Where a path in its text is: the server its shell is on, as its user (nil: this Mac); where a relative one starts —
    /// what the server's shell told (OSC 7), unchecked; this Mac's shell's folder as the kernel has it —; this Mac's home.
    var linkPlace: (server: SFTPTarget?, base: String?, home: String?) {
        if let t = target { (t.asUser, cwd, nil) } else { (nil, shellCwd, NSHomeDirectory()) }
    }

    /// A local shell running another machine's shell now: what it prints names that machine's files, not this Mac's.
    /// ponytail: by the program's name — a console of a VM, a serial line, a shell left after `exit` showing a server's
    /// lines above still open this Mac's file of the same name.
    var showsAnotherMachine: Bool { program.map(Self.remoteShells.contains) ?? false }
    nonisolated static let remoteShells: Set<String> = ["ssh", "mosh-client", "telnet", "docker", "podman", "kubectl"]
}

extension AppDelegate {
    /// A web address's app, after SwiftTerm's check (http(s) with a host, mailto). Replaced in tests: nothing opens.
    static var openWeb: @MainActor (TerminalLinkRequest, String) -> Void = { r, link in r.openDefault(link) }

    /// ⌘-click on a link in `tab`; ⌥ too: a panel shows it instead.
    func openLink(_ r: TerminalLinkRequest, flags: NSEvent.ModifierFlags, in tab: EmbeddedTerminal.Tab) {
        let (server, base, home) = tab.linkPlace
        if server == nil, tab.showsAnotherMachine { return TerminalGate.refused() }   // `ssh` in a local tab
        switch TerminalLink.route(r.link, base: base, home: home) {
        case nil: TerminalGate.refused()
        case .web(let link): Self.openWeb(r, link)
        case .path(let places):
            let reveal = flags.contains(.option)
            guard let t = server else {
                guard let o = TerminalLink.here(places, reveal: reveal) else { return TerminalGate.refused() }
                return open(o, on: nil)
            }
            let panel = panels.first { $0.remote?.target == t } ?? active, env = SSHAskpass.env
            Task {
                guard await ServerLock.authorize(t) else { return active.flash("\(t.host) stays locked") }
                let name = (places[0].path as NSString).lastPathComponent
                let found = await panel.busy("Looking for “\(name)”…", after: 0.5) { flag in
                    try SFTPClient.session(t, env: env, cancel: flag) { try TerminalLink.there(places, reveal: reveal, on: $0) }
                }
                switch found {
                case .success(let o?): open(o, on: t, in: panel)
                case .success(nil): TerminalGate.refused()
                case .failure(let e): if !(e is CancellationError) { showError(e) }
                }
            }
        }
    }

    private func open(_ o: TerminalLink.Opening, on t: SFTPTarget?, in panel: PanelViewController? = nil) {
        switch o {
        case .panel(let path, let into):
            showInPanel(into ? path : (path as NSString).deletingLastPathComponent, select: into ? nil : (path as NSString).lastPathComponent, on: t)
        case .editor(let p):
            guard let t else { return openInEditor(URL(fileURLWithPath: p.path), line: p.line) }
            remoteOpen(.edit, t, p.path, line: p.line, in: panel ?? active)
        case .viewer(let path):
            guard let t else { Viewer.show(URL(fileURLWithPath: path)); return }
            // F3's tail of a log; a big file that isn't text would come whole: not for a click.
            guard Viewer.tailLimit(for: (path as NSString).lastPathComponent) != nil else { return TerminalGate.refused() }
            remoteOpen(.view, t, path, in: panel ?? active)
        }
    }
}
