[Kermo documentation](../README.md#documentation)

# Panels, sidebar and search

How the Kermo window is laid out, and the three ways to reach anything: the key bar, the Places sidebar and search. All keys are in [Keyboard shortcuts](shortcuts.md).

![The window: the Places sidebar on the left, a local Git project and a server over SFTP in two panels, the command line and the key bar at the bottom](images/main-window.png)

## Panels and tabs

The window shows two to four panels side by side, each with its own tabs. Tab moves between panels. With three or four panels, F5 and F6 target the panel that was active before this one. A panel can show a folder on this Mac, a [server](servers.md), an archive, a Git list or search results.

## Key bar

The bottom row shows F1–F10. Hold ⇧, ⌥, ⌘ or ⌃ (or a combination such as ⇧⌘ or ⌃⌘) for a moment and it shows every shortcut that uses those modifiers.

- **Click** a slot to run it, as if you pressed the key. A pressed shortcut highlights its slot.
- **Hold** pins a layer for mouse use until you press ⎋ or run a command. **+N** opens the cheat sheet filtered to that layer.
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

- **Used and free:** right of a volume's name, used in red and free in green (`110 GB / 350 GB`), in whatever room the name leaves: a narrow sidebar cuts them from the end or hides them, and the name is never shortened for them. Widen the sidebar or hover: the tooltip says `/Volumes/USB · 110 GB used of 460 GB · 350 GB free`. Free space is counted as Finder counts it. The figures are read again every 30 seconds while Kermo is in front, after each copy, move or delete, and on mount and unmount. A network share shows the figures the system already has, and none if it has none.
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

F1 lists every shortcut, grouped by menu, with a filter field. It is generated from the current keymap, so your remapped keys appear in it.
