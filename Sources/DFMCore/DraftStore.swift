import CryptoKit
import Foundation

/// The built-in editor's open documents, kept between launches: what `DraftStore` writes to `session.json`. In tab
/// order; a document with changes has its text in a revision file, an unchanged one is read again from where it lives.
/// A field added later must be optional (or `current` goes up, with a migration): a manifest without it would no longer
/// decode, and its drafts would go to `damaged/`.
public struct EditorSession: Codable, Sendable, Equatable {
    public static let current = 1
    public var version = current
    /// The store numbers its commits.
    public internal(set) var seq = 0
    /// The editor window was showing: it shows again at launch.
    public var windowOpen = false
    public var active: UUID?
    public var docs: [Doc] = []

    public init() {}

    public struct Doc: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case untitled, local, server }
        /// Stays the same through Save As and launches.
        public var id: UUID
        public var kind: Kind
        /// An untitled one's: "Untitled 3".
        public var number: Int?
        /// A local file's, as opened.
        public var path: String?
        public var server: Server?
        public var baseline: Baseline?
        public var format: Format
        /// Saved here, but not where it lives (a server).
        public var unsent = false
        /// Has changes its file doesn't: its text is kept (`revision`, which the store fills in).
        public var dirty = false
        public internal(set) var revision: Revision?
        public var selection: [Int]?
        public var scroll: Double?

        public init(id: UUID = UUID(), kind: Kind, format: Format = Format()) {
            self.id = id
            self.kind = kind
            self.format = format
        }
    }

    /// A server's file: `root` apart, as `SFTPTarget` never decodes its sudo.
    public struct Server: Codable, Sendable, Equatable {
        public var target: SFTPTarget, root: Bool, path: String
        public init(_ target: SFTPTarget, root: Bool, path: String) { (self.target, self.root, self.path) = (target, root, path) }
    }

    /// What a save checks the file against: a local one's stat and SHA-256, a server's attributes.
    public struct Baseline: Codable, Sendable, Equatable {
        public var stamp: Stamp?, digest: Data?, attrs: SFTPClient.Attrs?
        public init(stamp: Stamp? = nil, digest: Data? = nil, attrs: SFTPClient.Attrs? = nil) { (self.stamp, self.digest, self.attrs) = (stamp, digest, attrs) }
    }

    /// `mode`: its permissions, which a file deleted meanwhile comes back with (none in a manifest from before it).
    public struct Stamp: Codable, Sendable, Equatable {
        public var dev: Int32, ino: UInt64, size: Int64, sec: Int, nsec: Int
        public var mode: UInt16?
        public init(dev: Int32, ino: UInt64, size: Int64, sec: Int, nsec: Int, mode: UInt16? = nil) {
            (self.dev, self.ino, self.size, self.sec, self.nsec, self.mode) = (dev, ino, size, sec, nsec, mode)
        }
    }

    /// How the text goes back into bytes. `encoding`: a `String.Encoding` raw value.
    public struct Format: Codable, Sendable, Equatable {
        public var encoding = String.Encoding.utf8.rawValue
        public var lossy = false, bom = false, crlf = false, encodingAsked = false, finalNewline = false
        public init() {}
    }

    /// `rev/<doc id>.<n>`: UTF-8, `length` bytes with that SHA-256.
    public struct Revision: Codable, Sendable, Equatable {
        public let n: Int, length: Int, sha256: Data
    }
}

/// Where `EditorSession` lives (`editor.noindex`): `session.json`, the texts of changed documents in `rev/`, and in
/// `damaged/` what couldn't be read — moved there, never deleted. Drafts may hold secrets: folders 0700, files 0600,
/// out of Time Machine. One process at a time (`flock` on `lock`): a second Kermo gets `.locked` and works without drafts.
///
/// A commit writes the new revisions first, then the manifest naming them, each as a temp file renamed into place:
/// a crash in between leaves the previous session whole, and the revisions it left go at the next launch. Commits run one after
/// another off the main thread; one still waiting is replaced by a newer one, keeping its texts.
public final class DraftStore: @unchecked Sendable {   // `lock` guards what's waiting; `queue` does the writing
    public enum Failure: Error, Equatable {
        /// Another process keeps the drafts.
        case locked
        /// Written by a newer Kermo: left as it is.
        case newer(Int)
        /// A revision isn't what the manifest says: moved to that folder (nil: it was gone).
        case damaged(String?)
    }

