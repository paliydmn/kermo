import CryptoKit
import Foundation
import Testing
@testable import DFMCore

// A catalog (protocol §12, Tools PR 8): an index taken only with its source's signature over its very bytes and a serial
// no lower than one seen; its entries' paths plain names under the folder; a file only with the signed sha256; per id
// the newest version this Kermo reads, from the first source that has it; an update says only what changes.

private let key = Curve25519.Signing.PrivateKey()
private let source = ToolCatalog.Source(name: "Test", url: "https://example.com/tools", key: key.publicKey.rawRepresentation.base64EncodedString())

private func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
private func entry(_ id: String, _ version: Int, minKermo: String? = nil, files: [String]? = nil) -> ToolCatalog.Entry {
    ToolCatalog.Entry(id: id, title: id, version: version, minKermo: minKermo,
                      files: (files ?? ["tools/\(id)/\(version)/\(id).json"]).map { ToolCatalog.File(path: $0, sha256: sha($0)) })
}
private func signed(_ index: ToolCatalog.Index) throws -> (Data, Data) {
    let data = try JSONEncoder().encode(index)
    return (data, Data(try key.signature(for: data).base64EncodedString().utf8 + [10]))
}

@Test func anIndexIsTakenOnlyWithItsSourcesSignature() throws {
    let (data, sig) = try signed(ToolCatalog.Index(serial: 5, tools: [entry("restic", 2)]))
    #expect(try ToolCatalog.index(data, signature: sig, source: source, seen: 4).tools.map(\.id) == ["restic"])
    #expect(try ToolCatalog.index(data, signature: sig, source: source, seen: 5).serial == 5, "the same index again")
    var other = source
    other.key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    #expect(throws: ToolCatalog.Refusal("its signature doesn't match its key: not taken")) { try ToolCatalog.index(data, signature: sig, source: other, seen: nil) }
    var changed = data
    changed[changed.count - 2] ^= 1
    #expect(throws: ToolCatalog.Refusal("its signature doesn't match its key: not taken")) { try ToolCatalog.index(changed, signature: sig, source: source, seen: nil) }
    #expect(throws: ToolCatalog.Refusal("its index is older than one seen before (5 < 6): not taken")) { try ToolCatalog.index(data, signature: sig, source: source, seen: 6) }
    other.key = "not a key"
    #expect(throws: ToolCatalog.Refusal("its key isn't an Ed25519 public key (32 bytes, base64)")) { try ToolCatalog.index(data, signature: sig, source: other, seen: nil) }
    let (newer, newerSig) = try signed(ToolCatalog.Index(catalog: 2, serial: 7, tools: []))
    #expect(throws: ToolCatalog.Refusal("its index needs a newer Kermo")) { try ToolCatalog.index(newer, signature: newerSig, source: source, seen: nil) }
}

/// A signature made by OpenSSL 3 (`openssl pkeyutl -sign -rawin`, as the catalog's key ceremony signs) is one CryptoKit
/// takes: both are plain Ed25519.
@Test func anOpenSSLSignatureIsTaken() throws {
    let s = ToolCatalog.Source(name: "OpenSSL", url: "https://example.com/", key: "7Cim273+Ofu1o4xxkB6a1Wicru4YwJlNWZYuISTS77M=")
    let sig = "IoT1LqvdcJjNmOoy0WtyR/ucacjpUs0w60Ye8uNx0eRJ/MOMuwGxFQv3IkVwytGqvqn18Qge+yCUVraahkkvAA==\n"
    let data = Data(#"{"catalog":1,"serial":1,"tools":[]}"#.utf8 + [10])
    #expect(try ToolCatalog.index(data, signature: Data(sig.utf8), source: s, seen: nil).serial == 1)
}

/// What could leave the folder or land under another name isn't taken: a path with "..", a hidden file, an absolute
/// path, a URL's characters; an id that isn't one; no `<id>.json`; two files of one name.
@Test func anEntryThatIsntWellFormedIsRefused() throws {
    for bad in [entry("x", 1, files: ["tools/../x.json"]), entry("x", 1, files: ["/etc/x.json"]), entry("x", 1, files: ["tools/x/.x.json", "x.json"]),
                entry("x", 1, files: ["tools/x.json?y"]), entry("x", 1, files: ["tools//x.json"]), entry("X", 1, files: ["X.json"]),
                entry("x", 1, files: ["tools/x/x.sh"]), entry("x", 1, files: ["a/x.json", "b/x.json"])] {
        let (data, sig) = try signed(ToolCatalog.Index(serial: 1, tools: [bad]))
        #expect(throws: ToolCatalog.Refusal("its entry “\(bad.id)” isn't well-formed: not taken"), "\(bad.files.map(\.path))") {
            try ToolCatalog.index(data, signature: sig, source: source, seen: nil)
        }
    }
    var short = entry("x", 1)
    short.files[0].sha256 = "abc"
    let (data, sig) = try signed(ToolCatalog.Index(serial: 1, tools: [short]))
    #expect(throws: ToolCatalog.Refusal("its entry “x” isn't well-formed: not taken")) { try ToolCatalog.index(data, signature: sig, source: source, seen: nil) }
}

