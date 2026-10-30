[Kermo documentation](../README.md#documentation)

# Tools

A tool turns a program on a server into a list with actions, as [Services…](servers.md#services-and-containers) does for systemd. Kermo comes with two:

- **Firewall (ufw)**: the rules, what's allowed and what's denied, and from where;
- **Banned IPs (fail2ban)**: the addresses fail2ban has banned, by jail.

A tool is a JSON file, a *preset*. Kermo has no code for any particular tool: the built-in ones use only what a preset of your own can.

## Where tools show

A server shows the tools whose program it has:

- **Tools ▸** in its row's menu in the sidebar, in a server folder's menu in a panel, and **Server ▸ Tools** in the menu bar (for the active panel's server): "Firewall (ufw)", "Banned IPs (fail2ban)". A click lists it in [search](window.md#search), on the server's overview (**web-01 › Firewall ›**), as Services… does.
- A row each in the server's [overview](servers.md#the-server-as-a-place): **Firewall**, **Banned IPs**, with how many rows the list had when it was last read (`20 rows`), shown while a connection is up; `—` till then. ↩ shows the list in that panel, ⌘↩ in the other.
- Search finds them by name too, once Kermo knows the server has them: `fire web` finds **Firewall — web-01**.

**What a server has is asked once its connection is up** — one short run that checks for every tool's program at once (`command -v ufw`), as the login user, and learns the system ("Fedora 44 · dnf"). Kermo never logs in for a menu: with no connection, **Tools ▸** says **Connect to see tools**. Once known, the tools stay in the menu greyed, with **As of 14:02**, after the connection closes — for a saved server across restarts too (`tools/known.json`; deleting it only means asking again). A server with none of their programs has no **Tools ▸**.

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

What opens a window or a tab of its own goes there instead of the line: a window of output, a log that follows (closing it ends the command on the server), a command in an SSH tab, a file in the editor (as any server file: history, checks, production's question on save).

⎋ stops the wait. A run that takes over 30 seconds, or gives over 16 MB of output, is stopped and says so; when the connection drops, the run ends on the server too, leaving nothing behind. Tools use at most 9 of a connection's sessions at once (OpenSSH allows 10; past them ssh would log in again): one more waits, and the status line says so.

## Safety

- **A secret** you type goes to the server in the command's input only: never on a command line, on screen, in Output… or in a log — `•••` there.
- **A value never becomes part of a command.** An address from the list, `203.0.113.7`, reaches `fail2ban-client set sshd unbanip` as one argument, whatever it holds. A value that begins with `-` (it would be read as an option) or holds a line break isn't put into a command at all: the action is greyed, saying why. On this Mac a value from the server may hold only letters, digits and `._:/@%+=,-`.
- **The same environment on every server:** the command goes to `sh` on its input, never to the login shell, with `LC_ALL=C` (no translated output) and `/usr/sbin` and `/sbin` on the `PATH`.
- **As root:** a tool that needs root runs through the server's `sudo`, `sudo -n` first. When sudo wants a password, Kermo asks for it as a [root panel](root-panel.md) does; the password goes to sudo on its input, never on a command line, and is shown as `•••` anywhere it could appear.
- **The production log:** each run on a production server is a line in the [production log](safety.md#production-log): `"action": "tool ufw delete"`, what was sent and its exit status.
- **Nothing stays on the server:** no files, nothing installed. A run ends with its connection.

## Your own tools

Put a tool's JSON file in `~/.config/dfilemanager/tools/`, with any script it names next to it. A file is read only if it's yours and neither its group nor others can write it (`chmod go-w`); otherwise it isn't loaded, saying why. A file of yours with a built-in tool's `id` takes that tool's place; if it has an error, the built-in one stays.

**Kermo ▸ Configuration ▸ Reload Config** reads the folder again and lists what's wrong with each file, with its line: `tools/my-tool.json: line 3: …`. An unknown field is an error, not something left out: it might be a safety field.

A tool of yours runs nothing — not even its check of the server — until you say to use it. **Tools ▸** lists it under **Not in use yet**; choosing it asks **Use the tool “…”?** with everything it can run: what runs by itself (its check, its header, its list, its choices) and what runs when you choose (its actions), each marked where it runs as root. A read-only action whose command looks destructive (`rm`, `kill`, `--force`, `>`…) is pointed out. **Open File** shows the file and its scripts. **Use This Tool** keeps your answer in `tools/trust.json`, by the file's and its scripts' sha256: a change to any of them asks again.

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
| `actions`, `toolActions` | A row's actions and the tool's: `id`, `title`, `key` (`return`, `f8`, `cmd+e`…), `command` or `script`, `readonly` (a look), `dangerous` (can't be undone), `confirm` (asks everywhere), `message` (what the question says), `verify`, `multi` (on marked rows too), `refresh`, `output` (`line`, `window`, `follow`, `terminal`, `silent`), `strip: "cri"`, `edit` (a server path for the editor), `done` |
| `inputs` | An action's sheet: `name`, `type` (`text`, `secret`, `choice`, `choice-from`), `title`, `placeholder`, `default`, `pattern`, `optional`, `options`; a `choice-from` has a `command` and a `key` (`{line}`) |
| `primary` | The tool action on the ＋ button |
| `version` | `command`, `pattern` with a group `v`, `tested` (`>=0.36 <0.37`) |
| `timeout`, `exitOk` | Seconds (30 by default); exit codes that count as success (`[0]`) |

Placeholders in braces, `{ip}`, take a sheet's values first, then a row's fields; `{server}`, `{host}` and `{user}` are Kermo's. A command given as an array of parts, `["ufw allow {port}", "comment {comment}"]`, leaves out a part whose value is empty.
