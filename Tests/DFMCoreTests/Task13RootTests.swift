import Foundation
import Testing
@testable import DFMCore

// Task 13: a server panel as root (`SFTPTarget.sudo`).

/// `stdin` reaches the command, then end of file — more than a pipe holds too; without it the command reads nothing,
/// as before. A command that stops reading early neither hangs nor kills the app (EPIPE).
@Test func commandsReadWhatTheyAreGiven() throws {
    #expect(try SSHCommand.capture(.local(), "cat", stdin: Data("one\ntwo".utf8)) == "one\ntwo")
    #expect(try SSHCommand.capture(.local(), "IFS= read -r a; echo \"[$a]\"; cat", stdin: Data("line\nrest".utf8)) == "[line]\nrest")
    let big = Data(repeating: 0x61, count: 300_000)
    #expect(try SSHCommand.capture(.local(), "wc -c | tr -d ' '", stdin: big) == "300000\n")
    #expect(try SSHCommand.capture(.local(), "head -c 3", stdin: big) == "aaa")
    #expect(try SSHCommand.capture(.local(), "cat") == "", "no stdin: end of file at once")
}
