[Kermo documentation](../README.md#documentation)

# Configuration

Where Kermo keeps its settings, the formats of the files you can edit, and the `defaults` options.

## Files

Kermo's files are in `~/.config/dfilemanager/` (the folder is owner-only, `0700`; files are `0600`). **Kermo ▸ Open Config Folder** opens it in the panel, and **Reload Config** applies a changed `keymap.json` without a restart.

| File | Holds | Edit with |
|---|---|---|
| `servers.json` | [Saved servers](servers.md#save-a-server) and their [tunnels](tunnels.md) | The sidebar menus; by hand, see below |
| `keymap.json` | Your shortcuts | **Edit Keymap…** |
| `usermenu.json` | The F2 menu ([commands](commands.md#user-menu)) | **Edit User Menu…** |
| `validators.json` | [Checks of server configs on save](config-checks.md#your-own-rules) | **Edit Validators…** |
| `filters.json` | Quick filter presets (⌘/) | **Edit Filter Presets…** |
| `bookmarks.json` | Sidebar Favorites | ⌘D, drag and drop |
| `frecency.json` | Sidebar Frequent and ⌘P | Kermo writes it |
| `audit.jsonl` | The [production log](safety.md#production-log) | **Admin ▸ Show Production Log** |
| `history.noindex/` | [Versions of server files](server-files.md#file-history) | Kermo writes it |

Kermo also writes `server-pins.json` (the order of pinned servers), `trash.json` (where trashed items came from, for Put Back) and `servers.json.broken` (a `servers.json` that failed to parse, moved aside so the next save doesn't overwrite your hand edit).

## Keymap

`keymap.json` maps a command's id to its keys: `{ "command.id": ["cmd+shift+p", "f9"] }`. **Edit Keymap…** writes every current binding on first use, so you change only what you need. An entry replaces all default keys of that command.

- **Key names:** modifiers `cmd`, `opt` (or `alt`), `ctrl`, `shift`, joined with `+`, then the key: a letter or digit, a punctuation key (`.`, `,`, `/`, `=` …), `f1`…`f12`, `return`, `tab`, `space`, `backspace`, `delete`, `esc`, `home`, `end`, `pgup`, `pgdn`, `left`, `right`, `up`, `down`, or `kpstar`, `kpplus`, `kpminus`. Examples: `cmd+shift+.`, `opt+5`, `shift+f6`.
- **Reload Config** reports unknown commands, bad keys and keys that macOS takes before Kermo sees them (⌥⌘D, ⌘M …).
- The cheat sheet (F1) shows your keys.

## Filter presets

`filters.json` is a list of `{ "title": "Images", "filter": "*.png;*.jpg" }`. The filter works as the quick filter does: globs separated by `;`, or `re:` and a regular expression. **Edit Filter Presets…** writes six examples on first use.

## Saved servers

`servers.json` is edited for you by the server sheets. You can edit it by hand, but quit Kermo first: it is read at launch and rewritten on every change. Only `host` is required.

| Key | Meaning |
|---|---|
| `name`, `host`, `user`, `port` | As in the sheet |
| `identityFile`, `startDir` | **Key file** and **Start folder** |
| `locked` | `true` asks for Touch ID or the Mac password |
| `prod` | `true` marks the server as [production](servers.md#mark-a-server-as-production) |
| `tunnels` | The server's [tunnels](tunnels.md#where-tunnels-are-kept) |

Passwords are not in the file: they are in the Keychain. A file that doesn't parse is moved to `servers.json.broken`.

## Options

Set an option with `defaults write com.dmn.dfilemanager <key> <value>`. Remove it, back to the default, with `defaults delete com.dmn.dfilemanager <key>`.

| Key | Value | Default | Effect |
|---|---|---|---|
| `keyBarHoldDelay` | seconds | 0.12 | How long to hold a modifier before the [key bar](window.md#key-bar) shows its shortcuts |
| `terminalFont` | font name | SF Mono | Font of the [terminal](terminal.md#options) |
| `terminalFontSize` | points | 13 | Its size, 9–36 (⌘+ / ⌘− save it) |
| `terminalOptionIsMeta` | `-bool` | `true` | ⌥ is Meta in the terminal; `false` lets ⌥ type your layout's characters |
| `terminalBundleID` | bundle id | `com.apple.Terminal` | App used by ⌥⌘T and ⌘↩, for example `com.googlecode.iterm2` |
| `editorBundleID` | bundle id | built-in editor | External editor used instead of the [built-in one](viewer-editor.md) for files on this Mac (server files always open in the built-in editor) |
| `editorFinalNewline` | `-bool` | config files only | Whether new editor windows end saved text with a newline; **File ▸ Ensure Final Newline** overrides it per window |
| `diffCommand` | command | built-in diff | Tool for [comparing files](search-compare.md), for example `'code --diff %1 %2'` (a server's file comes as its local copy) |
| `serverHistory` | `-bool` | `true` | `false` keeps no [versions of server files](server-files.md#file-history) |
| `auditLog` | `-bool` | `true` | `false` writes no [production log](safety.md#production-log) |

Kermo also keeps window sizes, the last folders, recent servers and the like in the same defaults domain. Leave those to the app.
