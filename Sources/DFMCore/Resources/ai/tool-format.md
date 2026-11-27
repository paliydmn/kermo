### The fields that work now

The smallest tool is three fields; it's in **Tools ▸** on every server, and its output opens in a window:

```json
{ "schema": 1, "id": "disk-usage", "title": "Disk Usage", "command": "df -h" }
```

| Field | Meaning |
|---|---|
| `schema`, `id`, `title` | `1`; the file's name without `.json`; the name in menus |
| `tool`, `icon`, `group`, `about` | The program's name ("Firewall (ufw)"); an SF Symbol (`wrench` if this macOS lacks it); a submenu of Tools ▸; one sentence for the overview |
| `requires` | A command that exits 0 where the tool can run: `command -v ufw`. As the login user, even with `sudo` |
| `sudo`, `where` | As root through sudo; `server` (default) or `mac` (this Mac's `sh`, never as root) |
| `command`, `script` | What runs, wherever something runs (the tool itself, an action, `list`, `poll`, `stream`, `requires`, a var): `command` is the shell text itself (`{name}` in it is Kermo's; `${HOME}`, curl's `%{http_code}` and awk's `{ print $1 }` stay the shell's); `script` is only the name of a file next to the tool's JSON (no `/`), for a long one |
| `list` | `command`, `script` or `files` (with `env`), and how its output becomes rows — `files`: a path on the server, `*` matching names in a folder (`{base}/state/*/deploy.json`), each file a row read over SFTP, as root through the server's sudo where the tool runs as root; `name` gets the file's folder's name, `also` (`files` and a `pattern` with named groups) adds fields from another file each row names (`{base}/conf/{unit}.yaml`) — `format` (`lines`, `json`, `jsonl`, `tsv`, `csv`, `table`, `regex`, `prometheus` — a record a sample line: `name`, its labels, `value` (a label called `name` or `value` is `label_name`, `label_value`) — or `nagios` — the whole run one record: `status` `ok` · `warn` · `crit` · `unknown` from the exit code, which then never counts as a failure up to 3, `message`, `perf.<label>`), `pattern`, `names`; `key` (what names a row), `title`, `subtitle`, `detail`, `state`, `columns` (as a dashboard table's: `tip` over a cell, `help` over a heading), `empty`, `sort` (`-cpu`: the most first), `limit` (500 rows unless set; more are said above the list), `every` (seconds: read again while the list shows, over the connection already there and only when nothing would be asked). The list's rows have the actions with no `rows`, `rows: "list"`, and those of the set its `json` `rows` reads — System's `procs`: the top processes' actions serve All Processes too |
| `header` | A command whose first line shows above the list |
| `actions`, `toolActions` | A row's actions and the tool's: `id`, `title`, `key` (`return`, `f8`, `cmd+e`…), `command` or `script`, `readonly` (a look), `dangerous` (can't be undone), `confirm` (asks everywhere), `message` (what the question says), `verify`, `multi` (on marked rows too), `refresh`, `only` (offered only on rows whose field has one of these values: `{ "kind": ["app"] }`), `output` (`line`, `window`, `follow`, `terminal`, `silent`, or `list`: rows one level down, read by the action's own `list` with its `actions` — without a `list` of its own it repeats the level it's on), `strip: "cri"`, `edit` (a server path for the editor), `open` (a server path shown in the active panel — `{stdout}` is the command's first line of output), `goto` (a place in Kermo: `services:{unit}`, `containers:{name}`, `ssh`), `done`, `save` (the name ⌘S offers for a window's output: `{server}-report.txt`). A tool with `toolActions` and no `list` lists its actions as its rows, as Server Info does |
| `long`, `progress`, `format` | `long: true`: a [long job](#long-jobs), on the server only. `progress` reads each line it prints: `{ "pattern": "(?<percent>\\d+)%" }` for text, `{ "percent": "pct" }` or `{ "fraction": "percent_done" }` for a JSON line, with `text` (a template of the line's fields) for its card; without it, a spinner and the last line. `format` (`jsonl`, `json`…): the last record of its output gives `done` its fields — `"done": "Backed up {files_new} files"` |
| `inputs` | An action's sheet: `name`, `type` (`text`, `secret`, `choice`, `choice-from`, and for a long action `folder` or `file` on this Mac — see [Long jobs](#long-jobs)), `title`, `placeholder`, `default`, `pattern`, `optional`, `options`, `remember` (a folder or a file: the last one chosen on that server and row fills the sheet); a `choice-from` has a `command` and a `key` (`{line}`) |
| `primary` | The tool action on the ＋ button |
| `version` | `command`, `pattern` with a group `v`, `tested` (`>=0.36 <0.37`) |
| `install`, `uninstall` | [Install](#install): a command per package manager — `apt` (apt-get's), `dnf`, `apk`, `pacman`, `zypper`, `brew` — or `script` (`url`, `env`, `sha256`, which it needs to run); `precheck` (`title`, `command`, `pattern` with a group `v`, `min`); `leaves` (`services`, `paths`, `ports`, `note`: what stays after Install); `docs`, `after` (the line it ends with); `uninstall` also `keeps` |
| `context` | [F2 on the server's files](#a-tools-files-f2-and-f4): `path` (a glob over the tool's vars, `*` within one folder: `{base}/conf/*.yaml`), `row` (the `key` of the list's row it's about, from the file: `{stem}` its name without the extension, `{file}` its path, `{dir}` its folder), `actions` (the row actions offered there, by id) |
| `validators` | Checks when such a file is saved: `path` (as `context`'s), `check` (a command with `{stem}`, `{file}`, `{dir}` — `{file}` is the file checked: the new text next to it for a `before` check), `when` (`before`, the default: the new text is checked before it takes the file's place; `after`: the file in place, its old text put back if the check fails). As root where the tool is |
| `accepts` | `"text"`, on a tool action: it's in [Send To…](#send-to), the text on its input; it has a `command` or `script`, its `output` a `line`, a `window` or `silent` |
| `vars` | Values per server, `{name}` in commands: `title`, `default`, `placeholder`, `pattern`, and one source — `command` (its first line, read once per connection) or `"ask": true` (asked on a saved server, kept in `tools/servers.json`; see [Where a tool is used](#where-a-tool-is-used)) |
| `timeout`, `exitOk` | Seconds (30 by default); exit codes that count as success (`[0]`) |
| `stream`, `poll`, `watch` | [Watching](#watching-a-server): a `stream` runs on and prints a record (a `jsonl` line, or a frame — `split`) every so often; a `poll` runs again every `watch.every` seconds; the tool's `list` is read that often too where `rows: "list"` takes its rows. `watch`: `every` (seconds, 1 to 10 years — so is every duration, `for` and a range), `down` (missed samples that make "not answering", 3) |
| `metrics` | Named numbers of a sample: `title`, `path` (`cpu.pct`), `unit` (`%`, `B`, `B/s`, `ms`, `s`, `h`, `days`, `/min`), `max`, `detail` (a template), `rows` + `key` (one series per row: disks by `mount`; `"list"`: the tool's list), `count: "state"` (rows by state), `calc` (`rate`: a counter's change per second; `age`: now minus the time at `path`, by the server's clock) |
| `alerts` | `id`, `metric`, `warn`, `crit`, `below` (low is bad), `for` (`{ "warn": "10m", "crit": "5m" }`) or `checks` (samples in a row), `message` (a template with `{value}` and the row's fields) |
| `events` | `id`, `level` (`info`, `warning`, `critical`), `message`, `goto`; `path` or `rows` + `key` + `field`; `when`: `changed`, `increased`, `added`, `left` (from `from`), `is` (`value`); `if` / `unless` (a field non-empty / empty). A record's own `"_event": { "id", "level", "message" }` is an event too, at most 10 an hour |
| `summary`, `dashboard` | The server's row in WATCHED: `metric`, `as` (`bar`, `count`, `text`), `of` (`max`, `sum`, `min`, `avg`), `label`. `dashboard`: blocks top to bottom, a `row` side by side — `{ "stat": "cpu" }` a tile (`["rx", "tx"]` two in one, `of`, `also`); `{ "charts": [["cpu"], ["rx", "tx"]] }` small multiples on one time axis — a chart of several metrics takes the first one's unit and thresholds — if their units differ, the chart says "units differ" and Problems warns; a metric named twice in one chart is an error; six series a chart, the first by name till you pick (`range`: `1h` is the hour in memory — Kermo adds `15m` before it —, longer ones the history on disk; `log`: Log for This Time, the action run with `{from}` / `{to}` — five minutes round a moment, a slot's 15 on the history, a stretch dragged); `{ "table": "procs" }` the rows of a row set as the last sample that had them (`title`, `key` — what names a row, `"{pid}.{start}"`, so the selection stays on it as its numbers change, `columns` as a list's — `"cpu:%"`, or `{ "field": "pct:bar", "title": "Used" }`, with `tip`, a template the pointer over a cell shows instead of its text, never copied (`"{args}"`), and `help`, the header's tooltip — `actions`: ids of actions with that `rows`, whose keys are that table's own; `list`: a button by its title opening the tool's list — `"All Processes…"`; an action run on a table's row reads no list after it, its command checks the row itself); `{ "events": true }`; `{ "counts": [{ "rows", "title", "goto" }] }` |

Placeholders in braces, `{ip}`, take a sheet's values first, then a row's fields; `{server}`, `{host}` and `{user}` are Kermo's. A command given as an array of parts, `["ufw allow {port}", "comment {comment}"]`, leaves out a part whose value is empty.

### Recipes

Each is a whole file for `~/.config/dfilemanager/tools/` (or **New Tool…**), short on purpose; the built-in tools' files (**Show File** on their pages) are longer examples.

**A list with actions, a state and a sheet** — nginx's sites, which are on, and a new one:

```json
{
  "schema": 1, "id": "nginx-sites", "title": "nginx Sites", "tool": "nginx", "sudo": true,
  "about": "The sites in sites-available, which are on; turn one on or off, edit one, add one.",
  "requires": "command -v nginx",
  "list": {
    "command": "cd /etc/nginx/sites-available && for f in *; do [ -e ../sites-enabled/\"$f\" ] && echo \"$f on\" || echo \"$f off\"; done",
    "format": "regex", "pattern": "^(?<site>\\S+) (?<on>on|off)$",
    "key": "{site}", "title": "{site}", "subtitle": "{on}",
    "state": { "field": "on", "ok": ["on"], "off": ["off"] }
  },
  "actions": [
    { "id": "edit", "title": "Edit", "key": "return", "edit": "/etc/nginx/sites-available/{site}" },
    { "id": "on", "title": "Turn On", "only": { "on": ["off"] },
      "command": "ln -s ../sites-available/{site} /etc/nginx/sites-enabled/ && nginx -t && systemctl reload nginx", "done": "{site} is on" },
    { "id": "off", "title": "Turn Off…", "confirm": true, "only": { "on": ["on"] },
      "command": "rm /etc/nginx/sites-enabled/{site} && systemctl reload nginx", "done": "{site} is off" }
  ],
  "toolActions": [
    { "id": "new", "title": "New Site…", "key": "cmd+n",
      "inputs": [ { "name": "name", "type": "text", "title": "Name", "placeholder": "example.com", "pattern": "[a-z0-9.-]+" } ],
      "command": "cp /etc/nginx/sites-available/default /etc/nginx/sites-available/{name}", "done": "{name} added: Edit it, then Turn On" }
  ],
  "primary": "new"
}
```

Edit opens the file as root, and saving it runs Kermo's own nginx check. A value goes into a command as one word, whatever it holds: `{site}` needs no quotes.

**A long job** — an upgrade that runs on without Kermo, in Activity:

```json
{
  "schema": 1, "id": "upgrade", "title": "Upgrade", "tool": "apt-get", "sudo": true,
  "about": "What an upgrade would change, and the upgrade itself.",
  "requires": "command -v apt-get",
  "toolActions": [
    { "id": "list", "title": "What Would Change", "key": "return", "readonly": true, "command": "apt-get -s upgrade | grep '^Inst'", "exitOk": [0, 1], "output": "window" },
    { "id": "upgrade", "title": "Upgrade All…", "confirm": true, "long": true,
      "command": "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade", "done": "Upgraded" }
  ]
}
```

**A number to watch** — a poll every minute, its chart, an alert:

```json
{
  "schema": 1, "id": "mail-queue", "title": "Mail Queue", "tool": "postqueue",
  "requires": "command -v postqueue",
  "poll": { "command": "printf '{\"queued\": %d}\\n' \"$(postqueue -j | wc -l)\"", "format": "json" },
  "watch": { "every": 60 },
  "metrics": { "queued": { "title": "Queued mail", "path": "queued" } },
  "alerts": [ { "id": "queued", "metric": "queued", "warn": 100, "crit": 1000, "for": { "warn": "10m" }, "message": "{value} messages queued" } ],
  "summary": [ { "metric": "queued", "as": "text", "label": "{value} queued" } ],
  "dashboard": [ { "row": [ { "stat": "queued" } ] }, { "charts": [["queued"]] } ]
}
```

Its tab is live while open; **Watch in Background…** keeps it with the alert.

**Install** — added to a tool, its program installed where it's missing, from the tool's page:

```json
"install": {
  "apt": "apt-get install -y restic", "dnf": "dnf install -y restic", "apk": "apk add restic",
  "leaves": { "paths": ["/usr/bin/restic"], "note": "Only the program: no service, no repository." }
},
"uninstall": { "apt": "apt-get remove -y restic", "dnf": "dnf remove -y restic", "apk": "apk del restic", "keeps": "your repositories" }
```

### Tools that help

A tool can work in Kermo's own places instead of a list. Deployments' F2 actions and its check on save:

```json
"context": [ { "path": "{base}/conf/*.yaml", "row": "{stem}", "actions": ["deploy", "check", "inspect"] } ],
"validators": [ { "path": "{base}/conf/*.yaml", "check": "dpl check {stem}", "when": "after" } ]
```

A tool like these has no list of its own, so Tools ▸ doesn't show it: **Use on Servers…** on its page (My Tools in the Tools window) puts it to use. And one with nothing but a Send To… target — the lines of an output window that say error or fail, found on the server:

```json
{
  "schema": 1, "id": "errors", "title": "Errors",
  "toolActions": [
    { "id": "count", "title": "Errors and Failures", "accepts": "text", "readonly": true,
      "command": "grep -inE 'error|fail' || echo 'none'", "output": "window" }
  ]
}
```

### With an AI assistant

In Kermo, **New Tool… ▸ Make with AI…** does this with your own AI. Any assistant can write a tool for you: give it this page from [The fields that work now](#the-fields-that-work-now) to here (the recipes and the example below show it the shape), the program's `--help`, and a few lines of its real output — what `--json` prints, if it has that — and say what you want: a list of what, which actions, which change things. Paste its answer into **New Tool…**: **Problems** says what doesn't fit, with its line, as you type; **Test on** a server runs its list there and shows the rows it made of the real output — and every line that didn't fit — before any of its actions can run. Saved, it still runs nothing until **Use the tool “…”?** has shown you everything it can run.

Take out of the sample what you don't want to send: host names, paths, addresses.

### Example: restic backups

A whole tool of the kind you'd make with New Tool…: restic's snapshots on a server, a snapshot's files, a restore, a check of the repository, and an alert when the last backup is late. Its repository and password file are asked once per server (**Set Up on web-01…**) and go to restic as variables; nothing secret is in the file. Its commands follow restic's documentation and weren't run against a real repository: try it with **Test on** your server first.

```json
{
  "schema": 1,
  "id": "restic",
  "title": "Backups",
  "tool": "restic",
  "where": "server",
  "about": "restic snapshots on a server: when the last one was made, what's in it, restore files; alerts when a backup is late.",
  "icon": "externaldrive.badge.timemachine",
  "group": "Backup",
  "author": "you (made with New Tool…)",
  "requires": "command -v restic",
  "sudo": true,

  "vars": {
    "repo": { "title": "Repository", "ask": true, "placeholder": "/backup/restic or sftp:backup@host:/srv/restic" },
    "passfile": { "title": "Password file on the server", "ask": true, "default": "/root/.restic-password" }
  },
  "env": { "RESTIC_REPOSITORY": "{repo}", "RESTIC_PASSWORD_FILE": "{passfile}" },
  "version": { "command": "restic version", "pattern": "restic (?<v>\\d+\\.\\d+\\.\\d+)", "tested": ">=0.16" },

  "list": {
    "command": "restic snapshots --json",
    "format": "json",
    "key": "{short_id}",
    "title": "{time:datetime}",
    "subtitle": ["{short_id}", "{paths}", "{tags}"],
    "detail": "{hostname}",
    "sort": "-time",
    "columns": ["time:datetime", "short_id", "paths", "tags", "hostname"],
    "empty": "No snapshots in {repo} yet"
  },
  "actions": [
    { "id": "files", "title": "Files", "key": "return", "readonly": true, "command": "restic ls {short_id} | head -500", "output": "window" },
    { "id": "restore", "title": "Restore to…", "key": "f5", "long": true, "confirm": true,
      "inputs": [
        { "name": "path", "type": "text", "title": "Only this path (empty: everything)", "optional": true, "placeholder": "/etc/nginx" },
        { "name": "target", "type": "text", "title": "Into this folder on the server", "default": "/tmp/restore-{short_id}" }
      ],
      "command": ["restic restore {short_id} --target {target}", "--include {path}"],
      "message": "Files are written into {target}; nothing in place is overwritten unless {target} is /.",
      "output": "window", "done": "Restored {short_id} into {target}" }
  ],
  "toolActions": [
    { "id": "check", "title": "Check Repository", "long": true, "readonly": true, "command": "restic check", "output": "window" }
  ],

  "poll": { "command": "restic snapshots --latest 1 --json", "format": "json" },
  "watch": { "every": 3600 },
  "metrics": {
    "age": { "title": "Last backup", "rows": "poll", "key": "paths", "path": "time", "calc": "age", "unit": "h" }
  },
  "summary": [ { "metric": "age", "as": "text", "of": "max", "label": "last {value} h ago" } ],
  "alerts": [
    { "id": "late", "metric": "age", "warn": 26, "crit": 50, "message": "{paths}: the last backup was {value} h ago" }
  ],
  "dashboard": [
    { "row": [ { "stat": "age", "of": "max" } ] },
    { "table": "list", "title": "Snapshots", "columns": ["time:datetime", "short_id", "paths", "tags", "hostname"], "actions": ["files", "restore"] }
  ]
}
```

- **The list** is `restic snapshots --json`, newest first; ↩ **Files** lists a snapshot's first 500 paths in a window.
- **Restore to…** (F5) asks for a folder on the server, and optionally one path to take; it always asks first, says it writes only into that folder, and runs as a long job.
- **Check Repository** runs as a long job too: a big repository takes a while.
- **Watching** reads the newest snapshot every hour; its age is a number (`calc: "age"`, by the server's clock), late after 26 hours, critical after 50.
