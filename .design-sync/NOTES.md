# Wonni Design System — Sync Notes

## Setup
- Package at `design-system/` (repo root), name `@wonni/design-system`
- Build: `cd design-system && npm run build` (tsup ESM + .d.ts)
- Converter entry: `./design-system/dist/index.js`
- Node modules: `./design-system/node_modules`
- CSS: `src/wonni.css` (package-relative) — contains all tokens and component styles, no external @imports
- Google Fonts @import was removed from wonni.css — caused Playwright timeout in headless render check. Inter and SF Pro Text are both marked `runtimeFontPrefixes`.

## Re-sync command (from repo root)
```sh
node .ds-sync/package-build.mjs \
  --config .design-sync/config.json \
  --node-modules ./design-system/node_modules \
  --entry ./design-system/dist/index.js \
  --out ./ds-bundle
node .ds-sync/package-validate.mjs ./ds-bundle
```

## Playwright
- Installed via `npm i playwright` inside `.ds-sync/`
- Chromium cached at `~/Library/Caches/ms-playwright/chromium_headless_shell-1228`
- On a fresh clone: `(cd .ds-sync && npm i playwright && npx playwright install chromium-headless-shell)`

## Known render notes
- `CrossPostStatusCard` and `ListingCard` use `cardMode: column` — their preview stories are wider than the default grid cells
- Preview images in both components use inline SVG data URIs (no network)
- All 11 components validated clean, `bad: 0`

## Re-sync risks
- **conventions.md vocabulary**: class names and token names in the conventions header are verified against the compiled CSS at this sync time. If tokens are renamed in `wonni.css` and the conventions file isn't updated, the design agent will reference stale names silently.
- **Emoji tab icons**: `WonniTabBar` uses emoji characters for tab icons (🏠📷🔍💬👤). If tab icons change in the iOS app, update both the Swift and React components.
- **Image placeholders in previews**: `ListingCard` and `CrossPostStatusCard` previews use SVG data-URI color squares instead of real photos. They look adequate but brand perception would improve with real product photography in a future re-sync.
- **No docs matched**: All 11 components used synthesized `.prompt.md` from `.d.ts`. Adding per-component `.md` docs to `design-system/docs/` and setting `cfg.docsDir` would improve the design agent's usage guidance.
