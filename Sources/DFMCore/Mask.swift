import Foundation

/// File-name mask: globs separated by ";" or "," ("*.log; *.txt"), or a regex with a "re:" prefix.
/// Always case-insensitive and Unicode-normalized (Cyrillic names, NFD names from the disk).
public struct Mask {
    private let globs: [String]
    private let regex: NSRegularExpression?

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

    private static func normalize(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
}
