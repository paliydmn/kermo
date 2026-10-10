import Foundation

/// Total Commander-style multi-rename pattern.
/// Mask tokens: [N] name without extension, [N2-5] / [N3-] characters (1-based), [E] extension,
/// [C] counter, [P] parent folder, [YMD] [Y] [M] [D] [hms] [h] [m] [s] from the modification date.
/// Then find → replace (plain or regex with $1), then case conversion.
public struct RenamePattern: Sendable {
    public enum Case: String, CaseIterable, Sendable { case unchanged, lower, upper, title }

    public var nameMask = "[N]"
    public var extMask = "[E]"
    public var find = ""
    public var replace = ""
    public var regex = false
    public var caseMode = Case.unchanged
    public var counterStart = 1
    public var counterStep = 1
    public var counterDigits = 1

    public init() {}

    /// Input the preview can't turn into a name (typed mid-edit, so report it — never trap).
    public struct Invalid: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// New names for a whole list, the regex compiled once (the preview runs this on every key).
    public func apply(_ items: [(name: String, mtime: Double)], parent: String) throws -> [String] {
        let re = regex && !find.isEmpty ? try NSRegularExpression(pattern: find) : nil
        return try items.enumerated().map { i, it in try apply(it.name, index: i, mtime: it.mtime, parent: parent, re: re) }
    }

    /// New name for `name` at position `index` in the list; throws for an invalid regex, a reversed
    /// [Nx-y] range, or a counter that overflows or pads past a file name's 255 characters.
    public func apply(_ name: String, index: Int, mtime: Double, parent: String, re: NSRegularExpression? = nil) throws -> String {
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }   // ".zshrc" has no extension
        let base = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[name.index(after: $0)...]) } ?? ""
        func counter() throws -> String {
            let (offset, o1) = index.multipliedReportingOverflow(by: counterStep)
            let (n, o2) = counterStart.addingReportingOverflow(offset)
            guard !o1, !o2 else { throw Invalid(message: "Counter is too large") }
            guard counterDigits <= 255 else { throw Invalid(message: "Counter digits must be at most 255") }
            let s = String(n)
            return String(repeating: "0", count: max(0, counterDigits - s.count)) + s
        }
        let date = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date(timeIntervalSince1970: mtime))
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }

        func expand(_ mask: String) throws -> String {
            var out = ""
            var rest = Substring(mask)
            while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
                out += rest[..<open]
                let token = String(rest[rest.index(after: open)..<close])
                out += try value(of: token) ?? "[\(token)]"
                rest = rest[rest.index(after: close)...]
            }
            return out + rest
        }
        func value(of token: String) throws -> String? {
            switch token {
            case "N": return base
            case "E": return ext
            case "C": return try counter()
            case "P": return (parent as NSString).lastPathComponent
            case "YMD": return "\(date.year ?? 0)\(two(date.month))\(two(date.day))"
            case "hms": return "\(two(date.hour))\(two(date.minute))\(two(date.second))"
            case "Y": return String(date.year ?? 0)
            case "M": return two(date.month)
            case "D": return two(date.day)
            case "h": return two(date.hour)
            case "m": return two(date.minute)
            case "s": return two(date.second)
            default:
                // [N2-5], [N3-], [N4]
                guard token.first == "N" else { return nil }
                let parts = token.dropFirst().split(separator: "-", omittingEmptySubsequences: false)
                guard let from = Int(parts[0]), from >= 1 else { return nil }
                let chars = Array(base)
                let end = parts.count == 1 ? from : Int(parts[1]) ?? from
                guard end >= from - 1 else { throw Invalid(message: "[\(token)]: the range ends before it starts") }
                let to = parts.count > 1 && parts[1].isEmpty ? chars.count : end
                guard from <= chars.count else { return "" }
                return String(chars[(from - 1)..<min(to, chars.count)])
            }
        }

        let newBase = try expand(nameMask)
        let newExt = try expand(extMask)
        var result = newExt.isEmpty ? newBase : newBase + "." + newExt
        if !find.isEmpty {
            if regex {
                let re = try re ?? NSRegularExpression(pattern: find)
                result = re.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replace)
            } else {
                result = result.replacingOccurrences(of: find, with: replace)
            }
        }
        switch caseMode {
        case .unchanged: break
        case .lower: result = result.lowercased()
        case .upper: result = result.uppercased()
        case .title: result = result.capitalized
        }
        return result
    }
}

public enum BatchRename {
    public struct Failure: LocalizedError {
        public let path: String
        public let message: String
        public var errorDescription: String? { "“\((path as NSString).lastPathComponent)”: \(message)" }
    }

    /// A new name typed or generated for an item: one path component. Check it before joining it to the folder —
    /// once joined, "../x" or "a/b" is just a path elsewhere.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// Problems that would make `pairs` (full paths) unsafe: empty/invalid names, two items getting
    /// the same name, or a target that already exists and isn't itself being renamed away. `exists` asks the disk
    /// unless told otherwise (a preview knows the folder's names).
    public static func conflicts(_ pairs: [(from: String, to: String)],
                                 exists: (String) -> Bool = { var s = stat(); return lstat($0, &s) == 0 }) -> Set<String> {
        let sources = Set(pairs.map(\.from))
        var seen: [String: Int] = [:]
        for p in pairs { seen[p.to.lowercased(), default: 0] += 1 }   // APFS is usually case-insensitive
        var bad = Set<String>()
        for p in pairs where p.from != p.to {
            let name = (p.to as NSString).lastPathComponent
            let caseOnly = p.from.lowercased() == p.to.lowercased()
            if name.isEmpty || name == "." || name == ".." || seen[p.to.lowercased()]! > 1
                || (!sources.contains(p.to) && !caseOnly && exists(p.to)) {
                bad.insert(p.from)
            }
        }
        return bad
    }

    /// Renames all pairs as one unit: everything is first moved to a temporary name, then to its
    /// target, so swaps (a↔b) and chains work. On any failure, everything already done is rolled back.
    public static func run(_ pairs: [(from: String, to: String)]) throws {
        let pairs = pairs.filter { $0.from != $0.to }
        guard !pairs.isEmpty else { return }
        if let bad = conflicts(pairs).first {
            throw Failure(path: bad, message: "the new name is invalid or already taken")
        }
        let tag = UUID().uuidString.prefix(8)
        let temps = pairs.enumerated().map { i, p in
            ((p.from as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".dfm-ren-\(tag)-\(i)")
        }
        var phase1 = 0, phase2 = 0
        func rollback() {
            for i in (0..<phase2).reversed() { rename(pairs[i].to, temps[i]) }
            for i in (0..<phase1).reversed() { rename(temps[i], pairs[i].from) }
        }
        for i in pairs.indices {
            guard rename(pairs[i].from, temps[i]) == 0 else {
                let err = String(cString: strerror(errno))
                rollback()
                throw Failure(path: pairs[i].from, message: err)
            }
            phase1 += 1
        }
        for i in pairs.indices {
            // rename(2) silently replaces an existing file; never let it.
            var s = stat()
            if lstat(pairs[i].to, &s) == 0 {
                rollback()
                throw Failure(path: pairs[i].to, message: "already exists")
            }
            guard rename(temps[i], pairs[i].to) == 0 else {
                let err = String(cString: strerror(errno))
                rollback()
                throw Failure(path: pairs[i].from, message: err)
            }
            phase2 += 1
        }
    }
}
