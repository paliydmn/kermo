import Foundation
import Testing
@testable import DFMCore

// New Tool… (Tools PR 4): the id a name gives — the file's name — and the files a tool starts from, each one a tool
// Kermo loads as it is.

@Test func aToolsIdComesFromItsName() {
    #expect(ToolNew.id(from: "My Tool") == "my-tool")
    #expect(ToolNew.id(from: "  Disk  usage (v2)!") == "disk-usage-v2")
    #expect(ToolNew.id(from: "Café Ünïcode") == "cafe-unicode")
    #expect(ToolNew.id(from: "Мій бекап")?.allSatisfy { ("a"..."z").contains($0) || $0 == "-" } == true)
    #expect(ToolNew.id(from: "---") == nil && ToolNew.id(from: "") == nil && ToolNew.id(from: "🙂") == nil)
    #expect(ToolNew.id(from: String(repeating: "a", count: 100))?.count == 64)
}

@Test func everyStarterLoadsWithNoProblem() throws {
    for kind in ToolNew.Kind.allCases {
        let text = ToolNew.text(kind, id: "my-tool", title: #"My "Tool""#)
        let (preset, problems) = ToolSchema.validate(Data(text.utf8), file: "my-tool.json")
        #expect(problems.isEmpty, "\(kind): \(problems)")
        #expect(preset?.id == "my-tool" && preset?.title == #"My "Tool""#, "\(kind)")
    }
    let list = try #require(ToolSchema.validate(Data(ToolNew.text(.list, id: "d", title: "D").utf8), file: "d.json").preset?.list)
    let rows = list.parse.records(Data("/dev/disk1s1 100 50 50 50% /\n/dev/sdb1 10 1 9 10% /mnt/my data\n".utf8))
    #expect(rows.rows.map { $0["mount"]?.text } == ["/", "/mnt/my data"] && rows.unmatched.isEmpty, "the list's pattern fits df -P")
}
