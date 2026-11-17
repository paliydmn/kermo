import Foundation

/// Anthropic's Messages API, streamed (API version 2026-10-21; shapes from its docs on 2026-11-17 — task 23
/// pr4-report.md, phase 0). Thinking is left to the model's default; its blocks come back as `.kept` and go back
/// unchanged, as a turn with tools must. One cache mark on the request: tools, system and the chat so far are reused.
public struct AIAnthropic: AIProvider {
    public static let version = "2026-10-21"
    static let maxTokens = 32000   // under every current model's ceiling
    let endpoint: AIEndpoint
    let transport: AITransport

    public init(_ endpoint: AIEndpoint, transport: @escaping AITransport = AIHTTP.live) { (self.endpoint, self.transport) = (endpoint, transport) }

    private func request(_ path: String, body: ToolValue? = nil) -> URLRequest {
        var headers = ["anthropic-version": Self.version]
        headers["x-api-key"] = endpoint.keyToSend
        return AIWire.request(endpoint.address.appendingPathComponent(path), body: body, headers: headers)
    }

    public func send(_ messages: [AIMessage], tools: [AITool], system: String) -> AsyncThrowingStream<AIEvent, Error> {
        AIWire.stream(request("v1/messages", body: body(messages, tools: tools, system: system)), endpoint, transport, Parser())
    }

    public func models() async throws -> [String] {
        var r = request("v1/models")
        r.url = r.url?.appending(queryItems: [URLQueryItem(name: "limit", value: "1000")])
        guard case .array(let all)? = try await AIWire.get(r, endpoint, transport)["data"] else { return [] }
        return all.compactMap { AIWire.string(AIWire.object($0)["id"]) }
    }

    func body(_ messages: [AIMessage], tools: [AITool], system: String) -> ToolValue {
        var b: [String: ToolValue] = ["model": .string(endpoint.model), "max_tokens": .number(Double(Self.maxTokens)), "stream": true,
                                      "messages": .array(messages.compactMap(Self.wire)), "cache_control": ["type": "ephemeral"]]
        if !system.isEmpty { b["system"] = .string(system) }
        if !tools.isEmpty { b["tools"] = .array(tools.map { ["name": .string($0.name), "description": .string($0.about), "input_schema": $0.schema] }) }
        return .object(b)
    }

    /// A message in Anthropic's shape; results first in a user turn, as the API wants. Nothing to send: nil.
    static func wire(_ m: AIMessage) -> ToolValue? {
        let parts = m.parts.filter { if case .result = $0 { true } else { false } } + m.parts.filter { if case .result = $0 { false } else { true } }
        let blocks: [ToolValue] = parts.compactMap { p in
            switch p {
            case .text(let t): return t.isEmpty ? nil : ["type": "text", "text": .string(t)]
            case .call(let c): return ["type": "tool_use", "id": .string(c.id), "name": .string(c.name), "input": .object(c.args ?? [:])]
            case .result(let id, let r):
                var o: [String: ToolValue] = ["type": "tool_result", "tool_use_id": .string(id), "is_error": .bool(r.isError)]
                if !r.text.isEmpty { o["content"] = .string(r.text) }
                return .object(o)
            case .kept(let v): return v
            }
        }
        return blocks.isEmpty ? nil : ["role": .string(m.role.rawValue), "content": .array(blocks)]
    }

    /// The stream's events, block by block; the turn and its calls only once `message_stop` came.
    struct Parser: AIParser {
        private struct Block {
            var start: [String: ToolValue]
            var text = "", json = "", signature = ""
            var closed = false
            var type: String { AIWire.string(start["type"]) ?? "" }
        }
        private var blocks: [Int: Block] = [:]
        private var reason: String?, category: String?
        private var usage = AIUsage()
        private var stopped = false

