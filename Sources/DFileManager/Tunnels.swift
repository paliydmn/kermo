import AppKit
import DFMCore

// Tunnels (README "Tunnels"): what the menus, ⌘⇧P and the tunnel sheet do with them. Their ports: `Tunnels`.
extension AppDelegate {
    /// Turn On: a locked server asks first (Touch ID, as connecting does); then its port listens, now and at launch.
    /// A production server's doesn't ask: a tunnel changes nothing there by itself.
    func turnOn(_ t: Tunnel, of s: SavedServer) {
        Task {
            guard await ServerLock.authorize(s, "open a tunnel to") else { return tunnels.say("🔒 \(s.title) stays locked", false) }
            if let why = tunnels.start(t, of: s) { return tunnels.say("“\(t.title)”: \(why)", true) }
            saveTunnel(t, of: s, on: true)
            tunnels.say("\(t.title): " + (t.host == "localhost" ? "\(t.address) → \(s.title):\(t.port)" : t.route(via: s.title)) + " · listening", false)
        }
    }

    /// Turn Off: asks first only while connections are open, since they close.
    func turnOff(_ t: Tunnel, of s: SavedServer) {
        Task {
            let n = tunnels.connections(t, of: s)
            if n > 0, await !confirm("Turn off “\(t.title)”?", info: n == 1 ? "1 open connection closes." : "\(n) open connections close.", ok: "Turn Off") { return }
            turnOffNow(t, of: s)
        }
    }

    /// Its port closes, its connections too, and it stays off at launch (Turn Off, Disconnect).
    func turnOffNow(_ t: Tunnel, of s: SavedServer) {
        tunnels.stop(t, of: s)
        saveTunnel(t, of: s, on: false)
    }

    private func saveTunnel(_ t: Tunnel, of s: SavedServer, on: Bool) {
        guard let i = savedServers.firstIndex(where: { $0.id == s.id }),
              let j = savedServers[i].tunnels.firstIndex(where: { $0.localPort == t.localPort }), savedServers[i].tunnels[j].on != on else { return }
        savedServers[i].tunnels[j].on = on
        Config.save("servers.json", savedServers)
    }
}
