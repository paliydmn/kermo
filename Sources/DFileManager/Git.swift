import AppKit
import DFMCore

/// The Git section's actions: branch and commit in the Picker, sync with the remote. Each runs in the background with
/// ⎋ (`busy`); git's own words come back — a short note when it worked, a sheet with all it said when it didn't.
/// Nothing forceful: pull is fast-forward only, a branch is deleted with -d, no --force, no stash.
extension AppDelegate {
    /// The active panel's work tree for an action, or nil after saying why.
    private func gitHere() -> (panel: PanelViewController, status: GitStatus)? {
        let panel = active
        guard panel.remote == nil, panel.archive == nil else { panel.flash("Git actions work in this Mac's folders"); return nil }
        guard let st = panel.git else {
            panel.flash(GitStatus.available ? "Not a git work tree (or its config can run commands)" : "Git needs the Command Line Tools (xcode-select --install)")
            return nil
        }
        return (panel, st)
    }

    /// ssh asks for a key's passphrase, and git for an https password, in the same dialog as for servers.
    private static var gitEnv: [String: String] { SSHAskpass.env.merging(["GIT_ASKPASS": SSHAskpass.env["SSH_ASKPASS"] ?? ""]) { $1 } }

    /// Runs `steps` in turn in `root` until one fails; then every panel in that work tree reloads (column, status line,
    /// the Git section). Worked: `done` of what git said, in the status line. Failed: all it said, in a sheet.
    func runGit(_ steps: [[String]], in root: String, _ message: String, network: Bool = false, done: @escaping @MainActor (String) -> String) {
        let panel = active, env = network ? Self.gitEnv : [:]
        Task {
            let r = await panel.busy(message) { flag in
                var out = ""
                for args in steps {
                    let r = GitStatus.act(args, in: root, env: env, cancel: flag)
                    out += r.output
                    if !r.ok { return (ok: false, output: out) }
                }
                return (ok: true, output: out)
            }
            for p in panels where p === panel || p.git?.root == root { p.reload() }
            switch r {
            case .success(let r) where r.ok: panel.flash(done(r.output))
            case .success(let r): gitFailed("git \(steps.last?.first ?? "") didn't work", r.output)
            case .failure: panel.flash("Stopped")
            }
        }
    }

