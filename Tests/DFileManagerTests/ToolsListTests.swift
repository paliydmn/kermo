import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Tools PR 2: a tool's list in a panel and in a Picker — the built-in ufw and fail2ban, run for real against stand-ins
// on this Mac: the programs, a sudo that wants no password, whois. Nothing goes to a server or the network.

/// Stand-ins for a server with ufw and fail2ban, each call written to calls.log; Tools' runs start with them first on
/// PATH, in a session of their own (the payload's watcher stops its session).
@MainActor final class ToolsBench {
    let dir: String
    private let was = (command: ToolRunner.command, sudo: ToolRunner.sudoProgram, master: ToolRunner.hasMaster, own: ToolRunner.own,
                       connected: AppDelegate.connected, audit: AuditLog.path)

    static let rules = """
        Status: active

             To                         Action      From
             --                         ------      ----
        [ 1] 22/tcp                     ALLOW IN    Anywhere
        [ 2] 80,443/tcp                 ALLOW IN    Anywhere                   # web
        [ 3] Anywhere                   DENY IN     203.0.113.7

        """

    init() throws {
        dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/kermo-tools-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
        let log = dir + "/calls.log"
        func tool(_ name: String, _ body: String) throws {
            try Data("#!/bin/sh\necho \"\(name) $*\" >> \(log)\n\(body)\n".utf8).write(to: URL(fileURLWithPath: dir + "/bin/" + name))
            chmod(dir + "/bin/" + name, 0o755)
        }
        try tool("ufw", """
            case "$1 $2" in
              "status numbered") [ -f \(dir)/inactive ] && { echo 'Status: inactive'; exit 0; }; cat \(dir)/rules ;;
              "status verbose") printf 'Status: active\\nLogging: on (low)\\nDefault: deny (incoming), allow (outgoing), disabled (routed)\\n' ;;
              "version ") echo 'ufw 0.36.2' ;;
              "--force delete") grep -v "^\\[ *$3\\] " \(dir)/rules > \(dir)/rules.new; mv \(dir)/rules.new \(dir)/rules; echo 'Rule deleted' ;;
              *) echo 'ERROR: Invalid syntax' >&2; exit 1 ;;
            esac
            """)
        try tool("fail2ban-client", """
            case "$*" in
              status) printf 'Status\\n|- Number of jail:\\t1\\n`- Jail list:\\tsshd\\n' ;;
              "status sshd") printf 'Status for the jail: sshd\\n`- Actions\\n   `- Banned IP list:\\t%s\\n' "$(cat \(dir)/banned)" ;;
              version) echo 1.0.2 ;;
              "set sshd unbanip "*) [ -f \(dir)/slow ] && sleep 1; echo 1 ;;
              *) exit 1 ;;
            esac
            """)
        try tool("whois", "echo 'NetRange: 203.0.113.0 - 203.0.113.255'")
        try Data("#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in -n|-S|-k) shift ;; -p) shift 2 ;; *) break ;; esac; done\nexec \"$@\"\n".utf8)
            .write(to: URL(fileURLWithPath: dir + "/sudo"))
        chmod(dir + "/sudo", 0o755)
        rules(Self.rules)
        banned("203.0.113.7 198.51.100.2")
        let setsid = "/usr/bin/perl -e 'use POSIX; setsid(); exec @ARGV' -- "
        ToolRunner.command = { [dir] in "PATH=\(dir)/bin:$PATH " + setsid + $0.command }
        ToolRunner.sudoProgram = dir + "/sudo"
        ToolRunner.hasMaster = { _ in true }
        ToolRunner.own = URL(fileURLWithPath: dir + "/own")
        AuditLog.path = dir + "/audit.jsonl"
    }

    func done() {
        (ToolRunner.command, ToolRunner.sudoProgram, ToolRunner.hasMaster, ToolRunner.own) = (was.command, was.sudo, was.master, was.own)
        (AppDelegate.connected, AuditLog.path) = (was.connected, was.audit)
        ServerLock.servers = { [] }
        try? FileManager.default.removeItem(atPath: dir)
    }

