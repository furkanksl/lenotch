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

### System usage

Open **System** from the notch tools menu to see CPU load across all cores, memory usage, and startup-disk storage.
CPU and memory update every two seconds while the page is visible; storage refreshes every thirty seconds. Sampling
stops when the page closes or the Mac locks. These readings stay local and require no additional permissions.
System replaces the menu's Inbox button by default; notification-driven inbox access is unchanged. The Inbox button
can come back from **Setup → Tools**.

### Tools menu

**Settings → Tools** has one compact row for each tool in the notch's tools menu: Chat, Dictation, Prompter, Today, Launcher,
Clipboard, Shelf, Shortcuts, Usage, System, To-do, Notes, and Notifications (shown in the menu as Inbox). Every tool is on except
Usage and Notifications. The menu shows five tools a row and grows a row when it needs one, so turning tools off shrinks it and
short rows stay centered. At least one tool always stays on.

Turning a tool off hides its button only. Its shortcut (⌥Space for Chat, ⌥D for Dictation, the Launcher shortcut),
dropping files on the notch to open the Shelf, and notifications opening the inbox keep working. Your choices are stored
in `lenotch.tools.choices` in the app's defaults, as just the tools you changed, so a tool added later starts on its
own default. Drag a row's grip to reorder the tools; an orange insertion line marks where it will land. The row's
options menu also has **Move up** and **Move down**, and a focused grip supports **Option–Up/Down**. Order is stored
separately in `lenotch.tools.order`; hidden tools keep their place. **Restore order** resets ordering only, leaving
shortcuts and visibility intact. **Preview menu** shows the current five-column layout.

Every tool's row has a **Shortcut** control, independently of its **In menu** switch. Defaults are **⌥Space** for Chat,
**⌥D** for Dictation, **⌥A** for Launcher, **⌥C** for Clipboard, **⌥T** for To-do, and **⌥N** for Notes; other tools start
unassigned. Click the chord or **Add shortcut**, then press a combination with Option, Control, or Command. Escape or
Tab cancels recording; Delete clears the shortcut. The row's options menu can clear or restore its default. Conflicts
with another tool or an unavailable system-wide shortcut are reported inline. Hidden tools retain their shortcuts.
Legacy disabled Launcher/Dictation shortcuts and saved bindings are preserved during migration. Dictation's **Fn hold**
remains an independent setting; the reserved **⌃⌥⌘A** Chat backup remains available.

### To-do lists

Open **To-do** from the notch tools menu. Start typing in the empty **Tasks** list, or use **+** to make another list.
Press Return to add a task; the field stays ready for the next one. Select a list's chip to switch between lists.
Check a task to move it under **Done**, and uncheck it to bring it back. **Clear** removes completed tasks together.

Double-click a list name or task title to rename it, or right-click for rename/delete actions. Deletions offer
**Undo** for six seconds. The To-do menu button shows the number of unfinished tasks across all lists, capped at 99.
Hide its button in **Setup → Tools** without deleting any lists.

Lists, task titles, completion state, and the selected list are saved after every change in
`~/Library/Application Support/lenotch/todos.json`. There is no database, account, or network sync. The file is
written atomically; an unreadable file is preserved before replacement, and an unsupported newer format is never
overwritten. Storage problems are reported on the To-do page.

### Notes

Open **Notes** from the tools menu for a title-and-preview list of your notes, newest edited first. Use **New note**
to start one. A note has a title and a plain-text body; Return in the title moves to the multiline editor. Changes
save as you type, including line breaks and Unicode. The back button returns to all notes. Delete a note from the
editor or a note's context menu, with **Undo** available for six seconds.

Notes are stored only in `~/Library/Application Support/lenotch/notes.json`, next to your To-do lists. There is no
database or network sync. The selected note is restored after a restart; unreadable files are preserved before a
replacement is saved, and newer unsupported formats are never overwritten. **Setup → Tools** controls the Notes
button. Usage and Notifications are off by default and can be turned back on there.

### ChatGPT voice (experimental)

In **Chat → ChatGPT**, the orb at the beginning of the input starts a voice conversation using
the account connected in **Setup → AI providers**. It is disabled while disconnected and is not
shown on the Claude tab. Allow microphone access when prompted. The expanded card shows connection,
listening, and speaking status, with mute, retry, and end controls. Ending voice returns to text Chat;
clicking outside or minimizing the card keeps the call running in a notch indicator. Click the
indicator to reopen the same call. **End voice**, locking the Mac, or disconnecting the account
stops microphone capture.

