import Foundation

/// A typed tool the model (tool use) or an outside agent (MCP) may call: what it is told about it, and how the places
/// it touches are read from its arguments — before anything runs. The runners are the app's.
public struct AITool: Sendable {
    /// What the tool is for, as a step in the chat shows it. What the scope checks is each target's access.
    public enum Kind: String, Sendable { case read, write, run, transfer, ui }

    public struct Param: Sendable {
        public var name: String, about: String
        public var required = true
        /// A list of objects with these text fields, each of them there: `propose_edit`'s edits, `request_scope`'s needs.
        public var fields: [String]?
    }

    /// One place a call touches: the argument naming the server, the one with the path (if any), the access —
    /// `.run("command")` names the argument holding the command.
    public struct Touch: Sendable {
        public var server: String
        public var path: String?
        public var access: AITarget.Access
    }

    public var name: String, about: String
    public var kind: Kind
    public var params: [Param]
    /// Empty: a tool that touches no place (what is on screen, asking for scope).
    public var places: [Touch] = []

    /// The arguments as JSON Schema — `input_schema` of tool use, `inputSchema` of MCP.
    public var schema: ToolValue {
        .object(["type": "object", "additionalProperties": false,
                 "required": .array(params.filter(\.required).map { .string($0.name) }),
                 "properties": .object(Dictionary(uniqueKeysWithValues: params.map { p in
                     var o: [String: ToolValue] = ["type": "string", "description": .string(p.about)]
                     if let f = p.fields {
                         o["type"] = "array"
                         o["items"] = .object(["type": "object", "additionalProperties": false, "required": .array(f.map(ToolValue.string)),
                                               "properties": .object(Dictionary(uniqueKeysWithValues: f.map { ($0, .object(["type": "string"])) }))])
                     }
                     return (p.name, .object(o))
                 }))])
    }

    /// `v` is a list of objects with exactly these text fields.
    private static func isList(_ v: [ToolValue], of fields: [String]) -> Bool {
        v.allSatisfy { item in
            guard case .object(let o) = item else { return false }
            return Set(o.keys) == Set(fields) && o.values.allSatisfy { if case .string = $0 { true } else { false } }
        }
    }

    /// What the call touches, `resolve` turning a server's name into its place. nil — nothing may be done: an
    /// argument the tool doesn't have, a missing or mistyped one, a server nobody knows, a path that isn't absolute
    /// (`AITarget.normal`).
    public func targets(_ args: [String: ToolValue], resolve: (String) -> AIPlace?) -> [AITarget]? {
        for (name, value) in args {
            guard let p = params.first(where: { $0.name == name }) else { return nil }
            switch value {
            case .array(let items) where p.fields.map({ Self.isList(items, of: $0) }) == true: break
            case .string where p.fields == nil: break
            default: return nil
            }
        }
        guard params.allSatisfy({ !$0.required || args[$0.name] != nil }) else { return nil }
        func text(_ name: String?) -> String? { if case .string(let s)? = name.flatMap({ args[$0] }) { s } else { nil } }
        var out: [AITarget] = []
        for t in places {
            var access = t.access
            if case .run(let arg) = access {
                guard let command = text(arg) else { return nil }
                access = .run(command)
            }
            guard let place = text(t.server).flatMap(resolve), let target = AITarget(place, text(t.path), access) else { return nil }
            out.append(target)
        }
        return out
    }
}

/// What a tool call came to, as tool use and MCP hand it back: text, and whether it is an error — said in words
/// the model can act on ("the user didn't allow it"), never a code.
public struct AIResult: Sendable, Equatable, Codable {
    public var text: String
    public var isError = false

    public init(_ text: String) { self.text = text }
    public static func failure(_ text: String) -> AIResult {
        var r = AIResult(text)
        r.isError = true
        return r
    }
}

public enum AITools {
    private static let server = AITool.Param(name: "server", about: "A server by the name Kermo shows, or \"mac\" for this Mac")
    private static func path(_ about: String) -> AITool.Param { .init(name: "path", about: about + " — an absolute path") }

