[Kermo documentation](../README.md#documentation)

# Panels, sidebar and search

How the Kermo window is laid out, and the three ways to reach anything: the key bar, the Places sidebar and search. All keys are in [Keyboard shortcuts](shortcuts.md).

![The window: the Places sidebar on the left, a local Git project and a server over SFTP in two panels, the command line and the key bar at the bottom](images/main-window.png)

## Panels and tabs

The window shows two to four panels side by side, each with its own tabs. Tab moves between panels. The active panel has a 2 pt line under its path bar in the color of where it is: the accent color on this Mac (a theme with a background has its own, cyan in Midnight Commander and Far Manager), purple on a production server, orange in a [root panel](root-panel.md), purple again when that's on a production server. Its path is in full contrast, the other panels' paths are dimmed, and in the System theme their cursor is an outline. A panel can show a folder on this Mac, a [server](servers.md), an archive, a Git list or search results.

The tab in front has a bold title with a line under it, in the accent color or the server's purple or orange; the other tabs' titles are grey. A server's tab has its chips before its title: PROD for a production server, ROOT for a root panel. The terminal's tabs look the same, and an SSH tab's dot is green while it's connected, grey when it isn't; a root login's tab has ROOT.

With three or four panels, F5 and F6 target the panel that was active before this one. Its path bar ends with **→ F5** in that panel's color, and the mark moves when Tab or a click makes another panel active.

Under the tabs, the path bar says where the panel is. On a server, in an archive or in search results a symbol before the path says which (a server rack, a box, a magnifier), and a server's chips follow it: PROD for a production server, ROOT for a [root panel](root-panel.md), LOCKED for a server locked with Touch ID. The path itself is plain text, which ⌘L edits.

### After a restart

Kermo comes back as you left it: each panel's tabs and the one in front, the active panel, each tab's cursor (on the same name; on the first row if that item is gone) and the dividers between the panels. Filters, Back / Forward history and marks start clean.

A server tab comes back **not connected**. Its header says where it was (`web1:/etc/nginx`, with a ROOT chip for a root panel), and its only row says `Not connected — ↩ connects to web1`. Nothing is sent to any server until you ask, production and locked ones included:

- **↩** or a double-click connects, as Connect does: a locked server asks for Touch ID first, and the cursor goes back to its name. A root tab connects as root; ⌃⌘R / ⌃⇧⌘R choose root or the user instead.
- ⌘↑ or ⌫ goes to the tab's folder on this Mac; the sidebar, ⌘L and the like go where you point, as on a local tab.
- The F-keys, the command line and anything else that would act on the files say `Not connected — ↩ connects to web1` and do nothing; so do copies and moves into it from the other panel.

SSH tabs in the terminal come back the same way: ↩ reconnects them ([Terminal](terminal.md)).

## Key bar

The bottom row shows F1–F10. Hold ⇧, ⌥, ⌘ or ⌃ (or a combination such as ⇧⌘ or ⌃⌘) for a moment and it shows every shortcut that uses those modifiers.

- **Click** a slot to run it, as if you pressed the key. A pressed shortcut highlights its slot.
- **Hold** pins a layer for mouse use until you press ⎋ or run a command. **+N** opens the cheat sheet filtered to that layer.
- ⌥ plus a digit does what its F-key does, so those layers sum them up in one slot: `⌥1…0 = F1…F10`, `⌥⇧4 5 6 8 = ⇧F4 5 6 8`.
- On a server's panel F8 says **Delete…** in red: it deletes for good after asking, because a server has no Trash.
- F5 and F6 say where they go when it isn't plain: `Copy → web-01` when the other panel is on a server (a production server's name in purple and bold), `Copy → site` with three or four panels. With two panels on this Mac they say **Copy** and **Move**.
- The delay is 120 ms. Change it with `defaults write com.dmn.dfilemanager keyBarHoldDelay 0.2`.

## Places sidebar

Show or hide it with ⌃⌘S (or the toolbar button). It has these sections:

