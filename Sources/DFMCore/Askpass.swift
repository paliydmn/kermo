import Darwin
import Foundation

/// ssh's questions — passwords, key passphrases, "continue connecting (yes/no)?" — asked by Kermo itself, in a sheet
/// on its window, instead of a dialog of another style. ssh runs the askpass script (`SSHAskpass`), which runs Kermo's
/// own executable as a client (`--askpass <prompt>`); the client hands the prompt to the running app over a unix
/// socket in `SFTP.controlDir` and prints its answer for ssh.
///
/// - The socket is in a folder only we can enter (0700, ours: `SFTP.controlDir`); a connection from another user
///   (`getpeereid`), or from a process this app didn't start (its parents, a few up), is refused.
/// - One question per connection; the request is read within `readWait`.
/// - The app says it took it (`taken`) within `ackWait`, or the client gives up (exit 2) and the script asks with its
///   own dialog, as before: a login never hangs on an app that doesn't answer. An app gone after that (it quit) is a
///   Cancel: no dialog is left behind it.
/// - The answer is written to the socket and forgotten: never logged, never kept.
/// - ssh gone (the client's parent): the client hangs up, and the app's question goes (`gone`).
///
/// Wire: request `prompt \0 why \0 target \0`; the app's `S` once taken, then `A` + the answer, or `C`; then close.
public enum Askpass {
    public struct Request: Sendable, Equatable {
        public let prompt: String, why: String, target: String
        public init(prompt: String, why: String = "", target: String = "") { (self.prompt, self.why, self.target) = (prompt, why, target) }
    }

    public static let maxRequest = 64 * 1024
    nonisolated(unsafe) public static var ackWait: TimeInterval = 5
    nonisolated(unsafe) public static var readWait: TimeInterval = 5

    // MARK: - The app's side

    /// Listens at `path` (replacing a socket left there) until `stop`. `ask`, on a thread of its own per question:
    /// call `taken` once the app has it, watch `gone` (the client hung up), return the answer or nil (Cancel).
    public final class Server: @unchecked Sendable {
        public let path: String
        private let fd: Int32
        private let ask: @Sendable (Request, _ taken: @escaping @Sendable () -> Void, _ gone: CancelFlag) -> String?
        /// Whether a client may ask: by default its uid is ours and this app started it (`descends`).
        nonisolated(unsafe) public var admits: @Sendable (Int32) -> Bool = { Askpass.descends($0, from: getpid()) }

        public init?(path: String, ask: @escaping @Sendable (Request, _ taken: @escaping @Sendable () -> Void, _ gone: CancelFlag) -> String?) {
            self.path = path
            self.ask = ask
            unlink(path)
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0, Askpass.withAddress(path, { bind(fd, $0, $1) }) == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
                if fd >= 0 { close(fd) }
                unlink(path)
                return nil
            }
            Thread { [self] in accepting() }.start()
        }

        public func stop() {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(path)
        }

        private func accepting() {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 {
                    if errno == EINTR { continue }
                    return   // stopped
                }
                Thread { [self] in serve(c) }.start()
            }
        }

        private func serve(_ c: Int32) {
            defer { close(c) }
            _ = fcntl(c, F_SETNOSIGPIPE, 1)
            var uid = uid_t(), gid = gid_t(), pid = pid_t(), size = socklen_t(MemoryLayout<pid_t>.size)
            guard getpeereid(c, &uid, &gid) == 0, uid == getuid(),
                  getsockopt(c, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, admits(pid),
                  let request = Askpass.readRequest(c) else { return }
            let gone = CancelFlag(), done = CancelFlag()
            Thread {   // the client hanging up (ssh gone) takes the question away
                var p = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
                while !done.isCancelled {
                    if poll(&p, 1, 200) > 0 { gone.cancel(); return }   // the client sends nothing more: data or hang-up, it's gone
                }
            }.start()
            let answer = ask(request, { _ = Askpass.write(c, "S") }, gone)
            done.cancel()
            guard !gone.isCancelled else { return }
            _ = Askpass.write(c, answer.map { "A" + $0 } ?? "C")
        }
    }

    /// `pid` is `root` or started by it, a few levels down (askpass ← sh ← ssh ← a ProxyJump's ssh ← git…).
    public static func descends(_ pid: pid_t, from root: pid_t) -> Bool {
        var p = pid
        for _ in 0..<8 {
            if p == root { return true }
            guard p > 1, let parent = parent(of: p) else { return false }
            p = parent
        }
        return false
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: - The client (`Kermo --askpass <prompt>`)

    /// Asks the app at `$DFM_ASKPASS_SOCKET`; `out` gets the answer for ssh. 0: answered, 1: cancelled (or ssh is
    /// gone), 2: the app didn't take it — the script asks with its own dialog.
    public static func client(prompt: String, env: [String: String], out: (String) -> Void) -> Int32 {
        guard let path = env["DFM_ASKPASS_SOCKET"], !path.isEmpty else { return 2 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return 2 }
        defer { close(fd) }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        guard withAddress(path, { connect(fd, $0, $1) }) == 0 else { return 2 }
        let request = [prompt, env["DFM_ASKPASS_WHY"] ?? "", env["DFM_ASKPASS_TARGET"] ?? ""].map { $0 + "\0" }.joined()
        guard write(fd, request) else { return 2 }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, Int32(ackWait * 1000)) > 0, read(fd, 1) == Data("S".utf8) else { return 2 }
        let ssh = parent(of: getppid())   // the script's: ssh (or git)
        while true {   // as long as it takes to type it, while ssh waits
            let r = poll(&p, 1, 500)
            if r > 0 { break }
            if r < 0 && errno != EINTR { return 2 }
            // ssh is gone (⎋, a closed tab): nobody to answer; hanging up takes the sheet away.
            if getppid() == 1 || ssh.map({ $0 <= 1 || kill($0, 0) != 0 }) == true { return 1 }
        }
        var reply = Data()
        while let more = read(fd, 4096), !more.isEmpty { reply += more }
        guard let kind = reply.first else { return 1 }   // the app went away after taking it (quit): no dialog left behind
        switch kind {
        case UInt8(ascii: "A"):
            out(String(decoding: reply.dropFirst(), as: UTF8.self))
            return 0
        default: return 1
        }
    }

    // MARK: - Wire

    static func readRequest(_ fd: Int32) -> Request? {
        var t = timeval(tv_sec: Int(readWait), tv_usec: Int32((readWait - floor(readWait)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        while data.filter({ $0 == 0 }).count < 3 {
            guard data.count < maxRequest, let more = read(fd, 4096), !more.isEmpty else { return nil }
            data += more
        }
        let parts = data.split(separator: 0, maxSplits: 3, omittingEmptySubsequences: false).prefix(3).map { String(decoding: $0, as: UTF8.self) }
        return Request(prompt: parts[0], why: parts[1], target: parts[2])
    }

    static func read(_ fd: Int32, _ max: Int) -> Data? {
        var buf = [UInt8](repeating: 0, count: max)
        let n = Darwin.read(fd, &buf, max)
        return n < 0 ? nil : Data(buf.prefix(n))
    }

    static func write(_ fd: Int32, _ s: String) -> Bool {
        let bytes = Array(s.utf8)
        var done = 0
        while done < bytes.count {
            let n = bytes[done...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            done += n
        }
        return true
    }

    static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: a.sun_path) else { errno = ENAMETOOLONG; return -1 }
        withUnsafeMutableBytes(of: &a.sun_path) { p in for (i, b) in bytes.enumerated() { p[i] = b } }
        a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }
}
