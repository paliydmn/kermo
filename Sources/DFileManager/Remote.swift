import AppKit
import CryptoKit
import DFMCore
import LocalAuthentication
import NetFS
import Network
import Security

/// A server in ~/.config/dfilemanager/servers.json: the sidebar's Saved section.
struct SavedServer: Codable, Equatable {
    var id = UUID()
    var name = ""          // "" = the address
    var host = ""          // address or ~/.ssh/config alias
    var user: String?      // nil = ssh's (or ~/.ssh/config's) default
    var port: Int?
    var identityFile: String?  // private key; nil = ssh's own choice
    var startDir: String?      // SFTP; nil = the login folder
    var locked = false         // Touch ID / the Mac password to connect, edit or delete (ServerLock)
    var prod = false           // production: `color` in the sidebar and headers; delete, overwrite and move there ask first
    var tunnels: [Tunnel] = [] // ports on this Mac that lead to it, or past it (`Tunnels`)

    init() {}

    /// Prefilled from what was typed in Connect ("me@nas:/share", "sftp://h:2222/x") or a ~/.ssh/config alias.
    init?(address: String) {
        guard case let .sftp(t, path)? = ServerAddress.parse(address) else { return nil }
        let at = t.host.lastIndex(of: "@")   // ssh splits at the last one too
        host = at.map { String(t.host[t.host.index(after: $0)...]) } ?? t.host
        user = at.map { String(t.host[..<$0]) }
        port = t.port
        startDir = path
    }

    /// One never saved, as a saved one (a temporary tunnel's server): its address, nothing more.
    init(target t: SFTPTarget) {
        let at = t.host.lastIndex(of: "@")
        host = at.map { String(t.host[t.host.index(after: $0)...]) } ?? t.host
        user = at.map { String(t.host[..<$0]) }
        port = t.port
        identityFile = t.identity
    }

    /// Hand-edited files may leave out anything but the host.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decode(String.self, forKey: .host)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        startDir = try c.decodeIfPresent(String.self, forKey: .startDir)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        prod = try c.decodeIfPresent(Bool.self, forKey: .prod) ?? false
        tunnels = try c.decodeIfPresent([Tunnel].self, forKey: .tunnels) ?? []
    }

    /// Production's mark wherever it shows (sidebar, menus, a root panel's header, titles): purple, as red says something
    /// failed and orange is root's.
    static var color: NSColor { .systemPurple }
    static let mark = "🟣 PROD "

    /// A saved server at this address (user@host:port) is tagged production.
    /// A saved server's name for `t`, else its address: what questions and hints call it.
    @MainActor static func name(for t: SFTPTarget) -> String {
        ServerLock.servers().first { !$0.name.isEmpty && SSHPasswords.sameKey($0.target, t) }?.name ?? t.shown
    }
    @MainActor static func isProd(_ t: SFTPTarget) -> Bool { ServerLock.servers().contains { $0.prod && SSHPasswords.sameKey($0.target, t) } }

    /// A server file's editor title: "web:/etc/nginx/nginx.conf", "🟣 PROD web:/…" on a production server, "root@web:/… #"
    /// from a root panel.
    @MainActor static func title(_ t: SFTPTarget, _ path: String) -> String { (isProd(t) ? mark : "") + "\(t.shown):\(path)" + (t.sudo ? " #" : "") }

    /// Said before what a change on production servers asks: "“h” is a production server. ", or "".
    @MainActor static func prodNote(_ targets: [SFTPTarget]) -> String {
        let hosts = targets.filter(isProd).map(\.host).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return hosts.isEmpty ? "" : hosts.map { "“\($0)”" }.joined(separator: " and ") + (hosts.count == 1 ? " is a production server. " : " are production servers. ")
    }

    // ponytail: a locked server's connection lives while a panel shows it (the panel's kept SFTP session rides on it)
    // and lingers 60 s after its last session, not 0: a copy, a preview or a size count right after would log in
    // again. The lock itself is time-based (`ServerLock`). `ssh -O exit` on closing its last tab if 60 s is too long.
    var target: SFTPTarget {
        SFTPTarget(host: user.map { "\($0)@\(host)" } ?? host, port: port, identity: identityFile, persist: locked ? 60 : nil)
    }
    var title: String { name.isEmpty ? target.host : name }
    /// As a server picker lists it: locked and production said up front.
    var pickerTitle: String { (locked ? "🔒 " : "") + (prod ? Self.mark : "") + title }

    /// Why ssh can't take it, or nil. A leading "-" would make ssh read it as an option (-oProxyCommand=…).
    var problem: String? {
        if host.isEmpty { return "Enter a host." }
        if host.hasPrefix("-") || host.contains(where: { $0.isWhitespace || $0 == "@" }) { return "“\(host)” isn't a host name." }
        if let u = user, u.isEmpty || u.hasPrefix("-") || u.contains(where: \.isWhitespace) { return "“\(u)” isn't a user name." }
        if let p = port, !(1...65535).contains(p) { return "The port must be 1–65535." }
        if let k = identityFile, !FileManager.default.isReadableFile(atPath: (k as NSString).expandingTildeInPath) {
            return "Can't read the key file “\(k)”."
        }
        return Tunnel.problem(tunnels)
    }

    static func load() -> [SavedServer] {
        do { return try Config.load("servers.json", as: [SavedServer].self) ?? [] } catch {
            // Saving would overwrite a hand edit gone wrong: keep it aside.
            let path = Config.path("servers.json")
            try? FileManager.default.removeItem(atPath: path + ".broken")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".broken")
            return []
        }
    }
}

