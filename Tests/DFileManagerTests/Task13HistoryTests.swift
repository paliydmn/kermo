import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// Task 13: server file history and diff with a server.

/// Saves keep versions in ~/.config/dfilemanager/history.noindex (Spotlight stays out by the name) unless
/// `defaults write com.dmn.dfilemanager serverHistory -bool false`.
@MainActor @Test func serverHistoryCanBeTurnedOff() {
    let app = AppDelegate()
    let was = UserDefaults.standard.object(forKey: "serverHistory")
    defer { UserDefaults.standard.set(was, forKey: "serverHistory") }
    UserDefaults.standard.removeObject(forKey: "serverHistory")
    #expect(app.serverHistory?.root == AppDelegate.historyRoot && AppDelegate.historyRoot == Config.path("history.noindex"))
    UserDefaults.standard.set(false, forKey: "serverHistory")
    #expect(app.serverHistory == nil)
}
