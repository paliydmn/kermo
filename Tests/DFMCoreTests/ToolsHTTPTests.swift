import Foundation
import Network
import Testing
@testable import DFMCore

// Sites' checks from this Mac (protocol §8.1, §8.6): the first answer as it is — up, a redirect not followed, down —
// the time to it, a word for no answer at all, and a certificate's days left. Against a web server on this Mac's
// loopback, never the network.

/// A web server on 127.0.0.1: each request gets the status `answer` gives for its path (a Location with a 3xx),
/// after its delay.
private final class LocalWeb: @unchecked Sendable {
    let listener: NWListener
    var url: String { "http://127.0.0.1:\(listener.port!.rawValue)" }

    init(_ answer: @escaping @Sendable (String) -> (code: Int, delay: Double)) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)   // loopback only: no firewall question
        listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "local-web")   // its own: a busy run's global queues answered 10 s late
        listener.newConnectionHandler = { c in
            c.start(queue: queue)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let words = String(decoding: data ?? Data(), as: UTF8.self).split(separator: " ")
                let (code, delay) = answer(words.count > 1 ? String(words[1]) : "/")
                queue.asyncAfter(deadline: .now() + delay) {
                    let head = "HTTP/1.1 \(code) X\r\nContent-Length: 2\r\nConnection: close\r\n" + (code / 100 == 3 ? "Location: /elsewhere\r\n" : "") + "\r\n"
                    c.send(content: Data((head + "ok").utf8), completion: .contentProcessed { _ in c.cancel() })
                }
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func done() { listener.cancel() }
}

@Test func aCheckTakesTheFirstAnswerAsItIs() async throws {
    let web = try LocalWeb { path in
        switch path { case "/moved": (301, 0); case "/elsewhere": (404, 0); case "/down": (503, 0); case "/slow": (200, 2); default: (200, 0) }
    }
    defer { web.done() }
    let before = Date().timeIntervalSince1970.rounded(.down)
    let up = await ToolHTTPCheck.check(web.url + "/")
    #expect(up["ok"] == true && up["status"] == 200 && up["error"] == nil && up["tls_days"] == nil, "\(up)")
    #expect((up["ms"]?.number ?? -1) >= 0 && up["url"] == .string(web.url + "/"))
    #expect((before...Date().timeIntervalSince1970 + 1).contains(up["checked"]?.number ?? 0), "when it was checked")
    let moved = await ToolHTTPCheck.check(web.url + "/moved")
    #expect(moved["ok"] == true && moved["status"] == 301, "a redirect is an answer, not followed: \(moved)")
    let down = await ToolHTTPCheck.check(web.url + "/down", method: "HEAD")
    #expect(down["ok"] == false && down["status"] == 503 && down["ms"] != nil)
    let slow = await ToolHTTPCheck.check(web.url + "/slow", timeout: 0.5)
    #expect(slow["ok"] == false && slow["status"] == "timed out" && slow["ms"] == nil && slow["error"] != nil, "\(slow)")
}

@Test func noAnswerIsSaidInAWord() async throws {
    let web = try LocalWeb { _ in (200, 0) }
    let url = web.url
    web.done()
    try await Task.sleep(for: .milliseconds(100))
    let refused = await ToolHTTPCheck.check(url)
    #expect(refused["ok"] == false && refused["status"] == "refused", "\(refused)")
    let bad = await ToolHTTPCheck.check("ftp://example.com/")
    #expect(bad["ok"] == false && bad["status"] == "bad address")
}

@Test func aCertificatesDaysLeft() throws {
    let dir = NSTemporaryDirectory() + "kermo-cert-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    p.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", dir + "/k", "-out", dir + "/c", "-outform", "DER", "-days", "30", "-subj", "/CN=test"]
    (p.standardOutput, p.standardError) = (FileHandle.nullDevice, FileHandle.nullDevice)
    try p.run()
    p.waitUntilExit()
    let cert = try #require(SecCertificateCreateWithData(nil, try Data(contentsOf: URL(fileURLWithPath: dir + "/c")) as CFData))
    #expect(ToolHTTPCheck.days(cert) == 29, "30 days from now, less the seconds since")
    #expect(ToolHTTPCheck.days(cert, now: Date().addingTimeInterval(40 * 86400)) == -11, "ended ten days and a bit ago")
}
