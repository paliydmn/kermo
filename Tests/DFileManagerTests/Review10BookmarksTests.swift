import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

// MARK: - I5: Favorites on a server

/// A server folder is kept scp-style, and ServerAddress.parse reads it back: user, port, IPv6, odd folder names.
@Test func serverBookmarkEntriesRoundTrip() throws {
    let cases: [(SFTPTarget, String, String)] = [
        (SFTPTarget(host: "me@web"), "/var/log", "me@web:/var/log"),
        (SFTPTarget(host: "web", port: 2222), "/srv", "web:2222:/srv"),
        (SFTPTarget(host: "fe80::1"), "/etc", "[fe80::1]:/etc"),
        (SFTPTarget(host: "u@::1", port: 22), "/", "u@[::1]:22:/"),
        (SFTPTarget(host: "web"), "/a b/c:d/2222", "web:/a b/c:d/2222"),
    ]
    for (t, dir, entry) in cases {
        #expect(Bookmark.entry(t, dir) == entry)
        let r = try #require(Bookmark.remote(entry), "\(entry)")
        #expect(r.target == t && r.dir == dir, "\(entry)")
    }
    for local in ["/Users/me", "/", "web", "~/x", "web:~/x", ""] { #expect(Bookmark.remote(local) == nil, "\(local)") }
    #expect(Bookmark.title("me@web:/var/log") == "log" && Bookmark.title("me@web:/") == "/" && Bookmark.title("/tmp/x") == "x")
}

/// Favorites show a server entry as a server folder (opened over SFTP), never as a local path to list.
@MainActor @Test func serverBookmarkIsAServerFolderInFavorites() throws {
    let s = SidebarModel.sections(bookmarks: ["/a", "me@web:2222:/var/log"], frecent: ["/a", "/c"], volumes: [], servers: ServerList(), tags: [])
    #expect(s[0].places == [.folder("/a"), .serverFolder("me@web:2222:/var/log")])
    #expect(s[0].places[1].path == nil && s[0].places[1].bookmark == "me@web:2222:/var/log" && s[0].places[1].selectable)
    #expect(s[1].places == [.folder("/c")])
    let row = try #require(SidebarController().outlineView(NSOutlineView(), viewFor: nil,
                                                           item: SidebarController.Node(place: s[0].places[1])) as? NSStackView)
    let labels = row.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    #expect(labels == ["log", "me@web"])
}

/// stat("me@web:/x") is ENOENT: a server entry must never pass for a local folder that's gone (§4's forget).
@Test func serverBookmarkIsNeverGone() {
    #expect(!Frecency.isGone("me@web:/nope") && !Frecency.isGone("web:2222:/srv"))
    #expect(!Frecency.isUnder("me@web:/x", "/x") && !Frecency.isUnder("me@web:/x", "/"))
}
