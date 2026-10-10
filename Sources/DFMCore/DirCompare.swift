import Foundation

/// Compare Folders (MC/TC): which files in each panel are missing on the other side or newer than
/// their counterpart. Marking those and pressing F5 brings the two folders in sync.
public enum DirCompare {
    /// - Returns: names to mark on the left and on the right. Folders are compared by presence only.
    /// `tolerance`: see `DirSync.mtimeTolerance`.
    public static func differences(left: [FileItem], right: [FileItem], tolerance: Double = 1) -> (left: Set<String>, right: Set<String>) {
        // Match names the way APFS does by default: case-insensitive, normalization-insensitive.
        func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
        let r = Dictionary(right.map { (key($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        let l = Dictionary(left.map { (key($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        var markL = Set<String>(), markR = Set<String>()
        for a in left {
            guard let b = r[key(a.name)] else { markL.insert(a.name); continue }
            guard a.kind != .dir && b.kind != .dir else { continue }
            // Same moment (FAT/SMB round mtimes) but different size: we can't tell which is right.
            if DirSync.sameMoment(a, b, tolerance: tolerance) {
                if a.size != b.size { markL.insert(a.name); markR.insert(b.name) }
            } else if a.mtime > b.mtime {
                markL.insert(a.name)
            } else {
                markR.insert(b.name)
            }
        }
        for b in right where l[key(b.name)] == nil { markR.insert(b.name) }
        return (markL, markR)
    }

    /// The same marks from a recursive `DirSync.compare`: a folder on both sides is marked on the side that has
    /// something newer or missing inside it. `unreadable`: rows whose folder couldn't be listed (left unmarked).
    public static func marks(_ plan: [DirSync.Item]) -> (left: Set<String>, right: Set<String>, unreadable: Int) {
        func top(_ p: String) -> String { String(p.split(separator: "/").first ?? "") }
        var markL = Set<String>(), markR = Set<String>(), unreadable = 0
        for it in plan {
            if it.unreadable != nil { unreadable += 1; continue }
            let l = top(it.path), r = top(it.rightPath ?? it.path)
            switch it.action {
            case .toRight: markL.insert(l)
            case .toLeft: markR.insert(r)
            // Same moment, another size: can't tell which is right. (File vs. folder: neither.)
            case .skip where it.isConflict && it.left?.kind != .dir && it.right?.kind != .dir: markL.insert(l); markR.insert(r)
            default: break
            }
        }
        return (markL, markR, unreadable)
    }
}
