[Kermo documentation](../README.md#documentation)

# Files and folders

Mark, copy, move, delete, rename, link, pack and inspect files on this Mac from a panel; files on a server are in [Files on a server](server-files.md).

## Mark files

Operations act on the marked items, or on the cursor item when nothing is marked. Marked names are bold in the theme's mark color, and the status line counts them with their size (a folder counts once its size is known). Leaving the folder clears the marks. So does finishing F5, F6, F8, ⇧F8, Multi-Rename, Compress, Put Back and the Admin operations.

- Space, ⇧↓ and ⇧↑ toggle the mark and move the cursor down, down and up. ⌘-click toggles one item, ⇧-click marks from the cursor to the click.
- ⌘A marks all, ⇧⌘A unmarks all, `*` inverts. Marking covers only what the panel shows: hidden files (unless ⇧⌘. is on) and names the quick filter hides are never marked, and operations skip them.
- `+` (**Mark by Mask…**) and `-` (**Unmark by Mask…**) take globs separated by `;` (`*.log; *.txt`) or `re:` and a regular expression. Case is ignored. A mask never marks folders.

## Copy and move

Press F5 (⌥5) for **Copy To…** and F6 (⌥6) for **Move To…**. The dialog proposes the other panel's folder (with three or four panels, the one you used before this). Edit the path: `~` works, and a relative path starts in the active folder.

- A path ending in `/`, or several items, means "into this folder", made if missing. One item and a path that isn't a folder means "under this name". F6 to the same name in another case (`Foo` → `foo`) renames it, as ⇧F6 does.
- ⌘C copies the marked files, ⌘V pastes them (files copied in Finder too) and ⌥⌘V (**Move Here**) moves them. Pasting into their own folder duplicates them as `name 2`.
- With a server on either side, see [Files on a server](server-files.md).

### The operations queue

Every copy, move, Trash and delete gets a row above the key bar: files done of total, bytes, speed, time left and the current name.

- A copy on this Mac's own disk starts at once and counts the total alongside: until it's counted, the row reads `1234 · 56 MB · counting…` and the bar moves without a fraction. From a stick, a share or a disk image it counts first ("Scanning…"), as two walks would make a hard disk seek.

- **Pause** (copies and moves) and **Cancel** sit on the row. Cancel stops at once: finished items stay, a half-written file is removed.
- Jobs on this Mac run one at a time and wait as **Queued**. **Start Now** (▶▶) runs one next to the others.
- A move inside one volume is a rename: instant. To another volume it copies, then removes each original.
- A copy inside one APFS volume is cloned where possible, and Pause then lands between files.
- Copies keep permissions, extended attributes, ACLs and dates, and copy a symbolic link as a link. Each file is written under a hidden name and renamed when whole, so a pulled drive never leaves a cut-off file under the real name. A hidden `.dfm-partial-…` file can stay behind; the next copy into that folder removes it once it is a day old.

### When a name is taken

A dialog asks. For files it shows size and date of both (**← newer** marks the new file when it is the newer one).

- Files: **Overwrite**, **Skip**, **Keep Both** (the new one becomes `name 2.ext`), **Overwrite if Newer**, **Cancel**. **Apply to all remaining conflicts** answers the rest the same way.
- Folders: **Merge** (keeps existing files, asks about each clash inside), **Skip**, **Keep Both**, **Cancel**.
- A file onto a folder: **Skip**, **Keep Both**, **Replace Folder** (the folder goes to the Trash), **Cancel**. Asked every time.
- An error asks **Skip**, **Retry** or **Abort**; **Skip all further errors** stops the questions, and a list of what was skipped follows. On "Permission denied" see [Administrator rights](#administrator-rights).

## Trash and delete

- F8 (⌥8, ⌘⌫, ⌦) **Move to Trash** asks nothing. ⌫ alone goes up a folder.
- In the Trash folder the same keys, and **File ▸ Put Back**, return items to where Kermo took them from. Missing folders are made and nothing is overwritten. Items Kermo didn't trash stay: use Finder.
- ⇧F8 (⌥⇧8, ⌥⌘⌫, ⇧⌦) **Delete Permanently…** asks, then deletes without the Trash.

> [!WARNING]
> **Delete Permanently…** and **Overwrite** can't be undone: the old file is gone.

## Undo and redo

**Edit ▸ Undo** (⌘Z) and **Redo** (⇧⌘Z) step through the last 100 file actions in the window, whichever panel they happened in.

- **Covered:** move, **Move to Trash**, **Put Back**, copy (the copies go to the Trash), **Rename…**, **Multi-Rename…** (one step), **New Folder…**, **New File…** and links (the new item goes to the Trash).
- **Not covered:** **Delete Permanently…**, Admin operations, permissions and owner, tags, extract and compress, split and combine, and everything on a server.
- Items that merged into or overwrote something aren't undone. Undo never overwrites: if the old name is taken again, it stops with an error.

## Preview

- ⌃Q (**Quick View Panel**) turns the other panel into a preview of the cursor's file, and ⌘Y opens Quick Look on the marked files, or the cursor's.
- Quick Look shows text it knows by its extension (`.txt`, `.log`, `.json`, scripts …), but a config without one it knows (`.conf`, `.env`, `.bak`, `syslog.1`, `server.key`, or no extension at all) only as an icon. Kermo looks at such a file's start and, when it's text, ⌃Q shows it itself: read-only, with F3's colors (syntax, error and warning lines, terminal colors) and line numbers if they're on in the viewer (`l`). Over 256 KB it shows the first 256 KB and says so; F3 views it all. ⌘Y shows it through a `.txt` copy with the file's own name in the title: a clone where the volume allows, else its first 4 MB. The copies are read-only, for you alone, and go when Quick Look shows something else or closes, and when you quit; Quick Look's **Open with** opens such a copy, so edit with F4.
- Binary files, and everything Quick Look shows itself (images, PDF, video …), look as before.

## Context menu

Right-click an item for its menu: Open, Open With, Quick Look, View, Edit, Get Info, Reveal in Finder, Open in Terminal, Copy Path and Copy Name, then New File…, Rename…, Copy Here As…, Copy To…, Move To… and Move to Trash. Clicking an item outside the marked ones acts on it alone.

Right-click empty space or `..` for the folder's menu: New File…, New Folder…, Paste; Open in Terminal; Copy Path, Reveal in Finder and Get Info of the folder (not inside an archive; on a server, Copy Path only); Show Hidden Files, **Sort By** (Name, Size, Modified, Reverse) and Calculate Folder Sizes; Git Changes in a repository.

From the keyboard, ⇧F10 or a PC keyboard's Menu key opens the cursor item's menu next to its row, acting on the marked items as the F-keys do; on `..` it opens the folder's menu. Sort by Name, Size or Modified and Reverse Sort Order are also commands in ⇧⌘P.

## Rename, create and link

- ⇧F6 (⌥⇧6) **Rename…** renames the cursor item and preselects the name without its extension. A case-only change works; `/` is refused.
- ⇧⌘M **Multi-Rename…** renames the marked items with a live preview. **Name** and **Extension** take `[N]` name, `[N2-5]` characters 2 to 5, `[E]` extension, `[C]` counter, `[P]` parent folder, `[YMD]` and `[hms]` modification date and time. Then come **Find** and **Replace** (tick **Regex ($1 in Replace)**), **Case** and the counter's start, step and digits.
- **Rename N** stays off while a new name is invalid or taken (red). The names are applied together: swaps work, and one failure puts everything back.
- F7 (⌥7, ⇧⌘N) **New Folder…** makes nested folders from `a/b/c`. ⇧F4 (⌥⇧4) **New File…** creates an empty file and opens it in the editor.
- ⇧F5 (⌥⇧5) **Copy Here As…** copies the cursor item next to itself under a new name: `nginx.conf` proposes `nginx.conf.bak` with `.bak` selected, so ↩ makes the backup. With several marked, it asks for a suffix (`.bak`) and adds it to each name. A folder is copied whole. A name that's taken is an error, nothing is copied and nothing is replaced. Undo moves a copy to the Trash, one copy per ⌘Z.
- ⌥⌘L **Create Symbolic Link…** and **Create Hard Link…** (File menu, no key) link the cursor item, proposing the other panel's folder. A symbolic link stores the absolute path; a hard link needs a file on the same volume. ⌘J **Go to Link Target** opens the target's folder with the target selected.

## Drag and drop

Drag items to the other panel, onto a folder row or onto a sidebar place; files can also come in from Finder or go out to it or another app. Dragging a marked item takes all marks. A drop moves within one volume (or within one server) and copies to another volume or to another server; hold ⌥ to force a copy, ⌘ to force a move. Dropping into the folder the items are already in does nothing. On the ⌃O terminal a drop types paths instead ([Terminal](terminal.md)).

## Archives

↩ on an archive opens it as a read-only folder: zip, jar, war, ear, apk, ipa, tar, tgz, tbz, tbz2, txz, tzst, 7z, rar, iso, cpio, xar, and `.tar.gz`, `.tar.bz2`, `.tar.xz`, `.tar.zst`, `.tar.lz4`. Kermo lists every entry first, so a big archive takes a moment. Zip names saved in a Windows code page (Cyrillic CP866 or CP1251) are detected and shown correctly.

- Inside, ⌫ goes up, ↩ on a file extracts it to a temporary folder and opens it, and F3 views it. What ↩ opens is quarantined, so Gatekeeper checks it first: with the archive's own quarantine if it has one, as Archive Utility does, else as a download from Kermo. Delete, rename, paste and drops are refused.
- **Extract…** (⌥F9, and F5 inside an archive) unpacks the marked entries (or the cursor's) into the folder you confirm, by default the other panel's. On an archive file in a normal folder F5 copies the file; ⌥F9 extracts all of it.
- Names that already exist ask **Keep Existing** (folders merge), **Overwrite** or **Cancel**. Then the archive unpacks into a hidden `.kermo-extract-…` folder there and moves out once it's all done: if it fails or you stop it, nothing of it lands and your files stay as they were.
- What a quarantined archive (a download) unpacks is quarantined too, as Archive Utility does; a clean archive's isn't.
- All of a tar (`.tar.gz`, `.tar.xz` and the like) isn't read once first just for its names: into an empty or new folder it unpacks straight in. Into a folder with things in it, it unpacks into a hidden `.kermo-extract-…` folder there; when tar is done, names that exist ask the question, and **Cancel** removes what was unpacked. If tar fails or you stop it, nothing of it lands. Where the archive has a file and the folder a folder of that name, or (with Keep Existing) the archive a folder and the folder a file or link, yours stays, and you're told.
- ↩ or F3 on one file inside a tar stops reading the archive at that file.
- ⌥F5 **Compress…** packs the marked items into a `.zip` it proposes in the other panel's folder, named after the item (or the current folder, for several). Edit the path to change it. The extension picks the format: `.zip`, `.tar.gz`, `.tgz`, `.tar.bz2`, `.tar.xz`, `.7z`. A name that exists is refused, and no `._` files are added.
- Extract, Compress, Split and Combine run in an output window, not in the queue: no progress row, no undo.

## Split and combine

**File ▸ Split File…** cuts the cursor file into `name.000`, `name.001` … next to it. The size is bytes or with K, M or G (`650M`; it starts at `1G`, then keeps your last). Split refuses while any part of that name is there already (not only `.000`). **Combine Parts…** with the cursor on any part joins the set (starting at `.000` or `.001`, no gaps) into the name you confirm and never overwrites. Every part but the last must be the size of the first, and the last no bigger: otherwise they're parts of two splits, and Combine names the one that doesn't fit and joins nothing.

## Sizes, hidden files and sort

- Space on a folder marks it and counts its size. ⌥Space (**Calculate Folder Sizes**) counts every folder, and ⎋ (or **Cancel** in the status line) stops. It adds up file bytes, not disk blocks, skips volumes mounted inside (`/` counts its data once, through `/Users` and the other firmlinks), and is forgotten when you leave.
- ⇧⌘. (**Show Hidden Files**) shows names starting with `.` and files with the hidden flag, in every panel, and is remembered.
- Click **Name**, **Size** or **Modified** to sort, again to reverse. Folders stay first. Each folder remembers its sort. A folder of more than 5,000 items sorts in the background: the list stays as it was until it's done (`Sorting…` in the status line after a moment), and the cursor stays on its item.

## Tags, Info and permissions

- ⌃1…⌃7 toggle Finder's colors (red, orange, yellow, green, blue, purple, gray); the first marked item decides whether all gain or lose it. ⌃0 removes all tags. ⌃T **Tags…** sets them by name, comma-separated.
- ⌘I **Get Info** shows the cursor item: path, kind, size, owner, mode, flags, dates, inode, xattrs, quarantine, ACL and a folder's contents. Buttons: **chmod**, **chown**, **Hidden**, **Locked (uchg)**, **Remove Quarantine**, **Code Signature**, **MD5**, **SHA-1**, **SHA-256**. The first checksum you press reads the file once for all three; the other two then show at once. A refused change offers **Try as Administrator**.
- ⌥⌘A **Permissions & Owner…** takes `755`, `me:staff` or `644 me:staff` for the marked items. A part left as shown isn't changed. A numeric owner needs its colon (`1000:`); without it Kermo asks before taking the number as a mode. It doesn't enter folders and changes a symbolic link itself.
- View ▸ **Show Permissions & Owner** adds Permissions, Owner and Group columns to every panel (they drop out when a panel is too narrow).
- ⇧⌘R **Reveal in Finder**, ⇧⌘C **Copy Path** and ⌥⌘C **Copy Name** (one per line) act on the marked items.

## Administrator rights

**Admin ▸ Copy as Administrator…**, **Move as Administrator…**, **New Folder as Administrator…** and **Delete as Administrator…** ask for your password in the standard macOS dialog. They skip the queue: no progress, no undo. Copy replaces existing files, Move never overwrites, and Delete runs `rm -rf` after a confirmation.
