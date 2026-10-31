[Kermo documentation](../README.md#documentation)

# Configuration

Where Kermo keeps its settings, the formats of the files you can edit, and the `defaults` options.

## Settings

**Kermo ▸ Settings…** (⌘,) has the options below and the files to edit in one window. Each option shows its `defaults` key at its right, and takes effect at once unless its line says when (new terminal tabs, new editor windows, the next viewer). The window comes back on the tab you left.

| Tab | What's there |
|---|---|
| General | Show hidden files (`showHidden`); Dates: `Today 13:33` or `2026-10-27 13:33` (`isoDates`); Check for updates once a day (`updateCheckOff`); install the `fm` command |
| Appearance | The themes, each with a preview: a click uses it (`theme`; **View ▸ Theme…** previews them as you move through the list); Permissions & Owner columns (`showPerms`); how long to hold a modifier before the key bar shows its keys (`keyBarHoldDelay`) |
| Keys | Every command with its keys; see [Keymap](#keymap) |
| Terminal | Font and size (`terminalFont`, `terminalFontSize`); the drawer's height (`terminalDrawerHeight`, by dragging its line); Option is Meta (`terminalOptionIsMeta`); Selecting text copies it and Right-click pastes (`terminalCopyOnSelect`, `terminalRightClickPaste`: both use the clipboard); the app for ⌥⌘T and ⌘↩ (`terminalBundleID`) |
| Editor & Viewer | The editor for files on this Mac (`editorBundleID`); End with a newline (`editorFinalNewline`); Line numbers (`viewerLineNumbers`); the tool that compares files (`diffCommand`) |
| Servers & Safety | Keep a production log (`auditLog`) and Show it; Keep earlier versions of saved server files (`serverHistory`); Checks before saving (**Edit…**); **Edit SSH Config…**; how long the sudo password is kept |
| Monitor | Whether macOS lets Kermo [notify](tools.md#notifications) and **Open System Settings**; a command to run on critical alerts (`onAlert`) and **Send Test** |
| Advanced | **Edit…** for `keymap.json`, `usermenu.json`, `validators.json` and `filters.json`; **Open** the config folder; **Reload Config** |

## Files

Kermo's files are in `~/.config/dfilemanager/` (the folder is owner-only, `0700`; files are `0600`). **Kermo ▸ Configuration ▸ Open Config Folder** (or **Open** in Settings › Advanced) opens it in the panel, and **Reload Config** (in the same menu, and there) applies a changed `keymap.json` and reads `tools/` again without a restart.

| File | Holds | Edit with |
|---|---|---|
| `servers.json` | [Saved servers](servers.md#save-a-server) and their [tunnels](tunnels.md) | The sidebar menus; by hand, see below |
| `keymap.json` | Your shortcuts | **Edit Keymap…** |
| `usermenu.json` | The F2 menu ([commands](commands.md#user-menu)) | **Edit User Menu…** |
| `validators.json` | [Checks of server configs on save](config-checks.md#your-own-rules) | **Edit Validators…** |
| `filters.json` | Quick filter presets (⌘/) | **Edit Filter Presets…** |
| `bookmarks.json` | Sidebar Favorites | ⌘D, drag and drop |
| `frecency.json` | Sidebar Frequent and ⌘P | Kermo writes it |
| `audit.jsonl` | The [production log](safety.md#production-log) | **Server ▸ Production Log** |
| `history.noindex/` | [Versions of server files](server-files.md#file-history) | Kermo writes it |
| `tools/` | [Your own tools](tools.md#your-own-tools): a JSON file each, with its scripts | By hand; **Reload Config** checks them |
| `tools/trust.json`, `tools/known.json` | Your own tools you said to use; what each saved server had | Kermo writes them |
| `tools/servers.json` | [Where each tool is used](tools.md#where-a-tool-is-used), hidden on which saved server, the values it asks for there | Use on Servers…, Hide, Set Up… |
| `tools/runs.json` | The [long jobs](tools.md#long-jobs) Kermo started: where, what (never a secret) and how they ended; kept a week after they end | Kermo writes it |

Kermo also writes `server-pins.json` (the order of pinned servers), `trash.json` (where trashed items came from, for Put Back) and `activity.json` (the last 100 finished jobs in [Activity](files.md#activity)).

A file Kermo writes back itself (`servers.json`, `bookmarks.json`, `server-pins.json`, `frecency.json`, `trash.json`) that it can't read is copied as it is to `name.broken` before anything is saved over it, and Kermo says so at launch (`trash.json`: when it's next read). In a list (servers, bookmarks, pins) only the entries that can't be read are left out; the rest load. A file that doesn't parse at all starts empty. When a `name.broken` with something else in it is there already, the new copy is `name.broken-<date>-<time>`.

## Keymap

**Settings › Keys** lists every command with its menu and keys. Type to find one by name, by a word it's known by, or by its key (`⌘D` or `cmd+d`). Click a key, or **＋** after them, and press the new one: **⎋** cancels, **⌫** removes the key you clicked. What can't work is said at once, as Reload Config would say it — a key of the menu bar's own items, one macOS takes first — and nothing changes. A key another command has asks: **Use Here** moves it, **Cancel** leaves both as they were. The arrow after a command's keys gives it Kermo's own back; **Reset All…** does that for every command, after a question.

Keys set there go into `keymap.json`, only for the commands you changed, and work at once. The file stays yours to edit: the tab reads it each time it opens.

`keymap.json` maps a command's id to its keys: `{ "command.id": ["cmd+shift+p", "f9"] }`. **Edit Keymap…** writes every current binding on first use, so you change only what you need. An entry replaces all default keys of that command.

- **Key names:** modifiers `cmd`, `opt` (or `alt`), `ctrl`, `shift`, joined with `+`, then the key: a letter or digit, a punctuation key (`.`, `,`, `/`, `=` …), `f1`…`f12`, `return`, `tab`, `space`, `backspace`, `delete`, `esc`, `home`, `end`, `pgup`, `pgdn`, `left`, `right`, `up`, `down`, or `kpstar`, `kpplus`, `kpminus`. Examples: `cmd+shift+.`, `opt+5`, `shift+f6`.
- **Reload Config** reports unknown commands, bad keys and keys that macOS takes before Kermo sees them (⌥⌘D, ⌘M …).
- The menu bar's own keys stay with their items, so they keep working in text fields, the viewer and the editor: ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A, ⌘F and ⌘G (Edit), ⌘S (File) and ⌘0 (Window). In a panel ⌘A does Mark All (`mark.all`), and ⌘F and ⌘G do Search Files (`search`). Giving one of these keys to another command, or taking ⌘A or ⌘F from those two, doesn't move it, and Reload Config says so.
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

Passwords are not in the file: they are in the Keychain. An entry that can't be read (`"port": "22"` in quotes, a misspelled `true`) is left out, the others load, and the file as it was is copied to `servers.json.broken`; see above.

## Options

Set an option in [Settings](#settings), or with `defaults write com.dmn.dfilemanager <key> <value>` (for scripts). Remove it, back to the default, with `defaults delete com.dmn.dfilemanager <key>`.

| Key | Value | Default | Effect |
|---|---|---|---|
| `isoDates` | `-bool` | `false` | `true`: the Modified column always shows `2026-10-25 13:33`, not "Today 13:33", "Oct 14 13:32" or "2024-03-01" ([Modified column](files.md#sizes-hidden-files-and-sort)) |
| `keyBarHoldDelay` | seconds | 0.12 | How long to hold a modifier before the [key bar](window.md#key-bar) shows its shortcuts |
| `terminalFont` | font name | SF Mono | Font of the [terminal](terminal.md#options) |
| `terminalFontSize` | points | 13 | Its size, 9–36 (⌘+ / ⌘− save it) |
| `terminalDrawerHeight` | points | 40 % of the room | The [terminal drawer](terminal.md#open-the-terminal)'s height (dragging its line saves it) |
| `terminalOptionIsMeta` | `-bool` | `true` | ⌥ is Meta in the terminal; `false` lets ⌥ type your layout's characters |
| `terminalCopyOnSelect` | `-bool` | `true` | Text selected in the terminal goes to the clipboard at once, as in PuTTY; `false`: only ⌘C copies |
| `terminalRightClickPaste` | `-bool` | `true` | A right-click in the terminal pastes, as in PuTTY (⇧-right-click in mc, htop and the like); `false`: it doesn't |
| `terminalBundleID` | bundle id | `com.apple.Terminal` | App used by ⌥⌘T and ⌘↩, for example `com.googlecode.iterm2` |
| `editorBundleID` | bundle id | built-in editor | External editor used instead of the [built-in one](viewer-editor.md) for files on this Mac (server files always open in the built-in editor) |
| `editorFinalNewline` | `-bool` | config files only | Whether new editor windows end saved text with a newline; **File ▸ Ensure Final Newline** overrides it per window |
| `diffCommand` | command | built-in diff | Tool for [comparing files](search-compare.md), for example `'code --diff %1 %2'` (a server's file comes as its local copy) |
| `serverHistory` | `-bool` | `true` | `false` keeps no [versions of server files](server-files.md#file-history) |
| `updateCheckOff` | `-bool` | `false` | `true`: Kermo doesn't [check for updates](install.md#updates) by itself (**Kermo ▸ Configuration ▸ Check for Updates Automatically** sets it) |
| `auditLog` | `-bool` | `true` | `false` writes no [production log](safety.md#production-log) |
| `onAlert` | command | none | Runs on this Mac, in your login shell, on each [critical alert](tools.md#notifications) of a watched server, with `KERMO_SERVER`, `KERMO_LEVEL`, `KERMO_MESSAGE` and `KERMO_TOOL` in its environment, for example `'curl -s -d "$KERMO_SERVER: $KERMO_MESSAGE" ntfy.sh/my-topic'` |

Kermo also keeps window sizes, the last folders, recent servers and the like in the same defaults domain. Leave those to the app.
