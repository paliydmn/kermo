import Foundation

/// Where to connect: an ssh host (alias from ~/.ssh/config or user@host), or — for tests — a local
/// sftp-server spoken to directly, no ssh involved.
public struct SFTPTarget: Sendable, Hashable, Codable {
    public let host: String
    public let port: Int?
    public let identity: String?   // private key file; nil = ssh's own choice (agent, ~/.ssh/config, defaults)
    /// Seconds the shared connection outlives its last session (nil = 600). Anyone running as this user can ride
    /// on it without logging in, so a locked server keeps it short.
    public let persist: Int?
    /// A root panel's: the server's sftp-server run through its `sudo` (`SudoServer`), on the same connection.
    /// Never decoded either: whatever is pasted, dropped or restored opens a server as its user, never as root.
    public private(set) var sudo = false
    /// Tests only. Never decoded: a pasteboard item or saved state naming a local program to run must not work.
    private(set) var localServer: String? = nil
    /// Tests only, never decoded: the stand-in `sudo` a root `.local()` target runs, and whether it says SELinux is on.
    private(set) var localSudo: String? = nil
    private(set) var localSELinux = false
    private enum CodingKeys: String, CodingKey { case host, port, identity, persist }

    public init(host: String, port: Int? = nil, identity: String? = nil, persist: Int? = nil) {
        self.host = host
        self.port = port
        self.identity = identity
        self.persist = persist
    }

    /// `sudo`: a stand-in for the server's sudo (a script), which makes it a root target.
    public static func local(server: String = "/usr/libexec/sftp-server", persist: Int? = nil, sudo: String? = nil,
                             selinux: Bool = false) -> SFTPTarget {
        var t = SFTPTarget(host: "localhost", persist: persist)
        t.localServer = server
        t.localSudo = sudo
        t.sudo = sudo != nil
        t.localSELinux = selinux
        return t
    }

    /// The same server as root (a root panel), or as its user.
    public func asRoot(_ root: Bool = true) -> SFTPTarget {
        var t = self
        t.sudo = root
        return t
    }

    /// Same server, same account: what the two connect to, not how (key, how long the login lingers). Another alias
    /// of one machine still looks like another server — a move between them must not rely on this alone. No port
    /// is whatever ~/.ssh/config says, not 22. Root and its user are two accounts: a copy between them goes through
    /// this Mac, with each side's own rights.
    public func isSameServer(as o: SFTPTarget) -> Bool {
        host == o.host && port == o.port && localServer == o.localServer && sudo == o.sudo
    }

    /// Port and key, then the host. The key alone: not every other one the agent holds.
    func arguments() -> [String] {
        (port.map { ["-p", String($0)] } ?? [])
            + (identity.map { ["-i", ($0 as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] } ?? [])
            + ["--", host]
    }
}

public struct SFTPError: LocalizedError {
    public let message: String
    /// Couldn't reach or log in to the server at all (as opposed to a failing command).
    public var connection = false
    /// The SFTP status code, when a server answered with one (SFTPClient).
    public var code: UInt32? = nil
    public var errorDescription: String? { message }
}

/// Remote file access over the system OpenSSH `ssh` (SFTPClient), so everything in ~/.ssh/config
/// (keys, agent, ProxyJump, known_hosts) just works. One connection is shared via ControlMaster,
/// so each session after the first costs a round trip, not a login.
public enum SFTP {
    /// Short path: unix socket paths are limited to 104 bytes, and ssh adds 17 while creating one (so not $TMPDIR).
    /// /tmp is shared, and the askpass script and mux sockets live here: use the predictable name only if that
    /// folder is really ours (another user may have made it first), else a fresh random one.
    public static let controlDir: String = {
        let dir = "/tmp/dfm-ssh-\(getuid())"
        mkdir(dir, 0o700)
        var s = stat()
        // Sticky /tmp: once it's ours, nobody else can rename or replace it.
        if lstat(dir, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid(), chmod(dir, 0o700) == 0 { return dir }
        var template = Array("/tmp/dfm-ssh-XXXXXXXX".utf8CString)
        return template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!).map { String(cString: $0) } }
            ?? NSTemporaryDirectory() + "dfm-ssh-unavailable"   // too long for sockets: ssh fails cleanly
    }()

