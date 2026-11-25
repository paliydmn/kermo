import AppKit
import SwiftTerm
import Testing
@testable import DFileManager

/// T1 (task 8): ⌃O and sidebar clicks type `cd …⏎` into the shell — never into a program running in it.
@MainActor @Test func typedCdOnlyWhenTheShellHasTheTerminal() async throws {
    _ = NSApplication.shared
    let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    view.startProcess(executable: "/bin/sh", args: ["-i"], environment: ["PS1=$ ", "PATH=/bin:/usr/bin"])
    defer { view.process?.terminate() }
    await until("shell at its prompt") { EmbeddedTerminal.atPrompt(view.process) }
    view.send(txt: "cat\r")
    await until("cat in the foreground") { !EmbeddedTerminal.atPrompt(view.process) }
    view.send(txt: "\u{4}")   // ⌃D ends cat
    await until("back at the prompt") { EmbeddedTerminal.atPrompt(view.process) }
}
