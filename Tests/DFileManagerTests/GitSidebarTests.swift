import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

private func status(_ s: String, dir: String = "/Users/me/kermo") -> GitStatus { GitStatus.parse(s, repoRoot: "/Users/me/kermo", dir: dir) }

private func parts(_ v: GitRowView) throws -> (chips: NSStackView, toolbar: NSStackView, name: NSTextField) {
    let line = try #require(v.subviews.first as? NSStackView)
    return (try #require(line.arrangedSubviews.first { $0 is ServerChips } as? NSStackView),
            try #require(line.arrangedSubviews.first { $0 is ServerToolbar } as? NSStackView),
            try #require(line.arrangedSubviews.first { $0 is ServerName } as? NSTextField))
}

/// The Git row at rest says what there is to tell — changes, ↓↑, a cloud for a branch no remote has — and under the
/// mouse offers Git Changes, Commit, Sync (Publish for that branch) and ⋯. The tooltip says all of it, the folder's
/// count as the folder's.
@MainActor @Test func gitRowSaysItsStateAndOffersItsActions() throws {
    var st = status("## task...origin/task [ahead 1, behind 2]\0M  a.swift\0 M b.swift\0?? c.md\0")
    st.fetched = Date(timeIntervalSince1970: 1_000_000)
    let row = GitRow(status: st)
    #expect(row.repo == "kermo" && row.changed == 3 && row.arrows == "↓2 ↑1" && !row.publishes)
    #expect(row.tip(now: Date(timeIntervalSince1970: 1_000_000 + 720)).hasPrefix("/Users/me/kermo · origin/task · ↓2 ↑1 · 3 changes, 1 staged · fetched "))

    let view = SidebarController().gitView(row)
    let (chips, toolbar, name) = try parts(view)
    #expect(name.stringValue == "task")
    #expect(chips.arrangedSubviews.map { $0.accessibilityLabel() } == ["3 changes", "2 to pull, 1 to push"])
    #expect(toolbar.arrangedSubviews.map { $0.accessibilityLabel() } == ["Git Changes", "Commit…", "Sync: pull (fast-forward only), then push", "Git menu"])
    #expect(toolbar.isHidden && !chips.isHidden, "at rest: the state")
    let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, trackingNumber: 0, userData: nil)!
    view.mouseEntered(with: enter)
    #expect(!toolbar.isHidden && chips.isHidden, "under the mouse: the actions")

    // A new branch: a cloud at rest, Publish instead of Sync; a clean one: no Changes, no Commit.
    let fresh = GitRow(status: status("## ports-multi\0"))
    #expect(fresh.publishes && fresh.tip().contains("not on a remote yet · no changes"))
    let (c2, t2, _) = try parts(SidebarController().gitView(fresh))
    #expect(c2.arrangedSubviews.map { $0.accessibilityLabel() } == ["Not on a remote yet"])
    #expect(t2.arrangedSubviews.map { $0.accessibilityLabel() } == ["Publish Branch: push it to origin", "Git menu"])

    // Conflicts: red, counted instead of changes, and no Commit until they're resolved; in a subfolder the count is its own.
    let merge = GitRow(status: status("## main...origin/main\0UU x.c\0M  y.c\0 M src/z.c\0", dir: "/Users/me/kermo/src"))
    #expect(merge.status.conflicts == 0 && merge.changed == 1 && merge.tip().contains("up to date · 1 change in this folder, 0 staged"))
    let conflicted = GitRow(status: status("## main...origin/main\0UU x.c\0M  y.c\0"))
    let (c3, t3, _) = try parts(SidebarController().gitView(conflicted))
    #expect(c3.arrangedSubviews.map { $0.accessibilityLabel() } == ["1 file in conflict"])
    #expect((c3.arrangedSubviews.first as? NSButton)?.contentTintColor == .systemRed)
    #expect(t3.arrangedSubviews.map { $0.accessibilityLabel() } == ["Git Changes", "Sync: pull (fast-forward only), then push", "Git menu"])

    // A server panel: the state shows, the actions are this Mac's — only ⋯.
    let server = GitRow(status: status("## main...origin/main [behind 1]\0 M a\0"), server: "db")
    let (c4, t4, _) = try parts(SidebarController().gitView(server))
    #expect(c4.arrangedSubviews.count == 2 && t4.arrangedSubviews.map { $0.accessibilityLabel() } == ["Git menu"])
    #expect(server.tip().hasPrefix("db:/Users/me/kermo · ") && server.tip().hasSuffix("Git actions work in this Mac's folders · ⋯: copy the branch name"))
    #expect(GitRow(status: status("## HEAD (no branch)\0")).tip().contains("detached HEAD"))
    #expect(GitRow(status: status("## old...origin/old [gone]\0")).tip().contains("origin/old is gone"))
}

/// The section sits under the list and is there only for a work tree: without one the list gets the room back.
@MainActor @Test func gitSectionShowsOnlyInAWorkTree() throws {
    let sidebar = SidebarController()
    let column = try #require(sidebar.view as? NSStackView)
    let block = try #require(column.arrangedSubviews.last)
    #expect(column.arrangedSubviews.first is NSScrollView && block.isHidden)
    sidebar.showGit(GitRow(status: status("## main\0")))
    #expect(!block.isHidden)
    sidebar.showGit(nil)
    #expect(block.isHidden)
}
