import Foundation
import Testing
@testable import DFMCore

// The editor's drafts between launches (`DraftStore`): every test has a folder of its own in the temp folder, never
// ~/.config.

private func tempDir() -> String {
    (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-drafts-" + UUID().uuidString
}

private func clean(_ dir: String) {
    chmod(dir + "/rev", 0o700)
    try? FileManager.default.removeItem(atPath: dir)
}

private func untitled(_ n: Int, dirty: Bool = true) -> EditorSession.Doc {
    var d = EditorSession.Doc(kind: .untitled)
    d.number = n
    d.dirty = dirty
    return d
}

/// Opens `dir` again once `s` has written everything, as the next launch would.
private func reopen(_ s: DraftStore) async throws -> (store: DraftStore, session: EditorSession, damaged: String?) {
    try await s.flush()
    s.release()
    return try DraftStore.open(s.dir)
}

/// Waits here (a test may: the store's queue is what's held up).
private func block(_ s: DispatchSemaphore) { s.wait() }

private func revisions(_ dir: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir + "/rev")) ?? []).sorted() }

/// Changed documents come back with their text and everything a save needs; unchanged ones without a text kept.
@Test func draftsComeBackAfterALaunch() async throws {
    let dir = tempDir()
    defer { clean(dir) }
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])   // made by hand
    let (store, empty, damaged) = try DraftStore.open(dir)
    #expect(empty == EditorSession() && damaged == nil)

    var note = untitled(1)
    var conf = EditorSession.Doc(kind: .server)
    conf.server = .init(SFTPTarget(host: "me@web-01", port: 2222), root: true, path: "/etc/nginx/nginx.conf")
    conf.baseline = .init(attrs: SFTPClient.Attrs(kind: .file, size: 1043, mtime: 1_762_250_000, mode: 0o644, uid: 0, gid: 0, sha256: Data([1, 2, 3])))
    conf.format.crlf = true
    conf.format.finalNewline = true
    conf.dirty = true
    conf.unsent = true
    var hosts = EditorSession.Doc(kind: .local)
    hosts.path = "/etc/hosts"
    hosts.baseline = .init(stamp: .init(dev: 16_777_231, ino: 812_345, size: 99, sec: 1_762_250_000, nsec: 5), digest: Data(repeating: 7, count: 32))
    hosts.format.encoding = String.Encoding.windowsCP1251.rawValue
    var s = EditorSession()
    s.docs = [note, conf, hosts]
    s.active = conf.id
    s.windowOpen = true
    store.submit(s, texts: [note.id: "TODO ✓ — привіт\n", conf.id: "server {\r\n}\r\n", hosts.id: "never written: unchanged"], durable: true)   // as closing the window: synced, the folder too

    let (again, back, _) = try await reopen(store)
    #expect(back.seq == 1 && back.active == conf.id && back.windowOpen)
    #expect(back.docs.map(\.id) == [note.id, conf.id, hosts.id], "tab order")
    #expect(back.docs[1].server == conf.server && back.docs[1].baseline == conf.baseline && back.docs[1].format == conf.format && back.docs[1].unsent)
    #expect(back.docs[2].baseline == hosts.baseline && back.docs[2].format.encoding == String.Encoding.windowsCP1251.rawValue)
    #expect(try again.text(of: back.docs[0]) == "TODO ✓ — привіт\n")
    #expect(try again.text(of: back.docs[1]) == "server {\r\n}\r\n", "line ends as given")
    #expect(try back.docs[2].revision == nil && again.text(of: back.docs[2]) == nil, "an unchanged file keeps no copy")
    #expect(revisions(dir).count == 2)

    // A commit without their texts (only the scroll moved — to NaN, which JSON can't say): the same texts stay.
    var scrolled = back
    scrolled.docs[0].scroll = .nan
    again.submit(scrolled)
    try await again.flush()
    #expect(try revisions(dir).count == 2 && again.text(of: back.docs[0]) == "TODO ✓ — привіт\n")

    // Saved: no text kept, its revision goes.
    note = back.docs[0]
    note.dirty = false
    again.submit(EditorSession(with: [note]))
    let (_, saved, _) = try await reopen(again)
    #expect(saved.docs.count == 1 && saved.docs[0].revision == nil && revisions(dir).isEmpty)

    // Only the owner gets in: the folder and every file.
    for (p, mode) in [(dir, 0o700), (dir + "/rev", 0o700), (dir + "/session.json", 0o600), (dir + "/lock", 0o600)] {
        #expect(try FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? Int == mode, "\(p)")
    }
    #expect(try URL(fileURLWithPath: dir).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
}

