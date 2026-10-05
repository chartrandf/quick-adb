# Quick ADB

A tiny macOS menu bar app to push APKs to an Android phone. Drop an APK on the ant, it lands on the phone and opens.

<p align="center">
  <img src="docs/window-idle.png" width="420" alt="Quick ADB window, waiting for an APK">
</p>

## Features

- **Drag and drop an APK** on the 🐜 in the menu bar, or on the Quick ADB window.
- **Reads the package name from the APK**, so it works with any app, nothing hardcoded.
- **Replaces the app in place** (`adb install -r`), so its data and home screen icon are kept. If that fails (e.g. a different signing key), it falls back to uninstall + install.
- **Launches the app** once installed.
- **Every connected device** gets the APK.
- **No device?** The window asks you to connect one and keeps the APK; hit **Push to device** when it's plugged in.
- **Capture log**: saves the last 1, 2, 3, 4, 5, 10, 15 or 30 minutes of `logcat` to the Desktop.
- **Take screenshot**: saves the phone screen as a PNG on the Desktop.
- Devices show by name (e.g. *Google Pixel 8a*), not by serial.


## Menu

| Item | What it does |
|---|---|
| Install APK… | Pick an APK from a file dialog |
| Show window | Reopen the window with the last result |
| Capture log → *Last N min* | `adb logcat -d -t <since>` → `~/Desktop/<device>-<date>.log` |
| Take screenshot → *device* | `adb exec-out screencap -p` → `~/Desktop/<device>-<date>.png` |
| Quit | |

## Requirements

- macOS 14+
- `adb` (Homebrew `android-platform-tools`, or the Android SDK `platform-tools`)
- `aapt2` from the Android SDK `build-tools` (or `apkanalyzer`) to read the package name
- USB debugging enabled on the phone

Tools are looked up in `/opt/homebrew/bin`, `/usr/local/bin`, `$ANDROID_HOME` and `~/Library/Android/sdk`.

## Build & run

```sh
./build.sh
open QuickADB.app
```

`build.sh` compiles `main.swift` with `swiftc` and wraps it in an ad-hoc signed `QuickADB.app`. No Xcode project needed.

To install it, copy `QuickADB.app` to `/Applications`. To start it at login: System Settings → General → Login Items → **+**.

## Notes

- Installs use `--install-reason 4` (user request), so the Pixel launcher can add a home screen icon on a fresh install when *Add app icons to Home screen* is on.
- Log time ranges use the Mac's clock, like `adb logcat -t`.
- The first log or screenshot may trigger a macOS prompt to allow access to the Desktop.
