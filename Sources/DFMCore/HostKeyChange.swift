import Foundation

/// ssh refused a server because its host key isn't the one known_hosts has for it ("REMOTE HOST IDENTIFICATION HAS
/// CHANGED"): the server was reinstalled, or someone is in the middle. Read from ssh's words, said plainly; the old key
/// goes only when the user says so (`remove`), never on its own — and the next login asks about the new one.
public struct HostKeyChange: Equatable, Sendable {
    /// As known_hosts names it: "web1", "[203.0.113.5]:2222".
    public var host: String
    /// The known_hosts file and line with the old key ("Offending ED25519 key in <file>:<line>": the line "Add correct
    /// host key in …" cuts a long path short).
    public var file: String
    public var line: Int
    public var keyType: String
    /// The new key's, as ssh says it ("SHA256:…").
    public var fingerprint: String

    /// The change ssh's output tells of; nil for anything else. Not "Offending key for IP in …" (the address's line,
    /// CheckHostIP): the host's own line is the one.
    public static func parse(_ text: String) -> HostKeyChange? {
        guard text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var host: String?, file: String?, line: Int?, type: String?, fingerprint: String?
        for (i, l) in lines.enumerated() {
            if l.hasPrefix("The fingerprint for the "), l.hasSuffix(" key sent by the remote host is"), i + 1 < lines.count {
                type = String(l.dropFirst("The fingerprint for the ".count).dropLast(" key sent by the remote host is".count))
                fingerprint = String(lines[i + 1].hasSuffix(".") ? lines[i + 1].dropLast() : lines[i + 1][...])
            } else if l.hasPrefix("Offending "), !l.hasPrefix("Offending key for IP"), let at = l.range(of: " key in "),
                      let colon = l[at.upperBound...].lastIndex(of: ":"), let n = Int(l[l.index(after: colon)...]) {
                (file, line) = (String(l[at.upperBound..<colon]), n)
            } else if l.hasPrefix("Host key for "), let end = l.range(of: " has changed") {
                host = String(l["Host key for ".endIndex..<end.lowerBound])
            }
        }
        guard let host, let file, let line, let type, let fingerprint, !host.isEmpty, !file.isEmpty else { return nil }
        return HostKeyChange(host: host, file: file, line: line, keyType: type, fingerprint: fingerprint)
    }

    /// In plain words, for `server` (as the user names it).
    public func message(_ server: String) -> String {
        "\(server)'s host key has changed. Either the server was reinstalled, or someone is intercepting the connection.\n\n"
            + "New \(keyType) key: \(fingerprint)\nOld key: \((file as NSString).abbreviatingWithTildeInPath), line \(line)"
    }

    /// Takes the old key out of its file (`ssh-keygen -R`, which keeps a copy as <file>.old). ssh-keygen exits 0 when it
    /// found nothing too: done only when it says it found and updated. Throws what it said otherwise.
    public func remove() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-R", host, "-f", file]
        let out = Pipe()
        (p.standardInput, p.standardOutput, p.standardError) = (FileHandle.nullDevice, out, out)
        try p.run()
        let said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard said.contains("found"), said.contains("updated") else {
            throw SFTPError(message: "The old key of \(host) wasn't removed from \((file as NSString).abbreviatingWithTildeInPath): "
                            + (said.isEmpty ? "ssh-keygen exited with \(p.terminationStatus)" : said.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }
}
