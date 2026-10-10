import Foundation
import Testing
@testable import DFMCore

private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "dfm-r9a-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

/// A zip like Windows' "Send to → Compressed folder" makes: names in a DOS/ANSI code page, no UTF-8 flag.
private func legacyZip(_ zip: String, charset: String, files: [String: String], in dir: String) {
    for (name, text) in files {
        let p = dir + "/src/" + name
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: URL(fileURLWithPath: p))
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    p.arguments = ["-c", "--format", "zip", "--options", "zip:hdrcharset=" + charset, "-f", zip, "-C", dir + "/src"] + files.keys.sorted()
    p.environment = ["LC_ALL": "en_US.UTF-8", "COPYFILE_DISABLE": "1"]
    try! p.run()
    p.waitUntilExit()
    precondition(p.terminationStatus == 0)
}

private func text(_ path: String) -> String? {
    (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) }
}

@Test func cp866ZipListsAndExtractsByItsNames() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    legacyZip(d + "/w.zip", charset: "CP866", files: ["Документ.txt": "doc", "Отчёт/Итог.TXT": "sum"], in: d)
    let idx = try ArchiveIndex.read(d + "/w.zip")
    #expect(idx.list("")?.map(\.name).sorted() == ["Документ.txt", "Отчёт"])
    #expect(idx.list("Отчёт")?.map(\.name) == ["Итог.TXT"])
    try idx.extract(["Документ.txt"], from: "", to: d + "/out")   // ↩ / F3 on it
    try idx.extract(["Итог.TXT"], from: "Отчёт", to: d + "/out")
    #expect(text(d + "/out/Документ.txt") == "doc" && text(d + "/out/Итог.TXT") == "sum")
    // F5 on the zip itself: the whole archive, under the names shown
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    p.arguments = idx.extractArguments([], from: "", to: d + "/all")
    p.environment = [:]   // a Finder-launched app has no LANG
    try FileManager.default.createDirectory(atPath: d + "/all", withIntermediateDirectories: true)
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0 && text(d + "/all/Отчёт/Итог.TXT") == "sum")
}

@Test func cp1251ZipIsToldFromCP866() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    legacyZip(d + "/w.zip", charset: "CP1251", files: ["документ.txt": "lower", "Звіт.txt": "uk"], in: d)
    let idx = try ArchiveIndex.read(d + "/w.zip")
    #expect(idx.list("")?.map(\.name).sorted() == ["Звіт.txt", "документ.txt"])
    try idx.extract(["Звіт.txt"], from: "", to: d + "/out")
    #expect(text(d + "/out/Звіт.txt") == "uk")
    #expect(ArchiveIndex.legacyCharset(Array("документ".data(using: .windowsCP1251)!)) == "CP1251")
}

@Test func oneFileCP866ZipIsNotTakenForCP1251() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    legacyZip(d + "/w.zip", charset: "CP866", files: ["шрифт.ttf": "font"], in: d)
    let idx = try ArchiveIndex.read(d + "/w.zip")
    #expect(idx.list("")?.map(\.name) == ["шрифт.ttf"])
    try idx.extract(["шрифт.ttf"], from: "", to: d + "/out")
    #expect(text(d + "/out/шрифт.ttf") == "font")
}

@Test func shortNamesGetTheirCodePage() {
    let cp866 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosRussian.rawValue)))
    for name in ["шрифт.ttf", "сюрприз.txt", "Документ.txt", "Новая папка/договор.pdf", "лог.txt"] {
        #expect(ArchiveIndex.legacyCharset(Array(name.data(using: cp866)!)) == "CP866", "\(name)")
    }
    for name in ["фото.jpg", "Фото.jpg", "план.docx", "книга.pdf", "сон.txt", "лог.txt", "Звіт.txt", "Мої документи/акт.doc"] {
        #expect(ArchiveIndex.legacyCharset(Array(name.data(using: .windowsCP1251)!)) == "CP1251", "\(name)")
    }
}

@Test func utf8ZipKeepsPlainExtractArguments() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    legacyZip(d + "/u.zip", charset: "UTF-8", files: ["Звіт.txt": "uk"], in: d)
    let idx = try ArchiveIndex.read(d + "/u.zip")
    #expect(idx.list("")?.map(\.name) == ["Звіт.txt"])
    #expect(idx.extractArguments([], from: "", to: "/o") == ["-x", "-f", d + "/u.zip", "-C", "/o"])
}

// MARK: - L12: iCloud / Dropbox placeholders aren't read (that would download them)

private func placeholder(_ name: String, size: Int64, mtime: Double, dataless: Bool = true) -> FileItem {
    FileItem(name: name, kind: .file, size: size, mtime: mtime, mode: 0o644, flags: dataless ? UInt32(SF_DATALESS) : 0)
}