extension SFTPTarget {
    /// The same target as its user: a root panel's server, for what doesn't care which account looks (reloading the
    /// panels on it, the other panel's folder there, SSH tabs — a shell there is always the user's).
    var asUser: SFTPTarget { asRoot(false) }

    /// Who and where, as headers say it: the host as given, "root@host" for a root panel.
    var shown: String { sudo ? "root@" + (host.lastIndex(of: "@").map { String(host[host.index(after: $0)...]) } ?? host) : host }
}

/// SSH passwords in the login keychain: one per user@host:port, readable by this app without asking (others ask).
/// `sudo`: a root panel's sudo password there (`SudoPasswords`), an item of its own: neither ever reads the other.
enum SSHPasswords {
    private static func query(_ t: SFTPTarget, sudo: Bool) -> [CFString: Any] {
        if sudo { return [kSecClass: kSecClassGenericPassword, kSecAttrService: "Kermo sudo", kSecAttrAccount: SudoPasswords.key(t)] }
        let at = t.host.lastIndex(of: "@")
        return [kSecClass: kSecClassInternetPassword, kSecAttrProtocol: kSecAttrProtocolSSH,
                kSecAttrServer: at.map { String(t.host[t.host.index(after: $0)...]) } ?? t.host,
                kSecAttrAccount: at.map { String(t.host[..<$0]) } ?? "",
                kSecAttrPort: t.port ?? 22]
    }

    static func sameKey(_ a: SFTPTarget, _ b: SFTPTarget) -> Bool { a.host == b.host && (a.port ?? 22) == (b.port ?? 22) }

    /// Without reading it.
    static func has(_ t: SFTPTarget, sudo: Bool = false) -> Bool { SecItemCopyMatching(query(t, sudo: sudo) as CFDictionary, nil) == errSecSuccess }

    static func get(_ t: SFTPTarget, sudo: Bool = false) -> String? {
        var q = query(t, sudo: sudo)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// "" or nil forgets it.
    @discardableResult
    static func set(_ password: String?, for t: SFTPTarget, sudo: Bool = false) -> OSStatus {
        SecItemDelete(query(t, sudo: sudo) as CFDictionary)
        guard let password, !password.isEmpty else { return errSecSuccess }
        var q = query(t, sudo: sudo)
        q[kSecValueData] = Data(password.utf8)
        q[kSecAttrLabel] = "Kermo\(sudo ? " sudo" : ""): \(t.host)" + (t.port.map { ":\($0)" } ?? "")
        return SecItemAdd(q as CFDictionary, nil)
    }
}

/// Root panels' sudo passwords (`SFTP.sudoPassword`): asked for in a sheet, then kept in memory while in use — 5 minutes
/// after the last use, as sudo's own ticket — and forgotten when the screen locks, the Mac sleeps or the server is
/// disconnected. In the Keychain too if the sheet's "Save in Keychain" was ticked, once sudo took it; one sudo refuses
/// goes from there as well. One per user@host:port. Off the main thread: a session asks while it connects.
enum SudoPasswords {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var kept: [String: (password: String, used: Date)] = [:]
    nonisolated(unsafe) private static var toSave: [String: String] = [:]   // typed with "Save in Keychain", not taken yet
    static let grace: TimeInterval = 300
    /// The dialog (`AppDelegate.askSudoPassword`); replaced in tests. nil: cancelled.
    @MainActor static var ask: @MainActor (SFTPTarget, _ wrong: Bool) async -> (password: String, save: Bool)? = { t, wrong in
        await (NSApp.delegate as? AppDelegate)?.askSudoPassword(t, wrong: wrong)
    }

