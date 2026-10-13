# Command-line launcher

Choose **Kermo ▸ Install “fm” Command** to create a link in `/usr/local/bin`. After installation, `fm` opens the current directory, `fm ~/a ~/b` opens both directories in two panels, and `fm /etc/hosts` reveals the file in its directory. Kermo also appears in Finder's **Open With** menu for folders.

Command-line and F2 menu placeholders:

- `%f` / `%F`: name / full path under the cursor
- `%s` / `%S`: marked items, or the item under the cursor
- `%d`: current directory
- `%D`: directory in the other panel

All substituted values are automatically escaped for the shell.

On a local panel ⌘E ↩ and F2 entries type the command into the ⌃O terminal's shell, as MC's subshell does: your aliases and functions, colors, `sudo` and `git commit` prompts, Tab completion and ⌃R all work, and the command lands in the shell's history. ⇧↩ runs it in an output window instead (no TTY, any file name), ⌘↩ and `"terminal": true` in Terminal.app. On a server panel ↩ runs over ssh in an output window and ⌘↩ opens an SSH tab with the command.

An entry in `usermenu.json` with `"server": true` shows only on a server panel (and `false` only locally). The default menu has `systemctl status` / `restart`, failed services and `journalctl` for the unit under the cursor; an existing `usermenu.json` isn't changed — copy them in, for example:

```json
{ "title": "Restart service", "command": "sudo systemctl restart %f && systemctl status --no-pager %f", "terminal": true, "server": true }
```

On a server tagged production, `systemctl stop` / `restart` asks first.
