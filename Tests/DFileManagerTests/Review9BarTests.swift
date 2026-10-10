import AppKit
import Testing
@testable import DFileManager

@MainActor private func buttons(_ v: NSView) -> [NSButton] {
    v.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) }
}

/// U4: at 820 pt the bar showed F1–F7 and hid Trash under "+3"; at the narrowest window the six file actions stay.
@Test @MainActor func coreFileActionsStayOnANarrowKeyBar() {
    for width in [820, AppDelegate.minWidth] {
        let bar = KeyBarView()
        bar.reload(AppDelegate().makeCommands())
        bar.frame = NSRect(x: 0, y: 0, width: width, height: 30)
        bar.layout()
        bar.render()
        bar.layoutSubtreeIfNeeded()
        let all = buttons(bar)
        #expect(all.contains { $0.attributedTitle.string.hasPrefix("+") }, "\(width): overflow still reachable")
        for id in KeyBarModel.core {
            guard let b = all.first(where: { $0.identifier?.rawValue == id }) else {
                Issue.record("\(width): \(id) is under +N")
                continue
            }
            #expect(b.frame.width > 0 && bar.bounds.contains(b.convert(b.bounds, to: bar)), "\(width): \(id)")
            #expect(b.fittingSize.width <= b.frame.width + 0.5, "\(width): \(id) label truncated")
        }
    }
}

@Test func overflowTakesOtherKeysBeforeFileActions() {
    let s = ["help.keys", "usermenu", "file.view", "file.edit", "file.copy", "file.move", "file.mkdir", "file.trash", "app.palette", "go.tree"]
        .map { KeySlot(key: $0, label: "", id: $0) }
    let (shown, more) = KeyBarModel.fit(s, capacity: 7)
    #expect(shown.compactMap(\.id) == ["file.view", "file.edit", "file.copy", "file.move", "file.mkdir", "file.trash"] && more == 4)
    #expect(KeyBarModel.fit(s, capacity: 8).shown.compactMap(\.id).first == "help.keys")
    #expect(KeyBarModel.fit(s, capacity: 3).shown.compactMap(\.id) == ["file.view", "file.edit"])
}
