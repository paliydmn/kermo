import Foundation
import Security

/// `http` (protocol §8.1, §8.6): one address checked from this Mac — a connection of its own each time (no cache, no
/// cookies, nothing kept between checks), the first answer taken as it is (a redirect isn't followed: a 3xx is up),
/// the time to that answer's head, never the whole body. The certificate's days are read as the server sent it,
/// before the system judges it: one the system refuses is still an error, never let through for its days.
public enum ToolHTTPCheck {
    /// The record (§8.1): `url`, `status` (the answer's code, or why there was none — "timed out", "refused"), `ok`
    /// (2xx or 3xx), `ms`, `tls_days`, `checked` (Unix seconds), `error`.
    public static func check(_ url: String, method: String = "GET", timeout: Double = 10) async -> ToolRecord {
        var r: ToolRecord = ["url": .string(url), "ok": false, "checked": .number(Date().timeIntervalSince1970.rounded())]
        guard valid(url), let u = URL(string: url) else {
            (r["status"], r["error"]) = ("bad address", "not an http:// or https:// address")
            return r
        }
        var request = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        let config = URLSessionConfiguration.ephemeral
        (config.urlCache, config.httpCookieStorage, config.httpShouldSetCookies, config.timeoutIntervalForResource) = (nil, nil, false, timeout)
        let probe = Probe(), session = URLSession(configuration: config, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let start = Date()
        do {
            let (_, response) = try await session.bytes(for: request)   // the head is the answer; the body is left unread
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            (r["status"], r["ok"]) = (.number(Double(code)), .bool((200..<400).contains(code)))
            r["ms"] = .number((Date().timeIntervalSince(start) * 1000).rounded())
        } catch {
            (r["status"], r["error"]) = (.string(said(error)), .string(error.localizedDescription))
        }
        if let days = probe.days { r["tls_days"] = .number(days) }
        return r
    }

    /// An address a check takes: http:// or https:// with a host — what the server sheet lets you save.
    public static func valid(_ url: String) -> Bool {
        guard let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return false }
        return u.host?.isEmpty == false
    }

    /// Why there was no answer, in a word or two for the table and the alert.
    static func said(_ e: Error) -> String {
        switch (e as? URLError)?.code {
        case .timedOut?: "timed out"
        case .cannotConnectToHost?: "refused"
        case .cannotFindHost?, .dnsLookupFailed?: "no such host"
        case .notConnectedToInternet?, .networkConnectionLost?: "no network"
        case .secureConnectionFailed?, .serverCertificateUntrusted?, .serverCertificateHasBadDate?, .serverCertificateHasUnknownRoot?,
             .serverCertificateNotYetValid?: "certificate refused"
        default: "no answer"
        }
    }

    /// Whole days till `cert` ends (below zero: it has); nil if it doesn't say.
    public static func days(_ cert: SecCertificate, now: Date = Date()) -> Double? {
        let key = kSecOIDX509V1ValidityNotAfter
        guard let values = SecCertificateCopyValues(cert, [key] as CFArray, nil) as? [CFString: Any], let v = values[key] as? [CFString: Any],
              let n = v[kSecPropertyKeyValue] as? NSNumber else { return nil }
        return floor(Date(timeIntervalSinceReferenceDate: n.doubleValue).timeIntervalSince(now) / 86400)
    }

    /// The session's delegate: no redirect followed; the leaf certificate's days as the server sent it, then the
    /// system's own judgement of it.
    private final class Probe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        /// Set on the session's queue before the answer comes back, read after it.
        var days: Double?
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if let trust = challenge.protectionSpace.serverTrust, let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
                days = ToolHTTPCheck.days(leaf)
            }
            return (.performDefaultHandling, nil)
        }
    }
}
