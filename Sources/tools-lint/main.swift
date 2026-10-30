import AppKit
import DFMCore

// tools-lint: Kermo's own checks of Tools presets, without Kermo — for an editor (`file:line: error: …`) and for the
// catalog's CI on a macOS runner. Reads files only: no network, no server.
//   tools-lint <preset.json>…                     the problems of each file; exit 1 if one has an error
//   tools-lint --fixtures <folder> <preset.json>…  parses each fixture with its preset (see `fixtures`)
//   tools-lint --schema                           the JSON Schema of presets, for editors and `$schema`

let args = Array(CommandLine.arguments.dropFirst())
let stderr = FileHandle.standardError

func say(_ s: String) { stderr.write(Data((s + "\n").utf8)) }

/// Each file's preset, or nil after saying its problems. Scripts are looked for next to it.
func load(_ path: String) -> (preset: ToolPreset?, errors: Bool) {
    guard let data = FileManager.default.contents(atPath: path) else { say("\(path): can't be read"); return (nil, true) }
    let dir = (path as NSString).deletingLastPathComponent
    let (preset, problems) = ToolSchema.validate(data, file: (path as NSString).lastPathComponent,
                                                 hasScript: { FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent($0)) },
                                                 hasSymbol: { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
    for p in problems { say("\(path):\(p.line ?? 1): \(p.level.rawValue): \(p.text)") }
    return (preset, problems.contains { $0.level == .error })
}

switch args.first {
case "--schema"?:
    FileHandle.standardOutput.write(ToolSchema.jsonSchema() + Data("\n".utf8))
case "--fixtures"? where args.count >= 3:
    let presets = args.dropFirst(2).compactMap { load($0).preset }
    var failed = presets.count < args.count - 2
    for f in (try? FileManager.default.contentsOfDirectory(atPath: args[1]).sorted()) ?? [] {
        let path = (args[1] as NSString).appendingPathComponent(f)
        guard let (preset, source) = ToolFixture.match(f, presets) else { continue }
        let result = ToolFixture.records(f, FileManager.default.contents(atPath: path) ?? Data(), source)
        print("\(f): \(preset.id) \(source.name) → \(result.summary)")
        if !result.matched { failed = true }
    }
    exit(failed ? 1 : 0)
case nil, "--help"?, "-h"?:
    say("usage: tools-lint <preset.json>… | --fixtures <folder> <preset.json>… | --schema")
    exit(2)
default:
    let errors = args.map { load($0).errors }.contains(true)
    exit(errors ? 1 : 0)
}