    static func key(_ t: SFTPTarget) -> String { "\(t.host):\(t.port ?? 22)" }   // ServerRow.key

    /// The one kept for `t` (memory, then Keychain), else asked for (waits for the dialog). `wrong`: the one given before
    /// goes first, from the Keychain too.
    static func password(_ t: SFTPTarget, wrong: Bool) -> String? {
        let key = key(t)
        if wrong {
            forget(key)
            SSHPasswords.set(nil, for: t, sudo: true)
        } else if let p = lock.withLock({ () -> String? in
            guard let k = kept[key], Date().timeIntervalSince(k.used) < grace else { return nil }
            kept[key]?.used = Date()
            return k.password
        }) ?? SSHPasswords.get(t, sudo: true) { return p }
        let answered = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer: (password: String, save: Bool)?
        Task { @MainActor in
            answer = await ask(t, wrong)
            answered.signal()
        }
        answered.wait()
        lock.withLock { toSave[key] = answer?.save == true ? answer?.password : nil }
        return answer?.password
    }

    /// sudo took it: kept for the next session, and saved if the user asked to.
    static func taken(_ t: SFTPTarget, _ password: String) {
        let save = lock.withLock { () -> Bool in
            kept[key(t)] = (password, Date())
            return toSave.removeValue(forKey: key(t)) == password
        }
        if save { SSHPasswords.set(password, for: t, sudo: true) }
    }

    /// That server's (`key`), or all — one typed to be saved but not taken yet too.
    static func forget(_ key: String? = nil) {
        lock.withLock {
            if let key { (kept[key], toSave[key]) = (nil, nil) } else { (kept, toSave) = ([:], [:]) }
        }
    }
}

/// Locked saved servers ask for Touch ID or the Mac password before a new connection (by any route to the same
/// user@host:port: sidebar, picker, typed address, reconnect), an edit or a delete. One success unlocks the server
/// for 5 minutes, or until the screen locks or the Mac sleeps. Open sessions stay open.
@MainActor
enum ServerLock {
    static var servers: () -> [SavedServer] = { [] }
    /// Replaced in tests.
    static var authenticate: (String) async -> Bool = { reason in
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
    static var grace: TimeInterval = 300
    private static var unlockedUntil: [UUID: Date] = [:]

    static func server(for t: SFTPTarget) -> SavedServer? {
        servers().first { $0.locked && SSHPasswords.sameKey($0.target, t) }
    }

    static func needsUnlock(_ t: SFTPTarget) -> Bool {
        server(for: t).map { (unlockedUntil[$0.id] ?? .distantPast) < Date() } ?? false
    }

    /// `action` completes "… to <action>" in the system's prompt.
    static func authorize(_ s: SavedServer, _ action: String) async -> Bool {
        let s = server(for: s.target) ?? s   // an unlocked twin at a locked address shares its password: asks too
        guard s.locked, (unlockedUntil[s.id] ?? .distantPast) < Date() else { return true }
        guard await authenticate("\(action) “\(s.title)”") else { return false }
        unlockedUntil[s.id] = Date().addingTimeInterval(grace)
        return true
    }

    static func authorize(_ t: SFTPTarget) async -> Bool {
        guard let s = server(for: t) else { return true }
        return await authorize(s, "connect to")
    }

    /// Also when the screen locks or the Mac sleeps (the app's tunnels: `Tunnels.relock`).
    static var onRelock: () -> Void = {}

    static func relock() {
        unlockedUntil = [:]
        SudoPasswords.forget()
        onRelock()
    }

    static func relockOnScreenLockAndSleep() {
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { _ in MainActor.assumeIsolated { relock() } }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { relock() }
        }
    }
}

/// Shared ssh connections (ControlMaster) ended on purpose: Disconnect; and after sleep or a network change, when they're
/// likely dead while `-O check` still says yes, so the first remote operation waited for ssh to give up (~90 s).
enum Masters {
    /// `SFTP.stopMaster`; replaced in tests (no ssh runs).
    nonisolated(unsafe) static var stopper: @Sendable (SFTPTarget, _ now: Bool) -> Void = { SFTP.stopMaster($0, now: $1) }

    /// Those of the servers `match` picks (all by default), off the main thread: each stop blocks briefly. The server
    /// panels' kept sessions on them go too: the next listing connects afresh instead of riding a dead connection.
    static func stop(now: Bool, where match: @escaping @Sendable (SFTPTarget) -> Bool = { _ in true }) async {
        let stopper = stopper
        await Blocking.run {
            for t in SFTP.masterTargets where match(t) {
                KeptSession.closeAll(on: t)
                stopper(t, now)
            }
        }
    }

