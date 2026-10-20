import Foundation
import Testing
@testable import DFMCore

@Test func placeholdersExpandAndQuote() {
    let ctx = ShellContext(dir: "/Users/me/My Docs", otherDir: "/tmp", cursor: "it's.txt", targets: ["a b", "c"])
    #expect(ctx.expand("cat %f") == "cat 'it'\\''s.txt'")
    #expect(ctx.expand("ls %S") == "ls '/Users/me/My Docs/a b' '/Users/me/My Docs/c'")
    #expect(ctx.expand("cp %s %D") == "cp 'a b' c /tmp")
    #expect(ctx.expand("cd %d && echo 100%%") == "cd '/Users/me/My Docs' && echo 100%")
    #expect(ctx.expand("printf '%x' trailing %") == "printf '%x' trailing %")   // unknown placeholders stay
}

@Test func quotedNamesSurviveARealShell() throws {
    let nasty = "a 'b' $HOME `x` \"q\" ; rm -rf ~ ї"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "printf %s " + ShellContext.quote(nasty)]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    p.waitUntilExit()
    #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == nasty)
}

@Test func modeStrings() {
    #expect(FileInfo.modeString(S_IFREG | 0o644) == "-rw-r--r--")
    #expect(FileInfo.modeString(S_IFDIR | 0o1777) == "drwxrwxrwt")
    #expect(FileInfo.modeString(S_IFREG | 0o4755) == "-rwsr-xr-x")
    #expect(FileInfo.modeString(S_IFREG | 0o2644) == "-rw-r-Sr--")
    #expect(FileInfo.octal(S_IFREG | 0o755) == "755")
    #expect(FileInfo.flagNames(UInt32(UF_HIDDEN | UF_IMMUTABLE)) == ["uchg", "hidden"])
}

@Test func xattrListing() throws {
    let path = NSTemporaryDirectory() + "dfm-xattr-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: path) }
    try Data("x".utf8).write(to: URL(fileURLWithPath: path))
    #expect(setxattr(path, "com.apple.quarantine", "0081;00000000;Safari;", 21, 0, 0) == 0)
    let list = FileInfo.xattrs(path)
    // macOS may add its own attributes (e.g. com.apple.provenance), so look ours up by name.
    #expect(list.first { $0.name == "com.apple.quarantine" }?.size == 21)
    #expect(FileInfo.xattrString(path, "com.apple.quarantine") == "0081;00000000;Safari;")
    #expect(FileInfo.acl(path) == nil)
}

@Test func adminCommandsQuoteEverything() {
    #expect(AdminCommand.copy(["/a/My File", "/b/x"], to: "/Library/Dest") ==
            "/usr/bin/ditto '/a/My File' '/Library/Dest/My File' && /usr/bin/ditto /b/x /Library/Dest/x")
    #expect(AdminCommand.move(["/a/it's"], to: "/opt") == "/bin/mv -n '/a/it'\\''s' /opt/")
    #expect(AdminCommand.delete(["/tmp/a b", "/tmp/-rf"]) == "/bin/rm -rf -- '/tmp/a b' /tmp/-rf")
    let write = AdminCommand.writeContents(.file("/tmp/a b"), sha256: "ab", to: "/etc/it's", stamp: "1:2:3.000000004", length: 5)
    #expect(write.contains("/bin/cat '/tmp/a b' > \"$c\"") && write.hasSuffix(" -- '/etc/it'\\''s' \"$c\" 1 2 5")
            && write.contains("[ ! -L '/etc/it'\\''s' ]") && write.contains("= 1:2:3.000000004 ]"))
    #expect(AdminCommand.chown("root:wheel", "/x") == "/usr/sbin/chown -h root:wheel /x")
}

/// S-01: Save as Administrator's text travels in osascript's argv, through AppleScript and back to the shell: every
/// byte must come out as it went in (CRLF, BOM, quotes, `%`, backslashes, a decomposed letter).
@Test func adminTextComesThroughOsascriptByteForByte() throws {
    let out = NSTemporaryDirectory() + "dfm-argv-" + UUID().uuidString
    defer { unlink(out) }
    let text = "\u{FEFF}line 1\r\nit's \"q\" %s %% \\ \\n $HOME `id` e\u{301} \u{0434}\t\r\n\n"
    var args = AdminCommand.osascriptArguments(AdminCommand.printing(text) + " > " + ShellContext.quote(out))
    args[3] = "do shell script (item 1 of argv)"   // without the privileges clause: no password in tests
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    #expect(FileManager.default.contents(atPath: out) == Data(text.utf8))
}

@Test func adminCommandRunsThroughOsascriptArgv() throws {
    // Without the privileges clause the same argv shape must reach the shell intact.
    let cmd = "printf %s " + ShellContext.quote("a \"b\" 'c' \\ $HOME")
    var args = AdminCommand.osascriptArguments(cmd)
    args[3] = "do shell script (item 1 of argv)"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    p.waitUntilExit()
    #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
            == "a \"b\" 'c' \\ $HOME")
}

