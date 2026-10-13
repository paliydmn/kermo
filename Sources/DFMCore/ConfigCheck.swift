import Foundation

/// A server file's check when it's saved: a command run there on the new text before it takes the file's place, or on
/// the file after (then a failure puts the old text back), and what reloads the service once it passed. Built-in rules
/// for the usual /etc configs; `~/.config/dfilemanager/validators.json` holds the user's own in the same shape, looked at
/// first. Kermo installs nothing: it runs the server's own tools.
public struct ConfigCheck: Codable, Sendable, Equatable {
    public enum When: String, Codable, Sendable { case before, after }

    /// A glob of the server path (`*` crosses "/" too, so `/etc/nginx/*` is all of it); without a "/", of the file's name.
    public var match: String
    /// A shell command there, `%f` the file's path (quoted). nil (`"check": null`): none — a built-in rule for that path
    /// is off.
    public var check: String?
    /// `before` (default): on the partial file next to it, which takes the file's place only if this passes — for a
    /// file that stands alone (sudoers: broken even for a second, `sudo -n` fails, and with it the way back). `after`:
    /// on the file in place — for configs with includes, which only the live tree checks — the old text put back on failure.
    public var when: When?
    /// Offered once the check passed (or the rule has none).
    public var reload: String?
    /// The check works only as root (`nginx -t`, `sshd -t` …): a user's panel doesn't run it.
    public var root: Bool?

    public init(match: String, check: String?, when: When? = nil, reload: String? = nil, root: Bool? = nil) {
        (self.match, self.check, self.when, self.reload, self.root) = (match, check, when, reload, root)
    }

    public var after: Bool { when == .after }
    public var needsRoot: Bool { root == true }

    /// sshd's reload: Debian names the unit ssh, Red Hat sshd.
    public static let sshdReload = "systemctl reload ssh || systemctl reload sshd"

    /// Checked on a test server (task notes): each catches a broken config, the `before` ones on a partial file; those
    /// marked root fail as a user even on a good config (no host keys, pid file, netlink, postfix's own refusal, 0440).
    public static let builtIn: [ConfigCheck] = [
        .init(match: "/etc/sudoers", check: "visudo -cf %f", root: true),
        .init(match: "/etc/sudoers.d/*", check: "visudo -cf %f", root: true),
        .init(match: "/etc/ssh/sshd_config", check: "sshd -t -f %f", reload: sshdReload, root: true),
        .init(match: "/etc/ssh/sshd_config.d/*", check: "sshd -t", when: .after, reload: sshdReload, root: true),
        .init(match: "/etc/haproxy/haproxy.cfg", check: "haproxy -c -f %f", reload: "systemctl reload haproxy"),
        .init(match: "/etc/nftables.conf", check: "nft -c -f %f", root: true),   // applied by hand: nft -f
        .init(match: "/etc/nginx/*", check: "nginx -t", when: .after, reload: "systemctl reload nginx", root: true),
        .init(match: "/etc/apache2/*", check: "apachectl configtest", when: .after, reload: "systemctl reload apache2"),
        .init(match: "/etc/httpd/*", check: "apachectl configtest", when: .after, reload: "systemctl reload httpd"),
        // A unit's partial file has no unit suffix: systemd-analyze refuses it.
        .init(match: "/etc/systemd/system/*.service", check: "systemd-analyze verify %f", when: .after, reload: "systemctl daemon-reload"),
        .init(match: "/etc/systemd/system/*.timer", check: "systemd-analyze verify %f", when: .after, reload: "systemctl daemon-reload"),
        .init(match: "/etc/postfix/*", check: "postfix check", when: .after, reload: "postfix reload", root: true),
        .init(match: "/etc/bind/named.conf*", check: "named-checkconf", when: .after, reload: "rndc reload"),   // Debian
        .init(match: "/etc/named.conf", check: "named-checkconf", when: .after, reload: "rndc reload"),          // Red Hat
        // The partial file is in the same folder: relative paths and .env are the same. No daemon needed.
        .init(match: "compose.yaml", check: "docker compose -f %f config -q"),
        .init(match: "compose.yml", check: "docker compose -f %f config -q"),
        .init(match: "docker-compose.yaml", check: "docker compose -f %f config -q"),
        .init(match: "docker-compose.yml", check: "docker compose -f %f config -q"),
    ]

    /// The rules for a save: the user's (`validators.json`'s bytes, nil: no file) first, then the built-in ones. A file
    /// that isn't a list of rules: the built-in ones, and what's wrong with it.
    public static func rules(_ data: Data?) -> (rules: [ConfigCheck], problem: String?) {
        guard let data else { return (builtIn, nil) }
        do { return (try JSONDecoder().decode([ConfigCheck].self, from: data) + builtIn, nil) } catch {
            return (builtIn, "validators.json: \(error.localizedDescription) Built-in checks only.")
        }
    }

    /// The first rule for `path`.
    public static func rule(for path: String, in rules: [ConfigCheck]) -> ConfigCheck? { rules.first { $0.matches(path) } }

    public func matches(_ path: String) -> Bool {
        fnmatch(match, match.contains("/") ? path : (path as NSString).lastPathComponent, 0) == 0
    }

    /// `command` with `%f` the path, quoted for the server's shell; `%%` a "%".
    public static func expand(_ command: String, path: String) -> String {
        command.components(separatedBy: "%%").map { $0.replacingOccurrences(of: "%f", with: ShellContext.quote(path)) }.joined(separator: "%")
    }
}
