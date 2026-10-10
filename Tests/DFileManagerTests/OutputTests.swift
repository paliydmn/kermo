import AppKit
import Testing
@testable import DFileManager

@Test func ptyOutputRedrawsProgressLines() {
    let storage = NSTextStorage()
    var pending = false
    for chunk in ["^D\u{8}\u{8}sftp> get a\r", "\nbig.bin   0%  0KB/s --:-- ETA\rbig.bin  45%  90MB 30MB/s 00:04 ETA",
                  "\rbig.bin 100%  200MB 40MB/s 00:00    \r", "\nsftp> bye\r\n"] {
        appendTerminalOutput(chunk, to: storage, pendingCR: &pending, attributes: [:])
    }
    #expect(storage.string == "sftp> get a\nbig.bin 100%  200MB 40MB/s 00:00    \nsftp> bye\n")
    #expect(!pending)
}
