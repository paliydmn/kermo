[Kermo documentation](../README.md#documentation)

# Server files as root

Open a server's files with root rights to edit `/etc` and other protected files, through the server's own `sudo`. Nothing is installed on the server.

## Open a panel as root

- In the sidebar, choose **Open SFTP as Root** in a server's menu.
- On a server panel, choose **Reopen Panel as Root** (⌃⌘R, **Admin** menu, search). **Reopen Panel as User** (⌃⇧⌘R) goes back.

The panel's SFTP then runs through `sudo` on the same connection. Kermo looks for `sftp-server` in the usual places (Debian/Ubuntu, RHEL/Fedora, Arch/Alpine, openSUSE, BSD/macOS) and runs `sudo -n -- <sftp-server>`.

The header and the window title read `root@host:/path #`. The header is orange, or purple on a production server.

## Set up sudo

**Without a password:** allow it for `sftp-server` alone, for example:

```
me ALL=(root) NOPASSWD: /usr/lib/openssh/sftp-server
```

> [!WARNING]
> `sftp-server` running as root can write any file, `/etc/sudoers` included, so this line is as good as full root for that user.

**With a password:** Kermo asks in a sheet when `sudo -n` refuses for want of one (never otherwise: a sudo that needs no password would pass it on to `sftp-server`).

- It tries the password once on its own, with `sudo -S -p '' -k -- <sftp-server>` and nothing after the password, so `sftp-server` ends at once. A wrong password costs a single attempt in the server's log. Then the session gives the password to sudo on stdin, never on a command line or in a file.
- If sudo takes the password but doesn't allow `sftp-server` to the user, it says so at once.
- The password stays in memory for 5 minutes after its last use. Locking the screen, sleep or **Disconnect** forgets it.
- **Save in Keychain** keeps it in the login keychain as "Kermo sudo: host", apart from the ssh password. It is removed when sudo refuses it, when you delete the saved server, or with **Forget the saved sudo password** in the server's **Edit…** sheet.
- sudo-rs 0.2.2 can't take a password this way. Set up `NOPASSWD` for it.

When sudo refuses, the panel says why: it needs a password; `Defaults requiretty` is set (old RHEL/CentOS: turn it off for the user); or there is no `sftp-server` (Alpine serves SFTP from sshd itself: run `apk add openssh-sftp-server`).

## What runs as root

Only the file operations run as root, plus a save's [check and reload](config-checks.md). Search, archives, Git status, the user menu, ⌘E and the terminal run as the user. The command line says so: its prompt stays `user@host:/path $`, and on a root panel it reads "⌘E: shell command in this folder as user, not root".

- Saves go the same way as the user's: [file history](server-files.md#file-history), the production question, "changed on the server since you opened it".
- Saving someone else's file (`www-data`'s, a user's) keeps its owner and group: the new file gets them before it replaces the old one, so it's never root's, not even for a moment.
- New files, folders and copies belong to `root:root`, as with any `sudo`.
- Folder sizes (Space, ⌥Space) come from `du` through `sudo -n`. Where sudo doesn't allow that without a password (a rule for `sftp-server` alone, say), the folders are walked over the root session instead, as before.
- On a server with SELinux (`/sys/fs/selinux`) a save writes into the file itself instead of renaming a new one over it, so the file keeps its label. It writes over the old text and then cuts it to length, so a dropped connection never leaves it empty ([Open and edit](server-files.md#open-and-edit)).

## Root and user are two accounts

- F5 / F6 between a root panel and a user panel of the same server copy through this Mac, each side with its own rights.
- ⌘C / ⌘V carry the user's account, never root, and so does anything dropped from another app. A drag from a root panel to another Kermo panel stays root.
- Nothing pasted, dropped or restored opens a server as root.
- A locked server asks for Touch ID, as for any connection.