/// A crash after the new revisions, before the manifest names them: the session before it, whole; the leftovers go.
@Test func aCrashBeforeTheManifestKeepsTheSessionBefore() async throws {
    let dir = tempDir()
    defer { clean(dir) }
    let (store, _, _) = try DraftStore.open(dir)
    let a = untitled(1)
    store.submit(EditorSession(with: [a]), texts: [a.id: "first"])
    try await store.flush()

    struct Crash: Error {}
    store.afterRevisions = { throw Crash() }
    let b = untitled(2)
    store.submit(EditorSession(with: [a, b]), texts: [a.id: "second", b.id: "new"])
    await #expect(throws: Crash.self) { try await store.flush() }
    #expect(revisions(store.dir).count == 3, "the crash's revisions are on disk")

    store.release()
    let (again, back, _) = try DraftStore.open(store.dir)
    #expect(try back.docs.map(\.id) == [a.id] && again.text(of: back.docs[0]) == "first")
    #expect(revisions(store.dir) == ["\(a.id.uuidString).1"], "the next launch sweeps what no manifest names")
}

/// Don't Save is for good: once its commit is through, the document doesn't come back.
@Test func aDiscardedDraftStaysDiscarded() async throws {
    let dir = tempDir()
    defer { clean(dir) }
    let (store, _, _) = try DraftStore.open(dir)
    let a = untitled(1), b = untitled(2)
    store.submit(EditorSession(with: [a, b]), texts: [a.id: "keep", b.id: "discard me"])
    try await store.flush()
    #expect(revisions(dir).contains { $0.hasPrefix(b.id.uuidString) })
    store.submit(EditorSession(with: [a]))
    let (again, back, _) = try await reopen(store)
    #expect(try back.docs.map(\.id) == [a.id] && again.text(of: back.docs[0]) == "keep")
    #expect(!revisions(store.dir).contains { $0.hasPrefix(b.id.uuidString) })
}

/// Commits one after another: one still waiting gives way to a newer one but keeps its texts; an old one never wins.
@Test func theNewestCommitWins() async throws {
    let dir = tempDir()
    defer { clean(dir) }
    let (store, _, _) = try DraftStore.open(dir)
    let a = untitled(1), b = untitled(2)
    let first = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
    store.afterRevisions = { first.signal(); go.wait() }
    store.submit(EditorSession(with: [a, b]), texts: [a.id: "a1", b.id: "b1"])
    block(first)   // the first commit is under way
    store.afterRevisions = {}
    store.submit(EditorSession(with: [a, b]), texts: [b.id: "b2"])
    store.submit(EditorSession(with: [a, b]), texts: [a.id: "a3"])
    go.signal()
    let (again, back, _) = try await reopen(store)
    #expect(back.seq == 2, "the two waiting were one commit")
    #expect(try again.text(of: back.docs[0]) == "a3")
    #expect(try again.text(of: back.docs[1]) == "b2", "the replaced commit's text wasn't lost")
}

/// Nowhere to write: the commit says so, the last good session stays, and its texts go with the next commit.
@Test func aFailedWriteKeepsTheLastGoodSession() async throws {
    let dir = tempDir()
    defer { clean(dir) }
    let (store, _, _) = try DraftStore.open(dir)
    let a = untitled(1)
    store.submit(EditorSession(with: [a]), texts: [a.id: "good"])
    try await store.flush()
    chmod(store.dir + "/rev", 0o500)
    defer { chmod(store.dir + "/rev", 0o700) }
    store.submit(EditorSession(with: [a]), texts: [a.id: "newer"])
    await #expect(throws: (any Error).self) { try await store.flush() }
    let onDisk = try JSONDecoder().decode(EditorSession.self, from: Data(contentsOf: URL(fileURLWithPath: store.dir + "/session.json")))
    #expect(try onDisk.seq == 1 && store.text(of: onDisk.docs[0]) == "good")

    chmod(store.dir + "/rev", 0o700)
    store.submit(EditorSession(with: [a]))   // no text given: the failed one's goes
    let (again, back, _) = try await reopen(store)
    #expect(try again.text(of: back.docs[0]) == "newer")
}

