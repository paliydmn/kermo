import Foundation

/// What the user has in front of them, as one value: both panels, the editor's document, the terminal's tab. The app
/// builds it in one place; ⌘E / F2's `ShellContext` is made of its panels.
public struct AIContext: Sendable, Equatable {
    public struct Folder: Sendable, Equatable {
        public var server: SFTPTarget?   // nil: this Mac
        public var dir: String
        public init(server: SFTPTarget?, dir: String) { (self.server, self.dir) = (server, dir) }
    }

    public struct Panel: Sendable, Equatable {
        /// Where what it shows is — as the panel has it (a root panel's is root); nil: this Mac.
        public var server: SFTPTarget?
        /// The folder its names are in; "." for a list (its server's login folder).
        public var dir: String
        /// Names in `dir`: under the cursor, and what an action acts on — the marked ones, else the cursor's.
        public var cursor: String?
        public var targets: [String]
        /// A server's list in place of a folder ("Services"): the names are its rows, not files.
        public var list: String?
        /// The file folder the panel stands in — what %D means to the other panel; behind a list or a search's
        /// results too. nil: a server tab not connected.
        public var folder: Folder?
        /// The server such a tab stands for, and the folder it would open there.
        public var parked: Folder?

        public init(server: SFTPTarget? = nil, dir: String, cursor: String? = nil, targets: [String] = [], list: String? = nil, folder: Folder?,
                    parked: Folder? = nil) {
            (self.server, self.dir, self.cursor, self.targets, self.list, self.folder, self.parked) = (server, dir, cursor, targets, list, folder, parked)
        }
    }

    public struct Editor: Sendable, Equatable {
        public var server: SFTPTarget?
        public var path: String?   // nil: an Untitled
        public var unsaved: Bool
        /// The selected text and its lines, from 1; nil: nothing selected.
        public var selection: (lines: ClosedRange<Int>, text: String)?

        public init(server: SFTPTarget?, path: String?, unsaved: Bool, selection: (lines: ClosedRange<Int>, text: String)?) {
            (self.server, self.path, self.unsaved, self.selection) = (server, path, unsaved, selection)
        }
        public static func == (a: Editor, b: Editor) -> Bool {
            a.server == b.server && a.path == b.path && a.unsaved == b.unsaved && a.selection?.lines == b.selection?.lines && a.selection?.text == b.selection?.text
        }
    }

    /// The tab's server is who it was opened as: after `sudo -i` or an ssh typed there, who is logged in isn't known.
    public struct Terminal: Sendable, Equatable {
        public var server: SFTPTarget?
        public var command: String?   // the last line ↩ was pressed on, prompt and all
        public var selection: String?

        public init(server: SFTPTarget?, command: String?, selection: String?) { (self.server, self.command, self.selection) = (server, command, selection) }
    }

    public var active: Panel, other: Panel
    public var editor: Editor?, terminal: Terminal?

    public init(active: Panel, other: Panel, editor: Editor? = nil, terminal: Terminal? = nil) {
        (self.active, self.other, self.editor, self.terminal) = (active, other, editor, terminal)
    }

    /// ⌘E / F2's placeholders: the active panel's folder and names; %D only when the other panel's folder is on the
    /// same machine (as the same user or not), and never from a list.
    public var shell: ShellContext {
        let there = active.list == nil ? other.folder.flatMap { $0.server?.asRoot(false) == active.server?.asRoot(false) ? $0.dir : nil } : nil
        return ShellContext(dir: active.dir, otherDir: there, cursor: active.cursor, targets: active.targets, server: active.server)
    }
}
