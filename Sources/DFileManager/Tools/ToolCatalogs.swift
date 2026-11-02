import AppKit
import DFMCore

// Catalogs (Tools PR 8, protocol §12): where they are (`tools/catalogs.json`, Settings → Tools), their indexes — fetched
// only when you open the Catalog or Check for Updates… — and Get, Update and Remove. A tool got is a file in your tools
// folder like one of yours: it takes a built-in's place as yours does, and its trust goes by its hash as any tool's;
// `tools/fetched.json` says where it came from and what it was, so an update knows whether you changed it.

@MainActor
final class ToolCatalogs {
    unowned let app: AppDelegate
    var sources = ToolCatalogs.start
    private(set) var fetched = ToolFetched()
    /// Each tool's newest version this Kermo reads, from the first source that has it: the last fetch's.
    private(set) var offers: [Offer] = []
    /// What a source said instead of its index, the last fetch: "Kermo: …".
    private(set) var problems: [String] = []
    private(set) var at: Date?
    private var fetching: Task<Void, Never>?

    struct Offer: Sendable {
        let source: ToolCatalog.Source
        let entry: ToolCatalog.Entry
    }

    init(_ app: AppDelegate) { self.app = app }

    /// The catalogs with no `tools/catalogs.json`: Kermo's — none under tests, which never reach GitHub.
    static let start = Config.isTestRun ? [] : [ToolCatalog.kermo]

