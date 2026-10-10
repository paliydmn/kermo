import Foundation

/// Parts written by Split File (`split -d -a 3`): "name.000", "name.001", … (".001"-first sets from other tools too).
public enum SplitParts {
    /// The original name and all parts in order, from any one part's name and the names in its folder.
    /// nil if `name` isn't a part or the numbering has a gap (a part is missing).
    public static func sequence(for name: String, in names: [String]) -> (base: String, parts: [String])? {
        func part(_ n: String) -> (base: String, number: Int)? {
            let ext = (n as NSString).pathExtension
            guard ext.utf8.count == 3, ext.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let i = Int(ext) else { return nil }
            return ((n as NSString).deletingPathExtension, i)
        }
        guard let base = part(name)?.base, !base.isEmpty else { return nil }
        let numbers = names.compactMap { n in part(n).flatMap { $0.base == base ? $0.number : nil } }.sorted()
        guard let first = numbers.first, first <= 1, numbers == Array(first..<first + numbers.count) else { return nil }
        return (base, numbers.map { base + "." + String(format: "%03d", $0) })
    }
}
