[Kermo documentation](../README.md#documentation)

# Checks on save and reloads

Kermo checks a server config with the server's own tool before a bad save can break the service, then offers to reload it. Nothing is installed on the server.

## How a save is checked

Saving a server config (⌘S in the F4 editor, a save from another app, or a revert from the file history) runs the check for that file from the table below. A tool that isn't on the server is no check: the status line says "no check for this file". So does a check that answers "command not found" (exit 127), such as `docker` without its compose plugin.

**Before the file is replaced** — for files that stand alone:

1. Kermo writes the whole new text to a partial file next to the old one (`.dfm-partial-…`; services don't read those from their include folders). For a symlink, that's next to the file it points to.
2. The check runs on the partial file. Only if it passes does the new file replace the old one.
3. If it fails, the file on the server stays as it was, the dialog shows what the tool said, and your text stays unsaved in the editor.

A check that couldn't run (sudo refused it) stops the save too: a broken `sudoers` would break `sudo -n`, and with it a root panel, even for a second.

**After the save, with the old text put back** — for configs with includes, which only the live tree can check:

- If the check fails, the text this save replaced goes back at once (a new file is removed), and the dialog says so.
- It stays put when someone changed the file in between (theirs stays) or when the file is over 5 MB (its old text isn't kept). The dialog says which.
- If the check couldn't run (sudo refused or was cancelled), the save stays in place unchecked and the status line says "unchecked: …". Nothing is put back.
- The [file history](server-files.md#file-history) keeps the version the save replaced, not the bad one.

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

## Copies aren't checked

F5, F6 and drag and drop put a file in as it is. On a production server the question says so when the file lands where a save would be checked first (`sudoers`, `sshd_config` …). Open it with F4 and save it to have it checked.

## Root and user

On a **root panel** the check runs through the server's `sudo`: `sudo -n`, or the sudo password the panel uses (kept, or asked for), given on stdin and never on a command line. `sudo -n` is tried first every time.

On a **user's panel** the checks that work only as root aren't run: `visudo`, `sshd`, `nft`, `nginx`, `postfix`, and `haproxy` and `apachectl`, which may read a key only root can. The status line says "check needs root — ⌃⌘R opens the panel as root".

Each check is one ssh command over the panel's connection (two where sudo wants a password). With sudo, it is a line in sudo's log.

## Reload after a checked save

Once a config passed its check, **Reload after saving …?** names the command and who runs it. **Compare** shows the save's change first (the text it replaced against yours).

- The reload runs as the check did. On a user's panel only reloads of your own rules are offered, since the built-in ones need root (the status line says "reload needs root").
- On a production server the question says so, and ↩ answers **Cancel**.
- The reload's output shows only if it fails.
- When `Port` or `ListenAddress` changes in `sshd_config` or a file in `sshd_config.d/`, and systemd listens for sshd (`ssh.socket`, Ubuntu 22.10 and later), a reload doesn't move the port. The reload is then `systemctl daemon-reload && systemctl restart ssh.socket`, and the question warns that new connections go to the new port (this one stays).

## Your own rules

Choose **Kermo ▸ Configuration ▸ Edit Validators…** (or search) to open `~/.config/dfilemanager/validators.json`, which starts with an example. Your rules are looked at before the built-in ones; the first that matches wins.

| Key | Meaning |
|---|---|
| `match` | A glob of the path on the server. `*` crosses `/`, so `/opt/app/nginx/*` is everything under it. Without a `/` it matches the file's name anywhere. |
| `check` | A shell command run on the server. `%f` is the file's path (quoted for you); `%%` is a `%`. `null` turns the check off for those paths. |
| `when` | `"before"` (the default) or `"after"`. |
| `reload` | Optional command for the reload question. |
| `root` | `true` for a check that works only as root. |

```json
[
  { "match": "/etc/caddy/Caddyfile", "check": "caddy validate --adapter caddyfile --config %f", "reload": "systemctl reload caddy" },
  { "match": "/etc/prometheus/prometheus.yml", "check": "promtool check config %f", "reload": "systemctl reload prometheus" },
  { "match": "/opt/app/nginx/*", "check": "docker exec app-nginx nginx -t", "when": "after", "reload": "docker exec app-nginx nginx -s reload" },
  { "match": "/etc/nginx/sites-available/*", "check": null }
]
```

A file that doesn't parse leaves the built-in rules, and the status line says why.
