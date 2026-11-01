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
              "--force enable") rm -f \(dir)/inactive; echo 'Firewall is active and enabled on system startup' ;;
              "allow proto"|"deny from"|"insert 1") echo 'Rule added' ;;
              "show added") echo 'Added user rules (see ufw status for running firewall):'; echo 'ufw allow 22/tcp' ;;
              "--force delete") grep -v "^\\[ *$3\\] " \(dir)/rules > \(dir)/rules.new; mv \(dir)/rules.new \(dir)/rules; echo 'Rule deleted' ;;
              *) echo 'ERROR: Invalid syntax' >&2; exit 1 ;;
            esac
            """)
        try tool("fail2ban-client", """
            case "$*" in
              status) [ -f \(dir)/f2b-down ] && { echo 'Failed to access socket path: /var/run/fail2ban/fail2ban.sock. Is fail2ban running?' >&2; exit 255; }
                      printf 'Status\\n|- Number of jail:\\t1\\n`- Jail list:\\tsshd\\n' ;;
              "set sshd banip "*) echo 1 ;;
              "status sshd") printf 'Status for the jail: sshd\\n`- Actions\\n   `- Banned IP list:\\t%s\\n' "$(cat \(dir)/banned)" ;;
              version) echo 1.0.2 ;;
              "set sshd unbanip "*) [ -f \(dir)/slow ] && sleep 1; echo 1 ;;
              *) exit 1 ;;
            esac
            """)
        try tool("whois", "echo 'NetRange: 203.0.113.0 - 203.0.113.255'")
        try tool("tail", "echo '2026-10-30 10:00:00,123 fail2ban.actions [1]: NOTICE [sshd] Ban 203.0.113.7'; exec sleep 30")
        try Data("#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in -n|-S|-k) shift ;; -p) shift 2 ;; *) break ;; esac; done\nexec \"$@\"\n".utf8)
            .write(to: URL(fileURLWithPath: dir + "/sudo"))
        chmod(dir + "/sudo", 0o755)
        rules(Self.rules)
        banned("203.0.113.7 198.51.100.2")
        let setsid = "/usr/bin/perl -e 'use POSIX; setsid(); exec @ARGV' -- "
        ToolRunner.command = { [dir] in "echo >> \(dir)/trips; PATH=\(dir)/bin:$PATH " + setsid + $0.command }
        ToolRunner.sudoProgram = dir + "/sudo"
        ToolRunner.hasMaster = { _ in true }
        ToolRunner.own = URL(fileURLWithPath: dir + "/own")
        AuditLog.path = dir + "/audit.jsonl"
        AppDelegate.connected = { _ in false }   // another suite's master to localhost isn't this one's: a test says when it's up
        ToolExec.forget(.local())   // "sudo wants a password there" is the process's: a run of another test's can't leave it
    }

    func done() {
        (ToolRunner.command, ToolRunner.sudoProgram, ToolRunner.hasMaster, ToolRunner.own) = (was.command, was.sudo, was.master, was.own)
        (AppDelegate.connected, AuditLog.path) = (was.connected, was.audit)
        ServerLock.servers = { [] }
        ToolExec.forget(.local())
        try? FileManager.default.removeItem(atPath: dir)
    }

    func rules(_ text: String) { try? Data(text.utf8).write(to: URL(fileURLWithPath: dir + "/rules")) }
    func banned(_ ips: String) { try? Data(ips.utf8).write(to: URL(fileURLWithPath: dir + "/banned")) }
    func flag(_ name: String, _ on: Bool = true) {
        if on { FileManager.default.createFile(atPath: dir + "/" + name, contents: nil) } else { try? FileManager.default.removeItem(atPath: dir + "/" + name) }
    }
    var calls: [String] { ((try? String(contentsOfFile: dir + "/calls.log", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    /// Round trips: payloads sent.
    var trips: Int { ((try? String(contentsOfFile: dir + "/trips", encoding: .utf8)) ?? "").count }
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

/// A list's columns in a narrow panel give way from the right, and come back as it widens — though the last one shown
/// stretched to the edge meanwhile (dpl's six columns never came back).
@MainActor @Test func aListsColumnsComeBackInAWiderPanel() throws {
    final class Six: ListSource {
        let title = "Six", target = SFTPTarget.local(), content: ListContent? = nil
        let columns = (0..<6).map { ListColumn(title: "c\($0)", field: .title, width: 120) }
        func read(_ cancel: CancelFlag) async throws -> ListContent { ListContent(rows: []) }
    }
    let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    let list = ListPanel(Six())
    list.attach(to: table)
    list.fit(250)
    #expect(table.tableColumns.map(\.isHidden) == [false, false, true, true, true, true])
    table.tableColumns[1].width = 372   // stretched to the edge of a 495-point panel, as the last one shown
    list.fit(900)
    #expect(table.tableColumns.allSatisfy { !$0.isHidden }, "\(table.tableColumns.map(\.isHidden))")
}

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
        #expect(Array(bench.calls.prefix(3)) == ["ufw status numbered", "ufw status verbose", "ufw version"] && bench.trips == 1, "one round trip")

        a.showList(source)
        app.window.makeFirstResponder(a.table)
        let list = try #require(a.list)
        #expect(list.shown.map(\.title) == ["Anywhere", "22/tcp", "80,443/tcp"], "what's denied first")
        #expect(a.table.tableColumns.map(\.title) == ["Name", "State", "Detail"])
        #expect(app.focusedKeys?.map(\.label) == ["Status in Full", "Delete Rule…", "Mark", "Filter", "Actions"])
        #expect(app.focusedKeys?.first { $0.label == "Delete Rule…" }?.danger == true)
        let menu = NSMenu()
        app.fillListMenu(menu, list)
        #expect(menu.items.map(\.title) == ["Delete Rule…", "", "Allow Port…", "Block Address…", "Status in Full", "Turn Firewall On…", "Turn Firewall Off…", "",
                                            "Copy", "Show ufw.json", "", "Refresh"])
        #expect(list.content?.primary?.title == "Allow Port…", "＋ Allow Port… over the columns")

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
        #expect(Array(bench.calls.dropFirst(before)) == ["ufw status numbered", "ufw --force delete 3", "ufw status numbered", "ufw status verbose"],
                "verified, deleted, read again — its version asked once a session")
        #expect(list.shown.map(\.title) == ["22/tcp", "80,443/tcp"] && list.cursor?.title == "22/tcp")
        #expect(list.actions.allSatisfy { $0.why == nil } && list.content?.primary?.why == nil, "nothing says busy once it's done")
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

    /// An empty list — an inactive firewall — still has the tool's actions: its keys, its menu (⌃↩) in a panel, and
    /// ⌃↩ on the Picker's action bar. Turn Firewall On… there asks, runs, says so under the list and reads it again.
    @Test func anEmptyListStillHasTheToolsActions() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        bench.flag("inactive")
        let source = ToolListSource(app, try toolNamed(app, "ufw"), SavedServer(target: .local()), .local())
        #expect(try await source.read(CancelFlag()).rows.isEmpty)
        app.showInSearch(source)
        let picker = try #require(Picker.current)
        #expect(picker.rows.isEmpty && picker.actionBar.contains { $0.key == "⌃↩" && $0.label == "Actions" })
        Picker.dismiss()

        a.showList(source)
        app.window.makeFirstResponder(a.table)
        let list = try #require(a.list)
        #expect(app.focusedKeys?.map(\.label) == ["Status in Full", "Mark", "Filter", "Actions"])
        let menu = NSMenu()
        app.fillListMenu(menu, list)
        #expect(menu.items.map(\.title) == ["Allow Port…", "Block Address…", "Status in Full", "Turn Firewall On…", "Turn Firewall Off…", "", "Show ufw.json", "", "Refresh"])
        var asked: [String] = []
        AppDelegate.answering = { m, _, _ in asked.append(m); return 0 }
        app.runList(try #require(list.actions.first { $0.title == "Turn Firewall On…" }), in: list)
        await toolsUntil { !list.resultLines.isEmpty && !list.shown.isEmpty }
        #expect(asked == ["Turn Firewall On on localhost?"] && bench.calls.contains("ufw --force enable"))
        #expect(list.resultLines.first?.hasPrefix("\u{FFFC} Firewall is on on localhost at ") == true, "\(list.resultLines)")
        #expect(list.shown.map(\.title) == ["Anywhere", "22/tcp", "80,443/tcp"], "read again")
    }

    /// Server Info has no list: its actions are its rows (§1.3), what each runs and its key beside it, the header above
    /// them. ↩ runs the row's — the others keep their keys. A window's output has Copy and Save… (⌘C with nothing
    /// selected, ⌘S), Save… offering the action's `save` name.
    @Test func aLauncherListsItsActions() async throws {
        let (app, a, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        let source = ToolListSource(app, try toolNamed(app, "sysinfo"), SavedServer(target: .local()), .local())
        let c = try await source.read(CancelFlag())
        #expect(c.rows.map(\.title) == ["Full Report", "CPU · RAM Now", "Live Load", "Disks", "Traffic (5 s)", "GPU", "Top Processes"])
        #expect(c.rows[0].subtitle == "sh -s < sysinfo.report.sh" && c.rows[0].detail == "" && c.rows[1].subtitle == "uptime; free -h; top -bn1 | head -15" && c.rows[1].detail == "⌘L")
        #expect(c.header?.contains(" · Darwin ") == true && bench.trips == 1, "\(c.header ?? "")")

        a.showList(source)
        app.window.makeFirstResponder(a.table)
        let list = try #require(a.list)
        #expect(list.shown.map(\.title) == c.rows.map(\.title) && a.table.tableColumns.map(\.title) == ["Action", "Runs", "Key"])
        #expect(list.actions.filter { $0.key == Shortcut("return") }.map(\.title) == ["Full Report"])
        a.table.selectRowIndexes([3], byExtendingSelection: false)
        #expect(list.actions.filter { $0.key == Shortcut("return") }.map(\.title) == ["Disks"] && list.actions.contains { $0.title == "CPU · RAM Now" && $0.key == Shortcut("cmd+l") })
        pressKey(a, 36, "\r")
        await toolsUntil { NSApp.windows.contains { $0.title == "Disks — localhost" && $0.isVisible } }
        let disks = try #require(NSApp.windows.first { $0.title == "Disks — localhost" })
        #expect(OutputWindow.keys(of: disks)?.map(\.title).suffix(2) == ["Copy", "Save…"] && (disks.windowController as? OutputWindow)?.saveName == nil)
        disks.close()

        a.table.selectRowIndexes([0], byExtendingSelection: false)
        pressKey(a, 36, "\r")
        await toolsUntil { NSApp.windows.contains { $0.title == "Full Report — localhost" && $0.isVisible } }
        let report = try #require(NSApp.windows.first { $0.title == "Full Report — localhost" })
        #expect((report.windowController as? OutputWindow)?.saveName == "localhost-report.txt")
        report.close()
    }

    /// A Picker closes before an action that opens a window of its own runs — and the list may go with it: the
    /// action (and the row's ↩) still runs, holding the app, the tool and the server, not the list.
    @Test func anActionRunsAfterItsListIsGone() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        var source: ToolListSource? = ToolListSource(app, try toolNamed(app, "ufw"), SavedServer(target: .local()), .local())
        let row = try #require(try await source?.read(CancelFlag()).rows.first)
        let status = try #require(row.listActions?().first { $0.title == "Status in Full" })
        weak var gone = source
        source = nil
        #expect(gone == nil, "the list is gone")
        let runs = { bench.calls.filter { $0 == "ufw status verbose" }.count }, read = runs()   // the header's run too
        _ = status.run(false)
        await toolsUntil { runs() == read + 1 && NSApp.windows.contains { $0.title == "Status in Full — localhost" && $0.isVisible } }
        #expect(runs() == read + 1)
        NSApp.windows.filter { $0.title == "Status in Full — localhost" }.forEach { $0.close() }
        row.run()   // ↩ on the row, as a closed Picker runs it
        await toolsUntil { runs() == read + 2 && NSApp.windows.contains { $0.title == "Status in Full — localhost" && $0.isVisible } }
        #expect(runs() == read + 2)
        try? await Task.sleep(for: .milliseconds(300))   // its window, then nothing of it left running
        NSApp.windows.filter { $0.title == "Status in Full — localhost" }.forEach { $0.close() }
    }

    /// A list of files (§3.1): read over SFTP — through the server's sudo where the tool runs as root — each file a row,
    /// its folder its name, `also`'s fields from the file that row names; nothing runs as a command. A folder that
    /// can't be read says so with its path; no folder at all is an empty list.
    @Test func aListOfFilesIsReadOverSFTP() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        let base = bench.dir + "/dpl", fm = FileManager.default
        for (unit, status) in [("api", "ready"), ("web", "failed"), (".old", "ready")] {
            try fm.createDirectory(atPath: "\(base)/state/\(unit)", withIntermediateDirectories: true)
            try Data(#"{"kind": "app", "last_status": "\#(status)"}"#.utf8).write(to: URL(fileURLWithPath: "\(base)/state/\(unit)/deploy.json"))
        }
        try fm.createDirectory(atPath: "\(base)/state/empty", withIntermediateDirectories: true)   // no deploy.json: left out
        try Data("1".utf8).write(to: URL(fileURLWithPath: base + "/state/serve.pid"))
        try fm.createDirectory(atPath: base + "/conf", withIntermediateDirectories: true)
        try Data("image: x\nstrategy: parallel\n".utf8).write(to: URL(fileURLWithPath: base + "/conf/api.yaml"))
        let sudo = bench.dir + "/sftp-sudo"
        try Data("#!/bin/sh\necho \"$*\" >> \(bench.dir)/sftp-sudo.log\n[ \"$1\" = -n ] && [ \"$2\" = -- ] || exit 2\nshift 2\nexec \"$@\"\n".utf8)
            .write(to: URL(fileURLWithPath: sudo))
        chmod(sudo, 0o755)
        try fm.createDirectory(atPath: bench.dir + "/own", withIntermediateDirectories: true)
        try Data(#"""
            { "schema": 1, "id": "units", "title": "Units", "sudo": true, "vars": { "base": { "default": "\#(base)" } },
              "list": { "files": "{base}/state/*/deploy.json", "format": "json", "name": "unit",
                        "also": { "files": "{base}/conf/{unit}.yaml", "pattern": "^strategy: (?<strategy>\\w+)" },
                        "key": "{unit}", "title": "{unit}", "subtitle": ["{last_status}", "{strategy}"], "empty": "No units in {base}" } }
            """#.utf8).write(to: URL(fileURLWithPath: bench.dir + "/own/units.json"))
        _ = app.tools.reload()
        app.tools.trust.trust(try #require(app.tools.library.tools.first { $0.preset.id == "units" }))
        let t = SFTPTarget.local(sudo: sudo).asRoot(false)
        let source = ToolListSource(app, try toolNamed(app, "units"), SavedServer(target: t), t)
        let c = try await source.read(CancelFlag())
        #expect(c.rows.map(\.title) == ["api", "web"] && c.rows.map(\.subtitle) == ["ready · parallel", "failed"], "\(c.rows.map(\.subtitle))")
        #expect((try? String(contentsOfFile: bench.dir + "/sftp-sudo.log", encoding: .utf8))?.contains("-n -- ") == true, "as root, through sudo")
        #expect(bench.trips == 0, "nothing ran as a command")

        chmod(base + "/state/web", 0)
        defer { chmod(base + "/state/web", 0o755) }
        let denied = await failure(of: source)
        #expect(denied?.message == "Units on localhost: \(base)/state/web/deploy.json: Permission denied", "\(String(describing: denied?.message))")
        chmod(base + "/state/web", 0o755)
        try fm.removeItem(atPath: base + "/state")
        let none = try await source.read(CancelFlag())
        #expect(none.rows.isEmpty && none.empty == "No units in \(base)")
    }
}
