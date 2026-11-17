import AppKit
import DFMCore

/// How `AppDelegate.gate` ended: through; a locked server's Touch ID refused; the question's Cancel.
enum Gate: Equatable {
    case pass, locked(SFTPTarget), cancelled
}

/// Who puts a `Confirm` to the user and brings back the button's index (the action 0, Cancel the last). Without one
/// it is a sheet (`AppDelegate.confirm`); the assistant's session brings its own — a card in its chat, a stub in tests.
typealias Asker = @MainActor (Confirm, NSWindow?) async -> Int

extension AppDelegate {
    /// What an action on a server passes before anything is sent there (commands, services, tools, file changes; a
    /// connection, a save, a tunnel and Copy SSH Key ask `ServerLock.authorize` themselves, then their own question),
    /// in this order: each of `targets` learned
    /// (where `ssh -G` says its address goes — a production or locked server under an alias is known as one from here
    /// on), Touch ID for a locked one whose five minutes ran out (`action` completes the system's "… to <action>
    /// “server”"), then `question`, built only now, when production is known however the address was typed — on
    /// `window` (default the main one). When to ask is the caller's: it returns nil for no question. The production
    /// log (`AuditLog.write`) is written only for what passed. `asker`: who asks `question` instead of the sheet.
    func gate(_ targets: [SFTPTarget], to action: String = "connect to", on window: NSWindow? = nil,
              question: @MainActor () -> Confirm? = { nil }, asker: Asker? = nil) async -> Gate {
        for t in targets where await !ServerLock.authorize(t, action) { return .locked(t) }
        guard let q = question() else { return .pass }
        let answer = if let asker { await asker(q, window) } else { await confirm(q, on: window) }
        return answer == 0 ? .pass : .cancelled
    }
}
