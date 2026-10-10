import Foundation
@testable import DFMCore
import Testing

// I8: search and archives on a server run there. `.local()` runs the server's command line here with /bin/sh.

private func tempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-i8-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// A `find` that logs its arguments and answers like GNU find would: the records for `.`, grep -lZ's hits for
/// `-exec grep`, a record per path for the second find in the content pipeline.
private func fakeFind(in dir: String) throws -> [String: String] {
    let bin = dir + "/bin"
    try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    try #"""
        #!/bin/sh
        printf '<%s>' "$@" >> "$FIND_LOG"; echo >> "$FIND_LOG"
        [ -n "$FIND_FAIL" ] && { echo "find: unknown predicate \`-printf'" >&2; exit 1; }
        case "$1 $*" in
          ". "*"-exec grep"*) printf './a b.txt\0./sub/c.log\0' ;;
          ". "*) printf 'd 755 0 1 ./sub\0f 644 12 1696767890.5 ./sub/c.log\0f 600 3 2 ./a b.txt\0p 644 0 3 ./fifo\0' ;;
          *) for p in "$@"; do case "$p" in ./*) printf 'f 644 5 100.5 %s\0' "$p" ;; esac; done ;;
        esac
        """#.write(toFile: bin + "/find", atomically: true, encoding: .utf8)
    chmod(bin + "/find", 0o755)
    return ["PATH": bin + ":/usr/bin:/bin", "FIND_LOG": dir + "/log"]
}

private func search(_ q: SearchQuery, _ env: [String: String]) throws -> [FileItem] {
    var hits: [FileItem] = []
    try FileSearch.runRemote(q, on: .local(), env: env) { hits.append($0) }
    return hits
}

@Test func remoteSearchRecordsBecomeItemsNamedByPath() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let env = try fakeFind(in: dir)
    var q = SearchQuery(root: dir)
    let all = try search(q, env)
    #expect(all.map(\.name) == ["sub", "sub/c.log", "a b.txt", "fifo"])
    #expect(all.map(\.kind) == [.dir, .file, .file, .other] && all[1].size == 12 && all[1].mtime == 1696767890.5)
    #expect(all[3].mode == UInt32(S_IFIFO) | 0o644, "a FIFO says so in Size, like in a listing")
    let args = try String(contentsOfFile: dir + "/log", encoding: .utf8)
    #expect(args == "<.><-xdev><-mindepth><1><-name><.*><-prune><-o><-printf><%y %m %s %T@ %p\\0>\n", "hidden folders pruned there")

    q.name = "*.LOG"   // Mask semantics, applied here, to the name only
    #expect(try search(q, env).map(\.name) == ["sub/c.log"])
    q.name = "sub"
    #expect(try search(q, env).map(\.name) == ["sub"])
}

/// What's typed goes to grep as one argument, whatever quotes or `$( )` it holds.
@Test func remoteContentSearchQuotesTheText() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let env = try fakeFind(in: dir)
    var q = SearchQuery(root: dir)
    q.contains = #"it's $(touch PWNED) "x" `id`"#
    q.includeHidden = true
    let hits = try search(q, env)
    #expect(hits.map(\.name) == ["a b.txt", "sub/c.log"] && hits.allSatisfy { $0.kind == .file && $0.size == 5 })
    let calls = try String(contentsOfFile: dir + "/log", encoding: .utf8).split(separator: "\n")
    #expect(calls.first == #"<.><-xdev><-mindepth><1><-type><f><-exec><grep><-lZiF><-e><it's $(touch PWNED) "x" `id`><--><{}><+>"#)
    #expect(calls.last == "<./a b.txt><./sub/c.log><-prune><-printf><%y %m %s %T@ %p\\0>")
    #expect(!FileManager.default.fileExists(atPath: dir + "/PWNED"))
    q.caseSensitive = true
    #expect(FileSearch.remoteCommand(q).contains(" -lZF -e "))
}

@Test func remoteSearchSaysWhyItFailed() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var env = try fakeFind(in: dir)
    env["FIND_FAIL"] = "1"
    #expect(throws: SFTPError.self) { try search(SearchQuery(root: dir), env) }
    #expect(throws: SFTPError.self) { try search(SearchQuery(root: dir + "/gone"), try fakeFind(in: dir)) }   // cd fails
}

@Test func remoteSearchRecordParsing() {
    #expect(FileSearch.remoteItem("l 777 7 3 ./a/link to x")?.name == "a/link to x")
    let exe = FileSearch.remoteItem("f 755 120 2 ./bin/run")
    #expect(exe?.mode == 0o755 && exe?.size == 120 && exe?.mtime == 2, "permissions for the column, ⌘⌥A and the exec color")
    #expect(FileSearch.remoteItem("f 644 1 2 ./")  == nil)
    #expect(FileSearch.remoteItem("f 644 1 2 /etc/passwd") == nil, "only paths below the root")
    #expect(FileSearch.remoteItem("garbage") == nil)
}

// MARK: - Archives on the server

@Test func remoteArchiveKinds() {
    #expect(RemoteArchive.isArchive("logs.TAR.GZ") && RemoteArchive.isArchive("a.tgz") && RemoteArchive.isArchive("app.jar"))
    #expect(!RemoteArchive.isArchive("a.7z") && !RemoteArchive.isArchive("app.log.gz") && !RemoteArchive.isArchive("tar"))
}

/// tar escapes names in its listing; the top names come out as they'll land on disk. unzip's are as they are.
@Test func remoteArchiveTopNames() {
    let listing = "./\n./dir/\n./dir/a\nfile\\040x\nweird\\nname\n\\320\\260.txt\nback\\\\slash\ndir/b\n"
    #expect(RemoteArchive.topNames(listing, of: "a.tar.gz") == ["dir", "file x", "weird\nname", "а.txt", "back\\slash"])
    #expect(RemoteArchive.topNames("folder\\file.txt\nother/x\n", of: "win.zip") == ["folder", "other"], "unzip makes folder/ of it")
}

/// The commands, run here (bsdtar, unzip): listed, then extracted with and without keeping what's there.
@Test func remoteArchiveCommandsRunAsBuilt() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let fm = FileManager.default
    try fm.createDirectory(atPath: dir + "/src/top dir", withIntermediateDirectories: true)
    try "new".write(toFile: dir + "/src/top dir/f.txt", atomically: true, encoding: .utf8)
    try "new".write(toFile: dir + "/src/it's.txt", atomically: true, encoding: .utf8)
    for name in ["it's a.tar.gz", "it's a.zip"] {
        let archive = dir + "/" + name
        #expect(try SSHCommand.capture(.local(), "cd \(ShellContext.quote(dir + "/src")) && /usr/bin/tar -a -cf \(ShellContext.quote(archive)) *") == "")
        #expect(try SSHCommand.capture(.local(), RemoteArchive.listCommand(archive)).contains("f.txt"))
        let top = RemoteArchive.topNames(try SSHCommand.capture(.local(), RemoteArchive.namesCommand(archive)), of: archive)
        #expect(Set(top) == ["top dir", "it's.txt"], "\(name)")

        let dest = dir + "/out " + name
        try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        try "old".write(toFile: dest + "/it's.txt", atomically: true, encoding: .utf8)
        _ = try SSHCommand.run(.local(), RemoteArchive.extractCommand(archive, to: dest, keep: true)) { _ in }
        #expect(try String(contentsOfFile: dest + "/it's.txt", encoding: .utf8) == "old", "kept: \(name)")
        #expect(try String(contentsOfFile: dest + "/top dir/f.txt", encoding: .utf8) == "new")
        _ = try SSHCommand.capture(.local(), RemoteArchive.extractCommand(archive, to: dest, keep: false))
        #expect(try String(contentsOfFile: dest + "/it's.txt", encoding: .utf8) == "new", "overwritten: \(name)")
        _ = try SSHCommand.capture(.local(), RemoteArchive.extractCommand(archive, to: dest + "/made/here", keep: false))
        #expect(fm.fileExists(atPath: dest + "/made/here/top dir/f.txt"), "a missing folder is made")
    }
}
