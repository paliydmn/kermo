import Foundation

/// JSON files in ~/.config/dfilemanager/ (keymap, bookmarks, frecency, user menu) — dotfile-friendly.
enum Config {
    /// Under tests (SwiftPM's and Xcode's runners) a folder of the run's own, next to the tests' files: no test reads the
    /// user's servers or writes their production log, frecency or history — whatever path it forgets to point elsewhere.
    static let dir: String = {
        guard isTestRun else { return (NSHomeDirectory() as NSString).appendingPathComponent(".config/dfilemanager") }
        let tmp = ProcessInfo.processInfo.environment["DFM_TEST_TMP"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return (tmp as NSString).appendingPathComponent("kermo-config-\(getpid())")
    }()

    static let isTestRun = ["swiftpm-testing-helper", "xctest"].contains(ProcessInfo.processInfo.processName)

    static func path(_ name: String) -> String { (dir as NSString).appendingPathComponent(name) }

    /// nil if the file doesn't exist; throws if it exists but can't be read or parsed.
    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        guard let data = try contents(path(name)) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// nil: no such file. One that's there but can't be read (root's after a `sudo` edit, no permission, a link to
    /// nowhere) throws: taken as missing, it was started afresh and saved over.
    static func contents(_ path: String) throws -> Data? {
        if let data = FileManager.default.contents(atPath: path) { return data }
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let fd = open(path, O_RDONLY)
        let why = fd < 0 ? String(cString: strerror(errno)) : "it can't be read"
        if fd >= 0 { close(fd) }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [NSLocalizedDescriptionKey: why])
    }

    /// Files there but unreadable at launch: never saved over this run (the user's file stays as it is).
    nonisolated(unsafe) private static var held = Set<String>()
    private static let heldLock = NSLock()

    /// A file Kermo writes back itself (saved servers, bookmarks, pins, frecency, the Trash log): one it can't read is
    /// copied aside as it was before anything is saved over it; `problem` says so. nil value: no file, or unreadable.
    static func loadKeeping<T: Decodable>(_ name: String, as type: T.Type, in dir: String = dir) -> (value: T?, problem: String?) {
        let path = (dir as NSString).appendingPathComponent(name)
        let read: Data?
        do { read = try contents(path) } catch {
            heldLock.withLock { _ = held.insert(path) }
            return (nil, "\(name) is there but couldn't be read (\(error.localizedDescription)), so it starts empty — and Kermo won't save over it until it's readable again")
        }
        guard let data = read else { return (nil, nil) }
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

    /// Writes to ~/.config (`save`, the production log), one after another and off the main thread: a home on a
    /// network share or a slow disk doesn't stall the app. `flush` waits for them.
    static let writes = DispatchQueue(label: "kermo.config.writes", qos: .utility)
    static func flush() { writes.sync {} }

    /// Owner-only: folder history (frecency) and Trash paths are nobody else's business on a shared Mac. Encoded
    /// here (what it is now), written in `writes`.
    static func save<T: Encodable>(_ name: String, _ value: T, in dir: String = dir) {
        let path = (dir as NSString).appendingPathComponent(name)
        guard !heldLock.withLock({ held.contains(path) }) else { return }   // unreadable at launch: the user's, as it is
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(value) else { return }
        writes.async {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            chmod(dir, 0o700)
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            chmod(path, 0o600)
        }
    }
}
