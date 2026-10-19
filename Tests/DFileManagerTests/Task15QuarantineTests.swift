import AppKit
@testable import DFMCore
import Testing
@testable import DFileManager

/// S-04: what ↩ hands another app from a server or an archive carries com.apple.quarantine, so Gatekeeper looks first.
/// `AppDelegate.openInApp` is replaced: nothing opens, no Gatekeeper dialog. One at a time: they all replace it.
@Suite(.serialized) @MainActor struct QuarantineTests {
    static let kermos = #/^0081;[0-9a-f]{8};Kermo;$/#

    func folder(_ files: [String]) throws -> String {
        let dir = NSTemporaryDirectory() + "dfm-qtn-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for f in files { try Data("#!/bin/sh\necho hi\n".utf8).write(to: URL(fileURLWithPath: dir + "/" + f)) }
        return dir
    }

    func zip(_ dir: String, _ name: String, _ files: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", name] + files
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        try p.run()
        p.waitUntilExit()
    }

    /// What `openInApp` was handed, with its quarantine and mode at that moment. Its temp folder is removed after,
    /// as Kermo does: `gone` says it went.
    func opening(_ run: () -> Void) async -> [(url: URL, mark: String?, mode: mode_t?, gone: Bool)] {
        var opened: [(url: URL, mark: String?, mode: mode_t?, gone: Bool)] = []
        let was = AppDelegate.openInApp
        AppDelegate.openInApp = { opened.append(($0, FileInfo.xattrString($0.path, "com.apple.quarantine"), FileJob.lstat($0.path)?.st_mode, false)) }
        defer { AppDelegate.openInApp = was }
        run()
        for _ in 0..<250 where opened.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        for i in opened.indices {
            let folder = opened[i].url.deletingLastPathComponent().path
            TempCopies.remove(folder)
            opened[i].gone = FileJob.lstat(folder) == nil
        }
        return opened
    }

    @Test func aServerFileOpenedInItsAppIsQuarantined() async throws {
        let dir = try folder(["run.command"])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
        panel.loadViewIfNeeded()
        defer { panel.shutdown() }
        let app = AppDelegate()
        app.panels = [panel]
        let opened = await opening { app.remoteOpen(.open, .local(), dir + "/run.command", in: panel) }
        #expect(opened.count == 1 && opened.first?.url.lastPathComponent == "run.command")
        #expect(opened.first?.mark?.wholeMatch(of: Self.kermos) != nil, "\(String(describing: opened.first?.mark))")
    }

    /// ⌘Y, ⌃Q and Compare Files' copy: Quick Look's Open with hands it to another app too.
    @Test func aServerFilesPreviewIsQuarantined() throws {
        let dir = try folder(["run.command"])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let got = try #require(try ServerCopies.download(.local(), dir + "/run.command", look: true, limit: 1 << 20, env: [:], cancel: CancelFlag()))
        defer { TempCopies.remove(got.url.deletingLastPathComponent().path) }
        let mark = FileInfo.xattrString(got.url.path, "com.apple.quarantine")
        #expect(mark?.wholeMatch(of: Self.kermos) != nil, "\(String(describing: mark))")
    }

    /// A clean archive's file gets Kermo's mark; a quarantined archive's keeps the archive's own (bsdtar copies it, with
    /// the archive's event id, as Archive Utility does).
    @Test func anArchivesFileOpenedInItsAppIsQuarantined() async throws {
        let dir = try folder(["run.command"])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try zip(dir, "clean.zip", ["run.command"])
        try zip(dir, "got.zip", ["run.command"])
        let theirs = "0081;6713a0c0;Safari;0D9B4A5C-1111-2222-3333-444455556666"
        #expect(setxattr(dir + "/got.zip", "com.apple.quarantine", theirs, theirs.utf8.count, 0, 0) == 0)
        let panel = PanelViewController(tabs: [dir], index: 0, showHidden: false)
        panel.loadViewIfNeeded()
        defer { panel.shutdown() }
        let app = AppDelegate()
        app.panels = [panel]
        var marks: [String?] = []
        for archive in ["clean.zip", "got.zip"] {
            panel.enterArchive(dir + "/" + archive)
            for _ in 0..<250 where panel.listedItems.map(\.name) != ["run.command"] { try? await Task.sleep(for: .milliseconds(20)) }
            #expect(panel.setMarks(["run.command"]) == 1)
            let opened = await opening { app.openFromArchive(view: false) }
            #expect(opened.count == 1, "\(archive)")
            marks.append(opened.first?.mark)
            // F-09: read-only, so edits in that app don't vanish with the temp folder; the panel says how to keep them
            #expect(opened.first?.mode.map { $0 & 0o222 } == 0, "\(archive): \(String(describing: opened.first?.mode))")
            #expect(panel.statusText == "A temporary copy, read-only: Extract (⌥F9) to keep your changes")
            #expect(opened.first?.gone == true, "a read-only copy is removed too")
            panel.navigate(to: dir)
            for _ in 0..<250 where panel.listedItems.count != 3 { try? await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(marks.first??.wholeMatch(of: Self.kermos) != nil, "\(String(describing: marks.first))")
        #expect(marks.last??.hasSuffix(";0D9B4A5C-1111-2222-3333-444455556666") == true, "\(String(describing: marks.last))")
    }

    /// F5 out of an archive and Extract carry a quarantined archive's mark onto what they unpack, and put none on a
    /// clean one's — bsdtar does that itself (no change was needed; this guards it).
    @Test func extractingCarriesOnlyTheArchivesOwnMark() throws {
        let dir = try folder(["run.command"])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try zip(dir, "clean.zip", ["run.command"])
        try zip(dir, "got.zip", ["run.command"])
        let theirs = "0081;6713a0c0;Safari;0D9B4A5C-1111-2222-3333-444455556666"
        #expect(setxattr(dir + "/got.zip", "com.apple.quarantine", theirs, theirs.utf8.count, 0, 0) == 0)
        for archive in ["clean.zip", "got.zip"] {
            let f5 = dir + "/f5-" + archive, whole = dir + "/x-" + archive, index = try ArchiveIndex.read(dir + "/" + archive)
            try index.extract(["run.command"], from: "", to: f5)
            try index.extract([], from: "", to: whole)   // Extract on the archive: all of it, the same bsdtar
            for out in [f5, whole] {
                let mark = FileInfo.xattrString(out + "/run.command", "com.apple.quarantine")
                #expect(FileManager.default.fileExists(atPath: out + "/run.command"))
                #expect(archive == "clean.zip" ? mark == nil : mark?.hasSuffix(";0D9B4A5C-1111-2222-3333-444455556666") == true, "\(out): \(String(describing: mark))")
            }
        }
    }
}
