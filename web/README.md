# LeNotch web

Landing page for LeNotch, built with SolidJS 2.0, TypeScript, Vite, Tailwind CSS 4, and self-hosted Geist Sans.

## Development

Use Node.js 22.12 or newer. From `web/`:

```sh
npm ci
npm run dev
```

Run `npm run typecheck` to check TypeScript, `npm run build` to build `dist/`, and `npm run preview` to preview the production output.

## Adding videos, images, and the release download

- **Hero screenshot:** replace `assets/hero-notch.webp`. If its dimensions change, update the image's `width` and `height` in `src/components/HeroScreenshot.tsx`.
- **Per-tool clips or screenshots:** put the MP4 in `public/` and set the tool's `recording` in `src/data/site.ts` to its filename (for example, `"shelf.mp4"`). Put a still at `assets/tools/<tool-id>.webp` if you have one. Tools without a still show their icon until the video plays.
- **Direct macOS download:** attach a signed `.dmg` to the latest published GitHub release. The landing page picks it up automatically.

## Self-hosting on Dokploy

`web/Dockerfile` runs a multi-stage build (Node 22 Debian slim to compile Solid 2.0, then Nginx Alpine to serve the static bundle on port `80`).

In your Dokploy application settings:

- **Build Path:** `/web`
- **Build Type:** `Dockerfile`
- **Dockerfile Path:** `Dockerfile`
- **Docker Context Path:** leave blank (or `web`)
- **Watch Paths:** `web/**`
- **Container Port (Domains):** `80`
- **Health check path (optional):** `/healthz`

To test locally with Docker:

```sh
cd web
docker build -t lenotch-web .
docker run --rm -p 8080:80 lenotch-web
```
