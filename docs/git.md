[Kermo documentation](../README.md#documentation)

# Git

See what changed in a repository, switch branches, commit and sync without leaving the panel. Everything below works in folders on this Mac. In an SFTP panel you get the status column, the branch with ↑↓, the sidebar's Git row and ⌃G when the server has git 2.26 or newer; the other actions work on this Mac only.

All of these are in the **Git** menu and in search (⇧⌘P).

## In the panel

In a Git repository the panel shows a **status column**, and the status bar shows the branch and ↑↓ for commits ahead of and behind its upstream. In the column, `M` (modified, also `R` renamed, `C` copied, `T` type changed) is amber, `A` (added) green, `?` (untracked) and `D` (deleted, struck through) grey, and `U` with ⚠ is a conflict, in red. A bold letter is staged. `•` on a folder means changes inside.

| Action | Keys |
|---|---|
| Show only changed files | ⌃G |
| Show all changes as a list | ⌃⇧G |
| Diff against HEAD | ⌃D |
| Log of the file, with patches | ⌃L |
| Blame, in the viewer | ⌃⇧L |
| Stage / unstage the marked files | ⌃⇧A / ⌃⇧U |

## The Git row in the sidebar

When the active panel is in a repository, a **Git** section sits at the bottom of the sidebar: the repository's name, then one row with the branch. It follows the active panel, and it isn't there outside a repository. The row shows only what there is to tell:

- `±5`: changes in the panel's folder, as its Git column counts them;
- `⚠ 2` in red: files in a merge conflict;
- `↓2 ↑1`: commits to pull and to push, as of the last fetch (the tooltip says when that was);
- a cloud: the branch isn't on a remote yet.

Under the mouse the row shows **Git Changes**, **Commit**, **Sync** (**Publish** for a branch no remote has) and **⋯** with everything else. A click on the row opens **Switch Branch**. The row costs no extra git: it reads the `git status` the panel already runs for its column. On a server panel it shows the state, and ⋯ copies the branch name or goes to the repository's root.

## Switch and create branches

**Switch Branch…** (⌃B) lists the local branches, then remote branches that have no local one, then tags, newest first, each with its last commit and age.

- ↩ switches. A remote branch becomes a local one that follows it; a tag checks out its commit (detached).
- Type a name that isn't there and choose **Create branch “name”**: spaces become dashes. ⌘N on a row creates a branch from that one.
- ⌘⌫ deletes a merged branch. It uses `git branch -d`, so git keeps a branch that isn't merged and says so.
- A branch whose remote was deleted (a merged pull request, after **Fetch**) shows "remote gone".

If uncommitted changes would be overwritten, git refuses to switch and Kermo shows what it said.

## Commit

**Commit…** (⌃⇧C) opens the same search window. Type the message in its field, then choose what goes in:

- **Commit N staged files**;
- **Commit all N changes**, which stages everything first;
- **Amend the last commit**, while it isn't pushed yet.

With nothing typed, the window lists the changed files of the whole repository; ↩ shows a file's diff. The message is one line; for a longer one, use the terminal (⌃O). Hooks run as they do in a terminal. While files are in conflict there is no commit: resolve them first (⌃⇧G lists them).

## Sync with the remote

| Command | What it runs |
|---|---|
| **Sync** | `git pull --ff-only`, then `git push` |
| **Publish Branch** | `git push -u origin <branch>` |
| **Pull** | `git pull --ff-only` |
| **Push** | `git push` (Publish for a branch no remote has) |
| **Fetch** | `git fetch --prune` |

Kermo never fetches by itself, and never forces, rebases, merges or stashes. When the branch and its remote went apart, `--ff-only` stops with git's explanation: merge or rebase in the terminal. A key's passphrase or an https password is asked in the same dialog as for servers; ⎋ stops a command that waits.

When a command works, the status bar says so. When git refuses, a sheet shows everything it said.

## A new repository

**Initialize Git Repository…** runs `git init` in the active panel's folder. It shows the folder's full path first, because a repository in the wrong place, say your home folder, makes every folder under it part of one. It refuses inside a repository.

## When there is no Git column

Kermo needs the Command Line Tools (or Xcode) on the Mac, because it runs `/usr/bin/git`, or git on the server. A folder you browse is untrusted: its `.git/config` can name commands that `git status` would run. So Kermo reads a repository only when its own config holds harmless keys: your user, branches, remote URLs, `core.filemode` and the like. A repository whose config sets anything else (aliases, filters, signing, diff drivers, `core.fsmonitor`) shows no Git column, no branch and no Git row, and the Git actions don't run there. This holds on servers too. Your own global git config is trusted.
