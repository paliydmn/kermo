import AppKit
import DFMCore

/// Settings › AI: the user's own provider — which, where, which model — its key in the Keychain, and Test. Nothing of
/// it exists until used: no provider object, no request, the key unread. Test is the one request, and the user's.
@MainActor
enum AISettings {
    /// The user's choice, 2026-11-17.
    static let anthropicModel = "claude-sonnet-5-5"
    static var keys = AIKeys.shared                  // tests: a store in memory
    static var transport: AITransport = AIHTTP.live  // tests: recorded answers
    /// Test's words and the models it found, for the settings as they were — a change forgets them.
    private(set) static var tested = ""
    private(set) static var models: [String] = []
    private static var testing: Task<Void, Never>?

    static func kind(_ d: UserDefaults) -> AIEndpoint.Kind { d.string(forKey: "aiProvider") == "openai" ? .openai : .anthropic }

    /// The address the settings name; nil — what's typed isn't one.
    static func address(_ d: UserDefaults) -> URL? {
        let typed = d.string(forKey: "aiAddress") ?? ""
        return typed.isEmpty ? AIEndpoint.defaultAddress(kind(d)) : AIEndpoint.address(typed)
    }

    /// With its key, read here the first time a launch needs it (`has` first: no item, no Keychain read).
    static func endpoint(_ d: UserDefaults) -> AIEndpoint? {
        guard let a = address(d) else { return nil }
        let k = kind(d)
        return AIEndpoint(k, address: a, model: d.string(forKey: "aiModel") ?? (k == .anthropic ? anthropicModel : ""), key: keys.has(a) ? keys.key(a) : nil)
    }

    /// The settings changed: Test's words are for what was. `models`: the list too (another provider or address).
    static func changed(models forget: Bool = true) {
        testing?.cancel()
        (testing, tested) = (nil, "")
        if forget { models = [] }
        (NSApp?.delegate as? AppDelegate)?.aiChanged()   // a key now, or none: the terminal watches for ✨ or stops
        SettingsWindow.refreshShown()
    }

    /// Another provider: its own address and models — not the other one's.
    static func providerChanged(_ d: UserDefaults) {
        d.removeObject(forKey: "aiAddress")
        d.removeObject(forKey: "aiModel")
        changed()
    }

    private static func say(_ words: String) {
        tested = words
        SettingsWindow.refreshShown()
    }

    static func addressNote(_ d: UserDefaults) -> String {
        guard let a = address(d) else { return "Not an address: http:// or https://, then the host" }
        var said: [String] = []
        if (d.string(forKey: "aiAddress") ?? "").isEmpty {
            said.append("Empty: \(a.absoluteString)" + (kind(d) == .openai ? ". Your own server: Ollama http://localhost:11434/v1, LM Studio http://localhost:1234/v1" : ""))
        }
        if a.scheme == "http" && !AIEndpoint.isLocal(a) {
            // macOS (App Transport Security) refuses plain http to a name; an address in numbers it lets through.
            let numbers = (a.host ?? "").contains(":") || (a.host ?? "").split(separator: ".").allSatisfy { Int($0) != nil }
            // With a key there the chat sends nothing (`AIEndpoint.problem`): the key never goes unencrypted.
            said.append(!numbers ? "Plain http: macOS doesn't let Kermo reach a name on the internet that way — use https"
                        : keys.has(a) ? "Plain http: with a key for it the chat sends nothing there — use https, or remove the key"
                        : "Plain http: the chat goes unencrypted")
        }
        return said.joined(separator: ". ")
    }

    static func keyNote(_ d: UserDefaults) -> String {
        guard let a = address(d) else { return "" }
        if keys.has(a) { return "In the Keychain, for \(a.host ?? a.absoluteString) only" }
        return kind(d) == .anthropic
            ? "Create one at platform.claude.com. A Claude plan doesn't include the API, but Max, Ultra and Team come with monthly API credits"
            : "Optional: a server on this Mac or your network usually takes none"
    }

    static func modelNote(_ d: UserDefaults) -> String {
        kind(d) == .anthropic ? "Empty: \(anthropicModel). Test lists the models your key may use"
            : "Test lists the server's models; empty: a server on this Mac or your network gets its first"
    }

    static func hasKey(_ d: UserDefaults) -> Bool { address(d).map(keys.has) ?? false }
    /// The AI is set up: a key for its address, or a model on this Mac (an OpenAI-compatible server here needs none).
    static func ready(_ d: UserDefaults) -> Bool { hasKey(d) || kind(d) == .openai && address(d).map(AIEndpoint.isLocal) == true }

    /// Settings › AI's "Never Send": nothing from a production server goes to the AI.
    static func neverProd(_ d: UserDefaults) -> Bool { d.string(forKey: "aiProduction") == "never" }

    /// ✨ Explain shows where something failed: Settings › AI's row on (its word first: no Keychain look when off) and
    /// the AI set up.
    static func explains(_ d: UserDefaults) -> Bool { (d.object(forKey: "aiHints") as? Bool ?? true) && ready(d) }

    /// nil: removed.
    static func saveKey(_ d: UserDefaults, _ key: String?) {
        guard let a = address(d) else { return say(key == nil ? "Not an address." : "Not an address — the key wasn't saved.") }
        let ok = keys.set(key, for: a)
        changed()
        if !ok { say("The Keychain didn't take the key.") }
    }

    /// The models the key may use (free), then one word from the chosen model: a fraction of a cent. With no model
    /// chosen, a server on this Mac or your network gets its first (OpenAI's first may be one that can't chat).
    static func test(_ d: UserDefaults) {
        guard testing == nil else { return }
        guard var e = endpoint(d) else { return say("Not an address.") }
        if let why = e.problem(model: false) { return say(why) }
        say("Testing…")
        testing = Task {
            do {
                let list = try await e.provider(transport).models()
                try Task.checkCancellation()
                models = list
                if e.model.isEmpty, AIEndpoint.isLocal(e.address), let first = list.first {
                    e.model = first
                    d.set(first, forKey: "aiModel")
                }
                guard !e.model.isEmpty else {
                    throw AIError(.other, list.isEmpty ? "The server lists no models."
                                  : "\(e.keyToSend == nil ? "The server answered" : "Key accepted"). Choose a model from the list, then Test again.")
                }
                var stop: AIStop?
                for try await event in e.provider(transport).send([AIMessage(.user, [.text("Reply with the single word OK.")])], tools: [], system: "") {
                    if case .done(_, let s, _) = event { stop = s }
                }
                guard !Task.isCancelled else { return }
                testing = nil
                say(stop == nil ? "" : "\(e.model) answered · \(list.count) model\(list.count == 1 ? "" : "s") to choose from")
            } catch {
                guard !Task.isCancelled else { return }
                testing = nil
                say(error.localizedDescription)
            }
        }
    }
}
