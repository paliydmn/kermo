import Foundation

// A tool in Kermo's own places (protocol §11): F2's actions on a server file its `context` names, and the check its
// `validators` add to that file's save (F4).

extension ToolPreset {
    /// The names a server `path` gives where `glob` (a `context`'s or validator's `path`, its placeholders filled from
    /// `scope`: `{base}/conf/*.yaml`) takes it: `{file}` the path, `{dir}` its folder, `{stem}` its name without the
    /// last extension. nil: it doesn't. A `*` stays within one folder.
    /// ponytail: a var's value is put in as it is — a `*` or `[` in a tool's folder is the glob's too.
    public static func fileNames(_ path: String, glob: String, _ scope: ToolTemplate.Scope) -> [String: ToolValue]? {
        guard fnmatch(ToolTemplate.text(glob, scope), path, FNM_PATHNAME) == 0 else { return nil }
        let name = (path as NSString).lastPathComponent
        return ["file": .string(path), "dir": .string((path as NSString).deletingLastPathComponent),
                "stem": .string((name as NSString).deletingPathExtension)]
    }

    /// Whether `glob` could take `path` once its placeholders are known: each one as anything, folders too — worth
    /// finding the vars for.
    public static func mayTake(_ path: String, glob: String) -> Bool {
        var g = "", from = glob.startIndex
        for p in ToolTemplate.placeholders(in: glob) {
            g += glob[from..<p.range.lowerBound] + "*"
            from = p.range.upperBound
        }
        return fnmatch(g + glob[from...], path, 0) == 0
    }

    /// The globs of the files the tool knows: its `context`'s and its validators'.
    public var fileGlobs: [String] { (context ?? []).map(\.path) + (validators ?? []).map(\.path) }

    /// The check the tool's `validators` add to a save of server `path` (§11), or nil: none takes it. Its command gets
    /// `{stem}`, `{file}`, `{dir}` and the tool's names as variables set just before it (`setup`), never as text in it
    /// (§3.2 rule 4); `{file}` is the file checked — for a `before` check, the new text next to it (`%f`). As root
    /// where the tool is. A value that won't go into a command (§3.2 rule 5) gives no check.
    public func check(for path: String, _ scope: ToolTemplate.Scope) -> ConfigCheck? {
        for v in validators ?? [] {
            guard let names = Self.fileNames(path, glob: v.path, scope) else { continue }
            var s = scope
            s.levels[0] = names
            var taken: [String: String] = [:]
            guard let body = try? ToolTemplate.command(.one(v.check), s, vars: &taken) else { continue }
            var values = body.values, lines: [String] = []
            for (name, t) in (env ?? [:]).sorted(by: { $0.key < $1.key }) {
                let e = ToolTemplate.value(t, s, vars: &taken)
                values += e.values.filter { !values.contains($0) }
                lines.append("export \(name)=\(e.text)")
            }
            let file = taken["file"]
            // ponytail: no check at all, said nowhere but in the save's line (no "checked:"): a file named "-x" isn't a unit's
            if values.contains(where: { $0.name != file && ToolTemplate.refusal($0.value, pattern: nil) != nil }) { return nil }
            // `%` is ConfigCheck.expand's: `%f` the file checked, `%%` a "%".
            let set = values.map { $0.name == file ? "\($0.name)=%f" : "\($0.name)=" + ShellContext.quote($0.value).replacingOccurrences(of: "%", with: "%%") }
            // `match` is a glob: the path itself, its `*`, `?`, `[` and `\` taken as they are.
            return ConfigCheck(match: path.replacing(/[*?\[\\]/) { "\\" + $0.output }, check: body.text.replacingOccurrences(of: "%", with: "%%"), when: v.when == "after" ? .after : nil,
                               root: sudo == true ? true : nil,
                               setup: (set + lines.map { $0.replacingOccurrences(of: "%", with: "%%") }).joined(separator: "\n"))
        }
        return nil
    }
}
