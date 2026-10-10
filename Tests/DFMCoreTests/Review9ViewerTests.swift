import Foundation
import Testing
@testable import DFMCore

// Task 9 QA follow-up, viewer group (tasks/task9_qa_followup/README.md): follow mode.

private func append(_ path: String, _ bytes: [UInt8]) throws {
    let h = try #require(FileHandle(forWritingAtPath: path))
    defer { try? h.close() }
    try h.seekToEnd()
    try h.write(contentsOf: Data(bytes))
}

private func text(_ events: [FollowReader.Event]) -> String {
    events.map { e in
        switch e {
        case .data(let d): String(decoding: d, as: UTF8.self)
        case .rotated: "<rotated>"
        case .truncated: "<truncated>"
        }
    }.joined()
}

/// V3: only whole lines come out, so a line (and a UTF-8 character) split between two writes arrives whole.
@Test func followReaderReturnsWholeLinesOnly() throws {
    let dir = NSTemporaryDirectory() + "dfm-follow-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/app.log"
    try Data("old\n".utf8).write(to: URL(fileURLWithPath: path))
    let r = try #require(FollowReader(path: path, from: 4))
    #expect(r.poll().isEmpty)
    let line = Array("привіт ERROR\n".utf8)
    try append(path, Array(line[..<3]))   // "п" and half of "р"
    #expect(r.poll().isEmpty && r.offset == 4)
    try append(path, Array(line[3...]) + Array("next".utf8))
    #expect(text(r.poll()) == "привіт ERROR\n")
    try append(path, Array("\n".utf8))
    #expect(text(r.poll()) == "next\n")

    // One line longer than a read: cut, but never inside a character.
    try append(path, Array("ййй\n".utf8))
    #expect(text(r.poll(max: 3)) == "й")
    #expect(text(r.poll(max: 3)) == "й")
    #expect(text(r.poll(max: 3)) == "й\n")
}

/// V3 + V8: a new file under the name is a rotation even when it's already bigger than the old one; the old
/// file's last lines come first. The same file getting shorter is a truncation.
@Test func followReaderTellsRotationFromTruncation() throws {
    let dir = NSTemporaryDirectory() + "dfm-follow-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/app.log"
    try Data("one\n".utf8).write(to: URL(fileURLWithPath: path))
    let r = try #require(FollowReader(path: path, from: 4))
    try append(path, Array("two\n".utf8))
    try FileManager.default.moveItem(atPath: path, toPath: path + ".1")
    #expect(text(r.poll()) == "two\n", "renamed away, no new file yet: keep reading the old one")
    try append(path + ".1", Array("three\n".utf8))
    try Data("a much longer first line in the new file\n".utf8).write(to: URL(fileURLWithPath: path))
    #expect(text(r.poll()) == "three\n<rotated>a much longer first line in the new file\n")

    let h = try #require(FileHandle(forWritingAtPath: path))
    try h.truncate(atOffset: 0)
    try h.close()
    try append(path, Array("fresh\n".utf8))
    #expect(text(r.poll()) == "<truncated>fresh\n")
    #expect(r.poll().isEmpty)
}

/// V3: followed text is capped: over the limit, the oldest lines go, down to about half, at a line start.
@Test func followTextTrimsAtALineStart() {
    #expect(FollowReader.trimCount("aaaa\nbbbb\n", limit: 10) == 0)
    #expect(FollowReader.trimCount("aaaa\nbbbb\ncc\n", limit: 10) == 10)        // keeps "cc\n"
    #expect(FollowReader.trimCount("aaaaaaaaaaaa\n", limit: 10) == 8)            // no line start to cut at
    #expect(FollowReader.trimCount("aaaaaaaa😀aaa\n", limit: 10) == 8)          // not inside a surrogate pair
}

/// V3: a rotation seen with more than one read of the old file left reads all of it before switching.
@Test func followReaderReadsAllTheOldFileOnRotation() throws {
    let dir = NSTemporaryDirectory() + "dfm-follow-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/app.log"
    try Data("one\n".utf8).write(to: URL(fileURLWithPath: path))
    let r = try #require(FollowReader(path: path, from: 4))
    try append(path, Array("abcdef\n".utf8))
    try FileManager.default.moveItem(atPath: path, toPath: path + ".1")
    try Data("new\n".utf8).write(to: URL(fileURLWithPath: path))
    #expect(text(r.poll(max: 4)) == "abcd")
    #expect(text(r.poll(max: 4)) == "ef\n<rotated>new\n")

    // Read in pieces, the old file's rest isn't cut inside a character.
    try append(path, Array("ab".utf8))
    try FileManager.default.moveItem(atPath: path, toPath: path + ".2")
    try append(path + ".2", Array("cйf\n".utf8))
    try Data("newer\n".utf8).write(to: URL(fileURLWithPath: path))
    #expect(text(r.poll(max: 4)) == "abc")
    #expect(text(r.poll(max: 4)) == "йf\n<rotated>newe")
}

/// V3: a last line that doesn't get its "\n" (progress dots) shows after a few polls, not cut inside a character.
@Test func followReaderShowsAnUnfinishedLineAfterAWhile() throws {
    let dir = NSTemporaryDirectory() + "dfm-follow-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/app.log"
    try Data().write(to: URL(fileURLWithPath: path))
    let r = try #require(FollowReader(path: path, from: 0))
    let y = Array("й".utf8)
    try append(path, Array("Downloading".utf8) + [y[0]])
    for _ in 0..<3 { #expect(r.poll().isEmpty) }
    #expect(text(r.poll()) == "Downloading")
    try append(path, [y[1]] + Array(" done\n".utf8))
    #expect(text(r.poll()) == "й done\n")
}
