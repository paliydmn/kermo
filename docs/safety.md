[Kermo documentation](../README.md#documentation)

# Safety on servers

What Kermo does to keep a server safe from a slip, and what it keeps on your Mac. Kermo has no telemetry and doesn't check for updates: its network traffic is the ssh connections you open, and the `smb://`, `nfs://` or `afp://` shares you mount (macOS does that).

## Production servers

[Mark a server as production](servers.md#mark-a-server-as-production) and Kermo treats everything you do there with more care:

- **Purple, not red.** The server's icon and name in the sidebar, its tunnels and a root panel's header are purple, and titles say 🟣 PROD. Red is kept for what failed; orange is a [root panel](root-panel.md).
- **Changes ask first**, and the question starts with "“host” is a production server". That covers saving a file (the first save in an editor; later saves there don't ask again), reverting a version, copying, moving, deleting, renaming, changing permissions, extracting, synchronizing and reloading a service. A new folder is created without a question, but it is logged.
- **Dangerous commands ask.** A command from ⌘E, F2 or the user menu asks (“Run “…” on host (production)?”) only when it starts with `rm`, `mv`, `chmod`, `chown`, `dd` or `systemctl stop` / `restart`, also behind `sudo`, `env` and the like. Any other command runs without a question, and is logged. [Run on Servers…](commands.md#run-on-several-servers) asks once for all the production servers it runs on, with ↩ on **Cancel**.
- **Safe defaults.** On the reload question ↩ answers **Cancel**. A copy that lands where a save would be [checked first](config-checks.md#copies-arent-checked) (`sudoers`, `sshd_config` …) says so in its question.
- **A log of what you did.** See below.
- **Opening a tunnel doesn't ask:** a tunnel changes nothing on the server by itself.

## Production log

On a production server, what Kermo does there goes into `~/.config/dfilemanager/audit.jsonl`, one JSON line each:

- saves and reverts (a failed check shows as its exit status and what became of the file; a passed or skipped check leaves nothing in the line);
- commands (⌘E, F2, Run on Servers…);
- copies, moves and deletes (F5, F6, F8, Synchronize);
- renames, permissions, new folders, extracting and reloads.

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

Server passwords are never put on a command line or in a file. A [locked server](servers.md#lock-a-server) asks for Touch ID or the Mac password before you use it.

## What listens on this Mac

Only [SSH tunnels](tunnels.md) listen, temporary ones too, and only on `127.0.0.1` and `::1`. Any program or user on this Mac can connect to such a port, so keep a tunnel to a production database off when you don't need it.
