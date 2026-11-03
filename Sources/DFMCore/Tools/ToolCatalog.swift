import CryptoKit
import Foundation

/// A catalog of tools (protocol §12, Tools PR 8): a folder on the web — or on a disk — with `catalog.json`, the index
/// of its tools and their files by sha256, and `catalog.json.sig`, the index's Ed25519 signature (base64). Kermo takes
/// an index only with its source's key, and a file only with the sha256 the signed index gives it: whoever can swap
/// the files on GitHub or a CDN can't swap the key built into Kermo. Nothing here touches the network.
public enum ToolCatalog {
    /// Where a catalog lives (`tools/catalogs.json`): its folder's address, the key it signs with, on or off.
    public struct Source: Sendable, Codable, Hashable {
        public var name: String
        /// The folder: `catalog.json` and the files' paths are under it ("https://…/main/", "file:///…/").
        public var url: String
        /// The Ed25519 public key, base64: its raw 32 bytes, or as `openssl pkey -pubout` writes it (PEM's lines or not).
        public var key: String
        public var off: Bool?

        public init(name: String, url: String, key: String, off: Bool? = nil) { (self.name, self.url, self.key, self.off) = (name, url, key, off) }

        /// The folder's address with its slash, or nil: only https, and file for a catalog on a disk.
        public var base: URL? {
            guard let u = URL(string: url.hasSuffix("/") ? url : url + "/"), ["https", "file"].contains(u.scheme ?? "") else { return nil }
            return u
        }

        /// What serials and the tools got from it go by: the folder's address as Kermo reads it (with its slash).
        public var address: String { base?.absoluteString ?? url }

        public var publicKey: Curve25519.Signing.PublicKey? {
            let text = key.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
            guard var raw = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { return nil }
            if raw.count == 44, raw.prefix(12) == Self.spki { raw = raw.dropFirst(12) }   // SubjectPublicKeyInfo, Ed25519's
            return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        }

        static let spki = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
    }

    /// Kermo's own: the one `tools/catalogs.json` starts with.
    public static let kermo = Source(name: "Kermo", url: "https://raw.githubusercontent.com/paliydmn/kermo-tools/main/",
                                     key: "MCowBQYDK2VwAyEArE7Xgq4hVRlyai1MbZDGfCaWEKSDDzmfu6QJrMTF4j0=")

    /// `catalog.json`. `serial` grows with each index signed: one lower than an index seen before is an old one served
    /// again, and refused — an old version of a tool may be one with a hole since fixed.
    public struct Index: Sendable, Codable, Hashable {
        public var catalog: Int
        public var serial: Int
        public var tools: [Entry]
        public init(catalog: Int = 1, serial: Int, tools: [Entry]) { (self.catalog, self.serial, self.tools) = (catalog, serial, tools) }
    }

    /// A version of a tool. The same id may be there more than once: the newest for each `minKermo` (§12).
    public struct Entry: Sendable, Codable, Hashable {
        public var id, title: String
        /// The program it's for: Suggested looks for it on your servers.
        public var tool, icon, about, author, minKermo: String?
        public var version: Int
        /// Reviewed, and checked by the catalog's CI.
        public var verified: Bool?
        public var files: [File]

        public init(id: String, title: String, tool: String? = nil, about: String? = nil, version: Int, verified: Bool? = nil, minKermo: String? = nil,
                    files: [File]) {
            (self.id, self.title, self.tool, self.about, self.version, self.verified, self.minKermo, self.files) = (id, title, tool, about, version, verified, minKermo, files)
        }

        /// The preset's file: `<id>.json`; the others are its scripts, `<id>.…` (§12).
        public var preset: File? { files.first { $0.name == id + ".json" } }

