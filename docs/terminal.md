[Kermo documentation](../README.md#documentation)

# Terminal and SSH sessions

A shell inside Kermo, local or on a server, that stays in step with the panels.

## Open the terminal

- **⌃O** opens the terminal as a drawer under the panels: your login shell on a local panel, the server's SSH session on a server panel. The panels stay in view, and the active one follows the shell's `cd`. Drag the line above the drawer to change its height; Kermo keeps it, also after a restart.
- **⌃⇧O** (**View ▸ Maximize Terminal**) gives the terminal the panels' room too, as ⌃O did before the drawer; press it again to put the terminal back in its drawer. A command that needs the panels (Connect to a folder, Show in Activity, a tag in the sidebar) puts it back too.
- **The focus decides where keys go.** Click in the terminal (or press ⌃O from a panel while the drawer is open) and keys go to it: the key bar shows the terminal's keys and the panels' commands rest. Click a panel (or press ⌘1–⌘4) and the panels work as without a terminal, with their key bar and the command line. Clicking the sidebar or searching in between changes nothing.
- **⌃O** with the keys in the terminal hides it; the active panel goes to the shell's folder. Press **⌃O twice quickly** to send ⌃O to the program in the terminal.
- The drawer's top row has its tabs and four buttons: **⋯** (the pane's [marks and Open in Editor](#marks-and-the-editor), as **View ▸ Terminal Pane** has them), **Split** (⌘\\), **Maximize** (⌃⇧O; **Restore** while maximized) and **Hide** (⌃O).
- While the keys are in the terminal, the [key bar](window.md#key-bar) shows its keys: **⌃O Hide Terminal**, **⌃⇧O Maximize**, **⌘T New Tab**, **⌘W Close Tab**, the splits, **⌘↑ Prev Mark**, **⌘↓ Next Mark**, **⇧⌘A Copy Output**, **⌃⇥** for the next tab, **⌘1**–**⌘4** back to a panel and the rest; holding ⌥⌘ shows the pane keys, ⌃⌘ the divider keys.
- **⌘K** opens a shell on a server in a new tab ([Servers and SSH](servers.md)). Inside the terminal, ⌘K clears it.
- **⌘+** and **⌘−** change the text size.

While the keys are in the terminal:

- Clicking a local place in the sidebar runs `cd` there in the shell.
- **⌃↩** types the active panel's cursor name and **⌃⇧↩** its marked items' full paths into the shell (from a panel they go into the command line).
- Files dropped on the terminal are typed into its shell as quoted paths (a local shell only: a server can't see this Mac's files).

From the editor, ⌃↩ types the line or the selection into a shell of the file's machine and ⌃⇧↩ runs it there ([Send to Terminal](viewer-editor.md#send-to-terminal)): only into a shell waiting for a line, else into a new tab.

### Copy and paste with the mouse

As in PuTTY: **selecting text copies it** — a drag, a double-click on a word, a triple-click on a line — and **a right-click pastes** the clipboard where the cursor is. ⌘C and ⌘V work as before.

- In a program that reads the mouse itself (mc, htop, vim with `mouse=a`, Claude Code), a right-click is the program's: **⇧-right-click** pastes there. **⇧-drag** selects text in the terminal, and the selection is copied when you let go of the button.
- **⌥-drag** selects a block: the same columns of each line, in any program.
- The wheel and the trackpad scroll such a program, and less, man or `git log` too, as in Terminal.app. With ⌥ held, the wheel scrolls the terminal's own scrollback instead (⇧ too, on a trackpad: macOS turns ⇧ with a mouse wheel into sideways scrolling); a full-screen program (vim, mc, less) has none, so nothing moves.
- A program can put text into the clipboard itself (OSC 52): Claude Code does when you select its text, and so do tmux and vim. It works in local and SSH tabs, in the tab in front. A program can't read the clipboard this way.
- A shell that asked for bracketed paste (zsh, bash 5.1 and later) runs nothing pasted until you press ↩. Pasting several lines into a **production** server's SSH tab, or one logged in as `root@`, into a shell that didn't ask for it (`sh`, an old bash), asks first: “Paste 5 lines into web1?”, with its PROD or ROOT strip, the lines themselves and ↩ on Cancel.
- Selecting replaces what the clipboard held. To keep it, turn either part off: `terminalCopyOnSelect`, `terminalRightClickPaste` ([Options](#options)).

### Find and select

- **⌘F** opens a find bar over the terminal. It searches the scrollback and the screen as you type; **Aa**, **.\*** and **Word** match case, take a regular expression, match whole words. ↩ finds the next one and ⇧↩ the one before, as the bar's arrows do; ⎋ closes it. With the keys in the text, the bar open or closed, ⌘G finds the next one. A match is selected but never copied: the clipboard keeps what you copied.
- **More than the window shows:** drag past the window's top or bottom edge — the scrollback scrolls, and the selection grows with it until you let go. Or double-click the first word, scroll to the last line, ⇧-click there. A selection stays on its text as new lines come in; a program that redraws the screen under it (`clear`) drops it. ⌘A selects the whole scrollback and screen, and copies it.
- **Links:** ⌘-click on a link a program printed with a hidden target (OSC 8, as `ls --hyperlink` prints them: the text shows one thing, the target may be another) opens nothing. Text from a server isn't trusted.

## Marks and the editor

Each ↩ you type at a shell marks the line it was typed on, as in Terminal.app: nothing is set up on the server and nothing is sent there. Not in vim, less, mc or another program that has the whole screen. The marks are in Kermo's memory only.

- **⌘↑** (**View ▸ Terminal Pane ▸ Previous Mark**) goes to the last command, then to the one before. Its line moves to the top of the terminal as far as it scrolls, and a short bar beside it shows where you are. **⌘↓** goes to the next one, and after the last back to the bottom. If you scrolled by hand, they go from the top line in view. In the panels, ⌘↑ and ⌘↓ are Go's as before; in the terminal ⌫ is the shell's.
- **⇧⌘A** (**View ▸ Terminal Pane ▸ Copy Output of Last Command**) copies what a command printed: the one ⌘↑ / ⌘↓ went to, else the last one that printed anything. A long line the terminal wrapped is one line again; spaces at the ends of lines and empty lines at the end are left out. With nothing to copy it beeps, and the clipboard stays as it was.
- Marks go when the lines move under them: ⌘K, `clear`, `reset`, a change of the terminal's width (a split, Join, the window's width), or a lower drawer that cuts rows (a full scrollback of 10,000 lines; a screen with empty lines under the prompt drops them too). ⌃L drops the marks on the screen it cleared, and the oldest go with the scrollback. A mark never lands on another command's line.
- zsh, bash 5.1 and later and fish say when they're at their prompt (bracketed paste), so there a ↩ pressed while a command runs, in `read` or at a password question isn't marked. In other shells (sh, an older bash) every ↩ outside a full-screen program is: harmless, a mark is only a place to go. Once a zsh, bash 5.1 or fish has run in a tab, an older shell started from it there (`ssh` to an old server, `exec bash`) gets no marks. Kermo's own lines count as typed: ⌘E ↩'s line, Execute in Terminal's, the `cd` a sidebar click types.
- Copy Output takes everything up to the next command's line: with a prompt of two lines (powerlevel10k, starship), the prompt's upper line comes at the end of the copy. In bash a last output line without a line break shares its row with the prompt and is left out (zsh puts the break in). A line that both clears and prints, such as `clear && make`, keeps a mark on a row of its own output: Copy Output then gives that output from there on.
- A shell that marks its own prompts (OSC 133: fish 4, a zsh or bash set up for it) adds those prompts as stops for ⌘↑ / ⌘↓ where there are no marks, for example above a width change.

**⌥⌘O** (**View ▸ Terminal Pane ▸ Open in Editor**) opens the pane in the [editor](viewer-editor.md#a-terminals-text) as a read-only copy: the selection if there is one, else the scrollback and the screen; with vim, mc or less running, the screen. **Open Output in Editor** does the same with Copy Output's text.

## Sessions side by side

One tab can show up to four sessions at once: run a command in one and watch a log in another, without switching tabs. It works as the split in VS Code's terminal.

- **⌘\\** splits the tab: a new session to the right of the current one. **⇧⌘\\** puts it below instead. The first split picks the way; later splits in that tab follow it.
- A new pane on a server is another SSH session to that server. It uses the connection that's already open, so it doesn't log in again. It starts in the folder the server's shell reported ([Shell integration](#shell-integration)), else in your home folder there. A local pane is a shell in the same folder.
- **⌥⌘←** **→** (side by side) or **⌥⌘↑** **↓** (one above another) move to the next pane, and so does a click. Keys go to the pane with the bold title and the colored line in its header. A production server's header is purple and a `root@` login's is orange.
- Drag a divider to resize, or press **⌃⌘** with an arrow. A double-click on a divider makes the panes the same size.
- **⌘W** or the header's × closes one pane. The tab's × closes all its panes and asks once if any of them is still running something. The question is a sheet on the window, as for one pane.
- **View ▸ Tabs ▸ Join Tab…**, or **Join with Current Tab** in another tab's right-click menu, moves that tab's sessions into the current tab. **Move Pane to New Tab** (in the header's right-click menu, or **View ▸ Tabs**) takes a pane out into its own tab.
- After a restart, SSH sessions come back in the same tabs, in the same order and arrangement, not connected. Panes start at equal sizes.

## Shell integration

The terminal sets `TERM_PROGRAM=Kermo`, so Apple's Terminal.app hook in `/etc/zshrc` doesn't load. A few lines in `~/.zshrc` bring it back, only inside Kermo:

```zsh
# ~/.zshrc — in Kermo's ⌃O terminal: the panel follows `cd`, the tab is named after the folder,
# and the ` cd` the app types stays out of your history.
if [[ $TERM_PROGRAM == Kermo ]]; then
  setopt HIST_IGNORE_SPACE
  source /etc/zshrc_Apple_Terminal   # Terminal.app's own `update_terminal_cwd` (OSC 7); nothing else without TERM_SESSION_ID
fi
```

Without it the panel still follows the shell's folder when you hide the terminal (⌃O), and the tab gets its folder's name when it's shown or switched to. With it, both update on every `cd`. fish and bash aren't checked.

## Touch ID for sudo

**File ▸ As Administrator ▸ Enable Touch ID for sudo** (also in ⇧⌘P) lets `sudo` in a terminal on this Mac take your fingerprint instead of your password. Kermo asks first, then writes `/etc/pam.d/sudo_local` — macOS's `sudo_local.template` with its `pam_tid.so` line on — and macOS asks for your password once to write it. A `sudo_local` of your own keeps its lines; the Touch ID line goes after them (one that is a symlink, kept by nix-darwin or the like, is left alone). The file survives macOS updates; new terminal windows use it. If it's on already, Kermo says so and asks nothing.

- **Turning it off:** `sudo rm /etc/pam.d/sudo_local` (or put `#` before the `pam_tid.so` line in it).
- **In tmux or screen** Touch ID needs [pam_reattach](https://github.com/fabianishere/pam_reattach): `brew install pam-reattach`, then the line `auth optional /opt/homebrew/lib/pam/pam_reattach.so` in `sudo_local` before the `pam_tid.so` one.

## Options

Set them in Settings › Terminal, or with `defaults write com.dmn.dfilemanager <key> <value>`:

| Key | Meaning |
|---|---|
| `terminalFont` | Font of the terminal, for example `'MesloLGS NF'` for Powerlevel10k or Starship prompt icons. SF Mono by default. |
| `terminalFontSize` | Its size, 13 by default, 9–36. The same ⌘+ / ⌘− change, saved automatically. |
| `terminalOptionIsMeta` | `true` by default: ⌥ is Meta (⌥B and ⌥F in zsh). `false` lets ⌥ type your layout's characters (`@`, `\|`, `[`, `]`). |
| `terminalCopyOnSelect` | `true` by default: a selection goes to the clipboard as it's made. `false`: only ⌘C copies. |
| `terminalRightClickPaste` | `true` by default: a right-click pastes. `false`: it does nothing, as before. |
| `terminalBundleID` | The app that ⌥⌘T and ⌘↩ open on this Mac's folders, for example `com.googlecode.iterm2`. Terminal.app by default. On a server panel both open an SSH tab in Kermo. |