/// A manifest that can't be read is moved aside with every revision — nothing deleted — and the editor starts empty.
@Test func aDamagedManifestIsKeptAside() async throws {
    let dir = tempDir()
    defer { clean(dir) }
    let (store, _, _) = try DraftStore.open(dir)
    let a = untitled(1)
    store.submit(EditorSession(with: [a]), texts: [a.id: "precious"])
    try await store.flush()
    store.release()
    try Data("{ not json".utf8).write(to: URL(fileURLWithPath: store.dir + "/session.json"))

    let (_, session, damaged) = try DraftStore.open(store.dir)
    #expect(session == EditorSession())
    let aside = try #require(damaged)
    #expect(aside.hasPrefix(store.dir + "/damaged/"))
    #expect(try String(contentsOfFile: aside + "/session.json", encoding: .utf8) == "{ not json")
    #expect(try String(contentsOfFile: aside + "/rev/\(a.id.uuidString).1", encoding: .utf8) == "precious")
    #expect(revisions(store.dir).isEmpty)
}

/// A newer Kermo's session is left as it is; a second process gets no drafts at all.
@Test func aNewerOrBusyStoreIsLeftAlone() async throws {
    let dir = tempDir()
    defer { clean(dir) }
    let (store, _, _) = try DraftStore.open(dir)
    #expect(throws: DraftStore.Failure.locked) { try DraftStore.open(dir) }
    store.release()

    let newer = Data(#"{"version":2,"docs":"another shape"}"#.utf8)
    try newer.write(to: URL(fileURLWithPath: dir + "/session.json"))
    #expect(throws: DraftStore.Failure.newer(2)) { try DraftStore.open(dir) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: dir + "/session.json")) == newer)
    #expect(!FileManager.default.fileExists(atPath: dir + "/damaged"))
    unlink(dir + "/session.json")
    _ = try DraftStore.open(dir).store   // the refused open let go of the lock
}

/// A revision that isn't what the manifest says is no text: it goes to damaged/, a missing one says so.
@Test func aChangedRevisionIsDamaged() async throws {
    let dir = tempDir()
    defer { clean(dir) }
    let (store, _, _) = try DraftStore.open(dir)
    let a = untitled(1), b = untitled(2)
    store.submit(EditorSession(with: [a, b]), texts: [a.id: "twelve bytes", b.id: "gone"])
    let (again, back, _) = try await reopen(store)
    let rev = again.dir + "/rev/\(a.id.uuidString).1"
    try Data("twelve bytez".utf8).write(to: URL(fileURLWithPath: rev))   // same length, other bytes
    unlink(again.dir + "/rev/\(b.id.uuidString).1")

    var moved: String?
    #expect { _ = try again.text(of: back.docs[0]) } throws: { e in
        guard case .damaged(let to)? = e as? DraftStore.Failure else { return false }
        moved = to
        return to != nil
    }
    #expect(try String(contentsOfFile: try #require(moved) + "/\(a.id.uuidString).1", encoding: .utf8) == "twelve bytez")
    #expect(!FileManager.default.fileExists(atPath: rev))
    #expect(throws: DraftStore.Failure.damaged(nil)) { try again.text(of: back.docs[1]) }
}

/// A file's mode goes with its stamp (a draft of a deleted 0600 file brings it back 0600); a manifest from before it
/// had none still reads.
@Test func aStampKeepsTheModeAndOldManifestsStillRead() throws {
    let stamp = EditorSession.Stamp(dev: 1, ino: 2, size: 3, sec: 4, nsec: 5, mode: 0o600)
    #expect(try JSONDecoder().decode(EditorSession.Stamp.self, from: JSONEncoder().encode(stamp)) == stamp)
    let old = try JSONDecoder().decode(EditorSession.Stamp.self, from: Data(#"{"dev":1,"ino":2,"size":3,"sec":4,"nsec":5}"#.utf8))
    #expect(old.mode == nil && old.ino == 2)
}

/// A big text is committed less often: each commit writes all of it.
@Test func bigTextsWaitLonger() {
    #expect(DraftStore.delay(forBytes: 0) == (0.5, 2) && DraftStore.delay(forBytes: 1 << 20) == (0.5, 2))
    #expect(DraftStore.delay(forBytes: (1 << 20) + 1) == (2, 10) && DraftStore.delay(forBytes: 8 << 20) == (2, 10))
    #expect(DraftStore.delay(forBytes: 32 << 20) == (5, 30))
}

private extension EditorSession {
    init(with docs: [Doc]) {
        self.init()
        self.docs = docs
    }
}