    /// `-O stop`, not exit: the socket goes, so the next operation logs in fresh, while an SSH tab on a connection
    /// that did survive (a short sleep, a second network joining) goes on; on a dead one it ends as ssh notices.
    static func stopOnWake(_ center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in Task { await stop(now: false) } }
    }

    private static let network = NWPathMonitor()
    static func stopOnNetworkChange() {
        network.pathUpdateHandler = changes { (_: NWPath) in Task { await stop(now: false) } }
        network.start(queue: DispatchQueue(label: "dfm.network"))
    }

    /// Calls `fire` with each value unlike the one before; the first (the monitor's state at start) only sets it.
    static func changes<T: Equatable & Sendable>(_ fire: @escaping @Sendable (T) -> Void) -> @Sendable (T) -> Void {
        nonisolated(unsafe) var last: T?   // one serial queue
        return { v in
            if let l = last, l != v { fire(v) }
            last = v
        }
    }
}

/// Saved servers' tunnels while they listen (README "Tunnels"): a `TunnelListener` each, by server and local port.
/// Each connection logs in when the server's master is down — after sleep or a network change too (`Masters` stops it
/// then), so nothing restarts — and rides it otherwise. The listeners' word comes in on the main thread.
/// Temporary ones (Forward Port…) live here alone, until Turn Off, Disconnect, the lock or quitting — on any server, an
/// unsaved one as a `SavedServer` made for it (never saved); servers.json and `sync` never see them.
@MainActor
final class Tunnels {
    struct Key: Hashable { let server: UUID, port: Int }
    struct State {
        var tunnel: Tunnel
        var server: SavedServer
        var listener: TunnelListener?   // nil: not listening, and `error` says why
        var error: String?              // why the last connection failed, or why it can't listen
        var said: String?               // the last failure the status line told: a new one once, not each retry of a pool
        let token = UUID()              // a listener started again: the old one's word no longer counts
        var temporary = false
    }
    private(set) var states: [Key: State] = [:]
    /// Listeners that stopped taking connections but keep their open ones (the screen locked; a tunnel that listens
    /// anew after an edit), until those end: Disconnect and quitting still end them, and count them when they ask.
    private var held: [(server: String, title: String, listener: TunnelListener)] = []
    /// One started or stopped listening (the sidebar shows it).
    var changed: () -> Void = {}
    /// A status line.
    var say: (String, _ error: Bool) -> Void = { _, _ in }
    /// What each connection runs; replaced in tests. A password asked for a client connecting in the background says
    /// what it's for (askpass), or it would come out of nowhere.
    var child: (Tunnel, SavedServer) -> @Sendable (CancelFlag) throws -> TunnelListener.Child = { t, s in
        t.child(on: s.target, env: SSHAskpass.env.merging(["DFM_ASKPASS_WHY": "For the tunnel “\(t.title)” → \(s.title)"]) { $1 },
                server: s.title)
    }
    private var heldNote: String?

    static func key(_ t: Tunnel, _ s: SavedServer) -> Key { Key(server: s.id, port: t.localPort) }
    func state(_ t: Tunnel, of s: SavedServer) -> State? { states[Self.key(t, s)] }
    func isListening(_ t: Tunnel, of s: SavedServer) -> Bool { state(t, of: s)?.listener != nil }
    func connections(_ t: Tunnel, of s: SavedServer) -> Int { state(t, of: s)?.listener?.connections ?? 0 }
    func listening(_ s: SavedServer) -> [Tunnel] { s.tunnels.filter { isListening($0, of: s) } }
    /// Servers (`ServerRow.key`) a tunnel listens for: in use, so their connection stays up (`releaseIdleServers`).
    var inUse: Set<String> { Set(states.values.filter { $0.listener != nil }.map { ServerRow.key($0.server.target) }) }

