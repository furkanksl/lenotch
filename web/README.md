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

Edit `src/data/site.ts`:

- **Main product demo video:** place your video in `public/` (for example `public/demo.mp4`) and set `siteConfig.demoVideoSrc` to `"/demo.mp4"`. Set `demoPosterSrc` if you have a poster. The player has no media until you set these paths.
- **Per-tool clips or screenshots:** add `media: { type: "video", src: "/tools/shelf.mp4", poster: "/tools/shelf.webp" }` or `media: { type: "image", src: "/tools/shelf.webp" }` to replace a tool’s large icon with an asset from `public/`.
- **Direct macOS download:** set `siteConfig.downloadUrl` to your signed release `.zip` or `.dmg` URL.