    func rules(_ text: String) { try? Data(text.utf8).write(to: URL(fileURLWithPath: dir + "/rules")) }
    func banned(_ ips: String) { try? Data(ips.utf8).write(to: URL(fileURLWithPath: dir + "/banned")) }
    func flag(_ name: String, _ on: Bool = true) {
        if on { FileManager.default.createFile(atPath: dir + "/" + name, contents: nil) } else { try? FileManager.default.removeItem(atPath: dir + "/" + name) }
    }
    var calls: [String] { ((try? String(contentsOfFile: dir + "/calls.log", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
}

@MainActor func toolsUntil(_ done: () -> Bool) async {
    for _ in 0..<250 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
}

/// The apps the tests make live to the end of the run: a panel's callbacks hold them unowned.
@MainActor private var keptApps: [AppDelegate] = []

/// Two wired panels in a window, the registry and the menu bar, as the app — its tools loaded.
@MainActor func toolsApp() throws -> (AppDelegate, PanelViewController, PanelViewController, () -> Void) {
    _ = NSApplication.shared
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/kermo-tools-app-" + UUID().uuidString, was = AppDelegate.keymapDir
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    AppDelegate.keymapDir = dir
    for k in ["listSort", "placeLastList"] { UserDefaults.standard.removeObject(forKey: k) }
    let app = AppDelegate()
    keptApps.append(app)
    app.terminal = EmbeddedTerminal(covering: NSView())
    app.applyConfig(reportProblems: false)
    let a = PanelViewController(tabs: [dir], index: 0, showHidden: false), b = PanelViewController(tabs: [dir], index: 0, showHidden: false)
    app.panels = [a, b]
    app.wireKeyBar()
    app.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
    app.window.contentView = host
    for (i, p) in [a, b].enumerated() { p.view.frame = NSRect(x: CGFloat(i) * 500, y: 0, width: 500, height: 600); host.addSubview(p.view) }
    host.layoutSubtreeIfNeeded()
    [a, b].forEach(app.wire)
    return (app, a, b, {
        Picker.dismiss()
        AppDelegate.answering = nil
        [a, b].forEach { $0.shutdown() }
        app.window = nil
        AppDelegate.keymapDir = was
        try? FileManager.default.removeItem(atPath: dir)
        for k in ["listSort", "placeLastList"] { UserDefaults.standard.removeObject(forKey: k) }
    })
}

@MainActor func pressKey(_ p: PanelViewController, _ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) {
    p.table.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
}

let toolsF8 = String(Character(UnicodeScalar(NSF8FunctionKey)!))

@MainActor func toolNamed(_ app: AppDelegate, _ id: String) throws -> LoadedTool { try #require(app.tools.tools.first { $0.preset.id == id }) }

/// Why a list's read failed (nil: it didn't).
@MainActor func failure(of s: ToolListSource) async -> ToolListSource.Failed? {
    do { _ = try await s.read(CancelFlag()); return nil } catch { return error as? ToolListSource.Failed }
}

extension ServerLockTests {
    /// ufw's list: its rows — what's denied first in a panel, as in the Picker — their state as a shape, the line
    /// above them from `header`, the row's keys and its menu: the row's actions, the tool's, Copy, the tool's file.
    /// Actions with a form aren't there yet (Tools PR 2b).
    @Test func aToolsListIsTheSameInAPanelAndAPicker() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        let source = ToolListSource(app, try toolNamed(app, "ufw"), SavedServer(target: .local()), .local())
        let c = try await source.read(CancelFlag())
        #expect(c.rows.map(\.title) == ["22/tcp", "80,443/tcp", "Anywhere"] && c.rows.map(\.state) == [.on, .on, .failed])
        #expect(c.rows[0].subtitle == "ALLOW IN · from Anywhere" && c.rows[1].detail == "web" && c.rows[2].badges.count == 1)
        #expect(c.header == "Firewall active · default: deny (incoming), allow (outgoing), disabled (routed)")
        #expect(Array(bench.calls.prefix(3)) == ["ufw status numbered", "ufw status verbose", "ufw version"])

        a.showList(source)
        app.window.makeFirstResponder(a.table)
        let list = try #require(a.list)
        #expect(list.shown.map(\.title) == ["Anywhere", "22/tcp", "80,443/tcp"], "what's denied first")
        #expect(a.table.tableColumns.map(\.title) == ["Name", "State", "Detail"])
        #expect(app.focusedKeys?.map(\.label) == ["Status in Full", "Delete Rule…", "Mark", "Filter", "Actions"])
        #expect(app.focusedKeys?.first { $0.label == "Delete Rule…" }?.danger == true)
        let menu = NSMenu()
        app.fillListMenu(menu, list)
        #expect(menu.items.map(\.title) == ["Delete Rule…", "", "Status in Full", "Turn Firewall On…", "Turn Firewall Off…", "", "Copy", "Show ufw.json", "", "Refresh"])

        app.showInSearch(source)
        let picker = try #require(Picker.current)
        #expect(picker.rows.map(\.title) == list.shown.map(\.title) && picker.headerSaid == c.header)
        let row = try #require(picker.rows.first)
        #expect(row.verb == "Status in Full" && row.menu?()?.items.map(\.title) == menu.items.map(\.title))
    }

    /// Delete Rule… can't be undone: it asks on any server, ↩ = Cancel, and only on the cursor's row, marks or not.
    /// Asked, the list is read again first: the row must be as asked about, field for field, or nothing runs. Then
    /// the rule goes, the line says so, and the list is read again with the cursor on the row next to it.
    @Test func deleteRuleAsksVerifiesAndReadsTheListAgain() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        let source = ToolListSource(app, try toolNamed(app, "ufw"), SavedServer(target: .local()), .local())
        _ = try await source.read(CancelFlag())
        a.showList(source)
        app.window.makeFirstResponder(a.table)
        let list = try #require(a.list)
        list.markAll()
        var asked: [(String, [String], Int?)] = []
        AppDelegate.answering = { m, b, d in asked.append((m, b, d)); return d ?? 0 }   // ↩
        pressKey(a, 100, toolsF8)
        await toolsUntil { !list.resultLines.isEmpty }
        #expect(asked.first?.0 == "Delete Rule on localhost?" && asked.first?.1 == ["Delete Rule", "Show Exactly What Runs", "Cancel"] && asked.first?.2 == 2,
                "one row, the cursor's: ↩ = Cancel")
        #expect(list.resultLines == ["Delete Rule: cancelled — nothing ran"] && !bench.calls.contains { $0.contains("delete") })

        AppDelegate.answering = { _, _, _ in bench.rules(ToolsBench.rules.replacingOccurrences(of: "203.0.113.7", with: "203.0.113.8")); return 0 }
        pressKey(a, 100, toolsF8)
        await toolsUntil { list.resultLines.first?.contains("changed") == true }
        #expect(list.resultLines == ["Delete Rule: the list changed; nothing ran"] && !bench.calls.contains { $0.contains("delete") })

        bench.rules(ToolsBench.rules)
        list.unmarkAll()
        AppDelegate.answering = { _, _, _ in 0 }
        let before = bench.calls.count
        pressKey(a, 100, toolsF8)
        await toolsUntil { list.resultLines.first?.contains("Deleted") == true }
        #expect(list.resultLines.first?.hasPrefix("\u{FFFC} Deleted rule 3 (Anywhere) on localhost at ") == true, "\(list.resultLines)")
        #expect(Array(bench.calls.dropFirst(before)) == ["ufw status numbered", "ufw --force delete 3", "ufw status numbered", "ufw status verbose", "ufw version"],
                "verified, deleted, read again")
        #expect(list.shown.map(\.title) == ["22/tcp", "80,443/tcp"] && list.cursor?.title == "22/tcp")
    }

    /// A list that can't be read says why: a program not there in words (exit 127), output that doesn't fit the
    /// preset as "didn't match" with what the server said a click away (Output…). An inactive firewall is no rules.
    @Test func aListThatCantBeReadSaysWhy() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        let ufw = try toolNamed(app, "ufw")
        bench.flag("inactive")
        let off = try await ToolListSource(app, ufw, SavedServer(target: .local()), .local()).read(CancelFlag())
        #expect(off.rows.isEmpty && off.empty == "No rules: everything follows the default policy.")
        bench.flag("inactive", false)

        bench.rules("[ 1] something ufw never says\n")
        var failed = await failure(of: ToolListSource(app, ufw, SavedServer(target: .local()), .local()))
        #expect(failed?.message == "Firewall on localhost: the output didn't match — [ 1] something ufw never says" && failed?.output == "[ 1] something ufw never says\n")
        app.showInSearch(ToolListSource(app, ufw, SavedServer(target: .local()), .local()))
        let picker = try #require(Picker.current)
        await toolsUntil { picker.said.contains("didn't match") }
        func buttons(_ v: NSView) -> [NSButton] { v.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        #expect(buttons(picker.panel.contentView!).contains { $0.title == "Output…" && !$0.isHidden })
        Picker.dismiss()

        try FileManager.default.removeItem(atPath: bench.dir + "/bin/ufw")
        failed = await failure(of: ToolListSource(app, ufw, SavedServer(target: .local()), .local()))
        #expect(failed?.message == "ufw isn't on localhost", "\(failed?.message ?? "")")
    }
}
