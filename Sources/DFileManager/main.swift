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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
