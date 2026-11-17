import Foundation
import Security

// A model provider on the user's own key (task 23 PR 4): Kermo's own shape of a chat, one turn as a stream of events,
// the HTTP under it, the key in the Keychain. The adapters — `AIAnthropic`, `AIOpenAI` — write and read the wire.

/// One turn of a chat as Kermo keeps it — the same for every provider.
public struct AIMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public enum Part: Sendable, Equatable {
        case text(String)
        /// The model's: a tool it asked for.
        case call(AIToolUse)
        /// The user's side: what a call came to.
        case result(id: String, AIResult)
        /// A provider's own block, sent back to it exactly as it came and to no other: Anthropic's thinking, which a
        /// turn with tools must return unchanged.
        case kept(ToolValue)
    }
    public var role: Role
    public var parts: [Part]
    public init(_ role: Role, _ parts: [Part]) { (self.role, self.parts) = (role, parts) }

    public var calls: [AIToolUse] { parts.compactMap { if case .call(let c) = $0 { c } else { nil } } }
    public var text: String { parts.map { if case .text(let t) = $0 { t } else { "" } }.joined() }
}

/// A tool the model asked for. Its arguments are the model's — untrusted, they go only through `AISession.call`.
/// `args` nil: what it wrote isn't a JSON object; nothing may run, the model is told so.
public struct AIToolUse: Sendable, Equatable {
    public var id: String, name: String
    public var args: [String: ToolValue]?
    public init(id: String, name: String, args: [String: ToolValue]?) { (self.id, self.name, self.args) = (id, name, args) }
}

/// Tokens of one turn. `input` is what wasn't read from the provider's cache.
public struct AIUsage: Sendable, Equatable {
    public var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
    public init() {}
}

public enum AIStop: Sendable, Equatable {
    case done, tools, maxTokens
    /// The provider's category, when it says one.
    case refused(String?)
    case other(String)
}

public enum AIEvent: Sendable, Equatable {
    /// Text as it comes, to show.
    case text(String)
    /// The end: the turn to keep and send back next time, why it ended, what it took. Calls are only ever in it —
    /// once the turn has ended asking for tools; a turn cut short never runs one.
    case done(AIMessage, AIStop, AIUsage)
}

public protocol AIProvider: Sendable {
    /// One turn. Ends with `.done`, an `AIError` in words, or — the task cancelled — nothing new. Events already
    /// buffered may still come after a stop: check `Task.isCancelled` before acting on `.done`.
    func send(_ messages: [AIMessage], tools: [AITool], system: String) -> AsyncThrowingStream<AIEvent, Error>
    /// The models the provider lists for this key.
    func models() async throws -> [String]
}

/// Why a turn failed, in words for the user (masked: never the key). `kind` tells what may help.
public struct AIError: Error, Equatable, LocalizedError {
    public enum Kind: Sendable { case offline, key, limit, busy, cut, other }
    public var kind: Kind
    public var words: String
    /// A 429's or 503's `retry-after`, in seconds.
    public var retryAfter: Double?
    public init(_ kind: Kind, _ words: String, retryAfter: Double? = nil) { (self.kind, self.words, self.retryAfter) = (kind, words, retryAfter) }
    public var errorDescription: String? { words }

    static let cut = AIError(.cut, "The answer broke off before its end — nothing it asked for was run.")
}

/// Where a provider is and how it is reached. The key is in no description: only `keyToSend` hands it out, to the one
/// header of a request to this address.
public struct AIEndpoint: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Kind: String, Sendable { case anthropic, openai }
    public var kind: Kind
    public var address: URL
    public var model: String
    public var key: String?
    public init(_ kind: Kind, address: URL, model: String, key: String?) { (self.kind, self.address, self.model, self.key) = (kind, address, model, key) }

    public static func defaultAddress(_ kind: Kind) -> URL { URL(string: kind == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1")! }

    /// An address as typed, made one spelling (it names the key's Keychain item): http or https with a host, no
    /// user, query or fragment, no trailing slash. nil: not one.
    public static func address(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("/") { t.removeLast() }
        guard var c = URLComponents(string: t), let s = c.scheme?.lowercased(), ["http", "https"].contains(s), let h = c.host, !h.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return nil }
        (c.scheme, c.host) = (s, h.lowercased())
        return c.url
    }

    /// This Mac or a private network: plain http is allowed a key there.
    /// ponytail: names other than localhost / *.local and IPv6 beyond ::1 count as public — https or no key.
    public static func isLocal(_ u: URL) -> Bool {
        guard let h = u.host?.lowercased() else { return false }
        if ["localhost", "::1", "[::1]"].contains(h) || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false), p = parts.compactMap { Int($0) }
        guard parts.count == 4, p.count == 4, p.allSatisfy((0...255).contains) else { return false }   // not 192.168.1.1.nip.io
        return p[0] == 127 || p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168) || (p[0] == 169 && p[1] == 254)
    }

    var isPlain: Bool { address.scheme != "https" && !Self.isLocal(address) }
    /// The key for a request's header — never over plain http to a public address.
    var keyToSend: String? { key.flatMap { $0.isEmpty || isPlain ? nil : $0 } }

    /// What keeps this from being used, in words; nil — nothing. `model: false` — a model isn't needed yet (Test
    /// fills the list).
    public func problem(model needed: Bool = true) -> String? {
        let hasKey = key?.isEmpty == false
        if kind == .anthropic && !hasKey { return "Anthropic needs a key." }
        if hasKey && isPlain { return "A key goes only over https, or over http to this Mac or your own network." }
        if needed && model.isEmpty { return "Choose a model." }
        return nil
    }

    public func provider(_ transport: @escaping AITransport = AIHTTP.live) -> AIProvider {
        kind == .anthropic ? AIAnthropic(self, transport: transport) : AIOpenAI(self, transport: transport)
    }

    public var description: String { "\(kind.rawValue) \(address.absoluteString) \(model)\(key == nil ? "" : " key •••")" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}

