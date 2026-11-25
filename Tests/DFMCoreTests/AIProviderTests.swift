import Foundation
import Testing
@testable import DFMCore

// Task 23 PR 4: providers on the user's own key — Anthropic and OpenAI-compatible adapters on recorded answers,
// cut in awkward places; errors in words without the key; stopping; the key's store. No network.

/// A recorded answer: its head, and its body in chunks cut at `cuts` (byte offsets); `hang`: the body never ends.
private struct Answer {
    var status = 200
    var headers: [String: String] = [:]
    var body: String
    var cuts: [Int] = []
    var hang = false
}

/// The transport: hands out the answers in turn and keeps what was asked; `stopped` once a body's reader went away.
private final class Wire: @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [Answer]
    private var asked: [URLRequest] = []
    private var gone = false
    init(_ answers: Answer...) { self.answers = answers }
    var requests: [URLRequest] { lock.withLock { asked } }
    var stopped: Bool { lock.withLock { gone } }

    var transport: AITransport {
        { [self] request in
            let a = lock.withLock { asked.append(request); return answers[min(asked.count, answers.count) - 1] }
            let (body, c) = AsyncThrowingStream<Data, Error>.makeStream()
            let bytes = Data(a.body.utf8)
            var at = 0
            for cut in a.cuts.filter({ $0 > 0 && $0 < bytes.count }) + [bytes.count] where cut > at {
                c.yield(Data(bytes[at..<cut]))
                at = cut
            }
            c.onTermination = { [self] _ in lock.withLock { gone = true } }
            if !a.hang { c.finish() }
            return AIHTTPResponse(status: a.status, headers: a.headers, body: body)
        }
    }
}

private func sse(_ payloads: [String]) -> String { payloads.map { "event: e\r\ndata: \($0)\r\n\r\n" }.joined() }
private func everyByte(_ s: String) -> [Int] { Array(1..<s.utf8.count) }

/// What a turn came to: its events, or the error that ended it.
private func run(_ stream: AsyncThrowingStream<AIEvent, Error>) async -> (events: [AIEvent], error: AIError?) {
    var events: [AIEvent] = []
    do { for try await e in stream { events.append(e) } } catch { return (events, error as? AIError ?? AIError(.other, "\(error)")) }
    return (events, nil)
}
private func done(_ events: [AIEvent]) -> (AIMessage, AIStop, AIUsage)? {
    if case .done(let m, let s, let u)? = events.last { (m, s, u) } else { nil }
}

/// Not shaped like any known secret: only the very string being masked hides it.
private let key = ["kermo", "test", "Q7f3", "zz91"].joined(separator: "-")
private let anthropic = AIEndpoint(.anthropic, address: AIEndpoint.defaultAddress(.anthropic), model: "claude-sonnet-5-5", key: key)
private let local = AIEndpoint(.openai, address: AIEndpoint.address("http://localhost:11434/v1")!, model: "qwen3", key: nil)

// MARK: - Anthropic

