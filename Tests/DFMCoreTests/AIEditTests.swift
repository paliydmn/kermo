import Foundation
@testable import DFMCore
import Testing

// Task 23 PR 7: propose_edit's change — made on the text as the editor holds it, never on a hidden value — and the
// parts the user keeps, put back as one change.

private func edit(_ text: String, _ edits: [(String, String)]) -> Result<String, AIEdit.Refused> {
    AIEdit.propose(edits.map { (old: $0.0, new: $0.1) }, to: text, in: "/etc/app.conf").map(\.proposed)
}
private func words(_ r: Result<String, AIEdit.Refused>) -> String { if case .failure(let no) = r { no.words } else { "" } }

@Test func anEditIsMadeOnceWhereTheModelCouldSeeIt() throws {
    let conf = "a = 1\nb = 2\nc = 1\n"
    #expect(try edit(conf, [("b = 2", "b = 3\nd = 4")]).get() == "a = 1\nb = 3\nd = 4\nc = 1\n")
    #expect(try edit(conf, [("a = 1\n", ""), ("c = 1", "c = 9")]).get() == "b = 2\nc = 9\n", "in order, each on the text the one before left")
    #expect(try edit(conf, [("b = 2\r\n", "b = 5\r\n")]).get() == "a = 1\nb = 5\nc = 1\n", "the model's CRLF is the editor's LF")
    #expect(try edit("a\r\nb\nc\n", [("a\r\n", "x\r\n")]).get() == "x\r\nb\nc\n", "a file of mixed line ends keeps them, as the editor does")
    #expect(try edit("", [("", "new\n")]).get() == "new\n" && words(edit(conf, [("", "x")])).contains("has to be there"), "an empty file's first text")
    #expect(words(edit(conf, [("= 1", "= 9")])).contains("2 times") && words(edit("aaa", [("aa", "b")])).contains("2 times"), "overlapping ones count")
    #expect(words(edit(conf, [("z = 0", "z = 1")])).contains("isn't in /etc/app.conf"))
    #expect(words(edit(conf, [("a = 1", "a = 2"), ("z", "y")])).hasPrefix("Edit 2: "), "which one, when there are more")
    #expect(words(edit(conf, [("b = 2", "b = 2")])).contains("differ") && words(edit(conf, [])).contains("at least one"))
    #expect(AIEdit.editorText("\u{FEFF}a\r\nb\r\n") == "a\nb\n" && AIEdit.editorText("a\r\nb\n") == "a\r\nb\n" && AIEdit.editorText("a\r\r\n") == "a\r\r\n")
    #expect(words(edit(conf, [("b = 2", "b = 3"), ("b = 3", "b = 2")])) == "The edits change nothing.")
}

@Test func aHiddenValueIsNeitherChangedNorConfirmed() {
    let key = "hun" + "ter22", conf = "user=bob\npass" + "word=\(key)\nport=80\n"
    // What the model saw was •••: it can't be taken as old_text, nor written back.
    #expect(words(edit(conf, [("pass" + "word=•••", "pass" + "word=x")])).contains("Kermo hid a value"))
    #expect(words(edit(conf, [("port=80", "port=•••")])).contains("Kermo hid a value"))
    // A guess inside it is no match — the same words as any miss, so they never tell a guess right.
    #expect(words(edit(conf, [(key, "x")])) == words(edit(conf, [("nothing-like-it", "x")])))
    #expect(words(edit(conf, [("=\(key)\nport", "=x\nport")])).contains("isn't in"))
    // On its name, or right beside it changing the character next to it: the change would run into it.
    #expect(words(edit(conf, [("pass" + "word=", "pass" + "word=x")])).contains("right at a value Kermo hid"))
    #expect(words(edit(conf, [("\nport=80", "port=81")])).contains("right at a value Kermo hid"), "joined to its line")
    #expect(words(edit(conf, [("bob\n", "bob")])).contains("right at a value Kermo hid"), "its line joined to the one before")
    // Around it is fine: whole lines before and after, their line ends as they are.
    #expect((try? edit(conf, [("user=bob\n", "user=al\n"), ("\nport=80", "\nport=81")]).get()) == "user=al\npass" + "word=\(key)\nport=81\n")
    // Its name isn't the model's to change, whatever the value is: the words never depend on it.
    let db = "DB_PASS" + "WORD=\(key)\nport=80\n", other = "DB_PASS" + "WORD=x!y\nport=80\n"
    for e in [("DB_PASS" + "WORD", "DB_X"), ("DB_PASS" + "WORD", "DB_PASS" + "WORD_OLD"), ("DB_PASS" + "WORD", "Bearer aaaa"), ("DB_PASS" + "WORD", "Bearer abcdefghijkl")] {
        #expect(words(edit(db, [e])).contains("right at a value Kermo hid") && words(edit(db, [e])) == words(edit(other, [e])), "\(e)")
    }
    // Text put elsewhere that makes more of it hidden: fine, and `mask` hides it all afterwards.
    let hid = try? edit("# db\nx_tok" + "en=hunter!2\n", [("# db", "# db Bearer")]).get()
    #expect(hid.map { AISecrets.mask($0).text } == "# db Bearer\n•••\n")
    // A secret written by the model is its own: the card shows it to the user; the base's stays •••.
    let p = try? AIEdit.propose([(old: "port=80", new: "api_" + "key=abc123")], to: db, in: "x").get()
    #expect(p?.proposed == "DB_PASS" + "WORD=\(key)\napi_" + "key=abc123\n" && p?.hiddenNew == [NSRange(location: 12, length: key.count)] && p?.hiddenOld == p?.hiddenNew)
}