    /// The ids of the tools built into Kermo: the Catalog lists them, and one comes back when yours of its id goes.
    static let builtIns = Set(((try? FileManager.default.contentsOfDirectory(atPath: ToolPreset.builtInFolder.path)) ?? [])
        .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })

    /// The sources and what came from them, as `tools/` has them now; what can't be read, as Reload Config says it.
    func reload() -> [String] {
        guard let dir = ToolRunner.own?.path else { return [] }
        let s = Config.loadKeeping("catalogs.json", as: [ToolCatalog.Source].self, in: dir)
        let f = Config.loadKeeping("fetched.json", as: ToolFetched.self, in: dir)
        (sources, fetched) = (s.value ?? Self.start, f.value ?? ToolFetched())
        return [s.problem, f.problem].compactMap { $0.map { "tools/" + $0 } }
    }

    func saveSources() {
        if let dir = ToolRunner.own?.path { Config.save("catalogs.json", sources, in: dir) }
    }

    private func saveFetched() {
        if let dir = ToolRunner.own?.path { Config.save("fetched.json", fetched, in: dir) }
    }

    /// The offer of a newer version of `tool` than it is (a built-in's or yours by `catalogVersion`); nil: none known.
    func update(for tool: LoadedTool) -> Offer? {
        offers.first { $0.entry.id == tool.preset.id && $0.entry.version > tool.preset.catalogVersion ?? 0 }
    }

    func offer(_ id: String) -> Offer? { offers.first { $0.entry.id == id } }

    /// Each source that's on: its index, taken only signed by its key and no older than one seen; then the offers. A
    /// second call while one runs waits for it.
    func fetch() async {
        if let fetching { return await fetching.value }
        let task = Task {
            await fetchNow()
            fetching = nil   // as the offers change, not a turn later: a fetch asked then is a new one
        }
        fetching = task
        await task.value
    }

    private func fetchNow() async {
        var indexes: [(ToolCatalog.Source, ToolCatalog.Index)] = [], said: [String] = []
        for s in sources where s.off != true {
            do {
                guard let base = s.base else { throw ToolCatalog.Refusal("its address is neither https:// nor file://") }
                async let data = Updates.get(base.appendingPathComponent("catalog.json"), limit: 1 << 20)
                async let sig = Updates.get(base.appendingPathComponent("catalog.json.sig"), limit: 1 << 10)
                let index = try ToolCatalog.index(try await data, signature: try await sig, source: s, seen: fetched.serials[s.url])
                fetched.serials[s.url] = index.serial
                indexes.append((s, index))
            } catch { said.append("\(s.name): \(Self.why(error))") }
        }
        offers = ToolCatalog.newest(indexes) { e in e.minKermo.map { !Updates.isNewer($0, than: Updates.current) } ?? true }.map(Offer.init)
        (problems, at) = (said, Date())
        saveFetched()
        ToolsWindow.refresh()
    }

    /// The tools you have that the catalogs have newer: Check for Updates… names them.
    var updates: [LoadedTool] { app.tools.library.tools.filter { update(for: $0) != nil } }

    static func why(_ error: Error) -> String {
        (error as? ToolCatalog.Refusal)?.description ?? error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    // MARK: Get, Update, Remove

    /// `o`'s files, each by its signed sum, loaded as a tool from a folder of their own — its files exactly its preset
    /// and the scripts it names, its id the entry's — for "Use the tool…?" to show and Open File to open before anything
    /// lands in your folder. The caller removes `dir`.
    func download(_ o: Offer) async throws -> (tool: LoadedTool, files: [String: Data], dir: URL) {
        guard let base = o.source.base else { throw ToolCatalog.Refusal("its address is neither https:// nor file://") }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kermo-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            var files: [String: Data] = [:]
            for f in o.entry.files {
                let data = try await Updates.get(base.appendingPathComponent(f.path), limit: 1 << 20)
                try ToolCatalog.check(data, f)
                try data.write(to: dir.appendingPathComponent(f.name))
                chmod(dir.appendingPathComponent(f.name).path, 0o600)
                files[f.name] = data
            }
            let lib = ToolLibrary.load(builtIn: dir.appendingPathComponent("none"), own: dir, hasSymbol: Symbol.exists)
            guard let tool = lib.tools.first else { throw ToolCatalog.Refusal(lib.problems.first ?? "\(o.entry.id).json isn't a tool") }
            try ToolCatalog.fits(o.entry, tool.preset)
            return (tool, files, dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// Get: its files, checked; "Use the tool…?" for this version; then in your tools folder, in use where it's found.
    /// What to say of it.
    func get(_ o: Offer, window: NSWindow?) async -> String {
        let name = o.entry.title
        do {
            let (tool, files, dir) = try await download(o)
            defer { try? FileManager.default.removeItem(at: dir) }
            let lead = "\(o.entry.id).json v\(o.entry.version) from the \(o.source.name) catalog: signed, each file checked"
                + (o.entry.verified == true ? ", reviewed and tested by its CI." : ", not reviewed.") + " Here is everything it can run:"
            guard await app.tools.trustAsk(tool, window: window, lead: lead) else { return "\(name): not got" }
            try place(files, o, hash: tool.hash, keep: false)
            return "\(name) v\(o.entry.version) is in your tools: Tools ▸ shows it on servers where it's found"
        } catch { return "\(name) wasn't got: \(Self.why(error))" }
    }

    /// Update: the newer version's files, checked. Yours — written by you, or changed since you got it — is replaced
    /// only if you say so (Compare shows the two; Keep Mine leaves it), and kept as `.bak`. Then "Use the tool…?" with
    /// only what changes in what it runs.
    func update(_ o: Offer, window: NSWindow?) async -> String {
        guard let now = app.tools.library.tools.first(where: { $0.preset.id == o.entry.id }) else { return await get(o, window: window) }
        let name = o.entry.title, file = o.entry.id + ".json"
        do {
            let (tool, files, dir) = try await download(o)
            defer { try? FileManager.default.removeItem(at: dir) }
            let yours = !now.builtIn && !fetched.pristine(now)
            if yours {
                var c = Confirm("Replace your “\(name)” with v\(o.entry.version) from the \(o.source.name) catalog?", action: "Replace")
                c.runs = "Your \(file) " + (fetched.tools[o.entry.id] == nil ? "is your own" : "has your changes") + ": it's kept as \(file).bak."
                (c.others, c.cancel) = (["Compare"], "Keep Mine")
                ask: while true {
                    switch await app.confirm(c, on: window) {
                    case 0: break ask
                    case 1: await app.diff(.init(path: now.path, name: "yours: \(file)"), .init(path: tool.path, name: "v\(o.entry.version): \(file)"), in: app.active)
                    default: return "\(name): yours kept"
                    }
                }
            }
            let changes = ToolRuns.changes(from: now.runs, to: tool.runs)
            let lead = "\(file) v\(o.entry.version) from the \(o.source.name) catalog, signed and checked, in place of "
                + (now.builtIn ? "the built-in" : yours ? "yours" : "v\(now.preset.catalogVersion ?? 0)") + (changes.isEmpty ? ": what it runs stays the same." : ". What changes in what it can run:")
            guard await app.tools.trustAsk(tool, window: window, lead: lead, runs: changes.isEmpty ? nil : changes) else { return "\(name): not updated" }
            try place(files, o, hash: tool.hash, keep: yours)
            return "\(name) is v\(o.entry.version) now"
        } catch { return "\(name) wasn't updated: \(Self.why(error))" }
    }

    /// The files written into your tools folder — each whole or not at all, owner-only; yours of a name kept as `.bak`
    /// first when `keep` — and where it came from noted; then the tools read again.
    private func place(_ files: [String: Data], _ o: Offer, hash: String, keep: Bool) throws {
        guard let own = ToolRunner.own else { throw ToolCatalog.Refusal("there's no tools folder") }
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        chmod(own.path, 0o700)
        for (name, data) in files {
            let to = own.appendingPathComponent(name)
            if keep, FileManager.default.fileExists(atPath: to.path) {
                let bak = own.appendingPathComponent(name + ".bak")
                try? FileManager.default.removeItem(at: bak)
                try FileManager.default.copyItem(at: to, to: bak)
            }
            try data.write(to: to, options: .atomic)
            chmod(to.path, 0o600)
        }
        fetched.tools[o.entry.id] = .init(source: o.source.url, version: o.entry.version, hash: hash)
        saveFetched()
        reloadTools()
    }

    /// Remove: one of yours, or one got from a catalog — its file and its scripts no other tool of yours names, to the
    /// Trash; what you trusted of it and where it came from, forgotten. A built-in of its id is back.
    func remove(_ tool: LoadedTool, window: NSWindow?) async -> String {
        let p = tool.preset, name = p.title
        guard !tool.builtIn, let own = ToolRunner.own else { return "\(name) is built into Kermo" }
        let others = app.tools.library.tools.filter { !$0.builtIn && $0.preset.id != p.id }.flatMap(\.preset.scriptNames)
        let files = [(tool.path as NSString).lastPathComponent] + p.scriptNames.subtracting(others).sorted()
        let builtIn = Self.builtIns.contains(p.id)
        var c = Confirm("Remove “\(name)”?", action: "Remove")
        c.items = files.map { Confirm.Item(name: $0) }
        c.runs = "Its files go to the Trash" + (builtIn ? "; the one built into Kermo is back in its place." : ".")
        guard await app.confirm(c, on: window) == 0 else { return "\(name): kept" }
        for f in files { try? FileManager.default.trashItem(at: own.appendingPathComponent(f), resultingItemURL: nil) }
        app.tools.trust.hashes[p.id] = nil
        Config.save("trust.json", app.tools.trust, in: own.path)
        fetched.tools[p.id] = nil
        saveFetched()
        reloadTools()
        return "\(name) is removed" + (builtIn ? ": the built-in one is back" : "")
    }

    private func reloadTools() {
        Config.flush()   // trust.json and fetched.json as last written: reload reads them back
        _ = app.tools.reload()
        app.toolsKnown(on: nil)
    }

    // MARK: Suggested

    /// The servers connected now, by name: saved ones, then others with a session.
    var connected: [(name: String, target: SFTPTarget)] {
        var seen = Set<String>()
        return (app.savedServers.map { ($0.title, $0.target) } + app.serverList.sessions.map { (SavedServer.name(for: $0.target.asUser), $0.target.asUser) })
            .filter { AppDelegate.connected($0.1) && seen.insert(ServerRow.key($0.1)).inserted }
    }

    /// Suggested (§10.2): the catalog's tools you don't have whose program is on one of `servers` — one `command -v`
    /// each, in one round trip over its connection, never a login. Kermo's own check: a catalog's `requires` runs
    /// nothing before you get its tool. Each offer with the servers that have it.
    func suggested(on servers: [(name: String, target: SFTPTarget)]) async -> [(offer: Offer, servers: [String])] {
        let have = Set(app.tools.library.tools.map(\.preset.id))
        let wanted = offers.filter { o in
            !have.contains(o.entry.id) && o.entry.tool.map { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) } } == true
        }
        guard !wanted.isEmpty else { return [] }
        let items = wanted.map { ToolBatch.Item(tool: $0.entry.id, action: nil, run: ToolRun(command: .one("command -v " + $0.entry.tool!))) }
        var found: [String: [String]] = [:]
        let command = ToolRunner.command, live = ToolRunner.hasMaster
        for (name, t) in servers {
            let a = await Blocking.run { ToolBatch.ask(t, items, scope: { _ in .init() }, scripts: { _ in [:] }, hasMaster: live, command: command) }
            for id in a?.passed ?? [] { found[id, default: []].append(name) }
        }
        return wanted.compactMap { o in found[o.entry.id].map { (o, $0) } }
    }
}
