import AppKit
import CryptoKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Tools PR 8: catalogs — a folder with a signed index (here on this Mac, file://, signed with the test's own key),
// fetched only when the Catalog opens or Check for Updates… runs; Get asks "Use the tool…?" and puts the files in your
// folder; Update says only what changes and asks before replacing yours (Keep Mine, Compare, Replace → .bak); Remove
// trashes them and a built-in is back; Suggested looks for a catalog tool's program over a connection that's up;
// Settings → Tools adds a catalog only with an address and a key that are ones.

private let key = Curve25519.Signing.PrivateKey()

/// A catalog in `dir`: each tool's files under tools/<id>/<version>/, its index signed; its source.
private func catalog(_ dir: String, serial: Int, _ tools: [(id: String, version: Int, tool: String?, files: [String: String])]) throws -> ToolCatalog.Source {
    var entries: [ToolCatalog.Entry] = []
    for t in tools {
        var files: [ToolCatalog.File] = []
        for (name, text) in t.files.sorted(by: { $0.key < $1.key }) {
            let path = "tools/\(t.id)/\(t.version)/\(name)"
            try FileManager.default.createDirectory(atPath: dir + "/tools/\(t.id)/\(t.version)", withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: dir + "/" + path))
            files.append(.init(path: path, sha256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()))
        }
        entries.append(ToolCatalog.Entry(id: t.id, title: t.id.capitalized, tool: t.tool, about: "About \(t.id)", version: t.version, verified: true, files: files))
    }
    let data = try JSONEncoder().encode(ToolCatalog.Index(serial: serial, tools: entries))
    try data.write(to: URL(fileURLWithPath: dir + "/catalog.json"))
    try Data(try key.signature(for: data).base64EncodedString().utf8).write(to: URL(fileURLWithPath: dir + "/catalog.json.sig"))
    return ToolCatalog.Source(name: "Team", url: URL(fileURLWithPath: dir, isDirectory: true).absoluteString, key: key.publicKey.rawRepresentation.base64EncodedString())
}

/// A tool `id` whose list is a script of `lines` lines.
private func disk(_ version: Int, lines: Int = 1, id: String = "disk") -> [String: String] {
    ["\(id).json": #"{ "schema": 1, "id": "\#(id)", "title": "\#(id.capitalized)", "catalogVersion": \#(version), "list": { "script": "\#(id).sh" } }"#,
     "\(id).sh": String(repeating: "df -P\n", count: lines)]
}

