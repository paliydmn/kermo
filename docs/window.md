# Window


- **Key bar** (bottom row): shows F1–F10. Hold ⇧, ⌥, ⌘ or ⌃ (or a combination such as ⇧⌘ or ⌃⌘) for a moment, and it shows every shortcut that uses those modifiers. Click a slot to run it, just like pressing the key; a pressed shortcut highlights its slot. **Hold ▾** pins a layer for mouse use until you press Esc or run a command, and **+N** opens the cheat sheet filtered to that layer. Change the 120 ms delay with `defaults write com.dmn.dfilemanager keyBarHoldDelay 0.2`.
- **Places sidebar** (⌃⌘S or the toolbar button):
  - **Favorites**: your bookmarks (⌘D). Drag a folder in to add it, drag to reorder, right-click to remove.
  - **Frequent**: your 5 most-visited folders that aren't Favorites.
  - **Locations**: mounted volumes, updated on mount and unmount, with Eject for removable and network volumes.
  - **Servers**: up to 6 recent servers plus **Connect…** (every server: ⌘K opens an SSH shell, ⌃⌘K a file panel). A server's row shows what's open there: `>_` SSH and a folder for SFTP in green (a count from 2), `⇄` for its tunnels listening (red when one failed); its icon has a lock for a locked server and a red dot when its last connection failed, and a production server is purple. Under the mouse: SSH, SFTP, Tunnels and ⋯ — the server's whole menu, as a right-click shows it. The tooltip says all of it.
  - **Tags**: Finder's 7 colors and your own tags. Clicking one lists every tagged file in your home folder.
  - Click opens a place in the active panel, ⌥-click in the other panel, ⌘-click in a new tab. Files dropped on a place are copied or moved there by Finder's rules.
  - ⌃⇧S moves the keyboard focus to the sidebar: ↑↓ choose a place, ↩ opens it (⌥↩ / ⌘↩ as with clicks), ⎋ goes back to the panel. Clicking the sidebar never takes the keys from the panels.
  - While the ⌃O terminal is open, clicking a local place `cd`s the shell there.
  - Sections fold when you click their header. The sidebar hides itself when panels get narrower than 360 pt each and returns from 400 pt, unless you hid it yourself.
- **Toolbar search** (⌘⇧P, F9): finds commands by name or synonym ("zip" finds Compress) and shows their shortcuts. It also finds folders (Favorites, frequent folders, volumes, servers) and files in the active panel. ↑↓ choose, ↩ runs or opens, ⌘↩ opens a folder in the other panel, Esc returns to the panel. The last row searches the disk (⌘F). Focused empty, it lists the last 10 things chosen in it (commands, folders, servers, disk searches) above Favorites; ✕ or ⌘⌫ removes one.
- **Cheat sheet** (F1): every shortcut, grouped by menu, with a filter field. It is generated from the current keymap, so your remapped keys appear in it.
