[Kermo documentation](../README.md#documentation)

# Getting started

Five minutes from a fresh install to copying files, connecting to a server and finding any command. Install first: [Install Kermo](install.md).

## Move around

1. Open Kermo. You see two panels. **Tab** switches between them, ↑↓ move the cursor, **↩** opens a folder or a file, **⌫** goes up.
2. Hold ⌘ for a moment. The bar at the bottom shows the shortcuts that use ⌘ alone (hold ⇧⌘ or ⌃⌘ to see those layers). Click a slot to run it.
3. Press **⇧⌘P** and type a few letters. Search finds commands, folders and files, and shows each command's shortcut. **F1** lists all shortcuts.
4. Press **⌘P** to jump to a bookmarked or frequent folder, and **⌘D** to bookmark the current one. **⌃⌘S** shows the Places sidebar.

> [!NOTE]
> Function keys on a Mac control media by default. Use ⌥ plus the digit instead: ⌥5 is F5, ⌥0 is F10.

## Work with files

1. Press **Space** on a file to mark it. Mark more, or mark nothing to use the file under the cursor.
2. Press **F5** to copy to the other panel, **F6** to move. Long copies run in a queue with progress, speed and a pause button.
3. **F7** makes a folder, **F8** moves to the Trash, **⌘Z** undoes it. **F3** views a file and **F4** edits it.

More in [Files and folders](files.md) and [Search, compare and synchronize](search-compare.md).

## Connect to a server

1. Press **⌃⌘K**, type `user@host:/path` (or pick a host from your `~/.ssh/config`) and press ↩. The panel now shows the server, and F5, F6, F3 and F4 work on it as on this Mac. F8 deletes there for good, after asking: a server has no Trash.
2. Press **⌘K** instead for a shell on the server.
3. To keep the server in the sidebar, choose **Server ▸ New Server…**. Mark servers where a slip is costly as production: [Servers and SSH](servers.md).

## Use a terminal

Press **⌃O** to swap the panels for a terminal. The panel follows `cd`. Press ⌃O again to come back. **⌘\\** splits the terminal, so a log can run beside your commands. More in [Terminal and SSH sessions](terminal.md).

## Next

- Every shortcut: [Keyboard shortcuts](shortcuts.md).
- Edit config files on a server safely: [Server files as root](root-panel.md), [Checks on save](config-checks.md).
- Change what Kermo does: [Configuration](configuration.md).
