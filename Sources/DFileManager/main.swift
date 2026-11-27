import AppKit
import DFMCore

// The askpass client (`SSHAskpass`'s script): asks the running app (`Askpass`), prints its answer for ssh. No UI here.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--askpass" {
    exit(Askpass.client(prompt: CommandLine.arguments[2], env: ProcessInfo.processInfo.environment) {
        FileHandle.standardOutput.write(Data(($0 + "\n").utf8))
    })
}

// The MCP bridge (`MCP.bridge`): an agent in a terminal tab starts it; it carries the agent's messages to the running app.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--mcp" { exit(MCP.bridge(env: ProcessInfo.processInfo.environment)) }

// One Kermo per config: its drafts first, before anything reads or writes a file of it. Another Kermo keeping them gets
// this launch and what it was asked to open; this one quits (`HandOff`).
let drafts = Result { try DraftStore.open(Config.drafts) }
if case .failure(DraftStore.Failure.locked) = drafts, let other = HandOff.holder() { HandOff.run(to: other) }

let app = NSApplication.shared
let delegate = AppDelegate()
delegate.drafts = drafts
app.delegate = delegate
HandOff.listen()   // from now: a second launch during this one's is queued like its own paths
app.setActivationPolicy(.regular)
app.run()
