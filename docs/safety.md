[Kermo documentation](../README.md#documentation)

# Safety on servers

What Kermo does to keep a server safe from a slip, and what it keeps on your Mac. Kermo has no telemetry. Its network traffic is the ssh connections you open, the `smb://`, `nfs://` or `afp://` shares you mount (macOS does that), and [one request a day to GitHub](install.md#updates) for the latest release, which **Kermo ▸ Check for Updates Automatically** turns off.

## Production servers

[Mark a server as production](servers.md#mark-a-server-as-production) and Kermo treats everything you do there with more care:

- **Purple, not red.** A production server carries a purple PROD chip wherever it shows: the path bar, panel and terminal tabs, server pickers, tunnels, Run on Servers, Activity and the title bars of the viewer and the editor (menus say PROD in purple). Purple also marks its icon in the sidebar, the line under an active panel's path bar there (a root panel's too), the line under its tab in front, and its name after F5 and F6 in the key bar when they copy or move there. Red is kept for what failed; orange is a [root panel](root-panel.md).
- **Changes ask first**, in a question with the server's purple PROD strip ([how a question asks](#how-a-question-asks)). That covers saving a file (the first save in an editor; later saves there don't ask again), reverting a version, copying, moving, deleting, renaming, changing permissions, extracting, synchronizing and reloading a service. A new folder is created without a question, but it is logged; the questions for a name (new file, rename, permissions) show the strip over the field.
- **Dangerous commands ask.** A command from ⌘E, F2 or the user menu asks (“Run this command on web-01?”, the command under it as it will run) when any command in the line (after `;`, `&&`, `||`, `|`, inside `$(…)`) is `rm`, `mv`, `chmod`, `chown`, `dd`, `truncate`, `shred`, `unlink`, `find` with `-delete` or `-exec`, `rsync --delete`, `git clean`, `git reset --hard` or `systemctl stop` / `restart` / `disable` / `mask` / `kill`, also behind `sudo`, `env`, `xargs` and the like, or when it writes over a file with `>`. Any other command runs without a question, and is logged. [Run on Servers…](commands.md#run-on-several-servers) asks once for all the production servers it runs on, with ↩ on **Cancel**.
- **Safe defaults.** On every production question ↩ answers **Cancel**; the action takes **⌘↩**. A copy that lands where a save would be [checked first](config-checks.md#copies-arent-checked) (`sudoers`, `sshd_config` …) says so in its question.
- **A log of what you did.** See below.
- **Opening a tunnel doesn't ask:** a tunnel changes nothing on the server by itself.

## How a question asks

Every question before a change reads the same way, top to bottom:

1. **The title** names the action and where: “Delete 2 items on web-01 permanently?”, “Restart nginx on web-01?”.
2. **A strip** with the place's chip: purple PROD for a production server, orange ROOT for a [root panel](root-panel.md) or an administrator's command on this Mac. Nowhere else.
3. **What exactly**: up to five items with their size, as the panel shows it (a folder's once counted), then “and 12 more”.
4. **The command**, in a mono box, exactly as it will run, when a command runs: a restart, a reload, ⌘E and F2 on a production server, Run on Servers, the administrator's delete. A line over it says how it runs: “Runs on web-01 as root, through the server's sudo.”
5. **What follows**, in a sentence: “A server has no Trash. This can't be undone.”
6. **Safe keys.** On a production server, and for what can't be undone (deleting for good, overwriting, deleting a saved server or tunnel), ↩ answers **Cancel** and the action takes **⌘↩**; a line of keys under the question says so. Elsewhere ↩ is the action, as in any dialog. ⎋ is always Cancel.
7. **The button** says what it does — Delete, Restart, Run, Copy — and is red only for what can't be undone.

Questions about a window are sheets on that window. Only quitting, which is about the whole app, asks in a window of its own.

## Production log

On a production server, what Kermo does there goes into `~/.config/dfilemanager/audit.jsonl`, one JSON line each:

- saves and reverts (a failed check shows as its exit status and what became of the file; a passed or skipped check leaves nothing in the line);
- commands (⌘E, F2, Run on Servers…);
- copies, moves and deletes (F5, F6, F8, Synchronize);
- renames, permissions, new folders, extracting and reloads;
- a key added with Copy SSH Key to Server….

Each line has the time, the server, the paths, the command and its exit status. There is no exit status for a command handed to Terminal, and a reload stopped with ⎋ says it may have run. `"root": true` marks what ran as root from a root panel: saves, copies, moves, deletes, renames, permissions, new folders and reloads. Commands and extracting always run as the user and carry no `root`. If a line can't be written, the status line says so once.

Read the log with `grep` or `jq`, or choose **Admin ▸ Show Production Log** (or search for it).

> [!WARNING]
> A command line may hold a secret (`mysql -pXXX`, a token in a `curl` header). The file is owner-only, but it's a plain file on this Mac. Turn the log off with `defaults write com.dmn.dfilemanager auditLog -bool false`.

## What stays on this Mac

| Where | What | Protection |
|---|---|---|
| `~/.config/dfilemanager/` | Settings, saved servers (no passwords), the production log | Folder `0700`, files `0600` |
| `~/.config/dfilemanager/history.noindex/` | Versions of the server files you saved, `.env` and keys included | Owner-only, out of Spotlight and Time Machine; [turn it off](server-files.md#file-history) |
| Login Keychain | "Kermo: host" (ssh password), "Kermo sudo: host" (sudo password) | Keychain; each only if you chose to save it |
| Memory | The sudo password for 5 minutes after its last use | Forgotten at screen lock, sleep and **Disconnect** |

Server passwords are never put on a command line or in a file. A [locked server](servers.md#lock-a-server) asks for Touch ID or the Mac password before you use it, by its saved address, an `~/.ssh/config` alias of it or any other way of writing it ssh takes to the same user, host and port.

A file from a server or an archive that **↩** opens in another app is quarantined first, as a browser's download is, so Gatekeeper asks before a script or app runs ([server files](server-files.md#open-and-edit), [archives](files.md#archives)).

## What listens on this Mac

Only [SSH tunnels](tunnels.md) listen, temporary ones too, and only on `127.0.0.1` and `::1`. Any program or user on this Mac can connect to such a port, so keep a tunnel to a production database off when you don't need it.