    /// Listens on its port (again, if it did: the connections open so far live on); nil, or why it can't — a taken
    /// port, with the next free one. `temporary`: one that can't listen leaves nothing behind.
    @discardableResult
    func start(_ t: Tunnel, of s: SavedServer, temporary: Bool = false) -> String? {
        let key = Self.key(t, s)
        let was = states.removeValue(forKey: key)
        was.map(hold)   // not `stop`: told once, when it listens anew (its server stays in use)
        var st = State(tunnel: t, server: s, temporary: temporary || was?.temporary == true)
        defer {
            if st.listener != nil || !st.temporary { states[key] = st }
            changed()
        }
        if let p = t.problem {
            st.error = p
            return p
        }
        let token = st.token
        do {
            st.listener = try TunnelListener(port: t.localPort, child: child(t, s)) { [weak self] e in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(e, token) } }
            }
            return nil
        } catch {
            st.error = error.localizedDescription + (TunnelListener.freePort(after: t.localPort).map { " — \($0) is free" } ?? "")
            return st.error
        }
    }

    /// Closes its port and its connections.
    func stop(_ t: Tunnel, of s: SavedServer) { stop(Self.key(t, s)) }

    private func stop(_ key: Key) {
        guard let st = states.removeValue(forKey: key) else { return }
        st.listener?.stop()
        changed()
    }

    /// Its port closes; its open connections live on, held.
    private func hold(_ st: State) {
        guard let l = st.listener else { return }
        l.stop(keepConnections: true)
        held.removeAll { $0.listener.connections == 0 }
        if l.connections > 0 { held.append((ServerRow.key(st.server.target), st.tunnel.title, l)) }
    }

    /// An edit gave it another local port: this one closes, the connections open on it live on (held) — `sync` would
    /// take it for a tunnel deleted and close them.
    func moving(_ t: Tunnel, of s: SavedServer) {
        guard let st = states.removeValue(forKey: Self.key(t, s)) else { return }
        hold(st)
        changed()
    }

    func isTemporary(_ t: Tunnel, of s: SavedServer) -> Bool { state(t, of: s)?.temporary == true }

    /// The temporary tunnels, by local port; those of one server (`ServerRow.key`) with `server`.
    func temporaries(server: String? = nil) -> [State] {
        states.values.filter { $0.temporary && (server == nil || ServerRow.key($0.server.target) == server) }.sorted { $0.tunnel.localPort < $1.tunnel.localPort }
    }

    /// Disconnect: the server's temporary tunnels close, with their connections.
    func stopTemporaries(server: String) {
        temporaries(server: server).forEach { stop(Self.key($0.tunnel, $0.server)) }
    }

    /// Save: a temporary tunnel becomes `s`'s — the one it was on, or that server saved since — without closing its port
    /// (servers.json gets it next, and `sync` then finds it as it is). Listens anew only if `s` connects another way.
    func adopt(_ t: Tunnel, of temporary: SavedServer, into s: SavedServer) {
        guard var st = states.removeValue(forKey: Self.key(t, temporary)) else { return }
        let other = st.server.target != s.target
        (st.temporary, st.server, st.tunnel) = (false, s, t)
        states[Self.key(t, s)] = st
        if other { start(t, of: s) } else { changed() }
    }

    /// Disconnect: what the server's held listeners still keep ends.
    func endHeld(_ server: String) {
        held.filter { $0.server == server }.forEach { $0.listener.stop() }
        held.removeAll { $0.server == server }
    }

    /// Quitting: every port closes, every connection with it.
    func stopAll() {
        states.values.forEach { $0.listener?.stop() }
        held.forEach { $0.listener.stop() }
        (states, held) = ([:], [])
    }

    /// By the listener's token, not its key: a temporary tunnel saved keeps its listener under its server's key.
    private func heard(_ e: TunnelListener.Event, _ token: UUID) {
        guard case .closed(let failure) = e, let key = states.first(where: { $0.value.token == token })?.key, var st = states[key] else { return }
        let flipped = (st.error == nil) != (failure == nil)   // the sidebar shows failed or fine, not each retry
        st.error = failure   // a clean end clears the last failure
        if let failure, failure != st.said {
            st.said = failure
            say("\(st.tunnel.title): \(failure)", true)
        }
        states[key] = st
        if flipped { changed() }
    }

    /// Locked: itself, or another saved server at its address is (`ServerLock`).
    private static func locked(_ s: SavedServer, among servers: [SavedServer]) -> Bool {
        servers.contains { $0.locked && SSHPasswords.sameKey($0.target, s.target) }
    }

    /// At launch: the tunnels that were on listen, without connecting — a login waits for the first client. A locked
    /// server's don't (Touch ID turns them on). Those that can't listen are named in one status line.
    func startSaved(_ servers: [SavedServer]) {
        let failed = servers.filter { !Self.locked($0, among: servers) }.flatMap { s in
            s.tunnels.filter(\.on).compactMap { t in start(t, of: s).map { "“\(t.title)” (\(s.title)): \($0)" } }
        }
        if !failed.isEmpty { say("Tunnels not listening: " + failed.joined(separator: "; "), true) }
    }

    /// The saved servers changed: a tunnel gone (or its server) stops; one whose way or server changed listens anew —
    /// its open connections live on — unless its server is now one that's locked (that asks for Touch ID first); a new
    /// name or URL just shows.
    func sync(_ servers: [SavedServer]) {
        for (key, st) in states where !st.temporary {
            guard let s = servers.first(where: { $0.id == key.server }), let t = s.tunnels.first(where: { $0.localPort == key.port }) else {
                stop(key)
                continue
            }
            if t.host == st.tunnel.host && t.port == st.tunnel.port && s.target == st.server.target {
                states[key]?.tunnel = t
                states[key]?.server = s
            } else if st.listener == nil {
                stop(key)
            } else if ServerRow.key(s.target) != ServerRow.key(st.server.target) && Self.locked(s, among: servers) {
                states.removeValue(forKey: key).map(hold)
                changed()
                say("“\(t.title)” turned off: “\(s.title)” is locked — Turn On asks for Touch ID", false)
            } else if let why = start(t, of: s) {
                say("“\(t.title)”: \(why)", true)
            }
        }
    }

    /// The screen locked or the Mac slept: locked servers' tunnels stop listening — their connections live on, as
    /// sessions do — and the status line names them once the Mac is back (`sayHeldNote`).
    func relock(_ servers: [SavedServer]) {
        let off = states.filter { $0.value.listener != nil && Self.locked($0.value.server, among: servers) }
        guard !off.isEmpty else { return }
        for key in off.keys { states.removeValue(forKey: key).map(hold) }
        changed()
        let names = off.values.map { "\($0.tunnel.title) (\($0.server.title))" }.sorted()
        heldNote = "Locked servers' tunnels turned off: " + names.joined(separator: ", ")
    }

    func sayHeldNote() {
        guard let n = heldNote else { return }
        heldNote = nil
        say(n, false)
    }

    /// "Postgres (3 connections), Grafana": the server's (`ServerRow.key`) tunnels listening and those held with
    /// connections still open; all of them with `server` nil.
    func described(server: String? = nil) -> String {
        let live = states.values.filter { st in st.listener != nil && (server == nil || ServerRow.key(st.server.target) == server) }
            .map { (ServerRow.key($0.server.target), $0.tunnel.title, $0.listener!.connections) }
        let kept = held.filter { server == nil || $0.server == server }.map { ($0.server, $0.title, $0.listener.connections) }.filter { $0.2 > 0 }
        return Self.listed(live.sorted { $0.1 < $1.1 } + kept)
    }

    /// Quitting closes these: only tunnels with connections open are worth a question (held ones too).
    func quitNote() -> String? {
        let busy = states.values.compactMap { st in st.listener.map { (ServerRow.key(st.server.target), st.tunnel.title, $0.connections) } }
            .filter { $0.2 > 0 }.sorted { $0.1 < $1.1 } + held.map { ($0.server, $0.title, $0.listener.connections) }.filter { $0.2 > 0 }
        return busy.isEmpty ? nil : "Tunnels: " + Self.listed(busy) + " — they close"
    }

    /// Each tunnel once, with what it holds from before an edit or the lock counted in ("Echo (1 connection)", not
    /// "Echo, Echo (1 connection)"); one name on two servers is two tunnels.
    private static func listed(_ tunnels: [(server: String, title: String, connections: Int)]) -> String {
        var order: [(String, String)] = [], count: [String: Int] = [:]
        for t in tunnels {
            let key = t.server + "\n" + t.title
            if count[key] == nil { order.append((key, t.title)) }
            count[key, default: 0] += t.connections
        }
        return order.map { key, title in
            let n = count[key]!
            return title + (n == 0 ? "" : " (\(n) connection\(n == 1 ? "" : "s"))")
        }.joined(separator: ", ")
    }
}

