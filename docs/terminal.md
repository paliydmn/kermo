[Kermo documentation](../README.md#documentation)

# Terminal and SSH sessions

A shell inside Kermo, local or on a server, that stays in step with the panels.

## Open the terminal

- **⌃O** replaces the panels with a terminal: your login shell on a local panel, the server's SSH session on a server panel. Press it again to get the panels back. A local panel follows `cd`.
- Press **⌃O twice quickly** to send ⌃O to the program in the terminal.
- **⌘K** opens a shell on a server in a new tab ([Servers and SSH](servers.md)). Inside the terminal, ⌘K clears it.
- **⌘+** and **⌘−** change the text size.

While the terminal is open:

- Clicking a local place in the sidebar runs `cd` there in the shell.
- **⌃↩** types the cursor's name and **⌃⇧↩** the marked items' full paths into the shell.
- Files dropped on the terminal are typed into its shell as quoted paths (a local shell only: a server can't see this Mac's files).

### Copy and paste with the mouse

As in PuTTY: **selecting text copies it** — a drag, a double-click on a word, a triple-click on a line — and **a right-click pastes** the clipboard where the cursor is. ⌘C and ⌘V work as before.

- In a program that reads the mouse itself (mc, htop, vim with `mouse=a`), a right-click is the program's: **⇧-right-click** pastes there, and ⌥-drag selects.
- A shell that asked for bracketed paste (zsh, bash 5.1 and later) runs nothing pasted until you press ↩. Pasting several lines into a **production** server's SSH tab, or one logged in as `root@`, into a shell that didn't ask for it (`sh`, an old bash), asks first: “Paste 5 lines into web1 (production)?”, with ↩ on Cancel.
- Selecting replaces what the clipboard held. To keep it, turn either part off: `terminalCopyOnSelect`, `terminalRightClickPaste` ([Options](#options)).

## Shell integration

The terminal sets `TERM_PROGRAM=Kermo`, so Apple's Terminal.app hook in `/etc/zshrc` doesn't load. A few lines in `~/.zshrc` bring it back, only inside Kermo:

```zsh
# ~/.zshrc — in Kermo's ⌃O terminal: the panel follows `cd`, the tab is named after the folder,
# and the ` cd` the app types stays out of your history.
if [[ $TERM_PROGRAM == Kermo ]]; then
  setopt HIST_IGNORE_SPACE
  source /etc/zshrc_Apple_Terminal   # Terminal.app's own `update_terminal_cwd` (OSC 7); nothing else without TERM_SESSION_ID
fi
```

Without it the panel still follows the shell's folder when you hide the terminal (⌃O), and the tab gets its folder's name when it's shown or switched to. With it, both update on every `cd`. fish and bash aren't checked.

## Touch ID for sudo

**Admin ▸ Enable Touch ID for sudo** (also in ⇧⌘P) lets `sudo` in a terminal on this Mac take your fingerprint instead of your password. Kermo asks first, then writes `/etc/pam.d/sudo_local` — macOS's `sudo_local.template` with its `pam_tid.so` line on — and macOS asks for your password once to write it. A `sudo_local` of your own keeps its lines; the Touch ID line goes after them (one that is a symlink, kept by nix-darwin or the like, is left alone). The file survives macOS updates; new terminal windows use it. If it's on already, Kermo says so and asks nothing.

- **Turning it off:** `sudo rm /etc/pam.d/sudo_local` (or put `#` before the `pam_tid.so` line in it).
- **In tmux or screen** Touch ID needs [pam_reattach](https://github.com/fabianishere/pam_reattach): `brew install pam-reattach`, then the line `auth optional /opt/homebrew/lib/pam/pam_reattach.so` in `sudo_local` before the `pam_tid.so` one.

## Options

Set them with `defaults write com.dmn.dfilemanager <key> <value>`:

| Key | Meaning |
|---|---|
| `terminalFont` | Font of the terminal, for example `'MesloLGS NF'` for Powerlevel10k or Starship prompt icons. SF Mono by default. |
| `terminalFontSize` | Its size, 13 by default, 9–36. The same ⌘+ / ⌘− change, saved automatically. |
| `terminalOptionIsMeta` | `true` by default: ⌥ is Meta (⌥B and ⌥F in zsh). `false` lets ⌥ type your layout's characters (`@`, `\|`, `[`, `]`). |
| `terminalCopyOnSelect` | `true` by default: a selection goes to the clipboard as it's made. `false`: only ⌘C copies. |
| `terminalRightClickPaste` | `true` by default: a right-click pastes. `false`: it does nothing, as before. |
| `terminalBundleID` | The app that ⌥⌘T and ⌘↩ open on this Mac's folders, for example `com.googlecode.iterm2`. Terminal.app by default. On a server panel both open an SSH tab in Kermo. |
