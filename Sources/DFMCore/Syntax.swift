import Foundation

/// Lightweight regex highlighter for the formats admins edit most: shell, Python, JSON, YAML, INI/conf/TOML,
/// XML/plist, Dockerfile, Makefile and C-family code. Every rule's matches are collected and the one that
/// starts first wins, so a "#" inside a string isn't a comment and a quote inside a comment isn't a string.
// ponytail: regex, not a parser — tree-sitter if exact highlighting of big code files ever matters.
public enum Syntax {
    public enum Token: Sendable { case comment, string, number, keyword, key, tag, variable }
    public enum Language: String, Sendable { case shell, python, json, yaml, ini, conf, xml, dockerfile, makefile, clike }

    public static func language(forFileName name: String, firstLine: String = "") -> Language? {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if lower == "dockerfile" || lower.hasPrefix("dockerfile.") { return .dockerfile }
        if lower == "makefile" || ext == "mk" { return .makefile }
        if [".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", ".zshenv", ".envrc"].contains(lower) { return .shell }
        if [".gitconfig", ".gitmodules", ".editorconfig"].contains(lower) { return .ini }
        switch ext {
        case "sh", "bash", "zsh", "command", "ksh": return .shell
        case "py": return .python
        case "json", "jsonc", "geojson": return .json
        case "yml", "yaml": return .yaml
        case "ini", "toml", "properties", "cfg", "env", "service", "timer", "socket", "desktop", "gitconfig": return .ini
        case "conf", "cnf": return .conf
        case "xml", "plist", "html", "htm", "svg", "xsd", "mobileconfig", "entitlements": return .xml
        case "swift", "c", "h", "m", "mm", "cpp", "hpp", "cc", "js", "mjs", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "cs", "php", "scala", "dart":
            return .clike
        default: break
        }
        if firstLine.hasPrefix("#!") {
            if firstLine.contains("python") { return .python }
            if firstLine.contains("sh") { return .shell }
        }
        return nil
    }

    private typealias Rule = (NSRegularExpression, Token)

    private static func r(_ pattern: String, _ token: Token, _ opts: NSRegularExpression.Options = []) -> Rule {
        (try! NSRegularExpression(pattern: pattern, options: opts.union(.anchorsMatchLines)), token)
    }

    private static let dq = #""(?:[^"\\\n]|\\.)*""#
    private static let sq = #"'(?:[^'\\\n]|\\.)*'"#
    private static let num = #"(?<![\w.])-?(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)(?![\w.])"#

