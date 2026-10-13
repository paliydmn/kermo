# Shell integration

The ⌃O terminal runs your login shell with `TERM_PROGRAM=Kermo`, so Apple's Terminal.app hook in `/etc/zshrc` doesn't load. Three lines in `~/.zshrc` bring it back, only inside Kermo:

```zsh
# ~/.zshrc — in Kermo's ⌃O terminal: the panel follows `cd`, the tab is named after the folder,
# and the ` cd` the app types stays out of your history.
if [[ $TERM_PROGRAM == Kermo ]]; then
  setopt HIST_IGNORE_SPACE
  source /etc/zshrc_Apple_Terminal   # Terminal.app's own `update_terminal_cwd` (OSC 7); nothing else without TERM_SESSION_ID
fi
```

Without it the panel still follows the shell's folder when you hide the terminal (⌃O), and the tab gets its folder's name when it's shown or switched to; with it both update on every `cd`. (fish, bash: not checked.)

The editor saves protected files such as `/etc/hosts` through **Save as Administrator**. The ⌘I Info window also offers administrator-authorized chmod and chown operations.
