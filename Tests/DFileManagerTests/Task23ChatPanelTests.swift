import AppKit
@testable import DFMCore
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
private func turn(call name: String, input: String = "{}") -> String {
    sse([#"{"type":"message_start","message":{"usage":{"input_tokens":1000,"output_tokens":1}}}"#,
         #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"\#(name)","input":\#(input)}}"#,
         #"{"type":"content_block_stop","index":0}"#,
         #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}"#, #"{"type":"message_stop"}"#])
}
/// Anthropic's stream for one round of several calls, side by side (`input`: each call's arguments as JSON).
private func turn(calls: [(name: String, input: [String: Any])]) -> String {
    var events = [#"{"type":"message_start","message":{"usage":{"input_tokens":1000,"output_tokens":1}}}"#]
    for (i, c) in calls.enumerated() {
        let input = String(decoding: try! JSONSerialization.data(withJSONObject: c.input), as: UTF8.self)
        events += [#"{"type":"content_block_start","index":\#(i),"content_block":{"type":"tool_use","id":"t\#(i)","name":"\#(c.name)","input":\#(input)}}"#,
                   #"{"type":"content_block_stop","index":\#(i)}"#]
    }
    return sse(events + [#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}"#, #"{"type":"message_stop"}"#])
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

    /// Task 23 PR 5b: a chat kept on this Mac — owner-only, nothing unmasked, the key nowhere; a new panel (a
    /// relaunch) lists it and goes on with it without its thinking; damaged, wide and newer files are left as they are
    /// and never pruned; the 50 latest kept; Delete; switched off, nothing written, and the kept ones go only if the
    /// user says so.
    @Test func chatsAreKeptOwnerOnlyAndComeBackWithoutThinking() async throws {
        let std = UserDefaults.standard, names = ["aiProvider", "aiAddress", "aiModel", "aiProduction", "aiKeepChats"], saved = names.map { ($0, std.object(forKey: $0)) }
        let thought = sse([#"{"type":"message_start","message":{"usage":{"input_tokens":1200,"output_tokens":1}}}"#,
                           #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
                           #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBsig"}}"#,
                           #"{"type":"content_block_stop","index":0}"#,
                           #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"Fine, I thought."}}"#,
                           #"{"type":"content_block_stop","index":1}"#,
                           #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":40}}"#, #"{"type":"message_stop"}"#])
        let wire = Wire([(200, thought), (200, turn(text: "Still fine."))])
        (AISettings.keys, AISettings.transport) = (AIKeys(Keys()), wire.transport)
        let base = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t23k-" + UUID().uuidString, dir = base + "/token=abc123secret"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = AIChatStore(dir: base + "/ai")
        var asked: [String] = [], answer = 1
        AppDelegate.answering = { title, _, _ in asked.append(title); return answer }
        let app = panelApp(dir)
        defer {
            for (k, v) in saved { if let v { std.set(v, forKey: k) } else { std.removeObject(forKey: k) } }
            (AISettings.keys, AISettings.transport, AppDelegate.answering) = (.shared, AIHTTP.live, nil)
            app.panels.forEach { $0.shutdown() }
            Config.flush()
            try? FileManager.default.removeItem(atPath: base)
        }
        names.forEach(std.removeObject(forKey:))
        func panel() -> AIPanel {
            let p = AIPanel(app: app)
            p.chats = store
            p.view.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
            p.build()
            return p
        }
        func send(_ p: AIPanel, _ q: String) async {
            for _ in 0..<300 where p.turn == nil {
                p.send(q)
                if p.turn == nil { try? await Task.sleep(for: .milliseconds(10)) }
            }
            await done(p)
            Config.flush()
        }
        let first = panel()
        first.attach(try #require(first.contexts(all: true).first { $0.id == "dir:mac:\(dir)" }))   // its name holds a secret
        await send(first, "Is it fine? token=abc123secret")
        let files = try FileManager.default.contentsOfDirectory(atPath: store.dir)
        try #require(files.count == 1 && files[0].hasSuffix(".json"), "\(files)")
        let id = String(files[0].dropLast(5)), file = store.dir + "/" + files[0]
        var st = stat()
        #expect(lstat(file, &st) == 0 && st.st_mode & 0o777 == 0o600 && lstat(store.dir, &st) == 0 && st.st_mode & 0o777 == 0o700)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: file)), text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("abc123secret") && !text.contains("test-key") && text.contains("token=•••") && !text.contains("EqQBsig") && text.contains("Fine, I thought."),
                "masked as it went (the question and the chip's name), no key, no thinking")

        // A relaunch: the list, the chat as it was shown, and going on without the thinking.
        let again = panel()
        let list = store.list()
        #expect(list.chats.map(\.title) == ["Is it fine? token=•••"] && list.chats.map(\.id) == [id] && list.unread.isEmpty)
        again.open(id)
        #expect(shown(again).contains("Is it fine? token=•••") && shown(again).contains("Fine, I thought.") && !shown(again).contains("abc123secret"), "\(shown(again))")
        await send(again, "And now?")
        let body = "\(wire.bodies.last?["messages"] ?? "")"
        #expect(wire.bodies.count == 2 && !body.contains("EqQBsig") && body.contains("Fine, I thought.") && body.contains("And now?"), "\(body)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.dir).count == 1, "the same chat, written over")

        // Damaged, wide and newer files: not read, said; never written over, never pruned. A new chat over 50: the oldest go.
        let kept = try Data(contentsOf: URL(fileURLWithPath: file))
        let odd = [("{", 0o600), (String(decoding: kept, as: UTF8.self), 0o644),
                   (String(decoding: kept, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":99"), 0o600)]
        for (content, mode) in odd {
            FileManager.default.createFile(atPath: store.dir + "/\(UUID().uuidString).json", contents: Data(content.utf8), attributes: [.posixPermissions: mode])
        }
        for i in 0..<50 {
            let path = store.dir + "/\(UUID().uuidString).json"
            FileManager.default.createFile(atPath: path, contents: kept, attributes: [.posixPermissions: 0o600])
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000 + Double(i))], ofItemAtPath: path)
        }
        #expect(store.list().unread.count == 3 && store.list().chats.count == 51)
        wire.then([(200, turn(text: "Same chat.")), (200, turn(text: "Pruned."))])
        await send(again, "Still 51?")
        #expect(store.list().chats.count == 51, "a chat written again prunes nothing")
        let before = Set(store.list().chats.map(\.id))
        click(try #require(views(again.view, NSButton.self).first { $0.toolTip == "New Chat" }))
        await send(again, "Prune?")
        let pruned = store.list()
        #expect(pruned.chats.count == 50 && pruned.unread.count == 3 && pruned.chats.contains { $0.id == id }, "\(pruned.unread)")

        // Delete the open chat: its file is gone, the panel starts afresh.
        let open = try #require(pruned.chats.map(\.id).first { !before.contains($0) })
        again.deleteChat(open)
        Config.flush()
        #expect(!FileManager.default.fileExists(atPath: store.dir + "/\(open).json") && store.list().chats.count == 49 && !shown(again).contains("Pruned."))

        // Switched off: the open chat isn't written again — not even once it's back on; the kept ones go only when
        // the user says so; a new chat is kept again.
        wire.then([(200, turn(text: "Kept.")), (200, turn(text: "On again.")), (200, turn(text: "Back.")), (200, turn(text: "New."))])
        await send(again, "Kept?")
        let keptID = try #require(store.list().chats.map(\.id).first { !before.contains($0) })
        #expect(store.list().chats.count == 50)
        std.set(false, forKey: "aiKeepChats")
        AIPanel.keepChatsChanged(app, panel: again)   // Keep
        for _ in 0..<300 where asked.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(asked == ["Delete the 50 chats kept on this Mac?"])
        std.removeObject(forKey: "aiKeepChats")   // on again at once: nothing went through save() while off
        await send(again, "On again?")
        let keptText = String(decoding: try Data(contentsOf: URL(fileURLWithPath: store.dir + "/\(keptID).json")), as: UTF8.self)
        #expect(wire.bodies.count == 6 && keptText.contains("Kept?") && !keptText.contains("On again?"), "the open chat's file as it was")
        std.set(false, forKey: "aiKeepChats")
        answer = 0
        AIPanel.keepChatsChanged(app, panel: again)
        for _ in 0..<300 where store.list().chats.count > 0 {
            try? await Task.sleep(for: .milliseconds(10))
            Config.flush()
        }
        #expect(store.list().chats.isEmpty && store.list().unread.count == 3 && asked.count == 2)
        std.removeObject(forKey: "aiKeepChats")
        await send(again, "Back?")
        #expect(wire.bodies.count == 7 && store.list().chats.isEmpty, "a deleted chat isn't written back")
        click(try #require(views(again.view, NSButton.self).first { $0.toolTip == "New Chat" }))
        await send(again, "New?")
        #expect(wire.bodies.count == 8 && store.list().chats.count == 1)
    }

    /// A chat read back keeps what 5a's guards read: its provider, and that it holds production text.
    @Test func aChatReadBackKeepsItsProviderAndItsProductionText() async throws {
        let std = UserDefaults.standard, names = ["aiProvider", "aiAddress", "aiModel", "aiProduction", "aiKeepChats"], saved = names.map { ($0, std.object(forKey: $0)) }
        let wire = Wire([])
        (AISettings.keys, AISettings.transport) = (AIKeys(Keys()), wire.transport)
        let base = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t23r-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let store = AIChatStore(dir: base + "/ai")
        let app = panelApp(base)
        defer {
            for (k, v) in saved { if let v { std.set(v, forKey: k) } else { std.removeObject(forKey: k) } }
            (AISettings.keys, AISettings.transport) = (.shared, AIHTTP.live)
            app.panels.forEach { $0.shutdown() }
            Config.flush()
            try? FileManager.default.removeItem(atPath: base)
        }
        names.forEach(std.removeObject(forKey:))
        let prod = AISavedChat(title: "Q", model: "claude-sonnet-5-5", provider: "anthropic https://api.anthropic.com", started: Date(), production: true,
                               messages: [AIMessage(.user, [.text("Q")]), AIMessage(.assistant, [.text("A")])], asked: [.init(question: "Q", chips: [], prod: [])])
        var elsewhere = prod
        (elsewhere.production, elsewhere.provider) = (false, "openai http://127.0.0.1:9/v1")
        let (a, b) = (UUID().uuidString, UUID().uuidString)
        store.save(a, prod) { _ in }
        store.save(b, elsewhere) { _ in }
        Config.flush()
        let panel = AIPanel(app: app)
        (panel.chats, panel.view.frame) = (store, NSRect(x: 0, y: 0, width: 400, height: 700))
        panel.build()
        std.set("never", forKey: "aiProduction")
        panel.open(a)
        panel.send("More?")
        #expect(panel.turn == nil && wire.bodies.isEmpty && shown(panel).contains("Never Send: start a New Chat"))
        std.removeObject(forKey: "aiProduction")
        panel.open(b)
        panel.send("Here?")
        #expect(panel.turn == nil && wire.bodies.isEmpty && shown(panel).contains("names another provider"))
    }

    /// Task 23 PR 6: a terminal tab's text goes as it was when it was taken, from where the tab says it is — a title
    /// naming a production server makes it production's (asked once; Never Send keeps it), one naming none is this
    /// Mac's. Follow selection takes what is selected at each ↩ (production's not under Never Send) until it's off. A
    /// panel's cursor file is a chip of its own.
    @Test func whatIsSelectedGoesAsItWasAndFromWhereTheTabSays() async throws {
        let std = UserDefaults.standard, names = ["aiProvider", "aiAddress", "aiModel", "aiProduction", "aiKeepChats"], saved = names.map { ($0, std.object(forKey: $0)) }
        let wire = Wire((1...5).map { (200, turn(text: "Answer \($0).")) })
        (AISettings.keys, AISettings.transport) = (AIKeys(Keys()), wire.transport)
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t23s-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: URL(fileURLWithPath: dir + "/notes.txt"))
        var box = SavedServer(target: .local(port: 2))
        (box.name, box.prod) = ("prodbox", true)
        ServerLock.servers = { [box] }
        var asked: [String] = []
        AppDelegate.answering = { title, _, _ in asked.append(title); return 0 }
        let app = panelApp(dir)
        defer {
            for (k, v) in saved { if let v { std.set(v, forKey: k) } else { std.removeObject(forKey: k) } }
            (AISettings.keys, AISettings.transport, AppDelegate.answering) = (.shared, AIHTTP.live, nil)
            ServerLock.servers = { [] }
            app.panels.forEach { $0.shutdown() }
            try? FileManager.default.removeItem(atPath: dir)
        }
        names.forEach(std.removeObject(forKey:))
        std.set(false, forKey: "aiKeepChats")
        let panel = AIPanel(app: app)
        panel.view.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        panel.build()
        func send(_ q: String) async {
            for _ in 0..<300 where panel.turn == nil {
                panel.send(q)
                if panel.turn == nil { try? await Task.sleep(for: .milliseconds(10)) }
            }
            await done(panel)
        }
        /// The last message of request `i`, as it went.
        func sent(_ i: Int) -> String {
            guard wire.bodies.indices.contains(i), let last = (wire.bodies[i]["messages"] as? [Any])?.last else { return "" }
            return String(decoding: (try? JSONSerialization.data(withJSONObject: last)) ?? Data(), as: UTF8.self)
        }
        let chips = { views(panel.view, ChipButton.self).map(\.attributedTitle.string).joined(separator: " | ") }

        // A tab whose title says it's on prodbox: production's — asked once, masked, Kermo's word with it.
        let tab = EmbeddedTerminal.Tab(kind: .shell, view: DropTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300)))
        tab.title = "deploy@prodbox: ~"
        let c = await AIPanel.terminal(tab, "deploy failed: token=abc123secret", what: "Selection")
        #expect(c.server.map(SavedServer.isProd) == true && c.title == "Selection · deploy@prodbox: ~")
        panel.attach(c)
        await send("Why?")
        #expect(asked == ["Send what you attached from prodbox to api.anthropic.com?"])
        #expect(sent(0).contains("deploy failed") && !sent(0).contains("abc123secret") && sent(0).contains("[Kermo: prodbox is a production server"), "\(sent(0))")

        // Never Send: such a chip isn't taken; a followed selection there doesn't go — the question does.
        std.set("never", forKey: "aiProduction")
        click(try #require(views(panel.view, NSButton.self).first { $0.toolTip == "New Chat" }))
        #expect(!panel.following)
        panel.attach(await AIPanel.terminal(tab, "more", what: "Selection"))
        #expect(shown(panel).contains("nothing from a production server goes to the AI"))
        tab.view.feed(text: "first line\r\n")
        tab.view.selectAll()
        panel.selected(tab)
        panel.toggleFollow()
        #expect(panel.following && chips().contains("Following: Selection · deploy@prodbox: ~"), "\(chips())")
        await send("Q1")
        #expect(wire.bodies.count == 2 && !sent(1).contains("first line") && sent(1).contains("Q1") && asked.count == 1)

        // A title that names no saved server: this Mac's. Each ↩ takes the selection as it is then.
        std.removeObject(forKey: "aiProduction")
        tab.title = "deploy@devbox: ~"
        #expect(await AIPanel.terminal(tab, "x", what: "Selection").server == nil)
        await send("Q2")
        #expect(sent(2).contains("first line") && sent(2).contains("Selection · deploy@devbox"), "\(sent(2))")
        tab.view.feed(text: "second\r\n")
        tab.view.selectAll()
        await send("Q3")
        #expect(sent(3).contains("second") && panel.following)
        tab.view.selectNone()
        panel.selected(tab)
        #expect(chips().contains("Following selection — none now"), "\(chips())")
        await send("Q4")
        #expect(!sent(4).contains("<attached") && asked.count == 1)
        panel.toggleFollow()
        #expect(!panel.following && chips().contains("Follow selection"))

        // Follow on a locked server's tab: Touch ID refused — nothing goes, and the chat says why.
        var lock = SavedServer(target: SFTPTarget(host: "lockbox.invalid"))
        lock.locked = true
        ServerLock.servers = { [box, lock] }
        let (wasAuth, wasG) = (ServerLock.authenticate, ServerLock.sshG)
        (ServerLock.authenticate, ServerLock.sshG) = ({ _ in false }, { t in "user u\nhostname \(t.host)\nport 22\n" })
        defer { (ServerLock.authenticate, ServerLock.sshG) = (wasAuth, wasG); ServerLock.relock() }
        let locked = EmbeddedTerminal.Tab(kind: .ssh(lock.target), view: DropTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300)))
        locked.view.feed(text: "secret things\r\n")
        locked.view.selectAll()
        panel.selected(locked)
        panel.toggleFollow()
        let before = wire.bodies.count
        await send("Q5")
        #expect(wire.bodies.count == before && shown(panel).contains("The followed selection wasn't read") && shown(panel).contains("stayed locked"), "\(shown(panel).suffix(300))")
        panel.toggleFollow()

        // ⇧⌘I in a panel: the file under its cursor.
        let p = app.panels[0]
        var row: Int?
        for _ in 0..<300 where row == nil {
            row = (0..<p.table.numberOfRows).first { p.item(at: $0)?.name == "notes.txt" }
            if row == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        p.table.selectRowIndexes(IndexSet(integer: try #require(row)), byExtendingSelection: false)
        #expect(panel.marked(p).map(\.title) == ["notes.txt · this Mac"])
    }

    /// Task 23 PR 6b: ✨ Explain attaches what failed and puts the question in the field — nothing goes till ↩, then
    /// both go; words already in the field stay. A production server's under Never Send: no chip, no question. Without
    /// the AI: nothing.
    @Test func explainAttachesWhatFailedAndSendsNothingTillReturn() async throws {
        let std = UserDefaults.standard, names = ["aiProvider", "aiAddress", "aiModel", "aiProduction", "aiKeepChats"], saved = names.map { ($0, std.object(forKey: $0)) }
        let wire = Wire([(200, turn(text: "The disk is full."))])
        (AISettings.keys, AISettings.transport) = (AIKeys(Keys()), wire.transport)
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t23e-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var box = SavedServer(target: .local(port: 2))
        (box.name, box.prod) = ("prodbox", true)
        ServerLock.servers = { [box] }
        let app = panelApp(dir)
        defer {
            for (k, v) in saved { if let v { std.set(v, forKey: k) } else { std.removeObject(forKey: k) } }
            (AISettings.keys, AISettings.transport) = (.shared, AIHTTP.live)
            ServerLock.servers = { [] }
            app.panels.forEach { $0.shutdown() }
            try? FileManager.default.removeItem(atPath: dir)
        }
        names.forEach(std.removeObject(forKey:))
        std.set(false, forKey: "aiKeepChats")
        let panel = AIPanel(app: app)
        panel.view.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        panel.build()
        let field = try #require(views(panel.view, ChatInput.self).first)
        let chips = { views(panel.view, ChipButton.self).map(\.attributedTitle.string).filter { !$0.hasPrefix("Follow") && !$0.isEmpty } }   // the scope row's +
        func settled() async { for _ in 0..<300 where chips().contains(where: { $0.hasSuffix(" …") }) { try? await Task.sleep(for: .milliseconds(10)) } }

        panel.explain([AIPanel.failure("pg_dump shop", on: nil, "$ pg_dump shop\npg_dump: error: No space left on device\n[exit 1]")])
        await settled()
        #expect(chips().first == "pg_dump shop · this Mac" && field.string == AIPanel.question && wire.bodies.isEmpty, "\(chips())")
        panel.send(field.string)
        await done(panel)
        let sent = String(decoding: try JSONSerialization.data(withJSONObject: (wire.bodies.first?["messages"] as? [Any])?.last ?? [:]), as: UTF8.self)
        #expect(wire.bodies.count == 1 && sent.contains("No space left on device") && sent.contains(AIPanel.question), "\(sent)")

        field.string = "is it the disk?"
        panel.explain([AIPanel.failure("df", on: nil, "$ df\n100%")])
        await settled()
        #expect(field.string == "is it the disk?" && chips().contains("df · this Mac"), "words typed stay")
        field.string = ""
        panel.explain([AIPanel.failure("df", on: nil, "$ df\n100%")])
        #expect(field.string == AIPanel.question && chips().filter { $0 == "df · this Mac" }.count == 1, "clicked again: the question, the chip once")
        field.string = ""

        std.set("never", forKey: "aiProduction")
        panel.explain([AIPanel.failure("nginx -t", on: box.target, "emerg")])
        #expect(!chips().contains { $0.hasPrefix("nginx -t") } && field.string.isEmpty, "Never Send: no chip, no question")
        std.removeObject(forKey: "aiProduction")

        final class None: AIKeyStore, @unchecked Sendable {   // no key (the Mac's own Keychain may have one)
            func has(_ account: String) -> Bool { false }
            func get(_ account: String) -> String? { nil }
            func set(_ key: String?, _ account: String) -> Bool { true }
        }
        AISettings.keys = AIKeys(None())
        panel.explain([AIPanel.failure("ls", on: nil, "nope")])
        #expect(!chips().contains { $0.hasPrefix("ls ·") } && field.string.isEmpty && wire.bodies.count == 1, "no AI: nothing")
    }

    /// Task 23 PR 6: `ssh` running in a local tab to a production server makes the tab's text that server's — one saved
    /// with its user, one saved by address and typed by its name; one Kermo doesn't know is this Mac's, "whoever is logged
    /// in". The `ssh` waits on a stand-in for its connection: no network, no config of yours.
    @Test func aLocalTabRunningSSHToProductionIsProductions() async throws {
        _ = NSApplication.shared
        let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t23h-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        var web = SavedServer(), db = SavedServer()
        (web.host, web.user, web.prod) = ("prodweb.invalid", "deploy", true)
        (db.host, db.name, db.prod) = ("198.51.100.7", "dbprod", true)
        ServerLock.servers = { [web, db] }
        defer {
            ServerLock.servers = { [] }
            try? FileManager.default.removeItem(atPath: d)
        }
        // zsh without rc files (nor history): nothing of yours runs.
        let shell = EmbeddedTerminal.Tab(kind: .shell, view: DropTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)))
        shell.view.startProcess(executable: "/bin/zsh", args: ["-f"], environment: ["HOME=\(d)", "PATH=/usr/bin:/bin", "TERM=xterm-256color"], currentDirectory: d)
        shell.started = "zsh"
        defer { shell.view.process.terminate() }
        for _ in 0..<3000 where !shell.isAtPrompt { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shell.origin.server == nil && !shell.origin.unsure, "the shell itself: this Mac's")
        for (to, expected) in [("prodweb.invalid", web.target.asUser), ("dbprod", db.target.asUser), ("devbox.invalid", nil)] {
            shell.view.send(txt: "ssh -F /dev/null -o BatchMode=yes -o ProxyCommand='sleep 30' \(to)\r")
            for _ in 0..<3000 where shell.foreground != "ssh" { try await Task.sleep(for: .milliseconds(10)) }
            #expect(shell.origin.server == expected && shell.origin.unsure, "\(to): \(String(describing: shell.origin))")
            shell.view.send(txt: "\u{3}")   // ⌃C
            for _ in 0..<3000 where shell.isRunning && !shell.isAtPrompt { try await Task.sleep(for: .milliseconds(10)) }
        }
        // An alias only ~/.ssh/config knows (here a stand-in for `ssh -G`): this Mac's as written, production's once learned.
        let alias = "p-" + UUID().uuidString.prefix(8).lowercased(), was = ServerLock.sshG
        ServerLock.sshG = { t in "user deploy\nhostname \(t.host == alias || t.host == "198.51.100.7" ? "198.51.100.7" : t.host)\nport 22\n" }
        defer { ServerLock.sshG = was }
        shell.view.send(txt: "ssh -F /dev/null -o BatchMode=yes -o ProxyCommand='sleep 30' \(alias)\r")
        for _ in 0..<3000 where shell.foreground != "ssh" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shell.origin.server == nil, "not learned yet: as written")
        let learned = await shell.learnedOrigin().server
        #expect(learned.map(SavedServer.isProd) == true, "\(String(describing: learned))")
        shell.view.send(txt: "\u{3}")
    }

    /// Agent (task 23 PR 8), the user's task whole: run a program on a server, its log to this Mac, an archive of it to
    /// another server — a plan and one "Allow for This Task", then only writing over the archive asks. What was
    /// allowed is the scope row's; Ask in the same chat changes nothing; the spending cap stops between rounds and
    /// asks to go on; New Chat starts from nothing; the row gives a place View and sets its level.
    @Test func anAgentDoesATaskOfThreePlacesWithOneAllow() async throws {
        let std = UserDefaults.standard, names = ["aiProvider", "aiAddress", "aiModel", "aiProduction", "aiChatLimit"], saved = names.map { ($0, std.object(forKey: $0)) }
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t23a-" + UUID().uuidString, fm = FileManager.default
        let app = dir + "/app", downloads = dir + "/Downloads", backups = dir + "/backups"
        for d in [app, downloads, backups] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        try Data("echo 1284 orders > report.log\n".utf8).write(to: URL(fileURLWithPath: app + "/report.sh"))
        try Data("old".utf8).write(to: URL(fileURLWithPath: backups + "/report.tgz"))
        func plan(_ states: [String]) -> (name: String, input: [String: Any]) {
            ("plan", ["steps": zip(["Run report.sh on box", "Copy its log to Downloads", "Archive the log on box", "Copy the archive to backup"], states).map { ["text": $0, "state": $1] }])
        }
        func copy(_ from: String, to server: String, _ folder: String) -> (name: String, input: [String: Any]) {
            ("copy", ["from_server": "box", "from_path": from, "to_server": server, "to_folder": folder])
        }
        let need = { (s: String, l: String, f: String, w: String) -> [String: Any] in ["server": s, "level": l, "folder": f, "why": w] }
        let wire = Wire([
            (200, turn(calls: [plan(["doing", "todo", "todo", "todo"]),
                               ("request_scope", ["needs": [need("box", "commands", "", "run report.sh, make the archive"), need("mac", "write", downloads, "save the log"),
                                                            need("backup", "write", backups, "put the archive")]])])),
            (200, turn(calls: [("run_command", ["server": "box", "command": "sh report.sh", "folder": app])])),
            (200, turn(calls: [plan(["done", "doing", "todo", "todo"]), copy(app + "/report.log", to: "mac", downloads)])),
            (200, turn(calls: [plan(["done", "done", "doing", "todo"]), ("run_command", ["server": "box", "command": "tar -czf report.tgz report.log", "folder": app])])),
            (200, turn(calls: [plan(["done", "done", "done", "doing"]), copy(app + "/report.tgz", to: "backup", backups)])),
            (200, turn(calls: [plan(["done", "done", "done", "done"])])),
            (200, turn(text: "Done: the log is in Downloads, the archive on backup.")),
        ])
        (AISettings.keys, AISettings.transport) = (AIKeys(Keys()), wire.transport)
        var box = SavedServer(target: .local(port: 2)), backup = SavedServer(target: .local(port: 3))
        (box.name, backup.name) = ("box", "backup")
        ServerLock.servers = { [box, backup] }
        var asked: [String] = []
        AppDelegate.answering = { title, _, _ in asked.append(title); return title.hasPrefix("This chat has cost") && asked.filter { $0.hasPrefix("This chat") }.count == 1 ? 1 : 0 }
        let shell = panelApp(dir)
        shell.ops = OpsController(window: shell.window) { [unowned shell] in shell.jobFinished($0) }   // copies go as F5's
        defer {
            for (k, v) in saved { if let v { std.set(v, forKey: k) } else { std.removeObject(forKey: k) } }
            (AISettings.keys, AISettings.transport, AppDelegate.answering) = (.shared, AIHTTP.live, nil)
            ServerLock.servers = { [] }
            ServerLock.relock()
            shell.panels.forEach { $0.shutdown() }
            try? fm.removeItem(atPath: dir)
        }
        names.forEach(std.removeObject(forKey:))
        for (panel, t) in [(shell.panels[1], SFTPTarget.local(port: 2)), (shell.panels[0], .local(port: 3))] {
            panel.loadRemote(t, dir: dir, select: nil)
            for _ in 0..<300 where panel.remote?.dir != dir { try? await Task.sleep(for: .milliseconds(10)) }
            try #require(panel.remote?.dir == dir)
        }
        let panel = AIPanel(app: shell)
        panel.view.frame = NSRect(x: 0, y: 0, width: 420, height: 900)
        panel.build()
        panel.setMode(.agent)
        #expect(shown(panel).contains("nothing yet — the AI asks first") && shown(panel).contains("acts within"))
        func ask(_ q: String) async {
            for _ in 0..<300 where panel.turn == nil {
                panel.send(q)
                if panel.turn == nil { try? await Task.sleep(for: .milliseconds(10)) }
            }
            await done(panel)
        }
        await ask("Run report.sh on box, the log to my Downloads, an archive of it to backup")
        let first = try #require(wire.bodies.first)
        #expect(first["system"] as? String == AIChat.agentSystem && (first["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == AIChat.agentTools.map(\.name))
        #expect(asked == ["Allow the assistant this, until the chat ends?", "Let the assistant write over what is there?"], "\(asked)")
        #expect(wire.bodies.count == 7 && "\(wire.bodies[1]["messages"] ?? "")".contains("Allowed until the chat ends"))
        #expect(fm.contents(atPath: downloads + "/report.log") == Data("1284 orders\n".utf8))
        #expect(fm.contents(atPath: backups + "/report.tgz")?.prefix(2) == Data([0x1f, 0x8b]), "the archive, over the old one")
        var text = shown(panel)
        #expect(text.contains("· Agent") && text.contains("✓  Copy the archive to backup") && !text.contains("○") && text.contains("Done: the log"), "\(text)")
        let chips = { Set(views(panel.view, ChipButton.self).map(\.title).filter { $0.contains(":") }) }
        #expect(chips() == ["box: run commands", "this Mac: write into \(downloads)", "backup: write into \(backups)"], "\(chips())")

        // Ask in the same chat: a command its scope allows isn't run.
        panel.setMode(.ask)
        wire.then([(200, turn(calls: [("run_command", ["server": "box", "command": "touch \(dir)/made"])])), (200, turn(text: "I can't."))])
        await ask("Touch a file")
        #expect(!fm.fileExists(atPath: dir + "/made") && "\(wire.bodies.last?["messages"] ?? "")".contains("only reads") && wire.bodies.last?["system"] as? String == AIChat.askSystem)

        // The cap: past it, asked before the next request — Stop sends nothing, the chat stays; Go On goes.
        std.set(0.001, forKey: "aiChatLimit")
        let before = wire.bodies.count
        wire.then([(200, turn(text: "Going on."))])
        await ask("And now?")
        #expect(wire.bodies.count == before && asked.last?.hasPrefix("This chat has cost") == true && shown(panel).contains("spending cap"), "\(asked)")
        await ask("Go on")
        #expect(wire.bodies.count == before + 1 && shown(panel).contains("Going on.") && asked.filter { $0.hasPrefix("This chat has cost") }.count == 2)

        // New Chat: nothing allowed, the mode as it was; the row's + gives View, its chip's menu the level.
        click(try #require(views(panel.view, NSButton.self).first { $0.toolTip == "New Chat" }))
        text = shown(panel)
        #expect(panel.mode == .ask && panel.granted.isEmpty && text.contains("nothing yet"))
        let add = panel.addScopeMenu()
        #expect(Set(add.items.filter(\.isEnabled).map(\.title)) == ["this Mac", "box", "backup"], "\(add.items.map(\.title))")
        let item = try #require(add.items.first { $0.title == "box" })
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        for _ in 0..<300 where panel.granted.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(panel.granted.map(\.words) == ["box: read"] && chips() == ["box: read"], "\(panel.granted.map(\.words)) \(chips())")
        let g = try #require(panel.granted.first)
        #expect(panel.scopeMenu(g).items.filter(\.isEnabled).map(\.title) == ["View — reads only", "Take Back"], "Ask: View only")
        panel.setMode(.agent)
        let all = try #require(panel.scopeMenu(g).items.first { $0.title.hasPrefix("All") && $0.isEnabled })
        _ = (all.target as? NSObject)?.perform(all.action, with: all)
        for _ in 0..<300 where panel.granted.first?.level != .all { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(panel.granted.first?.level == .all && chips() == ["box: everything"], "\(chips())")
    }
}

/// Task 23 PR 6: ⌥-click on a command's line gives the chat that command and its output — while the AI is set up; on
/// its output, or with no AI, the click is SwiftTerm's. A selection made tells the app; the Add to Chat button by it
/// goes with a key. A process's arguments, as `ssh prod` typed in a local tab is read.
@MainActor @Test func aCommandOptionClickedGoesToTheChatWithItsOutput() async throws {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    let v = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    w.contentView!.addSubview(v)
    v.pasteboard = NSPasteboard(name: .init("dfm-t23o-" + UUID().uuidString))
    var got: [String] = [], ready = false
    (v.onCommandClick, v.chatReady) = ({ got.append($0) }, { ready })
    let key = { (c: String, code: UInt16) in
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code)!
    }
    v.feed(text: "$ ")
    for (cmd, out) in [("ls", ["a", "b"]), ("df", ["x"])] {   // rows: 0 "$ ls", 1 a, 2 b, 3 "$ df", 4 x, 5 "$ "
        v.feed(text: cmd)
        v.typed(key("\r", 36))
        v.feed(text: "\r\n" + out.map { $0 + "\r\n" }.joined() + "$ ")
    }
    let cell = v.caretFrame.size
    func click(_ row: Int) {
        let p = NSPoint(x: cell.width * 1.5, y: v.frame.height - (CGFloat(row) + 0.5) * cell.height)
        let e = { (t: NSEvent.EventType) in
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: .option, timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        v.mouseDown(with: e(.leftMouseDown))
        v.mouseUp(with: e(.leftMouseUp))
    }
    click(0)
    #expect(got.isEmpty, "no AI: SwiftTerm's click")
    ready = true
    for row in [0, 3, 1] { click(row) }
    #expect(got == ["$ ls\na\nb", "$ df\nx"], "\(got)")
    #expect(v.commandWithOutput() == "$ df\nx")

    DropTerminalView.leftButtonDown = { false }   // the real one may be held; never put back (Task13TerminalMouseTests)
    var told = 0
    v.onSelect = { told += 1 }
    v.selectAll()
    await drained()
    #expect(told == 1, "\(told)")
    v.showChatButton("Add to Chat") {}
    #expect(v.chatButton != nil)
    v.typed(key("x", 7))
    #expect(v.chatButton?.superview == nil)
    v.selectNone()
    v.showChatButton("Add to Chat") {}
    #expect(v.chatButton?.superview == nil, "no selection: no button")

    let me = try #require(EmbeddedTerminal.Tab.arguments(of: getpid()))
    #expect(me.first == CommandLine.arguments.first && me.count == CommandLine.arguments.count, "\(me)")
}

// MARK: - Task 23 PR 7: Edit

extension EditorWindowTests {   // the editor window is the app's one; `UserDefaults.standard` as the panel reads it
    /// Edit: the model's propose_edit is a card in its answer — hidden values as •••; Drop leaves a change out;
    /// Apply puts the rest into the file's editor tab (opened for it) as one ⌘Z step and writes nothing; a tab that
    /// changed since refuses a card. The mode stays through New Chat; Ask again goes with Ask's instructions.
    @Test func anEditIsACardAppliedToTheEditorAsOneUndo() async throws {
        let std = UserDefaults.standard, names = ["aiProvider", "aiAddress", "aiModel", "aiProduction"], saved = names.map { ($0, std.object(forKey: $0)) }
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-t23e-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/drafts", withIntermediateDirectories: true)
        let conf = dir + "/app.conf", base = "a = 1\npass" + "word=hunter22\nb = 2\nc = 3\n"
        try Data(base.utf8).write(to: URL(fileURLWithPath: conf))
        let stamp = try FileManager.default.attributesOfItem(atPath: conf)[.modificationDate] as? Date
        func propose(_ edits: [(String, String)]) -> String {
            turn(call: "propose_edit", input: #"{"server":"mac","path":\#(json(conf)),"edits":["#
                 + edits.map { #"{"old_text":\#(json($0.0)),"new_text":\#(json($0.1))}"# }.joined(separator: ",") + "]}")
        }
        let wire = Wire([(200, propose([("a = 1", "a = 9"), ("c = 3", "c = 4")])), (200, turn(text: "Two changes."))])
        (AISettings.keys, AISettings.transport) = (AIKeys(Keys()), wire.transport)
        AppDelegate.answering = { _, _, _ in 0 }   // reading on this Mac: allowed
        if let h = EditorHost.shared { h.docs.forEach { $0.closed(); $0.host = nil }; h.drafts?.release(); h.window?.orderOut(nil); EditorHost.shared = nil }
        EditorHost.restore(dir + "/drafts") { _, _, _, _ in ({ _ in }, {}) }
        let app = panelApp(dir)
        defer {
            for (k, v) in saved { if let v { std.set(v, forKey: k) } else { std.removeObject(forKey: k) } }
            (AISettings.keys, AISettings.transport, AppDelegate.answering) = (.shared, AIHTTP.live, nil)
            if let h = EditorHost.shared { h.stopComparing(); h.docs.forEach { $0.closed(); $0.host = nil }; h.drafts?.release(); h.window?.orderOut(nil); EditorHost.shared = nil }
            app.panels.forEach { $0.shutdown() }
            try? FileManager.default.removeItem(atPath: dir)
        }
        names.forEach(std.removeObject(forKey:))
        let panel = AIPanel(app: app)
        panel.view.frame = NSRect(x: 0, y: 0, width: 420, height: 900)
        panel.build()
        panel.setMode(.edit)
        #expect(shown(panel).contains("proposes changes to files"))
        func ask(_ q: String) async {
            for _ in 0..<300 where panel.turn == nil {
                panel.send(q)
                if panel.turn == nil { try? await Task.sleep(for: .milliseconds(10)) }
            }
            await done(panel)
        }
        await ask("Fix it")
        let first = try #require(wire.bodies.first)
        #expect(first["system"] as? String == AIChat.editSystem && (first["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == AIChat.editTools.map(\.name))
        #expect(wire.bodies.count == 2 && "\(wire.bodies[1]["messages"] ?? "")".contains("Shown to the user as a diff"), "only the model's requests")
        let text = shown(panel)
        #expect(text.contains("· Edit") && text.contains("app.conf · this Mac") && text.contains("2 changes") && text.contains("pass" + "word=•••"), "\(text)")
        #expect(!text.contains("hunter22"), "a hidden value stays hidden in the card")

        // Drop the second change, Apply: the file opens, only the first goes in — one ⌘Z — nothing on the disk.
        let toggles = views(panel.view, NSSegmentedControl.self).filter { $0.label(forSegment: 0) == "Keep" }
        try #require(toggles.count == 2)
        toggles[1].selectedSegment = 1
        _ = toggles[1].target?.perform(toggles[1].action, with: toggles[1])
        click(try #require(button(panel, "Apply to Editor")))
        for _ in 0..<250 where Editor.document(at: conf)?.storage.string.hasPrefix("a = 9") != true { try await Task.sleep(for: .milliseconds(20)) }
        let doc = try #require(Editor.document(at: conf))
        #expect(doc.storage.string == "a = 9\npass" + "word=hunter22\nb = 2\nc = 3\n" && doc.textView.selectedRange().location == 0)
        #expect(doc.textView.undoManager?.undoActionName == "AI Change" && shown(panel).contains("Applied to the editor"))
        #expect(button(panel, "Apply to Editor")?.isEnabled == false, "once")
        doc.textView.undoManager?.undo()
        #expect(doc.storage.string == base, "one ⌘Z")
        #expect(FileManager.default.contents(atPath: conf) == Data(base.utf8) && (try? FileManager.default.attributesOfItem(atPath: conf)[.modificationDate] as? Date) == stamp)

        // An Agent doesn't write a file open in the editor, by write_file or by a copy onto it: its card is the way —
        // a session with no card (an outside agent's, as here) is told to leave it to the user.
        let agent = AISession(app: app) { _, _ in 0 }
        var r = await agent.call("write_file", ["server": "mac", "path": .string(conf), "text": "x\n"])
        #expect(r.isError && r.text.contains("open in Kermo's editor: tell the user") && FileManager.default.contents(atPath: conf) == Data(base.utf8), "\(r.text)")
        try FileManager.default.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        try Data("y\n".utf8).write(to: URL(fileURLWithPath: dir + "/src/app.conf"))
        r = await agent.call("copy", ["from_server": "mac", "from_path": .string(dir + "/src/app.conf"), "to_server": "mac", "to_folder": .string(dir)])
        #expect(r.isError && r.text.contains("open in Kermo's editor: tell the user") && FileManager.default.contents(atPath: conf) == Data(base.utf8), "\(r.text)")
        try FileManager.default.linkItem(atPath: conf, toPath: dir + "/same.conf")   // the same file by another name
        r = await agent.call("write_file", ["server": "mac", "path": .string(dir + "/same.conf"), "text": "x\n"])
        #expect(r.isError && r.text.contains("open in Kermo's editor: tell the user") && FileManager.default.contents(atPath: conf) == Data(base.utf8), "\(r.text)")
        agent.proposes = { _, _, _ in }   // the chat's session: its card is the way
        r = await agent.call("write_file", ["server": "mac", "path": .string(conf), "text": "x\n"])
        #expect(r.isError && r.text.contains("propose the change with propose_edit") && FileManager.default.contents(atPath: conf) == Data(base.utf8), "\(r.text)")

        // A card on a tab that changed since: refused, the tab as it was.
        wire.then([(200, propose([("b = 2", "b = 5")])), (200, turn(text: "One more."))])
        await ask("And b?")
        doc.apply("# typed\n", over: NSRange(location: 0, length: 0), in: doc.current, named: "Typing")
        click(try #require(views(panel.view, NSButton.self).last { $0.title == "Apply to Editor" && $0.isEnabled }))
        #expect(shown(panel).contains("changed since this was proposed") && doc.storage.string == "# typed\n" + base)

        // The mode stays through New Chat; Ask goes with Ask's instructions and tools.
        click(try #require(views(panel.view, NSButton.self).first { $0.toolTip == "New Chat" }))
        #expect(panel.mode == .edit)
        panel.setMode(.ask)
        wire.then([(200, turn(text: "Fine."))])
        await ask("Just look")
        let last = try #require(wire.bodies.last)
        #expect(last["system"] as? String == AIChat.askSystem && (last["tools"] as? [[String: Any]])?.count == AIChat.askTools.count)

        // Past 200 changed lines: no Keep / Drop, no Apply — Open in Compare puts the proposal beside the file.
        let now = doc.storage.string, big = AIEdit.Proposal(base: now, proposed: now + (1...210).map { "line \($0)\n" }.joined())
        let card = EditCard(big, on: nil, path: conf, app: app)
        #expect(views(card, NSButton.self).map(\.title) == ["Open in Compare"] && views(card, NSTextView.self).contains { $0.string.contains("210 changed lines") })
        click(try #require(views(card, NSButton.self).first))
        #expect(EditorHost.tabs.comparison != nil && EditorHost.tabs.docs.contains { $0.snapshot?.title == "app.conf (proposed)" }, "the proposal, read-only, beside it")
        #expect(doc.storage.string == now)

        // A root tab and a server file's copy on this Mac aren't the chat's to read or change: its user's tab only.
        let copy = dir + "/copy.conf", user = SFTPTarget.local(port: 2)
        try Data("x\n".utf8).write(to: URL(fileURLWithPath: copy))
        Editor.open(URL(fileURLWithPath: copy), server: (user.asRoot(), "/etc/x.conf", AppDelegate.RemoteEdit(baseline: .nothing)))
        for _ in 0..<250 where Editor.editing(user.asRoot(), "/etc/x.conf") == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(Editor.editing(user.asRoot(), "/etc/x.conf") != nil && Editor.document(at: copy) != nil)
        #expect(EditCard.tab(user, "/etc/x.conf") == nil && EditCard.tab(nil, copy) == nil && EditCard.tab(nil, conf) === doc)
        let byPath = EditCard(AIEdit.Proposal(base: "x\n", proposed: "y\n"), on: nil, path: copy, app: app)
        click(try #require(views(byPath, NSButton.self).first { $0.title == "Apply to Editor" }))   // `Editor.open` finds that tab by the path
        for _ in 0..<100 where !views(byPath, NSTextField.self).contains(where: { $0.stringValue.contains("another file's copy") }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(views(byPath, NSTextField.self).contains { $0.stringValue.contains("another file's copy") } && Editor.editing(user.asRoot(), "/etc/x.conf")?.storage.string == "x\n")

        // A server's file (this Mac's sftp-server as "box", saved as production): the card says so; Apply goes through
        // the server's gate, opens its tab and changes only the tab.
        let srv = dir + "/srv.conf", box = SFTPTarget.local(port: 2)
        try Data("s = 1\nt = 2\n".utf8).write(to: URL(fileURLWithPath: srv))
        var boxSaved = SavedServer(target: box)
        (boxSaved.name, boxSaved.prod) = ("box", true)
        ServerLock.servers = { [boxSaved] }
        defer { ServerLock.servers = { [] } }
        let remote = EditCard(AIEdit.Proposal(base: "s = 1\nt = 2\n", proposed: "s = 1\nt = 3\n"), on: box, path: srv, app: app)
        #expect(views(remote, NSTextView.self).contains { $0.string.contains("srv.conf · box · production") })
        click(try #require(views(remote, NSButton.self).first { $0.title == "Apply to Editor" }))
        for _ in 0..<250 where Editor.tab(onServer: box, srv, root: false)?.storage.string != "s = 1\nt = 3\n" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(Editor.tab(onServer: box, srv, root: false)?.storage.string == "s = 1\nt = 3\n" && FileManager.default.contents(atPath: srv) == Data("s = 1\nt = 2\n".utf8))
        #expect(views(remote, NSTextField.self).contains { $0.stringValue.contains("Applied to the editor") })
    }
}
