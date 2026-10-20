import AppKit
import Testing
import DFMCore
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

@Test func installTakesTheReleasesZipByItsExactName() throws {
    let json = #"{"tag_name": "v1.4", "assets": [{"name": "Kermo-1.4-universal.dmg", "browser_download_url": "https://x/a.dmg"},"#
        + #"{"name": "Kermo-1.4-universal.zip", "browser_download_url": "https://x/a.zip"}]}"#
    #expect(Updates.archive(try JSONDecoder().decode(Updates.Release.self, from: Data(json.utf8)))?.absoluteString == "https://x/a.zip")
    #expect(Updates.archive(try JSONDecoder().decode(Updates.Release.self, from: Data(#"{"tag_name": "v1.3", "body": "x"}"#.utf8))) == nil)
}

/// A tiny app signed ad hoc, and its designated requirement as text.
private func signedApp(_ dir: String, _ name: String = "T.app", version: String = "9.9") throws -> (url: URL, requirement: String) {
    let app = URL(fileURLWithPath: dir).appendingPathComponent(name)
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/t").path)
    try #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.kermo.update</string><key>CFBundleExecutable</key><string>t</string><key>CFBundleShortVersionString</key><string>\#(version)</string></dict></plist>"#
        .write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
    let sign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "-s", "-", app.path])
    sign.waitUntilExit()
    #expect(sign.terminationStatus == 0)
    var code: SecStaticCode?, req: SecRequirement?
    _ = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
    _ = SecCodeCopyDesignatedRequirement(code!, [], &req)
    return (app, Updates.text(req!)!)
}

private func requirement(_ text: String) -> SecRequirement {
    var r: SecRequirement?
    _ = SecRequirementCreateWithString(text as CFString, [], &r)
    return r!
}

@Test func anUpdateIsTakenOnlySignedAsThisKermoIs() throws {
    let dir = NSTemporaryDirectory() + "upd-sign-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let (app, own) = try signedApp(dir)
    #expect(Updates.isSigned(app, as: requirement(own)))
    #expect(!Updates.isSigned(app, as: requirement(#"identifier "com.dmn.dfilemanager" and certificate leaf = H"d3bd6ce342db8977ebddfcd8aad30158f53a1f68""#)))
    try Data("x".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))   // changed after signing
    #expect(!Updates.isSigned(app, as: requirement(own)))
}

private func sh(_ command: String) throws -> (status: Int32, err: String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

@Test func theReplaceSwapsInOnlyASignedAppAndLeavesNothingBehind() throws {
    let dir = NSTemporaryDirectory() + "upd-replace-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let installed = dir + "/Applications/Kermo.app"
    try FileManager.default.createDirectory(atPath: installed, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: URL(fileURLWithPath: installed + "/old"))
    let (new, own) = try signedApp(dir + "/dl")

    let other = try signedApp(dir + "/other", version: "6.6")   // signed too, but not as `own` says
    let refused = try sh(AdminCommand.replaceApp(other.url.path, at: installed, requirement: own))
    #expect(refused.status != 0 && refused.err.contains("nothing was replaced"))
    #expect(FileManager.default.fileExists(atPath: installed + "/old"))

    #expect(try sh(AdminCommand.replaceApp(new.path, at: installed, requirement: own)).status == 0)
    #expect(Updates.isSigned(URL(fileURLWithPath: installed), as: requirement(own)))
    #expect(!FileManager.default.fileExists(atPath: installed + "/old"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir + "/Applications") == ["Kermo.app"])   // no .kermo-update.*
}
