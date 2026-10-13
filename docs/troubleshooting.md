[Kermo documentation](../README.md#documentation)

# Troubleshooting

Find the symptom, apply the fix. If yours isn't here, see the end of the page.

| Symptom | Cause and fix | Details |
|---|---|---|
| Kermo won't open the first time | It isn't notarized by Apple. Click **Open Anyway** in System Settings ▸ Privacy & Security (macOS 15+), or Control-click the app and choose **Open** (macOS 14). | [Install](install.md) |
| macOS asks for Full Disk Access again | Releases are signed ad hoc, so an update looks like a new app to macOS. Grant it again. | [Install](install.md) |
| A shortcut does nothing | macOS may take it first: ⇧⌘/ is Help search, ⌃1…⌃7 switch desktops, ⌘M minimizes. Turn the system shortcut off or remap the command. Function keys without fn control media: use ⌥ plus the digit (F1–F10, ⇧F4, ⇧F6, ⇧F8); the other F-key shortcuts need fn or a remap. | [Shortcuts](shortcuts.md) |
| A remapped key never fires | Reload Config reports keys macOS takes before Kermo sees them (⌥⌘D, ⌘M …). Choose another. | [Configuration](configuration.md#keymap) |
| No Git column | The repository's own config names commands Kermo won't run, or git isn't installed. | [Git](git.md#when-there-is-no-git-column) |
| The panel doesn't follow `cd` in the terminal | Add the snippet to `~/.zshrc`. | [Terminal](terminal.md#shell-integration) |
| ⌥ types no `@`, `\|`, `[` or `]` in the terminal | Set `terminalOptionIsMeta` to `false`. | [Terminal](terminal.md#options) |
| Root panel: the sudo password sheet, "refused the password 3 times", `requiretty` or no `sftp-server` | The sheet is normal when sudo wants a password; `NOPASSWD` for `sftp-server` avoids it. Turn `requiretty` off, or install the SFTP server (Alpine: `apk add openssh-sftp-server`). sudo-rs 0.2.2 can't take the password and needs `NOPASSWD`. | [Root panel](root-panel.md#set-up-sudo) |
| "no check for this file" on a save | The server has no tool for that file, or the tool is missing (exit 127). | [Checks](config-checks.md#how-a-save-is-checked) |
| "check needs root" or "reload needs root" | Reopen the panel as root with ⌃⌘R. | [Checks](config-checks.md#root-and-user) |
| "changed on host since you opened it" | Someone changed the file meanwhile. **Compare** shows the difference before you overwrite. | [Files on a server](server-files.md#open-and-edit) |
| No version in the file history | Files over 5 MB get none, and history may be off (`serverHistory`). | [File history](server-files.md#file-history) |
| A tunnel is red | The tooltip says why: the remote port is closed, forwarding is forbidden, the host name doesn't resolve, or your local port is taken. | [Tunnels](tunnels.md#state) |
| A tunnel turns red with "Port N is in use" | Another program has the port. Turn the tunnel off, choose **Edit…** and give it another local port. When you save a port that is taken, Kermo offers the next free one. | [Tunnels](tunnels.md#add-a-tunnel) |

## Reset

Remove one option with `defaults delete com.dmn.dfilemanager <key>`. To start clean, quit Kermo, move `~/.config/dfilemanager` aside and run `defaults delete com.dmn.dfilemanager`. That removes your saved servers, keymap, file history and every option. Passwords saved in the Keychain stay until you delete them there.

## Report a problem

Open an [issue](https://github.com/paliydmn/kermo/issues) with the Kermo and macOS versions, what you did and what you expected. Leave out passwords, host names you want private and private paths.
