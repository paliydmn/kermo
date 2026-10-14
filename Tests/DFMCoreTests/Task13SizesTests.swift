import Foundation
import Testing
@testable import DFMCore

// Task 13: folder sizes by the server's own `du` (`ServerSizes`).

/// GNU du 9.4 and busybox 1.37 on a folder with an unreadable subfolder and a name that isn't there: each prints what it
/// could read, its complaints on stderr, and exits 1. A size with a complaint under it is "at least".
@Test func duAnswersAreReadWhateverTheExitStatus() {
    let names = ["a", "b", "missing"]
    let gnu = ServerSizes.parse("Welcome to the server\nkermo-sizes\n3349\ta\n500\tb\n", errors: """
        du: cannot read directory 'b/locked': Permission denied
        du: cannot access 'missing': No such file or directory
        """, status: 1, names: names)
    #expect(gnu == ["a": .init(bytes: 3349), "b": .init(bytes: 500, partial: true)])
    let busybox = ServerSizes.parse("kermo-sizes\n11541\ta\n12788\tb\n", errors: "\n\ndu: can't open 'b/locked': Permission denied\n\n",
                                    status: 1, names: names)
    #expect(busybox == ["a": .init(bytes: 11541), "b": .init(bytes: 12788, partial: true)])
    #expect(ServerSizes.parse("kermo-sizes\n0\ta\n", errors: "", status: 0, names: names) == ["a": .init(bytes: 0)])
}

/// Only the names asked for, and only after the script's own line (a login script may print "12\tx" too); a complaint
/// that points at none of them (a name du quotes its own way) makes every size "at least"; no line, no size.
@Test func duLinesAreMatchedByName() {
    let names = ["sp ace", "tab\there", "-rf", "it's"]
    let out = "12\tsp ace\nkermo-sizes\n7\tsp ace\n9\ttab\there\n5\t-rf\n3\tother\n2\tit's\nnot a number\tx\n"
    #expect(ServerSizes.parse(out, errors: "", status: 0, names: names)
            == ["sp ace": .init(bytes: 7), "tab\there": .init(bytes: 9), "-rf": .init(bytes: 5), "it's": .init(bytes: 2)])
    let odd = ServerSizes.parse(out, errors: "du: cannot read directory \"it's/x\": Permission denied", status: 1, names: names)
    #expect(odd.values.allSatisfy(\.partial) && odd.count == 4)
    #expect(ServerSizes.parse(out, errors: "du: cannot read directory 'it's/x'", status: 0, names: names).values.allSatisfy { !$0.partial },
            "exit 0: nothing went unread")
    #expect(ServerSizes.parse("12\ta\n", errors: "", status: 0, names: ["a"]).isEmpty, "no script line: nothing is du's")
}
