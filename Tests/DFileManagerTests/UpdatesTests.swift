import AppKit
import Testing
@testable import DFileManager

@Test func versionsCompareNumberByNumber() {
    #expect(Updates.isNewer("v1.10", than: "1.9.2"))
    #expect(Updates.isNewer("v1.2.1", than: "1.2"))
    #expect(Updates.isNewer("2.0", than: "1.99"))
    #expect(!Updates.isNewer("v1.2.0", than: "1.2"))
    #expect(!Updates.isNewer("v1.2.1", than: "1.2.1"))
    #expect(!Updates.isNewer("v1.1", than: "1.2.1"))
}

@Test func aSkippedOrOlderVersionIsntOffered() {
    #expect(Updates.offered(latest: "v1.3", skipped: nil, current: "1.2.1") == "1.3")
    #expect(Updates.offered(latest: "v1.3", skipped: "v1.3", current: "1.2.1") == nil)
    #expect(Updates.offered(latest: "v1.4", skipped: "v1.3", current: "1.2.1") == "1.4")
    #expect(Updates.offered(latest: "v1.2.1", skipped: nil, current: "1.2.1") == nil)
    #expect(Updates.offered(latest: nil, skipped: nil, current: "1.2.1") == nil)
}

@Test func releaseNotesShowHeadingsBoldAndBullets() {
    let s = Updates.notes("### Fixed\n\n- **Server sheet:** a fix.\n- Another")
    #expect(s.string == "Fixed\n\n• Server sheet: a fix.\n• Another")
    let font = { (i: Int) in s.attribute(.font, at: i, effectiveRange: nil) as? NSFont }
    #expect(font(0)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect(font(9)?.fontDescriptor.symbolicTraits.contains(.bold) == true)    // "Server sheet:"
    #expect(font(30)?.fontDescriptor.symbolicTraits.contains(.bold) == false)  // "Another"
}
