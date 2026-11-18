import AppKit
import DFMCore
import Testing
@testable import DFileManager

// Task 23 PR 5: the chat panel on recorded answers — what goes (the instructions, what was attached, the question,
// the Ask tools), a read the model asks for, an answer's code block, a failed request and Retry, Stop, no key. A key
// store in memory, no Keychain, no network.

private final class Keys: AIKeyStore, @unchecked Sendable {
    func has(_ account: String) -> Bool { account == "https://api.anthropic.com" }
    func get(_ account: String) -> String? { has(account) ? "test-" + "key" : nil }
    func set(_ key: String?, _ account: String) -> Bool { true }
}

/// Anthropic's stream for a turn of `text`, or of one call.
private func turn(text: String) -> String {
    sse([#"{"type":"message_start","message":{"usage":{"input_tokens":1200,"output_tokens":1}}}"#,
         #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
         #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":\#(json(text))}}"#,
         #"{"type":"content_block_stop","index":0}"#,
         #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":40}}"#, #"{"type":"message_stop"}"#])
}
private func turn(call name: String) -> String {
    sse([#"{"type":"message_start","message":{"usage":{"input_tokens":1000,"output_tokens":1}}}"#,
         #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"\#(name)","input":{}}}"#,
         #"{"type":"content_block_stop","index":0}"#,
         #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}"#, #"{"type":"message_stop"}"#])
}
private func sse(_ events: [String]) -> String { events.map { "data: \($0)\n\n" }.joined() }
private func json(_ s: String) -> String { String(decoding: try! JSONEncoder().encode(s), as: UTF8.self) }

/// Hands out the answers in turn (status, body; nil body: it never ends) and keeps each request's JSON.
private final class Wire: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(Int, String?)]
    private var asked: [[String: Any]] = []
    init(_ answers: [(Int, String?)]) { self.answers = answers }
    var bodies: [[String: Any]] { lock.withLock { asked } }
    func then(_ more: [(Int, String?)]) { lock.withLock { answers += more } }
    var transport: AITransport {
        { [self] r in
            let (status, body) = lock.withLock { () -> (Int, String?) in
                asked.append((try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:])
                return answers.isEmpty ? (500, "{}") : answers.removeFirst()
            }
            let (s, c) = AsyncThrowingStream<Data, Error>.makeStream()
            if let body {
                c.yield(Data(body.utf8))
                c.finish()
            }
            return AIHTTPResponse(status: status, headers: [:], body: s)
        }
    }
}

@MainActor private var keptApps: [AppDelegate] = []

@MainActor private func panelApp(_ dir: String) -> AppDelegate {
    _ = NSApplication.shared
    let app = AppDelegate()
    keptApps.append(app)
    app.commands = app.makeCommands()
    app.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    app.window.contentView = host
    app.terminal = EmbeddedTerminal(covering: host)
    app.panels = [PanelViewController(tabs: [dir], index: 0, showHidden: false), PanelViewController(tabs: [dir], index: 0, showHidden: false)]
    app.panels.forEach { $0.loadViewIfNeeded() }
    return app
}

@MainActor private func views<T: NSView>(_ v: NSView, _ type: T.Type) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views($0, type) } }
@MainActor private func shown(_ p: AIPanel) -> String { views(p.view, NSTextView.self).map(\.string).joined(separator: "\n") + views(p.view, NSTextField.self).map(\.stringValue).joined(separator: "\n") }
@MainActor private func button(_ p: AIPanel, _ title: String) -> NSButton? { views(p.view, NSButton.self).first { $0.title == title } }
@MainActor private func click(_ b: NSButton) { _ = (b.target as? NSObject)?.perform(b.action, with: b) }
@MainActor private func done(_ p: AIPanel) async { await p.turn?.value }

