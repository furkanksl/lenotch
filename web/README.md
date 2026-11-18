# LeNotch web

The standalone site uses Solid 2.0, TypeScript, Vite, Tailwind CSS 4, and a self-hosted Geist Sans font. The current screen is only a scaffold for the landing page.

## Development

Use Node.js 22.12 or newer. From `web/`, run:

```sh
npm ci
npm run dev
```

Vite prints the local URL (normally `http://localhost:5173`). Use `npm run typecheck` to check TypeScript, `npm run build` to generate the static site in `dist/`, and `npm run preview` to serve that build locally.

Use Tailwind utilities for component styling. Keep `src/styles.css` for global styles, shared theme tokens, and custom animations.