// MARK: - HTTP

public struct AIHTTPResponse: Sendable {
    public var status: Int
    /// Names in lower case.
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>
    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>) { (self.status, self.headers, self.body) = (status, headers, body) }
}

/// One request: the answer's head, then its body as it comes. The tests' is recorded answers.
public typealias AITransport = @Sendable (URLRequest) async throws -> AIHTTPResponse

public enum AIHTTP {
    /// No byte for this long — an error. Thinking and a tool's arguments being written can be quiet a while.
    public static let silence: TimeInterval = 300

    /// `URLSession`: a session of its own each time (no cache, no cookies), no redirect followed — the key stays with
    /// the address it was saved for; plain http (this Mac, your network) past no proxy. The body is the answer's
    /// only: stopping its reader, or just letting it go, cancels the connection.
    public static let live: AITransport = { request in
        let config = URLSessionConfiguration.ephemeral
        (config.urlCache, config.httpCookieStorage, config.httpShouldSetCookies) = (nil, nil, false)
        (config.timeoutIntervalForRequest, config.timeoutIntervalForResource) = (silence, 3600)
        if request.url?.scheme != "https" { config.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable: false] }
        let (body, pipe) = AsyncThrowingStream<Data, Error>.makeStream()
        let receiver = Receiver(pipe)
        let session = URLSession(configuration: config, delegate: receiver, delegateQueue: nil)
        let task = session.dataTask(with: request)
        pipe.onTermination = { _ in task.cancel() }
        let head = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                receiver.waiting(c)
                task.resume()
            }
        } onCancel: { task.cancel() }
        return AIHTTPResponse(status: head.statusCode, headers: Dictionary(head.allHeaderFields.map { ("\($0.key)".lowercased(), "\($0.value)") }) { a, _ in a },
                              body: body)
    }

    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let pipe: AsyncThrowingStream<Data, Error>.Continuation
        private let lock = NSLock()
        private var head: CheckedContinuation<HTTPURLResponse, Error>?
        private var failed: Error?
        init(_ pipe: AsyncThrowingStream<Data, Error>.Continuation) { self.pipe = pipe }

        func waiting(_ c: CheckedContinuation<HTTPURLResponse, Error>) {
            let early = lock.withLock { () -> Error? in
                if let failed { return failed }
                head = c
                return nil
            }
            if let early { c.resume(throwing: early) }
        }
        private func takeHead() -> CheckedContinuation<HTTPURLResponse, Error>? { lock.withLock { defer { head = nil }; return head } }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
            guard let h = response as? HTTPURLResponse else { return .cancel }
            takeHead()?.resume(returning: h)
            return .allow
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { pipe.yield(data) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let e = error ?? URLError(.badServerResponse)
            lock.withLock { failed = e }
            takeHead()?.resume(throwing: e)
            if let error { pipe.finish(throwing: error) } else { pipe.finish() }
            session.finishTasksAndInvalidate()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}

// MARK: - Reading a stream

/// The `data:` lines of a server-sent event stream. Whole lines only: a chunk cut inside a character or a line waits
/// for the rest. `event:` names, comments and blank lines are skipped — each payload says its own type.
struct AISSE {
    var maxLine = 4 << 20, maxTotal = 64 << 20
    private var pending = Data(), total = 0
    /// The head of `pending` already looked through: no new line in it.
    private var searched = 0

