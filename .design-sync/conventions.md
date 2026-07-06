# Wonni Design System — Agent Conventions

## Setup
No provider or root wrapper is needed. Import components directly and add `class="wonni"` to any container — it enables font smoothing and box-sizing inheritance. Every component already adds `wonni` to its own root so standalone use works without an extra wrapper.

The CSS file (`styles.css` → `_ds_bundle.css`) defines all tokens and component styles. It must be loaded for the brand to render.

## Components
11 components covering Wonni's sell flow — all available as `WonniDS.*`:

| Component | Use for |
|---|---|
| `Button` | CTAs — variants: `primary`, `secondary`, `ghost`, `destructive`; sizes: `sm`, `md`, `lg`; `loading` and `disabled` states |
| `AppPill` | Floating task pill above the tab bar; `progress=-1` = spinner, `0–1` = ring; `color` = `purple`/`accent`/`success`/`warning` |
| `AIBadge` | Inline badge for AI-generated content; `label` = `"AI identified"`, `"AI edited"`, `"AI priced"`; `variant` = `filled`/`outline` |
| `CrossPostBadge` | Platform status badge; `platform` = `wonni`/`ebay`/`etsy`/`mercari`/`facebook`; `status` = `posted`/`pending`/`failed`/`manual` |
| `CrossPostStatusCard` | Post-publish summary card; pass a `platforms` array with per-platform status entries |
| `ListingCard` | Item card with photo, title, price, status chip, AI badge, and platform icons; `status` = `draft`/`processing`/`active`/`sold`/`sold_out` |
| `PhotoGrid` | Selectable photo grid; `columns` = 2/3/4; `emptyState` renders the add-photos placeholder |
| `PlatformToggle` | Toggle row for enabling cross-post to a marketplace; shows connection status |
| `ProcessingProgress` | AI processing progress bar; `phase` = `uploading`/`identifying`/`generating`/`complete`; `progress` = 0–1 |
| `Sheet` | iOS-style bottom sheet container; use `noPadding` for edge-to-edge content |
| `WonniTabBar` | 5-tab bottom nav (`home`/`camera`/`search`/`inbox`/`profile`); camera tab renders as a purple FAB |

## Styling idiom — CSS custom properties
All brand tokens are defined as `var(--w-*)` in the loaded stylesheet. Use them for any layout or decoration you write outside of components:

**Color tokens**
- Brand purple: `--w-brand` (#8B5CF6), `--w-brand-dark` (#7C3AED), `--w-brand-light` (#EDE9FF)
- Purple scale: `--w-purple-50` through `--w-purple-900`
- Surfaces: `--w-surface` (white), `--w-surface-alt` (#F9F8FF, slight purple tint)
- Text: `--w-text` (#1A1228), `--w-text-secondary` (#6B6180), `--w-text-tertiary` (#9D97AE)
- Borders: `--w-border` (#DDD6FE), `--w-border-subtle` (#EDE9FF)
- Status: `--w-success`, `--w-warning`, `--w-error`, `--w-pending` + matching `-bg`/`-text` variants

**Spacing (4 px grid)**: `--w-space-1` (4px) → `--w-space-12` (48px)

**Border radius**: `--w-radius-xs` (6px) → `--w-radius-pill` (9999px)

**Typography**: `--w-font` = `-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', system-ui`; sizes `--w-text-xs` (11px) → `--w-text-2xl` (28px)

**Shadows**: `--w-shadow-sm`, `--w-shadow-md`, `--w-shadow-lg`, `--w-shadow-pill`

**Transitions**: `--w-t` (200ms ease), `--w-t-fast` (120ms), `--w-t-slow` (350ms)

Do not invent color values — use only the tokens above. For text on brand-colored backgrounds, use `--w-text-on-brand` (white).

## Where the truth lives
- Token definitions: `styles.css` → `_ds_bundle.css` (`:root { --w-* }` block at the top)
- Per-component API: each `<Name>.prompt.md` in `components/general/<Name>/`
- Component source: `<Name>.jsx` stubs + `<Name>.d.ts` type contracts

## Idiomatic example — sell flow screen fragment
```jsx
// Publish sheet: platform selection + CTA
<div style={{ background: 'var(--w-surface)', minHeight: '100vh', display: 'flex', flexDirection: 'column' }}>
  <WonniTabBar activeTab="camera" />
  <Sheet title="Publish listing" subtitle="3 items ready to post">
    <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--w-space-2)' }}>
      <PlatformToggle platform="ebay"    enabled={true}  connected={true} />
      <PlatformToggle platform="etsy"    enabled={true}  connected={true} />
      <PlatformToggle platform="mercari" enabled={false} connected={true} />
    </div>
    <div style={{ marginTop: 'var(--w-space-5)' }}>
      <Button variant="primary" label="Publish to 2 platforms" icon="🚀" fullWidth />
    </div>
  </Sheet>
</div>
```
