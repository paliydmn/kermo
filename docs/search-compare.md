[Kermo documentation](../README.md#documentation)

# Search, compare and synchronize

Filter a folder's listing, find files below it, and compare or synchronize two folders or two files.

## Quick filter

Press / (**View ▸ Quick Filter**) to type a filter under the list: the field says **Filter: text, *.log or re:regex**, and the key bar shows its keys while you type — **↩ Keep**, **↓ Back to List**, **⎋ Clear**. The list shrinks as you type, and the status line shows `filtered: 3 of 40`. Matching ignores case.

- Text matches anywhere in a name: `report`.
- Glob (text with `*`, `?` or `[`) matches the whole name: `*.log`. Separate globs with `;` (a comma works too). Each part is matched on its own, and a part without `*`, `?` or `[` is wrapped in `*`…`*`, so write `*.log;*notes*`. A name that contains a comma or semicolon can be matched only with a wildcard or a regex.
- Regex, after `re:`, matches anywhere in a name: `re:^v\d+`. While it doesn't compile, nothing is hidden.

↩ or ↓ keeps the filter and returns to the list. ⎋ clears it while you are typing in the filter field; to clear a kept filter, press / and then ⎋, or leave the folder. The filter covers files and folders of this listing, not subfolders (use [Find files](#find-files)). It ends when you leave the folder, and each tab keeps its own. Back in the list, ⌘A marks only what the filter shows, and the marks stay when you clear it.

⌘/ (**View ▸ Filter Presets…**) lists your presets, then up to 20 recent filters you confirmed with ↩. Choose one, or type a filter and press ↩.

**Kermo ▸ Configuration ▸ Edit Filter Presets…** opens `~/.config/dfilemanager/filters.json` and writes six examples the first time. The file is a JSON array of presets: `[ { "title": "Logs", "filter": "*.log;*.err" } ]`. A file that doesn't parse shows an error and no presets.

## Find files

Press ⌘F (⌥F7, **Go ▸ Search Files…**) to search below the active panel's folder. The dialog remembers your last entries. Everything you fill in must match:

- Name (first field): the quick-filter rules, always ignoring case. Empty matches any name.
- Text (second field): files whose content holds the text, matched literally as UTF-8. Files saved as UTF-16 or in a legacy code page (cp1251, say) won't match; ignoring case covers Latin, Greek, Cyrillic and Armenian letters. Files not downloaded from iCloud or Dropbox are skipped, and a message says how many.
- Tag (third field): items with that Finder tag.
- **Case-sensitive text** applies to the text field only.
- **Include hidden files and folders:** off skips dotfiles and items macOS flags as hidden (such as `~/Library`), and doesn't enter hidden folders. On a server only names starting with a dot are skipped.
- **Use Spotlight index (fast, skips what Spotlight doesn't index):** finds only what Spotlight has indexed. Without it, the search walks the folder and stays on its volume.

The results replace the panel's listing as they are found, named by their path below the folder. They behave like a listing: mark hits, then view (F3), edit (F4), preview (⌘Y), copy, move or delete them right there. The quick filter narrows them. The status line shows `searching… 12 found`, then `12 found`, with **⌫ Back** beside it: ⌫ or a click goes back to the folder.

- ↩ on a file opens its folder with the cursor on it. ↩ on a folder enters it.
- ⎋ does not stop a running search. ⌫ does, and leaves the results.
- On a server, the search runs there (`find` and `grep`, GNU `find` required) and the tag and Spotlight options are hidden. See [Files on a server](server-files.md#preview-sizes-and-compare).

The toolbar search (**Go ▸ Search…**, ⇧⌘P) finds commands, folders and files in the panel; its last row opens this dialog with your text. See [Panels, sidebar and search](window.md#search).

## Compare folders

Press ⇧F2 (**Mark ▸ Mark Differences**) to mark what differs between the active panel's folder and the other panel's, subfolders included. It changes no files and replaces the marks you had.

- A file is marked on the side where it is newer, or where the other side lacks it. The same date with a different size marks it on both sides. Contents are not read.
- A folder is marked on the side that holds something newer or missing inside it.
- Names match ignoring case. Hidden files count only while they are shown. Marks that a filter hides are counted in the message instead.

F5 opens **Copy To…** with the other panel's folder filled in, so the marked items go there. For the opposite direction, make the other panel active and press F5 (with three or four panels, F5 targets the previously active panel). In an archive or in search results, only the listed names are compared. ⎋ stops the comparison.

## Synchronize folders

Press ⇧⌘S (**Mark ▸ Synchronize Folders…**) to bring two folders in line. Both panels must show folders, on this Mac or on servers. The panel further left is the left side.

The **Synchronize Folders** window lists every difference below both folders. Nothing is copied until you click **Synchronize** (↩). ⎋ closes the window: nothing is queued, and a comparison in progress stops. Its key bar shows ↩ Synchronize and ⎋ Close, then the menu keys that work there, as in the viewer.

| Mode | Files that differ | Items on one side only |
|---|---|---|
| **Two-way (newer wins)** | The newer replaces the older. Same date, different size: skipped as a conflict (≠) | Copied to the other side |
| **Mirror → right** | The left replaces the right, even if the right is newer | Only left: copied. Only right: to the Trash |
| **Mirror ← left** | The right replaces the left, even if the left is newer | Only right: copied. Only left: to the Trash |

- **Compare contents (slow)** also reads files with equal size and date and flags a difference as a conflict. It is available only when both folders are on this Mac.
- **Include hidden** is off by default. **Show equal** adds the identical files to the list.
- Select rows, then **→ Right**, **← Left**, **Trash** or **Skip**, or click a row's arrow to cycle its action. Choose the mode and the checkboxes first: changing the mode, **Compare contents** or **Include hidden** recomputes the list and drops the directions you set by hand.
- Trash runs first, then the copies, in the queue above the key bar. Each job skips an item that changed since the comparison. A folder deleted on a server keeps whatever was put in it since the comparison began (a file written then, a folder moved in), with the folders above it, and the summary names each. Kermo goes by this Mac's clock here, so on a server whose clock runs behind, such a change may still go.
- A name that is a file on one side and a folder on the other, a folder that can't be read, names that differ only in case within one side, and a file named in another case on each side (`README` here, `readme` there) when the two differ, are always skipped (≠ or "can't read"), in every mode: a mirror isn't an exact copy there.

> [!WARNING]
> Once you click **Synchronize**, files are replaced with no further prompt and no copy in the Trash. On a server, mirror and **Trash** delete for good, because a server has no Trash. Kermo asks first for a delete there and for any change on a production server.

## Compare files

Press ⇧⌘D (**Mark ▸ Compare Files**) to diff two files. Kermo uses the first of these that applies:

1. Two files marked in the active panel.
2. The cursor's file and the file of the same name in the other panel's folder.
3. The cursor's files in both panels.

Folders are never compared. The result opens in a window as `diff -u`: added lines green, removed red, `@@` lines purple, and `Files are identical.` when they match. ⎋ closes it.

To use your own tool, set `diffCommand`. Kermo runs it through zsh with `%1` and `%2` replaced by the quoted paths, and opens no window:

```sh
defaults write com.dmn.dfilemanager diffCommand 'code --diff %1 %2'
```

`defaults delete com.dmn.dfilemanager diffCommand` brings back the built-in window. A server's file is fetched first and compared as a local copy. Compare folders and Synchronize also work with a server: see [Files on a server](server-files.md#preview-sizes-and-compare).