    mutating func feed(_ chunk: Data) throws -> [String] {
        total += chunk.count
        guard total <= maxTotal else { throw AIError(.other, "The answer passed \(maxTotal >> 20) MB; Kermo stopped reading it.") }
        pending.append(chunk)
        var out: [String] = [], start = pending.startIndex
        while let nl = pending[(start + searched)...].firstIndex(of: 10) {
            guard nl - start <= maxLine else { throw tooLong }
            var line = String(decoding: pending[start..<nl], as: UTF8.self)
            (start, searched) = (nl + 1, 0)
            if line.hasSuffix("\r") { line.removeLast() }
            guard line.hasPrefix("data:") else { continue }
            line.removeFirst(5)
            if line.hasPrefix(" ") { line.removeFirst() }
            out.append(line)
        }
        pending.removeSubrange(pending.startIndex..<start)
        searched = pending.count
        guard pending.count <= maxLine else { throw tooLong }
        return out
    }
    private var tooLong: AIError { AIError(.other, "One event of the answer passed \(maxLine >> 20) MB; Kermo stopped reading it.") }
}

/// An adapter's reading of one turn: each payload, then the end.
protocol AIParser: Sendable {
    mutating func take(_ payload: String) throws -> [AIEvent]
    mutating func end() throws -> AIEvent
}

enum AIWire {
    static let damaged = AIError(.cut, "The answer came damaged — nothing it asked for was run.")
    static func json(_ text: String) -> ToolValue? { try? JSONDecoder().decode(ToolValue.self, from: Data(text.utf8)) }
    static func object(_ v: ToolValue?) -> [String: ToolValue] { if case .object(let o)? = v { o } else { [:] } }
    static func string(_ v: ToolValue?) -> String? { if case .string(let s)? = v { s } else { nil } }
    static func int(_ v: ToolValue?) -> Int? { if case .number(let n)? = v, n.isFinite, abs(n) < 1e15 { Int(n) } else { nil } }
    static func data(_ v: ToolValue) -> Data { (try? JSONEncoder.sorted.encode(v)) ?? Data("{}".utf8) }