    public let dir: String
    private var lockFD: Int32
    /// The session as on disk. The queue's, once open.
    private var last: EditorSession
    private let queue = DispatchQueue(label: "dfm.drafts")
    private let lock = NSLock()
    private var next: (session: EditorSession, durable: Bool)?
    private var texts: [UUID: String] = [:]   // not yet in a revision
    private var submitted = 0, done = 0, running = false
    private var failure: Error?
    private var waiting: [(Int, CheckedContinuation<Void, Error>)] = []
    /// Tests: runs once the revisions are in place, before the manifest names them (a crash there).
    var afterRevisions: () throws -> Void = {}

    private init(_ dir: String, _ fd: Int32, _ session: EditorSession) { (self.dir, lockFD, last) = (dir, fd, session) }
    deinit { release() }

    /// Takes `dir` (made if missing) and reads its session; `damaged`: the folder an unreadable one was moved to.
    public static func open(_ dir: String) throws -> (store: DraftStore, session: EditorSession, damaged: String?) {
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/rev", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)   // a folder already there keeps its mode otherwise
        chmod(dir + "/rev", 0o700)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        var url = URL(fileURLWithPath: dir)
        try? url.setResourceValues(v)   // every time: a folder made by hand would go to Time Machine
        let fd = Darwin.open(dir + "/lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let e = errno
            close(fd)
            throw e == EWOULDBLOCK ? Failure.locked : posix(e)
        }
        var session = EditorSession(), damaged: String?
        do {
            let data: Data?
            do { data = try Data(contentsOf: URL(fileURLWithPath: dir + "/session.json")) } catch CocoaError.fileReadNoSuchFile { data = nil }
            if let data {
                struct Head: Decodable { let version: Int }
                if let v = try? JSONDecoder().decode(Head.self, from: data).version, v > EditorSession.current { throw Failure.newer(v) }
                do { session = try JSONDecoder().decode(EditorSession.self, from: data) } catch {
                    damaged = try moveAside(["session.json", "rev"], in: dir)
                    try fm.createDirectory(atPath: dir + "/rev", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                }
            }
        } catch {
            close(fd)
            throw error
        }
        let store = DraftStore(dir, fd, session)
        store.sweep()
        return (store, session, damaged)
    }

    /// Queues a commit of `session` with these documents' new texts (only the changed ones need be here) and returns:
    /// call it from one thread, in order. `durable`: on the disk itself, not only in the system's cache — for closing the
    /// window and quitting.
    public func submit(_ session: EditorSession, texts new: [UUID: String] = [:], durable: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        submitted += 1
        texts.merge(new) { $1 }
        next = (session, durable || next?.durable == true)
        if !running {
            running = true
            queue.async { self.drain() }
        }
    }

    /// Waits for what's been submitted so far; throws why its commit failed. The texts of a failed commit stay
    /// waiting for the next one.
    public func flush() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            defer { lock.unlock() }
            if done < submitted { waiting.append((submitted, c)) } else if let failure { c.resume(throwing: failure) } else { c.resume() }
        }
    }

    /// A document's kept text; nil if it has none. A revision that isn't what the manifest says goes to `damaged/`.
    /// For a session as on disk: a later commit's sweep takes the revisions it no longer names.
    public func text(of doc: EditorSession.Doc) throws -> String? {
        guard let r = doc.revision else { return nil }
        let name = "rev/\(doc.id.uuidString).\(r.n)"
        if let data = FileManager.default.contents(atPath: dir + "/" + name), data.count == r.length,
           Data(SHA256.hash(data: data)) == r.sha256, let text = String(data: data, encoding: .utf8) {
            return text
        }
        throw Failure.damaged(FileManager.default.fileExists(atPath: dir + "/" + name) ? try Self.moveAside([name], in: dir) : nil)
    }

    /// How long after an edit to commit — the whole text each time, so a big one less often, sparing the disk:
    /// `pause` after the last key, `most` while typing on.
    public static func delay(forBytes n: Int) -> (pause: Double, most: Double) {
        n <= 1 << 20 ? (0.5, 2) : n <= 8 << 20 ? (2, 10) : (5, 30)
    }

    /// Lets go of the lock (tests: to open the folder again, after `flush`).
    func release() {
        lock.lock()
        defer { lock.unlock() }
        if lockFD >= 0 { close(lockFD) }
        lockFD = -1
    }

    private func drain() {
        while true {
            lock.lock()
            guard let (session, durable) = next else {
                running = false
                lock.unlock()
                return
            }
            let (ticket, mine) = (submitted, texts)
            (next, texts) = (nil, [:])
            lock.unlock()
            var error: Error?
            do { try commit(session, mine, durable: durable) } catch let e { error = e }
            lock.lock()
            if error != nil { texts = mine.merging(texts) { $1 } }
            (done, failure) = (ticket, error)
            waiting.removeAll { t, c in
                guard t <= ticket else { return false }
                if let error { c.resume(throwing: error) } else { c.resume() }
                return true
            }
            lock.unlock()
        }
    }

    private func commit(_ s: EditorSession, _ texts: [UUID: String], durable: Bool) throws {
        var s = s
        s.version = EditorSession.current
        s.seq = last.seq + 1
        let kept = Dictionary(last.docs.compactMap { d in d.revision.map { (d.id, $0) } }) { a, _ in a }
        for i in s.docs.indices {
            let id = s.docs[i].id
            if s.docs[i].scroll?.isFinite == false { s.docs[i].scroll = nil }   // JSONEncoder throws on NaN: no commit would go
            if !s.docs[i].dirty {
                s.docs[i].revision = nil
            } else if let text = texts[id] {
                let data = Data(text.utf8)
                try put(data, "rev/\(id.uuidString).\(s.seq)", durable)
                s.docs[i].revision = .init(n: s.seq, length: data.count, sha256: Data(SHA256.hash(data: data)))
            } else {
                s.docs[i].revision = kept[id]
            }
        }
        try afterRevisions()
        try put(JSONEncoder().encode(s), "session.json", durable)
        if durable { FileInfo.syncFolder(dir) }   // the renames too
        last = s
        sweep()
    }

    /// Revisions the session doesn't name: older ones, discarded documents', a crash's. Ones it can't delete wait
    /// for the next commit.
    private func sweep() {
        let keep = Set(last.docs.compactMap { d in d.revision.map { "\(d.id.uuidString).\($0.n)" } })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir + "/rev")) ?? [] where !keep.contains(name) {
            unlink(dir + "/rev/" + name)
        }
    }

    private func put(_ data: Data, _ name: String, _ durable: Bool) throws {
        let path = dir + "/" + name, tmp = path + ".tmp"
        let fd = Darwin.open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix() }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try h.write(contentsOf: data)
        if durable, fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }   // a RAM disk has no F_FULLFSYNC
        try h.close()
        guard rename(tmp, path) == 0 else { throw posix() }
    }

    /// Moves `names` (in `dir`) to a new `damaged/<time>-<id>` and returns it.
    private static func moveAside(_ names: [String], in dir: String) throws -> String {
        let fm = FileManager.default
        let to = dir + "/damaged/" + ServerHistory.stamp(Date()) + "-" + UUID().uuidString.prefix(8)
        try fm.createDirectory(atPath: to, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in names where fm.fileExists(atPath: dir + "/" + name) {
            try fm.moveItem(atPath: dir + "/" + name, toPath: to + "/" + (name as NSString).lastPathComponent)
        }
        return to
    }
}

private func posix(_ e: Int32 = errno) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO) }
