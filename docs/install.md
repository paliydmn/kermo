[Kermo documentation](../README.md#documentation)

# Install Kermo

Kermo needs macOS 14 or later and runs on Apple Silicon and Intel Macs.

## Install a release

The quickest way: paste this into Terminal and press Return.

```sh
curl -fsSL https://raw.githubusercontent.com/paliydmn/kermo/master/install.sh | sh
```

It downloads the latest release's `.pkg`, checks its SHA-256, takes Kermo out of it (nothing is mounted or run as an installer), quits Kermo if it's open, puts Kermo in Applications and opens it. The same line updates Kermo. Run it in Terminal, not in Kermo's own terminal, since it quits Kermo. If Kermo came from the `.pkg` (then it belongs to root), it asks for your password. A file `curl` downloads isn't quarantined, so macOS doesn't ask for **Open Anyway**: [the script](../install.sh) is what you trust instead.

By hand:

1. Download the `.dmg` or the `.pkg` from the [latest release](https://github.com/paliydmn/kermo/releases/latest).
2. Open the DMG and drag **Kermo** to Applications. With the `.pkg`, open it and run the standard macOS installer, which puts Kermo in Applications.
3. Kermo isn't notarized by Apple, so macOS blocks it the first time: when you open the app from the DMG, or when you open the `.pkg`. Allow it:
   - on macOS 15 or later, click **Open Anyway** in System Settings ▸ Privacy & Security;
   - on macOS 14, Control-click it and choose **Open**.

## Updates

Once a day Kermo asks GitHub for its latest release: one HTTPS request to `api.github.com`, with nothing in it but Kermo's version. When a newer version is out, the status line says so once and the Kermo menu shows **Kermo X.Y Available…** until you update or skip it. No window opens by itself, and without a network nothing happens.

**Kermo ▸ Check for Updates…** (or `update` in ⌘⇧P) checks at once and shows the release notes:

- **Install and Relaunch** downloads the new version, checks that it's signed with the same certificate as this Kermo (nothing else is trusted: a changed file or another signer is refused), puts it in place of this one and opens it. If Kermo belongs to root (installed from the `.pkg`), macOS asks for your password first. A Kermo run from the disk image, or a build of your own, can't be updated this way and offers the release page instead. Releases without a `.zip` (1.2.1 and older) offer **Download**: it opens the release page; replace Kermo in Applications with the new app, or run the [install line](#install-a-release) again;
- **Later** keeps it in the menu;
- **Skip This Version** forgets this one; the next one is announced again.

Install and Relaunch comes with Kermo 1.4.1. Kermo 1.2.1 and older offer only **Download**: update them once with the [install line](#install-a-release) or by hand.

Turn the daily check off with **Kermo ▸ Check for Updates Automatically**, or `defaults write com.dmn.dfilemanager updateCheckOff -bool true`.

Releases after 1.2.1 are all signed with one certificate, so Full Disk Access and other permissions survive an update. Saved passwords in the Keychain may still ask once per update: click **Always Allow**.

Kermo was called DFileManager before. Settings carry over (same config folder, same defaults); delete the old DFileManager.app.

## Build from source

You need the Command Line Tools; Xcode isn't required. See [Contributing](../CONTRIBUTING.md#build-and-run).

## Uninstall

1. Quit Kermo and drag Kermo.app to the Trash.
2. Optional, to remove everything it kept:
   - the folder `~/.config/dfilemanager` (settings, saved servers, file history, production log);
   - its options: `defaults delete com.dmn.dfilemanager`;
   - the `fm` link in `/usr/local/bin`, if you installed it;
   - the Keychain items "Kermo: …" and "Kermo sudo: …" (Keychain Access).