private let start = #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5-5","stop_reason":null,"usage":{"input_tokens":12,"cache_read_input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":1}}}"#
private let thinking = [#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
                        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
                        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBsig"}}"#,
                        #"{"type":"content_block_stop","index":0}"#]
private func text(_ i: Int, _ pieces: [String]) -> [String] {
    [#"{"type":"content_block_start","index":\#(i),"content_block":{"type":"text","text":""}}"#, #"{"type": "ping"}"#]
        + pieces.map { #"{"type":"content_block_delta","index":\#(i),"delta":{"type":"text_delta","text":"\#($0)"}}"# }
        + [#"{"type":"content_block_stop","index":\#(i)}"#]
}
private func toolUse(_ i: Int, _ id: String, _ name: String, _ json: [String]) -> [String] {
    [#"{"type":"content_block_start","index":\#(i),"content_block":{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}}"#]
        + json.map { #"{"type":"content_block_delta","index":\#(i),"delta":{"type":"input_json_delta","partial_json":"\#($0)"}}"# }
        + [#"{"type":"content_block_stop","index":\#(i)}"#]
}
private func ending(_ reason: String, _ details: String = "null") -> [String] {
    [#"{"type":"message_delta","delta":{"stop_reason":"\#(reason)","stop_sequence":null,"stop_details":\#(details)},"usage":{"output_tokens":40}}"#,
     #"{"type":"message_stop"}"#]
}
private let chat = sse([start] + thinking + text(1, ["Привіт, ", "світе 🌍"]) + ending("end_turn"))
private let tools = sse([start] + text(0, ["Let me look."])
                        + toolUse(1, "toolu_1", "list_folder", ["", #"{\"server\": \"ma"#, #"c\", \"path\": \"/tmp/ü"#, #"\"}"#])
                        + toolUse(2, "toolu_2", "focus", [""]) + ending("tool_use"))

@Test func anthropicStreamsTextAndKeepsThinking() async throws {
    for cuts in [[], everyByte(chat)] {   // whole, and byte by byte: inside a letter, a line, the JSON
        let wire = Wire(Answer(body: chat, cuts: cuts))
        let (events, error) = await run(anthropic.provider(wire.transport).send([AIMessage(.user, [.text("Hi")])], tools: [], system: ""))
        #expect(error == nil)
        #expect(Array(events.dropLast()) == [.text("Привіт, "), .text("світе 🌍")])
        let (m, stop, usage) = try #require(done(events))
        #expect(m.parts == [.kept(["type": "thinking", "thinking": "", "signature": "EqQBsig"]), .text("Привіт, світе 🌍")])
        #expect(stop == .done)
        #expect(usage.input == 12 && usage.output == 40 && usage.cacheRead == 100, "the latest running total of each")
    }
}

@Test func anthropicToolCallsComeWholeAndOnlyAtTheEnd() async throws {
    for cuts in [[], everyByte(tools)] {
        let wire = Wire(Answer(body: tools, cuts: cuts))
        let (events, error) = await run(anthropic.provider(wire.transport).send([AIMessage(.user, [.text("Look")])], tools: AITools.all, system: "Be careful"))
        #expect(error == nil)
        let (m, stop, _) = try #require(done(events))
        #expect(stop == .tools)
        #expect(m.calls == [AIToolUse(id: "toolu_1", name: "list_folder", args: ["server": "mac", "path": "/tmp/ü"]),
                            AIToolUse(id: "toolu_2", name: "focus", args: [:])], "two calls; one with no arguments at all")
        #expect(events.dropLast().allSatisfy { if case .text = $0 { true } else { false } }, "a call is never an event of its own")
    }
}

/// Anywhere the answer breaks off before `message_stop`, it is an error — never a turn, never a call.
@Test func aCutAnswerIsNeverACall() async throws {
    let bytes = Array(tools.utf8), whole = bytes.count - 2   // the last line, message_stop, is whole once its new line came
    for n in stride(from: 0, to: bytes.count, by: 3) {
        let wire = Wire(Answer(body: String(decoding: bytes[..<n], as: UTF8.self)))
        let (events, error) = await run(anthropic.provider(wire.transport).send([], tools: [], system: ""))
        if n < whole {
            #expect(error?.kind == .cut && done(events) == nil, "cut at \(n)")
        } else {
            #expect(done(events)?.0.calls.count == 2)
        }
    }
    for reason in ["max_tokens", "refusal"] {   // a turn that stopped for another reason while writing a call
        let body = sse([start] + toolUse(0, "toolu_1", "write_file", [#"{\"server\": \"mac\", \"text\": \"half"#]) + ending(reason))
        let (events, error) = await run(anthropic.provider(Wire(Answer(body: body)).transport).send([], tools: [], system: ""))
        #expect(error?.kind == .cut && error?.words.contains(reason) == true && done(events) == nil)
    }
    // A damaged payload isn't skipped: what's left could still parse into another call ({"path":"/tmp/a"} + "}").
    let damaged = Wire(Answer(body: sse([start] + toolUse(0, "toolu_1", "read_file", [#"{\"path\":\"/tmp/a"#]) + ["{garbage", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"}"}}"#]), hang: true))
    let broken = await run(anthropic.provider(damaged.transport).send([], tools: [], system: ""))
    #expect(broken.error?.kind == .cut && done(broken.events) == nil)
    await until { damaged.stopped }
    #expect(damaged.stopped, "the body let go: its connection is cancelled, not read on")
    let inStart = sse([start, #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_9","name":"focus","input":{"why":"all at once"}}}"#,
                       #"{"type":"content_block_stop","index":0}"#] + ending("tool_use"))
    #expect(await done(run(anthropic.provider(Wire(Answer(body: inStart)).transport).send([], tools: [], system: "")).events)?.0.calls
            == [AIToolUse(id: "toolu_9", name: "focus", args: ["why": "all at once"])], "arguments whole in the block's start")
    let refused = sse([start] + text(0, ["I can"]) + ending("refusal", #"{"type":"refusal","category":"cyber","explanation":null}"#))
    #expect(await done(run(anthropic.provider(Wire(Answer(body: refused)).transport).send([], tools: [], system: "")).events)?.1 == .refused("cyber"))
}

@Test func anthropicErrorsInWordsWithoutTheKey() async throws {
    func failure(_ a: Answer) async -> AIError? {
        await run(anthropic.provider(Wire(a).transport).send([AIMessage(.user, [.text("Hi")])], tools: [], system: "")).error
    }
    let echoed = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key: \#(key)"},"request_id":"req_1"}"#
    let denied = try #require(await failure(Answer(status: 401, body: echoed)))
    #expect(denied.kind == .key && denied.words.contains("401") && denied.words.contains("invalid x-api-key"))
    #expect(!denied.words.contains(key), "a server that echoes the key: it is masked")
    let limited = try #require(await failure(Answer(status: 429, headers: ["retry-after": "7"], body: #"{"type":"error","error":{"type":"rate_limit_error","message":"Too many"}}"#)))
    #expect(limited.kind == .limit && limited.retryAfter == 7 && limited.words.contains("7 s"))
    #expect(await failure(Answer(status: 529, body: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))?.kind == .busy)
    #expect(await failure(Answer(status: 413, body: "<html><body>413 Request Entity Too Large</body></html>"))?.words.contains("413") == true, "a proxy's page")
    let straddling = try #require(await failure(Answer(status: 401, body: String(repeating: "x", count: 296) + " " + key)))
    #expect(!straddling.words.contains(String(key.prefix(3))), "masked before it is cut at 300: no part of it left")
    #expect(await failure(Answer(status: 302, headers: ["location": "https://elsewhere.example"], body: ""))?.words.contains("elsewhere") == true)

    let midway = sse([start] + text(0, ["Hel"]) + [#"{"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}"#])
    let (events, error) = await run(anthropic.provider(Wire(Answer(body: midway)).transport).send([], tools: [], system: ""))
    #expect(events == [.text("Hel")] && error?.kind == .busy, "an error after the 200 ends the turn in words")
}

@Test func anthropicRequestIsTheDocumentedShape() async throws {
    let wire = Wire(Answer(body: chat))
    let history = [AIMessage(.user, [.text("List /tmp")]),
                   AIMessage(.assistant, [.kept(["type": "thinking", "thinking": "", "signature": "s1"]), .text("Looking."),
                                          .call(AIToolUse(id: "toolu_1", name: "list_folder", args: ["server": "mac", "path": "/tmp"]))]),
                   AIMessage(.user, [.text("and?"), .result(id: "toolu_1", AIResult("a.txt"))])]
    _ = await run(anthropic.provider(wire.transport).send(history, tools: AITools.all, system: "Be careful"))
    let r = try #require(wire.requests.first)
    #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages" && r.httpMethod == "POST")
    #expect(r.value(forHTTPHeaderField: "x-api-key") == key && r.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
    let body = AIWire.object(try JSONDecoder().decode(ToolValue.self, from: try #require(r.httpBody)))
    #expect(body["model"] == "claude-sonnet-5-5" && body["stream"] == true && body["system"] == "Be careful" && body["cache_control"] == ["type": "ephemeral"])
    #expect(body["temperature"] == nil && body["top_p"] == nil, "2026-10-21 refuses them")
    guard case .array(let ts)? = body["tools"], case .array(let ms)? = body["messages"] else { Issue.record("tools, messages"); return }
    #expect(ts.count == AITools.all.count && AIWire.object(ts[0])["input_schema"] == AITools.all[0].schema)
    #expect(AIWire.object(ms[1])["content"] == [["type": "thinking", "thinking": "", "signature": "s1"], ["type": "text", "text": "Looking."],
                                                ["type": "tool_use", "id": "toolu_1", "name": "list_folder", "input": ["server": "mac", "path": "/tmp"]]],
            "thinking goes back exactly as it came, in its place")
    #expect(AIWire.object(ms[2])["content"] == [["type": "tool_result", "tool_use_id": "toolu_1", "content": "a.txt", "is_error": false],
                                                ["type": "text", "text": "and?"]], "results first")
}

@Test func theKeyGoesOnlyWhereItMay() async throws {
    func header(_ address: String, _ kind: AIEndpoint.Kind) async -> String? {
        let wire = Wire(Answer(body: chat))
        let e = AIEndpoint(kind, address: AIEndpoint.address(address)!, model: "m", key: key)
        _ = await run(e.provider(wire.transport).send([], tools: [], system: ""))
        return wire.requests.first.flatMap { $0.value(forHTTPHeaderField: "x-api-key") ?? $0.value(forHTTPHeaderField: "authorization") }
    }
    #expect(await header("https://api.anthropic.com", .anthropic) == key)
    #expect(await header("http://203.0.113.5:8080/v1", .openai) == nil, "plain http to a public address: never")
    #expect(AIEndpoint(.openai, address: AIEndpoint.address("http://203.0.113.5:8080/v1")!, model: "m", key: key).problem() != nil)
    #expect(await header("http://192.168.1.20:1234/v1", .openai) == "Bearer \(key)", "your own network")
    #expect(await header("http://localhost:11434/v1", .openai) == "Bearer \(key)")
    let plain = AIEndpoint(.openai, address: AIEndpoint.address("http://203.0.113.5/v1")!, model: "m", key: nil)
    #expect(plain.problem() == nil, "no key: allowed, the row says it goes in plain text")
    #expect(AIEndpoint(.anthropic, address: AIEndpoint.defaultAddress(.anthropic), model: "m", key: nil).problem() != nil)

    for shown in ["\(anthropic)", String(reflecting: anthropic), { var s = ""; dump(anthropic, to: &s); return s }()] {
        #expect(!shown.contains(key) && shown.contains("•••"), "no description holds it: \(shown)")
    }
}

/// Stopping the reader stops the connection, and nothing comes after.
@Test func stoppingEndsTheConnectionAndTheEvents() async throws {
    let wire = Wire(Answer(body: sse([start] + Array(text(0, ["first"]).dropLast())), hang: true))
    let stream = anthropic.provider(wire.transport).send([], tools: [], system: "")
    let seen = Seen()
    let reader = Task { do { for try await e in stream { seen.add(e) } } catch { seen.add(.text("error: \(error)")) } }
    await until { seen.all.count == 1 }
    reader.cancel()
    await until { wire.stopped }
    #expect(wire.stopped, "the body's reader went away")
    try await Task.sleep(for: .milliseconds(50))
    #expect(seen.all == [.text("first")], "no event, not even an error, after the stop")
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AIEvent] = []
    func add(_ e: AIEvent) { lock.withLock { events.append(e) } }
    var all: [AIEvent] { lock.withLock { events } }
}

@Test func streamCeilings() throws {
    var sse = AISSE(maxLine: 64, maxTotal: 1000)
    #expect(try sse.feed(Data("data: {\"a\":".utf8)) == [])
    #expect(try sse.feed(Data("1}\r\n\r\n: comment\nevent: x\ndata:2\n".utf8)) == ["{\"a\":1}", "2"])
    #expect(throws: AIError.self, "one line past its ceiling") { try sse.feed(Data(String(repeating: "x", count: 65).utf8)) }
    var whole = AISSE(maxLine: 64, maxTotal: 1000)
    #expect(throws: AIError.self, "a long line with its new line in the same chunk") { try whole.feed(Data(("data: " + String(repeating: "x", count: 80) + "\n").utf8)) }
    var all = AISSE(maxLine: 64, maxTotal: 100)
    #expect(throws: AIError.self, "the whole answer past its ceiling") { for _ in 0..<20 { _ = try all.feed(Data("data: 1234\n".utf8)) } }
}

@Test func modelsAreListed() async throws {
    let wire = Wire(Answer(body: #"{"data":[{"type":"model","id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5"},{"type":"model","id":"claude-opus-5-5"}],"has_more":false}"#),
                    Answer(body: #"{"object":"list","data":[{"id":"qwen3","object":"model","owned_by":"library"}]}"#))
    #expect(try await anthropic.provider(wire.transport).models() == ["claude-sonnet-5-5", "claude-opus-5-5"])
    #expect(wire.requests[0].url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000" && wire.requests[0].httpMethod == "GET")
    #expect(try await local.provider(wire.transport).models() == ["qwen3"])
    #expect(wire.requests[1].url?.absoluteString == "http://localhost:11434/v1/models" && wire.requests[1].value(forHTTPHeaderField: "authorization") == nil)
}

// MARK: - OpenAI-compatible

private func chunk(_ delta: String, finish: String? = nil) -> String {
    #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish.map { "\"\($0)\"" } ?? "null")}],"usage":null}"#
}
private let usage = #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[],"usage":{"prompt_tokens":120,"completion_tokens":9,"total_tokens":129,"prompt_tokens_details":{"cached_tokens":100}}}"#

@Test func openAIStreamsTextAndUsage() async throws {
    let body = sse([chunk(#"{"role":"assistant","content":""}"#), chunk(#"{"content":"Добрий "}"#), chunk(#"{"content":"день"}"#),
                    chunk("{}", finish: "stop"), usage, "[DONE]"])
    for cuts in [[], everyByte(body)] {
        let (events, error) = await run(local.provider(Wire(Answer(body: body, cuts: cuts)).transport).send([], tools: [], system: ""))
        #expect(error == nil && Array(events.dropLast()) == [.text("Добрий "), .text("день")])
        let (m, stop, u) = try #require(done(events))
        #expect(m.parts == [.text("Добрий день")] && stop == .done && u.input == 20 && u.cacheRead == 100 && u.output == 9)
    }
}

@Test func openAIToolCallsInPiecesOrWhole() async throws {
    // LM Studio, OpenAI: by index, in pieces; later pieces without an id or a name.
    let pieces = sse([chunk(#"{"tool_calls":[{"index":0,"id":"814890118","type":"function","function":{"name":"list_folder","arguments":""}}]}"#),
                      chunk(#"{"tool_calls":[{"index":0,"id":null,"type":null,"function":{"arguments":"{\"server\":\"mac\","}}]}"#),
                      chunk(#"{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"focus","arguments":"{}"}}]}"#),
                      chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"\"path\":\"/tmp\"}"}}]}"#),
                      chunk("{}", finish: "tool_calls"), "[DONE]"])
    let whole = sse([chunk(#"{"role":"assistant","content":"","tool_calls":[{"id":"call_x","index":0,"type":"function","function":{"name":"list_folder","arguments":"{\"server\":\"mac\",\"path\":\"/tmp\"}"}},{"id":"call_y","index":1,"type":"function","function":{"name":"focus","arguments":"{}"}}]}"#),
                     chunk("{}", finish: "stop"), "[DONE]"])   // Ollama: whole, and the reason in a chunk of its own
    for (body, ids) in [(pieces, ["814890118", "call_b"]), (whole, ["call_x", "call_y"])] {
        let (events, error) = await run(local.provider(Wire(Answer(body: body, cuts: everyByte(body))).transport).send([], tools: AITools.all, system: ""))
        #expect(error == nil)
        let (m, stop, _) = try #require(done(events))
        #expect(stop == .tools)
        #expect(m.calls == [AIToolUse(id: ids[0], name: "list_folder", args: ["server": "mac", "path": "/tmp"]), AIToolUse(id: ids[1], name: "focus", args: [:])])
    }
    let noIndex = sse(["", #"{"choices":[{"index":0,"delta":{"tool_calls":[{"id":"a","index":null,"type":"function","function":{"name":"focus","arguments":"{}"}}]},"finish_reason":null}],"error":null}"#,
                       #"{"choices":[{"index":0,"delta":{"tool_calls":[{"id":"b","type":"function","function":{"name":"focus","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#])
    #expect(await done(run(local.provider(Wire(Answer(body: noIndex)).transport).send([], tools: [], system: "")).events)?.0.calls.map(\.id) == ["a", "b"],
            "whole calls without an index, one a chunk: two calls, not one; \"error\": null is no error; \"data:\" alone is a keep-alive")
    let broken = sse([chunk(#"{"tool_calls":[{"index":0,"id":"c","function":{"name":"focus","arguments":"{\"server\": "}}]}"#), chunk("{}", finish: "tool_calls")])
    #expect(await done(run(local.provider(Wire(Answer(body: broken)).transport).send([], tools: [], system: "")).events)?.0.calls == [AIToolUse(id: "c", name: "focus", args: nil)],
            "a finished call whose arguments aren't a JSON object: a call nothing may run")
}

@Test func openAICutsAndErrors() async throws {
    func turn(_ a: Answer) async -> (events: [AIEvent], error: AIError?) { await run(local.provider(Wire(a).transport).send([], tools: [], system: "")) }
    let call = chunk(#"{"tool_calls":[{"index":0,"id":"c","function":{"name":"write_file","arguments":"{\"text\":\"ha"}}]}"#)
    #expect(await turn(Answer(body: sse([chunk(#"{"content":"Hi"}"#), call]))).error?.kind == .cut, "no finish reason: broke off")
    #expect(await turn(Answer(body: sse([call, chunk("{}", finish: "length")]))).error?.words.contains("length") == true)
    let crashed = await turn(Answer(body: sse([chunk(#"{"content":"Hi"}"#), #"{"error":{"message":"model runner crashed","type":"api_error"}}"#])))
    #expect(crashed.events == [.text("Hi")] && crashed.error?.words.contains("model runner crashed") == true)
    let loading = await turn(Answer(status: 503, headers: ["retry-after": "3"], body: #"{"error":{"code":503,"message":"Loading model","type":"unavailable_error"}}"#))
    #expect(loading.error?.kind == .busy && loading.error?.words.contains("Loading model") == true && loading.error?.retryAfter == 3)
    let openai = AIEndpoint(.openai, address: AIEndpoint.defaultAddress(.openai), model: "m", key: key)
    let denied = await run(openai.provider(Wire(Answer(status: 401, body: #"{"error":{"message":"Incorrect API key provided: \#(key)","type":"invalid_request_error","code":"invalid_api_key"}}"#)).transport).send([], tools: [], system: "")).error
    #expect(denied?.kind == .key && denied?.words.contains(key) == false)
}

@Test func openAIRequestIsTheDocumentedShape() async throws {
    let wire = Wire(Answer(body: sse([chunk("{}", finish: "stop")])))
    let e = AIEndpoint(.openai, address: AIEndpoint.defaultAddress(.openai), model: "gpt-x", key: key)
    let history = [AIMessage(.user, [.text("List /tmp")]),
                   AIMessage(.assistant, [.kept(["type": "thinking"]), .call(AIToolUse(id: "call_1", name: "list_folder", args: ["path": "/tmp", "server": "mac"]))]),
                   AIMessage(.user, [.text("and?"), .result(id: "call_1", .failure("not allowed"))])]
    _ = await run(e.provider(wire.transport).send(history, tools: AITools.all, system: "Be careful"))
    let r = try #require(wire.requests.first)
    #expect(r.url?.absoluteString == "https://api.openai.com/v1/chat/completions" && r.value(forHTTPHeaderField: "authorization") == "Bearer \(key)")
    let body = AIWire.object(try JSONDecoder().decode(ToolValue.self, from: try #require(r.httpBody)))
    #expect(body["stream_options"] == ["include_usage": true] && body["max_tokens"] == nil)
    #expect(body["messages"] == [["role": "system", "content": "Be careful"], ["role": "user", "content": "List /tmp"],
                                 ["role": "assistant", "content": .null, "tool_calls": [["id": "call_1", "type": "function",
                                    "function": ["name": "list_folder", "arguments": #"{"path":"/tmp","server":"mac"}"#]]]],
                                 ["role": "tool", "tool_call_id": "call_1", "content": "Error: not allowed"], ["role": "user", "content": "and?"]],
            "another provider's kept block isn't sent; the result before the text")
    guard case .array(let ts)? = body["tools"] else { Issue.record("tools"); return }
    #expect(ts[0] == ["type": "function", "function": ["name": "focus", "description": .string(AITools.all[0].about), "parameters": AITools.all[0].schema]])
}

// MARK: - Addresses and keys

@Test func addressesAreOneSpelling() {
    #expect(AIEndpoint.address(" HTTPS://API.Anthropic.com/ ")?.absoluteString == "https://api.anthropic.com")
    #expect(AIEndpoint.address("http://localhost:11434/v1/")?.absoluteString == "http://localhost:11434/v1")
    for bad in ["", "api.anthropic.com", "ftp://x.com", "https://user:pw@x.com", "https://x.com/v1?k=1", "https://"] {
        #expect(AIEndpoint.address(bad) == nil, "\(bad)")
    }
    for (host, isLocal) in [("localhost", true), ("127.0.0.1", true), ("10.1.2.3", true), ("172.16.0.1", true), ("172.32.0.1", false),
                            ("192.168.1.1", true), ("mac-mini.local", true), ("[::1]", true), ("203.0.113.5", false), ("api.openai.com", false),
                            ("localhost.example.com", false), ("192.168.1.1.nip.io", false)] {
        #expect(AIEndpoint.isLocal(URL(string: "http://\(host):1/")!) == isLocal, "\(host)")
    }
}

/// The store in memory: how often the key was read.
private final class Memory: AIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private(set) var reads = 0
    var deny = false
    func has(_ account: String) -> Bool { lock.withLock { items[account] != nil } }
    func get(_ account: String) -> String? { lock.withLock { reads += 1; return deny ? nil : items[account] } }
    func set(_ key: String?, _ account: String) -> Bool { lock.withLock { items[account] = key; return true } }
}

@Test func aKeyIsReadOnceALaunchAndBelongsToItsAddress() {
    let store = Memory(), keys = AIKeys(store)
    let a = AIEndpoint.defaultAddress(.anthropic), other = AIEndpoint.address("https://gateway.example.com")!
    #expect(!keys.has(a) && store.reads == 0, "has() never reads a key")
    _ = store.set(key, a.absoluteString)
    #expect(keys.has(a) && !keys.has(other) && store.reads == 0)
    #expect(keys.key(a) == key && keys.key(a) == key && store.reads == 1, "read once, then from memory")
    #expect(keys.key(other) == nil, "another address has none: the key never goes there")
    keys.set(nil, for: a)
    #expect(!keys.has(a) && keys.key(a) == nil && !store.has(a.absoluteString))
    keys.set("new-one", for: a)
    #expect(keys.key(a) == "new-one" && store.reads == 3, "set is remembered as it is written (the read of none, after Remove, wasn't kept)")
    var shown = ""
    dump(keys, to: &shown)
    #expect(!shown.contains("new-one") && !"\(keys)".contains("new-one"), "no key in a description")
    let denied = Memory(), later = AIKeys(denied)
    _ = denied.set(key, a.absoluteString)
    denied.deny = true
    #expect(later.has(a) && later.key(a) == nil, "the Keychain said no")
    denied.deny = false
    #expect(later.key(a) == key, "a refused read isn't kept: the next use asks again")
}

// MARK: - Prices (task 23 PR 5b)

private func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

@Test func dollarsAtAnthropicsPricesForItsOwnModelsOnly() async throws {
    var u = AIUsage()
    (u.input, u.output, u.cacheRead, u.cacheWrite) = (1_000_000, 100_000, 1_000_000, 1_000_000)
    #expect(near(AIPrice.dollars("claude-sonnet-5-5", u), 2 + 1 + 0.10 + 2.5), "a cache write is 1.25× input, a read the table's")
    #expect(near(AIPrice.dollars("claude-haiku-4-5-20251001", u), 1 + 0.5 + 0.10 + 1.25), "a date after the id")
    #expect(near(AIPrice.dollars("claude-opus-5", u), 5 + 2.5 + 0.5 + 6.25) && near(AIPrice.dollars("claude-opus-5-5", u), 4 + 2 + 0.2 + 5))
    for unknown in ["claude-opus-5-6", "claude-opus-5-5-preview", "claude-opus", "gpt-5", "", "claude-sonnet-5-5-2026"] {
        #expect(AIPrice.dollars(unknown, u) == nil, "\(unknown): never a neighbour's price")
    }
    // Haiku 5.5 costs five times as much for a request whose prompt passes 100K tokens — a request's, not a turn's.
    var small = AIUsage()
    (small.input, small.output) = (40_000, 1_000)
    var turn = AIUsage()
    for _ in 0..<3 {
        var r = small
        r.dollars = AIPrice.dollars("claude-haiku-5-5", r)
        turn.add(r)
    }
    #expect(near(turn.dollars, 3 * (40_000 * 0.10 + 1_000 * 0.50) / 1e6) && turn.input == 120_000)
    var big = small
    big.cacheRead = 70_000
    #expect(near(AIPrice.dollars("claude-haiku-5-5", big), (40_000 * 0.50 + 70_000 * 0.05 + 1_000 * 2.50) / 1e6))

    // The adapter prices each request at Anthropic's own address only; a gateway's prices are its own.
    let (events, _) = await run(anthropic.provider(Wire(Answer(body: chat)).transport).send([AIMessage(.user, [.text("Hi")])], tools: [], system: ""))
    #expect(near(try #require(done(events)).2.dollars, (12 * 2 + 100 * 0.10 + 40 * 10) / 1e6))
    var gateway = anthropic
    gateway.address = AIEndpoint.address("https://gw.example.com")!
    let (other, _) = await run(gateway.provider(Wire(Answer(body: chat)).transport).send([AIMessage(.user, [.text("Hi")])], tools: [], system: ""))
    #expect(try #require(done(other)).2.dollars == nil)
}
