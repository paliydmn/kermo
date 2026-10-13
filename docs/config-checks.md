# Checks on save and reloads

- **Checks on save:** saving a server config checks it with the server's own tool. Nothing is installed there; a tool that isn't there is no check, and the status line says "no check for this file" — so does a check that says "command not found" (exit 127), such as docker without its compose plugin.
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

  - **Copies aren't checked:** F5, F6 and drag and drop put a file in as it is. On a production server the question says so when it lands where a save would be checked first (sudoers, `sshd_config` …): open it with F4 and save it to have it checked.
  - **As root:** on a root panel the check runs through the server's `sudo` — `sudo -n`, or with the sudo password the panel uses (kept, or asked for), given on stdin, never in a command line; `sudo -n` is tried first every time. On a user's panel the checks that work only as root (`sudo`, `sshd`, `nft`, `nginx`, `postfix`, and `haproxy` and `apachectl`, which may read a key only root can) aren't run, and the status line says "check needs root — ⌃⌘R opens the panel as root". Each check is one ssh command over the panel's connection (two where sudo wants a password); with sudo, it's a line in sudo's log.
  - **Reload:** once a config passed its check, **Reload after saving …?** names the command and who runs it; **Compare** shows the save's change first (the text it replaced against yours). It runs as the check did; on a user's panel only reloads of your own rules are offered, since the built-in ones need root (the status line says "reload needs root"). On a production server the question says so, and ↩ answers Cancel. Its output shows only if it fails. When `Port` or `ListenAddress` changes in `sshd_config` and systemd listens for sshd (`ssh.socket`, Ubuntu 22.10 and later), a reload doesn't move the port, so the reload is `systemctl daemon-reload && systemctl restart ssh.socket` — the question warns that new connections go to the new port (this one stays).
  - **Your own rules** go in `~/.config/dfilemanager/validators.json` (**Edit Validators…** in the Kermo menu or ⌘⇧P starts it with an example), in the same shape, and are looked at before the built-in ones — the first that matches wins. `match` is a glob of the path on the server (`*` crosses `/`, so `/opt/app/nginx/*` is everything under it; without a `/` it matches the file's name anywhere); `check` a shell command run there, `%f` the file's path (quoted for you; `%%` is a `%`); `when` `"before"` (the default) or `"after"`; `reload` optional; `"root": true` for a check that works only as root. `"check": null` turns a check off for those paths. A file that doesn't parse leaves the built-in rules, and the status line says why. For example:

    ```json
    [
      { "match": "/etc/caddy/Caddyfile", "check": "caddy validate --adapter caddyfile --config %f", "reload": "systemctl reload caddy" },
      { "match": "/etc/prometheus/prometheus.yml", "check": "promtool check config %f", "reload": "systemctl reload prometheus" },
      { "match": "/opt/app/nginx/*", "check": "docker exec app-nginx nginx -t", "when": "after", "reload": "docker exec app-nginx nginx -s reload" },
      { "match": "/etc/nginx/sites-available/*", "check": null }
    ]
    ```