    /// Shared by SFTP sessions and the SSH tabs: whichever logs in first, the other rides on its connection.
    static func connectionOptions(_ t: SFTPTarget) -> [String] {
        ["-o", "ControlMaster=auto", "-o", "ControlPath=\(controlDir)/%C", "-o", "ControlPersist=\(t.persist ?? 600)",
         "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30"]
    }

    /// The shared connection's own log (`ssh -E`): its login errors, and once it runs in the background (stderr is
    /// /dev/null there) why it refused to open a channel — a tunnel's `channel 2: open failed: …`, which no client
    /// riding it is told. One per server in `controlDir` (0700; the file 0600), started afresh with each master; ssh
    /// doesn't expand %C in -E, so the name is made here from the host and port.
    // ponytail: two names of one connection (an alias and its user@host: one %C) keep two files, and a reason written
    // to the other is missed (the generic text instead); `ssh -G` per name would tell them apart.
    public static func masterLog(_ t: SFTPTarget) -> String {
        let name = "\(t.host)_\(t.port ?? 22)".unicodeScalars.map { c -> Character in
            c.isASCII && (CharacterSet.alphanumerics.contains(c) || "@._-".unicodeScalars.contains(c)) ? Character(c) : "_"
        }
        return controlDir + "/log-" + String(name.prefix(200))
    }

    /// What starts the master, between the connection options and the target.
    static func masterArguments(_ t: SFTPTarget) -> [String] { ["-E", masterLog(t), "-f", "-N"] }