/// Review 6 PR 8: a value the wider patterns hide is kept as any other — a flag's, a dashed key's.
@Test func aValueHiddenByAFlagIsKeptToo() {
    let key = "hun" + "ter22", conf = "run=mysql --pass" + "word \(key) --host db\napi-" + "key: \(key)\nport=80\n"
    #expect(words(edit(conf, [(key, "x")])) == words(edit(conf, [("nothing-like-it", "x")])), "a guess inside it is no match")
    #expect(words(edit(conf, [("--pass" + "word", "--user")])).contains("right at a value Kermo hid"))
    #expect(words(edit(conf, [("api-" + "key", "api-id")])).contains("right at a value Kermo hid"))
    #expect((try? edit(conf, [("\nport=80", "\nport=81")]).get()) == "run=mysql --pass" + "word \(key) --host db\napi-" + "key: \(key)\nport=81\n", "around it is fine")
}

@Test func whatsKeptIsPutBackAsOneChangeOfWholeLines() {
    let cases: [(String, String)] = [
        ("a\nb\nc\nd\ne\nf\ng\n", "a\nB\nc\nd\ne\nF\nG\nh\n"),
        ("one\ntwo", "zero\none\ntwo\nthree"),   // no final newline, added at both ends
        ("x\ny\n", "x\n"), ("x\ny", "x\ny\n"), ("x\ny\n", "x\ny"),   // the last line, the final newline
        ("😀 a\nb\n", "😁 a\nb\n"), ("e\u{301}\nz\n", "e\u{300}\nz\n"),   // a cut never inside a character
        ("", "new\n"),
    ]
    // Line ends the blocks can't carry (a lone CR or U+2028 at a block's edge), a change of line ends only: no card,
    // Compare only.
    for (base, new) in [("a\r", "a\rb"), ("a\rb", "a\r"), ("a\u{2028}b", "a\u{2028}"), ("a\rb", "a\nb"), ("p\rq\nr\n", "p\rQ\nr\n"), ("b\na\nb\r\rx", "a\n")] {
        let p = AIEdit.Proposal(base: base, proposed: new)
        #expect(p.diff == nil && p.changedLines > AIEdit.cardLines && AIEdit.kept(p, []) == base, "\(base.debugDescription) → \(new.debugDescription)")
    }
    for (base, new) in cases {
        let p = AIEdit.Proposal(base: base, proposed: new)
        let n = p.diff?.blocks.count ?? 0
        #expect(n > 0, "\(base.debugDescription)")
        #expect((AIEdit.kept(p, Array(repeating: true, count: n)) as NSString).isEqual(to: new), "all kept: \(base.debugDescription) → \(new.debugDescription)")
        #expect((AIEdit.kept(p, Array(repeating: false, count: n)) as NSString).isEqual(to: base), "none kept: \(base.debugDescription)")
        for mask in 0..<(1 << n) {   // any choice: one range of the base, whole lines, gives just that
            let keep = (0..<n).map { mask & (1 << $0) != 0 }, want = AIEdit.kept(p, keep)
            guard let s = AIEdit.span(base, want) else { #expect(!keep.contains(true)); continue }
            let made = (base as NSString).replacingCharacters(in: s.range, with: s.text)
            #expect((made as NSString).isEqual(to: want), "\(base.debugDescription) \(keep)")
            let starts = s.range.location == 0 || (base as NSString).character(at: s.range.location - 1) == 10 || (base as NSString).character(at: s.range.location - 1) == 13
            #expect(starts, "\(base.debugDescription): a line's start")
        }
    }
    // Only the kept one changes; the dropped one stays.
    let p = AIEdit.Proposal(base: "a\nb\nc\nd\n", proposed: "A\nb\nc\nD\n")
    #expect(AIEdit.kept(p, [false, true]) == "a\nb\nc\nD\n" && AIEdit.span("a\nb\nc\nd\n", "a\nb\nc\nD\n")! == (NSRange(location: 6, length: 2), "D\n"))
    #expect(AIEdit.span("same", "same") == nil && AIEdit.editorText("\u{FEFF}a\r\nb\r\n") == "a\nb\n")
    #expect(AIEdit.Proposal(base: "a\n", proposed: "b\n").changedLines == 2)
}

@Test func theHiddenRangesCoverWhatMaskHides() {
    let token = "sk-" + String(repeating: "A1b2", count: 6)
    let texts = ["DB_PASS" + "WORD=s3cr3t-value", "Authorization: Bearer abcdefghijklmnop", "url=postgres://u:pa55w0rd@db/x", "key \(token) here",
                 "-----BEGIN RSA PRIVATE " + "KEY-----\nMIIEow\nAAAA\n-----END RSA PRIVATE " + "KEY-----\nnext"]
    for t in texts {
        let s = t as NSString, hidden = AISecrets.ranges(t)
        #expect(!hidden.isEmpty, "\(t)")
        // Each range made •••, in one go, hides at least what `mask` does: nothing it hid is left in the text.
        let out = NSMutableString(string: t)
        for r in hidden.sorted(by: { $0.location > $1.location }) where NSMaxRange(r) <= out.length { out.replaceCharacters(in: r, with: "•••") }
        for secret in ["s3cr3t-value", "abcdefghijklmnop", "pa55w0rd", token, "MIIEow"] where s.contains(secret) {
            #expect(!(out as String).contains(secret), "\(t)")
        }
    }
    #expect(AISecrets.ranges("port=80\nuser=bob").isEmpty)
    for t in texts { #expect(AISecrets.mask(t).hidden == AISecrets.ranges(t).count, "one source: \(t)") }
}

@Test func proposeEditTakesAListOfEdits() throws {
    let tool = try #require(AITools.all.first { $0.name == "propose_edit" })
    let places: (String) -> AIPlace? = { $0 == "mac" ? .mac : nil }
    func call(_ edits: ToolValue) -> [AITarget]? { tool.targets(["server": "mac", "path": "/etc/hosts", "edits": edits], resolve: places) }
    let one: ToolValue = .object(["old_text": "a", "new_text": "b"])
    #expect(call(.array([one, one])) == [AITarget(.mac, "/etc/hosts", .read)!])
    #expect(call("a → b") == nil && call(.array([.object(["old_text": "a"])])) == nil, "a text, a field missing")
    #expect(call(.array([.object(["old_text": "a", "new_text": "b", "more": "c"])])) == nil && call(.array([.object(["old_text": "a", "new_text": .bool(true)])])) == nil)
    guard case .object(let o) = tool.schema, case .object(let props)? = o["properties"], case .object(let edits)? = props["edits"],
          case .object(let items)? = edits["items"] else { Issue.record("schema"); return }
    #expect(edits["type"] == "array" && items["required"] == .array(["old_text", "new_text"]) && o["required"] == .array(["server", "path", "edits"]))
    // Edit: Ask's tools and propose_edit; Ask's instructions as they were, Edit's of the same rules.
    #expect(AIChat.editTools.map(\.name) == AIChat.askTools.map(\.name) + ["propose_edit"])
    #expect(AIChat.askSystem.contains("Mode: Ask — you read and answer, and change nothing.") && !AIChat.askSystem.contains("Mode: Edit"))
    #expect(AIChat.editSystem.contains("Mode: Edit") && AIChat.editSystem.hasSuffix(String(AIChat.askSystem.suffix(from: AIChat.askSystem.range(of: "Rules:")!.lowerBound))))
}
