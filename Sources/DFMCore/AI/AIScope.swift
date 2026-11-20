import Foundation

/// Where a tool call acts: this Mac, or a server by the key the app gives it — one key per server however its address
/// is written (what `ssh -G` says it reaches, once learned). An address nobody can place gets a key of its own, so it
/// matches no grant.
public enum AIPlace: Hashable, Sendable {
    case mac, server(String)
}

/// One thing a tool call touches: a place, a path there when the tool names one, and what is done to it.
public struct AITarget: Hashable, Sendable {
    public enum Access: Hashable, Sendable {
        case read, write, remove
        case run(String)   // the command
    }
    public let place: AIPlace
    public let path: String?
    public let access: Access

    /// nil — the call is malformed, nothing is checked or done: a path that isn't `normal`, or writing / removing
    /// with no path at all.
    public init?(_ place: AIPlace, _ path: String? = nil, _ access: Access) {
        var normal: String?
        if let path {
            guard let n = Self.normal(path, home: place == .mac ? NSHomeDirectory() : nil) else { return nil }
            normal = n
        } else if access == .write || access == .remove { return nil }
        (self.place, self.path, self.access) = (place, normal, access)
    }

    /// An absolute path by its words alone — `//`, `/./` and a final `/` gone; `~` only where `home` is known (this
    /// Mac). nil: relative, empty, a control character, or any `..` — refused rather than resolved, since a symlink
    /// before it makes the words lie. Symlinks themselves the core can't see: `/srv/app/link` may lead out of
    /// `/srv/app` (the limit of a folder grant).
    public static func normal(_ path: String, home: String? = nil) -> String? {
        var p = path
        if let home, p == "~" || p.hasPrefix("~/") { p = home + p.dropFirst() }
        guard p.hasPrefix("/"), !p.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        let parts = p.split(separator: "/").filter { $0 != "." }
        return parts.contains("..") ? nil : "/" + parts.joined(separator: "/")
    }
}

/// A tool call as the scope sees it. `overwrites`: a `.write` target exists already — the tool's runner finds out
/// (stat) and says false; until it does, it is taken to exist.
public struct AICall: Sendable {
    public var tool: AITool
    public var targets: [AITarget]
    public var overwrites: Bool

    public init(_ tool: AITool, _ targets: [AITarget], overwrites: Bool = true) {
        (self.tool, self.targets, self.overwrites) = (tool, targets, overwrites)
    }
}

/// A chat's scope: where × what the user allowed the model, until the chat ends. A value — the session holds it.
public struct AIScope: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable {
        case view, work, all
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// What a place is allowed. View: read. Work: also write into `folders` and, with `commands`, run anything
    /// there. All: everything. Folders don't hold a command in: that is why commands are a grant of their own.
    public struct Grant: Sendable, Equatable {
        public var level: Level
        public var folders: [String] = []
        public var commands = false
    }

    /// What the scope lacks for a call: exactly what `grant` takes ("Allow for This Task").
    public struct Need: Sendable, Hashable {
        public var place: AIPlace
        public var level: Level
        public var folder: String?
        public var commands = false

        public init(place: AIPlace, level: Level, folder: String? = nil, commands: Bool = false) {
            (self.place, self.level, self.folder, self.commands) = (place, level, folder, commands)
        }
    }

    /// Why a call in scope is asked all the same; the first that holds is the one told.
    public enum Reason: Int, Sendable {
        case unclear      // the call doesn't fit its tool: asked rather than guessed
        case production   // any change on a production server
        case removes, overwrites
    }

    public enum Decision: Sendable, Equatable {
        case allowed
        case ask(Reason)       // in scope, and the user is asked this time whatever the scope
        case outside([Need])   // not in scope: a request to widen it, never a silent no
    }

    public private(set) var grants: [AIPlace: Grant] = [:]

    public init() {}