    // Block comments and long strings run to the end of the text when unclosed (as in editors): a pattern that can
    // fail after scanning to the end gets retried from every later opener, O(n²) on a crafted file (S8).
    private static let rules: [Language: [Rule]] = [
        .shell: [
            r(#"(?<![\w$\{])#.*$"#, .comment), r(dq, .string), r(#"'[^']*'"#, .string),
            r(#"\$\{[^}\n]*\}|\$[A-Za-z_]\w*|\$[0-9@#?$!*-]"#, .variable),
            r(#"\b(?:if|then|else|elif|fi|for|while|until|do|done|case|esac|in|function|return|local|export|readonly|declare|set|unset|shift|exit|source|alias|eval|exec|trap|break|continue)\b"#, .keyword),
            r(num, .number),
        ],
        .python: [
            r(#"#.*$"#, .comment), r(#"(?s)\"\"\"[\s\S]*?(?:\"\"\"|\z)|'''[\s\S]*?(?:'''|\z)"#, .string), r(dq, .string), r(sq, .string),
            r(#"\b(?:def|class|return|if|elif|else|for|while|in|not|and|or|is|import|from|as|with|try|except|finally|raise|pass|break|continue|lambda|yield|global|nonlocal|assert|del|async|await|None|True|False|self)\b"#, .keyword),
            r(#"@[A-Za-z_][\w.]*"#, .variable), r(num, .number),
        ],
        .json: [
            r(dq + #"(?=\s*:)"#, .key), r(dq, .string), r(#"\b(?:true|false|null)\b"#, .keyword), r(num, .number),
            r(#"//.*$"#, .comment),
        ],
        .yaml: [
            r(#"(?<!\S)#.*$"#, .comment), r(#"^\s*(?:-\s+)?[^\s#:'"\-][^#:\n]*?(?=:(?:\s|$))"#, .key), r(dq, .string), r(sq, .string),
            r(#"(?<![\w-])(?:true|false|yes|no|on|off|null|~)(?![\w-])"#, .keyword, .caseInsensitive), r(#"[&*][\w-]+"#, .variable),
            r(#"^(?:---|\.\.\.)\s*$"#, .tag), r(num, .number),
        ],
        .ini: [
            r(#"^\s*[#;].*$"#, .comment), r(#"^\s*\[[^\]\n]+\]"#, .tag), r(#"^\s*[\w.\-@/]+(?=\s*[=:])"#, .key),
            r(dq, .string), r(sq, .string), r(#"\b(?:true|false|yes|no|on|off)\b"#, .keyword, .caseInsensitive), r(num, .number),
        ],
        .conf: [   // nginx, sshd_config, httpd, my.cnf, pf.conf…: first word is the directive
            r(#"(?<!\S)[#;].*$"#, .comment), r(#"^\s*\[[^\]\n]+\]"#, .tag), r(#"^\s*[A-Za-z_][\w.\-]*"#, .key),
            r(dq, .string), r(sq, .string), r(#"\$\{?[A-Za-z_]\w*\}?"#, .variable),
            r(#"\b(?:on|off|yes|no|true|false)\b"#, .keyword, .caseInsensitive), r(num, .number),
        ],
        .xml: [
            r(#"<!--[\s\S]*?(?:-->|\z)"#, .comment), r(#"<!\[CDATA\[[\s\S]*?(?:\]\]>|\z)"#, .string), r(#"</?[A-Za-z_][\w:.\-]*|/?>|<\?[\w-]+|\?>"#, .tag),
            r(#"\b[\w:\-]+(?==)"#, .key), r(dq, .string), r(sq, .string),
        ],
        .dockerfile: [
            r(#"^\s*#.*$"#, .comment),
            r(#"^\s*(?:FROM|RUN|CMD|LABEL|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL|MAINTAINER)\b"#, .keyword, .caseInsensitive),
            r(dq, .string), r(sq, .string), r(#"\$\{?[A-Za-z_]\w*\}?"#, .variable), r(#"\bAS\b"#, .keyword),
        ],
        .makefile: [
            r(#"(?<!\\)#.*$"#, .comment), r(#"^[\w.\-/% ]+(?=\s*::?(?!=))"#, .key), r(#"\$[({][^)}\n]*[)}]|\$[@<^?*%+]"#, .variable),
            r(#"^\s*(?:ifeq|ifneq|ifdef|ifndef|else|endif|include|define|endef|export|override)\b"#, .keyword), r(dq, .string), r(sq, .string),
        ],
        .clike: [
            r(#"//.*$"#, .comment), r(#"/\*[\s\S]*?(?:\*/|\z)"#, .comment), r(dq, .string), r(sq, .string), r(#"`[^`]*`"#, .string),
            r(#"\b(?:if|else|for|while|do|switch|case|default|break|continue|return|func|function|fn|let|var|const|static|struct|class|enum|protocol|interface|extension|import|package|public|private|internal|fileprivate|protected|override|final|guard|defer|throw|throws|try|catch|async|await|new|delete|typedef|union|void|int|char|float|double|bool|long|short|unsigned|signed|auto|true|false|nil|null|NULL|self|this|super|in|is|as|where|type|impl|pub|mut|use|mod|match|trait|go|chan|select|map|range|export|from|yield|lazy|weak|unowned|some|any|extern|inline|namespace|template|using|virtual|operator|sizeof)\b"#, .keyword),
            r(#"^\s*#\s*\w+"#, .tag), r(num, .number),
        ],
    ]

    /// Token ranges (UTF-16, for NSAttributedString), non-overlapping, in order.
    /// Scans left to right: at each point the earliest match of any rule wins (ties go to the earlier rule),
    /// then scanning resumes after it — like a lexer, so one rule can't swallow another's territory.
    public static func tokens(_ text: String, _ lang: Language) -> [(range: NSRange, token: Token)] {
        guard let rules = rules[lang] else { return [] }
        let ns = text as NSString
        let length = ns.length
        // Transparent bounds: "^" and lookbehinds see the text before the scan position.
        let opts: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        func find(_ i: Int, from p: Int) -> NSRange? {
            var from = p
            while from < length {
                guard let m = rules[i].0.firstMatch(in: text, options: opts, range: NSRange(location: from, length: length - from)) else { return nil }
                if m.range.length > 0 { return m.range }
                from = m.range.location + 1   // skip empty matches
            }
            return nil
        }
        var next = rules.indices.map { find($0, from: 0) }
        var out: [(range: NSRange, token: Token)] = []
        var p = 0
        while true {
            var best: Int?
            for i in rules.indices {
                if let r = next[i], r.location < p { next[i] = find(i, from: p) }
                if let r = next[i], best == nil || r.location < next[best!]!.location { best = i }
            }
            guard let b = best, var range = next[b] else { break }
            p = NSMaxRange(range)
            if rules[b].1 == .key {   // keys may start with indentation; don't paint it
                while range.length > 0, let c = UnicodeScalar(ns.character(at: range.location)), CharacterSet.whitespaces.contains(c) {
                    range.location += 1
                    range.length -= 1
                }
            }
            out.append((range, rules[b].1))
        }
        return out
    }
}