extension ServerLockTests {   // `UserDefaults.standard` and `ServerLock.servers` as the panel reads them
    @Test func theChatSendsWhatWasAttachedReadsAndAnswers() async throws {
        let std = UserDefaults.standard, names = ["aiProvider", "aiAddress", "aiModel", "aiProduction"], saved = names.map { ($0, std.object(forKey: $0)) }
        let wire = Wire([(200, turn(call: "focus")), (200, turn(text: "Your folder is fine.\n\n```sh\nls -la /tmp\n```"))])
        (AISettings.keys, AISettings.transport) = (AIKeys(Keys()), wire.transport)
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t23p-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(("pass" + "word=hunter22\n").utf8).write(to: URL(fileURLWithPath: dir + "/app.conf"))
        defer {
            for (k, v) in saved { if let v { std.set(v, forKey: k) } else { std.removeObject(forKey: k) } }
            (AISettings.keys, AISettings.transport) = (.shared, AIHTTP.live)
            try? FileManager.default.removeItem(atPath: dir)
        }
        names.forEach(std.removeObject(forKey:))
        let app = panelApp(dir)
        defer { app.panels.forEach { $0.shutdown() } }
        let panel = AIPanel(app: app)
        panel.view.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        panel.build()
        #expect(shown(panel).contains("Ask about what's open"))

        // A folder attached: its names go, the secret in the question doesn't.
        let folder = try #require(panel.contexts(all: true).first { $0.id == "dir:mac:\(dir)" })
        panel.attach(folder)
        for _ in 0..<300 where panel.turn == nil {
            panel.send("What's here? token=abc123secret")
            if panel.turn == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        await done(panel)
        let first = try #require(wire.bodies.first)
        #expect(first["system"] as? String == AIChat.askSystem && (first["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == AIChat.askTools.map(\.name))
        let message = "\(first["messages"] ?? "")"
        #expect(message.contains("<attached name=") && message.contains("app.conf") && message.contains("What's here?") && !message.contains("abc123secret"), "\(message)")
        // The model's read went through the session and came back to it; the answer's code block can go to the terminal.
        #expect(wire.bodies.count == 2 && "\(wire.bodies[1]["messages"] ?? "")".contains("tool_result"))
        #expect(shown(panel).contains("Your folder is fine.") && shown(panel).contains("What's in front of you"), "\(shown(panel))")
        #expect(button(panel, "Into Terminal") != nil && button(panel, "Copy") != nil && shown(panel).contains("2.2k in · 60 out tokens"))

        // A limit: in words with Retry, which asks again and appends nothing twice.
        wire.then([(429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#), (200, turn(text: "Now it's fine."))])
        panel.send("Again?")
        await done(panel)
        #expect(shown(panel).contains("limit reached (429)"))
        click(try #require(button(panel, "Retry")))
        await done(panel)
        #expect(shown(panel).contains("Now it's fine.") && wire.bodies.count == 4)
        click(try #require(button(panel, "Retry")))   // that failure was answered: nothing more to ask
        #expect(panel.turn == nil && wire.bodies.count == 4)
        #expect("\(wire.bodies[3]["messages"] ?? "")".components(separatedBy: "Again?").count == 2, "the question once")

        // Stop while the answer is coming: said, and the next question joins it.
        wire.then([(200, nil)])
        panel.send("Hang?")
        try? await Task.sleep(for: .milliseconds(50))
        panel.stop()
        await done(panel)
        #expect(shown(panel).contains("Stopped."))

        // Rendered off screen, as it is laid out.
        let rep = try #require(panel.view.bitmapImageRepForCachingDisplay(in: panel.view.bounds))
        panel.view.cacheDisplay(in: panel.view.bounds, to: rep)
    }

    /// What is attached from a production server: asked once a chat (Cancel sends nothing), Kermo's word goes with it;
    /// Never Send turned on later ends that chat; a New Chat under Never Send doesn't take such a chip.
    @Test func productionIsAskedOnceAChatOrNeverSent() async throws {
        let std = UserDefaults.standard, names = ["aiProvider", "aiAddress", "aiModel", "aiProduction"], saved = names.map { ($0, std.object(forKey: $0)) }
        let wire = Wire([(200, turn(text: "Fine.")), (200, turn(text: "Still fine."))])
        (AISettings.keys, AISettings.transport) = (AIKeys(Keys()), wire.transport)
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t23q-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("listen 80;\n".utf8).write(to: URL(fileURLWithPath: dir + "/site.conf"))
        var box = SavedServer(target: .local(port: 2))
        (box.name, box.prod) = ("box", true)
        ServerLock.servers = { [box] }
        var asked: [String] = [], answer = 1
        AppDelegate.answering = { title, _, _ in asked.append(title); return answer }
        let app = panelApp(dir)
        defer {
            for (k, v) in saved { if let v { std.set(v, forKey: k) } else { std.removeObject(forKey: k) } }
            (AISettings.keys, AISettings.transport, AppDelegate.answering) = (.shared, AIHTTP.live, nil)
            ServerLock.servers = { [] }
            app.panels.forEach { $0.shutdown() }
            try? FileManager.default.removeItem(atPath: dir)
        }
        names.forEach(std.removeObject(forKey:))
        let panel = app.panels[1]
        panel.loadRemote(.local(port: 2), dir: dir, select: nil)
        for _ in 0..<300 where panel.remote?.dir != dir { try? await Task.sleep(for: .milliseconds(10)) }
        try #require(panel.remote?.dir == dir)
        let chat = AIPanel(app: app)
        chat.view.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        chat.build()
        func attachAndSend(_ q: String) async {
            if let c = chat.contexts(all: true).first(where: { $0.id == "dir:box:\(dir)" }) { chat.attach(c) }
            for _ in 0..<300 where chat.turn == nil {
                chat.send(q)
                if chat.turn == nil { try? await Task.sleep(for: .milliseconds(10)) }
            }
            await done(chat)
        }
        await attachAndSend("What's here?")   // Cancel: nothing goes
        #expect(asked == ["Send what you attached from box to api.anthropic.com?"] && wire.bodies.isEmpty)
        answer = 0
        chat.send("What's here?")
        await done(chat)
        #expect(asked.count == 2 && wire.bodies.count == 1 && shown(chat).contains("box: what you attach from it goes to api.anthropic.com"))
        #expect("\(wire.bodies[0]["messages"] ?? "")".contains("[Kermo: box is a production server"))
        await attachAndSend("And now?")   // once a chat
        #expect(asked.count == 2 && wire.bodies.count == 2)

        // The chat is the provider's its production text went to: another one is a New Chat.
        (std.set("openai", forKey: "aiProvider"), std.set("http://127.0.0.1:9/v1", forKey: "aiAddress"), std.set("m", forKey: "aiModel"))
        chat.send("Elsewhere?")
        #expect(chat.turn == nil && wire.bodies.count == 2 && shown(chat).contains("names another provider"))
        ["aiProvider", "aiAddress", "aiModel"].forEach(std.removeObject(forKey:))

        std.set("never", forKey: "aiProduction")
        chat.send("More?")
        #expect(chat.turn == nil && wire.bodies.count == 2 && shown(chat).contains("Never Send: start a New Chat"))
        click(try #require(views(chat.view, NSButton.self).first { $0.toolTip == "New Chat" }))
        if let c = chat.contexts(all: true).first(where: { $0.id == "dir:box:\(dir)" }) { chat.attach(c) }
        chat.send("Here?")   // the question goes, the production chip wasn't taken
        await done(chat)
        #expect(wire.bodies.count == 3 && !"\(wire.bodies[2]["messages"] ?? "")".contains("site.conf") && asked.count == 2)
    }

    @Test func withoutAKeyTheChatLeadsToSettings() async throws {
        let std = UserDefaults.standard, names = ["aiProvider", "aiAddress"], saved = names.map { ($0, std.object(forKey: $0)) }
        final class None: AIKeyStore, @unchecked Sendable {
            func has(_ a: String) -> Bool { false }
            func get(_ a: String) -> String? { nil }
            func set(_ k: String?, _ a: String) -> Bool { true }
        }
        AISettings.keys = AIKeys(None())
        defer {
            for (k, v) in saved { if let v { std.set(v, forKey: k) } else { std.removeObject(forKey: k) } }
            AISettings.keys = .shared
        }
        names.forEach(std.removeObject(forKey:))
        let app = panelApp(NSTemporaryDirectory())
        defer { app.panels.forEach { $0.shutdown() } }
        let panel = AIPanel(app: app)
        panel.view.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        panel.build()
        #expect(shown(panel).contains("Use your own AI") && button(panel, "Settings › AI…") != nil)
        panel.send("Hi")
        #expect(panel.turn == nil)
    }

    @Test func markdownAsTheChatDrawsIt() {
        #expect(ChatMarkdown.blocks("One\ntwo\n\n```sh\nls\n\nps\n```\nThree") == [.prose("One\ntwo"), .code("ls\n\nps", lang: "sh"), .prose("Three")])
        #expect(ChatMarkdown.blocks("Run:\n```bash\nuptime") == [.prose("Run:"), .code("uptime", lang: "bash")], "a fence still coming")
        let s = ChatMarkdown.prose("# Title\n- **bold** and `code` [docs](https://example.com/a) [x](file:///etc/passwd)")
        #expect(s.string == "Title\n• bold and code docs (https://example.com/a) x")
        var links: [URL] = []
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { v, _, _ in if let u = v as? URL { links.append(u) } }
        #expect(Set(links) == [URL(string: "https://example.com/a")!], "only http(s) is a link")
        #expect(!ChatMarkdown.prose("[Download&#x202E;fdp.exe](https://example.com/x) a&#8238;b").string.unicodeScalars.contains("\u{202E}"), "a reference is a control too")
        // 20 KB in one paragraph (~40 ms here; `Answer` paces its drawing by it): nothing that grows worse than that.
        let long = String(repeating: "Some **words** and `code` in a long answer. ", count: 460)
        let start = Date()
        _ = ChatMarkdown.prose(long)
        #expect(Date().timeIntervalSince(start) < 0.5, "\(Date().timeIntervalSince(start)) s for 20 KB")
    }
}
