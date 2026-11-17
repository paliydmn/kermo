import Foundation

/// An OpenAI-compatible server — OpenAI itself, Ollama, LM Studio, llama.cpp, vLLM — through `/chat/completions`,
/// streamed (shapes from their docs and sources on 2026-11-17 — task 23 pr4-report.md, phase 0). The key is optional:
/// a server on this Mac usually takes none.
public struct AIOpenAI: AIProvider {
    let endpoint: AIEndpoint
    let transport: AITransport

    public init(_ endpoint: AIEndpoint, transport: @escaping AITransport = AIHTTP.live) { (self.endpoint, self.transport) = (endpoint, transport) }

    private func request(_ path: String, body: ToolValue? = nil) -> URLRequest {
        var headers: [String: String] = [:]
        headers["authorization"] = endpoint.keyToSend.map { "Bearer \($0)" }
        return AIWire.request(endpoint.address.appendingPathComponent(path), body: body, headers: headers)
    }

    public func send(_ messages: [AIMessage], tools: [AITool], system: String) -> AsyncThrowingStream<AIEvent, Error> {
        AIWire.stream(request("chat/completions", body: body(messages, tools: tools, system: system)), endpoint, transport, Parser())
    }

    public func models() async throws -> [String] {
        guard case .array(let all)? = try await AIWire.get(request("models"), endpoint, transport)["data"] else { return [] }
        return all.compactMap { AIWire.string(AIWire.object($0)["id"]) }
    }

    /// No token limit: each server has its own default, and a local model's context may be smaller than any number
    /// picked here.
    func body(_ messages: [AIMessage], tools: [AITool], system: String) -> ToolValue {
        var b: [String: ToolValue] = ["model": .string(endpoint.model), "stream": true, "stream_options": ["include_usage": true],
                                      "messages": .array((system.isEmpty ? [] : [["role": "system", "content": .string(system)]]) + messages.flatMap(Self.wire))]
        if !tools.isEmpty {
            b["tools"] = .array(tools.map { ["type": "function", "function": ["name": .string($0.name), "description": .string($0.about), "parameters": $0.schema]] })
        }
        return .object(b)
    }

    /// A message as OpenAI's: a user turn's results as `tool` messages first, then its text; an assistant turn as
    /// one message with its calls. Another provider's `.kept` blocks aren't for this one.
    static func wire(_ m: AIMessage) -> [ToolValue] {
        let text = m.text
        if m.role == .user {
            let results: [ToolValue] = m.parts.compactMap {
                guard case .result(let id, let r) = $0 else { return nil }
                return ["role": "tool", "tool_call_id": .string(id), "content": .string(r.isError ? "Error: \(r.text)" : r.text)]
            }
            return results + (text.isEmpty ? [] : [["role": "user", "content": .string(text)]])
        }
        var o: [String: ToolValue] = ["role": "assistant", "content": text.isEmpty ? .null : .string(text)]
        if !m.calls.isEmpty {
            o["tool_calls"] = .array(m.calls.map { c in
                ["id": .string(c.id), "type": "function",
                 "function": ["name": .string(c.name), "arguments": .string(String(decoding: AIWire.data(.object(c.args ?? [:])), as: UTF8.self))]]
            })
        }
        return [.object(o)]
    }

    /// Chunks: text deltas; tool calls by `index` — in pieces (OpenAI, LM Studio) or whole in one (Ollama); the
    /// finish reason in any chunk; usage in the last, with no choices.
    struct Parser: AIParser {
        private var text = ""
        private var calls: [Int: (id: String, name: String, args: String)] = [:]
        private var finish: String?
        private var usage = AIUsage()

        mutating func take(_ payload: String) throws -> [AIEvent] {
            guard payload != "[DONE]" else { return [] }
            guard case .object(let m)? = AIWire.json(payload) else { throw AIWire.damaged }
            if let e = m["error"], e != .null {
                throw AIError(.other, "The server stopped the answer: \(AIWire.string(AIWire.object(e)["message"]) ?? AIWire.string(e) ?? "an error")")
            }
            if case .object(let u)? = m["usage"] {
                let cached = AIWire.int(AIWire.object(u["prompt_tokens_details"])["cached_tokens"]) ?? 0
                usage.input = max(0, (AIWire.int(u["prompt_tokens"]) ?? 0) - cached)
                (usage.cacheRead, usage.output) = (cached, AIWire.int(u["completion_tokens"]) ?? 0)
            }
            guard case .array(let choices)? = m["choices"], let first = choices.first else { return [] }
            let c = AIWire.object(first), d = AIWire.object(c["delta"])
            finish = AIWire.string(c["finish_reason"]) ?? finish
            if case .array(let parts)? = d["tool_calls"] {
                for (n, part) in parts.enumerated() {
                    let p = AIWire.object(part), f = AIWire.object(p["function"]), id = AIWire.string(p["id"]) ?? ""
                    var i = AIWire.int(p["index"]) ?? n
                    if p["index"] == nil, !id.isEmpty, let had = calls[i]?.id, !had.isEmpty, had != id { i = (calls.keys.max() ?? -1) + 1 }   // whole calls, no index
                    var call = calls[i] ?? ("", "", "")
                    if call.id.isEmpty { call.id = id }
                    if call.name.isEmpty { call.name = AIWire.string(f["name"]) ?? "" }
                    switch f["arguments"] {
                    case .string(let s)?: call.args += s
                    case .object?: call.args += String(decoding: AIWire.data(f["arguments"]!), as: UTF8.self)   // a server that sends the object
                    default: break
                    }
                    calls[i] = call
                }
            }
            guard let t = AIWire.string(d["content"]), !t.isEmpty else { return [] }
            text += t
            return [.text(t)]
        }

        /// Without a finish reason the answer broke off — an error in the stream too (Ollama just ends it).
        mutating func end() throws -> AIEvent {
            guard let finish else { throw AIError.cut }
            var stop: AIStop = switch finish {
            case "stop": .done
            case "tool_calls": .tools
            case "length": .maxTokens
            case "content_filter": .refused(nil)
            default: .other(finish)
            }
            var parts: [AIMessage.Part] = text.isEmpty ? [] : [.text(text)]
            if !calls.isEmpty {
                guard stop == .tools || stop == .done else { throw AIError(.cut, "The model stopped (\(finish)) while asking for a tool — nothing was run.") }
                stop = .tools
                for (i, c) in calls.sorted(by: { $0.key < $1.key }) {
                    parts.append(.call(AIToolUse(id: c.id.isEmpty ? "call_\(i)" : c.id, name: c.name, args: AIWire.args(c.args))))
                }
            }
            return .done(AIMessage(.assistant, parts), stop, usage)
        }
    }
}
