[Kermo documentation](../README.md#documentation)

# Keyboard shortcuts

Every shortcut in Kermo, grouped by what it does. Press F1 in the app for the list of command shortcuts, generated from your current keymap.

Keys are written as on the Mac's menus: ⌃ Control, ⌥ Option, ⇧ Shift, ⌘ Command, always in that order (⌃⌥⇧⌘), so ⇧⌘P means Shift, Command and P together. A slash separates the keys of paired actions: "Copy / Move: F5 / F6".

- **Find any command** with ⇧⌘P: it is listed with its shortcut. (The viewer and editor keys and mouse marking aren't commands, so search doesn't list them.)
- **Function keys:** F1–F10 and ⇧F4, ⇧F5, ⇧F6, ⇧F8 also work as ⌥ plus the digit (⌥0 is F10, ⌥⇧6 is ⇧F6), because Mac function keys control media by default. The other F-key shortcuts (⇧F2, ⇧F10, ⌥F1, ⌥F5, ⌥F7, ⌥F9, ⌥F10) have no digit twin: use fn, or remap them.
- **Text fields** (path entry, the command line, dialogs) take the usual ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z.
- **Questions:** ⎋ is Cancel. On a production server and for what can't be undone, ↩ is Cancel too and **⌘↩** does the action; the question's last line says so ([how a question asks](safety.md#how-a-question-asks)).
- **Layouts:** shortcuts are bound to physical keys, so they work with any keyboard layout (the ISO § key counts as `` ` ``). Menus show the characters of your current layout, so on a layout that moves Latin letters (Dvorak, AZERTY) a letter shortcut in a menu follows the letter.
- **Remap:** in **Settings › Keys** (⌘,) click a key and press the new one; or choose **Kermo ▸ Configuration ▸ Edit Keymap…**, then **Reload Config** (see [Configuration](configuration.md#keymap)).

> [!NOTE]
> Two shortcuts clash with macOS: ⇧⌘/ (computer root) is also the Help menu search, and ⌃1…⌃7 (Finder tags) switch desktops once you have several. Turn them off in System Settings ▸ Keyboard ▸ Keyboard Shortcuts, or remap the command. ⌘M minimizes the window, as everywhere on the Mac.

## Search and help

| Action | Keys |
|---|---|
| Search commands, folders and files | ⇧⌘P, F9, ⌥9 |
| Keyboard shortcuts cheat sheet (over a viewer or an editor: its keys) | F1, ⌥1 |
| Settings | ⌘, |
| Find a menu command by name | **Help** menu's search field |

## Panels, tabs and navigation

| Action | Keys |
|---|---|
| Next panel / panel N | Tab / ⌘1…⌘4 |
| Add / close a panel (2–4; F5 and F6 target the previously active one) | ⌥⌘N / ⌥⌘W |
| Show / hide the Places sidebar | ⌃⌘S |
| Activity: running, queued and finished copies, moves and deletes | ⌥⌘J |
| Keyboard focus to the sidebar (↑↓ choose, ↩ open, ⎋ back to the panel) | ⌃⇧S |
| New tab / close tab (or click its ×) | ⌘T / ⌘W |
| Next / previous tab | ⌃⇥, ⇧⌘] / ⌃⇧⇥, ⇧⌘[ |
| Swap panels / open the same folder in the other panel | ⌘U / ⌥= |
| Go to a folder (bookmarks and frequent folders) | ⌘P |
| Bookmark this folder (again: remove the bookmark) | ⌘D |
| Path entry with Tab completion (or a click on an empty spot of the path bar) | ⌘L, ⇧⌘G |
| Up / back / forward | ⌫, ⌘↑ / ⌘[ / ⌘] |
| Home / computer root | ⇧⌘H / ⇧⌘/ |
| Directory tree (←/→ collapse/expand, ↩ open) | F10, ⌥0, ⌥F10, ⇧⌘T |
| Open / enter an `.app` bundle | ↩ (or the keypad's ⌤) / ⌘↓ |
| Follow a link's target | ⌘J |
| Show hidden files / refresh | ⇧⌘. / ⌘R |
| Volumes (↩ on a gray one mounts it) / eject | ⇧⌘V, ⌥F1 / ⌥⌘E |
| Back to the panels from a viewer or editor | ⌘0 |

## Marking, filtering and finding

| Action | Keys |
|---|---|
| Mark files (Midnight Commander style) | Space, ⇧↑ / ⇧↓, ⌘-click, ⇧-click |
| Mark all / unmark all / invert | ⌘A / ⇧⌘A / `*` |
| Mark / unmark files by mask (folders are never touched) | `+` / `-` |
| Quick filter (text, `*.glob`, `re:`) / presets and recent filters | `/` / ⌘/ |
| Find files (name, content, Spotlight) | ⌘F, ⌥F7 |
| Calculate directory sizes: all / one | ⌥Space / Space (⎋ stops) |
| Quick View in the other panel / Quick Look | ⌃Q / ⌘Y |

## Files

| Action | Keys |
|---|---|
| View / edit | F3, ⌥3 / F4, ⌥4 |
| Context menu of the cursor's item (on `..`: of the folder) | ⇧F10, Menu (a PC keyboard's) |
| Copy / move | F5, ⌥5 / F6, ⌥6 |
| Rename / batch rename | ⇧F6, ⌥⇧6 / ⇧⌘M |
| Copy here under another name (`x.conf.bak`; several marked: a suffix each) | ⇧F5, ⌥⇧5 |
| New folder / new file | F7, ⌥7, ⇧⌘N / ⇧F4, ⌥⇧4 |
| Move to Trash (on a server: Delete…, after asking) | F8, ⌥8, ⌘⌫, ⌦ |
| Delete permanently | ⇧F8, ⌥⇧8, ⌥⌘⌫, ⇧⌦ |
| Put Back (restore an item Kermo moved to the Trash) | ⌘⌫ or F8 in the Trash |
| Undo / redo (this Mac's files; not a server's, not permanent delete) | ⌘Z / ⇧⌘Z |
| Info in Quick View: permissions, owner, xattr, ACL, hashes, signature (a server's file too) | ⌘I |
| Permissions and owner (chmod, chown; also on a server) | ⌥⌘A |
| Copy files / paste / move here | ⌘C / ⌘V / ⌥⌘V |
| Copy path / name | ⇧⌘C / ⌥⌘C |
| Reveal in Finder / open Terminal here | ⇧⌘R / ⌥⌘T |
| Create a symbolic link | ⌥⌘L |
| Open an archive as a folder / extract / create | ↩ / F5, ⌥F9 / ⌥F5 |
| Finder tags: color / remove all / edit | ⌃1…⌃7 / ⌃0 / ⌃T |

**Create Hard Link…** (**File ▸ Links**), **Split File…** and **Combine Parts…** (`.000`, `.001`, …; **File ▸ Split & Combine**) are in search too, without a key.

## Compare and Git

| Action | Keys |
|---|---|
| Compare folders recursively (marks differences) | ⇧F2 |
| Synchronize folders (two-way or mirror → / ←; also with a server) | ⇧⌘S |
| Diff two files (two marked, the cursor and the same name in the other panel, or both cursors; also a server's) | ⇧⌘D |
| Git: only changes / all changes as a list / diff against HEAD | ⌃G / ⌃⇧G / ⌃D |
| Git: log of the file / blame (in the viewer) | ⌃L / ⌃⇧L |
| Git: stage / unstage the marked files | ⌃⇧A / ⌃⇧U |
| Git: switch or create a branch / commit | ⌃B / ⌃⇧C |

## Servers, terminal and commands

| Action | Keys |
|---|---|
| Connect to a server in a file panel (SFTP; `~/.ssh/config`, `user@host:/path`, or `smb://` `nfs://` `afp://`) | ⌃⌘K |
| New SSH session: a shell on a server in the terminal (inside the terminal, ⌘K clears it) | ⌘K |
| Server panel as root / as its user again | ⌃⌘R / ⌃⇧⌘R |
| The terminal in a drawer under the panels (the active panel follows `cd`): open, go to it from a panel, hide it from the terminal; press ⌃O twice quickly to send ⌃O to the terminal | ⌃O |
| The terminal over the panels' room too, and back into its drawer | ⌃⇧O |
| Terminal text bigger / smaller | ⌘+ or ⌘= / ⌘− |
| Terminal: selecting copies; a right-click pastes (⇧-right-click in mc, htop and the like) | select / right-click |
| Terminal: split the tab, the new session to the right / below | ⌘\\ / ⇧⌘\\ |
| Terminal: the pane to the left, right, above, below | ⌥⌘← ⌥⌘→ ⌥⌘↑ ⌥⌘↓ |
| Terminal: move the pane's divider | ⌃⌘← ⌃⌘→ ⌃⌘↑ ⌃⌘↓ |
| User command menu / command line | F2, ⌥2 / ⌘E |
| Insert the cursor's name / the marked items' full paths into the command line, or into the shell while the terminal is open | ⌃↩ / ⌃⇧↩ |

In the command line, ↑↓ browse its history. On a local panel ↩ runs the line in the ⌃O shell (your aliases, colors, `sudo`, history), ⇧↩ in an output window, ⌘↩ in Terminal. On a server panel ↩ and ⇧↩ run it over ssh in an output window, and ⌘↩ opens an SSH tab with the command.

**File ▸ As Administrator ▸ Copy as Administrator…**, **Move as Administrator…**, **New Folder as Administrator…**, **Delete as Administrator…** and **Root Shell in Terminal** (also in search) work on this Mac's files. See [Administrator rights](files.md#administrator-rights).

## Viewer and editor

| Action | Keys |
|---|---|
| Viewer: find / wrap / hex / plist and JSON / follow (`tail -f`) / close | ⌘F / `w` / `h` / `p` / `f` / ⎋, F3, F10, `q`, ⌘W |
| Viewer: show only lines with / without text | `&` |
| Viewer: errors and warnings, errors only, all lines / line numbers | `e` / `l` |
| Services…: status / log / edit unit / restart / copy name / menu / in the other panel | ↩ / ⌘L / ⌘E / ⌘R / ⌘C / ⌃↩ or ⇧F10 / ⌘↩ |
| Containers…: log / restart / copy name / in the other panel | ↩ / ⌘R / ⌘C / ⌘↩ |
| Services in a panel: status / log / edit unit / restart / stop / copy name / mark / filter / menu / back | ↩ / ⌘L / F4 / ⌘R / F8 / ⌘C / Space / `/` / ⌃↩ or ⇧F10 / ⌫ |
| Containers in a panel: log / restart / copy name | ↩ / ⌘R / ⌘C |
| A server's overview: open a row / in the other panel / SSH there / its files as root / leave the server; from a server's `/` | ↩ / ⌘↩ / ⌃O / ⌃⌘R / ⌫; ⌫ |
| Server ▸ Overview | ⇧⌘O |
| A folder (or a list's row) in the other panel | ⌘↩ |
| A list in a panel: its keys / another list of its server / its log next door / a command on its server | ⇧/ (?) / ⇧; (:) / ⌘L / ⌘E |
| Ports (Forward Port…): forward / copy address / in the other panel; in a panel: forward / copy address / menu | ↩ / ⌘C / ⌘↩; ↩ / ⌘C / ⌃↩ |
| Viewer, files over 4 MB: go to (`50%`, `1.5G`, `end`) / start, end / search the whole file, next result | `g` / Home or ⌘↑, End or ⌘↓ / `/`, `n` |
| Editor: save / find and replace / close | ⌘S / ⌘F / ⎋, ⌘W |

The keys for large files work only in text mode, not while the file is followed (`f`) or filtered (`&`); in hex mode only `g` works. More in [Viewer and editor](viewer-editor.md).

Standard app keys such as ⌘Q, ⌘H and ⌘G (find next in the editor), and the cursor keys (↑↓, Home, End, PgUp, PgDn), aren't listed.

## Appearance

| Action | Keys |
|---|---|
| Theme: System, Midnight Commander, Far Manager, Solarized Dark / Light, Dracula, Nord, Gruvbox Dark, Monokai, One Dark, Tokyo Night, Catppuccin Mocha, GitHub Light | **View ▸ Theme…** |