@Test func syncByContentSkipsPlaceholders() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    for side in ["L", "R"] { try FileManager.default.createDirectory(atPath: d + "/" + side, withIntermediateDirectories: true) }
    try Data("aaaa".utf8).write(to: URL(fileURLWithPath: d + "/L/f"))
    try Data("bbbb".utf8).write(to: URL(fileURLWithPath: d + "/R/f"))
    let local = placeholder("f", size: 4, mtime: 100, dataless: false)
    let different = DirSync.row("f", local, local, left: d + "/L", right: d + "/R", byContent: true, tolerance: 1)
    #expect(different.action == .skip && different.isConflict && different.unreadable == nil)   // read: they differ
    // Same files, but one side is only a placeholder: not opened, so neither "equal" nor "different"
    let row = DirSync.row("f", local, placeholder("f", size: 4, mtime: 100), left: d + "/L", right: d + "/R", byContent: true, tolerance: 1)
    #expect(row.action == .skip && row.unreadable != nil)
    #expect(DirSync.choices(row) == [.skip])
    #expect(DirSync.mirror([row], toRight: true)[0].action == .skip)   // mirror doesn't copy (download) it either
    // Without "Compare contents" nothing is read anyway: same size and time is equal, as before
    #expect(DirSync.row("f", local, placeholder("f", size: 4, mtime: 100), left: d + "/L", right: d + "/R",
                        byContent: false, tolerance: 1).action == .equal)
}

@Test func contentSearchSkipsPlaceholders() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try Data("has the needle".utf8).write(to: URL(fileURLWithPath: d + "/f"))
    let needle = Array("needle".utf8)
    #expect(FileSearch.contentMatch(placeholder("f", size: 14, mtime: 0, dataless: false), d + "/f", needle, caseSensitive: true) == true)
    #expect(FileSearch.contentMatch(placeholder("f", size: 14, mtime: 0), d + "/f", needle, caseSensitive: true) == nil)
    #expect(FileInfo.flagNames(UInt32(SF_DATALESS)) == ["dataless"])
}

// MARK: - L17: case-insensitive search folds Cyrillic, Greek, accented Latin, not just ASCII

@Test func contentSearchFoldsNonASCIICase() throws {
    let d = tempDir()
    defer { try? FileManager.default.removeItem(atPath: d) }
    try Data("12:00 ERROR Помилка сервера\n".utf8).write(to: URL(fileURLWithPath: d + "/log"))
    for needle in ["помилка", "ПОМИЛКА", "error помилка", "Помилка Сервера", "поМиЛкА"] {
        #expect(FileSearch.fileContains(d + "/log", Array(needle.utf8), caseSensitive: false), "\(needle)")
    }
    #expect(!FileSearch.fileContains(d + "/log", Array("помилка".utf8), caseSensitive: true))
    #expect(!FileSearch.fileContains(d + "/log", Array("помилки".utf8), caseSensitive: false))
    // Across the 1 MB read boundary: the carried tail was folded once already
    var big = Data(repeating: UInt8(ascii: "x"), count: (1 << 20) - 5)
    big.append(contentsOf: Array("ПОМИЛКА".utf8))
    try big.write(to: URL(fileURLWithPath: d + "/edge"))
    #expect(FileSearch.fileContains(d + "/edge", Array("помилка".utf8), caseSensitive: false))
}

@Test func viewerFindFoldsNonASCIICaseAtTheRightOffset() {
    let text = Data("ascii, then Ελληνικά and Ünïcode, then ПОМИЛКА".utf8)
    let at = text.range(of: Data("ПОМИЛКА".utf8))!.lowerBound
    for chunk in [4, 7, 16, 4 << 20] {   // small windows: the match straddles one
        #expect(BigFile.find(Array("помилка".utf8), in: text, from: 0, caseSensitive: false, chunk: chunk) == at)
        #expect(BigFile.find(Array("ελληνικά".utf8), in: text, from: 0, caseSensitive: false, chunk: chunk) != nil)
        #expect(BigFile.find(Array("ÜNÏCODE".utf8), in: text, from: 0, caseSensitive: false, chunk: chunk) != nil)
    }
    #expect(BigFile.find(Array("помилка".utf8), in: text, from: at + 1, caseSensitive: false) == nil)
    #expect(BigFile.find(Array("помилка".utf8), in: text, from: 0, caseSensitive: true) == nil)
}

@Test func caseFoldIsStable() {
    // A folded chunk tail is folded again with the next chunk: that must change nothing
    for cp in 0x80..<0x800 { #expect(BigFile.fold2[Int(BigFile.fold2[cp])] == BigFile.fold2[cp], "U+\(String(cp, radix: 16))") }
    #expect(BigFile.fold2[0x3C2] == BigFile.fold2[0x3A3])   // ς, Σ
    #expect(BigFile.fold2[0x401] == 0x451)                  // Ё → ё
}
