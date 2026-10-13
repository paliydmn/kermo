# Configuration

Configuration files are stored in `~/.config/dfilemanager/`: `servers.json` (saved servers and their tunnels), `keymap.json`, `usermenu.json`, `validators.json` (checks of server configs on save, see SFTP panel), `filters.json`, `bookmarks.json` (sidebar Favorites), and `frecency.json` (sidebar Frequent, ⌘P). `audit.jsonl` is the production log.

Drag and drop works like Finder: files are moved on the same disk (or the same server) and copied to another disk or server. Hold ⌥ to force a copy or ⌘ to force a move. Files dropped on the ⌃O terminal are typed into its shell as quoted paths (a local shell only: a server can't see this Mac's files).

Set advanced options with `defaults write com.dmn.dfilemanager <key> <value>`:

- `terminalBundleID`: terminal used by ⌘⌥T and ⌘↩, for example `com.googlecode.iterm2`
- `terminalFont`: font of the built-in ⌃O terminal, for example `'MesloLGS NF'` for Powerlevel10k / Starship prompt icons; SF Mono by default
- `terminalFontSize`: its size — the same ⌘+ / ⌘− change, saved automatically
- `terminalOptionIsMeta`: `false` if you need ⌥ to type your layout's characters (`@`, `|`, `[`, `]`); `true` by default — ⌥ is Meta (⌥B / ⌥F in zsh)
- `editorBundleID`: external editor to use instead of the built-in editor
- `diffCommand`: file comparison tool, for example `'code --diff %1 %2'` (a server's file comes as its local copy)
- `serverHistory`: `false` keeps no versions of the server files you save (see SFTP panel)
- `auditLog`: `false` writes no production log (see SFTP panel)
