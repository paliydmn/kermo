import Foundation

/// New Tool… (Tools PR 4): the id a name gives, and the files a tool starts from — a list with an action, buttons, one
/// command. Each runs as it is on most Linux servers, so Test shows something before you change a line.
public enum ToolNew {
    public enum Kind: String, CaseIterable, Sendable {
        case list, buttons, command

        public var title: String {
            switch self {
            case .list: "List with Actions"
            case .buttons: "Buttons"
            case .command: "One Command"
            }
        }

        public var about: String {
            switch self {
            case .list: "Rows from a command's output; actions on a row. Like Firewall (ufw)."
            case .buttons: "Commands that run when pressed, each its own button. Like Server Info."
            case .command: "One command; its output opens in a window."
            }
        }
    }

    /// "My Tool" → "my-tool", "Мій бекап" → "mii-bekap": `[a-z0-9-]+`, the file's name. nil: no letter or digit in it.
    public static func id(from name: String) -> String? {
        let latin = name.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? name
        let id = latin.lowercased().unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return id.isEmpty ? nil : String(id.prefix(64))
    }

    /// The file `kind` starts from, with your id and title.
    public static func text(_ kind: Kind, id: String, title: String) -> String {
        let head = """
              "schema": 1,
              "id": \(quoted(id)),
              "title": \(quoted(title)),
            """
        switch kind {
        case .list:
            return """
                {
                \(head)
                  "about": "Mounted filesystems; a row's usage in full.",
                  "requires": "command -v df",
                  "list": {
                    "command": "df -P | tail -n +2",
                    "format": "regex",
                    "pattern": "^(?<fs>\\\\S+)\\\\s+\\\\d+\\\\s+\\\\d+\\\\s+\\\\d+\\\\s+(?<used>\\\\d+%)\\\\s+(?<mount>/.*)$",
                    "key": "{mount}",
                    "title": "{mount}",
                    "subtitle": "{used} used",
                    "detail": "{fs}"
                  },
                  "actions": [
                    { "id": "show", "title": "Show Usage", "key": "return", "readonly": true, "command": "df -h {mount}", "output": "window" }
                  ]
                }

                """
        case .buttons:
            return """
                {
                \(head)
                  "about": "How busy the server is.",
                  "toolActions": [
                    { "id": "load", "title": "Load Now", "key": "return", "readonly": true, "command": "uptime", "output": "window" },
                    { "id": "memory", "title": "Memory", "readonly": true, "command": "free -h", "output": "window" }
                  ]
                }

                """
        case .command:
            return """
                {
                \(head)
                  "about": "Who is logged in.",
                  "command": "who"
                }

                """
        }
    }

    private static func quoted(_ s: String) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .withoutEscapingSlashes
        return (try? enc.encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}