@Test func placeholdersWithNothingSelected() {
    let ctx = ShellContext(dir: "/d", otherDir: "/o", cursor: nil, targets: [])
    #expect(ctx.expand("a %f b %F c %s d %S e") == "a  b  c  d  e")
    #expect(ctx.expand("100%") == "100%")
    #expect(ctx.expand("%q%d") == "%q/d")
    #expect(ctx.expand("") == "")
    #expect(ShellContext.quote("") == "''")
    #expect(ShellContext.quote("a/b.c-d_e+f=g:h@i,j") == "a/b.c-d_e+f=g:h@i,j")
    #expect(ShellContext.quote("файл") == "файл")
    #expect(ShellContext.quote("a b") == "'a b'" && ShellContext.quote("*") == "'*'" && ShellContext.quote("~") == "'~'")
}

@Test func unicodeNamesPassThroughTheShellUnquoted() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "printf %s " + ShellContext.quote("Їжак_ñandú")]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    p.waitUntilExit()
    #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "Їжак_ñandú")
}

@Test func adminCommandsForEveryOperation() {
    #expect(AdminCommand.mkdir("/Library/New Folder") == "/bin/mkdir -p '/Library/New Folder'")
    #expect(AdminCommand.chmod("u+x", "/x y") == "/bin/chmod -h u+x '/x y'")
    #expect(AdminCommand.chflags("nouchg", "/x") == "/usr/bin/chflags -h nouchg /x")
    #expect(AdminCommand.move(["/a/1", "/a/2"], to: "/opt/") == "/bin/mv -n /a/1 /a/2 /opt//")
    #expect(AdminCommand.copy([], to: "/x") == "")
    let args = AdminCommand.osascriptArguments("echo hi")
    #expect(args.count == 7 && args.last == "echo hi" && args[3].contains("with administrator privileges"))
}

@Test func modeStringsForEveryFileType() {
    #expect(FileInfo.modeString(S_IFLNK | 0o777) == "lrwxrwxrwx")
    #expect(FileInfo.modeString(S_IFCHR | 0o666) == "crw-rw-rw-")
    #expect(FileInfo.modeString(S_IFBLK | 0o600) == "brw-------")
    #expect(FileInfo.modeString(S_IFIFO | 0o644) == "prw-r--r--")
    #expect(FileInfo.modeString(S_IFSOCK | 0o755) == "srwxr-xr-x")
    #expect(FileInfo.modeString(S_IFREG | 0o0) == "----------")
    #expect(FileInfo.modeString(S_IFREG | 0o4644) == "-rwSr--r--")   // setuid without execute
    #expect(FileInfo.modeString(S_IFDIR | 0o1766) == "drwxrw-rwT")   // sticky without execute
    #expect(FileInfo.modeString(S_IFREG | 0o6777) == "-rwsrwsrwx")
    #expect(FileInfo.octal(S_IFREG | 0o4755) == "4755" && FileInfo.octal(0) == "0")
    #expect(FileInfo.flagNames(0) == [])
    #expect(FileInfo.flagNames(UInt32(UF_NODUMP) | UInt32(SF_IMMUTABLE) | UInt32(SF_RESTRICTED)) == ["nodump", "schg", "restricted"])
}

@Test func ownerNamesAndACL() throws {
    #expect(FileInfo.userName(0) == "root" && FileInfo.groupName(0) == "wheel")
    #expect(FileInfo.userName(getuid()) == NSUserName())
    #expect(FileInfo.groupName(getgid()) != "\(getgid())")
    #expect(FileInfo.userName(4_000_000_000) == "4000000000")   // unknown ids fall back to the number
    #expect(FileInfo.groupName(4_000_000_000) == "4000000000")

    let path = NSTemporaryDirectory() + "dfm-acl-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: path) }
    try Data("x".utf8).write(to: URL(fileURLWithPath: path))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/chmod")
    p.arguments = ["+a", "\(NSUserName()) allow read,delete", path]
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
    let acl = try #require(FileInfo.acl(path))
    // acl_to_text form: "user:<GUID>:me:501:allow:read,delete"
    #expect(acl.hasPrefix("user:") && acl.contains(":\(NSUserName()):\(getuid()):allow:") && acl.hasSuffix("read,delete"))
    #expect(!acl.contains("!#acl"))
}

@Test func xattrsDoNotFollowLinksAndRealFifoMode() throws {
    let d = NSTemporaryDirectory() + "dfm-x-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: d) }
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: URL(fileURLWithPath: d + "/target"))
    #expect(setxattr(d + "/target", "com.dfm.on-target", "v", 1, 0, 0) == 0)
    try FileManager.default.createSymbolicLink(atPath: d + "/link", withDestinationPath: "target")
    #expect(FileInfo.xattrs(d + "/target").contains { $0.name == "com.dfm.on-target" && $0.size == 1 })
    #expect(!FileInfo.xattrs(d + "/link").contains { $0.name == "com.dfm.on-target" })
    #expect(FileInfo.xattrString(d + "/link", "com.dfm.on-target") == nil)
    #expect(FileInfo.xattrs(d + "/missing").isEmpty)
    #expect(FileInfo.xattrString(d + "/target", "com.dfm.nope") == nil)
    #expect(mkfifo(d + "/fifo", 0o600) == 0)
    var s = stat()
    #expect(lstat(d + "/fifo", &s) == 0 && FileInfo.modeString(s.st_mode) == "prw-------")
}