    private func gitFailed(_ title: String, _ output: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(3000)).bidiVisible
        alert.beginSheetModal(for: window)
    }

    // MARK: - Branches

    /// Switch Branch (⌃B, a click on the Git row): local branches, then remote ones without a local branch, then tags,
    /// newest first. ↩ switches; a name that isn't there becomes "Create branch"; ⌘N makes a branch from the highlighted
    /// one; ⌘⌫ deletes a merged one (-d: git keeps an unmerged one and says so).
    func showBranches() {
        guard let (panel, st) = gitHere() else { return }
        Task { [unowned self] in
            guard case .success(let found) = await panel.busy("Branches…", after: 0.3, { _ in GitStatus.refs(st.root) }) else { return }
            guard let refs = found else { return panel.flash("Git didn't list the branches", error: true) }
            let current = st.detached ? "HEAD" : st.branch
            let items = [Picker.Item(title: "＋ New Branch…", subtitle: "from \(current), or type its name above") { [unowned self] in newBranch(from: nil) }]
                + refs.map { ref in branchItem(ref, root: st.root) }
            Picker.show(over: window, placeholder: "Switch to a branch or tag — or type a new name · ⌘N new branch from the highlighted one · ⌘⌫ delete a merged branch",
                        items: items, freeText: { [unowned self] q in
                let name = q.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)   // as VS Code: "ports multi" → ports-multi
                guard !name.isEmpty, !refs.contains(where: { $0.kind == .local && $0.name == name }) else { return [] }
                return [Picker.Item(title: "Create branch “\(name)”", subtitle: "from \(current)", detail: "↩") { [unowned self] in createBranch(name, from: nil, in: st.root) }]
            }, freeTextLast: true, selected: refs.firstIndex { !$0.current }.map { $0 + 1 } ?? 0)   // the newest other branch
        }
    }

    private func branchItem(_ ref: GitStatus.Ref, root: String) -> Picker.Item {
        let detail = ref.current ? "current" : ref.kind == .tag ? "tag · \(ref.age)" : ref.age + (ref.gone ? " · remote gone" : "")
        var keys: [Shortcut: @MainActor () -> Void] = [Shortcut("cmd+n")!: { [unowned self] in newBranch(from: ref.name) }]
        if ref.kind == .local, !ref.current {
            keys[Shortcut("cmd+backspace")!] = { [unowned self] in
                runGit([["branch", "-d", ref.name]], in: root, "Deleting “\(ref.name)”…") { _ in "Deleted branch “\(ref.name)”" }
            }
        }
        return Picker.Item(title: (ref.kind == .tag ? "🏷 " : "") + ref.name, subtitle: "\(ref.hash)  \(ref.subject)", detail: detail, keys: keys) { [unowned self] in
            guard !ref.current else { return active.flash("Already on “\(ref.name)”") }
            let args: [String] = switch ref.kind {
            case .local: ["switch", ref.name]
            case .remote: ["switch", "--track", ref.name]   // a local branch of its name, following it
            case .tag: ["switch", "--detach", "refs/tags/" + ref.name]
            }
            runGit([args], in: root, "Switching to “\(ref.name)”…") { _ in ref.kind == .tag ? "Detached at \(ref.name) — ⌘N in Switch Branch makes a branch here" : "Switched to “\(ref.name)”" }
        }
    }

    /// New Branch…: the Picker asks for its name; from `base` (a branch or tag), else from where you are.
    func newBranch(from base: String?) {
        guard let (_, st) = gitHere() else { return }
        let from = base ?? (st.detached ? "HEAD" : st.branch)
        Picker.show(over: window, placeholder: "New branch from \(from) — its name", items: [], freeText: { [unowned self] q in
            let name = q.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            return name.isEmpty ? [] : [Picker.Item(title: "Create branch “\(name)”", subtitle: "from \(from)", detail: "↩") { [unowned self] in
                createBranch(name, from: base, in: st.root)
            }]
        })
    }

    private func createBranch(_ name: String, from base: String?, in root: String) {
        runGit([["switch", "-c", name] + (base.map { [$0] } ?? [])], in: root, "Creating “\(name)”…") { _ in "Created and switched to “\(name)”" }
    }

    // MARK: - Commit

    /// Commit (⌃⇧C): the message is typed in the Picker's field, and the rows say what goes in — the staged files, all
    /// changes, or an amend of the last commit while it isn't pushed. Nothing typed: the changed files; ↩ shows a diff.
    /// One line: a longer message is for the terminal (⌃O). Hooks run as they do there.
    func showCommit() {
        guard let (panel, here) = gitHere() else { return }
        Task { [unowned self] in
            // The whole work tree, not the panel's folder: that's what a commit takes.
            guard case .success(let found) = await panel.busy("Git status…", after: 0.3, { _ in GitStatus.load(here.root) }) else { return }
            guard let st = found else { return panel.flash("Git status didn't finish", error: true) }
            let root = st.root, total = st.changes.count, staged = st.staged
            let amend = !st.detached && (st.upstream == nil || st.ahead > 0)   // not pushed yet, as far as this Mac knows
            guard total > 0 || amend else { return panel.flash("Nothing to commit on “\(st.branch)”") }
            let files = st.changes.sorted { $0.key < $1.key }.map { path, code in
                Picker.Item(title: path, detail: code == "??" ? "new" : GitStatus.isConflict(code) ? "conflict" : (code.first != " " ? "staged · " : "") + code.trimmingCharacters(in: .whitespaces)) {
                    let abs = root + "/" + path
                    Shell.run(GitStatus.diffCommand(tracked: code == "??" ? [] : [abs], untracked: code == "??" ? [abs] : []), in: root, diff: true)
                }
            }
            Picker.show(over: window, placeholder: "Commit message — \(staged) of \(total) change\(total == 1 ? "" : "s") staged on \(st.branch)",
                        items: files, rank: { _, _ in nil }, freeText: { [unowned self] msg in
                guard !msg.isEmpty else { return [] }
                if st.conflicts > 0 {
                    return [Picker.Item(title: "\(st.conflicts) file\(st.conflicts == 1 ? "" : "s") in conflict: resolve them first", subtitle: "Git Changes lists them") { [unowned self] in
                        active.showGitChanges()
                    }]
                }
                return (staged == 0 ? [] : [Picker.Item(title: "Commit \(staged) staged file\(staged == 1 ? "" : "s")", subtitle: "“\(msg)”", detail: "↩") { [unowned self] in
                        runGit([["commit", "-m", msg]], in: root, "Committing…", done: Self.committed)
                    }])
                    + (total == staged ? [] : [Picker.Item(title: "Commit all \(total) change\(total == 1 ? "" : "s")",
                                                           subtitle: staged == 0 ? "stages them first" : "stages the other \(total - staged) first") { [unowned self] in
                        runGit([["add", "-A"], ["commit", "-m", msg]], in: root, "Committing…", done: Self.committed)
                    }])
                    + (!amend ? [] : [Picker.Item(title: "Amend the last commit", subtitle: "with this message\(staged > 0 ? " and the staged files" : "") — it isn't pushed yet") { [unowned self] in
                        runGit([["commit", "--amend", "-m", msg]], in: root, "Amending…", done: Self.committed)
                    }])
            })
        }
    }

    /// What git says first: "[main 1a2b3c4] the message".
    private static func committed(_ out: String) -> String { out.split(separator: "\n").first.map(String.init) ?? "Committed" }

    // MARK: - Remote

    /// ⟳: pull (fast-forward only: branches that went apart are for the terminal), then push. A branch no remote has
    /// yet is published instead.
    func gitSync() {
        guard let (_, st) = gitHere() else { return }
        guard !st.detached else { return active.flash("Detached HEAD: switch to a branch first (⌃B)") }
        guard st.upstream != nil else { return gitPublish() }
        guard !st.gone else { return active.flash("\(st.upstream!) is gone (merged?) — Publish Branch pushes it again", error: true) }
        runGit([["pull", "--ff-only"], ["push"]], in: st.root, "Syncing “\(st.branch)”…", network: true) { _ in "“\(st.branch)” is in sync with \(st.upstream!)" }
    }

    func gitPublish() {
        guard let (_, st) = gitHere() else { return }
        guard !st.detached else { return active.flash("Detached HEAD: switch to a branch first (⌃B)") }
        runGit([["push", "-u", "origin", st.branch]], in: st.root, "Publishing “\(st.branch)”…", network: true) { _ in "Published “\(st.branch)” to origin" }
    }

    func gitPull() {
        guard let (_, st) = gitHere() else { return }
        runGit([["pull", "--ff-only"]], in: st.root, "Pulling…", network: true) { $0.contains("Already up to date") ? "Already up to date" : "Pulled (fast-forward)" }
    }

    func gitPush() {
        guard let (_, st) = gitHere() else { return }
        guard st.upstream != nil else { return gitPublish() }
        runGit([["push"]], in: st.root, "Pushing…", network: true) { $0.contains("Everything up-to-date") ? "Everything up to date" : "Pushed “\(st.branch)”" }
    }

    /// Fetch --prune: ↓ counts again, and branches whose remote went (merged PRs) show "remote gone" in Switch Branch.
    func gitFetch() {
        guard let (_, st) = gitHere() else { return }
        runGit([["fetch", "--prune"]], in: st.root, "Fetching…", network: true) { _ in "Fetched" }
    }

    // MARK: - The rest

    /// `git init` in the active panel's folder — asked once with its full path, since a repo in the wrong place (~)
    /// makes every folder under it a work tree. Not inside one already.
    func gitInit() {
        let panel = active
        guard panel.remote == nil, panel.archive == nil, panel.searchTitle == nil else { return panel.flash("Git works in this Mac's folders") }
        let dir = panel.path
        Picker.show(over: window, placeholder: "Initialize a Git repository?", items: [
            Picker.Item(title: "Initialize a Git repository in “\(Self.folderTitle(dir))”", subtitle: (dir as NSString).abbreviatingWithTildeInPath, detail: "↩") { [unowned self] in
                Task {
                    let r = await panel.busy("git init…") { _ in GitStatus.initialize(dir) }
                    panel.reload()
                    guard case .success(let r) = r else { return }
                    r.ok ? panel.flash("Initialized a Git repository in \((dir as NSString).abbreviatingWithTildeInPath)") : gitFailed("git init didn't work", r.output)
                }
            },
        ])
    }

    private static func folderTitle(_ p: String) -> String { p == "/" ? "/" : (p as NSString).lastPathComponent }

    func gitRootFolder() {
        guard let st = active.git else { return active.flash("Not a git work tree") }
        if let r = active.remote { active.loadRemote(r.target, dir: st.root, select: nil) } else { active.navigate(to: st.root) }
    }

    func gitCopyBranch() {
        guard let st = active.git else { return active.flash("Not a git work tree") }
        copyToPasteboard([st.branch])
        active.flash("Copied “\(st.branch)”")
    }

    /// The Git row's ⋯ and right-click: the section's commands with their keys; a server panel's, what works there.
    func gitMenu() -> [NSMenuItem] {
        let server = active.remote != nil
        let ids: [String?] = server ? ["git.root", "git.copyBranch"]
            : ["git.switch", "git.newBranch", "git.commit", nil, active.git?.upstream == nil ? "git.publish" : "git.sync", "git.pull", "git.push", "git.fetch", nil,
               "git.changes", "view.gitOnly", nil, "git.root", "git.copyBranch"]
        return ids.map { id in
            guard let id, let c = commands.first(where: { $0.id == id }) else { return .separator() }
            let item = MenuAction.item(c.title) { [unowned self] in run(id) }
            item.keyEquivalent = c.keys.first?.menuKey ?? ""
            item.keyEquivalentModifierMask = c.keys.first?.flags ?? []
            return item
        }
    }
}
