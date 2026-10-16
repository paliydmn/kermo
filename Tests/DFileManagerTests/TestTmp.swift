import Foundation

/// Shadows Foundation's NSTemporaryDirectory() in this test target, so every test's files follow it: under
/// $DFM_TEST_TMP when set (test.sh points it at a spare disk to spare the Mac's SSD), else the usual temp folder.
/// macOS's own NSTemporaryDirectory() ignores TMPDIR. Code under test still uses the real one.
func NSTemporaryDirectory() -> String {
    guard let dir = ProcessInfo.processInfo.environment["DFM_TEST_TMP"], !dir.isEmpty else { return Foundation.NSTemporaryDirectory() }
    return dir.hasSuffix("/") ? dir : dir + "/"
}

/// A value a test changes after a sendable stand-in captured it (an answer to give later): the stand-in reads it then.
final class Later<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
