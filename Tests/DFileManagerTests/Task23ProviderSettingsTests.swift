import AppKit
import DFMCore
import Testing
@testable import DFileManager

// Task 23 PR 4: Settings › AI, your own AI — the key row keeps the key in its store for the address only (never in
// defaults), Test lists the models and asks for one word. A store in memory and recorded answers: no Keychain, no network.

private final class Store: AIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    var all: [String: String] { lock.withLock { items } }
    func has(_ account: String) -> Bool { lock.withLock { items[account] != nil } }
    func get(_ account: String) -> String? { lock.withLock { items[account] } }
    func set(_ key: String?, _ account: String) -> Bool { lock.withLock { items[account] = key; return true } }
}

/// Recorded answers by path: the model list, a one-word turn; what was asked.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    var all: [String] { lock.withLock { urls } }
    var transport: AITransport {
        { [self] r in
            let url = r.url?.absoluteString ?? ""
            lock.withLock { urls.append(url) }
            let body = url.contains("/models")
                ? #"{"data":[{"id":"claude-sonnet-5-5"},{"id":"claude-opus-5-5"}],"has_more":false}"#
                : [#"{"type":"message_start","message":{"usage":{"input_tokens":5,"output_tokens":1}}}"#,
                   #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                   #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"OK"}}"#,
                   #"{"type":"content_block_stop","index":0}"#,
                   #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}"#,
                   #"{"type":"message_stop"}"#].map { "data: \($0)\n\n" }.joined()
            let (s, c) = AsyncThrowingStream<Data, Error>.makeStream()
            c.yield(Data(body.utf8))
            c.finish()
            return AIHTTPResponse(status: 200, headers: [:], body: s)
        }
    }
}

@MainActor private func find<T: NSView>(_ w: SettingsWindow, _ label: String, as: T.Type) -> T? {
    func find(_ v: NSView) -> T? {
        if let t = v as? T, v.accessibilityLabel() == label { return t }
        return v.subviews.lazy.compactMap(find).first
    }
    return w.tabs.tabViewItems.lazy.compactMap { $0.viewController.map { find($0.view) } ?? nil }.first
}
@MainActor private func texts(_ w: SettingsWindow) -> [String] {
    func all(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(all) }
    return w.tabs.tabViewItems.flatMap { $0.viewController.map { all($0.view) } ?? [] }
}
@MainActor private func click(_ c: NSControl) { _ = (c.target as? NSObject)?.perform(c.action, with: c) }

extension ServerLockTests {
    /// (`UserDefaults.standard`: where the code reads the settings; put back after.)
    @Test func yourOwnAIKeepsTheKeyForItsAddressAndTests() async throws {
        let std = UserDefaults.standard, names = ["aiProvider", "aiAddress", "aiModel"], saved = names.map { ($0, std.object(forKey: $0)) }
        let store = Store(), asked = Asked()
        (AISettings.keys, AISettings.transport) = (AIKeys(store), asked.transport)
        defer {
            for (k, v) in saved { if let v { std.set(v, forKey: k) } else { std.removeObject(forKey: k) } }
            (AISettings.keys, AISettings.transport) = (.shared, AIHTTP.live)
            AISettings.changed()
        }
        names.forEach(std.removeObject(forKey:))
        _ = NSApplication.shared
        let app = AppDelegate()
        app.commands = app.makeCommands()
        let w = SettingsWindow(app: app, tabs: app.settingsTabs, defaults: std)
        w.refresh()
        let key = ["kermo", "row", "K2x9"].joined(separator: "-")

        let field = try #require(find(w, "API key", as: NSSecureTextField.self))
        #expect(field.placeholderString == "Paste your key" && find(w, "Remove — API key", as: NSButton.self)?.isEnabled == false)
        field.stringValue = key
        click(try #require(find(w, "Save — API key", as: NSButton.self)))
        #expect(store.all == ["https://api.anthropic.com": key], "the Keychain's item is the address's")
        #expect(field.stringValue.isEmpty && field.placeholderString == "Saved · paste to replace")
        #expect(!std.dictionaryRepresentation().values.contains { "\($0)".contains(key) }, "never in defaults")
        await until { texts(w).contains { $0.hasPrefix("In the Keychain, for api.anthropic.com") } }

        #expect(app.commands.contains { $0.id == "ai.test" && $0.hidden }, "the button's command")
        AISettings.test(std)   // what it runs: app.run wants panels
        await until { AISettings.tested.contains("answered") }
        #expect(AISettings.tested == "claude-sonnet-5-5 answered · 2 models to choose from")
        #expect(asked.all == ["https://api.anthropic.com/v1/models?limit=1000", "https://api.anthropic.com/v1/messages"])
        w.refresh()
        #expect(find(w, "Model", as: NSComboBox.self)?.objectValues.count == 2, "the list from Test")

        std.set("https://gateway.example.com", forKey: "aiAddress")   // another address: no key there, Test's words gone
        AISettings.changed()
        #expect(!AISettings.hasKey(std) && AISettings.tested.isEmpty && AISettings.endpoint(std)?.key == nil)
        std.removeObject(forKey: "aiAddress")
        w.refresh()
        click(try #require(find(w, "Remove — API key", as: NSButton.self)))
        #expect(store.all.isEmpty && !AISettings.hasKey(std))

        // An address still being typed when Save is pressed: the key is filed under it, not the one before.
        w.tabs.selectedTabViewItemIndex = try #require(w.tabs.tabViewItems.firstIndex { $0.label == "AI" })   // its fields in the window
        let address = try #require(find(w, "Address", as: NSTextField.self))
        #expect(w.window.makeFirstResponder(address) && address.currentEditor() != nil)
        (address.currentEditor() as? NSTextView)?.insertText("https://gw.example.com/v1", replacementRange: NSRange(location: 0, length: 0))   // typed, not ended
        field.stringValue = key
        click(try #require(find(w, "Save — API key", as: NSButton.self)))
        #expect(store.all == ["https://gw.example.com/v1": key] && std.string(forKey: "aiAddress") == "https://gw.example.com/v1")

        // Another provider: its own address and model; a public server's first model isn't picked for you.
        std.set("claude-opus-5-5", forKey: "aiModel")
        let provider = try #require(find(w, "Provider", as: NSSegmentedControl.self))
        provider.selectedSegment = 1
        click(provider)
        #expect(std.string(forKey: "aiProvider") == "openai" && std.object(forKey: "aiAddress") == nil && std.object(forKey: "aiModel") == nil)
        AISettings.test(std)
        await until { AISettings.tested.contains("answered") }
        #expect(AISettings.tested == "The server answered. Choose a model from the list, then Test again." && std.object(forKey: "aiModel") == nil,
                "no key for OpenAI's address: none was sent, so none was accepted")
        std.set("http://localhost:11434/v1", forKey: "aiAddress")
        click(provider)   // the chosen one again: nothing changes
        #expect(std.string(forKey: "aiAddress") == "http://localhost:11434/v1")
        std.set("gw.example.com", forKey: "aiAddress")
        AISettings.saveKey(std, key)
        #expect(AISettings.tested == "Not an address — the key wasn't saved.")
        // Plain http to a public address in numbers: unencrypted without a key; with one, the chat sends nothing there.
        std.set("http://203.0.113.5/v1", forKey: "aiAddress")
        #expect(AISettings.addressNote(std) == "Plain http: the chat goes unencrypted")
        _ = AISettings.keys.set(key, for: try #require(URL(string: "http://203.0.113.5/v1")))
        #expect(AISettings.addressNote(std).contains("the chat sends nothing there"), "\(AISettings.addressNote(std))")
    }
}
