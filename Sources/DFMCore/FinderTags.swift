import Foundation

/// Finder tags. The `com.apple.metadata:_kMDItemUserTags` xattr holds "Name\nColor" strings (binary plist);
/// Finder also mirrors the last colored tag into the FinderInfo label bits, which is what list views
/// (and `DirLister`, for free) read. Writing here keeps both in sync, like Finder does.
public enum FinderTags {
    public struct Tag: Equatable, Sendable {
        public var name: String
        public var color: Int   // 0 none, 1 gray, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange
        public init(name: String, color: Int = 0) { self.name = name; self.color = color }
    }

    private static let key = "com.apple.metadata:_kMDItemUserTags"

    public static func read(_ path: String) -> [Tag] {
        let n = getxattr(path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard n > 0 else {
            // Only a FinderInfo label (set by older apps): report it as its color tag.
            let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.labelNumberKey, .localizedLabelKey])
            guard let c = v?.labelNumber, c > 0 else { return [] }
            return [Tag(name: v?.localizedLabel ?? "", color: c)]
        }
        var buf = [UInt8](repeating: 0, count: n)
        guard getxattr(path, key, &buf, n, 0, XATTR_NOFOLLOW) == n,
              let list = try? PropertyListSerialization.propertyList(from: Data(buf), format: nil) as? [String] else { return [] }
        return list.map { s in
            let parts = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return Tag(name: String(parts[0]), color: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }
    }

    public static func write(_ path: String, _ tags: [Tag]) throws {
        if tags.isEmpty {
            if removexattr(path, key, XATTR_NOFOLLOW) != 0 && errno != ENOATTR { throw posixError() }
        } else {
            let data = try PropertyListSerialization.data(fromPropertyList: tags.map { "\($0.name)\n\($0.color)" }, format: .binary, options: 0)
            let rc = data.withUnsafeBytes { setxattr(path, key, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            if rc != 0 { throw posixError() }
        }
        try (URL(fileURLWithPath: path) as NSURL).setResourceValue(tags.last { $0.color != 0 }?.color ?? 0, forKey: .labelNumberKey)
    }

    /// Tags from "a, b, Red": names already on the file (or color names) keep their color.
    public static func parse(_ text: String, existing: [Tag], colorNames: [String]) -> [Tag] {
        var out: [Tag] = []
        for raw in text.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !out.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            let color = existing.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.color
                ?? colorNames.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame } ?? 0
            out.append(Tag(name: name, color: color))
        }
        return out
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
