[Kermo documentation](../README.md#documentation)

# Install Kermo

Kermo needs macOS 14 or later and runs on Apple Silicon and Intel Macs.

## Install a release

1. Download the `.dmg` or the `.pkg` from the [latest release](https://github.com/paliydmn/kermo/releases/latest).
2. Open the DMG and drag **Kermo** to Applications. With the `.pkg`, open it and run the standard macOS installer, which puts Kermo in Applications.
3. Kermo isn't notarized by Apple, so macOS blocks it the first time: when you open the app from the DMG, or when you open the `.pkg`. Allow it:
   - on macOS 15 or later, click **Open Anyway** in System Settings ▸ Privacy & Security;
   - on macOS 14, Control-click it and choose **Open**.

## Updates

Once a day Kermo asks GitHub for its latest release: one HTTPS request to `api.github.com`, with nothing in it but Kermo's version. When a newer version is out, the status line says so once and the Kermo menu shows **Kermo X.Y Available…** until you update or skip it. No window opens by itself, and without a network nothing happens.

**Kermo ▸ Check for Updates…** (or `update` in ⌘⇧P) checks at once and shows the release notes:

- **Download** opens the release page; replace Kermo in Applications with the new app;
- **Later** keeps it in the menu;
- **Skip This Version** forgets this one; the next one is announced again.

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
