# LeNotch

> This project is inspired by [fellipegoncalvesleite/liquid-notch](https://github.com/fellipegoncalvesleite/liquid-notch).

LeNotch turns your Mac’s notch into a place to control music, see what’s running, and open tools like dictation, notes, and timers. It works with a physical or virtual notch.

## Install

Requires **macOS 15 or later**. Download the ZIP from [GitHub Releases](https://github.com/furkanksl/lenotch/releases), unzip it, and move `LeNotch.app` to Applications. Right-click the notch for **Settings**, **Check for Updates…**, or **Quit**. There’s no Dock or menu bar icon.

Permissions are optional. Notifications and Messages use Full Disk Access. Local dictation runs on Apple silicon; choosing ChatGPT dictation sends the recording to OpenAI.

## Build from source

Use full **Xcode 26 or later** with the Metal Toolchain component. The first build fetches Swift package dependencies.

```sh
./tools/build_adapter.sh       # Optional: expanded Now Playing support
CONFIG=debug ./build_app.sh
open dist/LeNotch.app
```

Run `swift test` for the app or `swift tools/dev.swift` to rebuild on save. See [third-party notices](Resources/Third-Party-Notices.md) for credits.
