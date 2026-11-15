import AppKit
import DFMCore

/// How `AppDelegate.gate` ended: through; a locked server's Touch ID refused; the question's Cancel.
enum Gate: Equatable {
    case pass, locked(SFTPTarget), cancelled
}

extension AppDelegate {
    /// What every action on a server passes before anything is sent there, in this order: each of `targets` learned
    /// (where `ssh -G` says its address goes — a production or locked server under an alias is known as one from here
    /// on), Touch ID for a locked one whose five minutes ran out (`action` completes the system's "… to <action>
    /// “server”"), then `question`, built only now, when production is known however the address was typed — on
    /// `window` (default the main one). When to ask is the caller's: it returns nil for no question. The production
    /// log (`AuditLog.write`) is written only for what passed.
    func gate(_ targets: [SFTPTarget], to action: String = "connect to", on window: NSWindow? = nil,
              question: @MainActor () -> Confirm? = { nil }) async -> Gate {
        for t in targets where await !ServerLock.authorize(t, action) { return .locked(t) }
        if let q = question(), await confirm(q, on: window) != 0 { return .cancelled }
        return .pass
    }
}
