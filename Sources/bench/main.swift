// Usage: swift run -c release bench [N | /some/dir]
// Without a dir: builds a fixture of N entries (default 100k) in $TMPDIR and benchmarks it.
// Also checks that getattrlistbulk output matches FileManager — exits non-zero if not.
import Foundation
import DFMCore

let arg = CommandLine.arguments.dropFirst().first ?? "100000"
let dir: String
if arg.hasPrefix("/") || arg.hasPrefix("~") {
    dir = (arg as NSString).expandingTildeInPath
} else {
    let n = Int(arg) ?? 100_000
    dir = NSTemporaryDirectory() + "dfm-bench-\(n)"
    makeFixture(dir, n)
}

func makeFixture(_ dir: String, _ n: Int) {
    let fm = FileManager.default
    if (try? fm.contentsOfDirectory(atPath: dir).count) == n { return }
    try? fm.removeItem(atPath: dir)
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    print("creating \(n) entries in \(dir)…")
    let exts = ["txt", "log", "swift", "png"]
    for i in 0..<n {
        let p = "\(dir)/file\(i).\(exts[i % 4])"
        switch i {
        case _ where i % 50 == 0: try! fm.createDirectory(atPath: "\(dir)/dir\(i)", withIntermediateDirectories: false)
        case _ where i % 997 == 3: try! fm.createSymbolicLink(atPath: p, withDestinationPath: "file1.log")
        case _ where i % 1000 == 7: fm.createFile(atPath: "\(dir)/.hidden\(i)", contents: nil)
        default: fm.createFile(atPath: p, contents: Data(count: i % 4096))
        }
    }
}

@discardableResult
func measure(_ label: String, runs: Int = 5, _ body: () throws -> Void) rethrows -> Double {
    var best = Double.infinity
    for _ in 0..<runs {
        let t = DispatchTime.now().uptimeNanoseconds
        try body()
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
    }
    print(label.padding(toLength: 36, withPad: " ", startingAt: 0), String(format: "%9.1f ms", best))
    return best
}

// Correctness: fast lister must agree with FileManager.
let fast = try DirLister.list(dir)
let slow = try DirLister.listFoundation(dir)
check(fast.count == slow.count, "count mismatch: \(fast.count) vs \(slow.count)")
let oracle = Dictionary(slow.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
for f in fast {
    guard let s = oracle[f.name] else { check(false, "missing in FileManager: \(f.name)"); exit(1) }
    check(f.kind == s.kind, "kind mismatch for \(f.name): \(f.kind) vs \(s.kind)")
    if f.kind == .file { check(f.size == s.size, "size mismatch for \(f.name)") }
    check(abs(f.mtime - s.mtime) < 1, "mtime mismatch for \(f.name)")
}
print("✓ getattrlistbulk == FileManager on \(fast.count) entries in \(dir)")

// Correctness: fast natural sort must agree with Finder's order on ASCII names.
func names(_ s: [String]) -> [FileItem] { s.map { FileItem(name: $0, kind: .file, size: 0, mtime: 0, mode: 0, flags: 0) } }
let sample = ["file10.txt", "File2.txt", "file1.txt", "a_b", "a-b", "a1", "ab", "x007", "x7a", "x10", ".zshrc", "Ünïcode", "єнот", "яблуко", "README", "readme.md", "v1.10", "v1.9"]
let ours = names(sample).sortedForPanel(by: .name, ascending: true).map(\.name)
let ascii = sample.filter { $0.utf8.allSatisfy { $0 < 0x80 } }
let finderAscii = ascii.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
check(ours.filter(ascii.contains) == finderAscii, "natural sort differs from Finder:\n\(ours)\n\(finderAscii)")
var rng = SystemRandomNumberGenerator()
let alphabet = Array("abcXYZ0123456789_-. ~()")
let fuzz = (0..<3000).map { _ in String((0..<Int.random(in: 1...8, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }) }
let oursFuzz = names(fuzz).sortedForPanel(by: .name, ascending: true).map(\.name)
for (a, b) in zip(oursFuzz, oursFuzz.dropFirst()) {
    check(b.localizedStandardCompare(a) != .orderedAscending, "fuzz: \(a) should not precede \(b)")
}
print("✓ natural sort matches Finder order: \(ours.joined(separator: " "))\n")

print("best of 5, warm cache:")
try measure("list (getattrlistbulk)") { _ = try DirLister.list(dir) }
try measure("list (FileManager + resourceValues)", runs: 1) { _ = try DirLister.listFoundation(dir) }
measure("sort by name (natural)") { _ = fast.sortedForPanel(by: .name, ascending: true) }
measure("sort by size") { _ = fast.sortedForPanel(by: .size, ascending: false) }
measure("filter hidden") { _ = fast.filter { !$0.isHidden } }
measure("filter (Mask) each name folded") { let m = Mask(filter: "file1")!; _ = fast.filter { m.matches($0.name) } }
let folded = Mask.Folded(fast.lazy.map(\.name))
measure("filter (Mask) names folded once") { let m = Mask(filter: "file1")!; _ = fast.indices.filter { m.matches($0, of: folded, name: fast[$0].name) } }
measure("fold the names (a filter, once)") { _ = Mask.Folded(fast.lazy.map(\.name)) }

/// precondition() drops its message in -O builds; this one always prints.
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { FileHandle.standardError.write(Data("✗ \(msg())\n".utf8)); exit(1) }
}

// Syntax highlighting cost on ~1 MB of shell (the editor re-tints the whole file after edits).
let line = #"if [ -f "$HOME/x # y" ]; then echo ${#arr} 42 'q'; fi # comment"# + "\n"
let script = String(repeating: line, count: (1 << 20) / line.utf8.count)
measure("syntax: 1 MB shell", runs: 3) { _ = Syntax.tokens(script, .shell) }
