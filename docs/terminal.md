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

## Options

Set them with `defaults write com.dmn.dfilemanager <key> <value>`:

| Key | Meaning |
|---|---|
| `terminalFont` | Font of the terminal, for example `'MesloLGS NF'` for Powerlevel10k or Starship prompt icons. SF Mono by default. |
| `terminalFontSize` | Its size, 13 by default, 9–36. The same ⌘+ / ⌘− change, saved automatically. |
| `terminalOptionIsMeta` | `true` by default: ⌥ is Meta (⌥B and ⌥F in zsh). `false` lets ⌥ type your layout's characters (`@`, `\|`, `[`, `]`). |
| `terminalBundleID` | The app that ⌥⌘T and ⌘↩ open on this Mac's folders, for example `com.googlecode.iterm2`. Terminal.app by default. On a server panel both open an SSH tab in Kermo. |
