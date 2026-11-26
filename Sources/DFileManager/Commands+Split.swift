import AppKit
import DFMCore

extension AppDelegate {
    // MARK: - Split / combine (big files onto FAT sticks, mail limits…)

    func splitDialog() {
        guard let url = active.cursorURL, !url.hasDirectoryPath else { return NSSound.beep() }
        let name = url.lastPathComponent, dir = url.deletingLastPathComponent().path
        Task {
            guard let size = await prompt("Split “\(name)” into parts of:", value: defaults.string(forKey: "splitSize") ?? "1G", ok: "Split",
                                          info: "Bytes, or with K, M or G (650M, 4G). Parts go next to it: \(name).000, .001, …")
            else { return }
            guard size.range(of: #"^\d+[KkMmGg]?$"#, options: .regularExpression) != nil else {
                return showError(JobErrorMessage("“\(size)” isn't a size like 650M or 4G."))
            }
            // Any part there already, not just .000: split writes over the first ones and leaves the rest, and Combine
            // would join both splits.
            let parts = await Blocking.run(.userInitiated) {
                SplitParts.parts(of: name, in: ((try? DirLister.list(dir)) ?? []).map(\.name))
            }
            guard parts.isEmpty else {
                let shown = parts.prefix(3).map { "“\($0)”" }.joined(separator: ", ") + (parts.count > 3 ? " and \(parts.count - 3) more" : "")
                return showError(JobErrorMessage("\(shown) \(parts.count == 1 ? "is" : "are") there already: combine or remove \(parts.count == 1 ? "it" : "them") first."))
            }
            defaults.set(size, forKey: "splitSize")
            let q = ShellContext.quoteName
            Shell.run("split -d -a 3 -b \(size) -- \(q(name)) \(q(name + ".")) && ls -l \(q(name)).[0-9][0-9][0-9]", in: dir) { [self] _ in
                active.reload(select: name + ".000")
            }
        }
    }

    /// Cursor on any part: joins the whole numbered set back into one file (never overwrites).
    func combineDialog() {
        guard let url = active.cursorURL else { return NSSound.beep() }
        let dir = url.deletingLastPathComponent().path
        Task {
            let items = await Blocking.run(.userInitiated) { (try? DirLister.list(dir)) ?? [] }   // all of them, not just what the filter shows
            guard let seq = SplitParts.sequence(for: url.lastPathComponent, in: items.map(\.name)) else {
                return active.flash("Put the cursor on a part (name.000 / name.001) — and make sure none is missing")
            }
            let sizes = Dictionary(items.map { ($0.name, $0.size) }) { a, _ in a }
            if let odd = SplitParts.misfit(seq.parts, sizes: sizes) {
                let size = { ByteCountFormatter.short(sizes[$0] ?? 0) }
                return showError(JobErrorMessage("“\(odd)” is \(size(odd)), “\(seq.parts[0])” \(size(seq.parts[0])): these look like parts of two different splits. Nothing was combined."))
            }
            guard let target = await prompt("Combine \(seq.parts.count) parts (\(seq.parts.first!) … \(seq.parts.last!)) into:",
                                            value: seq.base, ok: "Combine"), !target.isEmpty else { return }
            let q = ShellContext.quoteName
            Shell.run("set -C; cat \(seq.parts.map(q).joined(separator: " ")) > \(q(target)) && ls -l \(q(target))", in: dir) { [self] _ in
                active.reload(select: (target as NSString).lastPathComponent)
            }
        }
    }
}