    /// A session's own ssh never stays behind as the ControlMaster, so without an SSH tab every listing would be a
    /// fresh login. Start a background master once; it lives ControlPersist seconds past the last use. If it can't
    /// connect or log in, throws ssh's reason (trying again with the session's ssh would only double the wait).
    public static func startMaster(_ t: SFTPTarget, env: [String: String], cancel: CancelFlag? = nil) throws {
        guard t.localServer == nil else { return }
        noteMaster(t)
        func ssh(_ args: [String], stderr: FileHandle = .nullDevice, extra: [String: String] = [:]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = connectionOptions(t) + args + t.arguments()
            p.environment = ProcessInfo.processInfo.environment.merging(env.merging(extra) { $1 }) { $1 }
            p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = stderr
            guard (try? p.run()) != nil else { return -1 }
            let previous = cancel?.onCancel { p.terminate() } ?? nil
            p.waitUntilExit()   // -f: returns once logged in
            cancel?.onCancel(previous)
            return p.terminationStatus
        }
        if ssh(["-O", "check"]) == 0 { return }
        guard let login = beginLogin(t, cancel: cancel) else { throw CancellationError() }
        defer { login.end() }
        if ssh(["-O", "check"]) == 0 { return }   // the login waited for brought it up
        // Its log afresh; what ssh says on stderr before it goes to the background (a server's banner) lands there too.
        // A file, not a pipe: the backgrounded master would hold a pipe open forever.
        let log = masterLog(t)
        let fd = open(log, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd >= 0 { fchmod(fd, 0o600) }
        let errors = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : .nullDevice
        let status = withPassword(t) { ssh(masterArguments(t), stderr: errors, extra: $0) }   // ControlMaster=auto makes it the master
        try? errors.close()
        // Another listing may have become the master meanwhile; then this one only lost the race.
        let up = status == 0 || ssh(["-O", "check"]) == 0
        let why = up ? "" : String(decoding: FileManager.default.contents(atPath: log) ?? Data(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).filter { !$0.contains("Warning: Permanently added") }.joined(separator: "\n")
        if !up { unlink(log) }   // no master: nothing more will come
        if cancel?.isCancelled == true { throw CancellationError() }
        guard !up else { return }
        // ponytail: no fallback once the master failed with a message; add one if a server ever refuses `-N` but serves sftp.
        if !why.isEmpty { throw SFTPError(message: why, connection: true) }   // else the session's ssh tries and says why
    }

    /// The shared connection to `t` is up (`ssh -O check`): what rides on it needs no login.
    public static func isConnected(_ t: SFTPTarget) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = connectionOptions(t) + ["-O", "check"] + t.arguments()
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// A login to one server under way in this app: a background master (`startMaster`), or an SSH tab's ssh asking
    /// in the tab. Another waits for it, then rides its connection — two at once asked for the password twice, and
    /// the master that lost the socket stayed out of Disconnect's and ⌘Q's reach.
    public final class Login: @unchecked Sendable {
        let key: String
        private var ended = false
        init(key: String) { self.key = key }
        public func end() {
            SFTP.loginCond.withLock {
                guard !ended else { return }
                ended = true
                SFTP.loggingIn.remove(key)
                SFTP.loginCond.broadcast()
            }
        }
    }
    private static let loginCond = NSCondition()
    nonisolated(unsafe) private static var loggingIn = Set<String>()

    /// Waits for a login to `t` under way here (up to two minutes: a password prompt left open), then starts one.
    /// nil once `cancel` is set.
    public static func beginLogin(_ t: SFTPTarget, cancel: CancelFlag?) -> Login? {
        let key = "\(t.host):\(t.port ?? 0):\(t.localServer ?? "")"   // isSameServer, root or not: one connection
        let deadline = Date().addingTimeInterval(120)
        loginCond.lock()
        defer { loginCond.unlock() }
        while loggingIn.contains(key), Date() < deadline {
            if cancel?.isCancelled == true { return nil }
            _ = loginCond.wait(until: min(deadline, Date().addingTimeInterval(0.2)))
        }
        if cancel?.isCancelled == true { return nil }
        loggingIn.insert(key)
        return Login(key: key)
    }

    private static let mastersLock = NSLock()
    nonisolated(unsafe) private static var masters = Set<SFTPTarget>()

    /// Servers that may have a shared, logged-in connection from this app (an SSH tab makes one too).
    public static func noteMaster(_ t: SFTPTarget) { mastersLock.withLock { _ = masters.insert(t) } }
    public static var masterTargets: Set<SFTPTarget> { mastersLock.withLock { masters } }

    /// Ends the shared connection, which otherwise outlives its last session by ControlPersist (anyone running as
    /// this user could ride it meanwhile). `now`: at once, with whatever still runs on it (quitting); else it takes
    /// no new sessions and goes when the last one (a transfer, a follow) ends. Blocks briefly.
    public static func stopMaster(_ t: SFTPTarget, now: Bool) {
        guard t.localServer == nil, mastersLock.withLock({ masters.remove(t) }) != nil else { return }
        unlink(masterLog(t))   // first: a master started right after this one goes begins a file of its own
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = connectionOptions(t) + ["-O", now ? "exit" : "stop"] + t.arguments()
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }

    /// A saved password for the target, if any (the app's Keychain). Set once at launch; called off the main thread,
    /// only when a login is due.
    nonisolated(unsafe) public static var password: (@Sendable (SFTPTarget) -> String?)?

    /// A root panel's sudo password, when its server's sudo wants one (`SudoServer`): saved or asked for; `wrong`: the
    /// one given before was refused. nil: none given. Set once at launch; called off the main thread, one at a time.
    nonisolated(unsafe) public static var sudoPassword: (@Sendable (SFTPTarget, _ wrong: Bool) -> String?)?
    /// That sudo took it (worth keeping).
    nonisolated(unsafe) public static var sudoPasswordTaken: (@Sendable (SFTPTarget, String) -> Void)?

    /// Runs `login` with the target's saved password waiting for the askpass script in a FIFO ($DFM_ASKPASS_FIFO):
    /// not an environment variable (those show in `ps eww`), not a file. Read once, then gone, so a wrong password's
    /// second prompt asks the user. Gone when `login` returns, read or not.
    /// Only the target's own prompt gets it ($DFM_ASKPASS_FOR, see `askpassSavedPassword`): a ProxyJump bastion's
    /// ssh asks through the same askpass. If ssh can't say how it will name the target, the user is asked.
    static func withPassword<T>(_ t: SFTPTarget, _ login: ([String: String]) throws -> T) rethrows -> T {
        guard let secret = password?(t), let who = promptLogin(t) else { return try login([:]) }
        return try withSecret(secret, for: who, login)
    }

    static func withSecret<T>(_ secret: String, for who: String, _ login: ([String: String]) throws -> T) rethrows -> T {
        let path = controlDir + "/pw-" + UUID().uuidString
        guard mkfifo(path, 0o600) == 0 else { return try login([:]) }
        let done = CancelFlag()
        let writer = Thread {
            while !done.isCancelled {
                let fd = open(path, O_WRONLY | O_NONBLOCK)   // fails until askpass opens it for reading
                if fd < 0 { usleep(20_000); continue }
                unlink(path)
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                _ = secret.withCString { write(fd, $0, strlen($0)) }
                close(fd)
                return
            }
        }
        writer.start()
        defer {
            done.cancel()
            unlink(path)
        }
        return try login(["DFM_ASKPASS_FIFO": path, "DFM_ASKPASS_FOR": who])
    }

    /// The askpass script's first line: the saved password answers ssh's own prompts for the expected login only,
    /// "user@host's password: " and keyboard-interactive "(user@host) Password:". Anything else falls through (the dialog).
    public static let askpassSavedPassword = #"""
        case "$1" in "$DFM_ASKPASS_FOR's password: "|"($DFM_ASKPASS_FOR) "*assword*) [ -n "$DFM_ASKPASS_FOR" ] && [ -p "$DFM_ASKPASS_FIFO" ] && exec cat "$DFM_ASKPASS_FIFO";; esac
        """#

    /// user@host the way ssh names the target in its prompts: `ssh -G`'s user and HostKeyAlias, else HostName
    /// (a ~/.ssh/config alias resolved, lowercased). Doesn't connect.
    static func promptLogin(_ t: SFTPTarget) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-G"] + connectionOptions(t) + t.arguments()
        let out = Pipe()
        p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? promptLogin(sshG: String(decoding: data, as: UTF8.self)) : nil
    }

    static func promptLogin(sshG: String) -> String? {
        var o: [Substring: Substring] = [:]
        for line in sshG.split(separator: "\n") {
            let kv = line.split(separator: " ", maxSplits: 1)
            if kv.count == 2, o[kv[0]] == nil { o[kv[0]] = kv[1] }
        }
        guard let user = o["user"], let host = o["hostkeyalias"] ?? o["hostname"] else { return nil }
        return "\(user)@\(host)"
    }

    /// The login folder. `kept`: on that session (a server panel's), not a new one.
    public static func home(_ t: SFTPTarget, env: [String: String] = [:], cancel: CancelFlag? = nil, on kept: KeptSession? = nil) throws -> String {
        try session(t, env: env, cancel: cancel, on: kept) { try $0.realpath(".") }
    }

    /// Over SFTP itself (READDIR): names come as the server's bytes, never through `ls` text or sftp's globbing.
    /// `owners` hears each item's owner and group: the server's names where its `ls -l` line has them, else numbers.
    /// `links` hears where each symlink points and the errno following it gives (0: there). `kept`: as in `home`.
    public static func list(_ t: SFTPTarget, _ dir: String, env: [String: String] = [:], cancel: CancelFlag? = nil,
                            owners: ((_ name: String, _ owner: String, _ group: String) -> Void)? = nil,
                            links: ((_ name: String, _ target: String, _ error: Int32) -> Void)? = nil,
                            on kept: KeptSession? = nil) throws -> [FileItem] {
        try session(t, env: env, cancel: cancel, on: kept) { c in
            var items = try c.list(dir, owners: owners).filter { FileJob.isSafeName($0.name) }.map { name, a in
                FileItem(name: name, kind: a.kind, size: a.size, mtime: a.mtime, mode: a.type | (a.mode ?? 0), flags: 0,
                         uid: a.uid ?? FileItem.unknown, gid: a.gid ?? FileItem.unknown)
            }
            if let links {
                let found = c.targets(items.filter { $0.kind == .link }.map { (dir as NSString).appendingPathComponent($0.name) })
                for i in items.indices where items[i].kind == .link {
                    guard let f = found[(dir as NSString).appendingPathComponent(items[i].name)] else { continue }
                    items[i].linkDir = f.dir
                    links(items[i].name, f.target, f.error)
                }
            }
            return items
        }
    }

    /// One SFTP session for `body` (or the `kept` one). Cancelled, it throws CancellationError, not the "connection
    /// closed" of the session the cancel closed (the panel tells those apart).
    public static func session<T>(_ t: SFTPTarget, env: [String: String], cancel: CancelFlag?, on kept: KeptSession?,
                                  _ body: (SFTPClient) throws -> T) throws -> T {
        let flag = cancel ?? CancelFlag()
        do {
            if let kept { return try kept.run(env: env, cancel: flag, body) }
            return try SFTPClient.session(t, env: env, cancel: flag, body)
        } catch where flag.isCancelled { throw CancellationError() }
    }

    /// The type letter of a special file → its S_IFMT type (kept in `mode`; see FileItem).
    static let special: [String: mode_t] = ["c": S_IFCHR, "b": S_IFBLK, "p": S_IFIFO, "s": S_IFSOCK]
}

/// A server panel's SFTP session, kept from one listing to the next: a session each was an `ssh -O check`, an ssh
/// process and a handshake (some 0.1 s on a LAN, 4 round trips far away). The same one while it's connected, a new one
/// once it isn't: closed, its ssh gone, or stopped with its master after sleep or a network change (`closeAll`) —
/// riding a dead connection, a listing would wait ~90 s for ssh to notice. One call at a time. A cancelled call closes
/// it at once (a listing leaves nothing to tidy up on the server); the next call connects again.
public final class KeptSession: @unchecked Sendable {
    public let target: SFTPTarget
    private let calls = NSLock()   // held through a call: a client is one thread's at a time
    private let lock = NSLock()    // `client`: closing never waits for a call
    private(set) var client: SFTPClient?
    nonisolated(unsafe) private static let all = NSHashTable<KeptSession>.weakObjects()
    private static let allLock = NSLock()

    public init(_ target: SFTPTarget) {
        self.target = target
        Self.allLock.withLock { Self.all.add(self) }
    }

    deinit { client?.close() }   // else its reader thread keeps the client, and the ssh, alive

    func run<T>(env: [String: String], cancel: CancelFlag, _ body: (SFTPClient) throws -> T) throws -> T {
        try calls.withLock {
            let c: SFTPClient
            if let live = lock.withLock({ client }), live.isConnected {
                c = live
            } else {
                c = try SFTPClient(target, env: env, cancel: cancel)
                lock.withLock { client = c }
            }
            let previous = cancel.onCancel { c.close() }
            defer { cancel.onCancel(previous) }
            return try body(c)
        }
    }

    public func close() { lock.withLock { client }?.close() }

    /// Every kept session to `t`'s server (`isSameServer`): its connection is being stopped.
    public static func closeAll(on t: SFTPTarget) {
        for k in allLock.withLock({ all.allObjects }) where k.target.isSameServer(as: t) { k.close() }
    }
}

/// An interactive session through the system `ssh` (it reads ~/.ssh/config, the agent, known_hosts itself).
public enum SSHCommand {
    /// The SSH tab's ssh shares the sftp connection (ControlMaster), so one password covers both.
    /// `command` runs instead of a login shell (`tty`: with a terminal, for anything interactive).
    public static func arguments(_ t: SFTPTarget, command: String? = nil, tty: Bool = true) -> [String] {
        SFTP.connectionOptions(t) + (command == nil ? [] : [tty ? "-t" : "-T"]) + t.arguments() + (command.map { [$0] } ?? [])
    }

    /// A remote command line: `command` in `dir` (the server's login shell parses it; `dir` is quoted for it).
    public static func inDir(_ dir: String, _ command: String) -> String {
        "cd -- \(ShellContext.quote(dir)) && " + command
    }

    /// Runs `command` on the server without a terminal (its login shell parses it), handing stdout over as it
    /// arrives; the test target (`.local()`) runs it here with /bin/sh. Returns the exit status and stderr.
    /// `stdin`: what the command reads, then end of file (a secret goes this way: never in its command line); none
    /// by default. `options`: ssh's, before the host.
    public static func run(_ t: SFTPTarget, _ command: String, env: [String: String] = [:], cancel: CancelFlag? = nil,
                           options: [String] = [], stdin: Data? = nil, onOutput: (Data) -> Void) throws -> (status: Int32, errors: String) {
        try SFTP.startMaster(t, env: env, cancel: cancel)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: t.localServer == nil ? "/usr/bin/ssh" : "/bin/sh")
        p.arguments = t.localServer == nil ? SFTP.connectionOptions(t) + options + ["-T"] + t.arguments() + [command] : ["-c", command]
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let out = Pipe(), err = Pipe(), input = stdin.map { _ in Pipe() }
        p.standardInput = input ?? FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err
        try p.run()
        try? out.fileHandleForWriting.close()   // our copies: else EOF never comes
        try? err.fileHandleForWriting.close()
        if let input, let stdin {
            try? input.fileHandleForReading.close()
            let fd = input.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)   // a command that doesn't read it all: EPIPE, not a killed app
            // On a thread of its own: more than a pipe holds waits for the command, which may wait for us to read.
            Thread {
                stdin.withUnsafeBytes { b in
                    var off = 0
                    while off < b.count {
                        let n = Darwin.write(fd, b.baseAddress! + off, b.count - off)
                        if n < 0 && errno == EINTR { continue }
                        if n <= 0 { break }
                        off += n
                    }
                }
                try? input.fileHandleForWriting.close()
            }.start()
        }
        let previous = cancel?.onCancel { p.terminate() } ?? nil
        defer { cancel?.onCancel(previous) }
        nonisolated(unsafe) var errData = Data()
        let errReader = Thread { errData = err.fileHandleForReading.readDataToEndOfFile() }
        errReader.start()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = Darwin.read(out.fileHandleForReading.fileDescriptor, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            onOutput(Data(buf[0..<n]))
        }
        p.waitUntilExit()
        while !errReader.isFinished { usleep(1000) }
        if cancel?.isCancelled == true { throw CancellationError() }
        let errors = String(decoding: errData, as: UTF8.self).split(separator: "\n").filter { !$0.contains("Warning: Permanently added") }
        return (p.terminationStatus, errors.joined(separator: "\n"))
    }

    /// `run`'s whole output; a failure throws what it said.
    public static func capture(_ t: SFTPTarget, _ command: String, env: [String: String] = [:], cancel: CancelFlag? = nil,
                               stdin: Data? = nil) throws -> String {
        var out = Data()
        let (status, errors) = try run(t, command, env: env, cancel: cancel, stdin: stdin) { out += $0 }
        guard status == 0 else { throw SFTPError(message: errors.isEmpty ? "“\(command)” failed (exit \(status))" : errors) }
        return String(decoding: out, as: UTF8.self)
    }

    /// `run`'s output; nil if it failed or ran over `timeout` (a server that stopped answering).
    public static func output(_ t: SFTPTarget, _ command: String, env: [String: String] = [:], timeout: TimeInterval = 30) -> Data? {
        let flag = CancelFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { flag.cancel() }
        var data = Data()
        guard let (status, _) = try? run(t, command, env: env, cancel: flag, onOutput: { data += $0 }), status == 0 else { return nil }
        return data
    }

    /// Prints the server's `path` from byte `size` on and keeps following it by name, through rotation (F3 + f).
    public static func follow(_ path: String, after size: Int64) -> String {
        "tail -c +\(size + 1) -F -- \(ShellContext.quote(path))"
    }

    /// An interactive shell in `dir`, after `command` if any (⌘↩ on the command line, ⌃O on a server panel).
    public static func shell(in dir: String, after command: String? = nil) -> String {
        (command.map { inDir(dir, $0) } ?? "cd -- \(ShellContext.quote(dir))") + "; exec \"$SHELL\" -l"
    }

    /// What to paste into a terminal.
    public static func line(_ t: SFTPTarget) -> String {
        (["ssh"] + t.arguments()).map(ShellContext.quote).joined(separator: " ")
    }

    /// A raw wait(2) status, for the "disconnected" line.
    public static func describe(status s: Int32) -> String {
        if s & 0x7f != 0 { return "ssh ended by signal \(s & 0x7f)" }
        let code = (s >> 8) & 0xff
        return code == 0 ? "Connection closed" : "ssh exited with status \(code)"
    }
}

/// Host aliases from ~/.ssh/config (following Include), for the Connect picker.
public enum SSHConfig {
    public struct Host: Sendable, Equatable {
        public var alias: String
        public var hostName: String?
        public var user: String?
        public var port: Int?
    }

    public static func hosts(file: String = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")) -> [Host] {
        var out: [Host] = []
        var seen = Set<String>()
        parse(file, depth: 0, into: &out, seen: &seen)
        return out
    }

    private static func parse(_ file: String, depth: Int, into out: inout [Host], seen: inout Set<String>) {
        guard depth < 5, let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
        var current: [Int] = []   // indices in `out` the following options apply to
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch key {
            case "host":
                current = []
                for alias in value.split(whereSeparator: \.isWhitespace).map(String.init)
                where !alias.contains(where: { "*?!".contains($0) }) && seen.insert(alias).inserted {
                    out.append(Host(alias: alias))
                    current.append(out.count - 1)
                }
            case "match":
                current = []
            case "hostname": for i in current where out[i].hostName == nil { out[i].hostName = value }
            case "user": for i in current where out[i].user == nil { out[i].user = value }
            case "port": for i in current where out[i].port == nil { out[i].port = Int(value) }
            case "include":
                for pattern in value.split(whereSeparator: \.isWhitespace) {
                    var p = (String(pattern) as NSString).expandingTildeInPath
                    if !p.hasPrefix("/") { p = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/" + p) }
                    var g = glob_t()
                    defer { globfree(&g) }
                    if glob(p, 0, nil, &g) == 0 {
                        for i in 0..<Int(g.gl_pathc) {
                            if let c = g.gl_pathv[i] { parse(String(cString: c), depth: depth + 1, into: &out, seen: &seen) }
                        }
                    }
                }
            default: break
            }
        }
    }
}

/// What the user typed in Connect to Server.
public enum ServerAddress: Equatable {
    case sftp(SFTPTarget, path: String?)
    case mount(URL)

    /// "user@host:/path", "host", "host:2222[:/path]", "[fe80::1]:2222", "sftp://user@host:2222/path" → SFTP;
    /// "smb://…", "nfs://…", "afp://…" → mount.
    /// nil for a host starting with "-": that's an ssh option (-oProxyCommand=…), never a server.
    public static func parse(_ input: String) -> ServerAddress? {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if let url = URL(string: s), let scheme = url.scheme?.lowercased() {
            if scheme == "sftp" || scheme == "ssh", lower.hasPrefix(scheme + "://") {
                // "sftp://:22", "ssh://u@[]/x": Foundation's host is "" (not nil) for an authority with no host; "sftp://",
                // "sftp:///x": nil — the scheme alone isn't one. "ssh:2222" (no "//") is a host named ssh, scp-style below.
                guard let host = url.host, !host.isEmpty, !host.hasPrefix("-") else { return nil }
                let userHost = url.user.map { "\($0)@\(host)" } ?? host
                return .sftp(SFTPTarget(host: userHost, port: url.port), path: url.path.isEmpty ? nil : url.path)
            }
            if ["smb", "cifs", "nfs", "afp", "webdav", "http", "https", "ftp"].contains(scheme) { return .mount(url) }
        } else if lower.hasPrefix("sftp://") || lower.hasPrefix("ssh://") {
            return nil   // "sftp://h x": not a URL, and the scheme isn't a host either
        }
        // [user@]host[:port][:path]; an IPv6 host in brackets ([::1]:2222:/etc) or bare and alone (fe80::1).
        let at = s[..<(s.firstIndex(of: ":") ?? s.endIndex)].firstIndex(of: "@").map { s.index(after: $0) } ?? s.startIndex
        var v6 = in6_addr()
        var host: String, rest: Substring
        if s[at...].hasPrefix("["), let close = s[at...].firstIndex(of: "]") {
            host = String(s[..<at] + s[s.index(after: at)..<close])
            rest = s[s.index(after: close)...]
            guard rest.isEmpty || rest.hasPrefix(":") else { return nil }
            rest = rest.dropFirst()
        } else if inet_pton(AF_INET6, String(s[at...]), &v6) == 1 {
            (host, rest) = (s, "")
        } else {
            let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            (host, rest) = (String(parts[0]), parts.count == 2 ? parts[1] : "")
        }
        // "::1:/etc", "[]", "u@[]:22", ":2222": no host to connect to.
        guard !host.hasPrefix("-"), host.count > s[..<at].count else { return nil }
        // Digits alone, or before ":/…" or ":~…", are a port; anything else after the host is a path (scp-style).
        let pieces = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var port: Int?
        if !pieces[0].isEmpty, pieces[0].allSatisfy({ $0.isASCII && $0.isNumber }),
           pieces.count == 1 || pieces[1].isEmpty || pieces[1].hasPrefix("/") || pieces[1].hasPrefix("~") {
            guard let p = Int(pieces[0]), (1...65535).contains(p) else { return nil }
            port = p
            rest = pieces.count == 2 ? pieces[1] : ""
        }
        return .sftp(SFTPTarget(host: host, port: port), path: rest.isEmpty ? nil : String(rest))
    }
}

