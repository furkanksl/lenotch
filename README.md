# LeNotch

A native macOS notch app. Source: [LeNotch](https://github.com/furkanksl/lenotch).

## Run locally

Requires macOS 15 or later and full Xcode 26 or later with Swift 6.2 or later (plus the Xcode Metal Toolchain component).
The Icon Composer build step needs Xcode's asset compiler; Command Line Tools alone aren't sufficient.

From the project directory:

```sh
./tools/build_adapter.sh
CONFIG=debug ./build_app.sh
open dist/LeNotch.app
```

The first build downloads the Sparkle dependency. The app bundle is `dist/LeNotch.app`, its executable is `LeNotch`, and its bundle identifier is `com.lenotch.app`. Existing settings and helper paths keep their lowercase `lenotch` names.

The app icon is the root `lenotch.icon` document. Packaging compiles it directly with Apple's `actool`, preserving its
light, dark and tinted appearances in `Assets.car` and generating a full-size `.icns` fallback for older macOS versions.
Edit that document in Icon Composer rather than exporting a flat PNG. The dev watcher rebuilds when its contents change.

There is no Dock or menu bar icon. Right-click the notch to open Setup or quit. Grant the permissions you want LeNotch to use in Setup.

### ChatGPT voice (experimental)

In **Ask AI → ChatGPT**, the orb at the beginning of the input starts a voice conversation using
the account connected in **Setup → AI providers**. It is disabled while disconnected and is not
shown on the Claude tab. Allow microphone access when prompted. The expanded card shows connection,
listening, and speaking status, with mute, retry, and end controls. Ending voice returns to text Ask;
closing the card, locking the Mac, or disconnecting the account stops microphone capture.

Choose a voice in **Setup → AI providers → Voice mode**. Cove is the default; your selection is
saved for new conversations. End and restart an active voice conversation to apply a change.

Microphone audio is sent to ChatGPT over WebRTC. Voice uses the experimental ChatGPT/Codex backend,
not a separately billed OpenAI API key; account eligibility, limits, and backend availability can vary.
Voice is a separate conversation: it does not inherit Ask's text history or execute Mac/agent tools.

### Desktop transitions (optional)

**Setup → Appearance → Desktop switching** enables Interspace-style Spaces transitions. It is **off by default**;
when off, LeNotch installs no desktop event taps, monitors no trackpad contacts, and captures no desktop snapshots.
Choose Instant, Lightweight, Magnetic, Hexagon, Stack, or macOS default. Speed, swipe sensitivity, rounded corners,
and whether the Dock moves with the desktop are configurable. Existing three/four-finger trackpad gestures and the
macOS “Move left/right a space” keyboard shortcuts are used; disabled shortcuts stay disabled.

Accessibility is needed for input handling; drawn transitions also need Screen Recording. Images stay in memory and
are discarded on disable, lock, or presentation. Reduce Motion pauses custom transitions. LeNotch does not visit your
desktops to preload them: until a desktop has been captured, its wallpaper may be shown instead. Turning the feature
off restores native switching and the previous shortcut enable states. These private macOS APIs can change across OS
releases; if unavailable, native switching remains in place. Do not run a second desktop-transition app simultaneously.

Custom transitions run in a helper process from the signed LeNotch bundle, separate from the notch's UI and Metal
render loop. Setup controls it through local pipes; it has no network listener. Disabling desktop switching or quitting
LeNotch stops it, including when LeNotch exits unexpectedly. Only one helper can own the desktop input hooks at a time.

The implementation is adapted from [Interspace](https://github.com/cnrad/interspace) under the MIT license; notices are
included in `Resources/Interspace-LICENSE.txt` and in the app bundle. `refs/interspace` is an ignored reference checkout,
not a build dependency.

After code changes, quit the app, rebuild, and launch it again. To build a universal release for Apple silicon and Intel, run `./build_app.sh` without `CONFIG=debug`.

### Dictation (Apple silicon)

In **Setup → Dictation**, choose **ChatGPT** to transcribe with the account connected under
**Setup → AI providers**, without downloading a speech model. This option is disabled until
an account is connected. Audio is uploaded to ChatGPT when you finish recording; it requires
internet and does not show live text previews. This uses ChatGPT's backend transcription service,
not the separately billed OpenAI Audio API. Account access and service availability may vary.

For offline transcription, choose **On this Mac**, then **Fluid Speech Pro** (live previews, finalized when you stop) or
**Nemotron 3.5 Streaming 320 ms** (native streaming). Download the chosen model explicitly
before first use (roughly 650–700 MB). Grant **Microphone** and **Accessibility** under
**Setup → Permissions**. Press **⌥D** to start, then press it again to finish; the result is inserted
into the app that remained focused, or copied to the clipboard if insertion is unavailable.
Recording is limited to 90 seconds and held only in memory. Enable **Hold Fn to talk** in Dictation
settings to record while holding Fn / Globe, then release to finish and paste. Push-to-talk is off by
default; **⌥D** has its own switch and stays enabled unless you turn it off. Fn-key combinations cancel
the hold and pass through normally. Fn needs Accessibility access. If macOS also opens Emoji or Dictation,
set **Press 🌐 key to → Do Nothing** in macOS Keyboard settings; LeNotch doesn't change that preference.
Press **Esc** or use **Cancel Dictation** from the notch menu to discard an active recording.

On-device cleanup using **Qwen3.5-0.8B 4-bit** is temporarily hidden and disabled pending a better model.
Its implementation, saved preference, and any downloaded model are retained. After models are downloaded, dictation runs locally;
the app does not upload recordings, transcripts, or analytics. Model downloads use Hugging Face.
The model files are downloaded by the user, not bundled with the app. Fluid Speech Pro requires
CC BY 4.0 attribution; check each model's terms before redistributing its weights. See the model terms:
[Fluid Speech Pro](https://huggingface.co/FluidVoice-Labs/fluid-speech-pro-coreml),
[Nemotron 3.5](https://huggingface.co/BarathwajAnandan/nemotron-3.5-asr-streaming320-int8-CoreML),
and [Qwen3.5](https://huggingface.co/mlx-community/Qwen3.5-0.8B-4bit).

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

For Setup-window work, use `swift tools/dev.swift --setup` to reopen Setup after each rebuild. Setup has separate Permissions, Appearance, Dictation, and Integrations pages and follows your Mac’s light or dark appearance.

## Video in the notch

To watch a video in the notch, allow **Screen Recording** in Setup → Permissions → Music & media. This is macOS’s name for screen-capture access: LeNotch mirrors the video window without recording or saving a video file. The screen-recorder tool and its shortcut are not included.

Both video views have **back 10 seconds**, **play/pause**, and **forward 10 seconds** controls. The notch view also has an elapsed/total-time slider. Seeking is available when the source player supplies a duration and accepts media seek commands; LeNotch does not inject browser shortcuts.

Use the captions button to load a local `.srt` or `.vtt` subtitle file. Subtitles follow the video’s reported playback time, including seeking, in the notch and PiP. Captions already enabled in the source player are part of the mirrored picture too. LeNotch does not automatically download or transcribe captions; subtitle files must match the video.

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
