import Foundation

/// Folder sizes on a server by its own `du` (Space / ⌥Space on a server panel): one command over the connection instead
/// of an SFTP walk of every folder. `du -slbx`: GNU and busybox both know it — apparent bytes (`-b`), each hard link
/// counted (`-l`) and nothing past the folder's file system (`-x`), as the walk counts. BSD's du has no `-b`: then the walk.
public enum ServerSizes {
    public struct Size: Equatable, Sendable {
        public var bytes: Int64
        /// du couldn't read all of it: at least this much.
        public var partial = false
        public init(bytes: Int64, partial: Bool = false) { (self.bytes, self.partial) = (bytes, partial) }
    }

    /// The line the script prints before du's own: whatever a login script printed comes before it.
    static let marker = "kermo-sizes"

    /// du's answer for `names` (each an argument, as given): a line "<bytes>\t<name>" for each it could look at — stdout
    /// is read whatever the exit status, as du prints what it could and exits 1. A name with no line has no size (gone
    /// meanwhile). Exit 1: the names its `du:` lines on stderr point into are partial; a line that points nowhere among
    /// them (a name du quotes its own way) makes them all partial — "at least" is true either way.
    static func parse(_ output: String, errors: String, status: Int32, names: [String]) -> [String: Size] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let at = lines.firstIndex(of: Substring(marker)) else { return [:] }
        let wanted = Set(names)
        var out: [String: Size] = [:]
        for line in lines[(at + 1)...] {
            guard let tab = line.firstIndex(of: "\t"), let bytes = Int64(line[..<tab]), bytes >= 0 else { continue }
            let name = String(line[line.index(after: tab)...])
            if wanted.contains(name) { out[name] = Size(bytes: bytes) }
        }
        guard status != 0 else { return out }
        var partial = Set<String>(), all = false
        for line in errors.split(whereSeparator: \.isNewline) where line.hasPrefix("du: ") {
            // "du: cannot read directory 'b/locked': Permission denied" (GNU), "du: can't open 'b/locked': …" (busybox)
            guard let q = line.range(of: " '") else { all = true; continue }   // not the one in "can't"
            let name = String(line[q.upperBound...].prefix { $0 != "/" && $0 != "'" })
            if wanted.contains(name) { partial.insert(name) } else { all = true }
        }
        for name in out.keys where all || partial.contains(name) { out[name]!.partial = true }
        return out
    }
}