private func ufw(_ version: Int) throws -> [String: String] {
    let text = try String(contentsOf: ToolPreset.builtInFolder.appendingPathComponent("ufw.json"), encoding: .utf8)
    return ["ufw.json": text.replacingOccurrences(of: #""catalogVersion": 2"#, with: #""catalogVersion": \#(version)"#)]
}

@MainActor private func closeAll() { ToolsWindow.main?.window.close() }
/// `#require` reflects what it's given, and an app's unowned references end the run when it fails: a plain guard.
private func need<T>(_ v: T?, _ what: String) throws -> T {
    guard let v else { Issue.record("no \(what)"); throw CancellationError() }
    return v
}
@MainActor private func mode(_ path: String) -> mode_t {
    var st = stat()
    return stat(path, &st) == 0 ? st.st_mode & 0o777 : 0
}

extension ServerLockTests {
    /// Opening the Catalog fetches it: built-ins, then the catalog's others, each with what the catalog has of it. An
    /// index older than one seen, or changed after it was signed, is refused and said; nothing of it is offered.
    @Test func theCatalogIsFetchedAsItOpensAndTakenOnlySigned() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { closeAll(); bench.done(); done() }
        let dir = bench.dir + "/catalog", c = app.tools.catalogs
        #expect(c.sources.isEmpty, "under tests no catalog is Kermo's own")
        c.sources = [try catalog(dir, serial: 3, [("disk", 1, nil, disk(1)), ("ufw", 9, "ufw", try ufw(9))])]
        #expect(c.at == nil && c.offers.isEmpty, "nothing fetched before the Catalog opens")
        ToolsWindow.show(app)
        let w = try need(ToolsWindow.main, "Tools window")
        w.sidebar.selectRowIndexes([try need(w.rows.firstIndex(of: .library(mine: false)), "Catalog row")], byExtendingSelection: false)
        let lib = try need(w.library, "library")
        await toolsUntil { c.at != nil }
        #expect(c.problems.isEmpty && c.offers.map(\.entry.id) == ["disk", "ufw"] && c.fetched.serials[c.sources[0].url] == 3)
        #expect(lib.rows.map(\.id) == ["dpl", "fail2ban", "sites", "sysinfo", "system", "ufw", "disk"])
        func said(_ id: String) throws -> String { lib.catalog(try need(lib.rows.first { $0.id == id }, id)) }
        #expect(try said("ufw") == "update: v9" && said("disk") == "v1 · verified" && said("dpl") == "built in")
        #expect(lib.said.stringValue.hasPrefix("Team: checked ") && c.updates.map(\.preset.id) == ["ufw"])

        _ = try catalog(dir, serial: 2, [("disk", 1, nil, disk(1))])
        await c.fetch()
        #expect(c.problems == ["Team: its index is older than one seen before (2 < 3): not taken"] && c.offers.isEmpty)
        #expect(lib.said.stringValue.hasSuffix("\n" + (c.problems.first ?? "-")) && lib.said.textColor == Palette.fail)
        _ = try catalog(dir, serial: 4, [("disk", 1, nil, disk(1))])
        try Data(try String(contentsOfFile: dir + "/catalog.json", encoding: .utf8).replacingOccurrences(of: "About disk", with: "About this").utf8)
            .write(to: URL(fileURLWithPath: dir + "/catalog.json"))
        await c.fetch()
        #expect(c.problems == ["Team: its signature doesn't match its key: not taken"] && c.offers.isEmpty && c.fetched.serials[c.sources[0].url] == 3)
    }

    /// Get: "Use the tool…?" with where it's from and all it runs; Don't Use writes nothing. Used: its files in your
    /// folder, owner-only, trusted, noted as the catalog's; a file the signed index doesn't sum to is refused.
    @Test func getAsksThenPutsItInYourFolder() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { closeAll(); bench.done(); done() }
        let dir = bench.dir + "/catalog", c = app.tools.catalogs
        c.sources = [try catalog(dir, serial: 1, [("disk", 1, nil, disk(1))])]
        c.saveSources()   // a Get reads tools/ again
        await c.fetch()
        let o = try need(c.offer("disk"), "disk offer")
        var asked: [String] = [], info = ""
        AppDelegate.answering = { m, b, _ in asked.append(m); info = AppDelegate.answeredInfo; return b.count - 1 }
        #expect(await c.get(o, window: nil) == "Disk: not got" && !FileManager.default.fileExists(atPath: bench.dir + "/own/disk.json"))
        #expect(asked == ["Use the tool “Disk”?"] && info.hasPrefix("disk.json v1 from the Team catalog: signed, each file checked, reviewed and tested by its CI.")
                && info.contains("list: the script disk.sh (1 lines)"), "\(info)")
        AppDelegate.answering = { _, _, _ in 0 }
        #expect(await c.get(o, window: nil) == "Disk v1 is in your tools: Tools ▸ shows it on servers where it's found")
        let t = try toolNamed(app, "disk")
        #expect(!t.builtIn && app.tools.trust.trusts(t) && c.fetched.pristine(t) && c.fetched.tools["disk"]?.version == 1)
        #expect(mode(bench.dir + "/own/disk.json") == 0o600 && mode(bench.dir + "/own/disk.sh") == 0o600)
        #expect(c.update(for: t) == nil)

        try Data("rm -rf /\n".utf8).write(to: URL(fileURLWithPath: dir + "/tools/disk/1/disk.sh"))
        #expect(await c.get(o, window: nil) == "Disk wasn't got: disk.sh isn't the file the catalog signed (sha256 differs): not taken")
        #expect(try String(contentsOfFile: bench.dir + "/own/disk.sh", encoding: .utf8) == "df -P\n")
    }

    /// Update: as it came, it's replaced after "Use the tool…?" says only what changes. Changed by you: Keep Mine leaves
    /// it, Replace keeps yours as .bak. Remove trashes its files; a built-in of its id is back.
    @Test func updateSaysOnlyWhatChangesAndAsksBeforeReplacingYours() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { closeAll(); bench.done(); done() }
        let dir = bench.dir + "/catalog", c = app.tools.catalogs
        c.sources = [try catalog(dir, serial: 1, [("disk", 1, nil, disk(1))])]
        c.saveSources()   // a Get reads tools/ again
        await c.fetch()
        AppDelegate.answering = { _, _, _ in 0 }
        _ = await c.get(try need(c.offer("disk"), "disk offer"), window: nil)
        _ = try catalog(dir, serial: 2, [("disk", 2, nil, disk(2, lines: 2)), ("ufw", 9, "ufw", try ufw(9))])
        await c.fetch()
        let disk1 = try toolNamed(app, "disk")
        let v2 = try need(c.update(for: disk1), "v2")
        var asked: [String] = [], info = ""
        AppDelegate.answering = { m, _, _ in asked.append(m); info = AppDelegate.answeredInfo; return 0 }
        #expect(await c.update(v2, window: nil) == "Disk is v2 now")
        #expect(asked == ["Use the tool “Disk”?"] && info.hasPrefix("""
            disk.json v2 from the Team catalog, signed and checked, in place of v1. What changes in what it can run:
            Runs by itself:
            + list: the script disk.sh (2 lines)
            − list: the script disk.sh (1 lines)

            """), "\(info)")
        #expect(try toolNamed(app, "disk").preset.catalogVersion == 2 && c.fetched.tools["disk"]?.version == 2 && !FileManager.default.fileExists(atPath: bench.dir + "/own/disk.json.bak"))

        let builtIn = try toolNamed(app, "ufw")
        let ufw9 = try need(c.update(for: builtIn), "ufw v9")
        asked = []
        #expect(await c.update(ufw9, window: nil) == "Ufw is v9 now" && asked == ["Use the tool “Firewall (ufw)”?"])
        #expect(info.hasPrefix("ufw.json v9 from the Team catalog, signed and checked, in place of the built-in: what it runs stays the same.\nRuns by itself:"))
        #expect(!(try toolNamed(app, "ufw").builtIn))

        try Data(#"{ "schema": 1, "id": "disk", "title": "My Disk", "catalogVersion": 1, "list": { "script": "disk.sh" } }"#.utf8)
            .write(to: URL(fileURLWithPath: bench.dir + "/own/disk.json"))
        _ = app.tools.reload()
        _ = try catalog(dir, serial: 3, [("disk", 3, nil, disk(3))])
        await c.fetch()
        let mine = try need(app.tools.library.tools.first { $0.preset.id == "disk" }, "my disk")
        let v3 = try need(c.update(for: mine), "v3")
        asked = []
        AppDelegate.answering = { m, b, _ in asked.append(m); info = AppDelegate.answeredInfo; return b.count - 1 }
        #expect(await c.update(v3, window: nil) == "Disk: yours kept" && asked == ["Replace your “Disk” with v3 from the Team catalog?"])
        #expect(info == "Your disk.json has your changes: it's kept as disk.json.bak." && app.tools.library.tools.contains { $0.preset.title == "My Disk" })
        AppDelegate.answering = { _, _, _ in 0 }
        #expect(await c.update(v3, window: nil) == "Disk is v3 now")
        #expect(try String(contentsOfFile: bench.dir + "/own/disk.json.bak", encoding: .utf8).contains("My Disk"))

        let ufw = try need(app.tools.library.tools.first { $0.preset.id == "ufw" }, "ufw")
        #expect(await c.remove(ufw, window: nil) == "Firewall is removed: the built-in one is back")
        #expect(try toolNamed(app, "ufw").builtIn && !FileManager.default.fileExists(atPath: bench.dir + "/own/ufw.json") && c.fetched.tools["ufw"] == nil)
        #expect(await c.remove(try toolNamed(app, "disk"), window: nil) == "Disk is removed")
        #expect(!FileManager.default.fileExists(atPath: bench.dir + "/own/disk.sh") && app.tools.trust.hashes["disk"] == nil)
    }

    /// Suggested: a catalog tool you don't have whose program a connected server has — asked in one round trip over
    /// its connection, Kermo's own `command -v`, never the catalog's.
    @Test func suggestedLooksForTheProgramWhereConnected() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done(); app.savedServers = [] }
        app.savedServers = [SavedServer(address: "localhost")!, SavedServer(address: "web-01")!]
        let c = app.tools.catalogs
        c.sources = [try catalog(bench.dir + "/catalog", serial: 1, [("who", 1, "whois", disk(1, id: "who")), ("nope", 1, "no-such-program", disk(1, id: "nope")),
                                                                    ("odd", 1, "a b", disk(1, id: "odd")), ("ufw", 9, "ufw", try ufw(9))])]
        await c.fetch()
        #expect(c.connected.isEmpty, "no server connected: none asked")
        AppDelegate.connected = { $0.host == "localhost" }
        #expect(c.connected.map(\.name) == ["localhost"])
        let trips = bench.trips
        let s = await c.suggested(on: [("localhost", .local())])   // the stand-ins run on this Mac
        #expect(s.map(\.offer.entry.id) == ["who"] && s.first?.servers == ["localhost"] && bench.trips == trips + 1, "\(s.map(\.offer.entry.id))")
    }

    /// Settings → Tools: a catalog needs a name, an https:// (or file://) address and an Ed25519 key; one there already
    /// isn't added twice; off, it isn't fetched.
    @Test func aCatalogIsAddedOnlyWhole() async throws {
        let (app, _, _, done) = try toolsApp()
        let bench = try ToolsBench()
        defer { bench.done(); done() }
        let pane = ToolSourcesPane(app: app), k = key.publicKey.rawRepresentation.base64EncodedString()
        #expect(pane.add(.init(name: "", url: "https://example.com/", key: k)) == "A catalog needs a name.")
        #expect(pane.add(.init(name: "Team", url: "http://example.com/", key: k)) == "Its address starts with https:// (or file:// for a folder on a disk).")
        #expect(pane.add(.init(name: "Team", url: "https://example.com/", key: "abc")) == "Its key is the catalog's Ed25519 public key: 32 bytes, base64.")
        #expect(pane.add(.init(name: "Team", url: "https://example.com/tools", key: k)) == nil && pane.table.numberOfRows == 1)
        #expect(pane.add(.init(name: "Again", url: "https://example.com/tools/", key: k)) == "That catalog is in the list already.")
        pane.setOn(0, false)
        Config.flush()
        #expect(app.tools.catalogs.reload().isEmpty && app.tools.catalogs.sources.first?.off == true)
        await app.tools.catalogs.fetch()
        #expect(app.tools.catalogs.problems.isEmpty && app.tools.catalogs.offers.isEmpty)
    }
}
