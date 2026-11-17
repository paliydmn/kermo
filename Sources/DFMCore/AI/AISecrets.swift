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
    /// - the value after a key naming a password, secret, token or key (`DB_PASSWORD=…`, `"api_key": "…"`, YAML);
    /// - tokens known by their shape (`sk-…`, GitHub, AWS key ids, Slack) and crypt hashes (`$6$…`).
    public static func mask(_ text: String) -> (text: String, hidden: Int) {
        let out = NSMutableString(string: text)
        var hidden = 0
        for (re, keep) in patterns {
            for m in re.matches(in: out as String, range: NSRange(location: 0, length: out.length)).reversed() {
                let secret = keep ? m.range(at: 2) : m.range
                guard secret.length > 0 else { continue }
                out.replaceCharacters(in: secret, with: "•••")
                hidden += 1
            }
        }
        return (out as String, hidden)
    }

    /// In order — a key's value after `Bearer`: `token: Bearer x` loses `x` and the word before it (counted twice).
    /// `keep`: only group 2 is the secret. Lookbehinds, not `\b`, where a run of name characters comes first: `\b`
    /// starts again inside the run, which is quadratic on a long token.
    private static let patterns: [(NSRegularExpression, keep: Bool)] = [
        (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY[A-Z ]*-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY[A-Z ]*-----|\z)"#, false),
        (#"(?i)(\bBearer\s+|\bAuthorization:\s*Basic\s+)([A-Za-z0-9._~+/=-]{12,})"#, true),
        (#"((?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]*://[^:/@\s]*:)([^@/\s]+)(?=@)"#, true),
        (#"(?i)((?<![\w.-])[\w.-]*(?:PASSWORD|PASSWD|PASSPHRASE|SECRET|TOKEN|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY)[\w.-]*["']?[ \t]*(?:=>|:=|[=:])[ \t]*)("(?:\\.|[^"\\\n])*"?|'[^'\n]*'?|[^\s"'•]\S*)"#, true),
        (#"\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})"#, false),
        (#"\$(?:1|2[aby]|5|6|y)\$[./A-Za-z0-9$=,]{20,}"#, false),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}
