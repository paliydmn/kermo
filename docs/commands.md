[Kermo documentation](../README.md#documentation)

# Commands, user menu and `fm`

Run a shell command on the files in front of you, keep your own commands in a menu, and open Kermo from the shell.

## Command line

**⌘E** opens the command line for the active panel's folder. ↑↓ browse its history (kept per server and for this Mac).

| Panel | ↩ | ⇧↩ | ⌘↩ |
|---|---|---|---|
| This Mac | Types the command into the ⌃O terminal's shell | Runs it in an output window (no TTY, any file name) | Runs it in Terminal.app, or the app in `terminalBundleID` |
| A server | Runs it over ssh in an output window | The same | Opens an SSH tab with the command |

On this Mac, ↩ works as Midnight Commander's subshell does: your aliases and functions, colors, `sudo` and `git commit` prompts, Tab completion and ⌃R all work, and the command lands in the shell's history. On a root panel the command still runs as the user ([root panel](root-panel.md#what-runs-as-root)).

## Placeholders

In the command line and in the user menu:

| Placeholder | Is |
|---|---|
| `%f` / `%F` | Name / full path under the cursor |
| `%s` / `%S` | The marked items' names / full paths, or the item under the cursor |
| `%d` | The current folder |
| `%D` | The folder in the other panel |
| `%%` | A literal `%` (for example `find -printf '%%f'`) |

Every substituted value is escaped for the shell. A command with `%D` doesn't run when the other panel is on another machine (a local panel next to a server panel, or two different servers).

## User menu

**F2** (⌥2) opens your menu of commands for the files under the cursor. **Kermo ▸ Edit User Menu…** opens `usermenu.json`, writing fourteen examples on first use (ten for this Mac, four for servers):

```json
[
  { "title": "Restart service", "command": "sudo systemctl restart %f && systemctl status --no-pager %f", "terminal": true, "server": true }
]
```

| Key | Meaning |
|---|---|
| `title` | The menu entry. |
| `command` | The shell command, with placeholders. |
| `terminal` | `true` runs it in Terminal (or the app in `terminalBundleID`); on a server panel it opens an SSH tab with the command. |
| `server` | `true` shows the entry only on a server panel, `false` only on this Mac. Without it the entry shows in both, except that on a server panel it is left out when it calls a Mac-only tool (`xattr`, `open`, `pbcopy` …). |

The four server entries (service status, restart, failed services, and the log of the unit under the cursor) are in the file Kermo writes. If your `usermenu.json` is older and lacks them, Kermo adds them after your entries on a server panel, marked "built in". On a production server, `systemctl stop` and `restart` ask first.

## The `fm` command

Choose **Kermo ▸ Install “fm” Command** to create a link in `/usr/local/bin`. Then:

| Type | Result |
|---|---|
| `fm` | Opens the current directory |
| `fm ~/a ~/b` | Opens both directories in two panels |
| `fm /etc/hosts` | Reveals the file in its directory |

Kermo also appears in Finder's **Open With** menu for folders.
