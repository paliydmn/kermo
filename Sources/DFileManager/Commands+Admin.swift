import AppKit
import DFMCore

extension AppDelegate {
    // MARK: - Administrator operations

    /// How an administrator's command runs, over it in a question.
    static let asAdmin = "Runs as root on this Mac; macOS asks for an administrator's password first."

    func runAdmin(_ title: String, _ command: String) async {
        switch await Self.runAsAdmin(command) {
        case .ok: active.flash("\(title): done")
        case .cancelled: break
        case .failed(let msg): showError(JobErrorMessage("\(title) failed: \(msg)"))
        }
        panels.forEach { $0.reload() }
    }

    func adminTransfer(move: Bool) {
        if active.archive != nil { return readOnly() }
        let srcs = active.targetURLs
        guard !srcs.isEmpty else { return NSSound.beep() }
        let verb = move ? "Move" : "Copy"
        Task {
            guard let input = await prompt("\(verb) \(srcs.count == 1 ? "“\(srcs[0].lastPathComponent)”" : "\(srcs.count) items") as administrator to:",
                                           value: ((other.path + "/") as NSString).abbreviatingWithTildeInPath, ok: verb,
                                           info: move ? "Existing items are never overwritten (mv -n)." : "ditto keeps owner, mode, ACLs and xattrs; it asks before replacing what's there.")
            else { return }
            await adminTransfer(srcs.map(\.path), to: resolve(input), move: move)
        }
    }

    /// After the prompt: what F5/F6 would refuse is refused here too, before the password is asked (`AdminCommand.check`,
    /// off the main thread: the destination may be a share); what a copy would replace is asked about first.
    func adminTransfer(_ paths: [String], to dest: String, move: Bool) async {
        let verb = move ? "Move" : "Copy", panel = active
        let (refusal, existing) = await Blocking.run(.userInitiated) { AdminCommand.check(paths, to: dest, move: move) }
        if let refusal { return panel.flash("\(verb) as administrator: \(refusal)", error: true) }
        let command = move ? AdminCommand.move(paths, to: dest) : AdminCommand.copy(paths, to: dest)
        if !move, !existing.isEmpty {
            let what = existing.count == 1 ? "“\(existing[0])”" : "\(existing.count) items"
            var c = Confirm("Replace \(what) in \((dest as NSString).abbreviatingWithTildeInPath) as administrator?", action: "Replace")
            (c.chips, c.place, c.items) = ([.root], "this Mac", existing.map { Confirm.Item(name: $0) })
            (c.runs, c.command) = (Self.asAdmin, command)
            (c.note, c.irreversible) = ("What's there now is replaced. This can't be undone.", true)
            guard await confirm(c) == 0 else { return }
        }
        await runAdmin("\(verb) as administrator", command)
        panel.unmarkAll()
    }

    func adminMkdir() {
        if active.archive != nil { return readOnly() }
        Task {
            guard let name = await prompt("New folder as administrator:", value: "", ok: "Create"), !name.isEmpty else { return }
            await runAdmin("New folder", AdminCommand.mkdir(resolve(name)))
        }
    }

    func adminDelete() {
        let srcs = active.targetURLs
        guard !srcs.isEmpty else { return NSSound.beep() }
        let command = AdminCommand.delete(srcs.map(\.path))
        var c = Confirm("Delete \(Self.describe(srcs)) permanently as administrator?", action: "Delete")
        (c.chips, c.place, c.items) = ([.root], "this Mac", active.listed(srcs))
        (c.runs, c.command) = (Self.asAdmin, command)
        (c.note, c.irreversible) = ("They don't go to the Trash. This can't be undone.", true)
        Task {
            guard await confirm(c) == 0 else { return }
            await runAdmin("Delete as administrator", command)
            active.unmarkAll()
        }
    }
}
