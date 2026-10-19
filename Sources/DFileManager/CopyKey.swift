import AppKit
import DFMCore

// Copy SSH Key to Server… (docs/servers.md): this Mac's public key into a server's authorized_keys, so it logs in with
// the key instead of a password. Over the server's shared connection (`SSHKeyCopy`), then checked by a login with the key.
extension AppDelegate {
    /// ⌘⇧P: on the server the active panel or SSH tab is on (as its user); else pick one, as Forward Port does.
    func copyKey() {
        if let here = terminal.isShown ? terminal.current?.target : active.remote?.target { return copyKey(to: here.asUser) }
        let items = serverChoices().map { c in
            Picker.Item(title: c.saved?.pickerTitle ?? c.title, subtitle: c.saved.map { ServerRow.address($0.target) } ?? "~/.ssh/config") { [unowned self] in
                copyKey(to: c.target)
            }
        }
        Picker.show(over: window, placeholder: "Copy your SSH key to which server? — or type user@host", items: items, freeText: { q in
            guard case let .sftp(t, _)? = ServerAddress.parse(q) else { return [] }
            return [Picker.Item(title: "Copy your key to “\(q)”", detail: "↩") { [self] in copyKey(to: t) }]
        }, freeTextLast: true)
    }

    /// Which key (K2): the server's own key file's, else the usual ones there are — several: pick one; none: how to make one.
    func copyKey(to t: SFTPTarget) {
        let s = savedServer(at: t) ?? SavedServer(target: t)
        let keys = Self.publicKeys(identity: s.identityFile)
        guard !keys.isEmpty else { return noKeyYet(s.identityFile) }
        if keys.count == 1 { return copyKey(keys[0], to: s) }
        Picker.show(over: window, placeholder: "Which key goes to \(s.title)?", items: keys.map { pub in
            let comment = (try? String(contentsOfFile: pub, encoding: .utf8)).flatMap(SSHKeyCopy.line)?.split(separator: " ").dropFirst(2).joined(separator: " ")
            return Picker.Item(title: (pub as NSString).lastPathComponent, subtitle: comment ?? "") { [unowned self] in copyKey(pub, to: s) }
        })
    }

    /// The public key files to offer: the server's own key file's (".pub" next to it) — the one its logins use, so no
    /// other — else ~/.ssh's id_ed25519, id_ecdsa and id_rsa that are there.
    nonisolated static func publicKeys(identity: String?, home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        if let own = identity.map({ ($0 as NSString).expandingTildeInPath + ".pub" }) { return fm.fileExists(atPath: own) ? [own] : [] }
        return ["id_ed25519", "id_ecdsa", "id_rsa"].map { home + "/.ssh/\($0).pub" }.filter { fm.fileExists(atPath: $0) }
    }

    /// No key to copy: Kermo makes none (a passphrase is the terminal's business) — the command to make one; for the
    /// server's own key file without its ".pub", the command that writes it.
    private func noKeyYet(_ identity: String?) {
        let (title, command, info) = identity.map { k in
            ("No “\((k as NSString).lastPathComponent).pub” next to the server's key file",
             "ssh-keygen -y -f \(ShellContext.quote((k as NSString).expandingTildeInPath)) > \(ShellContext.quote((k as NSString).expandingTildeInPath + ".pub"))",
             "Its logins use \(k), so that's the key to copy. Write its public half in Terminal:")
        } ?? ("No SSH key on this Mac yet", "ssh-keygen -t ed25519", "Make one in Terminal:")
        let after = identity == nil ? "It asks where to keep it (↩ takes ~/.ssh/id_ed25519) and for a passphrase. " : ""
        Task {
            let r = await choose(title, info: "\(info)\n\n\(command)\n\n\(after)Then Copy SSH Key to Server… again.", ["Copy Command", "Show Docs", "Cancel"])
            if r == 0 {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } else if r == 1 {
                NSWorkspace.shared.open(URL(string: "https://github.com/paliydmn/kermo/blob/master/docs/servers.md#copy-your-ssh-key-to-a-server")!)
            }
        }
    }

    /// K3: a locked server asks first, a production one too (↩ adds: nothing is lost); the login as anywhere (askpass
    /// says what for); "Adding …" while it runs, ⎋ stops it. Then a login with the key says whether it took.
    private func copyKey(_ pub: String, to s: SavedServer) {
        let name = ((pub as NSString).lastPathComponent as NSString).deletingPathExtension, identity = String(pub.dropLast(".pub".count))
        let panel = active, t = s.target
        Task {
            guard let key = (try? String(contentsOfFile: pub, encoding: .utf8)).flatMap(SSHKeyCopy.line) else {
                return panel.flash("“\((pub as NSString).abbreviatingWithTildeInPath)” isn't a public key", error: true)
            }
            if await !ServerLock.authorize(t, "copy your SSH key to") {
                return panel.flash("🔒 \(s.title) stays locked")
            }
            if SavedServer.isProd(t), await choose("\(s.title) is a production server. Add your key to its authorized_keys?",
                                                   info: "\(name) goes into ~/.ssh/authorized_keys of \(t.host).",
                                                   ["Add", "Cancel"], default: 0) != 0 { return }
            let env = SSHAskpass.env.merging(["DFM_ASKPASS_WHY": "For “Copy SSH Key” to \(s.title)"]) { $1 }
            let r = await panel.busy("Adding \(name) to \(s.title)…") { flag in
                let added = try SSHKeyCopy.install(key, on: t, env: env, cancel: flag)
                return (added, try SSHKeyCopy.verify(t, identity: identity, env: env, cancel: flag))
            }
            let log = { (error: String?) in
                AuditLog.write(t, "add ssh key", paths: ["\(name).pub → ~/.ssh/authorized_keys"], exit: error == nil ? 0 : 1, error: error)
            }
            switch r {
            case .failure(is CancellationError): log("cancelled, may have been added")
            case .failure(let e):
                log(e.localizedDescription)
                _ = await choose("Couldn't add \(name) to \(s.title)", info: e.localizedDescription, ["OK"])
            case .success((_, let refused?)):
                log("added; a login with it failed: " + refused)
                _ = await choose("\(name) is on \(s.title), but logging in with it failed",
                                 info: refused + "\n\nsshd ignores keys in a folder others can write to (StrictModes): check the permissions "
                                 + "of the home folder, ~/.ssh and ~/.ssh/authorized_keys there.", ["OK"])
            case .success((let added, nil)):
                log(nil)
                panel.flash("\(s.title) now takes \(name)" + (added ? "" : " (it was there already)"))
                await afterKeyCopied(identity, name: name, to: s)
            }
        }
    }

    /// K4: a saved server without a key file gets this one (the server sheet shows it); a password in the Keychain may go.
    /// The connection already up stays as it is.
    private func afterKeyCopied(_ identity: String, name: String, to s: SavedServer) async {
        if let i = savedServers.firstIndex(where: { $0.id == s.id }), savedServers[i].identityFile == nil,
           FileManager.default.isReadableFile(atPath: identity) {
            savedServers[i].identityFile = (identity as NSString).abbreviatingWithTildeInPath
            Config.save("servers.json", savedServers)
            refreshSidebar()
        }
        guard SSHPasswords.has(s.target) else { return }
        if await choose("Forget \(s.title)'s saved password?", info: "It now logs in with \(name).", ["Forget", "Keep"], default: 0) == 0 {
            SSHPasswords.set(nil, for: s.target)
        }
    }
}
