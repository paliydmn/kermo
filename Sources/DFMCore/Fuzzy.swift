import Foundation

public enum Fuzzy {
    /// Case-insensitive subsequence match ("dwn" matches "Downloads"). Higher is better; nil = no match.
    /// Picks the best placement of the query letters (not just the first one found): rewards letters at
    /// word starts (after / space _ - .) and consecutive runs (weighted highest), and prefers shorter candidates. O(query × candidate).
    public static func score(_ query: String, _ candidate: String) -> Int? {
        mayMatch(query, candidate) ? fullScore(query, candidate) : nil
    }

    static func fullScore(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { $0 != " " })
        if q.isEmpty { return 0 }
        let c = Array(candidate.lowercased())
        let n = c.count
        // prev[j] = best score with the previous query letter matched at c[j]
        var prev = [Int?](repeating: nil, count: n)
        for qi in 0..<q.count {
            var cur = [Int?](repeating: nil, count: n)
            var farBest: Int? = nil   // best prev[j] for j <= i-2 (non-adjacent predecessor)
            for i in 0..<n {
                if i >= 2, let p = prev[i - 2] { farBest = max(farBest ?? p, p) }
                guard c[i] == q[qi] else { continue }
                let bonus = 1 + (i == 0 || "/ _-.".contains(c[i - 1]) ? 8 : 0)
                if qi == 0 { cur[i] = bonus; continue }
                var best = farBest
                if i >= 1, let p = prev[i - 1] { best = max(best ?? (p + 10), p + 10) }
                if let best { cur[i] = best + bonus }
            }
            prev = cur
        }
        return prev.compactMap { $0 }.max().map { $0 * 10 - n }
    }

    /// False when a plain-ASCII candidate lacks the query's letters in order, from the bytes alone: no arrays, no
    /// Unicode (most names in a big folder go no further). Anything not ASCII may lowercase into a match (K, the
    /// Kelvin sign, is "k"): true, the full scoring decides.
    static func mayMatch(_ query: String, _ candidate: String) -> Bool {
        func lower(_ b: UInt8) -> UInt8 { b >= 65 && b <= 90 ? b | 0x20 : b }
        var c = candidate.utf8.makeIterator()
        for q in query.utf8 where q != 32 {   // the query's spaces aren't letters to find
            guard q < 0x80 else { return true }
            while true {
                guard let b = c.next() else { return false }
                if b >= 0x80 { return true }
                if lower(b) == lower(q) { break }
            }
        }
        return true
    }
}

/// zoxide-style directory ranking: visit count weighted by how recently it was visited.
public struct Frecency: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var count: Double
        public var last: Double
    }
    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public mutating func visit(_ path: String, now: Double = Date().timeIntervalSince1970) {
        entries[path, default: Entry(count: 0, last: now)].count += 1
        entries[path]!.last = now
        // Age everything once the total gets large, forgetting rarely used dirs (zoxide's scheme).
        if entries.values.reduce(0, { $0 + $1.count }) > 5000 {
            entries = entries.compactMapValues { e in
                let aged = Entry(count: e.count * 0.9, last: e.last)
                return aged.count >= 1 ? aged : nil
            }
        }
    }

    public mutating func remove(_ path: String) { entries[path] = nil }

    /// The folder and everything under it (deleted, moved away).
    public mutating func remove(under dir: String) { entries = entries.filter { !Self.isUnder($0.key, dir) } }

    /// `path` is `dir` or inside it.
    public static func isUnder(_ path: String, _ dir: String) -> Bool { path == dir || path.hasPrefix(dir == "/" ? "/" : dir + "/") }

    /// Gone for good, not just out of reach: no such file (not EACCES, not a timeout), and when it lands on
    /// /Volumes/X (also through a link), X is mounted — an unplugged disk or a dropped share keeps its places.
    public static func isGone(_ path: String) -> Bool {
        var st = stat()
        guard path.hasPrefix("/"), stat(path, &st) != 0, errno == ENOENT else { return false }   // "me@web:/x" is a server's
        let parts = landing(path).split(separator: "/")
        guard parts.count > 1, parts[0] == "Volumes" else { return true }
        var vol = stat(), volumes = stat()
        return stat("/Volumes/" + parts[1], &vol) == 0 && stat("/Volumes", &volumes) == 0 && vol.st_dev != volumes.st_dev
    }

    /// Where `path` points, its links followed as far as they go: a link to a missing place still names it
    /// (realpath gives up there).
    static func landing(_ path: String) -> String {
        var out = "", rest = path.split(separator: "/").map(String.init), hops = 0
        while !rest.isEmpty {
            let next = out + "/" + rest.removeFirst()
            if hops < 40, let to = try? FileManager.default.destinationOfSymbolicLink(atPath: next) {
                hops += 1
                rest = (to.hasPrefix("/") ? to : out + "/" + to).split(separator: "/").map(String.init) + rest
                out = ""
            } else {
                out = next
            }
        }
        return out.isEmpty ? "/" : (out as NSString).standardizingPath
    }

    public func rank(_ path: String, now: Double = Date().timeIntervalSince1970) -> Double {
        guard let e = entries[path] else { return 0 }
        let age = now - e.last
        let weight = age < 3600 ? 4 : age < 86400 ? 2 : age < 604800 ? 0.5 : 0.25
        return e.count * weight
    }

    /// Paths, best first; of two as good, the one visited last.
    public func ranked(now: Double = Date().timeIntervalSince1970) -> [String] {
        entries.keys.sorted { a, b in
            let (x, y) = (rank(a, now: now), rank(b, now: now))
            return x != y ? x > y : entries[a]!.last != entries[b]!.last ? entries[a]!.last > entries[b]!.last : a < b
        }
    }
}