/// ssh can't prompt on a terminal we don't have; SSH_ASKPASS makes it ask through a macOS dialog instead
/// (passwords, key passphrases, "continue connecting (yes/no)?").
enum SSHAskpass {
    static let env: [String: String] = {
        let path = SFTP.controlDir + "/askpass"
        let script = """
            #!/bin/sh
            # Called by ssh with the prompt as $1; prints the answer.
            # A saved password waits in a FIFO, once (SFTP.withPassword); a second ask means it was wrong.
            \(SFTP.askpassSavedPassword)
            # $DFM_ASKPASS_WHY: what the login is for, when nothing on screen says so (a tunnel's client connecting).
            exec /usr/bin/osascript - "$1" "$DFM_ASKPASS_WHY" <<'APPLESCRIPT'
            on run argv
                set p to item 1 of argv
                if item 2 of argv is not "" then set p to p & return & return & item 2 of argv
                activate
                if p contains "(yes/no" then
                    display dialog p buttons {"Cancel", "Yes"} default button "Yes" with title "Kermo — SSH" with icon caution
                    return "yes"
                else
                    return text returned of (display dialog p default answer "" with hidden answer with title "Kermo — SSH")
                end if
            end run
            APPLESCRIPT

            """
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o700)
        return ["SSH_ASKPASS": path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"]
    }()
}

