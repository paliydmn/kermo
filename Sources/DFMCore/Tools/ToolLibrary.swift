import CryptoKit
import Foundation

/// A preset as Kermo loaded it, with its scripts' text and the hash trust goes by.
public struct LoadedTool: Sendable {
    public var preset: ToolPreset
    public var path: String
    public var builtIn: Bool
    public var scripts: [String: String]
    /// sha256 of the file and every script it names (§12): a change to any of them is a new version to trust.
    public var hash: String
    /// Warnings: it loads, and Problems shows them.
    public var warnings: [ToolProblem]
}

/// The tools Kermo knows: the built-in ones, and your own from `~/.config/dfilemanager/tools/` (§12). One of yours
/// with a built-in's id takes its place; one with an error isn't loaded, and says why.
public struct ToolLibrary: Sendable {
    public var tools: [LoadedTool]
    /// What couldn't be loaded and why, as Reload Config says it: "tools/ufw.json: line 3: …".
    public var problems: [String]

    public init(tools: [LoadedTool] = [], problems: [String] = []) { (self.tools, self.problems) = (tools, problems) }

    /// `own`: your folder (nil: none). `uid`: who may own your files. `hasSymbol`: whether this macOS has an SF Symbol.
    public static func load(builtIn: URL = ToolPreset.builtInFolder, own: URL?, uid: uid_t = getuid(),
                            hasSymbol: @escaping (String) -> Bool = { _ in true }) -> ToolLibrary {
        var problems: [String] = []
        func read(_ dir: URL, builtIn: Bool) -> [LoadedTool] {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".json") && (builtIn || !kermosOwn.contains($0)) }.sorted()
            return files.compactMap { f in
                let path = dir.appendingPathComponent(f).path, label = builtIn ? "built-in \(f)" : "tools/\(f)"
                if !builtIn, let why = refusal(path, uid: uid) { problems.append("\(label): not loaded: \(why)"); return nil }
                guard let data = FileManager.default.contents(atPath: path) else { problems.append("\(label): not loaded: it can't be read"); return nil }
                let (preset, found) = ToolSchema.validate(data, file: f, hasScript: { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) },
                                                          hasSymbol: hasSymbol)
                guard let preset else {
                    problems += found.filter { $0.level == .error }.map { "\(label): \($0)" }
                    return nil
                }
                var scripts: [String: String] = [:], hash = SHA256()
                hash.update(data: data)
                for name in preset.scriptNames.sorted() {
                    let sp = dir.appendingPathComponent(name).path
                    if !builtIn, let why = refusal(sp, uid: uid) { problems.append("\(label): not loaded: \(name): \(why)"); return nil }
                    guard let s = FileManager.default.contents(atPath: sp) else { problems.append("\(label): not loaded: \(name) can't be read"); return nil }
                    hash.update(data: Data("\0\(name)\0".utf8))
                    hash.update(data: s)
                    scripts[name] = String(decoding: s, as: UTF8.self)
                }
                return LoadedTool(preset: preset, path: path, builtIn: builtIn, scripts: scripts,
                                  hash: hash.finalize().map { String(format: "%02x", $0) }.joined(), warnings: found)
            }
        }
        var tools = read(builtIn, builtIn: true)
        for t in own.map({ read($0, builtIn: false) }) ?? [] {
            tools.removeAll { $0.preset.id == t.preset.id }
            tools.append(t)
        }
        return ToolLibrary(tools: tools, problems: problems)
    }

    /// Kermo's own files in your tools folder — what you trusted, what servers had — never a tool.
    public static let kermosOwn: Set<String> = ["trust.json", "known.json", "servers.json", "runs.json", "installed.json"]

    /// Why a file of yours isn't read (as mc has it): someone else owns it, or its group or others may write it. The
    /// file a link leads to counts.
    static func refusal(_ path: String, uid: uid_t) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return "it can't be read" }
        if st.st_uid != uid { return "it belongs to another user" }
        if st.st_mode & (S_IWGRP | S_IWOTH) != 0 { return "its group or others can change it (chmod go-w)" }
        return nil
    }

    /// The tools that may run: built-ins, and yours as trusted (`trust`). An untrusted tool runs nothing, not even
    /// `requires`.
    public func trusted(_ trust: ToolTrust) -> [LoadedTool] { tools.filter(trust.trusts) }
}

/// Which versions of your tools you said to use (`tools/trust.json`): each tool's hash then. A changed file, or a
/// changed script of it, asks again.
public struct ToolTrust: Sendable, Codable, Hashable {
    public var hashes: [String: String] = [:]
    public init() {}
    public func trusts(_ t: LoadedTool) -> Bool { t.builtIn || hashes[t.preset.id] == t.hash }
    public mutating func trust(_ t: LoadedTool) { hashes[t.preset.id] = t.hash }
}

extension ToolPreset {
    /// Every script a Run of the tool names.
    public var scriptNames: Set<String> {
        var runs = [requires, header, list?.run, list?.view.header, stream?.run, poll?.run] + (vars ?? [:]).values.map(\.run)
        for (_, a) in allActions {
            runs += [a.run, a.spec.requires, a.spec.list?.view.header] + (a.spec.inputs ?? []).map(\.run)
        }
        return Set(runs.compactMap { $0?.script } + [script].compactMap { $0 })
    }

    /// The vars' values on a server (§9): what you set there, else what its command found this connection, else its
    /// default. `saved` comes from `tools/servers.json` (Tools PR 4).
    public func varValues(saved: [String: String], found: [String: String] = [:]) -> [String: ToolValue] {
        (vars ?? [:]).reduce(into: [:]) { all, v in
            if let s = saved[v.key] ?? found[v.key] ?? v.value.info.default { all[v.key] = .string(s) }
        }
    }

    /// Vars asked for when the tool is put on a server (`ask`) and not set there yet.
    public func varsToAsk(saved: [String: String]) -> [String] {
        (vars ?? [:]).filter { $0.value.info.ask == true && saved[$0.key] == nil }.keys.sorted()
    }

    /// Vars whose value a command finds, once per connection: its output's first line.
    public var varCommands: [(name: String, run: ToolRun)] {
        (vars ?? [:]).filter { !$0.value.run.sources.isEmpty }.map { ($0.key, $0.value.run) }.sorted { $0.name < $1.name }
    }
}
