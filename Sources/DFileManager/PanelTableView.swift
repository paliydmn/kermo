import AppKit

/// NSTableView whose selection is only the cursor; marking lives in the panel.
/// Lets the panel see keys and mark-clicks first.
final class PanelTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    var onFocusChange: ((Bool) -> Void)?
    var onMarkClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    var onSelectAll: (() -> Void)?
    var onFind: (() -> Void)?
    /// Rows to drag when the drag starts on `row` (the marked set), or nil for just that row.
    var dragRows: ((Int) -> IndexSet?)?
    private(set) var allowMultiSelection = false

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }
    override func selectAll(_ sender: Any?) { onSelectAll?() }
    /// Edit ▸ Find (⌘F) in a panel means "search files", not "find text".
    override func performTextFinderAction(_ sender: Any?) { onFind?() }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        let mods = event.modifierFlags.intersection([.command, .shift])
        if row >= 0, !mods.isEmpty {
            window?.makeFirstResponder(self)
            onMarkClick?(row, mods)
            return
        }
        if row >= 0, let rows = dragRows?(row) {
            // Temporarily select the marked set so a drag carries all of it.
            allowMultiSelection = true
            selectRowIndexes(rows, byExtendingSelection: false)
            super.mouseDown(with: event)
            allowMultiSelection = false
            if selectedRowIndexes.count > 1 { selectRowIndexes([row], byExtendingSelection: false) }
            return
        }
        super.mouseDown(with: event)
    }
}