        /// Its files' names make a tool of its own in your folder: `<id>.json` once, every other one `<id>.<name>` and
        /// neither JSON nor a backup — so none lands on another tool's file, on one of Kermo's own (`trust.json`,
        /// `catalogs.json`…) or on a `.bak` — none two that a Mac's disk takes for one, at most `maxFiles`.
        var named: Bool {
            let names = files.map(\.name)
            return !ToolLibrary.kermosOwn.contains(id + ".json") && names.filter { $0 == id + ".json" }.count == 1 && names.count <= Self.maxFiles
                && names.map { $0.lowercased() }.allSatisfy { $0 == id + ".json" || ($0.hasPrefix(id + ".") && !$0.hasSuffix(".json") && !$0.hasSuffix(".bak")) }
                && Set(names.map { $0.lowercased() }).count == names.count
        }

        public static let maxFiles = 20
    }

    public struct File: Sendable, Codable, Hashable {
        /// Under the catalog's folder: "tools/restic/2/restic.json".
        public var path: String
        public var sha256: String
        public init(path: String, sha256: String) { (self.path, self.sha256) = (path, sha256) }
        /// The name it takes in your tools folder.
        public var name: String { String(path.split(separator: "/").last ?? "") }
    }

    public struct Refusal: Error, CustomStringConvertible, Equatable {
        public var description: String
        public init(_ s: String) { description = s }
    }

    /// A path under the folder: plain names — no "..", no hidden file, nothing that means something to a URL.
    static func plain(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            part.first.map { $0 != "." } == true && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        }
    }

    /// The index in `data`, once `signature` (base64, its lines wrapped or not) shows `source`'s key signed these very
    /// bytes, its serial no lower than `seen` (the highest taken from this source before), and each entry well-formed.
    /// Nothing of it is read before.
    public static func index(_ data: Data, signature: Data, source: Source, seen: Int?) throws -> Index {
        guard let key = source.publicKey else { throw keyRefusal }
        let sig = Data(base64Encoded: String(decoding: signature, as: UTF8.self), options: .ignoreUnknownCharacters)
        guard let sig, key.isValidSignature(sig, for: data) else { throw Refusal("its signature doesn't match its key: not taken") }
        guard let index = try? JSONDecoder().decode(Index.self, from: data) else { throw Refusal("its index can't be read") }
        guard index.catalog == 1 else { throw Refusal("its index needs a newer Kermo") }
        if let seen, index.serial < seen { throw Refusal("its index is older than one seen before (\(index.serial) < \(seen)): not taken") }
        for e in index.tools {
            guard ToolSchema.isID(e.id), e.named,
                  e.files.allSatisfy({ plain($0.path) && $0.sha256.count == 64 && $0.sha256.allSatisfy { "0123456789abcdef".contains($0) } })
            else { throw Refusal("its entry “\(e.id)” isn't well-formed: not taken") }
        }
        return index
    }

    public static let keyRefusal = Refusal("its key isn't an Ed25519 public key (base64)")

    /// Per source, each id's newest version this Kermo reads (`readable`: its `minKermo`); the sources in their order.
    public static func newest(_ indexes: [(Source, Index)], readable: (Entry) -> Bool) -> [(source: Source, entry: Entry)] {
        indexes.flatMap { s, i in
            var here: [String: Entry] = [:]
            for e in i.tools where readable(e) && e.version > here[e.id]?.version ?? .min { here[e.id] = e }
            return here.sorted { $0.key < $1.key }.map { (s, $0.value) }
        }
    }

    /// A file's sha256, as the index has it.
    public static func sum(_ data: Data) -> String { SHA256.hash(data: data).hex }

    /// Whether `data` is the file the signed index says.
    public static func check(_ data: Data, _ f: File) throws {
        guard sum(data) == f.sha256 else { throw Refusal("\(f.name) isn't the file the catalog signed (sha256 differs): not taken") }
    }

    /// Whether `entry`'s files make `preset` whole: its id and its version, its `<id>.json`, the scripts it names and
    /// nothing else — no file of it lands in your folder under a name the tool doesn't use.
    public static func fits(_ entry: Entry, _ preset: ToolPreset) throws {
        guard preset.id == entry.id else { throw Refusal("\(entry.id).json says it's “\(preset.id)”: not taken") }
        guard preset.catalogVersion == entry.version else { throw Refusal("\(entry.id).json says it's version \(preset.catalogVersion ?? 0), not \(entry.version): not taken") }
        let names = Set(entry.files.map(\.name)), wanted = preset.scriptNames.union([entry.id + ".json"])
        guard names == wanted else {
            throw Refusal("\(entry.id)'s files aren't the ones it names (" + names.symmetricDifference(wanted).sorted().joined(separator: ", ") + "): not taken")
        }
    }
}

