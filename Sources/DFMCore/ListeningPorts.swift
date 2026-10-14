import Foundation

/// A TCP port a server listens on, as `ss -ltnp` or `netstat -ltnp` (net-tools, busybox) say it: what Forward Port…
/// lists. Its IPv4 and IPv6 sockets are one port.
public struct ListeningPort: Equatable, Sendable {
    public var port: Int
    /// Where it listens: "*" for every address, "localhost" for 127.0.0.1 and ::1, else the address as the server
    /// wrote it (no brackets, no %interface) — in the order seen.
    public var addresses: [String]
    /// Its program, where the server shows it: `ss -p` and `netstat -p` show a user's own processes only.
    public var process: String?

    public init(port: Int, addresses: [String], process: String? = nil) {
        (self.port, self.addresses, self.process) = (port, addresses, process)
    }

    /// Where a tunnel to it goes, as the server sees it (`ssh -W`): localhost, unless it listens on another address alone.
    public var host: String { addresses.contains("*") || addresses.contains("localhost") ? "localhost" : addresses[0] }
    /// "all addresses", "localhost only", "192.0.2.10 only".
    public var reach: String { addresses.contains("*") ? "all addresses" : addresses.joined(separator: ", ") + " only" }
}

public enum ListeningPorts {
    /// The ports in `ss -ltn[p]`'s or `netstat -ltn[p]`'s output, by port. A line counts only if it starts with ss's
    /// `LISTEN` or netstat's `tcp` / `tcp6` (busybox writes `tcp` for IPv6 too): headers, warnings and whatever a login
    /// script printed are passed over.
    public static func parse(_ text: String) -> [ListeningPort] {
        var ports: [Int: ListeningPort] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let process: String?
            if words.first == "LISTEN", words.count >= 5 {   // State Recv-Q Send-Q Local Peer [users:(("name",pid=1,fd=3))]
                process = line.range(of: "users:((\"").flatMap { at in line[at.upperBound...].split(separator: "\"", maxSplits: 1).first.map(String.init) }
            } else if ["tcp", "tcp6"].contains(words.first), words.count >= 6, words[5] == "LISTEN" {   // Proto Recv-Q Send-Q Local Foreign State [PID/Program]
                let program = words.dropFirst(6).joined(separator: " ")
                process = program.firstIndex(of: "/").map { String(program[program.index(after: $0)...]) }.flatMap { $0.isEmpty ? nil : $0 }
            } else {
                continue
            }
            guard let (address, port) = local(words[3]) else { continue }
            var p = ports[port] ?? ListeningPort(port: port, addresses: [])
            if !p.addresses.contains(address) { p.addresses.append(address) }
            p.process = p.process ?? process
            ports[port] = p
        }
        return ports.values.sorted { $0.port < $1.port }
    }

    /// What runs there, in `sh` (the login shell may be any): ss if there is one, else netstat — each said by a line first
    /// (a login script may print before it) — and the sbin folders in PATH (ss is in /usr/sbin on Red Hat). ss without -H:
    /// an old one has no such option, and its header is passed over anyway.
    static let script = "PATH=\"$PATH:/usr/sbin:/sbin\"; if command -v ss >/dev/null 2>&1; then echo kermo-ss; exec ss -ltnp; "
        + "elif command -v netstat >/dev/null 2>&1; then echo kermo-netstat; exec netstat -ltnp; else echo kermo-none; fi"

    /// The ports `t`'s server listens on: one ssh command over its connection (a login first if it's down: the saved
    /// password, askpass — `env`). `server`: as the sidebar names it. Throws a failed login as ssh said it, and in plain
    /// words a server without ss or netstat, or one that failed.
    public static func read(on t: SFTPTarget, server: String, env: [String: String] = [:], cancel: CancelFlag? = nil) throws -> [ListeningPort] {
        var out = Data()
        let (status, errors) = try SSHCommand.run(t, "sh -c " + ShellContext.quote(script), env: env, cancel: cancel, options: ["-x", "-a"]) { out += $0 }
        return try outcome(status: status, output: String(decoding: out, as: UTF8.self), errors: errors, server: server).get()
    }

    /// What the script's run comes to: the tool's line, then its output (netstat's "not all processes" warning on stderr,
    /// exit 0, isn't a failure).
    static func outcome(status: Int32, output: String, errors: String, server: String) -> Result<[ListeningPort], SFTPError> {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let at = lines.firstIndex(where: { ["kermo-ss", "kermo-netstat", "kermo-none"].contains($0) }) else {
            return .failure(SFTPError(message: errors.isEmpty ? "Couldn't look at the ports of \(server) (exit \(status))" : errors))
        }
        let tool = lines[at].dropFirst("kermo-".count)
        if tool == "none" { return .failure(SFTPError(message: "\(server) has neither ss nor netstat to tell its ports")) }
        guard status == 0 else {
            return .failure(SFTPError(message: "\(tool) failed on \(server): " + (errors.isEmpty ? "exit \(status)" : errors)))
        }
        return .success(parse(lines[(at + 1)...].joined(separator: "\n")))
    }

    /// "127.0.0.53%lo:53", "*:80", "[::1]:631", "[::]%eth0:22", ":::22" (netstat's IPv6, no brackets): the port after the
    /// last ":".
    static func local(_ s: Substring) -> (String, Int)? {
        guard let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]), (1...65535).contains(port) else { return nil }
        var host = String(s[..<colon])
        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }   // ss: "[fe80::1]%eth0:22" too
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        switch host {
        case "*", "0.0.0.0", "::", "": return ("*", port)
        case "127.0.0.1", "::1": return ("localhost", port)
        default: return (host, port)
        }
    }
}
