import Foundation
import DFMCore

/// Runs a shell command as root through the standard macOS password dialog.
// ponytail: prompts per action (macOS caches the grant for a few minutes); a privileged helper
// (SMAppService) is the P5 upgrade if that gets tedious.
enum Admin {
    enum Outcome: Sendable {
        case ok
        case cancelled
        case failed(String)
    }

    static func run(_ command: String) async -> Outcome {
        await Blocking.run { () -> Outcome in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = AdminCommand.osascriptArguments(command)
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return .failed(error.localizedDescription) }
            let data = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus != 0 else { return .ok }
            var msg = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("(-128)") { return .cancelled }   // user pressed Cancel in the password dialog
            if let r = msg.range(of: "execution error: ") { msg = String(msg[r.upperBound...]) }
            return .failed(msg)
        }
    }
}