    /// Every tool, in the order a model is told. No delete, move or archive yet: they come with their runners.
    public static let all: [AITool] = [
        AITool(name: "focus", about: "What the user has in front of them: both panels (server, folder, cursor, marked names), the editor's file and selection, the terminal tab.",
               kind: .ui, params: []),
        AITool(name: "request_scope", about: "Ask the user once for all a task needs in this chat, the least that does it: they allow the whole list or nothing.",
               kind: .ui, params: [.init(name: "needs", about: "One item each. server: a name Kermo shows, or \"mac\". level: view (read), write (into folder), "
                                         + "commands (run commands that change things there), all (everything there). folder: the absolute folder for write, else \"\". "
                                         + "why: what for, one short line the user reads", fields: ["server", "level", "folder", "why"])]),
        AITool(name: "plan", about: "Show the user the task's steps as a checklist, and keep it current: call it again with the whole list as it stands, in the same message as the next step's own call.",
               kind: .ui, params: [.init(name: "steps", about: "Every step in order. text: one short line. state: todo, doing, done or skipped", fields: ["text", "state"])]),
        AITool(name: "list_folder", about: "The names in a folder, with sizes and dates.", kind: .read, params: [server, path("The folder")],
               places: [.init(server: "server", path: "path", access: .read)]),
        AITool(name: "read_file", about: "A text file's content.", kind: .read, params: [server, path("The file")],
               places: [.init(server: "server", path: "path", access: .read)]),
        AITool(name: "terminal_output", about: "What the last command printed in the terminal tab of that server.", kind: .read, params: [server],
               places: [.init(server: "server", access: .read)]),
        AITool(name: "server_info", about: "The server at a glance: system, load, memory, disks.", kind: .read, params: [server],
               places: [.init(server: "server", access: .read)]),
        AITool(name: "run_command", about: "Run a shell command and get its output. Use a typed tool instead wherever one fits: copy and write_file ask before they write over anything, a command may not.",
               kind: .run, params: [server, .init(name: "command", about: "The command, for a POSIX shell"),
                                    .init(name: "folder", about: "Where to run it — an absolute path; the login folder if left out", required: false)],
               places: [.init(server: "server", path: "folder", access: .run("command"))]),
        AITool(name: "copy", about: "Copy a file or a folder from one place to another — between servers and this Mac too.", kind: .transfer,
               params: [.init(name: "from_server", about: server.about), .init(name: "from_path", about: "What to copy — an absolute path"),
                        .init(name: "to_server", about: server.about), .init(name: "to_folder", about: "The folder to copy into — an absolute path")],
               places: [.init(server: "from_server", path: "from_path", access: .read), .init(server: "to_server", path: "to_folder", access: .write)]),
        AITool(name: "write_file", about: "Write a text file that isn't open in the editor.", kind: .write,
               params: [server, path("The file"), .init(name: "text", about: "The whole new content")],
               places: [.init(server: "server", path: "path", access: .write)]),
        AITool(name: "propose_edit", about: "Propose a change to a text file as a diff the user keeps or drops piece by piece and applies to Kermo's editor; nothing is saved. All of a file's changes in one call.",
               kind: .ui, params: [server, path("The file"),
                                   .init(name: "edits", about: "The changes, made in this order: each old_text exactly as it is in the file — spaces and line ends too — and there once; new_text replaces it",
                                         fields: ["old_text", "new_text"])],
               places: [.init(server: "server", path: "path", access: .read)]),
        AITool(name: "open_in_editor", about: "Open a file in Kermo's editor for the user.", kind: .ui, params: [server, path("The file")],
               places: [.init(server: "server", path: "path", access: .read)]),
    ]

    /// What an outside agent (MCP) is offered: `plan` is the chat's card — an agent shows its own.
    public static let forAgents = all.filter { $0.name != "plan" }
}
