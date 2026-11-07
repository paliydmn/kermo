[Kermo documentation](../README.md#documentation)

# Tools

A tool turns a program on a server into a list with actions, as [Services…](servers.md#services-and-containers) does for systemd. Kermo comes with six:

- **Firewall (ufw)**: the rules, what's allowed and what's denied, and from where;
- **Banned IPs (fail2ban)**: the addresses fail2ban has banned, by jail;
- **Server Info**: a report of the machine for support, its load now and as it goes, disks, traffic, GPU, the busiest processes;
- **System**: CPU, memory, disks and traffic, [watched](#watching-a-server) live or in the background;
- **[Sites](#sites)**: the web addresses you saved with a server, checked from this Mac;
- **Deployments (dpl)**: the units [dpl](https://dpl.cesbo.com) deployed — their state, read from dpl's own files as root — with **Deploy…** (a folder from this Mac, as a [long job](#long-jobs)), **Roll Back…**, Inspect, Logs and their config; [watched](#watching-a-server), how many units are ready, a table of them with their actions, requests, errors and the slowest answers per domain, and an event when a deploy fails or a new version serves.

A tool is a JSON file, a *preset*. Kermo has no code for any particular tool: the built-in ones use only what a preset of your own can.

## Where tools show

A server shows the tools whose program it has (and that you [use there](#where-a-tool-is-used)):

- **Tools ▸** in its row's menu in the sidebar, in a server folder's menu in a panel, and **Server ▸ Tools** in the menu bar (for the active panel's server): "Firewall (ufw)", "Banned IPs (fail2ban)". A click lists it in [search](window.md#search), on the server's overview (**web-01 › Firewall ›**), as Services… does.
- A row each in the server's [overview](servers.md#the-server-as-a-place): **Firewall**, **Banned IPs**, with how many rows the list had when it was last read (`20 rows`), shown while a connection is up; `—` till then. ↩ shows the list in that panel, ⌘↩ in the other.
- Search finds them by name too, once Kermo knows the server has them: `fire web` finds **Firewall — web-01**.
- [The Tools window](#the-tools-window): a page for each server, its tools as tabs.

**What a server has is asked once its connection is up** — one short run that checks for every tool's program at once (`command -v ufw`), as the login user, and learns the system ("Fedora 44 · dnf"). Kermo never logs in for a menu: with no connection, **Tools ▸** says **Connect to see tools**. Once known, the tools stay in the menu greyed, with **As of 14:02**, after the connection closes — for a saved server across restarts too (`tools/known.json`; deleting it only means asking again). Server Info needs no program of its own, so every server has it.

## The Tools window

**Window ▸ Tools** (⌃⌘T) opens it on the active panel's server; **Open in Tools Window**, last in a server's **Tools ▸**, on that server. Its sidebar lists your saved servers (production in its color, a locked one with its lock), then servers connected now, and the library: **[Catalog](#the-catalog)**, **My Tools** and **[New Tool…](#new-tool)**; drag its edge to make it wider or narrower (Kermo keeps the width). ↩ or a double-click on a library row opens the tool's page: who made it, its version and the sha256 its trust goes by; what it runs, grouped as **Use the tool “…”?** shows it (a dangerous action in red); and each saved server — whether it has the program, whether the tool is used there, its values set or **Set Up…**, and **[Install…](#install)** where it isn't there. Its buttons: **Use on Servers…**, **Show File**, and **Edit** for yours, **[Customize](#customize-a-built-in-tool)** for a built-in one; **Remove…** for a file in your folder; **Get** or **Update to v…** for [a catalog's](#the-catalog).

A server's page has its name, the open tab's line from the program (`jails: sshd · 1.0.2`, a version outside what the tool was tested with), **Terminal** (an SSH tab in the main window) and **⋯**. Its tabs are the tools it shows, ⌘1…⌘9:

- **A list** stays in the main window: **Open in Panel** shows it in the active panel, **Open in Search** in search, with the same rows, keys and questions as anywhere else.
- **Buttons** (Server Info): each runs its action as its row does — the question on production, the line under the buttons saying how it went, its window where it has one. One that can't run here is greyed, saying why.
- **A one-command tool**: one button.

A server that isn't connected shows the tools it had when Kermo last saw it, greyed, and **Connect**: Kermo doesn't log in to draw a page. **＋** after the tabs lists the library's other tools: one hidden on this server shows again, one the server hasn't got is greyed. Under the title, what Kermo installed there: "Installed by Kermo: dpl 0.7.1, 3 Nov". **⋯** has **Open in New Window** (the page as a window of its own; several servers' at once), **[Clean Up Kermo Files](#install)**, **Use … on Servers…**, the tool's file, and **Hide … on web-01**. The windows open when Kermo quits come back when it starts, each on its server and tab, in its place — not connected, as above; a server deleted meanwhile is left out. Sites comes back on the page's first tab instead: open, it would check the addresses at once.

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

A tool with a `stream` (**System**: CPU, memory, load, disks, network and disk I/O, the busiest processes, failed services and containers, read-only from `/proc`, `df` and `ps` every 5 seconds) has a live tab on a server's page. Opened on a connected server, the tab is **live while open**: the stream runs on the server while the tab shows, its numbers in tiles with the tool's thresholds, and ends there when you leave the tab or close the window; while it shows, its connection isn't closed as an idle one. Nothing logs in to draw it: a server that isn't connected shows **Connect**.

**Watch in Background…** (⋯ on the page, **Watch…** in a saved server's menu in the main window, **Server ▸ Watch Server…**) keeps it running without a window, with alerts: the sheet says what goes to the server and how often, the tool's rules, and that the connection stays open while the server is watched — it shows in `w` and `last` there. Only a saved server is watched (`"watch": true` in `tools/servers.json`), and watching resumes by itself when Kermo starts. **Stop Watching** ends it; an alert that was standing goes without a word — a stop is no recovery.

The Tools window's sidebar then starts with **WATCHED**: each watched server with its worst state as a shape — a triangle for a warning, an octagon for a critical alert, a dot when fine, a ring while paused or waiting for a login — and its tools' summary (CPU, memory and the fullest disk as bars with their thresholds), problems first; the rest under **OTHER SERVERS**. A tab with an alert standing shows the mark instead of its icon.

How watching behaves:

- **Alerts** come from the tool's rules: CPU over 85 % for 10 minutes is a warning, over 95 % for 5 minutes critical, a disk over 85 % a warning at once. One line per change for the worse; **back to normal** only when a real sample says so. A gap — the Mac asleep, the connection dropped, the server not answering — keeps every alert as it was: nothing recovers through a gap.
- **Drops.** When the connection goes (sleep, a network change, ⌘Q of the shared connection), the series get a gap and Kermo reconnects after 2, 5, 15, 30, then 60 seconds, one server after another. No sample for three intervals is **not answering** (critical) — unless this Mac has no network, or woke less than a minute ago.
- **Login.** A watched server logs in without a dialog: a key, or a password saved in the Keychain. One whose login would ask — a password not saved, a passphrase, a host key to confirm — isn't logged in behind your back: its row says **needs login**, and a click on **Connect** in its tab logs in once, as any look does.
- **A locked server** is watched read-only, without Touch ID, and its connection stays open while it's watched — after the Mac sleeps or locks, watching resumes by itself. The lock guards actions in Kermo (Stop, Kill, a panel), not the connection.
- **An hour** of each series stays in memory; events (a reboot, an OOM kill, a service that failed, a container that left `running`) are listed per tool. A watched tool also keeps **a week on this Mac**: every 15 minutes, each series' lowest, average and highest value, and the gaps (the Mac asleep, the server not watched), a line each in `monitor/<the server's id>/<day>.jsonl` under the config folder, readable only by you — some 100 KB a server a week; older days go by themselves while it's watched, and deleting the saved server deletes them.
- **A tool's list** is read while it's watched or its tab is open, where its numbers, events or tables take its rows (Deployments' units): a list of files from this Mac every interval over one SFTP session kept open — as root through the server's sudo where the tool runs as root, never with a sudo password: one that wants a password says on the tab what to allow in sudoers — and a command's list in the same channel as the tool's stream. A list that can't be read is a gap in its numbers, never zeros, and the tab says why.
- **On battery or in Low Power Mode** watching checks three times less often (System every 15 seconds, Sites every 3 minutes): the tab says so. **Settings › Monitor** can turn that off (`monitorSlowOnBattery`), keep this Mac awake while it's on power and something is watched (`monitorKeepAwake`; also **Keep This Mac Awake on Power** in the menu bar's popover — the display sleeps, closing the lid still puts the Mac to sleep, on battery it sleeps as usual). **Open Kermo at login** (Settings › General) starts watching again by itself.

**The dashboard.** Under System's tiles, the last hour as charts — CPU, memory, traffic in and out, disk reads and writes — on one time axis: a stretch where the Mac slept, the connection dropped or the server didn't answer is a band saying so (never zeros), the tool's thresholds are dashed lines, the hour's events sit on the axis, and a hover shows the values at that moment in each chart's header. A click on a chart opens the server's journal for the five minutes around it (**Log for This Time**: warnings and worse, and the kernel's lines). Below: the busiest processes and the disks as tables — each as tall as its rows, or as you drag the grip under it (Kermo keeps it; a double-click on the grip goes back to its rows) — each row with its actions — **Open Folder** (the process's folder in the active panel), **Open Files**, **Stop…**, **Kill…**, **Biggest Folders** (a disk's biggest folders, as root, in a picker over the window: ↩ **Show in Panel** shows one in the active panel, ⌘↓ **Biggest Folders Inside** goes into it, as deep as you like, ⌫ or ⎋ back up) — then the events of the tool and of watching itself, newest first, with **Services…** or **Containers…** where one leads there, and the counts of failed services and containers. A row's action goes the way every action does: Touch ID on a locked server, the question on production (always for Kill…), the line under the page saying how it went. **24h** and **7d** over the charts draw the week on this Mac: each 15 minutes' average, with a band where the Mac slept or the server wasn't watched.

### Sites

**Sites** checks the web addresses you saved with a server (**Edit Server ▸ Tools ▸ Sites**: `https://example.com https://example.com/health`) from this Mac — no SSH, nothing on the server — every minute while its tab is open or the server is watched. Its tab is on every saved server: with no addresses yet it says so, beside **Add Address…**. Each check is one request with nothing kept between them (no cache, no cookies), its answer taken as it is: a redirect isn't followed, a 3xx is up. The table has each address's status (or why there was none: `timed out`, `refused`, `certificate refused`), the time to the answer, the certificate's days left and when it was checked, with **Open** (in the browser), **Check Now** (every address at once), **Headers** (the answer's) and **Errors** (the server's nginx or Apache error log, as root); the chart, each address's response time. **Add Address…** opens Edit Server.

An address on this network (`http://nas.local/`): macOS asks once whether Kermo may find devices on local networks. Without that, such an address says `local network off` — **System Settings ▸ Privacy & Security ▸ Local Network ▸ Kermo** turns it on. Servers over SSH never need it.

Its alerts: an address down two checks in a row is critical (a notification, `on_alert`), an answer slower than 2 seconds for 5 minutes a warning, a certificate ending in 14 days a warning and in 3 critical. A certificate macOS doesn't trust is down, whatever its days. While this Mac is offline, and in the first minute after it wakes, nothing is checked.

## A tool's list

A tool's list works as Services… does, in search and in a panel: ↑↓, typing filters, ⌃↩ (or a right-click) its row's menu, ⌘↩ the same rows in the other panel, Refresh reads it again. Each row has a state mark with its color — ● green, ○ orange, ◆ red, a grey dot — and what's in trouble comes first. The line above the rows comes from the program (`Firewall active · default: deny (incoming)`), and says so when:

- there are more rows than the list shows ("shown 500 of 812");
- the server's clock is over a minute off;
- the program's version is outside what the tool was tested with (asked once a session).

A row's menu has the row's actions, the tool's actions, then **Copy** (the row as text) and **Show ufw.json** (the tool's file). An action that can't run now is greyed out, and its tooltip says why; one meant for some rows only isn't on the others at all. In a panel, the tool's main action is a button over the columns: **＋ Allow Port…**, **＋ Ban Address…**.

Some actions list rows of their own — a folder's biggest folders, a jail's banned addresses: they show one level down, on the same picker (where it is, as its chip: `web-01 › System › /var`) or panel (the same in its path bar), with their own actions; ⌫ or ⎋ goes back up to the row you came from, and Refresh reads that level again. Getting there asks what any action asks — Touch ID on a locked server, its sheet, the question on production.

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

The keys work in search. In a panel a row's key works where it's one of Kermo's own command keys (↩, F8, ⌘L, ⌘J, ⌘N — there the row's ⌘N comes before New Editor Document); the others (⌘B, ⇧⌘S) are on the ＋ button and in the row's menu (⌃↩).

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

What opens a window or a tab of its own goes there instead of the line: a window of output, a log that follows (closing it ends the command on the server), a command in an SSH tab, a file in the editor (as any server file: history, checks, production's question on save). In a window of output, **⌘C** with nothing selected copies all of it, **⌘S** saves it as a text file, and **F2** sends it to a tool that takes text ([Send To…](#send-to)).

⎋ stops the wait. A run that takes over 30 seconds, or gives over 16 MB of output, is stopped and says so; when the connection drops, the run ends on the server too, leaving nothing behind. Tools use at most 9 of a connection's sessions at once (OpenSSH allows 10; past them ssh would log in again): one more waits, and the status line says so.

## Long jobs

An action marked `long` — a deploy, a backup, an upgrade — runs on the server on its own, and Kermo follows it:

- **It starts and comes back at once.** The line under the list says so ("Deploy: started on web-01 at 14:02 — it runs on there; Activity (⌥⌘J) follows it"), and its row spins while it runs; when it's over, its list is read again, as after any change. Starting it again on the same row says it's already running and shows Activity. The tool isn't busy meanwhile: its other actions run.
- **Activity (⌥⌘J)** has a card for it: its progress (or a spinner) and the last line it printed, **Show** (its output in a window, more as it comes; closing the window stops nothing) and **Stop…**. Once it's over: ✓ or ✕ and how it went, **Retry** (the same action with the same values, asked as any run; a secret is asked again), **Show Log** and ✕. The toolbar's ring and the Dock count it along with copies.
- **It runs on without Kermo.** When the connection drops, the Mac sleeps or Kermo quits, the job goes on. Its card says "connection lost — the job runs on", or after a relaunch "connect to web-01 to see how it goes"; once a connection to that server is up, Kermo follows it again. It never logs in just for that.
- **Stop…** asks on production, then stops the job and everything it started (its process group; a root job's through sudo).
- **When it ends** while Kermo isn't in front, after more than a minute, a macOS notification says how it went; clicking it shows Activity. Kermo asks to send notifications when you start your first long job. If they're off, the Dock's badge and the card tell you instead.

**A folder or a file from this Mac** (a deploy's source): the sheet has **Choose…**, and the question says what goes — a folder that is a git repository as committed (`git archive HEAD`: changes not committed stay on the Mac, and the question says how many there are), any other folder without `.git`, `node_modules` and `.DS_Store`. A repository whose own config could make git run a command (a cloned one's `tar.tar.gz.command`) is sent as a plain folder. After the question it's packed (`.tar.gz`) and uploaded through the copy queue, which Activity shows, to `~/.cache/kermo/upload/` on the server; the command gets that path. The job removes it when its command ends; one whose job never started goes a week later.

On the server a long job runs as the login user in a session of its own (`setsid`; perl's or python3's where there's none), with sudo only around its command; a sudo password is checked before the job starts and goes to sudo through a pipe. Its output goes to `~/.cache/kermo/runs/<id>.log` (the folder is the login user's, `0700`), its exit status to `<id>.exit`. A job's files are removed a week after it ended, when the next long job starts on that server. Kermo keeps the jobs it started in `tools/runs.json` on this Mac.

### Notifications

While something is watched, Kermo has an item in the menu bar: a gauge, and how many watched servers have a problem, in red when one is critical, orange for warnings. Its popover lists each watched server as WATCHED does, problems first — a click opens its page — then **Open Monitor** (⌃⌘M: the Tools window on the watched servers), **Open Kermo**, **Snooze Notifications ▾** and **Quit Kermo**. **Show web-01 in the Menu Bar** (⋯ on a watched server's page) gives up to three servers an item of their own: the state's shape and the summary, `web-01 42% · 61% · 27%`; a click opens the page. Closing the last window leaves Kermo there alone — no Dock icon, no ⌘Tab — watching on, a copy's progress on the item; any of these, a notification, or opening Kermo again brings the Dock icon back. With nothing watched, closing the last window quits Kermo as before.

What reaches you:

- **A warning** shows in the menu bar, on the Dock icon's badge and in the Tools window, and nowhere else.
- **A critical alert** — a watched tool's threshold, a critical event, a script's critical `_event`, a server not answering — also comes as a macOS notification, once while it stands: **Open** shows its tab, **Snooze 1 Hour**, and for an alert **Mute This Alert on This Server** (it still shows in the menu bar and the window; the mute is kept in `tools/servers.json` as `"muted": ["cpu"]`). Back to normal is a line in the tool's events, not a notification. A tool's event that only says how things stood when watching started — a unit whose deploy failed before Kermo opened or before you pressed Watch — is listed, not notified; it notifies when it happens while watched (a script's `_event` always notifies). A tool only live on an open tab notifies nothing.
- **Your command** (`on_alert`, **Settings › Monitor**) runs on this Mac for each critical alert, in zsh as a login shell (so it has the PATH your `.zprofile` sets, Homebrew's included), with what happened only in its environment — `KERMO_SERVER`, `KERMO_LEVEL`, `KERMO_MESSAGE`, `KERMO_TOOL` — so a message from a server never becomes part of a command; it's stopped after 30 seconds, and how it went is a line in the server's events. A tool can never set it. To have alerts on your phone: `curl -s -d "$KERMO_SERVER: $KERMO_MESSAGE" ntfy.sh/my-topic`. **Send Test** shows a notification and runs it with made-up values.
- **Snooze** (the menu bar, or a notification's button) silences every notification and `on_alert` for 15 minutes, an hour, or till 9:00; the menu bar's item dims and still counts problems. What comes up meanwhile shows in the menu bar and the window, and what still stands when the snooze ends is sent then. Quiet hours are macOS Focus.
- **Maintenance ▾** on a watched tool's tab — 30 minutes, 1 hour, 3 hours — is for a reboot or an upgrade: nothing notifies of that server till then — what still stands when it ends is sent then — its alerts still show, the charts mark the time as a band, and the tab says till when with **End Now**. It ends by itself; quitting Kermo ends it too.
- **Thresholds…** on the same tab: your own warning and critical value for each of the server's watched tools' alerts, for **All Servers** or **Only web-01** over those. An empty field leaves it to the value under it, shown in grey; **Restore Defaults** empties them. On one server, **Notify** unticked keeps an alert from notifying there (a notification's Mute does the same). They're kept by the alert's id, so a new version of the tool keeps them: in `tools/servers.json`, `"alerts": { "system": { "cpu": { "warn": 80 } } }` at the top for all servers, and `"alerts": { "cpu": { "crit": 98 } }` beside `"muted"` in a server's tool.

macOS asks whether Kermo may notify the first time you watch a server. If you said no, **Settings › Monitor** says so, with **Open System Settings**; the menu bar and the Dock still show every problem. "Use the tool…?" says a watched tool may send notifications.

## A tool's files: F2 and F4

A tool can know some of a server's files: Deployments knows its units' configs, `conf/*.yaml` in dpl's folder (found on each server, `/opt/dpl` by default).

- **F2** on such a file in a server panel lists the tool's actions for it above [your own commands](commands.md): on `web.yaml`, **Deployments: Deploy web…**, **Deployments: Check Config web**, **Deployments: Inspect web**. Kermo reads the tool's list first — the status line says so, ⎋ stops it — and offers what the list offers on that unit's row: Deploy only on an app. Each runs as it does from the list: Touch ID on a locked server, its sheet, the question, the line saying how it went in the panel's status line. A file whose unit isn't in the list (not deployed yet) gets none, and the status line says so.
- **Saving** such a file (F4, then ⌘S) runs the tool's check — `dpl check web` once the file is in place, as root, the old text put back if it fails — as [config checks](config-checks.md) do. Your own `validators.json` rule for that path comes first, then Kermo's built-in ones: where Kermo has a check of its own for a file (sudoers, `sshd_config`, nginx's), the tool's isn't run there. **Use the tool “…”?** lists a tool's checks with what it runs by itself.

Only tools in use on that server count. A tool's folder is the one its command found there this session — looked for once, the first time a file there could be the tool's (the status line says so; ⎋ stops it) — or yours set for the server; its default if that found nothing.

## Send To…

**F2** in a window of output — a command's output, a tool's, a log — lists the actions of the server's tools that take text; one gets what's selected in the window, or all of it, as its input. None of the built-in tools takes text: it's [one of yours](#tools-that-help) that does, say `grep -c error` on the server, or a program on this Mac. **Send To…** is on the window's key bar once such a tool is in use on the window's server.

Sending always asks first: how many lines go, how they begin, and where. The text goes to the command's input inside the script itself, never on a command line; **Show Exactly What Runs** and the production log show how many lines it was, not the text. The output comes back as the action says: a line in the window's status line, or a window of its own.

## Safety

- **A secret** you type goes to the server in the command's input only: never on a command line, on screen, in Output… or in a log — `•••` there.
- **A value never becomes part of a command.** An address from the list, `203.0.113.7`, reaches `fail2ban-client set sshd unbanip` as one argument, whatever it holds. A value that begins with `-` (it would be read as an option) or holds a line break isn't put into a command at all: the action is greyed, saying why. On this Mac a value from the server may hold only letters, digits and `._:/@%+=,-`.
- **The same environment on every server:** the command goes to `sh` on its input, never to the login shell, with `LC_ALL=C` (no translated output) and `/usr/sbin` and `/sbin` on the `PATH`.
- **As root:** a tool that needs root runs through the server's `sudo`, `sudo -n` first. When sudo wants a password, Kermo asks for it as a [root panel](root-panel.md) does; the password goes to sudo on its input, never on a command line, and is shown as `•••` anywhere it could appear.
- **The production log:** each run on a production server is a line in the [production log](safety.md#production-log): `"action": "tool ufw delete"`, what was sent and its exit status.
- **Nothing stays on the server** but a long job's log, and what you [install](#install): no other files. A run ends with its connection; only a [long job](#long-jobs) runs on, and its log stays in `~/.cache/kermo/` there for 7 days; a folder uploaded for it goes when it ends.

## Install

Most tools are **agentless**: they run commands, and nothing of theirs stays on the server. A tool that can install its program says **installs software** on its page, and its **What it runs** has a group for it: the command for each system, the vendor's script with its sha256, and what stays on the server after it (its services, paths and ports).

On the tool's page, a server without the program has **Install…** — or why not: the server is read-only, installs are off there, its system has no command in the tool, or Kermo hasn't seen the server yet. **Installs allowed** in [Edit Server ▸ Safety](servers.md) is on, but off on production unless you turn it on there.

1. The tool's checks run first, as your login, in one go: "Podman 4.8 or newer is needed (found 4.3)" stops it there.
2. The command is the one for the server's package manager (`apt-get`, `dnf`, `apk`, `pacman`, `zypper`; `brew` not as root). A tool that installs with its vendor's script has it fetched on this Mac and checked against the sha256 the tool names; a script that isn't that one doesn't run, and nothing goes to the server as `curl | sh`. The script goes to the server as the command's input, its values (`DPL_VERSION=0.7.1`) as variables.
3. The question, always — on any server, red on production: the exact command (**Show Exactly What Runs** shows the script), as root, and what stays on the server after it.
4. It runs as a [long job](#long-jobs) in Activity. When it ends, Kermo looks at the server again: the tool shows there, and `tools/installed.json` keeps what was installed, where and when — the server's page says "Installed by Kermo: dpl 0.7.1, 3 Nov".

Install turns on only what the program's own installer turns on. Where Kermo installed a program, the tool's page has **Uninstall…** (a tool with its own uninstall command; else **Docs**): asked as a change that can't be undone, with the command, when Kermo installed it, what Install left and what stays after it ("your repositories and their password files"). **Remove…** of a tool Kermo installed somewhere asks **Remove from Kermo Only** or **Also Uninstall from web-01…**: each Uninstall is asked and started first, and a server where it didn't start keeps the tool. Kermo answers only for its own Install: a program installed some other way has no Uninstall here.

**Clean Up Kermo Files** in a server page's ⋯ shows the size of `~/.cache/kermo` there — long jobs' logs and what was uploaded for them, Kermo's only files on a server — and removes it once you say so; not while a long job runs from it.

## The catalog

**Catalog** in the Tools window's library lists the tools built into Kermo, those you got from a catalog, and the others a catalog has — each with where it's used and what the catalog has of it: its version, **verified** (reviewed and tested by the catalog's CI) or **community**, **update: v5** when it has a newer one, **yours changed** when you edited yours. Kermo's own catalog is [kermo-tools](https://github.com/paliydmn/kermo-tools).

**Kermo reaches a catalog only when you ask**: when the Catalog opens, by its **Check for Updates** button, and by **Kermo ▸ Check for Updates…**, which then names the tools the catalogs have newer. The daily check for a new Kermo never fetches one. What came last is kept till Kermo quits; everything you got works offline.

**What Kermo takes from a catalog:** its index (`catalog.json`), only signed with the catalog's Ed25519 key (`catalog.json.sig`) — Kermo's own key is built into Kermo, so whoever could swap the files on GitHub couldn't sign them — and never an index older than one it already took from there (a number in it only grows). Each file of a tool comes only with the sha256 the signed index gives it. A catalog's index can't name a file outside its folder; a tool's files are its `<id>.json` and the scripts it names, nothing else, each script named `<id>.<something>` and not JSON — so none can land on another tool's file or one of Kermo's own. A file of yours where a tool from a catalog is written (one that doesn't load, a script of the same name, one you changed) is kept next to it as `….bak`.

A catalog's tool not got yet opens its page from its files, checked: what it runs, grouped as the question shows it. Then:

- **Get** asks **Use the tool “…”?** with where it's from and everything it can run; **Use This Tool** puts its files in `~/.config/dfilemanager/tools/`, readable only by you, and it shows on the servers where its check finds what it needs. It takes a built-in tool's place as [one of yours](#your-own-tools) does.
- **Update to v…** comes only from where the tool came from — the catalog you got it from, Kermo's own for a built-in tool — and asks only about **what changes in what it can run**: `+` what it runs now, `−` what it no longer runs, `~` a script whose text changed. A tool you wrote, or changed since you got it, is replaced only if you say so: **Replace** keeps yours next to it as `….json.bak`, **Compare** shows the two, **Keep Mine** leaves it.
- **Remove…** moves its file and its scripts (those no other tool of yours names) to the Trash; a built-in tool of its id is back in its place.

**Suggested**, under the Catalog's title: a catalog's tool you don't have whose program is on a server connected now — "restic is on web-01: the catalog has a tool for it". Kermo looks with its own `command -v`, in one run per server over the connection that's up; a catalog's own commands run nothing before you get its tool.

**Settings › Tools** lists the catalogs: each on or off (off, what it offered goes at once), **Add…** (a name, the `https://` address of its folder — or `file://` for a folder on a disk — and its Ed25519 public key as `openssl pkey -pubout` writes it), **Remove…** (the tools you got from it stay). When two catalogs have a tool of the same `id`, the Catalog shows the first one's. Kermo's own catalog always goes by the key built into Kermo. A team's own catalog is a folder with the same layout as kermo-tools: `catalog.json` lists each tool's `id`, `title`, `version` (its `catalogVersion`), its program (`tool`), `about` and its `files` (`path` under the folder, `sha256`; at most 20), with a `serial` that grows; `catalog.json.sig` is the base64 Ed25519 signature of `catalog.json` (`openssl pkeyutl -sign -rawin`). **verified** is what the catalog says of a tool: Kermo's means reviewed and tested by kermo-tools' CI.

## Your own tools

Put a tool's JSON file in `~/.config/dfilemanager/tools/`, with any script it names next to it. A file is read only if it's yours and neither its group nor others can write it (`chmod go-w`); otherwise it isn't loaded, saying why. A file of yours with a built-in tool's `id` takes that tool's place; if it has an error, the built-in one stays.

**Kermo ▸ Configuration ▸ Reload Config** reads the folder again and lists what's wrong with each file, with its line: `tools/my-tool.json: line 3: …`. An unknown field is an error, not something left out: it might be a safety field.

My Tools in [the Tools window](#the-tools-window) lists a file of yours that doesn't load under the table, with why; a click opens it in the editor.

A tool of yours runs nothing — not even its check of the server — until you say to use it. **Tools ▸** lists it under **Not in use yet**; choosing it asks **Use the tool “…”?** with everything it can run: what runs by itself (its check, its header, its list, its choices, its checks of a file you save) and what runs when you choose (its actions), each marked where it runs as root. A read-only action whose command looks destructive (`rm`, `kill`, `--force`, `>`…) is pointed out. **Open File** shows the file and its scripts. **Use This Tool** keeps your answer in `tools/trust.json`, by the file's and its scripts' sha256: a change to any of them asks again.

### New Tool…

**New Tool…** in the Tools window's library asks for a name — the file's name comes from it, `Disk Check` → `disk-check.json`; one that's there already, or a built-in tool's, won't do — and what to start from:

- **List with Actions**: rows from a command's output, an action on a row (it starts as the mounted filesystems, `df -P`);
- **Buttons**: commands that run when pressed, each its own button (`uptime`, `free -h`);
- **One Command**: one command, its output in a window (`who`).

Each starter works as it is on most Linux servers. It opens in Kermo's editor — a window of its own, not a tab: no draft is kept, and closing it with changes asks — not yet on disk; **⌘S** (or **Save** beside the text) writes it to `~/.config/dfilemanager/tools/` readable only by you, reads your tools again and asks **Use the tool “…”?** — then, for a new tool, **Use on Servers…**. Saving again asks again: it's a new version of the file. A tool with no script needs nothing else; one that names a script needs that file next to it.

Beside the text:

- **Problems**: the file checked as Kermo loads it, as you type — errors (it isn't loaded: an unknown field, a missing script, an `id` that isn't the file's name…) apart from warnings (it loads: a placeholder in quotes, `sudo` without `about`…), each with its line; a click selects that line. A file saved with an error isn't loaded, and **Reload Config** says why too.
- **Test on** a server **connected now**: runs what the tool runs by itself — its `vars` commands, its check (`requires`, its actions' too), its header, its version, its list — and never one of its actions. It shows whether each check passed, the header line, the version against `tested`, the first rows the list made, their fields, and every line of the output that didn't fit the pattern, with the exit status and stderr of what failed. Test never logs in: connect the server first. Its first run says exactly what will run; on production it asks every time. A list made of files is read over SFTP, as the list reads them.

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
| `list` | `command`, `script` or `files`, and how its output becomes rows — `files`: a path on the server, `*` matching names in a folder (`{base}/state/*/deploy.json`), each file a row read over SFTP, as root through the server's sudo where the tool runs as root; `name` gets the file's folder's name, `also` (`files` and a `pattern` with named groups) adds fields from another file each row names (`{base}/conf/{unit}.yaml`) — `format` (`lines`, `json`, `jsonl`, `tsv`, `csv`, `table`, `regex`, `prometheus` — a record a sample line: `name`, its labels, `value` (a label called `name` or `value` is `label_name`, `label_value`) — or `nagios` — the whole run one record: `status` `ok` · `warn` · `crit` · `unknown` from the exit code, which then never counts as a failure up to 3, `message`, `perf.<label>`), `pattern`, `names`; `key` (what names a row), `title`, `subtitle`, `detail`, `state`, `columns`, `empty` |
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
| `stream`, `poll`, `watch` | [Watching](#watching-a-server): a `stream` runs on and prints a record (a `jsonl` line, or a frame — `split`) every so often; a `poll` runs again every `watch.every` seconds; the tool's `list` is read that often too where `rows: "list"` takes its rows. `watch`: `every` (seconds, 1 or more), `down` (missed samples that make "not answering", 3) |
| `metrics` | Named numbers of a sample: `title`, `path` (`cpu.pct`), `unit` (`%`, `B`, `B/s`, `ms`, `s`, `h`, `days`, `/min`), `max`, `detail` (a template), `rows` + `key` (one series per row: disks by `mount`; `"list"`: the tool's list), `count: "state"` (rows by state), `calc` (`rate`: a counter's change per second; `age`: now minus the time at `path`, by the server's clock) |
| `alerts` | `id`, `metric`, `warn`, `crit`, `below` (low is bad), `for` (`{ "warn": "10m", "crit": "5m" }`) or `checks` (samples in a row), `message` (a template with `{value}` and the row's fields) |
| `events` | `id`, `level` (`info`, `warning`, `critical`), `message`, `goto`; `path` or `rows` + `key` + `field`; `when`: `changed`, `increased`, `added`, `left` (from `from`), `is` (`value`); `if` / `unless` (a field non-empty / empty). A record's own `"_event": { "id", "level", "message" }` is an event too, at most 10 an hour |
| `summary`, `dashboard` | The server's row in WATCHED: `metric`, `as` (`bar`, `count`, `text`), `of` (`max`, `sum`, `min`, `avg`), `label`. `dashboard`: blocks top to bottom, a `row` side by side — `{ "stat": "cpu" }` a tile (`["rx", "tx"]` two in one, `of`, `also`); `{ "charts": [["cpu"], ["rx", "tx"]] }` small multiples on one time axis (`range`: the first is the hour in memory, the rest wait for the history on disk; `log`: the action a click runs with `{from}` / `{to}`); `{ "table": "procs" }` the rows of a row set as the last sample that had them (`title`, `key` — what names a row, `"{pid}"`, `columns` as a list's — `"cpu:%"`, or `{ "field": "pct:bar", "title": "Used" }` — `actions`: ids of actions with that `rows`); `{ "events": true }`; `{ "counts": [{ "rows", "title", "goto" }] }` |

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

Any assistant can write a tool for you: give it this page from [The fields that work now](#the-fields-that-work-now) to here (the recipes and the example below show it the shape), the program's `--help`, and a few lines of its real output — what `--json` prints, if it has that — and say what you want: a list of what, which actions, which change things. Paste its answer into **New Tool…**: **Problems** says what doesn't fit, with its line, as you type; **Test on** a server runs its list there and shows the rows it made of the real output — and every line that didn't fit — before any of its actions can run. Saved, it still runs nothing until **Use the tool “…”?** has shown you everything it can run.

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
