# Kermo

A keyboard-first file manager and admin console for macOS: 2–4 panels, SSH and SFTP, a built-in terminal, built with Swift and AppKit. *Kermo* is Ukrainian for "helm".

[![Kermo in 80 seconds: SFTP, SSH, Git, live logs and production safety](docs/video.jpg)](https://youtu.be/hjXibnVEQ9c)

## Requirements and installation

Kermo requires macOS 14 or later. To install a packaged release, open the DMG, drag Kermo to Applications, then open it. Local releases are not notarized by Apple, so the first launch is blocked: on macOS 15 or later click **Open Anyway** in System Settings > Privacy & Security; on macOS 14 Control-click the app and choose **Open**. Kermo was called DFileManager before: settings and permissions carry over, so delete the old DFileManager.app.

To create a universal installer for Apple Silicon and Intel Macs:

```bash
./package.sh                                   # writes universal .pkg and .dmg files to dist/
```

Send the `.pkg` file for the simplest installation: opening it runs the standard macOS installer and places Kermo in Applications. Because local releases are not notarized by Apple, the recipient allows the package the same way on the first open.

Building from source requires the Command Line Tools. The full Xcode installation is not required.

```bash
./cert.sh                                      # create a local signing certificate (run once)
./build.sh                                     # build build/Kermo.app
cp -R build/Kermo.app /Applications/           # install the app
open /Applications/Kermo.app                   # launch it
```

Running `./cert.sh` once creates a local self-signed certificate in your login keychain. This keeps Full Disk Access and other macOS permissions from being reset after every rebuild. Without the certificate, `build.sh` uses ad-hoc signing.

Other development commands:

```bash
./test.sh                                      # run tests (works around a CLT swift-testing plugin bug)
swift run -c release bench                     # benchmark and verify 100k generated files
swift run -c release bench ~/Library           # benchmark a real directory
```

## Window

- **Key bar** (bottom row): shows F1–F10. Hold ⇧, ⌥, ⌘ or ⌃ (or a combination such as ⇧⌘ or ⌃⌘) for a moment, and it shows every shortcut that uses those modifiers. Click a slot to run it, just like pressing the key; a pressed shortcut highlights its slot. **Hold ▾** pins a layer for mouse use until you press Esc or run a command, and **+N** opens the cheat sheet filtered to that layer. Change the 120 ms delay with `defaults write com.dmn.dfilemanager keyBarHoldDelay 0.2`.
- **Places sidebar** (⌃⌘S or the toolbar button):
  - **Favorites**: your bookmarks (⌘D). Drag a folder in to add it, drag to reorder, right-click to remove.
  - **Frequent**: your 5 most-visited folders that aren't Favorites.
  - **Locations**: mounted volumes, updated on mount and unmount, with Eject for removable and network volumes.
  - **Servers**: up to 6 recent servers plus **Connect…** (every server: ⌘K opens an SSH shell, ⌃⌘K a file panel).
  - **Tags**: Finder's 7 colors and your own tags. Clicking one lists every tagged file in your home folder.
  - Click opens a place in the active panel, ⌥-click in the other panel, ⌘-click in a new tab. Files dropped on a place are copied or moved there by Finder's rules.
  - ⌃⇧S moves the keyboard focus to the sidebar: ↑↓ choose a place, ↩ opens it (⌥↩ / ⌘↩ as with clicks), ⎋ goes back to the panel. Clicking the sidebar never takes the keys from the panels.
  - While the ⌃O terminal is open, clicking a local place `cd`s the shell there.
  - Sections fold when you click their header. The sidebar hides itself when panels get narrower than 360 pt each and returns from 400 pt, unless you hid it yourself.
- **Toolbar search** (⌘⇧P, F9): finds commands by name or synonym ("zip" finds Compress) and shows their shortcuts. It also finds folders (Favorites, frequent folders, volumes, servers) and files in the active panel. ↑↓ choose, ↩ runs or opens, ⌘↩ opens a folder in the other panel, Esc returns to the panel. The last row searches the disk (⌘F). Focused empty, it lists the last 10 things chosen in it (commands, folders, servers, disk searches) above Favorites; ✕ or ⌘⌫ removes one.
- **Cheat sheet** (F1): every shortcut, grouped by menu, with a filter field. It is generated from the current keymap, so your remapped keys appear in it.

## Keyboard shortcuts

Every function-key action also has an ⌥+number shortcut (⌥0 = F10) because Mac function keys control media by default. Shortcuts are bound to physical keys, so they work with any keyboard layout (the ISO § key counts as `` ` ``); menu items still show and match the characters of the current layout, so on a layout that moves Latin letters (Dvorak, AZERTY) a letter shortcut in a menu follows the letter. To remap any shortcut, choose **Edit Keymap…** from the application menu.

Clashes with macOS: ⌘⇧/ (computer root) is also the system's Help-menu search, and ⌃1…⌃7 (Finder tags) switch desktops once you have several — turn those off in System Settings › Keyboard › Keyboard Shortcuts, or remap the command. ⌘M minimizes the window, as everywhere on the Mac.

| Action | Shortcut |
|---|---|
| **Search**: commands, folders and files (all actions below) | ⌘⇧P, F9, ⌥9 |
| Keyboard shortcuts cheat sheet | F1, ⌥1 |
| Show / hide the Places sidebar | ⌃⌘S |
| Keyboard focus to the sidebar (↑↓ choose, ↩ open, ⎋ back to the panel) | ⌃⇧S |
| Go to directory (bookmarks ★ + frequently used) / add bookmark | ⌘P / ⌘D |
| Next panel / panel N | Tab / ⌘1…⌘4 |
| Back to the panels from a viewer or editor (Window menu) | ⌘0 |
| Add / close panel (2–4; F5/F6 target the previously active panel) | ⌘⌥N / ⌘⌥W |
| Directory tree (←/→ collapse/expand, ↩ open) | F10, ⌥0, ⌥F10, ⌘⇧T |
| Open / enter an `.app` bundle | ↩ / ⌘↓ |
| Up / back / forward | ⌫, ⌘↑ / ⌘[ / ⌘] |
| Home / computer root | ⌘⇧H / ⌘⇧/ |
| Path entry with Tab completion | ⌘L, ⌘⇧G |
| Tabs: new / close (or click a tab's ×) / next / previous | ⌘T / ⌘W / ⌃⇥, ⌘⇧] / ⌃⇧⇥, ⌘⇧[ |
| Swap panels / open the same directory in the other panel | ⌘U / ⌥= |
| Quick filter (text, `*.glob`, `re:`) / presets and recent filters | / / ⌘/ |
| Find files (name / content / Spotlight) | ⌘F, ⌥F7 |
| Quick View in the other panel / Quick Look | ⌃Q / ⌘Y |
| Mark files (MC style) | Space, ⇧↑/⇧↓, ⌘-click, ⇧-click |
| Mark all / unmark / invert / mark by mask / unmark by mask | ⌘A / ⌘⇧A / `*` / `+` / `-` |
| Calculate directory sizes (all) | ⌥Space (Space calculates one; ⎋ stops) |
| View / Edit | F3, ⌥3 / F4, ⌥4 |
| Copy / Move | F5, ⌥5 / F6, ⌥6 |
| Rename / batch rename | ⇧F6, ⇧⌥6 / ⌘⇧M |
| New directory / new file | F7, ⌥7, ⌘⇧N / ⇧F4, ⇧⌥4 |
| Move to Trash / delete permanently | F8, ⌥8, ⌘⌫, ⌦ / ⇧F8, ⌘⌥⌫, ⇧⌦ |
| Put Back (restore an item Kermo moved to Trash) | ⌘⌫ / F8 in Trash |
| Undo / redo (rename, move, Trash, copy, mkdir) | ⌘Z / ⌘⇧Z |
| Info: permissions, owner, xattr, ACL, hashes, signature | ⌘I |
| User command menu / command line | F2, ⌥2 / ⌘E (↩ run in the ⌃O shell — aliases, colors, sudo, your history; ⇧↩ output window; ⌘↩ run in Terminal; ↑↓ history) |
| Insert the cursor name / the marked items' full paths into the command line — or into the shell while the ⌃O terminal is up | ⌃↩ / ⌃⇧↩ |
| Reveal in Finder / open Terminal here | ⌘⇧R / ⌘⌥T |
| Copy files / paste / move here | ⌘C / ⌘V / ⌘⌥V |
| Copy path / name | ⌘⇧C / ⌘⌥C |
| Show hidden files / refresh | ⌘⇧. / ⌘R |
| Connect to server in a file panel: SFTP (`~/.ssh/config`, `user@host:/path`) or smb:// nfs:// afp:// | ⌃⌘K |
| New SSH session: a shell on a server in the ⌃O terminal (inside the terminal ⌘K clears it) | ⌘K |
| Replace panels with terminal (the panel follows `cd`); ⌃O twice quickly sends ⌃O to the terminal | ⌃O |
| Terminal text bigger / smaller | ⌘+ / ⌘− |
| Open archive as directory / extract / create archive | ↩ / F5, ⌥F9 / ⌥F5 |
| Compare directories, recursively (mark differences) / synchronize (two-way or mirror → / ←) — also with a server | ⇧F2 / ⌘⇧S |
| Diff two files — also a server's (two marked, the cursor and the same name in the other panel, or both cursors) | ⌘⇧D |
| Git: only changes / all changes as a list / diff against HEAD | ⌃G / ⌃⇧G / ⌃D |
| Git: log of the file (with patches) / blame — in the viewer; stage / unstage marked files | ⌃L / ⌃⇧L; ⌃⇧A / ⌃⇧U |
| Finder tags: Finder color / remove all / edit | ⌃1…⌃7 / ⌃0 / ⌃T |
| Split file into parts / combine (`.000`, `.001`, …) | **File** menu |
| Theme (System, Midnight Commander, Far Manager, Solarized Dark/Light, Dracula, Nord, Gruvbox, Monokai, One Dark, Tokyo Night, Catppuccin, GitHub Light) | View ▸ Theme… |
| Create symbolic link / follow link target | ⌘⌥L / ⌘J |
| Volumes / Eject | ⌘⇧V, ⌥F1 / ⌘⌥E |
| Run as administrator: copy / move / mkdir / delete / root shell | **Admin** menu (or search, ⌘⇧P) |
| Server panel as root / as its user again (see SFTP panel) | ⌃⌘R / ⌃⇧⌘R (**Admin** ▸ Reopen Panel as Root / as User) |
| Viewer: find / wrap / hex / plist-JSON / follow (tail -f) / close | ⌘F / w / h / p / f / Esc, F3, q, ⌘W |
| Viewer, files larger than 32 MB: go to (`50%`, `1.5G`, `end`) / start, end / search entire file, next result | g / Home, End / `/`, n |
| Editor: save / find and replace / close | ⌘S / ⌘F / Esc, ⌘W |

## SFTP panel

- Uses the system OpenSSH client, so keys, agents, and ProxyJump settings from `~/.ssh/config` work exactly as they do in Terminal.
- Requests passwords through a macOS dialog.
- A panel keeps one connection to its server while it shows it, so opening a folder doesn't start ssh again; after sleep or a network change the next folder connects afresh.
- F5 / F6, ⌘C / ⌘V and drag and drop copy and move files in every direction: server ↔ local, server ↔ another server, and within one server (a move there is a rename, a copy happens on the server). They run in the operations queue like local copies: progress with speed and ETA, pause, cancel, the overwrite / skip / keep both dialog, and Retry, which continues a large file where a dropped connection left it.
- Operations on different servers and on this Mac run side by side; ones on the same server wait their turn (▶︎▶︎ Start Now runs a queued one at once).
- F3 / F4 open a file; the editor uploads it after every ⌘S, and closing with changes asks first.
- ↩ opens a file in its app (as does Quick Look's Open with); every save there goes up to the server the same way: if someone changed the file there meanwhile, you're asked first (Compare shows the differences), and so are you on a production server (once). An app that autosaves (TextEdit) sends its autosaves too — F4 is the safer choice on production. Quitting names what didn't reach the server; its copy is kept.
- F7 / ⇧F6 / F8 operate on the server.
- ⌃Q / ⌘Y preview the file under the cursor: it's fetched once the cursor rests on it (up to 64 MB; the copies stay until you quit, 256 MB of them at most). ⌘Y there shows the cursor's file, not the marked ones.
- ⌥Space (and Space on a folder) count folder sizes on the server, one folder after another; ⎋ stops it.
- ⌘⇧D compares a server's file with this Mac's or another server's: fetched as ⌃Q fetches it, and named `host:/path` in the diff.
- **File history:** every save of a server file (F4's ⌘S, a save in another app, a revert) first keeps the version it replaces on this Mac, in `~/.config/dfilemanager/history.noindex/<server>/<path there>/<name>@<date>` — 20 versions a file, 200 MB in all, the oldest going first; a file over 5 MB gets none (the status line says so). **Server File History…** (⌘⇧P or the File menu, on a server file or in its editor) lists them: ↩ / F3 view one, ⌘⇧D diffs it with the server's file now, ⌘D with the version before it, ⌘R reverts to it (a production server asks; a change made there since the list opened is asked about). The server's sidebar menu has **Show File History**, which opens that folder in the panel; F8 there deletes. The folder is owner-only and kept out of Spotlight and Time Machine; it holds whatever the files did (`.env`, keys) — turn it off with `defaults write com.dmn.dfilemanager serverHistory -bool false`.
- **As root:** **Open SFTP as Root** in a server's sidebar menu, or **Reopen Panel as Root** (⌃⌘R, Admin menu, ⌘⇧P; **Reopen Panel as User**, ⌃⇧⌘R, goes back) on a server panel. The panel's SFTP then runs through the server's own `sudo`, on the same connection: Kermo looks for `sftp-server` in the usual places (Debian/Ubuntu, RHEL/Fedora, Arch/Alpine, openSUSE, BSD/macOS) and runs `sudo -n -- <sftp-server>`. Nothing is installed on the server. The header and the window's title read `root@host:/path #`, the header in orange (red on a production server).
  - **sudo without a password:** allow it for `sftp-server` alone, e.g. `me ALL=(root) NOPASSWD: /usr/lib/openssh/sftp-server`. Be honest with yourself about what that is: `sftp-server` running as root can write any file, `/etc/sudoers` included, so this line is as good as full root for that user.
  - **sudo with a password:** asked for in a sheet when `sudo -n` refuses for want of one (never otherwise: a sudo that needs none would pass it to `sftp-server`). It's tried once on its own — the same `sudo -S -k -- <sftp-server>` with nothing after the password, so `sftp-server` ends at once — so a wrong one costs a single attempt in the server's log; then the session gives it to sudo on stdin — never on a command line or in a file. If sudo takes the password but doesn't allow `sftp-server` to the user, it says so at once. It's kept in memory for 5 minutes after its last use; the screen locking, sleep or Disconnect forgets it. **Save in Keychain** keeps it in the login keychain as "Kermo sudo: host", apart from the ssh password; it goes from there once sudo refuses it, with the saved server, or with **Forget the saved sudo password** in the server's Edit sheet. sudo-rs 0.2.2 can't take a password this way: set up NOPASSWD for it.
  - When sudo refuses, the panel says why: it needs a password, `Defaults requiretty` (old RHEL/CentOS; turn it off for the user), or no `sftp-server` (Alpine serves SFTP from sshd itself: `apk add openssh-sftp-server`).
  - Saves go the same way as the user's: the file history, the production question, "changed on the server since you opened it". New files, folders and copies belong to root:root, as with any `sudo`. On a server with SELinux (`/sys/fs/selinux`) a save writes into the file itself instead of renaming a new one over it, so the file keeps its label.
  - Root and the user are two accounts: F5 / F6 between a root panel and a user panel of the same server copy through this Mac, each side with its own rights. ⌘C / ⌘V carry the user's account, never root, and so does anything dropped from another app; a drag from a root panel to another Kermo panel stays root. Nothing pasted, dropped or restored opens a server as root. A locked server asks for Touch ID as for any connection.
  - Only the file operations run as root — and a save's check and reload (below): search, archives, Git status, the user menu, ⌘E and ⌃O run as the user. The command line says so: its prompt stays `user@host:/path $`, and on a root panel it reads "⌘E: shell command in this folder as user, not root".
- **Checks on save:** saving a server config checks it with the server's own tool. Nothing is installed there; a tool that isn't there is no check, and the status line says "no check for this file".
  - **Before it takes the file's place** — for files that stand alone. A save first writes the whole new text to a partial file next to the old one (`.dfm-partial-…`, which services don't read from their include folders); the check runs on that, and only if it passes does it replace the file. A failure leaves the file on the server as it was, shows what the tool said, and keeps your text unsaved in the editor. A check that couldn't run (sudo refused it) stops the save too: a broken `sudoers` would break `sudo -n` — and with it a root panel — even for a second.
  - **After, with the old text put back** — for configs with includes, which only the live tree can check. If the check fails, the text this save replaced goes back at once (a new file is removed), and the dialog says so. Not when someone changed the file in between (theirs stays) or it's over 5 MB (its old text isn't kept); then the dialog says that instead. The file history keeps the version the save replaced, not the bad one.

    | File | Check | When | Reload |
    |---|---|---|---|
    | `/etc/sudoers`, `/etc/sudoers.d/*` | `visudo -cf` | before | — |
    | `/etc/ssh/sshd_config` | `sshd -t -f` | before | `systemctl reload ssh` (or `sshd`) |
    | `/etc/ssh/sshd_config.d/*` | `sshd -t` | after | the same |
    | `/etc/haproxy/haproxy.cfg` | `haproxy -c -f` | before | `systemctl reload haproxy` |
    | `/etc/nftables.conf` | `nft -c -f` | before | — (apply it yourself: `nft -f`) |
    | `/etc/nginx/*` | `nginx -t` | after | `systemctl reload nginx` |
    | `/etc/apache2/*`, `/etc/httpd/*` | `apachectl configtest` | after | `systemctl reload apache2` / `httpd` |
    | `/etc/systemd/system/*.service`, `*.timer` | `systemd-analyze verify` | after | `systemctl daemon-reload` |
    | `/etc/postfix/*` | `postfix check` | after | `postfix reload` |
    | `/etc/bind/named.conf*`, `/etc/named.conf` | `named-checkconf` | after | `rndc reload` |
    | `compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml` anywhere | `docker compose config -q` | before | — |

  - **As root:** on a root panel the check runs through the server's `sudo` — `sudo -n`, or with the sudo password the panel uses (kept, or asked for), given on stdin, never in a command line; `sudo -n` is tried first every time. On a user's panel the checks that work only as root (`sudo`, `sshd`, `nft`, `nginx`, `postfix`) aren't run, and the status line says "check needs root — ⌃⌘R opens the panel as root". Each check is one ssh command over the panel's connection (two where sudo wants a password); with sudo, it's a line in sudo's log.
  - **Reload:** once a config passed its check, **Reload after saving …?** names the command and who runs it; **Compare** shows the save's change first (the text it replaced against yours). It runs as the check did; on a user's panel only reloads of your own rules are offered, since the built-in ones need root. On a production server the question says so, and ↩ answers Cancel. Its output shows only if it fails. When `Port` or `ListenAddress` changes in `sshd_config` and systemd listens for sshd (`ssh.socket`, Ubuntu 22.10 and later), a reload doesn't move the port, so the reload is `systemctl daemon-reload && systemctl restart ssh.socket` — the question warns that new connections go to the new port (this one stays).
  - **Your own rules** go in `~/.config/dfilemanager/validators.json` (**Edit Validators…** in the Kermo menu or ⌘⇧P starts it with an example), in the same shape, and are looked at before the built-in ones — the first that matches wins. `match` is a glob of the path on the server (`*` crosses `/`, so `/opt/app/nginx/*` is everything under it; without a `/` it matches the file's name anywhere); `check` a shell command run there, `%f` the file's path (quoted for you; `%%` is a `%`); `when` `"before"` (the default) or `"after"`; `reload` optional; `"root": true` for a check that works only as root. `"check": null` turns a check off for those paths. A file that doesn't parse leaves the built-in rules, and the status line says why. For example:

    ```json
    [
      { "match": "/etc/caddy/Caddyfile", "check": "caddy validate --adapter caddyfile --config %f", "reload": "systemctl reload caddy" },
      { "match": "/etc/prometheus/prometheus.yml", "check": "promtool check config %f", "reload": "systemctl reload prometheus" },
      { "match": "/opt/app/nginx/*", "check": "docker exec app-nginx nginx -t", "when": "after", "reload": "docker exec app-nginx nginx -s reload" },
      { "match": "/etc/nginx/sites-available/*", "check": null }
    ]
    ```
- **Production log:** on a server tagged production, what Kermo does there goes into `~/.config/dfilemanager/audit.jsonl`, a JSON line each — saves and reverts (and how their check ended), commands (⌘E, F2), copies, moves and deletes (F5, F6, F8, Synchronize), renames, permissions, new folders, extracting, reloads — with the time, the server (`"root": true` from a root panel), the paths, the command and its exit status. Read it with `grep` or `jq`, or **Show Production Log** (Admin menu, ⌘⇧P). A command line may hold a secret (`mysql -pXXX`, a token in a `curl` header): the file is owner-only, but it's a plain file on this Mac — turn it off with `defaults write com.dmn.dfilemanager auditLog -bool false`.

Git repositories show a status column, and the status bar displays the branch and ↑↓ indicators — also on an SFTP panel, when the server has git 2.26 or newer. The editor includes line numbers and syntax highlighting for shell, YAML, JSON, configuration files, XML/plist, Python, and more.

## Command-line launcher

Choose **Kermo ▸ Install “fm” Command** to create a link in `/usr/local/bin`. After installation, `fm` opens the current directory, `fm ~/a ~/b` opens both directories in two panels, and `fm /etc/hosts` reveals the file in its directory. Kermo also appears in Finder's **Open With** menu for folders.

Command-line and F2 menu placeholders:

- `%f` / `%F`: name / full path under the cursor
- `%s` / `%S`: marked items, or the item under the cursor
- `%d`: current directory
- `%D`: directory in the other panel

All substituted values are automatically escaped for the shell.

On a local panel ⌘E ↩ and F2 entries type the command into the ⌃O terminal's shell, as MC's subshell does: your aliases and functions, colors, `sudo` and `git commit` prompts, Tab completion and ⌃R all work, and the command lands in the shell's history. ⇧↩ runs it in an output window instead (no TTY, any file name), ⌘↩ and `"terminal": true` in Terminal.app. On a server panel ↩ runs over ssh in an output window and ⌘↩ opens an SSH tab with the command.

An entry in `usermenu.json` with `"server": true` shows only on a server panel (and `false` only locally). The default menu has `systemctl status` / `restart`, failed services and `journalctl` for the unit under the cursor; an existing `usermenu.json` isn't changed — copy them in, for example:

```json
{ "title": "Restart service", "command": "sudo systemctl restart %f && systemctl status --no-pager %f", "terminal": true, "server": true }
```

On a server tagged production, `systemctl stop` / `restart` asks first.

## Configuration

Configuration files are stored in `~/.config/dfilemanager/`: `keymap.json`, `usermenu.json`, `validators.json` (checks of server configs on save, see SFTP panel), `filters.json`, `bookmarks.json` (sidebar Favorites), and `frecency.json` (sidebar Frequent, ⌘P). `audit.jsonl` is the production log.

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

## Shell integration

The ⌃O terminal runs your login shell with `TERM_PROGRAM=Kermo`, so Apple's Terminal.app hook in `/etc/zshrc` doesn't load. Three lines in `~/.zshrc` bring it back, only inside Kermo:

```zsh
# ~/.zshrc — in Kermo's ⌃O terminal: the panel follows `cd`, the tab is named after the folder,
# and the ` cd` the app types stays out of your history.
if [[ $TERM_PROGRAM == Kermo ]]; then
  setopt HIST_IGNORE_SPACE
  source /etc/zshrc_Apple_Terminal   # Terminal.app's own `update_terminal_cwd` (OSC 7); nothing else without TERM_SESSION_ID
fi
```

Without it the panel still follows the shell's folder when you hide the terminal (⌃O), and the tab gets its folder's name when it's shown or switched to; with it both update on every `cd`. (fish, bash: not checked.)

The editor saves protected files such as `/etc/hosts` through **Save as Administrator**. The ⌘I Info window also offers administrator-authorized chmod and chown operations.

## License

Kermo is released under the [MIT License](LICENSE).
