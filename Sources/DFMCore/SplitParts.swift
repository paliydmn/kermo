import Foundation

/// Parts written by Split File (`split -d -a 3`): "name.000", "name.001", … (".001"-first sets from other tools too).
public enum SplitParts {
    /// "name.007" → ("name", 7); nil for anything else.
    public static func part(_ n: String) -> (base: String, number: Int)? {
        let ext = (n as NSString).pathExtension
        guard ext.utf8.count == 3, ext.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let i = Int(ext) else { return nil }
        return ((n as NSString).deletingPathExtension, i)
    }

    /// The original name and all parts in order, from any one part's name and the names in its folder.
    /// nil if `name` isn't a part or the numbering has a gap (a part is missing).
    public static func sequence(for name: String, in names: [String]) -> (base: String, parts: [String])? {
        guard let base = part(name)?.base, !base.isEmpty else { return nil }
        let numbers = names.compactMap { n in part(n).flatMap { $0.base == base ? $0.number : nil } }.sorted()
        guard let first = numbers.first, first <= 1, numbers == Array(first..<first + numbers.count) else { return nil }
        return (base, numbers.map { base + "." + String(format: "%03d", $0) })
    }

    /// Parts of `name` among `names` (any number, not only .000), in order: Split refuses to write over them.
    public static func parts(of name: String, in names: [String]) -> [String] {
        names.filter { part($0)?.base == name }.sorted()
    }

    /// The first part that doesn't fit the set: one before the last of another size than the first part, or a last
    /// one bigger than it. Parts of two splits (by 1G, then by 2G over them) number on without a gap.
    public static func misfit(_ parts: [String], sizes: [String: Int64]) -> String? {
        guard let size = parts.first.flatMap({ sizes[$0] }) else { return parts.first }
        return parts.dropFirst().enumerated().first { i, p in
            guard let s = sizes[p] else { return true }
            return i == parts.count - 2 ? s > size : s != size
        }?.element
    }
}
