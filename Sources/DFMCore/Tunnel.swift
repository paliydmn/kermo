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

    public struct Problem: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

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

extension Tunnel {
    /// What each connection to the tunnel runs: a login first when the server's master is down (`startMaster`: the
    /// saved password, askpass — `env`), then `ssh -W` riding it. A refusal is read from the master's log, from where it
    /// ended when the child started. `server`: as the sidebar names it, for the reasons.
    /// The tunnel's logins go one at a time: when one fails (a wrong password, the dialog cancelled), the connections that
    /// came while it was under way fail with it — a client opening several at once doesn't get the dialog again for each.
    public func child(on t: SFTPTarget, env: [String: String], server: String) -> @Sendable (CancelFlag) throws -> TunnelListener.Child {
        let tunnel = self, gate = LoginGate()
        return { cancel in
            try gate.pass(since: Date()) {
                do { try SFTP.startMaster(t, env: env, cancel: cancel) } catch let e as SFTPError {
                    // A changed host key is said already, in plain words: its first line (the fingerprint is in the panel's alert).
                    let hostKey = e.hostKey != nil ? e.message.split(whereSeparator: \.isNewline).first.map(String.init) : nil
                    throw Problem(message: hostKey ?? tunnel.failure(e.message, server: server) ?? e.message)
                }
            }
            let log = SFTP.masterLog(t)
            let from = (try? FileManager.default.attributesOfItem(atPath: log)[.size] as? UInt64) ?? 0
            return TunnelListener.Child(executable: "/usr/bin/ssh", arguments: tunnel.arguments(t), environment: env) { status, stderr in
                guard status != 0 else { return nil }
                let since = FileHandle(forReadingAtPath: log).map { h in
                    defer { try? h.close() }
                    try? h.seek(toOffset: from)   // a new master emptied it meanwhile: nothing past the end
                    return h.readDataToEndOfFile()
                } ?? Data()
                // Nothing said (LogLevel QUIET in ~/.ssh/config hides it from the child): still not a clean end.
                return tunnel.failure(String(decoding: since, as: UTF8.self) + "\n" + stderr, server: server)
                    ?? "\(server) refused the connection to \(tunnel.remote)"
            }
        }
    }
}

/// A tunnel's logins, one at a time (`Tunnel.child`).
final class LoginGate: @unchecked Sendable {
    private let lock = NSLock()   // held through a login
    private var failed: (at: Date, error: Error)?

    /// `login`, unless one that failed ended after `came` (this connection waited for it): its error then.
    func pass(since came: Date, _ login: () throws -> Void) throws {
        try lock.withLock {
            if let f = failed, f.at > came { throw f.error }
            do { try login() } catch {
                failed = (Date(), error)
                throw error
            }
        }
    }
}

