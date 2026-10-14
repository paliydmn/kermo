[Kermo documentation](../README.md#documentation)

# Files on a server

What works in an SFTP panel, and how it differs from a local one. To open one, see [Servers and SSH](servers.md). F7, ⇧F6 and F8 create, rename and delete on the server.

## Copy and move

F5 / F6, ⌘C / ⌘V and drag and drop copy and move files in every direction: server to this Mac, this Mac to a server, server to server, and within one server.

- They run in the operations queue like local copies: progress with speed and ETA, pause, cancel, the overwrite / skip / keep both dialog, and **Retry**, which continues a large file where a dropped connection left it.
- Within one server a move is a rename. A copy happens on the server when its `sftp-server` supports it (OpenSSH 9.0 and later); otherwise the data goes through this Mac.
- Operations on different servers and on this Mac run side by side. Ones on the same server wait their turn (**▶︎▶︎ Start Now** runs a queued one at once).

## Open and edit

- **F3** views a file, **F4** edits it. The editor uploads the file after every ⌘S, and closing with changes asks first.
- **↩** opens a file in its app (so does Quick Look's **Open with**). Every save there goes up to the server the same way. If someone changed the file there meanwhile, you're asked first (**Compare** shows the differences); on a production server you're asked once as well.
- An app that autosaves (TextEdit) sends its autosaves too, so on a production server F4 is the safer choice. Quitting names what didn't reach the server; its copy is kept.
- Saving a server config checks it first: see [Checks on save](config-checks.md).

## Preview, sizes and compare

- **⌃Q** and **⌘Y** preview the file under the cursor. It is fetched once the cursor rests on it (up to 64 MB). Copies stay until you quit, 256 MB of them at most. ⌘Y shows the cursor's file, not the marked ones.
- **⌥Space** (and Space on a folder) counts folder sizes with the server's own `du` (`du -slbx`, as GNU, uutils and busybox know it), one command for all of them: file bytes, each hard link counted, volumes mounted inside skipped. A folder `du` couldn't read all of shows as `≥ 1.2 GB`. A server whose `du` has no `-b` (BSD) is walked over SFTP, one folder after another, as before. ⎋ stops it, and `du` on the server too. On a root panel `du` runs as root.
- The status line says what's free on the server's disk there, as `df` calls it Available: `🌐 sftp · web1 · 1,234 items · 120 GB free`. A server that doesn't tell (no `statvfs@openssh.com`) shows no figure.
- **⇧⌘D** compares a server's file with one on this Mac or on another server. The file is fetched as ⌃Q fetches it and shown as `host:/path` in the diff.
- Compare and Synchronize Folders, Find Files and archive listing work on a server too. **↩** on an archive there shows its contents (read on the server with `tar -tv` or `unzip -l`).
- Git status, branch and ↑↓ show in an SFTP panel when the server has git 2.26 or newer ([Git](git.md)).

## File history

Every save of a server file (F4's ⌘S, a save in another app, a revert) first keeps the version it replaces on this Mac, in `~/.config/dfilemanager/history.noindex/<server>/<path there>/<name>@<date>`. It keeps 20 versions a file and 200 MB in all, the oldest going first. A file over 5 MB gets none, and the status line says so.

Choose **Server File History…** from the File menu, or find it with search (⇧⌘P), on a server file or in its editor. It has no shortcut of its own. It lists the versions:

- ↩ or F3 views one.
- ⇧⌘D compares it with the file on the server now, ⌘D with the version before it.
- ⌘R reverts the server's file to it. A production server asks first, and so does a change made on the server since the list opened.

The server's sidebar menu has **Show File History**, which opens that folder in the panel. F8 there moves a version to the Trash, ⇧F8 deletes it for good.

> [!WARNING]
> Versions hold whatever the files did, `.env` files and keys included. The folder is owner-only and kept out of Spotlight and Time Machine. Turn history off with `defaults write com.dmn.dfilemanager serverHistory -bool false`.