    /// Widens only: a higher level, one more folder, commands. A folder that isn't `AITarget.normal` is dropped
    /// (never read as `/`); so are a folder and commands given with View — they'd wake up at a later Work the user
    /// allowed for something else. Narrowing is `revoke`, then `grant`.
    public mutating func grant(_ place: AIPlace, _ level: Level, folder: String? = nil, commands: Bool = false) {
        var g = grants[place] ?? Grant(level: level)
        g.level = max(g.level, level)
        if level >= .work {
            if let f = folder.flatMap({ AITarget.normal($0, home: place == .mac ? NSHomeDirectory() : nil) }), !g.folders.contains(f) { g.folders.append(f) }
            g.commands = g.commands || commands
        }
        grants[place] = g
    }
    public mutating func grant(_ n: Need) { grant(n.place, n.level, folder: n.folder, commands: n.commands) }
    public mutating func revoke(_ place: AIPlace) { grants[place] = nil }

    /// The user's own word from the scope row: this level from now on, up or down. View drops the folders and
    /// commands (they'd wake up at a later Work); Work keeps the folders and, on a server, runs commands — what the
    /// row offers; All keeps the folders for a Work after it.
    public mutating func set(_ place: AIPlace, _ level: Level) {
        var g = grants[place] ?? Grant(level: level)
        g.level = level
        if level == .view { (g.folders, g.commands) = ([], false) } else if level == .work, place != .mac { g.commands = true }
        grants[place] = g
    }

    /// The scope already allows all `n` asks for.
    public func covers(_ n: Need) -> Bool {
        guard let g = grants[n.place] else { return false }
        if g.level == .all || n.level == .view { return true }
        if n.level == .all || g.level == .view { return false }
        return (n.folder.map { f in g.folders.contains { Self.holds($0, f) } } ?? true) && (!n.commands || g.commands)
    }

    /// Whether `t` changes something — never in Ask or Edit, and never under View. Two readings of a command must
    /// agree; and run in /dev, `cat watchdog` reads a device.
    public static func changes(_ t: AITarget) -> Bool {
        switch t.access {
        case .read: false
        case .run(let c): !AICommand.isReadOnly(c) || AICommand.overwrites(c) || t.path.map(AICommand.consumes) == true
        case .write, .remove: true
        }
    }

    /// May this call go on to the gate? Each target by its own access, the strictest answer for the call:
    /// - read, and a command `AICommand.isReadOnly`: the place is in the scope at any level;
    /// - write, remove: All, or Work with a folder that holds the path (`/srv/app` doesn't hold `/srv/app2`);
    /// - any other command: All, or Work with commands;
    /// - asked always, in scope or not: a removal, writing over what exists, a command that `AICommand.overwrites`,
    ///   any change on production; and a call that doesn't fit its tool (no targets for a tool that has them,
    ///   a change from a `read` or `ui` tool).
    ///
    /// Pure, so `prod` is the caller's knowledge at that moment: an alias not looked up yet isn't known as
    /// production. The runner checks again inside the gate's question, when it is.
    public func check(_ call: AICall, prod: (AIPlace) -> Bool) -> Decision {
        var needs: [Need] = [], reasons: Set<Reason> = []
        for t in call.targets {
            let g = grants[t.place], changes = Self.changes(t)
            switch t.access {
            case .read: break
            case .run(let c):
                guard changes else { break }
                if g?.level != .all && !(g?.level == .work && g?.commands == true) { needs.append(Need(place: t.place, level: .work, commands: true)) }
                if AICommand.overwrites(c) { reasons.insert(.overwrites) }
            case .write, .remove:
                let path = t.path ?? "/"   // never nil: `AITarget.init` refuses it
                if g?.level != .all && !(g?.level == .work && g?.folders.contains(where: { Self.holds($0, path) }) == true) {
                    needs.append(Need(place: t.place, level: .work, folder: path))
                }
                if t.access == .remove { reasons.insert(.removes) } else if call.overwrites { reasons.insert(.overwrites) }
            }
            if !changes, g == nil { needs.append(Need(place: t.place, level: .view)) }
            if changes, prod(t.place) { reasons.insert(.production) }
            if changes, call.tool.kind == .read || call.tool.kind == .ui { reasons.insert(.unclear) }
        }
        if !needs.isEmpty { return .outside(needs.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }) }
        if call.targets.count != call.tool.places.count { return .ask(.unclear) }
        return reasons.min { $0.rawValue < $1.rawValue }.map { .ask($0) } ?? .allowed
    }

    static func holds(_ folder: String, _ path: String) -> Bool { path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/") }
}
