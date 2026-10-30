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

**What a server has is asked once its connection is up** — one short run that checks for every tool's program at once (`command -v ufw`), as the login user, and learns the system ("Fedora 44 · dnf"). Kermo never logs in for a menu: with no connection, **Tools ▸** says **Connect to see tools**. Once known, the tools stay in the menu greyed, with **As of 14:02**, after the connection closes. A server with none of their programs has no **Tools ▸**.

## A tool's list

A tool's list works as Services… does, in search and in a panel: ↑↓, typing filters, ⌃↩ (or a right-click) its row's menu, ⌘↩ the same rows in the other panel, Refresh reads it again. Each row has a state mark with its color — ● green, ○ orange, ◆ red, a grey dot — and what's in trouble comes first. The line above the rows comes from the program (`Firewall active · default: deny (incoming)`), and says so when:

- there are more rows than the list shows ("shown 500 of 812");
- the server's clock is over a minute off;
- the program's version is outside what the tool was tested with.

A row's menu has the row's actions, the tool's actions, then **Copy** (the row as text) and **Show ufw.json** (the tool's file). An action that can't run now is greyed out, and its tooltip says why.

### Firewall (ufw)

| Key | Does |
|---|---|
| ↩ | **Status in Full**: `ufw status verbose` in a window |
| F8 | **Delete Rule…**: deletes the rule under the cursor |

Its menu also has **Turn Firewall On…** and **Turn Firewall Off…**. An inactive firewall is a list with no rules. Deleting, and turning it on or off, always ask first. **Delete Rule…** acts on the rule under the cursor only, never on marked rows: ufw numbers its rules, and the numbers move after each delete. Before it deletes, Kermo reads the rules again; if that number is now another rule, nothing is deleted and the line says "the list changed".

### Banned IPs (fail2ban)

| Key | Does |
|---|---|
| ↩ | **Who Is It?**: `whois` for the address, on this Mac, in a window |
| F8 | **Unban**: from the jail that banned it |

Its menu also has **Unban from Every Jail**. The line above the rows lists the jails and fail2ban's version.

## How an action runs

1. **A locked server** asks for Touch ID first. An action that runs on this Mac (Who Is It?) doesn't reach the server and doesn't ask.
2. **The question**, when there is one:

   | Action | Asks |
   |---|---|
   | One that can't be undone (Delete Rule…, Turn Firewall Off…) | Always. Its button is red, ↩ is Cancel |
   | Any other change, on a [production server](safety.md#production-servers) | Yes |
   | A look (Status in Full, Who Is It?) | Never, production included |
   | Any other change elsewhere | No |

   The question shows the command with its values filled in, and how and where it runs (as root, through the server's sudo). **Show Exactly What Runs** shows what Kermo sends, then asks again.
3. **The run.** The row says what runs on it, with a spinner. Another change of the same tool on that server waits for it ("Firewall on web-01 is busy: Delete Rule"); looks run alongside.
4. **How it went**, in a line under the list: "Deleted rule 3 (80/tcp) on web-01 at 14:02:11", or ✕ and the first line of what the program said, with **Output…** for all of it. With the list closed, the status line says it. A program that isn't on the server is said so: "apt-get isn't on web-01 (Fedora 44 · dnf)".
5. **The list is read again** after a change, the cursor staying on its row, or going to the next one if that row is gone. A look reads nothing again.

⎋ stops the wait. A run that takes over 30 seconds, or gives over 16 MB of output, is stopped and says so; when the connection drops, the run ends on the server too, leaving nothing behind.

## Safety

- **A value never becomes part of a command.** An address from the list, `203.0.113.7`, reaches `fail2ban-client set sshd unbanip` as one argument, whatever it holds. A value that begins with `-` (it would be read as an option) or holds a line break isn't put into a command at all: the action is greyed, saying why. On this Mac a value from the server may hold only letters, digits and `._:/@%+=,-`.
- **The same environment on every server:** the command goes to `sh` on its input, never to the login shell, with `LC_ALL=C` (no translated output) and `/usr/sbin` and `/sbin` on the `PATH`.
- **As root:** a tool that needs root runs through the server's `sudo`, `sudo -n` first. When sudo wants a password, Kermo asks for it as a [root panel](root-panel.md) does; the password goes to sudo on its input, never on a command line, and is shown as `•••` anywhere it could appear.
- **The production log:** each run on a production server is a line in the [production log](safety.md#production-log): `"action": "tool ufw delete"`, what was sent and its exit status.
- **Nothing stays on the server:** no files, nothing installed. A run ends with its connection.

## Your own tools

Put a tool's JSON file in `~/.config/dfilemanager/tools/`, with any script it names next to it. A file is read only if it's yours and neither its group nor others can write it (`chmod go-w`); otherwise it isn't loaded, saying why. A file of yours with a built-in tool's `id` takes that tool's place; if it has an error, the built-in one stays.

**Kermo ▸ Configuration ▸ Reload Config** reads the folder again and lists what's wrong with each file, with its line: `tools/my-tool.json: line 3: …`. An unknown field is an error, not something left out: it might be a safety field.

This version checks your tools but offers only the built-in ones: a tool of yours shows once Kermo has asked you to trust it, which a coming version does.

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
| `actions`, `toolActions` | A row's actions and the tool's: `id`, `title`, `key` (`return`, `f8`, `cmd+e`…), `command` or `script`, `readonly` (a look), `dangerous` (can't be undone), `confirm` (asks everywhere), `message` (what the question says), `verify`, `multi` (on marked rows too), `refresh`, `output` (`line`, `window`, `silent`), `done` |
| `version` | `command`, `pattern` with a group `v`, `tested` (`>=0.36 <0.37`) |
| `timeout`, `exitOk` | Seconds (30 by default); exit codes that count as success (`[0]`) |

Placeholders in braces, `{ip}`, take a row's fields; `{server}`, `{host}` and `{user}` are Kermo's.
