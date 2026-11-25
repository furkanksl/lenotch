# LeNotch

> This project is inspired by [fellipegoncalvesleite/liquid-notch](https://github.com/fellipegoncalvesleite/liquid-notch).

LeNotch puts media controls, quick notes, and other everyday tools in your Mac's notch. It can draw a virtual notch on Macs and displays without a physical one.

[Download for macOS](https://github.com/furkanksl/lenotch/releases) · [See the features](#features)

![LeNotch in the notch at the top of a Mac desktop](web/assets/hero-notch.webp)

## Features

Click a preview to open its recording.

| Now Playing | AI Chat |
| --- | --- |
| [![Music controls open in the notch](web/assets/tools/now-playing.webp)](web/public/music-player.mp4) | [![AI chat open in the notch](web/assets/tools/chat.webp)](web/public/ai-text-chat.mp4) |
| Pause, skip, or scrub without switching apps. | Ask Claude or ChatGPT a question without leaving your current app. |

| ChatGPT Voice Mode | Timer |
| --- | --- |
| [![ChatGPT Voice Mode in the notch](web/assets/tools/voice-mode.webp)](web/public/ai-chat.mp4) | [![Countdown timer running in the notch](web/assets/tools/timer.webp)](web/public/timer.mp4) |
| Talk with ChatGPT. This experimental feature needs a connected account and microphone access. | Start a countdown and see how much time is left in the notch. |

| Video in the Notch | Agent Sessions |
| --- | --- |
| [![Video playing in the notch](web/assets/tools/notch-video.webp)](web/public/pip.mp4) | [![Coding sessions open in the notch](web/assets/tools/agent-sessions.webp)](web/public/ai-coding.mp4) |
| Mirror supported video into the notch or pop it out as picture-in-picture. | Follow Claude and Codex coding sessions and respond to permission prompts after setting up hooks. |

| Shelf | Launcher |
| --- | --- |
| [![Files held on the Shelf](web/assets/tools/shelf.webp)](web/public/shelf.mp4) | [![Saved items in the Launcher](web/assets/tools/launcher.webp)](web/public/launcher.mp4) |
| Hold files to drag into another app. | Open saved apps, folders, and links. |

| Clipboard | Dictation |
| --- | --- |
| [![Clipboard history open in the notch](web/assets/tools/clipboard.webp)](web/public/clipboard.mp4) | [![Dictation active in the notch](web/assets/tools/dictation.webp)](web/public/dictation.mp4) |
| Find and paste recently copied text. | Turn speech into text. Local dictation requires Apple silicon. |

| Prompter | Today |
| --- | --- |
| [![Prompter showing a script below the camera](web/assets/tools/prompter.webp)](web/public/prompter.mp4) | [![Calendar events in the Today view](web/assets/tools/today.webp)](web/public/meeting.mp4) |
| Scroll your script below the camera. | Check your calendar and see what meeting is next. |

| To-do | Notes |
| --- | --- |
| [![A to-do list open in the notch](web/assets/tools/todo.webp)](web/public/todo.mp4) | [![A note open in the notch](web/assets/tools/notes.webp)](web/public/notes.mp4) |
| Keep a task list on your Mac. | Jot down notes that save on your Mac. |

| Shortcuts | System |
| --- | --- |
| [![macOS Shortcuts open in the notch](web/assets/tools/shortcuts.webp)](web/public/shortcuts.mp4) | [![System stats open in the notch](web/assets/tools/system.webp)](web/public/system-info.mp4) |
| Run your macOS Shortcuts. | Check CPU, memory, and disk usage. |

| Usage | Inbox |
| --- | --- |
| [![Claude and Codex usage in the notch](web/assets/tools/usage.webp)](web/public/usage.mp4) | [![Recent notifications in the Inbox](web/assets/tools/inbox.webp)](web/public/notifications.mp4) |
| See how much of your Claude and Codex limits you've used. | Read recent macOS notifications. |

| Incoming Call | Messages |
| --- | --- |
| [![Incoming call preview in the notch](web/assets/tools/incoming-call.webp)](web/public/incoming-call.mp4) | [![Message notification and inline reply preview](web/assets/tools/messages.webp)](web/public/messages.mp4) |
| Preview the incoming-call and in-call layouts in the notch. | Preview a message notification and its inline reply field. |

| Volume | Brightness | Status Alerts |
| --- | --- | --- |
| [![Volume level beside the notch](web/assets/tools/volume.webp)](web/public/hud.mp4) | [![Brightness level beside the notch](web/assets/tools/brightness.webp)](web/public/birghtness.mp4) | [![A status alert in the notch](web/assets/tools/status-alerts.webp)](web/public/airpods-charging-limit-reset.mp4) |
| See the volume level in the notch when you press a volume key. | See the display level in the notch when you change the brightness. | See AirPods battery, Mac charging status, and usage-limit resets in the notch. |

## Install

Requires **macOS 15 or later**. Open the DMG from [GitHub Releases](https://github.com/furkanksl/lenotch/releases) and drag `LeNotch.app` to Applications. If your release only has a ZIP, unzip it and move the app to Applications.

Right-click the notch for **Settings**, **Check for Updates…**, or **Quit**. There’s no Dock or menu bar icon.

Permissions are optional. Notifications and Messages use Full Disk Access. Local dictation runs on Apple silicon; choosing ChatGPT dictation sends the recording to OpenAI.

## Build from source

Use full **Xcode 26 or later** with the Metal Toolchain component. The first build fetches Swift package dependencies.

```sh
./tools/build_adapter.sh       # Optional: expanded Now Playing support
CONFIG=debug ./build_app.sh
open dist/LeNotch.app
```

Run `swift test` for the app or `swift tools/dev.swift` to rebuild on save. See [third-party notices](Resources/Third-Party-Notices.md) for credits.

## License

LeNotch is released under the [MIT License](LICENSE). Bundled third-party code, icons, and artwork keep their own licenses; see the [third-party notices](Resources/Third-Party-Notices.md).
