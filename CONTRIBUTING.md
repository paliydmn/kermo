# Contributing to Kermo

Found a bug or have an idea? Open an [issue](https://github.com/paliydmn/kermo/issues). For a change to the code or the docs, open a pull request.

## Build and run

You need macOS 14 or later and the Command Line Tools with Swift 6 or newer (`swift --version`). Xcode isn't required.

```bash
./cert.sh                    # once: a local signing certificate
./build.sh                   # builds build/Kermo.app
open build/Kermo.app
cp -R build/Kermo.app /Applications/   # optional: install your build
```

`./cert.sh` creates a self-signed certificate in your login keychain, so Full Disk Access and other permissions aren't reset after every rebuild. Without it `build.sh` signs ad hoc.

## Test and measure

```bash
./test.sh                                 # the test suite
swift run -c release bench                # speed and checks on 100k generated files
swift run -c release bench ~/Library      # the same on a real folder
```

Use `./test.sh`, not `swift test`: it works around a Command Line Tools bug with the swift-testing plugin. The comment at its top explains `DFM_TEST_DISK`, which runs the tests on a RAM disk or a spare volume.

## Package

`./package.sh` writes a universal `.pkg` and `.dmg` for Apple Silicon and Intel to `dist/`. To hand Kermo to someone, send the `.pkg`: opening it runs the standard macOS installer. It isn't notarized, so the recipient allows it on the first open, as in [Install Kermo](docs/install.md).

## Before you open a pull request

- A change users can see adds a line under `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md).
- The docs change in the same pull request. A new or changed shortcut goes into [docs/shortcuts.md](docs/shortcuts.md), an option into [docs/configuration.md](docs/configuration.md), and so on: the [index](README.md#documentation) lists the pages.
- Tests pass: `./test.sh`. If you touched the docs, `python3 tools/check-docs.py` finds broken links and anchors.
- Nothing local gets in: no real host names, user names, paths or passwords in code, tests, docs, screenshots or commit messages. Examples use `me`, `user@host`, `example.com`.

## Writing docs

Each page does one job and starts by saying what it is for. The rules:

- Lead with the answer. Short paragraphs, present tense, "you".
- Steps are numbered, one action each, the imperative first.
- UI labels in **bold**, exactly as on screen; commands and paths in `code`.
- Shortcuts as glyphs in the Mac's order: ⌃ ⌥ ⇧ ⌘, then the key (⇧⌘P).
- A table only when each row has three or more attributes.
- A `> [!WARNING]` only for data loss, irreversible steps or security; at most one or two a page.
- Say each fact once and link to it.