- **Favorites:** your bookmarks (⌘D). Drag a folder in to add it, drag to reorder, right-click to remove.
- **Frequent:** the 5 folders you visit most, weighting recent visits more, that aren't Favorites.
- **Locations:** mounted volumes, then in gray the volumes of plugged-in disks that aren't mounted. See [Volumes](#volumes) below.
- **Servers:** five rows (your pinned servers plus one, if you pin more), then **Connect…** (⌘K opens an SSH shell, ⌃⌘K a file panel). Pinned servers always get a row, then the servers used last and those with an open session; saved servers and `~/.ssh/config` hosts fill any rows left. The rows keep a fixed order (pinned, saved, `~/.ssh/config` hosts, then the rest by name), not the order of use. [Server rows](servers.md#server-rows-in-the-sidebar) are explained on the servers page.
- **Tags:** Finder's 7 colors and the last 10 custom tags you set in Kermo's Tags dialog. Clicking one lists every tagged file in your home folder.
- **Git:** at the bottom, while the active panel is in a repository: its branch and what changed. See [the Git row](git.md#the-git-row-in-the-sidebar).

How to use it:

- **Click** opens a place in the active panel, **⌥-click** in the other panel, **⌘-click** in a new tab. Files dropped on a place are copied or moved there by Finder's rules.
- **⌃⇧S** moves the keyboard focus to the sidebar: ↑↓ choose a place, ↩ opens it (⌥↩ and ⌘↩ as with clicks), ⎋ goes back to the panel. Clicking the sidebar never takes the keys from the panels.
- While the ⌃O terminal is open, clicking a local place runs `cd` there in the shell.
- Click a section's header to fold it (the Git section doesn't fold). The sidebar hides itself when panels get narrower than 360 pt each and returns from 400 pt, unless you hid it yourself.

### Volumes

- **Free space:** under a volume's name, a thin bar of how full it is — grey, amber from 85 % full, red from 95 % — and `350 GB free` beside it. A narrow sidebar shortens that to `350 GB`, then shows the bar alone. Widen the sidebar or hover: the tooltip says `/Volumes/USB · 110 GB used of 460 GB · 350 GB free`. Free space is counted as Finder counts it. The figures are read again every 30 seconds while Kermo is in front, after each copy, move or delete, and on mount and unmount. A network share shows the figures the system already has, and none if it has none.
- **Eject:** ⏏ on a removable or network volume's row, ⌥⌘E for the active panel's volume.
- **Mount:** a gray volume's ⊕ mounts it. Clicking its row, or ↩ on it in **Volumes…** (⇧⌘V), mounts it and opens it in the active panel.
- **Unmount:** the volume goes and its disk stays plugged in, so the row turns gray, ready to mount again. Right-click a volume for **Mount**, **Unmount** or **Eject**. **Unmount Volume** is also in ⇧⌘P, for the active panel's volume.
- **While it runs:** a spinner takes the button's place, and the row takes no second Mount, Unmount or Eject. Before Unmount or Eject, panels on the volume go to your home folder.
- **When a volume won't go:** the alert names who holds it, for example `Couldn't eject “KINGSTON”: in use by Preview, zsh`. Close the file there and try again.
- **Which volumes show unmounted:** only external and removable disks, a card in the Mac's reader among them. This Mac's own disk, the disk the Mac started from (an external one too), disk images, network shares, the EFI partition and macOS's service volumes (Preboot, Recovery, VM…) never do. On an external macOS disk the mounted system snapshot is listed, not its System volume. Unmount is offered only for volumes that can be mounted again from here. A disk image's or a share's row has Eject only.

## Search

Press ⇧⌘P (or F9, ⌥9) to open the toolbar search. It finds:

- **commands** by name or synonym ("zip" finds Compress), with their shortcuts;
- **folders:** Favorites, frequent folders, volumes and recently used servers;
- **files** in the active panel.

↑↓ choose, ↩ runs or opens, ⌘↩ opens a folder in the other panel, ⎋ returns to the panel. The last row searches the disk (⌘F). When it is focused and empty, it lists the last 10 things you chose (commands, folders, servers, disk searches) above Favorites; ✕ or ⌘⌫ removes one.

## Cheat sheet

F1 lists every shortcut, grouped by menu, with a filter field. It is generated from the current keymap, so your remapped keys appear in it. Over a viewer or an editor, F1 lists that window's keys and the menu keys that work there.
