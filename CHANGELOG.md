# Changelog

All notable changes to Kermo are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

<!--
Every user-visible change adds a line under [Unreleased]: Added, Changed, Fixed, Removed or Security.

Release:
1. Set CFBundleShortVersionString in build.sh to the new version.
2. Rename [Unreleased] to [X.Y] - YYYY-MM-DD, start a new empty [Unreleased], and add the link at the bottom.
3. Commit, `git tag vX.Y`, `./package.sh`, then attach dist/*.dmg, *.pkg and their .sha256 to the GitHub release with that section as its notes.
-->

## [Unreleased]

### Added

- **Server file history:** every save of a server file (F4's ⌘S, a save in another app) keeps the version it replaces on this Mac, in `~/.config/dfilemanager/history.noindex/<server>/<path there>/<name>@<date>`: 20 versions a file and 200 MB in all, the oldest going first. "Overwrite" after someone else's change keeps their version. A file over 5 MB gets none, and the status line says so; so it does when a version can't be written, and the save goes on. Saving a small file you opened with F4 costs no extra wait: the check before writing already reads it. The folder is owner-only and out of Spotlight and Time Machine; `defaults write com.dmn.dfilemanager serverHistory -bool false` turns it off.
- **Compare Files (⌘⇧D) with a server:** a server's file against this Mac's or another server's, by the same rules as before: two marked files; the cursor's and the same name in the other panel (now looked for on its server too); or the two cursors. A server's file is fetched as the ⌃Q preview fetches it (the copy already here if it's unchanged, up to 64 MB), and `diff -u` names it "host:/path" instead of its temporary copy; a `diffCommand` tool gets the copies.
- **Server File History…** (⌘⇧P or the File menu, on a server panel's file or in a server file's editor): the versions its saves kept, newest first. ↩ or F3 views one; ⌘⇧D diffs it with the file on the server now; ⌘R reverts the server's file to it through the same save as ⌘S, so a production server asks first, a change made there since the list opened is asked about, and the version it replaces is kept too. A locked server asks for Touch ID first.
- Versions in the history keep their file's syntax highlighting in the viewer and editor (the date at the end of their name hid the extension).
- **Sidebar:** a server's menu has **Show File History**, which opens its folder of versions in the panel (view, compare or delete them there as any files). Deleting a saved server offers to delete its file history too, unless another saved server at that address still uses it.

### Changed

- **Speed:** undo and redo of a move, undo of a copy and batch rename do their disk work in the background: thousands of items on a network share no longer freeze the window. So do rename, Go to Link Target, diff, compress, `fm` and Info's chmod, chown and flags: a share that stopped answering doesn't hang the app.
- **Speed:** "Scanning…" before a copy or move from a server reads the tree a level at a time, up to 64 folders together, instead of one folder after another: thousands of folders on a distant server take seconds, not minutes. A folder skipped in a conflict isn't read a second time.
- **Speed:** deleting on a server (F8, and Synchronize's deletions) takes all the items together: the files 64 at a time, the folders a level at a time, up to 64 listed together with their files deleted together, then the empty folders, deepest first. A file that can't be deleted is still asked about on its own (Retry, Skip, Abort), and the folders above it stay without an error each.
- **Speed:** comparing folders with a server (Compare, Synchronize Folders) reads both sides at once, a level at a time with up to 64 folders together, instead of one folder after another, one side after the other.
- **Speed:** synchronizing with a server checks every item against what Compare saw in one go, up to 64 requests together, and reuses what it saw for the scan and the copy, instead of several requests per item before the first byte.
- **Speed:** reading a file from a server (a download, F3, F4, the check before saving with ⌘S) asks for the end of the file together with its last piece, and doesn't wait for the server to confirm it was closed: two waits less per file. Reading a server folder (opening it, a scan, Compare, a delete) doesn't wait for its close either.
- **Speed:** a big server folder opens several times faster: up to 8 requests for its names are in flight together instead of one at a time (10 000 names: 13 waits instead of 100). Scans, Compare and deletes keep up to 4 a folder in flight, so a level of small folders is read in one wave.
- **Speed:** downloading a server folder takes each item's kind, size, date and mode from the folder's listing instead of asking the server again: with the two changes above, a small file costs 2 waits instead of 5.
- **Speed:** a file copied to a server gets its close, mode and date sent right behind its data instead of after the server confirmed the data: one wait less per file. A file whose owner can't write it still waits, so one that fails half-way stays writable for Retry.
- **Speed:** copying a folder to a server doesn't ask whether each name is taken in the folder it has just made there (nothing can be yet; a name that differs only in case from one copied before is still asked about): one wait less per file. With the change above, a small file uploads in 4 waits instead of 6.
- **Speed:** saving a server file you edit (F4, ⌘S) sends its mode along with the close, right behind the data, and checks that the server's copy hasn't changed with a single read: 8 waits instead of 12.
- **Speed:** a server panel keeps one connection to its server while it shows it, instead of opening a new one for every folder: going into a folder skips the ssh start and handshake (about 0.1 s on a local network, several round trips to a distant server). After sleep or a network change the next folder connects afresh. A locked server's connection therefore stays open while a panel shows it; the lock itself still lasts 5 minutes.

### Fixed

- **Panels:** a folder reloading by itself (or after a save to its server) no longer wipes the status line's "… ⎋ cancels" of an operation still running there, or a message shown a moment before.
- **Panels:** symlinks to folders no longer turn into files (shown with their own size and sorted with the files) after a folder reloads by itself.
- **Stop and ⎋:** ⎋ stops counting folder sizes on this Mac, as on a server, and so does leaving the folder; closing Info stops its folder count; Stop during "Scanning…" before a copy stops at once instead of after the whole tree. Search by content and compare by content stop within a big file instead of after it; closing Info stops its checksums.
- **Info:** a checksum of a file that fails to read part-way shows the read error instead of a hash of the part that was read.

## [1.0] - 2026-10-10

The first public release. Kermo was previously called DFileManager; settings and permissions carry over.

### Added

- **Panels:** 2–4 panels with tabs, a Places sidebar (Favorites, Frequent, Locations, Servers, Tags), a directory tree, a quick filter with presets, and Quick View. Large folders load in the background without freezing the window.
- **Keyboard:** MC-style marking, a key bar that shows shortcuts for held modifiers, toolbar search for commands, folders and files (⌘⇧P), a cheat sheet (F1), and a keymap editor. Shortcuts work with any keyboard layout.
- **File operations:** a background queue with pause, speed and ETA, a conflict dialog, APFS clones, undo/redo, Put Back from the Trash, batch rename, folder sizes, links, split/combine, and Finder tags.
- **Viewer and editor:** a viewer for multi-gigabyte files (mmap) with hex, plist/JSON, follow (`tail -f`) and line filter modes; an editor with syntax highlighting, line numbers and Save as Administrator.
- **Search and compare:** search by name, content or Spotlight with results as a panel; compare and synchronize folders (two-way or mirror), including with a server; diff two files.
- **Archives:** browse zip/tar/7z as folders, extract, and create archives.
- **Servers:** SFTP panels and SSH sessions through the system OpenSSH (`~/.ssh/config`, agent, ProxyJump). Copy and move between this Mac and servers, and from server to server, with resume after a dropped connection. Saved servers with Keychain passwords, Touch ID locks and a production tag that asks before changes. SMB, NFS and AFP mounts.
- **Terminal:** a built-in terminal (⌃O) whose panel follows `cd`, with SSH tabs; ⌘E commands and the F2 user menu run in it.
- **Git:** a status column, branch and ahead/behind in the status bar, changes-only views, diff against HEAD, log, blame, stage and unstage; the status column and branch work on servers too.
- **Admin:** Info window with permissions, owner, xattr, ACL, hashes and signature; chmod, chown, copy, move and delete as administrator.
- **Themes:** System, Midnight Commander, Far Manager and 10 more.
- **`fm` command** to open folders from the shell.

[Unreleased]: https://github.com/paliydmn/kermo/compare/v1.0...HEAD
[1.0]: https://github.com/paliydmn/kermo/releases/tag/v1.0
