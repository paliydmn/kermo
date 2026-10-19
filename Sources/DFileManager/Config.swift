import Foundation

/// JSON files in ~/.config/dfilemanager/ (keymap, bookmarks, frecency, user menu) — dotfile-friendly.
enum Config {
    static let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".config/dfilemanager")

    static func path(_ name: String) -> String { (dir as NSString).appendingPathComponent(name) }

    /// nil if the file doesn't exist; throws if it exists but can't be parsed.
    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        guard let data = FileManager.default.contents(atPath: path(name)) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A file Kermo writes back itself (saved servers, bookmarks, pins, frecency, the Trash log): one it can't read is
    /// copied aside as it was before anything is saved over it; `problem` says so. nil value: no file, or unreadable.
    static func loadKeeping<T: Decodable>(_ name: String, as type: T.Type, in dir: String = dir) -> (value: T?, problem: String?) {
        let path = (dir as NSString).appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: path) else { return (nil, nil) }
        do { return (try JSONDecoder().decode(T.self, from: data), nil) } catch {
            let why = ((error as? DecodingError).flatMap {
                guard case .dataCorrupted(let c) = $0 else { return nil }
                return (c.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            }) ?? error.localizedDescription
            return (nil, "\(name) couldn't be read (\(why)), so it starts empty" + keepAside(data, path))
        }
    }

    /// A list of entries, each read on its own: a broken one (`"port": "22"`) is left out, not all of them.
    static func loadEach<T: Decodable>(_ name: String, as type: T.Type, in dir: String = dir) -> (value: [T], problem: String?) {
        let (all, problem) = loadKeeping(name, as: [Each<T>].self, in: dir)
        let good = (all ?? []).compactMap(\.value)
        guard let all, good.count < all.count else { return (good, problem) }
        let path = (dir as NSString).appendingPathComponent(name)
        let bad = all.count - good.count
        return (good, "\(name): \(bad == 1 ? "an entry" : "\(bad) entries") of \(all.count) couldn't be read and \(bad == 1 ? "is" : "are") left out"
                    + keepAside(FileManager.default.contents(atPath: path) ?? Data(), path))
    }

    private struct Each<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    /// Copies `data`, the file as it was, to "name.broken" — or, when one with something else in it is there, to
    /// "name.broken-<date>": the earlier one may be the only copy of something else. The same again (each launch
    /// until the file is fixed or saved) is not copied twice. Returns the words that say where.
    private static func keepAside(_ data: Data, _ path: String) -> String {
        var kept = path + ".broken"
        if let there = FileManager.default.contents(atPath: kept), there != data {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            kept += "-" + f.string(from: Date())
        }
        guard FileManager.default.contents(atPath: kept) == data
                || FileManager.default.createFile(atPath: kept, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return " — and couldn't be copied aside: Kermo's next save of it replaces it"
        }
        return " — the file as it was is kept as \((kept as NSString).lastPathComponent)"
    }

    /// What the state files read at launch couldn't: said once, with the config problems.
    @MainActor static var unreadable: [String] = []

    @MainActor static func noting<T>(_ loaded: (value: T, problem: String?)) -> T {
        if let p = loaded.problem { unreadable.append(p) }
        return loaded.value
    }

    /// Owner-only: folder history (frecency) and Trash paths are nobody else's business on a shared Mac.
    static func save<T: Encodable>(_ name: String, _ value: T) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? enc.encode(value).write(to: URL(fileURLWithPath: path(name)), options: .atomic)
        chmod(path(name), 0o600)
    }
}