Choose a voice in **Setup → AI providers → Voice mode**. Cove is the default; your selection is
saved for new conversations. End and restart an active voice conversation to apply a change.

Microphone audio is sent to ChatGPT over WebRTC. Voice uses the experimental ChatGPT/Codex backend,
not a separately billed OpenAI API key; account eligibility, limits, and backend availability can vary.
Voice is a separate conversation: it does not inherit Chat's text history. Research tasks are
delegated to the connected ChatGPT web-search backend, with a visible Working/search status until
the result is returned to voice. Ending the call cancels delegated work. Voice cannot run Mac
commands, inspect local files, or execute coding-agent tools.

### Desktop transitions (optional)

**Settings → Appearance → Desktop switching** is **off by default**. macOS renders the live desktops in every mode.
None uses an overlay, captures the screen, or requires Screen Recording. Removed styles fall back to **macOS default**.

- **macOS default** keeps the standard Spaces animation and inputs.
- **Instant** uses the Dock's desktop-swipe mechanism to switch quickly with your existing three- or four-finger swipes
  and macOS "Move left/right a space" shortcuts. Swipe sensitivity is adjustable.
- **Live Slide** paces the slide for those keyboard shortcuts. Trackpad swipes stay native. **Slide duration** sets how long
  LeNotch drives the slide before the Dock settles it, not the total transition time. It ranges from 150 to 750 ms and
  defaults to 350 ms.

Switching via Mission Control or app activation stays native. Instant and Live Slide require Accessibility. Disabled shortcuts
stay disabled. These modes pause while the Mac is locked,
presenting, or using Reduce Motion. They use experimental private macOS APIs that may change across releases. If those APIs
are unavailable, macOS handles switching as usual. Do not run another desktop-transition app at the same time.

Input handling runs in a local helper from the signed LeNotch bundle. Disabling desktop switching or quitting LeNotch stops
the helper and restores normal desktop controls.

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

LeNotch uses Sparkle and checks [furkanksl/lenotch](https://github.com/furkanksl/lenotch) for updates. Right-click the notch and choose **Check for Updates…** to check immediately. Sparkle shows the release notes and can install the update and relaunch. Copies shipped before `SUPublicEDKey` was added need a one-time manual upgrade.

### One-time setup

1. Back up `.release/keys/ed25519-private.key` securely. Restore that same key on a new release Mac instead of generating a replacement. The matching public key is in `.release/keys/ed25519-public.key` and `Resources/Info.plist`. Only the public key is committed.
2. Install a **Developer ID Application** certificate and its private key in your login Keychain. Copy `.env.release.example` to `.env.release` if it doesn't exist. Fill in `LN_NOTARY_TEAM_ID` and either `LN_NOTARY_APPLE_ID` and `LN_NOTARY_PASSWORD` (an [Apple app-specific password](https://account.apple.com/)), or store the credentials with `xcrun notarytool store-credentials lenotch` and set `LN_NOTARY_KEYCHAIN_PROFILE='lenotch'`. Using Keychain avoids keeping a password in the file.
3. Sign in with `gh auth login` using an account that can publish to `furkanksl/lenotch`. The GitHub CLI uses its own credentials; the publish script doesn't need the Apple password or Sparkle private key.

### Each release

From the repo root, run `npm run bump patch`, `npm run bump minor`, or `npm run bump major`. To set an exact version, pass a higher `X.Y.Z` version, for example `npm run bump 2.1.0`. No `npm install` is needed. Each bump updates `CFBundleShortVersionString` and adds one to Sparkle's `CFBundleVersion` in `Resources/Info.plist`.

Add a matching `## <version>` section with bullet points in `CHANGELOG.md`. Commit and push the release inputs before publishing so the GitHub tag points at the same commit used to build the app. Then run:

```sh
./tools/release.sh            # Build, sign, notarize, and package. Does not publish.
./tools/publish.sh --dry-run  # Validate local artifacts without writing to GitHub.
./tools/publish.sh            # Upload both assets to a draft, then publish as latest.
```

Build output is `dist/release/<version>/`: the stapled `LeNotch-<version>.zip`, `appcast.xml`, and a local `commit.txt` that identifies the source revision. The GitHub release must include both the ZIP and appcast because installed copies read `releases/latest/download/appcast.xml`. Don't replace the ZIP on an existing public release; bump the version and build instead. The local debug build does not need these release settings.
