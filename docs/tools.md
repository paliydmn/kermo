[Kermo documentation](../README.md#documentation)

# Tools

A tool turns a program on a server into a list with actions, as [Services…](servers.md#services-and-containers) does for systemd. Kermo comes with three:

- **Firewall (ufw)**: the rules, what's allowed and what's denied, and from where;
- **Banned IPs (fail2ban)**: the addresses fail2ban has banned, by jail;
- **Server Info**: a report of the machine for support, its load now and as it goes, disks, traffic, GPU, the busiest processes.

A tool is a JSON file, a *preset*. Kermo has no code for any particular tool: the built-in ones use only what a preset of your own can.

## Where tools show

A server shows the tools whose program it has (and that you [use there](#where-a-tool-is-used)):

- **Tools ▸** in its row's menu in the sidebar, in a server folder's menu in a panel, and **Server ▸ Tools** in the menu bar (for the active panel's server): "Firewall (ufw)", "Banned IPs (fail2ban)". A click lists it in [search](window.md#search), on the server's overview (**web-01 › Firewall ›**), as Services… does.
- A row each in the server's [overview](servers.md#the-server-as-a-place): **Firewall**, **Banned IPs**, with how many rows the list had when it was last read (`20 rows`), shown while a connection is up; `—` till then. ↩ shows the list in that panel, ⌘↩ in the other.
- Search finds them by name too, once Kermo knows the server has them: `fire web` finds **Firewall — web-01**.
- [The Tools window](#the-tools-window): a page for each server, its tools as tabs.

**What a server has is asked once its connection is up** — one short run that checks for every tool's program at once (`command -v ufw`), as the login user, and learns the system ("Fedora 44 · dnf"). Kermo never logs in for a menu: with no connection, **Tools ▸** says **Connect to see tools**. Once known, the tools stay in the menu greyed, with **As of 14:02**, after the connection closes — for a saved server across restarts too (`tools/known.json`; deleting it only means asking again). Server Info needs no program of its own, so every server has it.

## The Tools window

**Window ▸ Tools** (⌃⌘T) opens it on the active panel's server; **Open in Tools Window**, last in a server's **Tools ▸**, on that server. Its sidebar lists your saved servers (production in its color, a locked one with its lock), then servers connected now, and the library: **Built into Kermo**, **My Tools** and **[New Tool…](#new-tool)**. ↩ or a double-click on a library row opens the tool's page: who made it, its version and the sha256 its trust goes by; what it runs, grouped as **Use the tool “…”?** shows it (a dangerous action in red); and each saved server — whether it has the program, whether the tool is used there, its values set or **Set Up…**. Its buttons: **Use on Servers…**, **Show File**, and **Edit** for yours, **[Customize](#customize-a-built-in-tool)** for a built-in one.

A server's page has its name, the open tab's line from the program (`jails: sshd · 1.0.2`, a version outside what the tool was tested with), **Terminal** (an SSH tab in the main window) and **⋯**. Its tabs are the tools it shows, ⌘1…⌘9:

- **A list** stays in the main window: **Open in Panel** shows it in the active panel, **Open in Search** in search, with the same rows, keys and questions as anywhere else.
- **Buttons** (Server Info): each runs its action as its row does — the question on production, the line under the buttons saying how it went, its window where it has one. One that can't run here is greyed, saying why.
- **A one-command tool**: one button.

A server that isn't connected shows the tools it had when Kermo last saw it, greyed, and **Connect**: Kermo doesn't log in to draw a page. **＋** after the tabs lists the library's other tools: one hidden on this server shows again, one the server hasn't got is greyed. **⋯** has **Open in New Window** (the page as a window of its own; several servers' at once), **Use … on Servers…**, the tool's file, and **Hide … on web-01**. The windows don't reopen after a restart.

### Where a tool is used

A tool shows on every server where its program is found. **Use on Servers…** (a library row's button, the tool's page, or ⋯ on a server's page) changes that: **Every server where ufw is found**, the saved servers unticked having it hidden, or **Only on the servers checked below**. Each server says whether it has the program, hasn't, or wasn't checked yet. **Hide** takes a tool off one server; ＋ or Use on Servers… shows it again. Tools ▸, the overview's rows, search and the Tools window all go by it. Nothing changes on a server: it's what Kermo shows.

A tool can ask for a value per server (`vars` with `"ask": true`), say a backup repository's path. It shows on a saved server as **Backups — Set Up on web-01…** until you set it: a sheet with a field for each value, checked as you type. The values stay with the server in Kermo, not in the tool's file. A server that isn't saved has no settings: it shows the tools used wherever they're found, and none that ask for a value.

These settings are in `tools/servers.json`, by the saved server's id:

```json
{
  "servers": {
    "6F1C2A4E-…": { "ufw": { "hidden": true }, "restic": { "vars": { "repo": "/backup/restic" } }, "system": { "watch": true } }
  },
  "only": { "restic": ["6F1C2A4E-…"] }
}
```

### Watching a server

A tool with a `stream` (**System**: CPU, memory, load, disks, network and disk I/O, the busiest processes, failed services and containers, read-only from `/proc`, `df` and `ps` every 5 seconds) has a live tab on a server's page. Opened on a connected server, the tab is **live while open**: the stream runs on the server while the tab shows, its numbers in tiles with the tool's thresholds, and ends there when you leave the tab or close the window. Nothing logs in to draw it: a server that isn't connected shows **Connect**.

**Watch in Background…** (⋯ on the page, **Watch…** in a saved server's menu in the main window, **Server ▸ Watch Server…**) keeps it running without a window, with alerts: the sheet says what goes to the server and how often, the tool's rules, and that the connection stays open while the server is watched — it shows in `w` and `last` there. Only a saved server is watched (`"watch": true` in `tools/servers.json`), and watching resumes by itself when Kermo starts. **Stop Watching** ends it; an alert that was standing goes without a word — a stop is no recovery.

The Tools window's sidebar then starts with **WATCHED**: each watched server with its worst state as a shape — a triangle for a warning, an octagon for a critical alert, a dot when fine, a ring while paused or waiting for a login — and its tools' summary (CPU, memory and the fullest disk as bars with their thresholds), problems first; the rest under **OTHER SERVERS**. A tab with an alert standing shows the mark instead of its icon.

How watching behaves:

- **Alerts** come from the tool's rules: CPU over 85 % for 10 minutes is a warning, over 95 % for 5 minutes critical, a disk over 85 % a warning at once. One line per change for the worse; **back to normal** only when a real sample says so. A gap — the Mac asleep, the connection dropped, the server not answering — keeps every alert as it was: nothing recovers through a gap.
- **Drops.** When the connection goes (sleep, a network change, ⌘Q of the shared connection), the series get a gap and Kermo reconnects after 2, 5, 15, 30, then 60 seconds, one server after another. No sample for three intervals is **not answering** (critical) — unless this Mac has no network, or woke less than a minute ago.
- **Login.** A watched server logs in without a dialog: a key, or a password saved in the Keychain. One whose login would ask — a password not saved, a passphrase, a host key to confirm — isn't logged in behind your back: its row says **needs login**, and a click on **Connect** in its tab logs in once, as any look does.
- **A locked server** is watched read-only, without Touch ID, and its connection stays open while it's watched — after the Mac sleeps or locks, watching resumes by itself. The lock guards actions in Kermo (Stop, Kill, a panel), not the connection.
- **An hour** of each series stays in memory; events (a reboot, an OOM kill, a service that failed, a container that left `running`) are listed per tool. A longer history, notifications and the menu bar come with a later release.

**The dashboard.** Under System's tiles, the last hour as charts — CPU, memory, traffic in and out, disk reads and writes — on one time axis: a stretch where the Mac slept, the connection dropped or the server didn't answer is a band saying so (never zeros), the tool's thresholds are dashed lines, the hour's events sit on the axis, and a hover shows the values at that moment in each chart's header. A click on a chart opens the server's journal for the five minutes around it (**Log for This Time**: warnings and worse, and the kernel's lines). Below: the busiest processes and the disks as tables, each row with its actions — **Open Folder** (the process's folder in the active panel), **Open Files**, **Stop…**, **Kill…**; **Biggest Folders** comes with a later release — then the events of the tool and of watching itself, newest first, with **Services…** or **Containers…** where one leads there, and the counts of failed services and containers. A row's action goes the way every action does: Touch ID on a locked server, the question on production (always for Kill…), the line under the page saying how it went. The 24h and 7d ranges wait for the history on disk.

## A tool's list

A tool's list works as Services… does, in search and in a panel: ↑↓, typing filters, ⌃↩ (or a right-click) its row's menu, ⌘↩ the same rows in the other panel, Refresh reads it again. Each row has a state mark with its color — ● green, ○ orange, ◆ red, a grey dot — and what's in trouble comes first. The line above the rows comes from the program (`Firewall active · default: deny (incoming)`), and says so when:

- there are more rows than the list shows ("shown 500 of 812");
- the server's clock is over a minute off;
- the program's version is outside what the tool was tested with (asked once a session).

A row's menu has the row's actions, the tool's actions, then **Copy** (the row as text) and **Show ufw.json** (the tool's file). An action that can't run now is greyed out, and its tooltip says why. In a panel, the tool's main action is a button over the columns: **＋ Allow Port…**, **＋ Ban Address…**.

An action whose title ends in **…** asks for something first, in a sheet over the list: a field for each value — a menu for a choice, dots for a secret. What's wrong is said under the field as you type (an empty port, `http` where a number goes), and the button waits until it's all right. **Will run:** under the fields shows the command with what you typed, a secret as `•••`. A choice from the server (fail2ban's jails) is read as the sheet opens; if that fails, its field says why. A field you may leave empty takes its part of the command with it (an empty comment: no `comment` at all). Cancel: nothing runs.

### Firewall (ufw)

| Key | Does |
|---|---|
| ↩ | **Status in Full**: `ufw status verbose` in a window |
| ⌘N | **Allow Port…**: a port or a range, the protocol, from where (`any`, an address or a network), a comment |
| ⌘B | **Block Address…**: an address or a network, a comment; the rule goes first, ahead of what allows |
| F8 | **Delete Rule…**: deletes the rule under the cursor |

Its menu also has **Turn Firewall On…** and **Turn Firewall Off…**. An inactive firewall is a list with no rules; with no row under the cursor, ⌃↩ (in search: **⌃↩ Actions** on the bar) has the tool's own actions all the same. Deleting, and turning it on or off, always ask first. **Delete Rule…** acts on the rule under the cursor only, never on marked rows: ufw numbers its rules, and the numbers move after each delete. Before it deletes, Kermo reads the rules again; if that number is now another rule, nothing is deleted and the line says "the list changed".

### Banned IPs (fail2ban)

| Key | Does |
|---|---|
| ↩ | **Who Is It?**: `whois` for the address, on this Mac, in a window |
| ⌘N | **Ban Address…**: an address, and the jail, from fail2ban's own list |
| ⌘J | **Jail Status…**: `fail2ban-client status` of a jail, in a window |
| ⌘L | **fail2ban Log**: the log as it goes, in a window of its own; in a panel, next door (Quick View) |
| F8 | **Unban**: from the jail that banned it |

Its menu also has **Unban from Every Jail**. The line above the rows lists the jails and fail2ban's version.

### Server Info

Server Info has no list: its rows are what it can show, and ↩ on a row runs it. The line above them is the server's name, its kernel and how long it's been up. Nothing needs root, and nothing changes on the server.

| Row | Key | Shows |
|---|---|---|
| **Full Report** | | Host, OS, CPU, memory, disks, GPU, network, the busiest processes and failed services, in a window — ⌘S saves it as `web-01-report.txt` to send |
| **CPU · RAM Now** | ⌘L | `uptime`, `free -h` and `top`'s first lines |
| **Live Load** | | `vmstat 2` as it goes, in a window of its own; in a panel, next door |
| **Disks** | | Mounted file systems by use, and the disks with their sizes and models |
| **Traffic (5 s)** | | Each network interface's download and upload over 5 seconds |
| **GPU** | | `nvidia-smi`, else the graphics devices `lspci` sees |
| **Top Processes** | | The busiest by CPU |

A command that isn't on the server says so in its window (`lsblk: not available here`) instead of leaving it empty.

The keys work in search. In a panel a row's key works where it's one of Kermo's own command keys (↩, F8, ⌘L, ⌘J); the others (⌘N, ⌘B) are on the ＋ button and in the row's menu (⌃↩).

## How an action runs

1. **A locked server** asks for Touch ID first. An action that runs on this Mac (Who Is It?) doesn't reach the server and doesn't ask.
2. **The sheet** of an action that asks for something (above).
3. **The question**, when there is one:

   | Action | Asks |
   |---|---|
   | One that can't be undone (Delete Rule…, Turn Firewall Off…) | Always. Its button is red, ↩ is Cancel |
   | Any other change, on a [production server](safety.md#production-servers) | Yes — with **Don't ask again for this tool on web-01 for 10 minutes** |
   | Any change on a server marked **Read-only** | Doesn't run: only looks do there, the rest greyed, saying so |
   | A look (Status in Full, Who Is It?) | Never, production included |
   | Any other change elsewhere | No |

   The question shows the command with its values filled in, and how and where it runs (as root, through the server's sudo). **Show Exactly What Runs** shows what Kermo sends, then asks again. The 10 minutes are for that tool on that server only, and end with Kermo or with a change to the tool's file; what can't be undone asks every time.
4. **The run.** The row says what runs on it, with a spinner. Another change of the same tool on that server waits for it ("Firewall on web-01 is busy: Delete Rule"); looks run alongside.
5. **How it went**, in a line under the list: "Deleted rule 3 (80/tcp) on web-01 at 14:02:11", or ✕ and the first line of what the program said, with **Output…** for all of it. With the list closed, the status line says it. A program that isn't on the server is said so: "apt-get isn't on web-01 (Fedora 44 · dnf)".
6. **The list is read again** after a change, the cursor staying on its row, or going to the next one if that row is gone. A look reads nothing again.

What opens a window or a tab of its own goes there instead of the line: a window of output, a log that follows (closing it ends the command on the server), a command in an SSH tab, a file in the editor (as any server file: history, checks, production's question on save). In a window of output, **⌘C** with nothing selected copies all of it, and **⌘S** saves it as a text file.

⎋ stops the wait. A run that takes over 30 seconds, or gives over 16 MB of output, is stopped and says so; when the connection drops, the run ends on the server too, leaving nothing behind. Tools use at most 9 of a connection's sessions at once (OpenSSH allows 10; past them ssh would log in again): one more waits, and the status line says so.

## Long jobs

An action marked `long` — a deploy, a backup, an upgrade — runs on the server on its own, and Kermo follows it:

- **It starts and comes back at once.** The line under the list says so ("Deploy: started on web-01 at 14:02 — it runs on there; Activity (⌥⌘J) follows it"), and its row spins while it runs. Starting it again on the same row says it's already running and shows Activity. The tool isn't busy meanwhile: its other actions run.
- **Activity (⌥⌘J)** has a card for it: its progress (or a spinner) and the last line it printed, **Show** (its output in a window, more as it comes; closing the window stops nothing) and **Stop…**. Once it's over: ✓ or ✕ and how it went, **Retry** (the same action with the same values, asked as any run; a secret is asked again), **Show Log** and ✕. The toolbar's ring and the Dock count it along with copies.
- **It runs on without Kermo.** When the connection drops, the Mac sleeps or Kermo quits, the job goes on. Its card says "connection lost — the job runs on", or after a relaunch "connect to web-01 to see how it goes"; once a connection to that server is up, Kermo follows it again. It never logs in just for that.
- **Stop…** asks on production, then stops the job and everything it started (its process group; a root job's through sudo).
- **When it ends** while Kermo isn't in front, after more than a minute, a macOS notification says how it went; clicking it shows Activity. Kermo asks to send notifications when you start your first long job. If they're off, the Dock's badge and the card tell you instead.

On the server a long job runs as the login user in a session of its own (`setsid`; perl's or python3's where there's none), with sudo only around its command; a sudo password is checked before the job starts and goes to sudo through a pipe. Its output goes to `~/.cache/kermo/runs/<id>.log` (the folder is the login user's, `0700`), its exit status to `<id>.exit`. A job's files are removed a week after it ended, when the next long job starts on that server. Kermo keeps the jobs it started in `tools/runs.json` on this Mac.

## Safety

- **A secret** you type goes to the server in the command's input only: never on a command line, on screen, in Output… or in a log — `•••` there.
- **A value never becomes part of a command.** An address from the list, `203.0.113.7`, reaches `fail2ban-client set sshd unbanip` as one argument, whatever it holds. A value that begins with `-` (it would be read as an option) or holds a line break isn't put into a command at all: the action is greyed, saying why. On this Mac a value from the server may hold only letters, digits and `._:/@%+=,-`.
- **The same environment on every server:** the command goes to `sh` on its input, never to the login shell, with `LC_ALL=C` (no translated output) and `/usr/sbin` and `/sbin` on the `PATH`.
- **As root:** a tool that needs root runs through the server's `sudo`, `sudo -n` first. When sudo wants a password, Kermo asks for it as a [root panel](root-panel.md) does; the password goes to sudo on its input, never on a command line, and is shown as `•••` anywhere it could appear.
- **The production log:** each run on a production server is a line in the [production log](safety.md#production-log): `"action": "tool ufw delete"`, what was sent and its exit status.
- **Nothing stays on the server** but a long job's log: no other files, nothing installed. A run ends with its connection; only a [long job](#long-jobs) runs on, and its log stays in `~/.cache/kermo/` there for 7 days.

## Your own tools

Put a tool's JSON file in `~/.config/dfilemanager/tools/`, with any script it names next to it. A file is read only if it's yours and neither its group nor others can write it (`chmod go-w`); otherwise it isn't loaded, saying why. A file of yours with a built-in tool's `id` takes that tool's place; if it has an error, the built-in one stays.

**Kermo ▸ Configuration ▸ Reload Config** reads the folder again and lists what's wrong with each file, with its line: `tools/my-tool.json: line 3: …`. An unknown field is an error, not something left out: it might be a safety field.

My Tools in [the Tools window](#the-tools-window) lists a file of yours that doesn't load under the table, with why; a click opens it in the editor.

A tool of yours runs nothing — not even its check of the server — until you say to use it. **Tools ▸** lists it under **Not in use yet**; choosing it asks **Use the tool “…”?** with everything it can run: what runs by itself (its check, its header, its list, its choices) and what runs when you choose (its actions), each marked where it runs as root. A read-only action whose command looks destructive (`rm`, `kill`, `--force`, `>`…) is pointed out. **Open File** shows the file and its scripts. **Use This Tool** keeps your answer in `tools/trust.json`, by the file's and its scripts' sha256: a change to any of them asks again.

### New Tool…

**New Tool…** in the Tools window's library asks for a name — the file's name comes from it, `Disk Check` → `disk-check.json`; one that's there already, or a built-in tool's, won't do — and what to start from:

- **List with Actions**: rows from a command's output, an action on a row (it starts as the mounted filesystems, `df -P`);
- **Buttons**: commands that run when pressed, each its own button (`uptime`, `free -h`);
- **One Command**: one command, its output in a window (`who`).

Each starter works as it is on most Linux servers. It opens in Kermo's editor, not yet on disk; **⌘S** (or **Save** beside the text) writes it to `~/.config/dfilemanager/tools/` readable only by you, reads your tools again and asks **Use the tool “…”?** — then, for a new tool, **Use on Servers…**. Saving again asks again: it's a new version of the file. A tool with no script needs nothing else; one that names a script needs that file next to it.

Beside the text:

- **Problems**: the file checked as Kermo loads it, as you type — errors (it isn't loaded: an unknown field, a missing script, an `id` that isn't the file's name…) apart from warnings (it loads: a placeholder in quotes, `sudo` without `about`…), each with its line; a click selects that line. A file saved with an error isn't loaded, and **Reload Config** says why too.
- **Test on** a server **connected now**: runs what the tool runs by itself — its `vars` commands, its check (`requires`, its actions' too), its header, its version, its list — and never one of its actions. It shows whether each check passed, the header line, the version against `tested`, the first rows the list made, their fields, and every line of the output that didn't fit the pattern, with the exit status and stderr of what failed. Test never logs in: connect the server first. Its first run says exactly what will run; on production it asks every time. A list read from files (over SFTP) isn't tested yet.

### Customize a built-in tool

**Customize** on a built-in tool's page opens its file in the editor as yours: `~/.config/dfilemanager/tools/` with the same `id`. Once you save it, its scripts are copied next to it, yours takes the built-in's place and asks **Use the tool “…”?**; where you use it stays as it was. Yours with an error leaves the built-in in its place, and My Tools lists your file as not loaded. To go back to the built-in, delete your file and **Reload Config**.

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
| `list` | `command` or `script`, and how its output becomes rows: `format` (`lines`, `json`, `jsonl`, `tsv`, `csv`, `table`, `regex`), `pattern`, `names`; `key` (what names a row), `title`, `subtitle`, `detail`, `state`, `columns`, `empty` |
| `header` | A command whose first line shows above the list |
| `actions`, `toolActions` | A row's actions and the tool's: `id`, `title`, `key` (`return`, `f8`, `cmd+e`…), `command` or `script`, `readonly` (a look), `dangerous` (can't be undone), `confirm` (asks everywhere), `message` (what the question says), `verify`, `multi` (on marked rows too), `refresh`, `output` (`line`, `window`, `follow`, `terminal`, `silent`), `strip: "cri"`, `edit` (a server path for the editor), `open` (a server path shown in the active panel — `{stdout}` is the command's first line of output), `goto` (a place in Kermo: `services:{unit}`, `containers:{name}`, `ssh`), `done`, `save` (the name ⌘S offers for a window's output: `{server}-report.txt`). A tool with `toolActions` and no `list` lists its actions as its rows, as Server Info does |
| `long`, `progress`, `format` | `long: true`: a [long job](#long-jobs), on the server only. `progress` reads each line it prints: `{ "pattern": "(?<percent>\\d+)%" }` for text, `{ "percent": "pct" }` or `{ "fraction": "percent_done" }` for a JSON line, with `text` (a template of the line's fields) for its card; without it, a spinner and the last line. `format` (`jsonl`, `json`…): the last record of its output gives `done` its fields — `"done": "Backed up {files_new} files"` |
| `inputs` | An action's sheet: `name`, `type` (`text`, `secret`, `choice`, `choice-from`), `title`, `placeholder`, `default`, `pattern`, `optional`, `options`; a `choice-from` has a `command` and a `key` (`{line}`) |
| `primary` | The tool action on the ＋ button |
| `version` | `command`, `pattern` with a group `v`, `tested` (`>=0.36 <0.37`) |
| `vars` | Values per server, `{name}` in commands: `title`, `default`, `placeholder`, `pattern`, and one source — `command` (its first line, read once per connection) or `"ask": true` (asked on a saved server, kept in `tools/servers.json`; see [Where a tool is used](#where-a-tool-is-used)) |
| `timeout`, `exitOk` | Seconds (30 by default); exit codes that count as success (`[0]`) |
| `stream`, `poll`, `watch` | [Watching](#watching-a-server): a `stream` runs on and prints a record (a `jsonl` line, or a frame — `split`) every so often; a `poll` runs again every `watch.every` seconds. `watch`: `every` (seconds, 1 or more), `down` (missed samples that make "not answering", 3) |
| `metrics` | Named numbers of a sample: `title`, `path` (`cpu.pct`), `unit` (`%`, `B`, `B/s`, `ms`, `s`, `h`, `days`, `/min`), `max`, `detail` (a template), `rows` + `key` (one series per row: disks by `mount`), `count: "state"` (rows by state), `calc` (`rate`: a counter's change per second; `age`: now minus the time at `path`, by the server's clock) |
| `alerts` | `id`, `metric`, `warn`, `crit`, `below` (low is bad), `for` (`{ "warn": "10m", "crit": "5m" }`) or `checks` (samples in a row), `message` (a template with `{value}` and the row's fields) |
| `events` | `id`, `level` (`info`, `warning`, `critical`), `message`, `goto`; `path` or `rows` + `key` + `field`; `when`: `changed`, `increased`, `added`, `left` (from `from`), `is` (`value`); `if` / `unless` (a field non-empty / empty). A record's own `"_event": { "id", "level", "message" }` is an event too, at most 10 an hour |
| `summary`, `dashboard` | The server's row in WATCHED: `metric`, `as` (`bar`, `count`, `text`), `of` (`max`, `sum`, `min`, `avg`), `label`. `dashboard`: blocks top to bottom, a `row` side by side — `{ "stat": "cpu" }` a tile (`["rx", "tx"]` two in one, `of`, `also`); `{ "charts": [["cpu"], ["rx", "tx"]] }` small multiples on one time axis (`range`: the first is the hour in memory, the rest wait for the history on disk; `log`: the action a click runs with `{from}` / `{to}`); `{ "table": "procs" }` the rows of a row set as the last sample that had them (`title`, `columns` as a list's — `"cpu:%"`, or `{ "field": "pct:bar", "title": "Used" }` — `actions`: ids of actions with that `rows`); `{ "events": true }`; `{ "counts": [{ "rows", "title", "goto" }] }` |

Placeholders in braces, `{ip}`, take a sheet's values first, then a row's fields; `{server}`, `{host}` and `{user}` are Kermo's. A command given as an array of parts, `["ufw allow {port}", "comment {comment}"]`, leaves out a part whose value is empty.