/// Listens on this Mac's loopback — 127.0.0.1 and ::1, as `ssh -L` does: most clients try localhost's ::1 first, where
/// another program could otherwise take the port — and gives each connection a child process of its own with the socket
/// as its stdin and stdout, as inetd does: the bytes never pass through Kermo. Accepts on a queue of its own, never the
/// main thread. `stop` closes the port and ends the children, so their connections close.
public final class TunnelListener: @unchecked Sendable {
    /// One connection's child, and how its end reads: nil, a clean end.
    public struct Child: Sendable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]?
        public var failure: @Sendable (_ status: Int32, _ stderr: String) -> String?
        public init(executable: String, arguments: [String] = [], environment: [String: String]? = nil,
                    failure: @escaping @Sendable (_ status: Int32, _ stderr: String) -> String? = { _, _ in nil }) {
            (self.executable, self.arguments, self.environment, self.failure) = (executable, arguments, environment, failure)
        }
    }
    /// A connection came, or went (with why it failed, if it did). Not after `stop`. On the listener's threads, before
    /// `connections` counts it.
    public enum Event: Sendable, Equatable { case opened, closed(failure: String?) }

    public let port: Int
    private let child: @Sendable (CancelFlag) throws -> Child
    private let onEvent: @Sendable (Event) -> Void
    private let closed = DispatchSemaphore(value: 0)
    private let lock = NSLock()   // guards the rest
    private var sources: [DispatchSourceRead] = []   // empty once stopped
    private var stopped = false
    private var logins: [CancelFlag] = []   // connections still logging in, each with a flag of its own (a flag holds one handler)
    private var live: [Process] = []
    private var count = 0

    /// Connections open now, those still logging in too.
    public var connections: Int { lock.withLock { count } }

    /// Fails at once when the port is taken: someone listens on it on the loopback, or on every address — with
    /// SO_REUSEADDR (without it a port stays taken ~30 s after its connections close) a bind to the loopback alone would
    /// quietly take localhost:`port` over from them. Port 0: any free one (tests).
    public init(port: Int, child: @escaping @Sendable (CancelFlag) throws -> Child, onEvent: @escaping @Sendable (Event) -> Void) throws {
        func taken(_ e: Int32) -> Tunnel.Problem {
            Tunnel.Problem(message: e == EADDRINUSE ? "Port \(port) is in use on this Mac" : "Can't listen on port \(port): \(String(cString: strerror(e)))")
        }
        for (family, host) in [(AF_INET, "0.0.0.0"), (AF_INET6, "::")] {   // IPv4's wildcard: a dual-stack [::] too
            let probe = Self.bound(family, host, port)
            guard probe.fd >= 0 else { throw taken(probe.error) }
            close(probe.fd)
        }
        let v4 = Self.bound(AF_INET, "127.0.0.1", port)
        guard v4.fd >= 0 else { throw taken(v4.error) }
        var a = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(v4.fd, $0, &len) } }
        let actual = Int(UInt16(bigEndian: a.sin_port))
        let v6 = Self.bound(AF_INET6, "::1", actual)
        let fds = [v4.fd] + (v6.fd >= 0 ? [v6.fd] : [])
        if v6.fd < 0 || fds.contains(where: { listen($0, 64) != 0 }) {
            let e = v6.fd < 0 ? v6.error : errno
            fds.forEach { close($0) }
            throw taken(e)
        }
        (self.port, self.child, self.onEvent) = (actual, child, onEvent)
        let queue = DispatchQueue(label: "kermo.tunnel")
        for fd in fds {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll(fd) }
            source.setCancelHandler { [closed] in   // a source's fd closes once it no longer watches it
                close(fd)
                closed.signal()
            }
            source.resume()
            sources.append(source)
        }
    }

    deinit { sources.forEach { $0.cancel() } }

    /// Closes the port — it's free when this returns, to listen on again — and stops logins under way. With
    /// `keepConnections` (the screen locked: like open sessions, they live on) that's all; else the children get SIGTERM
    /// and their clients see the end. Again later: ends those kept.
    public func stop(keepConnections: Bool = false) {
        let (sources, logins, live) = lock.withLock { () -> ([DispatchSourceRead], [CancelFlag], [Process]) in
            defer { (self.sources, stopped) = ([], true) }
            return (self.sources, self.logins, self.live)
        }
        logins.forEach { $0.cancel() }
        sources.forEach { $0.cancel() }
        for _ in sources { _ = closed.wait(timeout: .now() + 2) }   // an accept under way finishes first: a moment
        if !keepConnections { live.forEach { $0.terminate() } }
    }

    /// A terminal's shell starts by a fork (SwiftTerm's `forkpty`), and every descriptor open then that isn't
    /// close-on-exec yet goes with it: a socket caught between `socket()` (or `accept()`) and its FD_CLOEXEC stayed
    /// open in that shell — its port taken, its connection held — for as long as the shell ran (D-090). Those two steps
    /// and a fork (`forking`) never overlap.
    private static let halfMade = NSLock()
    public static func forking<T>(_ fork: () throws -> T) rethrows -> T { try halfMade.withLock(fork) }

    /// Nobody listens on `port` here (as `init` sees it), without listening on it.
    public static func isFree(_ port: Int) -> Bool {
        for (family, host) in [(AF_INET, "0.0.0.0"), (AF_INET6, "::"), (AF_INET, "127.0.0.1"), (AF_INET6, "::1")] {
            let b = bound(family, host, port)
            guard b.fd >= 0 else { return false }
            close(b.fd)
        }
        return true
    }

    /// The first free port after `port`, for "Use 15433": never taken silently, the user picks it.
    public static func freePort(after port: Int) -> Int? {
        port < 65535 ? (port + 1...min(port + 100, 65535)).first(where: isFree) : nil
    }

    /// A TCP socket bound to host:port, SO_REUSEADDR (else a port stays taken while its old connections sit in
    /// TIME_WAIT), close-on-exec (a child — an ssh master that outlives the tunnel, a terminal's shell — must never keep
    /// the port); IPv6 for itself alone.
    private static func bound(_ family: Int32, _ host: String, _ port: Int) -> (fd: Int32, error: Int32) {
        let (fd, e) = halfMade.withLock { () -> (Int32, Int32) in
            let fd = socket(family, SOCK_STREAM, 0), e = errno
            if fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (fd, e)
        }
        guard fd >= 0 else { return (-1, e) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        let r: Int32
        if family == AF_INET6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = UInt16(port).bigEndian
            _ = inet_pton(AF_INET6, host, &a.sin6_addr)
            r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var a = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: UInt16(port).bigEndian,
                                sin_addr: in_addr(s_addr: inet_addr(host)), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard r == 0 else {
            let e = errno
            close(fd)
            return (-1, e)
        }
        return (fd, 0)
    }

    private func acceptAll(_ fd: Int32) {
        while true {
            let (c, e) = Self.halfMade.withLock { () -> (Int32, Int32) in
                let c = accept(fd, nil, nil), e = errno
                if c >= 0 { _ = fcntl(c, F_SETFD, FD_CLOEXEC) }   // another connection's child mustn't hold this one open
                return (c, e)
            }
            if c < 0 {
                if e == EINTR || e == ECONNABORTED { continue }
                if e == EMFILE || e == ENFILE { usleep(100_000) }   // out of files: not a busy loop meanwhile
                return   // EAGAIN: none left
            }
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)   // BSD hands the listener's O_NONBLOCK on: not for the child
            onEvent(.opened)
            lock.withLock { count += 1 }
            Thread { [self] in serve(c) }.start()
        }
    }

    /// One connection: its child (a login may come first), then waiting for it to end.
    private func serve(_ c: Int32) {
        let sock = FileHandle(fileDescriptor: c, closeOnDealloc: true), flag = CancelFlag()
        var failure: String?
        defer {
            try? sock.close()
            if !lock.withLock({ stopped }) { onEvent(.closed(failure: failure)) }
            lock.withLock {
                count -= 1
                logins.removeAll { $0 === flag }
            }
        }
        guard lock.withLock({ () -> Bool in
            if !stopped { logins.append(flag) }
            return !stopped
        }) else { return }
        let spec: Child
        do { spec = try child(flag) } catch {
            if !(error is CancellationError) && !flag.isCancelled { failure = error.localizedDescription }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: spec.executable)
        p.arguments = spec.arguments
        if let env = spec.environment { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        p.standardInput = sock
        p.standardOutput = sock
        let err = Pipe()
        p.standardError = err
        let started = lock.withLock { () -> Result<Void, Error>? in   // under the lock: `stop` ends whatever has started
            guard !stopped else { return nil }
            do { try p.run() } catch { return .failure(error) }
            live.append(p)
            return .success(())
        }
        try? sock.close()   // the child has it: ours would keep the client from ever seeing the end
        try? err.fileHandleForWriting.close()
        guard case .success = started else {
            if case .failure(let e) = started { failure = "Can't run \(spec.executable): \(e.localizedDescription)" }
            return
        }
        let said = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        lock.withLock { live.removeAll { $0 === p } }
        failure = spec.failure(p.terminationStatus, String(decoding: said, as: UTF8.self))
    }
}