/// Mounts smb/nfs/afp shares the way Finder does (Keychain, standard sign-in dialog), without opening a Finder window.
enum NetworkMount {
    @MainActor
    static func mount(_ url: URL, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI
        var request: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions, nil, &request, .main) { err, _, mountpoints in
            let points = (mountpoints as? [String]) ?? []
            MainActor.assumeIsolated {
                switch err {
                case 0 where !points.isEmpty: completion(.success(points[0]))
                case EEXIST:   // already mounted: find it by share name (the kernel's list: no volume is asked)
                    let share = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
                    if let m = SidebarModel.mounts().first(where: { ($0.path as NSString).lastPathComponent == share }) { completion(.success(m.path)) }
                    else { completion(.failure(JobErrorMessage("“\(url.absoluteString)” is already mounted."))) }
                case -128, Int32(ECANCELED): break   // user cancelled the sign-in
                default:
                    completion(.failure(JobErrorMessage("Couldn't mount \(url.absoluteString): \(String(cString: strerror(err))) (\(err))")))
                }
            }
        }
        if status != 0 {
            completion(.failure(JobErrorMessage("Couldn't mount \(url.absoluteString) (\(status))")))
        }
    }
}

/// Local copies of server files (↩ F3 F4 on a server panel) and of files taken out of archives. Each goes when its
/// viewer or editor closes; at launch, any older than a day (opened in another app: nothing says when that's done)
/// — except one marked kept: the only copy of text that didn't reach its server.
enum TempCopies {
    static let prefixes = ["dfm-sftp-", "dfm-archive-", "dfm-git-", "dfm-command-", "dfm-text-"]   // dfm-git-: Git Log / Blame text; dfm-command-: ⌘↩ scripts; dfm-text-: ⌘Y's .txt copies
    static let keptMarker = ".dfm-kept"

    /// The file lives in one of these copies (so Save As doesn't offer that folder: it goes with the copy).
    static func holds(_ url: URL) -> Bool { prefixes.contains(where: url.deletingLastPathComponent().lastPathComponent.hasPrefix) }

    static func keep(_ dir: String) { FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent(keptMarker), contents: nil) }
    static func unkeep(_ dir: String) { try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(keptMarker)) }

    static func remove(_ dir: String) {
        let fm = FileManager.default
        // Archives bring read-only folders, whose contents removeItem can't delete. Never through a link.
        if (try? fm.attributesOfItem(atPath: dir))?[.type] as? FileAttributeType == .typeDirectory, let e = fm.enumerator(atPath: dir) {
            for case let sub as String in e where e.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                chmod((dir as NSString).appendingPathComponent(sub), 0o700)
            }
        }
        try? fm.removeItem(atPath: dir)
    }

    static func sweep(in root: String = NSTemporaryDirectory(), now: Date = Date()) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where prefixes.contains(where: name.hasPrefix) {
            let path = (root as NSString).appendingPathComponent(name)
            // lstat: a link's own date; removeItem then takes the link, not what it points to.
            guard let a = try? fm.attributesOfItem(atPath: path), let m = a[.modificationDate] as? Date, now.timeIntervalSince(m) > 86_400,
                  !(a[.type] as? FileAttributeType == .typeDirectory && fm.fileExists(atPath: (path as NSString).appendingPathComponent(keptMarker)))
            else { continue }
            remove(path)
        }
    }
}

/// Local copies of server files that left the panel: ⌃Q / ⌘Y previews (Quick Look's Open with hands one to another
/// app) and ↩'s. A save there goes up to the server as F4's do: the conflict check, a production server asking first.
/// They stay until quit (an app may still have one open); then the ones on the server go, the others are kept.
@MainActor enum ServerCopies {
    @MainActor final class Copy {
        let url: URL, target: SFTPTarget, path: String
        let listed: (size: Int64, mtime: Double)   // the server's file as the panel listed it: what a preview asks for
        let state: AppDelegate.RemoteEdit          // the server's file as downloaded or last uploaded
        let preview: Bool                          // not opened anywhere on purpose: the budget may take it
        var seen: Editor.Stamp?, settling = false  // the copy as last looked at; changed since the look before
        var synced = true                          // what's in it is on the server
        var uploaded = false                       // an app saved it at least once: it's being edited
        var sends = 0, pending = 0                 // saves sent up so far (only the latest one's syncs it); on their way
        init(_ url: URL, _ target: SFTPTarget, _ path: String, listed: (Int64, Double), baseline: SFTPClient.Attrs, preview: Bool) {
            (self.url, self.target, self.path, self.listed, self.preview) = (url, target, path, listed, preview)
            state = AppDelegate.RemoteEdit(baseline: baseline)
            seen = Editor.Stamp(url.path)
        }
        var dir: String { url.deletingLastPathComponent().path }
    }

