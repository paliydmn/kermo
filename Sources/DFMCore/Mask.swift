import Foundation

/// File-name mask: globs separated by ";" or "," ("*.log; *.txt"), or a regex with a "re:" prefix.
/// Always case-insensitive and Unicode-normalized (Cyrillic names, NFD names from the disk).
public struct Mask {
    private let globs: [String]
    private let regex: NSRegularExpression?
    /// The globs for fnmatch, and plain text ("*log*" as the quick filter makes it) as the substring it is.
    private let cglobs: [[CChar]]
    private let plain: [CChar]?

    /// nil for an empty spec or an invalid regex.
    public init?(_ spec: String) {
        let spec = spec.trimmingCharacters(in: .whitespaces)
        if spec.hasPrefix("re:") {
            guard let re = try? NSRegularExpression(pattern: String(spec.dropFirst(3)), options: .caseInsensitive) else { return nil }
            regex = re
            globs = []
        } else {
            globs = spec.split(whereSeparator: { $0 == ";" || $0 == "," })
                .map { Self.normalize($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
            regex = nil
            if globs.isEmpty { return nil }
        }
        cglobs = globs.map { Array($0.utf8CString) }
        let g = globs.first ?? ""
        plain = globs.count == 1 && g.count > 2 && g.hasPrefix("*") && g.hasSuffix("*") && !g.dropFirst().dropLast().contains { "*?[\\".contains($0) }
            ? Array(String(g.dropFirst().dropLast()).utf8CString) : nil
    }

    /// Quick-filter semantics: plain text matches anywhere in the name; text with * ? [ is a glob.
    public init?(filter text: String) {
        let hasWildcard = text.contains { "*?[".contains($0) }
        self.init(hasWildcard || text.hasPrefix("re:") ? text : "*\(text)*")
    }

    public func matches(_ name: String) -> Bool {
        if let regex {
            return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        let n = Self.normalize(name)
        return globs.contains { g in fnmatch(g, n, 0) == 0 }
    }

    /// A name the way masks see it; plain ASCII (most names) needs no Unicode composition.
    static func normalize(_ s: String) -> String {
        s.utf8.allSatisfy { $0 < 0x80 } ? s.lowercased() : s.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `matches` for the `i`th name of `folded` (`name` itself, for a regex), with no folding of it on every call: a
    /// filter typed over a big folder did that for every name on every key.
    public func matches(_ i: Int, of folded: Folded, name: String) -> Bool {
        guard regex == nil else { return matches(name) }
        return folded.withName(i) { n in
            if let plain { return plain.withUnsafeBufferPointer { strstr(n, $0.baseAddress!) != nil } }
            return cglobs.contains { g in g.withUnsafeBufferPointer { fnmatch($0.baseAddress!, n, 0) == 0 } }
        }
    }

    /// Names folded once, in one buffer: a mask matches the `i`th without folding it again.
    public struct Folded: Sendable {
        private var bytes: [CChar] = []
        private var starts: [Int] = []

        public init(_ names: some Sequence<String>) { append(names) }

        public mutating func append(_ names: some Sequence<String>) {
            for n in names {
                starts.append(bytes.count)
                bytes.append(contentsOf: Mask.normalize(n).utf8CString)
            }
        }

        public var count: Int { starts.count }

        func withName<T>(_ i: Int, _ body: (UnsafePointer<CChar>) -> T) -> T {
            bytes.withUnsafeBufferPointer { body($0.baseAddress! + starts[i]) }
        }
    }
}
