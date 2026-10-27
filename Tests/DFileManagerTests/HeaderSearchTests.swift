import DFMCore
import Testing
@testable import DFileManager

@MainActor private func search(_ q: String, folders: [SearchHit] = [], files: [String] = [], recent: [String] = []) -> [(group: String, hits: [SearchHit])] {
    HeaderSearchModel.results(q, commands: AppDelegate().makeCommands(), folders: folders, files: files, recent: recent)
}

@Test @MainActor func searchFindsCommandsByAliasWithTheirKeys() {
    let cmds = search("zip").first { $0.group == "Commands" }!.hits
    #expect(cmds.first?.title == "Compress…" && cmds.first?.detail == "⌥F5")
    #expect(search("chmod").first?.hits.first?.target == .command("file.attrs"), "the marked items, also on a server (I4)")
    #expect(search("sftp").first?.hits.first?.target == .command("go.connect"))
    #expect(!search("command").flatMap(\.hits).contains { $0.target == .command("app.palette") }, "the search doesn't list itself")
}

@Test @MainActor func searchGroupsFoldersAndFilesAndOffersDiskSearch() {
    let folders = [SearchHit(title: "logs", subtitle: "/var/log", detail: "favorite", target: .folder("/var/log")),
                   SearchHit(title: "logs", subtitle: "~/x/logs", target: .folder("/x/logs"))]
    let r = search("logs", folders: folders, files: ["old-logs.txt", "README.md"])
    #expect(r.map(\.group) == ["Commands", "Folders", "In This Panel", ""].filter { g in r.contains { $0.group == g } })
    #expect(r.first { $0.group == "Folders" }!.hits.map(\.target) == [.folder("/var/log"), .folder("/x/logs")], "equal score: favorite first")
    #expect(r.first { $0.group == "In This Panel" }!.hits.map(\.title) == ["old-logs.txt"])
    #expect(r.last!.hits == [SearchHit(title: "Search “logs” on disk…", detail: "⌘F", target: .disk("logs"))])
}

@Test @MainActor func emptySearchShowsRecentChoicesAndFavorites() {
    let fav = SearchHit(title: "a", detail: "favorite", target: .folder("/a"))
    let b = SearchHit(title: "b", target: .folder("/b")), srv = SearchHit(title: "h:/x", detail: "server", target: .server("h:/x"))
    var r = search("", folders: [fav, b, srv], recent: ["file.copy", "gone.command", "command:file.move", "folder:/b", "folder:/gone", "server:h:/x", "disk:inv"])
    #expect(r.map(\.group) == ["Recent", "Favorites"])
    #expect(r[0].hits.map(\.target) == [.command("file.copy"), .command("file.move"), .folder("/b"), .server("h:/x"), .disk("inv")],
            "a bare id is a command; a folder the search no longer lists is left out")
    #expect(r[0].hits.allSatisfy(\.removable) && r[1].hits == [fav])
    r = search("", folders: [fav], recent: ["folder:/a"] + Array(repeating: "file.copy", count: 12))
    #expect(r.map(\.group) == ["Recent"] && r[0].hits.count == HeaderSearchModel.recentMax, "a favorite in Recent isn't listed twice")
    for t: SearchHit.Target in [.command("file.copy"), .folder("/a:b"), .server("h:/x"), .disk("a:b"), .place(server: "ssh://me@h:2222", row: "File History")] { #expect(SearchHit.Target(key: t.key!) == t) }
    #expect(SearchHit.Target.file("x").key == nil)
}

/// A query typed on stops the ranking of the last one: a cancelled ranking leaves the panel's names out.
@Test @MainActor func aCancelledRankingStops() {
    let files = (0..<5000).map { "file\($0).log" }, flag = CancelFlag()
    let ranked = { HeaderSearchModel.results("file", commands: [], folders: [], files: files, recent: [], cancel: flag) }
    #expect(ranked().first { $0.group == "In This Panel" }?.hits.count == HeaderSearchModel.perGroup)
    flag.cancel()
    #expect(ranked().first { $0.group == "In This Panel" } == nil)
}

/// P-7 (review 1): what a panel runs by itself (↩ on a server's file or archive) isn't offered as a command.
@Test @MainActor func searchLeavesOutHiddenCommands() {
    let hidden = AppDelegate().makeCommands().filter(\.hidden).map(\.id)
    #expect(Set(hidden) == ["remote.open", "remote.archive", "archive.open"])
    for q in ["remote", "archive", "open"] {
        #expect(!search(q).flatMap(\.hits).contains { if case .command(let id) = $0.target { hidden.contains(id) } else { false } }, "\(q)")
    }
    #expect(search("", recent: ["remote.open", "file.copy"])[0].hits.map(\.target) == [.command("file.copy")], "nor in Recent")
}