    static private(set) var copies: [Copy] = []
    /// Sends a changed copy up (`AppDelegate.upload`); true once it's there.
    static var upload: (Copy) async -> Bool = { _ in false }
    // ponytail: fixed; a setting if someone previews bigger files over a fast link.
    static let budget: Int64 = 256 << 20   // what previews nobody edits take together, the oldest going first

    static func preview(of target: SFTPTarget, _ path: String, size: Int64, mtime: Double) -> URL? {
        copies.first { $0.target == target && $0.path == path && $0.listed == (size, mtime) && $0.synced }?.url
    }

    /// A preview's download (⌃Q, ⌘Y, Compare Files), over a session of its own, into a `dfm-sftp-` folder of its own
    /// (a leftover goes with the launch sweep), named as there: Quick Look goes by the extension. nil: `look` (a link,
    /// whose own size says nothing; a size not known) asked the server first, and it isn't a file or is over `limit`.
    nonisolated static func download(_ t: SFTPTarget, _ path: String, look: Bool, limit: Int64, env: [String: String],
                                     cancel: CancelFlag) throws -> (url: URL, attrs: SFTPClient.Attrs)? {
        let tmp = NSTemporaryDirectory() + "dfm-sftp-" + UUID().uuidString
        mkdir(tmp, 0o700)
        let local = URL(fileURLWithPath: tmp).appendingPathComponent((path as NSString).lastPathComponent)   // a search hit's is a path
        do {
            let attrs = try SFTPClient.session(t, env: env, cancel: cancel) { c -> SFTPClient.Attrs? in
                if look, case let a = try c.stat(path), a.kind != .file || a.size > limit { return nil }
                return try c.download(path, to: local.path)
            }
            guard let attrs, !cancel.isCancelled else { TempCopies.remove(tmp); return nil }
            return (local, attrs)
        } catch {
            TempCopies.remove(tmp)
            throw error
        }
    }

    static func add(_ c: Copy) {
        copies.append(c)
        var left = copies.filter { $0.preview && $0.synced && !$0.uploaded }.reduce(0) { $0 + $1.state.baseline.size }
        // ponytail: an untouched preview may still be open in an app (Open with) when the budget takes it.
        for old in copies where left > budget && old !== c && old.preview && old.synced && !old.uploaded {
            left -= old.state.baseline.size
            TempCopies.remove(old.dir)
            copies.removeAll { $0 === old }
        }
        if watching == nil { watching = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); tick() } } }
    }
    private static var watching: Task<Void, Never>?

    /// Looks at every copy (stat only, a handful of files): one an app saved goes up once it stays the same for a
    /// tick — not halfway through being written.
    // ponytail: polls once a second; FSEvents if many copies are ever watched at once.
    static func tick() {
        for c in copies {
            let now = Editor.Stamp(c.url.path)
            guard now != nil else { continue }   // being replaced (an atomic save), or removed: next tick tells
            if now != c.seen { (c.seen, c.settling) = (now, true); continue }
            guard c.settling else { continue }
            c.settling = false
            send(c)
        }
    }

    /// Only if the bytes changed: an app touching or re-saving the same text sends nothing (nor asks on production).
    private static func send(_ c: Copy) {
        c.sends += 1
        if c.pending == 0, let sum = c.state.baseline.sha256, c.seen?.size ?? .max <= SFTPClient.hashLimit,
           let data = try? Data(contentsOf: c.url), Data(SHA256.hash(data: data)) == sum { return c.synced = true }
        c.synced = false
        c.pending += 1
        let n = c.sends
        c.state.save(in: c.dir) {
            let ok = await upload(c)
            c.pending -= 1
            if ok { c.uploaded = true }
            if ok && n == c.sends { c.synced = true }
            return ok
        }
    }

    /// What quitting leaves behind: copies whose last save isn't on the server, and ones still being edited.
    static var unsynced: [Copy] { copies.filter { !$0.synced } }
    static var editing: [Copy] { copies.filter { $0.uploaded && $0.synced } }

    /// Quitting: the copies on the server go; the others stay, marked kept (the only copy of that text).
    static func quit() {
        watching?.cancel()
        for c in copies { if c.synced { TempCopies.remove(c.dir) } else { TempCopies.keep(c.dir) } }
        copies.removeAll()
    }
}
