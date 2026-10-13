# Requirements and installation

Kermo requires macOS 14 or later. To install a packaged release, open the DMG, drag Kermo to Applications, then open it. Local releases are not notarized by Apple, so the first launch is blocked: on macOS 15 or later click **Open Anyway** in System Settings > Privacy & Security; on macOS 14 Control-click the app and choose **Open**. Kermo was called DFileManager before: settings and permissions carry over, so delete the old DFileManager.app.

To create a universal installer for Apple Silicon and Intel Macs:

```bash
./package.sh                                   # writes universal .pkg and .dmg files to dist/
```

Send the `.pkg` file for the simplest installation: opening it runs the standard macOS installer and places Kermo in Applications. Because local releases are not notarized by Apple, the recipient allows the package the same way on the first open.

Building from source requires the Command Line Tools. The full Xcode installation is not required.

```bash
./cert.sh                                      # create a local signing certificate (run once)
./build.sh                                     # build build/Kermo.app
cp -R build/Kermo.app /Applications/           # install the app
open /Applications/Kermo.app                   # launch it
```

Running `./cert.sh` once creates a local self-signed certificate in your login keychain. This keeps Full Disk Access and other macOS permissions from being reset after every rebuild. Without the certificate, `build.sh` uses ad-hoc signing.

Other development commands:

```bash
./test.sh                                      # run tests (works around a CLT swift-testing plugin bug)
swift run -c release bench                     # benchmark and verify 100k generated files
swift run -c release bench ~/Library           # benchmark a real directory
```