        mutating func take(_ payload: String) throws -> [AIEvent] {
            guard case .object(let m)? = AIWire.json(payload) else { throw AIWire.damaged }   // never skipped: the rest could still parse
            let i = AIWire.int(m["index"]) ?? -1
            switch AIWire.string(m["type"]) {
            case "message_start": count(AIWire.object(AIWire.object(m["message"])["usage"]))
            case "content_block_start":
                let start = AIWire.object(m["content_block"])
                blocks[i] = Block(start: start, text: AIWire.string(start["text"]) ?? AIWire.string(start["thinking"]) ?? "",
                                  signature: AIWire.string(start["signature"]) ?? "")
            case "content_block_delta":
                guard blocks[i] != nil else { return [] }
                let d = AIWire.object(m["delta"])
                switch AIWire.string(d["type"]) {
                case "text_delta":
                    let t = AIWire.string(d["text"]) ?? ""
                    blocks[i]!.text += t
                    return t.isEmpty ? [] : [.text(t)]
                case "input_json_delta": blocks[i]!.json += AIWire.string(d["partial_json"]) ?? ""
                case "thinking_delta": blocks[i]!.text += AIWire.string(d["thinking"]) ?? ""
                case "signature_delta": blocks[i]!.signature = AIWire.string(d["signature"]) ?? ""
                default: break
                }
            case "content_block_stop": blocks[i]?.closed = true
            case "message_delta":
                let d = AIWire.object(m["delta"])
                reason = AIWire.string(d["stop_reason"]) ?? reason
                category = AIWire.string(AIWire.object(d["stop_details"])["category"]) ?? category
                count(AIWire.object(m["usage"]))
            case "message_stop": stopped = true
            case "error":
                let e = AIWire.object(m["error"]), message = AIWire.string(e["message"]) ?? "an error"
                switch AIWire.string(e["type"]) {
                case "overloaded_error": throw AIError(.busy, "Anthropic is overloaded: \(message) — try again shortly.")
                case "rate_limit_error": throw AIError(.limit, "Anthropic: limit reached: \(message)")
                default: throw AIError(.other, "Anthropic stopped the answer: \(message)")
                }
            default: break   // ping, and types added later
            }
            return []
        }

        /// The counts are running totals: the latest of each is the turn's.
        private mutating func count(_ u: [String: ToolValue]) {
            usage.input = AIWire.int(u["input_tokens"]) ?? usage.input
            usage.output = AIWire.int(u["output_tokens"]) ?? usage.output
            usage.cacheRead = AIWire.int(u["cache_read_input_tokens"]) ?? usage.cacheRead
            usage.cacheWrite = AIWire.int(u["cache_creation_input_tokens"]) ?? usage.cacheWrite
        }

        mutating func end() throws -> AIEvent {
            guard stopped, blocks.values.allSatisfy(\.closed) else { throw AIError.cut }
            let stop: AIStop = switch reason {
            case "end_turn"?, "stop_sequence"?: .done
            case "tool_use"?: .tools
            case "max_tokens"?: .maxTokens
            case "refusal"?: .refused(category)
            default: .other(reason ?? "none")
            }
            var parts: [AIMessage.Part] = []
            for (_, b) in blocks.sorted(by: { $0.key < $1.key }) {
                switch b.type {
                case "text": if !b.text.isEmpty { parts.append(.text(b.text)) }
                case "tool_use":
                    guard stop == .tools else { throw AIError(.cut, "The model stopped (\(reason ?? "no reason")) while asking for a tool — nothing was run.") }
                    let args = b.json.isEmpty ? AIWire.object(b.start["input"]) : AIWire.args(b.json)   // all in its start, or in pieces
                    parts.append(.call(AIToolUse(id: AIWire.string(b.start["id"]) ?? "", name: AIWire.string(b.start["name"]) ?? "", args: args)))
                case "thinking": parts.append(.kept(["type": "thinking", "thinking": .string(b.text), "signature": .string(b.signature)]))
                default: parts.append(.kept(.object(b.start)))   // redacted_thinking: whole in its start
                }
            }
            return .done(AIMessage(.assistant, parts), stop, usage)
        }
    }
}
