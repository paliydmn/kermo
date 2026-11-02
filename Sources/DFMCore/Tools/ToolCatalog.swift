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
        /// The raw 32-byte Ed25519 public key, base64.
        public var key: String
        public var off: Bool?

        public init(name: String, url: String, key: String, off: Bool? = nil) { (self.name, self.url, self.key, self.off) = (name, url, key, off) }

        /// The folder's address with its slash, or nil: only https, and file for a catalog on a disk.
        public var base: URL? {
            guard let u = URL(string: url.hasSuffix("/") ? url : url + "/"), ["https", "file"].contains(u.scheme ?? "") else { return nil }
            return u
        }

        public var publicKey: Curve25519.Signing.PublicKey? {
            Data(base64Encoded: key).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        }
    }

    /// Kermo's own: the one `tools/catalogs.json` starts with.
    public static let kermo = Source(name: "Kermo", url: "https://raw.githubusercontent.com/paliydmn/kermo-tools/main/",
                                     key: "MCowBQYDK2VwAyEA-placeholder-until-the-key-ceremony=")

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

        /// The preset's file: `<id>.json`; the others are its scripts.
        public var preset: File? { files.first { $0.name == id + ".json" } }
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
        init(_ s: String) { description = s }
    }

    /// A path under the folder: plain names — no "..", no hidden file, nothing that means something to a URL.
    static func plain(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            part.first.map { $0 != "." } == true && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        }
    }

    /// The index in `data`, once `signature` (base64) shows `source`'s key signed these very bytes, its serial no lower
    /// than `seen` (the highest taken from this source before), and each entry well-formed. Nothing of it is read before.
    public static func index(_ data: Data, signature: Data, source: Source, seen: Int?) throws -> Index {
        guard let key = source.publicKey else { throw Refusal("its key isn't an Ed25519 public key (32 bytes, base64)") }
        let sig = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        guard let sig, key.isValidSignature(sig, for: data) else { throw Refusal("its signature doesn't match its key: not taken") }
        guard let index = try? JSONDecoder().decode(Index.self, from: data) else { throw Refusal("its index can't be read") }
        guard index.catalog == 1 else { throw Refusal("its index needs a newer Kermo") }
        if let seen, index.serial < seen { throw Refusal("its index is older than one seen before (\(index.serial) < \(seen)): not taken") }
        for e in index.tools {
            guard !e.id.isEmpty, e.id.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }), e.preset != nil,
                  e.files.allSatisfy({ plain($0.path) && $0.sha256.count == 64 && $0.sha256.allSatisfy { "0123456789abcdef".contains($0) } }),
                  Set(e.files.map(\.name)).count == e.files.count
            else { throw Refusal("its entry “\(e.id)” isn't well-formed: not taken") }
        }
        return index
    }

    /// Per id, the newest version this Kermo reads (`readable`: its `minKermo`), from the first source that has the id.
    public static func newest(_ indexes: [(Source, Index)], readable: (Entry) -> Bool) -> [(source: Source, entry: Entry)] {
        var taken: [String: (source: Source, entry: Entry)] = [:], order: [String] = []
        for (s, i) in indexes {
            var here: [String: Entry] = [:]
            for e in i.tools where readable(e) && e.version > here[e.id]?.version ?? .min { here[e.id] = e }
            for (id, e) in here.sorted(by: { $0.key < $1.key }) where taken[id] == nil {
                taken[id] = (s, e)
                order.append(id)
            }
        }
        return order.map { taken[$0]! }
    }

    /// Whether `data` is the file the signed index says.
    public static func check(_ data: Data, _ f: File) throws {
        let sum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard sum == f.sha256 else { throw Refusal("\(f.name) isn't the file the catalog signed (sha256 differs): not taken") }
    }

    /// Whether `entry`'s files make `preset` whole: its id, its `<id>.json`, the scripts it names and nothing else — no
    /// file of it lands in your folder under a name the tool doesn't use.
    public static func fits(_ entry: Entry, _ preset: ToolPreset) throws {
        guard preset.id == entry.id else { throw Refusal("\(entry.id).json says it's “\(preset.id)”: not taken") }
        let names = Set(entry.files.map(\.name)), wanted = preset.scriptNames.union([entry.id + ".json"])
        guard names == wanted else {
            throw Refusal("\(entry.id)'s files aren't the ones it names (" + names.symmetricDifference(wanted).sorted().joined(separator: ", ") + "): not taken")
        }
    }
}

/// What Kermo got from catalogs (`tools/fetched.json`): each tool's source, version and hash as written — a tool whose
/// hash is no longer that one was changed by you, and an update asks before it replaces it; and the highest serial
/// taken from each source.
public struct ToolFetched: Sendable, Codable, Hashable {
    public struct Got: Sendable, Codable, Hashable {
        public var source: String
        public var version: Int
        public var hash: String
        public init(source: String, version: Int, hash: String) { (self.source, self.version, self.hash) = (source, version, hash) }
    }
    public var tools: [String: Got] = [:]
    /// By the source's url.
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

extension ToolRuns {
    /// What `new` runs that `old` didn't (+) and what it no longer runs (−), group by group: an update's "Use the
    /// tool…?" says only that. Empty: what it runs is the same.
    public static func changes(from old: ToolRuns, to new: ToolRuns) -> String {
        let was = Dictionary(old.groups.map { ($0.title, $0.lines.map(\.text)) }) { a, _ in a }
        let now = Dictionary(new.groups.map { ($0.title, $0.lines.map(\.text)) }) { a, _ in a }
        var titles = new.groups.map(\.title)
        titles += old.groups.map(\.title).filter { !titles.contains($0) }
        return titles.compactMap { t -> String? in
            let a = was[t] ?? [], b = now[t] ?? []
            let lines = b.filter { !a.contains($0) }.map { "+" + $0.dropFirst() } + a.filter { !b.contains($0) }.map { "−" + $0.dropFirst() }
            return lines.isEmpty ? nil : (["\(t):"] + lines).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
