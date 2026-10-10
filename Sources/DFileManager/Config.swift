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
