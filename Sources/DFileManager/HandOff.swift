import AppKit
import DFMCore

/// One Kermo per config. A second launch on a config another Kermo keeps (its editor's lock, `DraftStore`) — the Dock's
/// copy while a build's runs, say — gives that one the front and what it was asked to open (paths, kermo://), and
/// quits before it reads or writes a file of the config: two copies would split the drafts and overwrite each
/// other's servers.json. A config of its own (a mock home, the tests') is another config: launches as usual.
@MainActor enum HandOff {
    /// The Kermo keeping this config; nil — none found (an unbundled build keeps it): launch as before, without drafts.
    static func holder() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let kermos = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        let pid = pick(lock: DraftStore.holder(Config.drafts), running: kermos.map(\.processIdentifier), me: getpid())
        return kermos.first { $0.processIdentifier == pid }
    }

    /// The lock's pid while it's another running Kermo — stale or not one (an unbundled build): none. A Kermo before 2.3
    /// writes no pid: the other running Kermo while there's just one (a copy on a config of its own may be another).
    nonisolated static func pick(lock: pid_t?, running: [pid_t], me: pid_t) -> pid_t? {
        let others = running.filter { $0 != me }
        if let lock { return others.contains(lock) ? lock : nil }
        return others.count == 1 ? others[0] : nil
    }

    /// Runs the app just long enough to take what it was asked to open, hands it over, and exits.
    static func run(to other: NSRunningApplication) -> Never {
        let d = Forward(other)
        NSApplication.shared.delegate = d   // weak
        withExtendedLifetime(d) { NSApplication.shared.run() }
        exit(0)
    }

    /// To the holder by its pid: Launch Services' `open…(withApplicationAt:)` picks any copy of the bundle id — another
    /// one, or this very launch.
    static let note = Notification.Name("com.dmn.dfilemanager.handOff")

    /// The holder's side: a second launch's paths and kermo:// as if opened here; none — as a Dock click.
    static func listen() {
        DistributedNotificationCenter.default().addObserver(forName: note, object: "\(getpid())", queue: .main) { n in
            let urls = (n.userInfo?["urls"] as? [String] ?? []).compactMap(URL.init(string:))
            MainActor.assumeIsolated {
                guard let d = NSApp.delegate as? AppDelegate else { return }
                if !urls.isEmpty { d.application(NSApp, open: urls) }   // still launching: kept for its end (`openPending`)
                else if d.window != nil { _ = d.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) }   // nil: it comes forward as it ends
            }
        }
    }

    private final class Forward: NSObject, NSApplicationDelegate {
        let other: NSRunningApplication
        var urls: [URL] = []
        init(_ other: NSRunningApplication) { self.other = other }

        func application(_ application: NSApplication, open urls: [URL]) { self.urls += urls }   // before didFinishLaunching

        // ponytail: a launch's kermo:// comes after didFinishLaunching (paths before it): what came in 0.5 s goes.
        // Wait for the URL event itself if a slow Mac ever loses one. A holder quitting right now gets it and is gone.
        func applicationDidFinishLaunching(_ notification: Notification) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                NSApp.yieldActivation(to: other)   // its window may come to the front
                DistributedNotificationCenter.default().postNotificationName(note, object: "\(other.processIdentifier)",
                                                                             userInfo: ["urls": urls.map(\.absoluteString)], deliverImmediately: true)
                other.activate()   // a Kermo before 2.3 doesn't listen: its windows to the front at least
                exit(0)
            }
        }
    }
}
