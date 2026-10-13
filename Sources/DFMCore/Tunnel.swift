import Foundation

/// A saved server's tunnel (README "Tunnels"): Kermo listens on 127.0.0.1:`localPort` itself, and each connection
/// there rides the server's shared ssh connection to `host`:`port` as the server sees it (`ssh -W`); "localhost" is
/// the server itself. In servers.json; `on` ones listen from launch.
public struct Tunnel: Codable, Equatable, Sendable {
    public var name = ""             // "" = the port's usual name, else host:port
    public var localPort = 0
    public var host = "localhost"
    public var port = 0
    public var url: String?          // nil: http(s)://localhost:<localPort> for a web port, none for the rest
    public var on = false

    public init(name: String = "", localPort: Int, host: String = "localhost", port: Int, url: String? = nil, on: Bool = false) {
        (self.name, self.localPort, self.host, self.port, self.url, self.on) = (name, localPort, host, port, url, on)
    }

    /// Hand-written ones may give the port alone: the same port here, to the server itself.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decode(Int.self, forKey: .port)
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? port
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        url = try c.decodeIfPresent(String.self, forKey: .url).flatMap { $0.isEmpty ? nil : $0 }
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? false
    }

    /// Names for the ports a tunnel usually goes to: a new tunnel's name when none is typed.
    public static let knownNames = [5432: "Postgres", 3306: "MySQL", 6379: "Redis", 27017: "MongoDB", 9200: "Elasticsearch",
                                    3000: "Grafana", 9090: "Prometheus", 15672: "RabbitMQ", 8006: "Proxmox"]
    /// Ports a browser opens, and how; a database's port has no URL, so no Open in Browser.
    static let webSchemes = [80: "http", 443: "https", 3000: "http", 5601: "http", 8000: "http", 8006: "https", 8080: "http",
                             8443: "https", 9090: "http", 9200: "http", 15672: "http"]

    public var title: String { name.isEmpty ? Self.knownNames[port] ?? remote : name }
    /// Where it goes, as the server sees it: "localhost:5432", "[::1]:5432".
    public var remote: String { (host.contains(":") ? "[\(host)]" : host) + ":\(port)" }
    /// What a client on this Mac connects to (Copy Address).
    public var address: String { "localhost:\(localPort)" }
    /// "localhost:15432 → db1 → localhost:5432".
    public func route(via server: String) -> String { "\(address) → \(server) → \(remote)" }
    /// Open in Browser's.
    public var link: URL? {
        if let url { return URL(string: url) }
        return Self.webSchemes[port].flatMap { URL(string: "\($0)://localhost:\(localPort)") }
    }

    /// The Forward field, as `ssh -L` takes it: "5432", "15432:5432", "15432:db.internal:5432".
    public var forward: String {
        host == "localhost" ? (localPort == port ? "\(port)" : "\(localPort):\(port)") : "\(localPort):\(remote)"
    }

    public struct Problem: Error, Equatable { public let message: String }

    /// The Forward field read as `ssh -L` reads it: "5432" (to the server's own 5432), "15432:5432",
    /// "15432:db.internal:5432", "15432:[::1]:5432". A bind address before them may only be this Mac's loopback:
    /// Kermo listens on 127.0.0.1 alone. The rest of the tunnel (name, URL, on) stays as it was.
    public func reading(_ forward: String) -> Result<Tunnel, Problem> {
        var parts = [""], inBrackets = false
        for ch in forward.trimmingCharacters(in: .whitespaces) {
            if ch == "[" { inBrackets = true } else if ch == "]" { inBrackets = false }
            if ch == ":" && !inBrackets { parts.append("") } else { parts[parts.count - 1].append(ch) }
        }
        if parts.count == 4 {
            guard ["127.0.0.1", "localhost"].contains(parts[0]) else {
                return .failure(Problem(message: "Kermo listens on 127.0.0.1 only, never on “\(parts[0])”."))
            }
            parts.removeFirst()
        }
        guard parts != [""] else { return .failure(Problem(message: "Enter a port as ssh -L takes it: 5432, 15432:5432 or 15432:db.internal:5432.")) }
        guard parts.count <= 3 else { return .failure(Problem(message: "Too many “:” — an IPv6 address goes in brackets: 15432:[::1]:5432.")) }
        var ports: [Int] = []
        for p in [parts.first!, parts.last!] {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else {
                return .failure(Problem(message: "“\(p)” isn't a port."))
            }
            ports.append(n)
        }
        var t = self
        (t.localPort, t.port) = (ports[0], ports[1])
        t.host = parts.count == 3 ? parts[1] : "localhost"
        if t.host.hasPrefix("["), t.host.hasSuffix("]") { t.host = String(t.host.dropFirst().dropLast()) }
        return t.problem.map { .failure(Problem(message: $0)) } ?? .success(t)
    }

    /// Why it can't be used, or nil. The host goes to ssh inside one argument ("-W host:port"), never through a shell;
    /// still no leading "-", space or "@" (it's a host, not ssh's options or a login).
    public var problem: String? {
        if !(1...65535).contains(localPort) { return "The local port must be 1–65535." }
        if !(1...65535).contains(port) { return "The port must be 1–65535." }
        if host.isEmpty { return "Enter a host." }
        if host.hasPrefix("-") || host.contains(where: { $0.isWhitespace || "@[]/".contains($0) }) { return "“\(host)” isn't a host name." }
        if let url, !["http", "https"].contains(URL(string: url)?.scheme?.lowercased() ?? "") { return "The URL must start with http:// or https://." }
        return nil
    }

    /// A server's tunnels: each one's problem, then a local port twice (one of them could never listen).
    public static func problem(_ tunnels: [Tunnel]) -> String? {
        for t in tunnels { if let p = t.problem { return "Tunnel “\(t.title)”: \(p)" } }
        var seen = Set<Int>()
        for t in tunnels where !seen.insert(t.localPort).inserted { return "Two tunnels listen on port \(t.localPort): each needs a port of its own." }
        return nil
    }

    /// The child for one connection, with the accepted socket as its stdin and stdout: `ssh -W host:port` riding the
    /// server's master. ControlMaster=no comes first (ssh keeps an option's first value): if the master went away
    /// meanwhile, this one logs in by itself and never stays behind as a master holding the client's socket.
    public func arguments(_ t: SFTPTarget) -> [String] {
        ["-o", "ControlMaster=no"] + SFTP.connectionOptions(t) + ["-W", remote] + t.arguments()
    }

    /// Why a connection failed, in plain words, from what ssh said: the master's log since the connection began (in
    /// mux mode the reason is there alone; the child only says "Session open refused by peer") and the child's
    /// stderr (where it is without a master). `server`: as the sidebar names it. nil: nothing said.
    // ponytail: two refusals at once on one server may swap reasons — a channel's number can't be tied to its client.
    public func failure(_ said: String, server: String) -> String? {
        let lines = said.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("Warning: Permanently added") }
        if let line = lines.last(where: { $0.contains("open failed: ") }), let at = line.range(of: "open failed: ") {
            let why = line[at.upperBound...]
            if why.contains("administratively prohibited") { return "\(server) forbids port forwarding (AllowTcpForwarding / PermitOpen)" }
            if why.contains("Connection refused") { return "Nothing listens on \(remote) (as seen from \(server))" }
            if ["not known", "does not resolve", "name resolution", "No address associated"].contains(where: { why.contains($0) }) {
                return "\(server) can't resolve \(host)"
            }
            return "\(server) can't reach \(remote): " + (why.hasPrefix("connect failed: ") ? why.dropFirst("connect failed: ".count) : why)
        }
        let rest = lines.filter { !$0.hasPrefix("Stdio forwarding request failed") && !$0.hasPrefix("stdio forwarding failed") }
        return rest.last ?? (lines.isEmpty ? nil : "\(server) refused the connection to \(remote)")
    }
}
