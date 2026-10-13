import Foundation
import Testing
@testable import DFMCore

// These run processes: in the one serialized suite with the rest (`SudoPasswordTests`).
extension SudoPasswordTests {

/// The master logs to a file of its server (`-E`): what it says once in the background — a tunnel's refused channel —
/// has nowhere else to go. Its login errors are read from there, word for word as ssh said them on stderr before; with
/// no master after all the file goes at once (a stale one, too). One that runs: `aTunnelRidesTheServersMaster`.
@Test func theMasterLogsToAFileOfItsServer() throws {
    let t = SFTPTarget(host: "dfm-no-such-host.invalid", port: 2222)
    let log = SFTP.masterLog(t)
    #expect(log == SFTP.controlDir + "/log-dfm-no-such-host.invalid_2222")
    #expect(SFTP.masterArguments(t) == ["-E", log, "-f", "-N"])
    #expect(SFTP.masterLog(SFTPTarget(host: "me@fe80::1%en0")) == SFTP.controlDir + "/log-me@fe80__1_en0_22")
    #expect(SFTP.masterLog(SFTPTarget(host: "a/../b c")) == SFTP.controlDir + "/log-a_.._b_c_22", "never outside the folder")
    try Data("stale\n".utf8).write(to: URL(fileURLWithPath: log))
    let e = try #require(throws: SFTPError.self) { try SFTP.startMaster(t, env: [:]) }
    #expect(e.connection)
    #expect(e.message.hasPrefix("ssh: Could not resolve hostname dfm-no-such-host.invalid") && !e.message.contains("stale"), "got: \(e.message)")
    #expect(!FileManager.default.fileExists(atPath: log))
}

}
