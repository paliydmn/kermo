[Kermo documentation](../README.md#documentation)

# AI: chat and agents

Two ways to work with AI in Kermo, both with your own account and nothing of Kermo's in between:

- **The chat** (⌃⌘I): ask your own model about what is open — a folder, a file, the editor, the terminal. It reads, with your permission, and answers; it changes nothing. → [The chat](#the-chat)
- **Agents in Kermo's terminal**: [Claude Code](https://claude.com/claude-code) or another MCP client works where Kermo is connected — reads and copies files, runs commands on your servers, opens a file in the editor. The agent calls Kermo's tools; Kermo asks you before anything you haven't allowed. → [Switch it on and connect Claude Code](#switch-it-on-and-connect-claude-code)

Both are off until you set them up, and Kermo sends nothing anywhere by itself.

## Your own AI

The chat talks to a model provider with your own key: **Settings › AI**, under **Your own AI**. There is no Kermo server or account in between: requests go straight from this Mac to the address you set.

1. **Provider:** Anthropic, or an OpenAI-compatible server — OpenAI itself, or one on your Mac or network such as [Ollama](https://ollama.com) (`http://localhost:11434/v1`) or [LM Studio](https://lmstudio.ai) (`http://localhost:1234/v1`).
2. **Address:** empty means the provider's own (`https://api.anthropic.com`, `https://api.openai.com/v1`).
3. **API key:** paste it and press **Save**. It goes to the Keychain (item **Kermo AI**), kept for that address only: change the address and the key isn't sent there. It's read once a launch, when first needed. **Remove** deletes it. A server on your Mac or network usually needs no key.
4. **Test** lists the models your key may use, then asks the chosen model for one word — a fraction of a cent — and says what came back, or why not. Pick the **Model** from the list (Anthropic: `claude-sonnet-5-5` until you choose; a server on your Mac or network: its first). Switching the provider clears the address and the model.

Until you press **Test** or send a question in the chat nothing of this runs: no request, no key read.

**A Claude plan and the API are billed apart.** Pro doesn't include API use; Max, Ultra and Team come with [monthly API credits](https://platform.claude.com/docs/en/about-claude/api-credits-for-subscribers) once you link a Console organization, and a key from it draws on them. To work on your plan instead, run Claude Code in Kermo's terminal and connect it below.

Plain `http` is allowed only to this Mac and private networks (`localhost`, `10.*`, `172.16–31.*`, `192.168.*`, `*.local`) when there is a key; to any other address your key is never sent and Settings warns that the chat would go unencrypted. macOS doesn't let Kermo use plain `http` to a name on the internet at all (an address in numbers it lets through): use `https` there.

## The chat

**⌃⌘I**, the ✨ button at the right of the toolbar or **View ▸ AI Chat** shows the chat at the right of the window, beside the panels and the terminal; ⌃⌘I from the chat hides it. Drag its edge to make it wider; Kermo remembers the width and whether it was shown. Without a key it shows **Use your own AI**, which opens **Settings › AI**.

The chat is in **Ask**: the model reads and answers, and changes nothing. For a change it gives you the commands or the text, and you do it.

1. **Attach what the question is about.** Under the field Kermo suggests what is open, dashed: the active panel's folder and the file under the cursor, the editor's document and its selection, the terminal's last command with its output. A click attaches one; **+** or **#** in the field lists everything open in both panels. Nothing is attached until you choose it. A click on an attached chip shows exactly what goes, with **Remove**.
2. **Ask** and press ↩ (⇧↩ for a new line). The 👁 button shows **what will be sent** with the message: Kermo's instructions to the model, each attachment and your words.
3. **The answer** comes as it is written. A shell command comes in a block with **Into Terminal** — it goes into the line of the terminal tab on the machine in front of you, and nothing runs until you press ↩ there — and **Copy**. Under each answer: the tokens it took, in and out — and, for Anthropic's models at Anthropic's own address, what they cost at Anthropic's prices as of 2026-11 (cache reads and writes counted). Your bill is the provider's; other providers show tokens only.
4. **⎋ or the Stop button** stops the answer, and any question of the chat that is waiting. What the model asked for and didn't get yet isn't done.
5. **The model reads by itself** where it needs to: the folders, files, terminal output and server info it asks for, and commands that only read (Kermo's allow-list: `cat`, `tail`, `ls`, `df`, `journalctl`, `systemctl status`, `nginx -t`…). The first read on each server — and on this Mac — asks you in the chat: **Allow in This Chat**, or **Cancel** (↩). Every read shows as a step; a click shows what came back. A command that could change something is refused without a question. A turn stops after 10 rounds of reading; say "go on" to let it continue.

When the provider says no — a limit, too busy, no network — the chat says so in words with **Retry**; a key it doesn't accept, with **Settings…**. Kermo never retries by itself: each request is your money.

**New Chat** (the pencil at the top) starts again: what the model was allowed is gone.

### Chats on this Mac

Kermo keeps the last 50 chats in `~/.config/dfilemanager/ai`, one file each, only yours to read (folder 0700, files 0600), written after each message and each answer. A file holds what went to the provider — your words and attachments as they went, secrets as `•••` — and the model's answers; never your key. The 🕘 at the top lists them, the latest first, with the model each began with: a click opens one to go on with. **Delete** removes one for good (not to the Trash). Past 50, the oldest go by themselves.

A chat opened again shows its questions, what was attached (by name) and the answers — not the reads. It asks again before its first read on each server and before sending anything from a production server; it stays with the provider it began with; under **Never Send**, one that holds production text goes no further. Its earlier thinking isn't sent again: providers check it against what it was written with.

**Settings › AI › Keep chats on this Mac** off: nothing is written — the chat open then isn't written again, even once it's back on; Kermo asks whether to delete the chats already kept. A file Kermo can't read — damaged, a newer Kermo's, readable by others — is left as it is and named in the list.

### Production servers

Something attached from a [production server](safety.md) asks once a chat for each server before it is sent, ↩ = **Cancel**; after **Send** a purple line says it goes. Kermo also tells the model that the server is production and to be careful — in the message and in what a read there returns; **What will be sent** shows it. In **Settings › AI**, **Production servers: Never Send** keeps everything from production servers out of the chat: such a chip isn't attached and the model's reads there are refused. Where the panels stand (a server's name and folder) the model may still learn from `focus`.

### What goes to your provider

- Kermo's instructions for the chat and the descriptions of its tools — the same in every chat;
- your messages, with what you attached — and, in a chat opened again, its earlier messages and answers;
- what the model's reads return.

Passwords, tokens and keys Kermo recognises are replaced with `•••` before anything is sent — in what you type too. The patterns are not complete: don't attach files whose content must not leave this Mac. Every earlier message of the chat goes again with each new one, as providers need.

## Switch it on and connect Claude Code

1. Open **Settings › AI** (⌘,) and switch on **Allow agents in Kermo's terminal (MCP)**.
2. Open a **new** terminal tab in Kermo (⌃O). Tabs opened before the switch don't know about it.
3. Once, tell Claude Code about Kermo. **Settings › AI** shows the line with the right path:

   ```
   claude mcp add -s user kermo -- /Applications/Kermo.app/Contents/MacOS/Kermo --mcp
   ```

   `-s user` makes it work in every folder; without it Claude Code knows Kermo only in the folder where you ran the line.

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

The agent acts as you: on a server, as the user you log in as. Kermo never opens a root session for it, but a command may say `sudo` itself, and where your user has passwordless `sudo` that works — `sudo cat /etc/shadow` counts as a command that only reads.

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
