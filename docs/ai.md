[Kermo documentation](../README.md#documentation)

# AI agents

Let an AI agent you run in Kermo's terminal — [Claude Code](https://claude.com/claude-code) or another MCP client — work where Kermo is connected: read and copy files, run commands on your servers, open a file in the editor. The agent calls Kermo's tools; Kermo asks you before anything you haven't allowed. It is off until you switch it on, and Kermo sends nothing anywhere itself: the agent is yours, with your own account.

## Switch it on and connect Claude Code

1. Open **Settings › AI** (⌘,) and switch on **Allow agents in Kermo's terminal (MCP)**.
2. Open a **new** terminal tab in Kermo (⌃O). Tabs opened before the switch don't know about it.
3. Once, tell Claude Code about Kermo. **Settings › AI** shows the line with the right path:

   ```
   claude mcp add kermo -- /Applications/Kermo.app/Contents/MacOS/Kermo --mcp
   ```

4. Start `claude` in that tab. `/mcp` there lists **kermo** as connected.

Another MCP client works the same way: its server is the command `Kermo --mcp` (stdio).

Only a program started from one of Kermo's terminal tabs gets in — any program you run there, not only the agent you set up; a question's sheet names the tab it comes from. An agent in another terminal app, or inside `tmux` or `screen`, is turned away and told why.

## What the agent can do

| Tool | What it does | Asks you |
|---|---|---|
| `focus` | What is in front of you: both panels, the editor's file, the terminal tab | No; names and selections only where you allowed reading |
| `list_folder`, `read_file`, `terminal_output`, `server_info` | Read | The first time on each server (and on this Mac) |
| `run_command` | Run a shell command on a server | A command that only reads: as reading. Anything else: until you allow commands there |
| `write_file`, `copy` | Write a text file; copy a file or a folder between this Mac and servers | Until you allow writing into that folder; always before writing over a file |
| `propose_edit`, `open_in_editor` | Check that a change fits a file; open a file in Kermo's editor | As reading |
| `request_scope` | Ask you for more, with a reason | Always |

The agent acts as you: on a server, as the user you log in as, never as root.

## What Kermo asks

A question appears as a sheet on Kermo's window, and Kermo comes to the front; the agent waits for your answer. **Cancel** leaves everything as it was, and the agent is told you didn't allow it.

- **Allow for This Task** names exactly what is asked: reading on a server, writing into one folder, running commands. It holds until the agent disconnects.
- These ask every time, whatever you allowed: writing over a file, and any change on a [production server](safety.md).
- A [locked server](servers.md#lock-a-server) asks for Touch ID first, as for you.
- Commands on a production server, saves and copies there go to the [production log](safety.md#production-log), marked as the assistant's.

> [!WARNING]
> Once you allow an agent to **run commands** on a server, a command can change or delete files there without another question: Kermo recognises the obvious ones (`rm`, `mv`, `>`), not every way a shell can write. Allow commands only where that is acceptable, and prefer letting the agent use `copy` and `write_file`.

## See and take back what an agent may do

While an agent is connected, the first panel's status line shows a chip with its name and what you allowed it. Click the chip, or open **AI Scope** in the **Window** menu (it is there while agents are allowed):

- each line is one place and what the agent may do there; its **Take Away** withdraws it, and the next call there asks again;
- **Show Journal…** lists every call the agent made, what Kermo decided and how it ended. A ⚠ marks calls made after the agent read something from a server: text from a server can try to steer an agent;
- **Disconnect** hangs up on the agent.

Switching **Allow agents in Kermo's terminal (MCP)** off disconnects every agent and forgets what each was allowed.

## Limits

- Paths are absolute. `write_file` and `copy` refuse a path that goes through a symbolic link and name the real one: on a Mac `/tmp/…` is `/private/tmp/…` and `/var/…` is `/private/var/…`.
- Secrets Kermo recognises in what the agent reads (keys, tokens, passwords in configs) are replaced with `•••`. The patterns are not complete: don't point an agent at files whose content must not leave this Mac.
- A command gets 30 seconds and 256 KB of output, with no terminal: nothing interactive.
- Commands run on servers only, not on this Mac.
- Deleting, moving and archiving are not among the tools yet.
- The journal is kept in memory and goes with the connection.
