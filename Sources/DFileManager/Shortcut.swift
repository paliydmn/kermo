import AppKit

/// A key + modifiers, matched by physical key code so shortcuts work on any layout (incl. Ukrainian).
/// Spec format: "cmd+shift+.", "opt+5", "f5", "shift+f6", "backspace", "kpstar".
struct Shortcut: Hashable {
    let keyCode: UInt16
    let mods: UInt

    private static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// name → (ANSI key code, menu key-equivalent character, display label)
    private static let keys: [String: (UInt16, String, String)] = {
        func fk(_ v: Int) -> String { String(Character(UnicodeScalar(UInt32(v))!)) }
        var k: [String: (UInt16, String, String)] = [
            "return": (36, "\r", "↩"), "kpenter": (76, "\u{3}", "⌤"), "tab": (48, "\t", "⇥"),
            "space": (49, " ", "Space"), "backspace": (51, "\u{8}", "⌫"), "delete": (117, fk(NSDeleteFunctionKey), "⌦"),
            "esc": (53, "\u{1b}", "⎋"), "home": (115, fk(NSHomeFunctionKey), "↖"), "end": (119, fk(NSEndFunctionKey), "↘"),
            "pgup": (116, fk(NSPageUpFunctionKey), "⇞"), "pgdn": (121, fk(NSPageDownFunctionKey), "⇟"),
            "left": (123, fk(NSLeftArrowFunctionKey), "←"), "right": (124, fk(NSRightArrowFunctionKey), "→"),
            "down": (125, fk(NSDownArrowFunctionKey), "↓"), "up": (126, fk(NSUpArrowFunctionKey), "↑"),
            "kpstar": (67, "*", "*"), "kpplus": (69, "+", "+"), "kpminus": (78, "-", "-"),
            "menu": (110, fk(NSMenuFunctionKey), "Menu"),   // a PC keyboard's (kVK_ContextualMenu)
        ]
        let fcodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fcodes.enumerated() {
            k["f\(i + 1)"] = (code, fk(NSF1FunctionKey + i), "F\(i + 1)")
        }
        let ansi: [(String, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
            ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
            ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38),
            ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47), ("`", 50),
        ]
        for (ch, code) in ansi { k[ch] = (code, ch, ch.uppercased()) }
        return k
    }()

    init?(_ spec: String) {
        var flags: NSEvent.ModifierFlags = []
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.last, let key = Self.keys[keyName] else { return nil }
        for m in parts.dropLast() {
            switch m {
            case "cmd": flags.insert(.command)
            case "opt", "alt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            case "shift": flags.insert(.shift)
            default: return nil
            }
        }
        keyCode = key.0
        mods = flags.rawValue
        name = keyName
    }

    /// A menu item's letter or digit key ("c" with ⌘: cmd+c); nil for none, or another key.
    init?(menuItem it: NSMenuItem) {
        let m = it.keyEquivalentModifierMask
        let mods = [(NSEvent.ModifierFlags.control, "ctrl"), (.option, "opt"), (.shift, "shift"), (.command, "cmd")].filter { m.contains($0.0) }.map(\.1)
        guard !it.keyEquivalent.isEmpty else { return nil }
        self.init((mods + [it.keyEquivalent.lowercased()]).joined(separator: "+"))
    }

    init(event: NSEvent) {
        let code = event.keyCode == 10 ? 50 : event.keyCode   // ISO keyboards: § (top left) does what ANSI ` does; macOS reports the two swapped on some of them
        keyCode = code
        mods = event.modifierFlags.intersection(Self.relevant).rawValue
        name = Self.keys.first { $0.value.0 == code }?.key ?? ""
    }

    let name: String   // key name as in specs: "f5", "a", "space"
    static func == (a: Shortcut, b: Shortcut) -> Bool { a.keyCode == b.keyCode && a.mods == b.mods }
    func hash(into h: inout Hasher) { h.combine(keyCode); h.combine(mods) }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: mods) }
    var menuKey: String { Self.keys[name]?.1 ?? "" }

    /// What macOS does with it before any app sees it — a keymap.json binding there never fires (warned about at launch).
    var takenByMacOS: String? { Self.systemTaken[self] }
    private static let systemTaken: [Shortcut: String] = Dictionary(uniqueKeysWithValues: [
        ("cmd+opt+d", "toggles Dock hiding"), ("cmd+m", "Minimize, in every Mac app"), ("cmd+opt+m", "Minimize All, in every Mac app"), ("cmd+h", "Hide"), ("cmd+opt+h", "Hide Others"),
        ("cmd+q", "Quit"), ("cmd+space", "Spotlight"), ("cmd+opt+space", "Finder search"), ("cmd+tab", "the app switcher"),
        ("cmd+`", "next window"), ("cmd+shift+3", "screenshot"), ("cmd+shift+4", "screenshot"), ("cmd+shift+5", "screenshot"),
        ("ctrl+cmd+q", "lock screen"), ("cmd+opt+esc", "Force Quit"), ("ctrl+cmd+space", "emoji"), ("ctrl+space", "input source"),
        ("ctrl+opt+space", "input source"), ("ctrl+up", "Mission Control"), ("ctrl+down", "App windows"), ("ctrl+left", "Spaces"),
        ("ctrl+right", "Spaces"), ("cmd+shift+/", "the Help menu's search"),
    ].map { (Shortcut($0.0)!, $0.1) })

    /// Back to the "cmd+shift+." form used in keymap.json.
    var spec: String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        return (parts + [name]).joined(separator: "+")
    }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + (Self.keys[name]?.2 ?? "?")
    }
}
