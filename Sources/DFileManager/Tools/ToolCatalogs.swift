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
    /// Each source's newest version of each tool this Kermo reads, the sources in their order: the last fetch's.
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

    /// Kermo's own catalog: its key is the one built into this Kermo, whatever `catalogs.json` says (a key saved by an
    /// older Kermo, or written there by hand). Tests: a catalog of their own as Kermo's.
    static var kermo = ToolCatalog.kermo
    /// The catalogs with no `tools/catalogs.json`: Kermo's — none under tests, which never reach GitHub.
    static var start: [ToolCatalog.Source] { Config.isTestRun ? [] : [kermo] }

    /// The ids of the tools built into Kermo: the Catalog lists them, and one comes back when yours of its id goes.
    static let builtIns = Set(((try? FileManager.default.contentsOfDirectory(atPath: ToolPreset.builtInFolder.path)) ?? [])
        .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })

    /// The sources and what came from them, as `tools/` has them now; what can't be read, as Reload Config says it.
    func reload() -> [String] {
        guard let dir = ToolRunner.own?.path else { return [] }
        let s = Config.loadKeeping("catalogs.json", as: [ToolCatalog.Source].self, in: dir)
        let f = Config.loadKeeping("fetched.json", as: ToolFetched.self, in: dir)
        sources = (s.value ?? Self.start).map { s in
            var s = s
            if s.address == Self.kermo.address { s.key = Self.kermo.key }
            return s
        }
        fetched = f.value ?? ToolFetched()
        return [s.problem, f.problem].compactMap { $0.map { "tools/" + $0 } }
    }

    func saveSources() {
        if let dir = ToolRunner.own?.path { Config.save("catalogs.json", sources, in: dir) }
    }

    private func saveFetched() {
        if let dir = ToolRunner.own?.path { Config.save("fetched.json", fetched, in: dir) }
    }

    /// A newer version of `tool` from where it comes from: the catalog it was got from, or for a built-in (and yours
    /// in its place) Kermo's own; nil for one of yours of another id, or none newer. Another catalog's tool of the same
    /// id is no update: a team's v99 never stands in for Kermo's own.
    func update(for tool: LoadedTool) -> Offer? {
        let id = tool.preset.id, got = fetched.tools[id]
        guard let from = got?.source ?? (Self.builtIns.contains(id) ? Self.kermo.address : nil) else { return nil }
        let have = got?.version ?? tool.preset.catalogVersion ?? 0
        return offers.first { $0.entry.id == id && $0.source.address == from && $0.entry.version > have }
    }

    /// The first catalog's version of `id`.
    func offer(_ id: String) -> Offer? { offers.first { $0.entry.id == id } }

    /// A catalog turned off or removed: its offers go at once, though fetched before.
    func forget(_ s: ToolCatalog.Source) {
        offers.removeAll { $0.source.address == s.address }
        ToolsWindow.refresh()
    }

    /// Each source that's on, all at once: its index, taken only signed by its key and no older than one seen; then the
    /// offers. A second call while one runs waits for it; `Updates.get` gives each request a minute at most.
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
        let on = sources.filter { $0.off != true }, seen = fetched.serials
        let got = await withTaskGroup(of: (Int, Result<ToolCatalog.Index, Error>).self) { group in
            for (i, s) in on.enumerated() {
                group.addTask {
                    do {
                        guard let base = s.base else { throw Self.notAnAddress }
                        guard s.publicKey != nil else { throw ToolCatalog.keyRefusal }   // nothing fetched for an index never taken
                        async let data = Updates.get(base.appendingPathComponent("catalog.json"), limit: 1 << 20)
                        async let sig = Updates.get(base.appendingPathComponent("catalog.json.sig"), limit: 1 << 10)
                        return (i, .success(try ToolCatalog.index(try await data, signature: try await sig, source: s, seen: seen[s.address])))
                    } catch { return (i, .failure(error)) }
                }
            }
            var all: [Int: Result<ToolCatalog.Index, Error>] = [:]
            for await (i, r) in group { all[i] = r }
            return all
        }
        var indexes: [(ToolCatalog.Source, ToolCatalog.Index)] = [], said: [String] = []
        for (i, s) in on.enumerated() {
            switch got[i] {
            case .success(let index)?:
                fetched.serials[s.address] = index.serial
                indexes.append((s, index))
            case .failure(let error)?: said.append("\(s.name): \(Self.why(error))")
            case nil: break
            }
        }
        offers = ToolCatalog.newest(indexes) { e in e.minKermo.map { !Updates.isNewer($0, than: Updates.current) } ?? true }.map(Offer.init)
        (problems, at) = (said, Date())
        saveFetched()
        ToolsWindow.refresh()
    }

    /// The tools you have that the catalogs have newer: Check for Updates… names them.
    var updates: [LoadedTool] { app.tools.library.tools.filter { update(for: $0) != nil } }

    nonisolated static let notAnAddress = ToolCatalog.Refusal("its address is neither https:// nor file://")

    static func why(_ error: Error) -> String {
        (error as? ToolCatalog.Refusal)?.description ?? error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    // MARK: Get, Update, Remove

    /// `o`'s files, each by its signed sum, loaded as a tool from a folder of their own — its files exactly its preset
    /// and the scripts it names, its id the entry's — for "Use the tool…?" to show and Open File to open before anything
    /// lands in your folder. The caller removes `dir`.
    func download(_ o: Offer) async throws -> (tool: LoadedTool, files: [String: Data], dir: URL) {
        guard let base = o.source.base else { throw Self.notAnAddress }
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
            let lead = "\(o.entry.id).json v\(o.entry.version) from the \(o.source.name) catalog: signed, each file checked; "
                + (o.entry.verified == true ? "the catalog says it's reviewed and tested by its CI." : "the catalog doesn't say it's reviewed.") + " Here is everything it can run:"
            guard await app.tools.trustAsk(tool, window: window, lead: lead) else { return "\(name): not got" }
            let kept = try place(files, o, hash: tool.hash)
            return "\(name) v\(o.entry.version) is in your tools: Tools ▸ shows it on servers where it's found" + Self.said(kept)
        } catch { return "\(name) wasn't got: \(Self.why(error))" }
    }

    /// Update: the newer version's files, checked. Yours — written by you, or changed since you got it — is replaced
    /// only if you say so (Compare shows the two; Keep Mine leaves it), and kept as `.bak`. Then "Use the tool…?" with
    /// only what changes in what it runs — all it runs if the one there isn't in use.
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
            let trusted = app.tools.trust.trusts(now), changes = trusted ? tool.changes(from: now) : ""
            let lead = "\(file) v\(o.entry.version) from the \(o.source.name) catalog, signed and checked, in place of "
                + (now.builtIn ? "the built-in" : yours ? "yours" : "v\(fetched.tools[o.entry.id]?.version ?? 0)")
                + (!trusted ? ". Here is everything it can run:" : changes.isEmpty ? ": what it runs stays the same." : ". What changes in what it can run:")
            guard await app.tools.trustAsk(tool, window: window, lead: lead, runs: changes.isEmpty ? nil : changes) else { return "\(name): not updated" }
            let kept = try place(files, o, hash: tool.hash)
            return "\(name) is v\(o.entry.version) now" + Self.said(kept)
        } catch { return "\(name) wasn't updated: \(Self.why(error))" }
    }

    /// The files written into your tools folder, each in one piece, owner-only. A file there that isn't the one Kermo
    /// wrote for this tool last — yours, one you changed, one that doesn't load — is kept as `.bak` first, decided now:
    /// you may have saved it while the questions were up. Where it came from noted; then the tools read again. The
    /// names kept.
    private func place(_ files: [String: Data], _ o: Offer, hash: String) throws -> [String] {
        guard let own = ToolRunner.own else { throw ToolCatalog.Refusal("there's no tools folder") }
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        chmod(own.path, 0o700)
        let wrote = fetched.tools[o.entry.id]?.files ?? [:]
        var kept: [String] = []
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            let to = own.appendingPathComponent(name)
            if let there = FileManager.default.contents(atPath: to.path), there != data, ToolCatalog.sum(there) != wrote[name] {
                let bak = own.appendingPathComponent(name + ".bak")
                try? FileManager.default.removeItem(at: bak)
                try FileManager.default.copyItem(at: to, to: bak)
                kept.append(bak.lastPathComponent)
            }
            try data.write(to: to, options: .atomic)
            chmod(to.path, 0o600)
        }
        fetched.tools[o.entry.id] = .init(source: o.source.address, version: o.entry.version, hash: hash, files: files.mapValues(ToolCatalog.sum))
        saveFetched()
        reloadTools()
        return kept
    }

    private static func said(_ kept: [String]) -> String { kept.isEmpty ? "" : " — what was there is kept as " + kept.joined(separator: ", ") }

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
        let stuck = files.filter { (try? FileManager.default.trashItem(at: own.appendingPathComponent($0), resultingItemURL: nil)) == nil }
        app.tools.trust.hashes[p.id] = nil
        Config.save("trust.json", app.tools.trust, in: own.path)
        fetched.tools[p.id] = nil
        saveFetched()
        reloadTools()
        guard stuck.isEmpty else { return "\(name): " + stuck.joined(separator: ", ") + " couldn't go to the Trash" }
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

    /// Suggested (§10.2): the catalogs' tools you don't have whose program is on one of `servers` — `command -v` with
    /// its name as a variable, all in one round trip over a server's connection, never a login. Kermo's own check: a
    /// catalog's `requires` runs nothing before you get its tool. Each offer (the first catalog's) with the servers.
    func suggested(on servers: [(name: String, target: SFTPTarget)]) async -> [(offer: Offer, servers: [String])] {
        var ids = Set(app.tools.library.tools.map(\.preset.id))
        let wanted = offers.filter { o in
            ids.insert(o.entry.id).inserted && o.entry.tool.map { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) } } == true
        }
        guard !wanted.isEmpty else { return [] }
        let program = Dictionary(wanted.map { ($0.entry.id, ToolValue.string($0.entry.tool!)) }) { a, _ in a }
        let items = wanted.map { ToolBatch.Item(tool: $0.entry.id, action: nil, run: ToolRun(command: .one("command -v {program}"))) }
        var found: [String: [String]] = [:]
        let command = ToolRunner.command, live = ToolRunner.hasMaster
        for (name, t) in servers {
            let a = await Blocking.run {
                ToolBatch.ask(t, items, scope: { .init(vars: ["program": program[$0] ?? .string("")]) }, scripts: { _ in [:] }, hasMaster: live, command: command)
            }
            for id in a?.passed ?? [] { found[id, default: []].append(name) }
        }
        return wanted.compactMap { o in found[o.entry.id].map { (o, $0) } }
    }
}
