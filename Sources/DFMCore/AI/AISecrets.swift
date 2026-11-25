import Foundation

/// Secrets as `•••` in text before it goes to a model provider or into a kept chat.
///
/// By patterns, so incomplete: a password in prose, a secret under a key that doesn't say so, a token of an unknown
/// shape pass as they are. It errs towards hiding (`Bearer authentication` loses a word). Never the only protection:
/// the model gets only what the user added or allowed. A value without quotes ends at its first space
/// (`password: my secret phrase` keeps two words).
public enum AISecrets {
    /// - a PEM private key (to its END line, or to the end of the text when it is cut);
    /// - `Bearer …`, `Authorization: Basic …`;
    /// - the password of `scheme://user:password@host`;
    /// - the value after a key naming a password, secret, token or key (`DB_PASSWORD=…`, `"api_key": "…"`, `api-key:`,
    ///   `APP_KEY=`, YAML) — a key's name is one of API, APP, AUTH, PRIVATE, ACCESS, ENCRYPTION, SIGNING, MASTER before
    ///   KEY: not `KEY=` alone, `PUBLIC_KEY`, `SSH_KEY`, `sort_keys` (a public key, a path, a setting);
    /// - the value after a command line's `--password`, `--passphrase`, `--token`, `--secret`, `--api-key` (and
    ///   `--db-password`…), with `=` or a space — not `-p` (ssh's port), not `--password-file /path` (a path), not a
    ///   next `--flag`;
    /// - tokens known by their shape (`sk-…`, GitHub, AWS key ids, Slack) and crypt hashes (`$6$…`, Apache's `$apr1$…`).
    public static func mask(_ text: String) -> (text: String, hidden: Int) {
        let hidden = ranges(text), out = NSMutableString(string: text)
        for r in hidden.reversed() { out.replaceCharacters(in: r, with: "•••") }
        return (out as String, hidden.count)
    }

    /// What `mask` hides in `text`, in its UTF-16, in order — the one place it is found, so what a model reads and
    /// what `propose_edit` keeps it from changing are the same.
    public static func ranges(_ text: String) -> [NSRange] { found(text).hidden }

    /// Every pattern on the text as it is; what they hide, overlapping or touching ones as one; and each match whole —
    /// a key and its `=` with the value: an edit touching that could change what is hidden, or whether it is.
    public static func found(_ text: String) -> (hidden: [NSRange], whole: [NSRange]) {
        let all = NSRange(location: 0, length: (text as NSString).length)
        let matches = patterns.flatMap { re, keep in re.matches(in: text, range: all).map { (keep ? $0.range(at: 2) : $0.range, $0.range) } }.filter { $0.0.length > 0 }
        func merged(_ rs: [NSRange]) -> [NSRange] {
            rs.sorted { $0.location < $1.location }.reduce(into: []) { out, r in
                if let last = out.last, r.location <= NSMaxRange(last) { out[out.count - 1] = NSUnionRange(last, r) } else { out.append(r) }
            }
        }
        return (merged(matches.map(\.0)), merged(matches.map(\.1)))
    }

    /// A key's value after `Bearer`: `token: Bearer x` loses `x` and the word before it (counted twice). `keep`: only
    /// group 2 is the secret. Lookbehinds, not `\b`, where a run of name characters comes first: `\b` starts again
    /// inside the run, which is quadratic on a long token.
    private static let patterns: [(NSRegularExpression, keep: Bool)] = [
        (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY[A-Z ]*-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY[A-Z ]*-----|\z)"#, false),
        (#"(?i)(\bBearer\s+|\bAuthorization:\s*Basic\s+)([A-Za-z0-9._~+/=-]{12,})"#, true),
        (#"((?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]*://[^:/@\s]*:)([^@/\s]+)(?=@)"#, true),
        (#"(?i)((?<![\w.-])[\w.-]*(?:PASSWORD|PASSWD|PASSPHRASE|SECRET|TOKEN|(?:API|APP|AUTH|PRIVATE|ACCESS|ENCRYPTION|SIGNING|MASTER)[_-]?KEYS?(?![A-Za-z]))[\w.-]*["']?[ \t]*(?:=>|:=|[=:])[ \t]*)("(?:\\.|[^"\\\n])*"?|'[^'\n]*'?|[^\s"'•]\S*)"#, true),
        (#"(?i)((?<![\w-])--(?!no-)[\w-]*(?:PASSWORD|PASSWD|PASSPHRASE|SECRET|TOKEN|API[_-]?KEY)(?![\w-])(?:=|[ \t]+))("(?:\\.|[^"\\\n])*"?|'[^'\n]*'?|[^\s"'•-]\S*)"#, true),
        (#"\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})"#, false),
        (#"\$(?:1|2[aby]|5|6|y|apr1)\$[./A-Za-z0-9$=,]{20,}"#, false),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}
