[Kermo documentation](../README.md#documentation)

# Git

See what changed in a repository without leaving the panel. Everything below works in folders on this Mac. In an SFTP panel you get the status column, the branch with ↑↓ and ⌃G when the server has git 2.26 or newer; the other actions work on this Mac only.

## In the panel

In a Git repository the panel shows a **status column**, and the status bar shows the branch and ↑↓ for commits ahead of and behind its upstream.

| Action | Keys |
|---|---|
| Show only changed files | ⌃G |
| Show all changes as a list | ⌃⇧G |
| Diff against HEAD | ⌃D |
| Log of the file, with patches | ⌃L |
| Blame, in the viewer | ⌃⇧L |
| Stage / unstage the marked files | ⌃⇧A / ⌃⇧U |

## When there is no Git column

Kermo needs the Command Line Tools (or Xcode) on the Mac, because it runs `/usr/bin/git`, or git on the server. A folder you browse is untrusted: its `.git/config` can name commands that `git status` would run. So Kermo reads a repository only when its own config holds harmless keys: your user, branches, remote URLs, `core.filemode` and the like. A repository whose config sets anything else (aliases, filters, signing, diff drivers, `core.fsmonitor`) shows no Git column and no branch. This holds on servers too. Your own global git config is trusted.
