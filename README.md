# LeNotch

A native macOS notch app. Source: [LeNotch](https://github.com/furkanksl/lenotch).

## Run locally

Requires macOS 15 or later and Xcode 16 or later with Swift 6.

From the project directory:

```sh
./tools/build_adapter.sh
CONFIG=debug ./build_app.sh
open dist/LeNotch.app
```

The first build downloads the Sparkle dependency. The app bundle is `dist/LeNotch.app`, its executable is `LeNotch`, and its bundle identifier is `com.lenotch.app`. Existing settings and helper paths keep their lowercase `lenotch` names.

There is no Dock or menu bar icon. Right-click the notch to open Setup or quit. Grant the permissions you want LeNotch to use in Setup.

After code changes, quit the app, rebuild, and launch it again. To build a universal release for Apple silicon and Intel, run `./build_app.sh` without `CONFIG=debug`.

## Development mode

Run this foreground watcher from the project directory:

```sh
swift tools/dev.swift
```

It builds the Now Playing adapter and a debug app, launches `dist/LeNotch.app`, then watches `Sources/`, `Resources/`, `Package.swift`, `Package.resolved`, `build_app.sh`, and `tools/build_adapter.sh`. Saves are debounced and builds run one at a time. `.build/`, `dist/`, and `Vendor/` are excluded.

This is native Swift incremental rebuild-and-relaunch, not true SwiftUI hot reload. Each successful rebuild restarts the app, so transient UI state resets. A failed build leaves the current app running. The watcher builds and verifies a separate staged bundle before quitting and replacing only this checkout's app; it does not quit another installed copy of LeNotch. If the app does not quit within five seconds, the watcher cancels that reload without force-quitting it.

Pass `--debug` to open the existing debug panel after each launch, or `--once` to build and relaunch without watching:

```sh
swift tools/dev.swift --debug
swift tools/dev.swift --once
```

Press **Ctrl-C** to stop the watcher and any build it started. The last launched app stays open. Do not run a separate build or `swift test` while the watcher is running, since both use this checkout's `.build/` directory. Ad-hoc signing can require granting macOS permissions again after a rebuild; the existing `LN_SIGN_IDENTITY` build option can use a stable signing identity.

For Setup-window work, use `swift tools/dev.swift --setup` to reopen Setup after each rebuild. Setup has separate Permissions, Appearance, and Integrations pages and follows your Mac’s light or dark appearance.

## Prompter

Open the notch's tools and choose **Prompter**, or right-click the notch and choose **Prompter…**. Write or paste a script in the editor; scripts and display preferences save locally on your Mac.

Start moves the reader below the camera, with an optional three-second countdown. Pause and resume without losing your place, restart from the beginning, or scroll manually. Adjust speed and text size while reading; Mirror flips only the script for a teleprompter reflector. Stop closes the reader. Switching to another activity or hiding the card pauses playback instead of scrolling unseen.

The reader stays open when you click another app, so it can sit beside the camera during a presentation. Click the text to focus its keyboard controls: **Space** pauses/resumes, **R** restarts, **↑/↓** changes speed, and **Esc** stops. Editor typing is unaffected.

This is constant-speed, local prompting. It does not use microphone or Speech permission and does not send scripts to a service. Voice-following and cloud synchronization are not included.

## Tests

```sh
swift test
```

## Updates and releases

Updates and releases use [furkanksl/lenotch](https://github.com/furkanksl/lenotch). The updater's `SUFeedURL` is `https://github.com/furkanksl/lenotch/releases/latest/download/appcast.xml`.

Automatic update checks remain disabled until you add LeNotch's own `SUPublicEDKey` to `Resources/Info.plist` and rebuild. Use `tools/updates.sh keygen` to create a signing key for a new release setup, or `tools/updates.sh pubkey` to read the public key from an existing local signing key. Keep the private key at `~/.config/lenotch/update-signing.key` backed up and out of the repository. Do not use the upstream project's signing key.

`tools/release.sh` defaults to `https://github.com/furkanksl/lenotch`. It only builds release artifacts and prints a publish command targeting `furkanksl/lenotch`; it does not publish them. Attach both the signed `LeNotch-<version>.zip` and `appcast.xml` to each GitHub release so the updater can check it. An optional `LN_RELEASE_REPO_URL` override requires a matching `SUFeedURL`.

Releases also require a Git checkout with committed app sources, a `CHANGELOG.md` section for the app version, and the signing key matching `SUPublicEDKey`. The local debug build does not need these release settings.