@Test func aFileIsTakenOnlyWithItsSignedSum() throws {
    let f = ToolCatalog.File(path: "tools/x/1/x.json", sha256: sha("{}"))
    try ToolCatalog.check(Data("{}".utf8), f)
    #expect(throws: ToolCatalog.Refusal("x.json isn't the file the catalog signed (sha256 differs): not taken")) { try ToolCatalog.check(Data("{ }".utf8), f) }
}

/// Its files are the preset's own: `<id>.json` and the scripts it names, its id the entry's.
@Test func anEntrysFilesMakeItsToolWhole() throws {
    let (p, _) = ToolSchema.validate(Data(#"{ "schema": 1, "id": "x", "title": "X", "list": { "script": "x.sh" } }"#.utf8), file: "x.json",
                                     hasScript: { _ in true }, hasSymbol: { _ in true })
    let preset = try #require(p)
    try ToolCatalog.fits(entry("x", 1, files: ["t/x.json", "t/x.sh"]), preset)
    #expect(throws: ToolCatalog.Refusal("x's files aren't the ones it names (x.sh): not taken")) { try ToolCatalog.fits(entry("x", 1), preset) }
    #expect(throws: ToolCatalog.Refusal("x's files aren't the ones it names (y.sh): not taken")) {
        try ToolCatalog.fits(entry("x", 1, files: ["t/x.json", "t/x.sh", "t/y.sh"]), preset)
    }
    #expect(throws: ToolCatalog.Refusal("y.json says it's “x”: not taken")) { try ToolCatalog.fits(entry("y", 1, files: ["t/y.json", "t/x.sh"]), preset) }
}

/// The newest version this Kermo reads; an id from the first source that has it, however new another's is.
@Test func newestReadableFromTheFirstSource() {
    var team = source
    team.url = "https://example.org/team/"
    let picked = ToolCatalog.newest([(source, ToolCatalog.Index(serial: 1, tools: [entry("a", 1), entry("a", 3, minKermo: "9"), entry("a", 2), entry("b", 1)])),
                                     (team, ToolCatalog.Index(serial: 1, tools: [entry("b", 5), entry("c", 1)]))]) { $0.minKermo != "9" }
    #expect(picked.map { "\($0.entry.id) \($0.entry.version) \($0.source.url)" }
            == ["a 2 https://example.com/tools", "b 1 https://example.com/tools", "c 1 https://example.org/team/"])
}

@Test func aSourcesFolderIsHTTPSOrADisk() {
    #expect(source.base?.absoluteString == "https://example.com/tools/")
    #expect(ToolCatalog.Source(name: "", url: "file:///srv/catalog/", key: "").base != nil)
    #expect(ToolCatalog.Source(name: "", url: "http://example.com/", key: "").base == nil)
    #expect(ToolCatalog.Source(name: "", url: "ftp://example.com/", key: "").base == nil)
}

/// An update's question: what it runs now that it didn't (+), what it no longer runs (−), by group; nothing when the same.
@Test func anUpdateSaysOnlyWhatChanges() {
    var old = ToolRuns(itself: [.init(what: "list", how: "ufw status")], chosen: [.init(what: "Delete", how: "ufw delete {n}", root: true)])
    var new = old
    new.chosen.append(.init(what: "Allow", how: "ufw allow {port}", root: true))
    new.itself = [.init(what: "list", how: "ufw status numbered")]
    #expect(ToolRuns.changes(from: old, to: new) == """
        Runs by itself:
        + list: ufw status numbered
        − list: ufw status
        Runs when you choose:
        + Allow: ufw allow {port}   — as root
        """)
    #expect(ToolRuns.changes(from: old, to: old).isEmpty)
    old.background = [.init(what: "stream", how: "the script s.sh (3 lines)")]
    #expect(ToolRuns.changes(from: old, to: new).hasSuffix("In the background, when you watch it — may send notifications:\n− stream: the script s.sh (3 lines)"))
}

@Test func whatCameFromACatalogAsItCame() throws {
    var f = ToolFetched()
    let t = LoadedTool(preset: try #require(ToolLibrary.load(own: nil).tools.first).preset, path: "/x", builtIn: false, scripts: [:], hash: "h1", warnings: [])
    f.tools[t.preset.id] = .init(source: source.url, version: 1, hash: "h1")
    #expect(f.pristine(t))
    var changed = t
    changed.hash = "h2"
    #expect(!f.pristine(changed))
    #expect(try JSONDecoder().decode(ToolFetched.self, from: Data("{}".utf8)) == ToolFetched())
}
