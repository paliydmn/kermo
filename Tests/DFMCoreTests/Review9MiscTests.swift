import Foundation
import Testing
@testable import DFMCore

// Task 9 §6, misc: R2b, R25b.

/// R2b: hex offsets past 4 GB (the tail of a big server log starts there) aren't cut to 32 bits.
@Test func hexDumpOffsetsAreNotCutAt32Bits() {
    let dump = TextFormat.hexDump(Data("abc".utf8), base: 5_000_000_000)
    #expect(dump.hasPrefix("12a05f200  61 62 63"), "\(dump.prefix(24))")
    #expect(TextFormat.hexDump(Data("abc".utf8), base: 0x100).hasPrefix("00000100  61 62 63"), "small ones keep 8 digits")
}

/// R25b: an address with nothing to connect to ("::1:/etc" is a bare IPv6 cut at its first colon, "[]", "u@[]:22",
/// ":2222") is refused like any other the picker doesn't understand, not taken as an empty host. The URL form the
/// picker advertises too: Foundation's URL.host is "" (not nil) for "sftp://:22" or "ssh://u@[]/x".
@Test func serverAddressWithoutAHostIsNotOne() {
    for s in ["::1:/etc", "[]", "u@[]:22", ":2222", "u@", "u@:22", "[]:/etc", ":",
              "sftp://:22", "sftp://u@:22", "sftp://[]:22/etc", "ssh://:/", "sftp://[]", "sftp://u@[]/x", "ssh://u@",
              "sftp://", "ssh://", "SFTP://", "sftp:///x", "sftp://h x"] {   // the placeholder prefix alone: not a host named sftp
        #expect(ServerAddress.parse(s) == nil, "\(s)")
    }
    #expect(ServerAddress.parse("u@[::1]:22") == .sftp(SFTPTarget(host: "u@::1", port: 22), path: nil), "a bracketed host still works")
    #expect(ServerAddress.parse("h:2222") == .sftp(SFTPTarget(host: "h", port: 2222), path: nil))
    #expect(ServerAddress.parse("ssh:2222") == .sftp(SFTPTarget(host: "ssh", port: 2222), path: nil), "no //: scp-style, a host named ssh")
    #expect(ServerAddress.parse("sftp://u@h:22/x") == .sftp(SFTPTarget(host: "u@h", port: 22), path: "/x"), "the URL form still works")
}
