import AppKit
import DFMCore
import SwiftTerm
import Testing
@testable import DFileManager

// Task 21 PR 5: zoom a pane (C2), what happened in a tab that isn't shown (C4).

@MainActor private var windows: [NSWindow] = []   // the terminal holds its host view unowned

@MainActor private func terminal() -> EmbeddedTerminal {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    let panels = NSView(frame: w.contentView!.bounds)
    w.contentView!.addSubview(panels)
    windows.append(w)
    return EmbeddedTerminal(covering: panels)
}

private let a = SFTPTarget(host: "a@dfm-t21c.invalid"), b = SFTPTarget(host: "b@dfm-t21c.invalid"), c = SFTPTarget(host: "c@dfm-t21c.invalid")

/// C2: ⇧⌘↩ — the current pane over its whole tab, the others as they were (sizes kept: no reflow for their programs);
/// again — back where it was, its size too. A split, ⌥⌘ arrows, a closed pane put it back first; one pane: nothing.
@MainActor @Test func zoomShowsOnePaneAndPutsItBack() throws {
    let term = terminal()
    term.restore([.init(vertical: true, panes: [a, b, c])])
    _ = term.show()
    let g = try #require(term.groups.first)
    term.focusPane(by: 1, vertical: true)
    let (pa, pb, pc) = (g.panes[0], g.panes[1], g.panes[2])
    #expect(term.current === pb)
    g.split.window?.contentView?.layoutSubtreeIfNeeded()
    let before = [pa, pb, pc].map(\.box.frame)
    #expect(before.allSatisfy { $0.width > 100 })

    term.zoom()
    g.split.window?.contentView?.layoutSubtreeIfNeeded()
    #expect(g.zoomed === pb && g.split.isHidden && pb.box.superview !== g.split && !pb.box.isHidden)
    #expect(pb.box.frame.width > before[1].width * 2, "over the whole tab: \(pb.box.frame)")
    #expect(pa.box.frame == before[0] && pc.box.frame == before[2], "the others keep their sizes")
    #expect([pa, pb, pc].allSatisfy { $0.header.isHidden }, "no headers over one pane")
    #expect(term.current === pb && term.shows(pb) && !term.shows(pa))

    term.zoom()
    g.split.window?.contentView?.layoutSubtreeIfNeeded()
    #expect(g.zoomed == nil && !g.split.isHidden && g.split.arrangedSubviews == [pa.box, pb.box, pc.box])
    #expect([pa, pb, pc].map(\.box.frame) == before, "back as it was")
    #expect(term.shows(pa) && term.shows(pc))

    term.zoom()
    term.focusPane(by: -1, vertical: true)
    #expect(g.zoomed == nil && term.current === pa && g.split.arrangedSubviews == [pa.box, pb.box, pc.box], "⌥⌘←: the panes again")
    term.zoom()
    term.close(pa.id, confirm: false)
    #expect(g.zoomed == nil && g.split.arrangedSubviews == [pb.box, pc.box] && pa.box.superview == nil, "the zoomed pane closed: its place goes")

    let one = terminal()
    one.restore([.init(vertical: true, panes: [a])])
    _ = one.show()
    one.beep = {}
    one.zoom()
    #expect(one.groups[0].zoomed == nil, "one pane: nothing to zoom")
}

/// C4: a tab that isn't shown says it had output (once a batch reaches it — one hop to the main queue per arming, not per
/// batch) or rang, until it's shown; Kermo's own words in it aren't its program's. A shown tab rings aloud, with no mark.
@MainActor @Test func aHiddenTabSaysWhatHappenedInIt() async throws {
    let term = terminal()
    term.restore([.init(vertical: true, panes: [a]), .init(vertical: true, panes: [b])])
    _ = term.show()
    var beeps = 0
    term.beep = { beeps += 1 }
    let ta = try #require(term.groups.first?.panes.first), tb = try #require(term.groups.last?.panes.first)
    term.select(ta.id)
    #expect(term.shows(ta) && !term.shows(tb) && ta.news == nil && tb.news == nil)

    tb.view.say("Kermo's own words\r\n")
    var hops = 0
    let tell = tb.view.onOutput
    tb.view.onOutput = { hops += 1; tell?() }
    tb.view.startProcess(executable: "/bin/sh", args: ["-c", "while :; do seq 1 2000; sleep 0.05; done"])
    defer { tb.view.process?.terminate() }
    for _ in 0..<300 where tb.news == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(tb.news == .output && hops == 1, "say() isn't output; the first batch tells")
    try await Task.sleep(for: .milliseconds(400))
    #expect(hops == 1, "marked: no more hops while it stays hidden")

    term.select(tb.id)
    #expect(tb.news == nil && term.shows(tb), "shown: no news")
    term.select(ta.id)
    for _ in 0..<300 where tb.news == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(tb.news == .output, "hidden again: watched again")

    // A bell: the hidden tab's marks it, quietly; it stays over output. The shown tab's sounds, with no mark.
    tb.view.terminalDelegate?.bell(source: tb.view)
    #expect(tb.news == .bell && beeps == 0)
    ta.view.terminalDelegate?.bell(source: ta.view)
    #expect(ta.news == nil && beeps == 1)
    ta.view.feed(text: "\u{7}")   // a program's BEL, through SwiftTerm's own queue
    for _ in 0..<100 where beeps < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(beeps == 2)
}
