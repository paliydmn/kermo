import Foundation
import Testing
@testable import DFMCore

// Text files Quick Look shows as an icon: the panel previews them itself.

@Test func quickLookKeepsWhatItShows() {
    for name in ["app.log", "a.json", "notes.txt", "run.sh", "README.md", "x.yaml", "photo.jpg", "doc.pdf", "clip.mov",
                 "a.plist", "logs.tar.gz", "page.html", "logo.svg"] {
        #expect(TextFormat.quickLookShows(name), "\(name)")
        #expect(!TextFormat.previewsAsText(name, head: Data("hello\n".utf8)), "\(name)")
    }
}

@Test func textQuickLookDoesntKnowIsPreviewedAsText() {
    let text = Data("listen 80;\nserver_name example.com;\n".utf8)
    for name in ["site.conf", "Makefile", ".env", "sshd_config.bak", "syslog.1", "app.log.1", "server.key", "id_rsa.pub", "hosts"] {
        #expect(!TextFormat.quickLookShows(name), "\(name)")
        #expect(TextFormat.previewsAsText(name, head: text), "\(name)")
    }
    #expect(TextFormat.previewsAsText("empty.conf", head: Data()))   // an empty file: an empty text, not an icon
    #expect(TextFormat.previewsAsText("ru.conf", head: Data("ключ = значення\n".utf8)))
    #expect(TextFormat.previewsAsText("cp1251.conf", head: "ключ = значение\n".data(using: .windowsCP1251)!))
}

@Test func binaryOrUTF16StaysWithQuickLook() {
    var bin = Data([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0])
    bin += Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 * 7) })
    #expect(!TextFormat.previewsAsText("a.out", head: bin))
    #expect(!TextFormat.previewsAsText("blob", head: Data(repeating: 0, count: 1000)))
    // UTF-16: F3 shows it as hex too (no UTF-16 decoding there).
    let utf16 = Data([0xff, 0xfe]) + "key = value\n".data(using: .utf16LittleEndian)!
    #expect(!TextFormat.previewsAsText("w.conf", head: utf16))
    // Only the start is looked at: text, then a binary tail past `previewSniff`.
    let head = Data(repeating: UInt8(ascii: "a"), count: TextFormat.previewSniff) + Data(repeating: 0, count: 100_000)
    #expect(TextFormat.previewsAsText("big.conf", head: head))
}
