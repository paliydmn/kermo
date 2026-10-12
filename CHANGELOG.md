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

### Changed

- **Speed:** undo and redo of a move, undo of a copy and batch rename do their disk work in the background: thousands of items on a network share no longer freeze the window. So do rename, Go to Link Target, diff, compress, `fm` and Info's chmod, chown and flags: a share that stopped answering doesn't hang the app.
- **Speed:** "Scanning…" before a copy or move from a server reads the tree a level at a time, up to 64 folders together, instead of one folder after another: thousands of folders on a distant server take seconds, not minutes. A folder skipped in a conflict isn't read a second time.

### Fixed

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
