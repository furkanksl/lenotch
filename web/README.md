# LeNotch web

Landing page for LeNotch, built with SolidJS 2.0, TypeScript, Vite, Tailwind CSS 4, and self-hosted Geist Sans.

## Development

Use Node.js 22.12 or newer. From `web/`:

```sh
npm ci
npm run dev
```

Run `npm run typecheck` to check TypeScript, `npm run build` to build `dist/`, and `npm run preview` to preview the production output.

For direct links and refreshes, configure the host to serve `index.html` for `/privacy` and `/terms` (with or without a trailing slash). Vite’s dev and preview servers already do this.

## Adding videos, images, and the release download

Set these paths in `src/data/site.ts`:

- **Main product demo video:** place your video in `public/` (for example `public/demo.mp4`) and set `siteConfig.demoVideoSrc` to `"/demo.mp4"`. Set `demoPosterSrc` if you have a poster. The player has no media until you set these paths.
- **Direct macOS download:** set `siteConfig.downloadUrl` to your signed release `.zip` or `.dmg` URL.

### Per-tool demos

Drop an MP4 into `assets/tools/`, named for the card's `id` in `src/data/site.ts` (e.g. `now-playing.mp4`, `chat.mp4`, or `voice-mode.mp4`). Around three seconds is a good target, not a limit. A matching `.webp` shows before playback or works as a still on its own. With neither file, the card keeps its icon.

Clips play once, muted, when you hover over the preview. Moving away restores the still. Tap the preview or use Enter or Space to play without hovering. Reduced-motion settings disable hover playback.

Crop close to the notch, aim for a 3:2 frame, and show one action per clip. For example: skip a track in Now Playing, open Chat with Claude and ChatGPT visible, mute the mic in Voice Mode, or start a countdown in Timer. Use sample tracks, accounts, and content so recordings don’t show personal information.

From `web/`, use FFmpeg to trim a cropped recording. Adjust `-t 3` to fit the action. To add a poster from the first frame, use `cwebp`:

```sh
mkdir -p assets/tools
ffmpeg -ss 1 -i recording.mov -t 3 -an -vf 'scale=720:-2,fps=30' \
  -c:v libx264 -pix_fmt yuv420p -crf 23 -movflags +faststart assets/tools/now-playing.mp4
ffmpeg -i assets/tools/now-playing.mp4 -frames:v 1 first-frame.png
cwebp -q 82 first-frame.png -o assets/tools/now-playing.webp
```
