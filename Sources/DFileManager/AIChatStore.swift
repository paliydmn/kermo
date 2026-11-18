import Foundation
import DFMCore

/// The chats kept on this Mac (task 23 PR 5b): `~/.config/dfilemanager/ai/<id>.json`, owner-only in an owner-only
/// folder, the last 50. Each is written whole (beside it, then renamed, on the disk itself); writes, deletes and the
/// pruning go one after another off the main thread (`Config.writes`, which quitting waits for). Read when the list
/// is opened; a file that isn't the user's alone, a link, a damaged or a newer Kermo's one is left as it is, said.
struct AIChatStore {
    static let keep = 50
    static let maxSize = 64 << 20
    let dir: String

    struct Entry: Equatable { var id: String, title: String, model: String, updated: Date }
    /// Why a file wasn't read, in words.
    struct Unread: Error { var words: String }

    /// The ids of the files there: a UUID each, nothing else.
    private func ids() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let id = String(name.dropLast(5))
            return UUID(uuidString: id) != nil ? id : nil
        }
    }
    private func path(_ id: String) -> String { (dir as NSString).appendingPathComponent(id + ".json") }

    /// The saved chats, the latest first, and those that couldn't be read — in words.
    func list() -> (chats: [Entry], unread: [String]) {
        struct Head: Decodable { var version: Int; var title: String; var model: String }
        var chats: [Entry] = [], unread: [String] = []
        for id in ids() {
            switch data(id) {
            case .failure(let why): unread.append(why.words)
            case .success(let (data, updated)):
                guard let h = try? JSONDecoder().decode(Head.self, from: data) else { unread.append("\(id).json is damaged"); continue }
                guard h.version <= AISavedChat.current else { unread.append("\(id).json is a newer Kermo's"); continue }
                chats.append(Entry(id: id, title: h.title, model: h.model, updated: updated))
            }
        }
        return (chats.sorted { $0.updated > $1.updated }, unread)
    }

    func read(_ id: String) -> Result<AISavedChat, Unread> {
        data(id).flatMap { data, _ in
            guard let c = try? JSONDecoder().decode(AISavedChat.self, from: data) else { return .failure(Unread(words: "\(id).json is damaged")) }
            return c.version <= AISavedChat.current ? .success(c) : .failure(Unread(words: "\(id).json is a newer Kermo's"))
        }
    }

    /// The file's bytes and date: only a regular file, not through a link, the user's own and nobody else's to read.
    private func data(_ id: String) -> Result<(Data, Date), Unread> {
        let fd = open(path(id), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(Unread(words: "\(id).json: \(errno == ELOOP ? "a link" : String(cString: strerror(errno)))")) }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return .failure(Unread(words: "\(id).json isn't a file")) }
        guard st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { return .failure(Unread(words: "\(id).json isn't yours alone (it should be 0600)")) }
        guard st.st_size <= Self.maxSize else { return .failure(Unread(words: "\(id).json is over \(Self.maxSize >> 20) MB")) }
        guard let data = try? h.readToEnd() else { return .failure(Unread(words: "\(id).json couldn't be read")) }
        return .success((data, Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))))
    }

    /// Written in turn; `failed` hears why not, on the main thread. Over the 50, the oldest readable ones go — never
    /// this one, never one that can't be read.
    @MainActor func save(_ id: String, _ chat: AISavedChat, failed: @escaping @MainActor (String) -> Void) {
        let data: Data
        do { data = try JSONEncoder().encode(chat) } catch { return failed(error.localizedDescription) }
        Config.writes.async {
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                chmod(dir, 0o700)   // a folder already there keeps its mode otherwise
                try FileInfo.writeWhole(data, to: path(id), durable: true)
                FileInfo.syncFolder(dir)
            } catch {
                let why = error.localizedDescription
                return DispatchQueue.main.async { MainActor.assumeIsolated { failed(why) } }
            }
            guard ids().count > Self.keep else { return }
            remove(list().chats.dropFirst(Self.keep).map(\.id).filter { $0 != id })
        }
    }

    /// For good: the file (and a write's leftover), not to the Trash.
    func delete(_ ids: [String]) { Config.writes.async { remove(ids) } }

    private func remove(_ ids: [String]) {
        for id in ids {
            unlink(path(id))
            unlink(path(id) + ".tmp")
        }
        FileInfo.syncFolder(dir)
    }
}