/// What Kermo got from catalogs (`tools/fetched.json`): each tool's source, version and hash as written — a tool whose
/// hash is no longer that one was changed by you, and an update asks before it replaces it — and each file's sha256 as
/// written, so a file there that isn't one of those is kept as `.bak` before anything is written over it; and the
/// highest serial taken from each source.
public struct ToolFetched: Sendable, Codable, Hashable {
    public struct Got: Sendable, Codable, Hashable {
        /// The source's `address`: its updates come from there only.
        public var source: String
        public var version: Int
        public var hash: String
        public var files: [String: String]
        public init(source: String, version: Int, hash: String, files: [String: String] = [:]) {
            (self.source, self.version, self.hash, self.files) = (source, version, hash, files)
        }

        /// One written without its files' sums keeps every file there as `.bak` on its next update.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            (source, version, hash) = (try c.decode(String.self, forKey: .source), try c.decode(Int.self, forKey: .version), try c.decode(String.self, forKey: .hash))
            files = try c.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
        }
    }
    public var tools: [String: Got] = [:]
    /// By the source's `address`.
    public var serials: [String: Int] = [:]
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tools = try c.decodeIfPresent([String: Got].self, forKey: .tools) ?? [:]
        serials = try c.decodeIfPresent([String: Int].self, forKey: .serials) ?? [:]
    }

    /// From a catalog and as it came: an update replaces it without asking about your changes.
    public func pristine(_ t: LoadedTool) -> Bool { !t.builtIn && tools[t.preset.id]?.hash == t.hash }
}

extension LoadedTool {
    /// What this version runs that `old` didn't (+) and what it no longer runs (−), group by group — a line that only
    /// stopped or started being dangerous counts — then each script whose text changed (~): a script's line says only
    /// its name and length. An update's "Use the tool…?" says only this. Empty: it runs the same.
    public func changes(from old: LoadedTool) -> String {
        func text(_ l: ToolRuns.Line) -> String { String(l.text.dropFirst(2)) + (l.dangerous ? "   — dangerous" : "") }
        let was = Dictionary(old.runs.groups.map { ($0.title, $0.lines) }) { a, _ in a }, now = Dictionary(runs.groups.map { ($0.title, $0.lines) }) { a, _ in a }
        var titles = runs.groups.map(\.title)
        titles += old.runs.groups.map(\.title).filter { !titles.contains($0) }
        let runs = titles.compactMap { t -> String? in
            let a = was[t] ?? [], b = now[t] ?? []
            let lines = b.filter { !a.contains($0) }.map { "+ " + text($0) } + a.filter { !b.contains($0) }.map { "− " + text($0) }
            return lines.isEmpty ? nil : (["\(t):"] + lines).joined(separator: "\n")
        }
        let changed = scripts.keys.sorted().filter { old.scripts[$0] != nil && old.scripts[$0] != scripts[$0] }
        return (runs + (changed.isEmpty ? [] : ["Scripts whose text changed (Open File shows them):"] + changed.map { "~ " + $0 })).joined(separator: "\n")
    }

    /// Whether it differs from `old` in more than its words, its look and its version — in what `changes` has no line
    /// for too (an `env`, a `files` path, an address): an update with no changes may still not run the same.
    public func differs(from old: LoadedTool) -> Bool {
        func bare(_ p: ToolPreset) -> ToolPreset {
            var p = p
            (p.title, p.tool, p.about, p.icon, p.group, p.author, p.minKermo, p.catalogVersion, p.notes, p.schemaURL) = ("", nil, nil, nil, nil, nil, nil, nil, nil, nil)
            return p
        }
        return bare(preset) != bare(old.preset) || scripts != old.scripts
    }
}

extension SHA256.Digest {
    /// Lowercase hex, as sha256sum prints it.
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}