    /// A tool call's arguments as the model wrote them: a JSON object, or nil. Nothing written: none.
    static func args(_ text: String) -> [String: ToolValue]? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        if case .object(let o)? = json(text) { return o }
        return nil
    }

    static func request(_ url: URL, body: ToolValue?, headers: [String: String]) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: AIHTTP.silence)   // not URLRequest's own 60 s
        r.httpMethod = body == nil ? "GET" : "POST"
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body {
            r.httpBody = data(body)
            r.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        return r
    }

    /// One turn: the request, its answer's payloads through `parser`, its end. Errors in words with the key masked;
    /// a stop — the reader gone, its task cancelled — ends it with nothing more.
    static func stream(_ request: URLRequest, _ e: AIEndpoint, _ transport: @escaping AITransport, _ parser: some AIParser) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                var answering = false
                do {
                    let r = try await transport(request)
                    guard r.status == 200 else { throw await failure(r, e) }
                    answering = true
                    var sse = AISSE(), p = parser
                    for try await chunk in r.body {
                        for payload in try sse.feed(chunk) { for ev in try p.take(payload) { c.yield(ev) } }
                    }
                    try Task.checkCancellation()
                    c.yield(try p.end())
                    c.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError { c.finish() } else { c.finish(throwing: said(error, e, answering: answering)) }
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    /// A GET's JSON answer (8 MB at most).
    static func get(_ request: URLRequest, _ e: AIEndpoint, _ transport: @escaping AITransport) async throws -> [String: ToolValue] {
        do {
            let r = try await transport(request)
            guard r.status == 200 else { throw await failure(r, e) }
            let body = try await read(r.body, max: 8 << 20)
            guard body.count <= 8 << 20 else { throw AIError(.other, "\(e.address.host ?? "The provider") answered with over 8 MB; Kermo stopped reading it.") }
            guard case .object(let o)? = try? JSONDecoder().decode(ToolValue.self, from: body) else {
                throw AIError(.other, "\(e.address.host ?? "The provider") answered with something that isn't JSON.")
            }
            return o
        } catch { throw said(error, e) }
    }

    /// Up to just past `max`; the rest isn't read (letting the body go cancels it).
    static func read(_ body: AsyncThrowingStream<Data, Error>, max: Int) async throws -> Data {
        var all = Data()
        for try await chunk in body {
            all.append(chunk)
            if all.count > max { break }
        }
        return all
    }

    /// An answer other than 200, in words.
    static func failure(_ r: AIHTTPResponse, _ e: AIEndpoint) async -> AIError {
        let text = hide(String(decoding: (try? await read(r.body, max: 64 << 10)) ?? Data(), as: UTF8.self), e)   // before it is cut
        let err = object(json(text))["error"]   // Anthropic's, OpenAI's, Ollama's and llama.cpp's shape; a proxy's page is text
        let message = string(object(err)["message"]) ?? string(err) ?? String(text.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
        let host = e.address.host ?? "The provider", detail = message.isEmpty ? "" : ": \(message)"
        let retry = r.headers["retry-after"].flatMap(Double.init)
        let error = switch r.status {
        case 401, 403: AIError(.key, "\(host) didn't accept the key (\(r.status))\(detail)")
        case 429: AIError(.limit, "\(host): limit reached (429)\(detail)" + (retry.map { " — try again in \(Int($0)) s." } ?? ""), retryAfter: retry)
        case 503, 529: AIError(.busy, "\(host) is overloaded (\(r.status))\(detail) — try again shortly.", retryAfter: retry)
        case 300..<400: AIError(.other, "\(host) sent the request elsewhere (\(r.status)); Kermo doesn't follow it with your key — check the address.")
        default: AIError(.other, "\(host) answered \(r.status)\(detail)")
        }
        return masked(error, e)
    }

    /// Any error as the user reads it: the key never in it — the very string, and anything shaped like a secret.
    /// `answering`: the 200 had come — a connection lost now broke the answer off.
    static func said(_ error: Error, _ e: AIEndpoint, answering: Bool = false) -> AIError {
        if let a = error as? AIError { return masked(a, e) }
        let host = e.address.host ?? "the provider"
        if (error as? URLError)?.code == .timedOut { return AIError(answering ? .cut : .offline, "\(host) went quiet for over \(Int(AIHTTP.silence)) s" + (answering ? " — nothing it asked for was run." : ".")) }
        if answering { return AIError(.cut, "The connection to \(host) broke off in the middle of the answer (\(ToolHTTPCheck.said(error))) — nothing it asked for was run.") }
        return masked(AIError(.offline, "No answer from \(host): \(ToolHTTPCheck.said(error))."), e)
    }

    static func masked(_ a: AIError, _ e: AIEndpoint) -> AIError {
        var a = a
        a.words = hide(a.words, e)
        return a
    }
    static func hide(_ text: String, _ e: AIEndpoint) -> String {
        AISecrets.mask(e.key.map { $0.count >= 4 ? text.replacingOccurrences(of: $0, with: "•••") : text } ?? text).text
    }
}

// MARK: - Keys

/// Where keys are kept; the tests' is in memory — the real Keychain asks on an ad-hoc build.
public protocol AIKeyStore: Sendable {
    func has(_ account: String) -> Bool
    func get(_ account: String) -> String?
    @discardableResult func set(_ key: String?, _ account: String) -> Bool
}

/// The Keychain: service "Kermo AI", one item per provider address — never the servers' passwords.
public struct AIKeychain: AIKeyStore {
    public init() {}
    private func query(_ account: String) -> [CFString: Any] { [kSecClass: kSecClassGenericPassword, kSecAttrService: "Kermo AI", kSecAttrAccount: account] }

    /// Without reading it (no prompt).
    public func has(_ account: String) -> Bool { SecItemCopyMatching(query(account) as CFDictionary, nil) == errSecSuccess }

    public func get(_ account: String) -> String? {
        var q = query(account)
        (q[kSecReturnData], q[kSecMatchLimit]) = (true, kSecMatchLimitOne)
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil or "": forget it.
    public func set(_ key: String?, _ account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        guard let key, !key.isEmpty else { return true }
        var q = query(account)
        (q[kSecValueData], q[kSecAttrLabel]) = (Data(key.utf8), "Kermo AI: \(account)")
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

/// The user's keys by provider address. Each is read from the store once a launch, when first needed, then kept in
/// memory; `has` never reads one.
public final class AIKeys: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    public static let shared = AIKeys(AIKeychain())
    private let store: AIKeyStore
    private let lock = NSLock()
    /// Keys read or saved this launch. A read that failed (denied) isn't kept: the next use asks again.
    private var known: [String: String] = [:]
    public init(_ store: AIKeyStore) { self.store = store }

    public func has(_ address: URL) -> Bool {
        let a = address.absoluteString
        return lock.withLock { known[a] != nil } || store.has(a)
    }

    public func key(_ address: URL) -> String? {
        let a = address.absoluteString
        if let k = lock.withLock({ known[a] }) { return k }
        let k = store.get(a)
        if let k { lock.withLock { known[a] = k } }
        return k
    }

    /// nil or "": removed. Failed: nothing kept in memory either (the store may have lost the old one).
    @discardableResult public func set(_ key: String?, for address: URL) -> Bool {
        let a = address.absoluteString, k = key?.isEmpty == false ? key : nil
        let ok = store.set(k, a)
        lock.withLock { known[a] = ok ? k : nil }
        return ok
    }

    public var description: String { "AIKeys" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
