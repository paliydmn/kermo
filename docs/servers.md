[Kermo documentation](../README.md#documentation)

# Servers and SSH

Connect to a server, save it, lock it and mark it as production. Kermo uses the system OpenSSH client, so keys, agents and `ProxyJump` from `~/.ssh/config` work exactly as in Terminal. Passwords are asked for in a macOS dialog.

## Connect

- **⌃⌘K** opens a server's files in the active panel (SFTP). **⌘K** opens a shell on a server in the terminal (SSH); inside the terminal, ⌘K clears it.
- Both open a picker. Type `user@host:/path` or `sftp://host:2222/path`, or choose a saved server (🔒 locked, 🟣 PROD production), a recent one or a host from `~/.ssh/config`. ⌃⌘K also takes `smb://`, `nfs://` and `afp://` addresses and mounts them.
- A panel keeps one connection to its server while it shows it, so opening a folder doesn't start ssh again. After sleep or a network change the next folder connects again.
- If an SSH tab's session ends, **Go ▸ Reconnect SSH Session** (or the tab's **Reconnect** button, ↩) starts it again. **Go ▸ Disconnect Server** ends the server's shared connection: its SSH sessions end, its file tabs go back, its tunnels turn off, and a remembered sudo password is forgotten. It asks first while an SSH session is running or a tunnel is listening.

## Save a server

A saved server gets a name, a sidebar row, a Touch ID lock if you want one, a production mark and tunnels.

1. Choose **Go ▸ New Server…** (also in search, in the Servers header's right-click menu, and as **＋ New Server…** in the picker).
2. Fill in the sheet and click **Save** (or **Save & Connect**).

To keep a server you already used, right-click its recent or `~/.ssh/config` row in the sidebar and choose **Save…**.

| Field | Left empty means | Notes |
|---|---|---|
| **Name** | the address | Shown in the sidebar. |
| **Host** | required | An address or a `~/.ssh/config` host. |
| **User** | ssh's default | |
| **Port** | 22 | 1–65535. |
| **Key file** | ssh's own choice (agent, `~/.ssh/config`) | **Choose…** opens `~/.ssh`. |
| **Password** | ask every time | Saved in the login Keychain as "Kermo: user@host" (with `:port` for a port other than 22), one per user, host and port. Never shown again; type to replace it. |
| **Start folder** | the login folder | Where SFTP opens. |
| **Lock with Touch ID or the Mac password** | not locked | See below. |

Saved servers live in `~/.config/dfilemanager/servers.json` (see [Configuration](configuration.md#saved-servers)). Passwords are never written there.

## Manage a server

Right-click a server row in the sidebar (or click **⋯** under the mouse):

- **Edit…** opens the sheet again. **Duplicate…** makes a copy named "name copy"; its tunnels are copied but turned off.
- **Delete…** removes the server and its saved passwords from the Keychain (unless another saved server has the same address). It offers to delete its [file history](server-files.md#file-history) too. Open sessions stay open and its tunnels turn off.
- **Pin** keeps the server at the top of the Servers list. **Remove from Recents** drops a recent address.
- **Open SSH Session**, **Open SFTP**, **Open SFTP in New Tab / in Other Panel**, **Open SFTP as Root** ([root panel](root-panel.md)), **Forward Port…** and **Tunnels** ([tunnels](tunnels.md); both on any server row), **Copy SSH Command**, **Copy SSH Key to Server…** ([below](#copy-your-ssh-key-to-a-server)) and **Close All Sessions** (the connection closes too, unless a tunnel is on; **Disconnect** also turns tunnels off).
- **Mark as Production** / **Unmark Production** and **Save as Production…**: see below.

**Go ▸ Edit SSH Config** opens `~/.ssh/config` in the editor and creates it with an example if it doesn't exist.

To run one command on several servers at once, choose **Run on Servers…** in the Servers header's right-click menu: see [Run on several servers](commands.md#run-on-several-servers).

## Copy your SSH key to a server

**Copy SSH Key to Server…** puts this Mac's public key into the server's `~/.ssh/authorized_keys`, so it logs in with the key instead of a password. It is in each server row's menu and in search; from search it works on the server of the active panel or SSH tab, or asks which server (type `user@host` for one that isn't listed).

- **Which key:** the server's **Key file** (its `.pub` next to it) if it has one, else `~/.ssh/id_ed25519.pub`, `id_ecdsa.pub` or `id_rsa.pub`. With several, you pick one. A key file without its `.pub` gets the command that writes it (`ssh-keygen -y -f`), not another key: the server's logins use that one.
- **No key yet:** Kermo doesn't make one (a passphrase belongs in Terminal). The dialog gives the command, `ssh-keygen -t ed25519`, to copy.
- It logs in as any connection does (the saved password or the password dialog, which says it's for Copy SSH Key), adds the key unless it's there already (`~/.ssh` and the file are made owner-only when new), then logs in with the key alone to check it took. ⎋ stops it. A locked server asks for Touch ID first; a production server asks first and logs it.
- If the key went in but a login with it fails, the dialog shows ssh's words. Usually sshd refuses keys in a home folder or `~/.ssh` that others can write to (`StrictModes`).
- Afterwards a saved server without a key file gets this one (see **Edit…**), and if a password is saved for it, Kermo offers to forget it. The connection already open stays as it is.

## When the host key changed

If a server's host key no longer matches the one in `known_hosts`, Kermo won't connect and says so plainly: the server was reinstalled, or someone is intercepting the connection. It shows the new key's fingerprint and the file and line of the old one. Nothing is removed by itself.

- Opening the server's files, the alert has **Remove Old Key…** (↩ is **Cancel**). It runs `ssh-keygen -R` on that file (the old file is kept as `known_hosts.old`) and connects again; the new key is then asked about as for a server seen the first time. On a production server the alert adds: check the new fingerprint with the server's admin first.
- Elsewhere (Forward Port…, Run on Servers…, a tunnel's tooltip) the same words show without the button. An SSH tab shows ssh's own message too.

## Server rows in the sidebar

![Server rows: a production server in purple with an SFTP panel open, a server with a tunnel listening, a locked one](images/server-rows.png)

A row shows what is open on the server:

- `>_` for SSH and a folder for SFTP, in green (with a count from 2);
- `⇄` for tunnels that are listening, in green (red when one failed);
- a lock on the icon for a locked server, a red dot when the last connection failed, purple for a production server.

Under the mouse the row shows **SSH**, **SFTP**, **Tunnels** (for a saved server that has tunnels, or a server with [temporary ones](tunnels.md#forward-a-port-the-server-listens-on)) and **⋯**. A click goes to the server's open session. With nothing open, a double-click connects with SSH, so a single click on an idle server does nothing. The tooltip says all of it.

## Lock a server

A locked server asks for Touch ID or the Mac password before you connect, edit, duplicate or delete it, copy its SSH command, mark it as production or open its file history. One success unlocks it for 5 minutes. Locking the screen or sleep locks it again.

Open sessions stay open. A locked server isn't added to the recents, and its shared connection idles out after 60 seconds instead of 10 minutes. See [tunnels](tunnels.md#locked-servers) for how a lock affects them.

## Mark a server as production

Production is a flag on a saved server for the servers where a mistake is expensive. It turns the server purple (🟣 PROD in titles) and makes Kermo ask before risky changes and log what you do there. [Safety](safety.md) lists what changes.

- **Mark as Production** is in the server row's menu. A locked server asks for Touch ID first.
- **Save as Production…** (on a recent or `~/.ssh/config` row) opens the save sheet with the flag already set.
- Or set `"prod": true` for the server in `servers.json`.
