[Kermo documentation](../README.md#documentation)

# Install Kermo

Kermo needs macOS 14 or later and runs on Apple Silicon and Intel Macs.

## Install a release

1. Download the `.dmg` or the `.pkg` from the [latest release](https://github.com/paliydmn/kermo/releases/latest).
2. Open the DMG and drag **Kermo** to Applications. With the `.pkg`, open it and run the standard macOS installer, which puts Kermo in Applications.
3. Kermo isn't notarized by Apple, so macOS blocks it the first time: when you open the app from the DMG, or when you open the `.pkg`. Allow it:
   - on macOS 15 or later, click **Open Anyway** in System Settings ▸ Privacy & Security;
   - on macOS 14, Control-click it and choose **Open**.

To update, replace the app in Applications. Releases are signed ad hoc, so macOS can ask again for permissions such as Full Disk Access after an update.

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
