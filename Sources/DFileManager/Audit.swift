import DFMCore
import Foundation

/// What Kermo did on production servers (`SavedServer.prod`): a JSON line each in ~/.config/dfilemanager/audit.jsonl,
/// for `grep` and `jq` — saves, reverts, commands, copies, moves, deletes, renames, syncs, reloads: where the production
/// question is asked. A command line may hold a secret (`mysql -p…`): the file is owner-only. `defaults write
/// com.dmn.dfilemanager auditLog -bool false` stops it.
@MainActor enum AuditLog {
    /// Tests: a file of their own.
    static var path = Config.path("audit.jsonl")
    /// Hears why a line couldn't be written: once, until one is again (the app's status line).
    static var failed: (@MainActor (String) -> Void)?
    private static var failing = false

    struct Entry: Encodable {
        var time: String, server: String, root: Bool?, action: String, paths: [String], to: String?, command: String?, exit: Int32?, error: String?
    }

    /// A line for `action` on `t`, if it's a production server. `exit`: 0 done, else failed (`error` says how); nil: not
    /// known (handed to the terminal app).
    static func write(_ t: SFTPTarget, _ action: String, paths: [String], to: String? = nil, command: String? = nil, exit: Int32?, error: String? = nil) {
        guard UserDefaults.standard.object(forKey: "auditLog") as? Bool ?? true, SavedServer.isProd(t) else { return }
        let time = ISO8601DateFormatter()
        time.timeZone = .current
        let entry = Entry(time: time.string(from: Date()), server: t.host + (t.port.map { ":\($0)" } ?? ""), root: t.sudo ? true : nil,
                          action: action, paths: paths, to: to, command: command, exit: exit, error: error)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0a)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var error = fd < 0 ? String(cString: strerror(errno)) : nil
        if fd >= 0 {
            fchmod(fd, 0o600)   // made looser by hand: owner-only again
            if line.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) != line.count { error = String(cString: strerror(errno)) }
            close(fd)
        }
        if let error, !failing { failed?("Production log not written (\((path as NSString).abbreviatingWithTildeInPath)): \(error)") }
        failing = error != nil
    }

    /// A finished copy, move or delete (F5, F6, F8, Synchronize): a line for each production server it changed files on
    /// (one for a move within a server). Synchronize's copies name each file's two places, the server's among them.
    /// Where a job's items went: its folder, or for one item under a new name (Copy Here As, F5 to a name) that
    /// name's path; nil for a delete.
    static func destination(_ job: FileJob) -> String? {
        guard job.kind != .delete, let dir = job.destDir else { return nil }
        return job.targetName.map { (dir as NSString).appendingPathComponent($0) } ?? dir
    }

    static func write(_ job: FileJob, sync: Bool) {
        let kind = switch job.kind { case .copy: "copy"; case .move: "move"; case .delete: "delete"; case .trash: "trash" }
        let p = job.progress, ok = p.state == .done && p.errors.isEmpty
        let error = p.state == .cancelled ? "cancelled" : p.errors.isEmpty ? nil : p.errors.prefix(5).joined(separator: "\n")
        let paths = job.pairs.isEmpty ? job.sources : job.pairs.map { "\($0.src) → \($0.dst)" }
        let to = destination(job)
        var done: [SFTPTarget] = []
        for t in AppDelegate.changed(from: job.from, to: job.to, move: job.kind == .move) where !done.contains(t) {
            done.append(t)
            write(t, (sync ? "sync " : "") + kind, paths: paths, to: to, exit: ok ? 0 : 1, error: ok ? nil : error)
        }
    }
}
