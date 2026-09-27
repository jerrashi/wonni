# Facebook Marketplace — captured DOM (create-item form)

Reference data for `CrossPostContainerView` autofill (`wonni/wonni/Views/CrossPostWebView.swift`).
Captured from the **mobile layout** the in-app WKWebView loads (iPhone UA, `#screen-root`),
via DevTools → Copy element. Not a decision spec: paste new captures here so they are only
ever copied once. Newest capture date per section.

## Layout facts (2026-09-26)
- Server-driven "MComponent" UI: `data-mcomponent`, absolutely positioned divs, inline
  `margin-top`/`width`. No `aria-label`, no `<label>` wrappers.
- **Unstable — never select on:** `data-action-id` (server-generated), inline styles,
  `nth-child`, classes like `m`, `bg-s8`, `nb`, `f1`.
- **Stable handle:** visible label text. Strategy: find the text node/div whose trimmed text
  equals the field label, then take the nearest following focusable control.

## Category (captured 2026-09-26)
Label:
```html
<div data-mcomponent="ServerTextArea" data-type="text" class="m" style="margin-top:8px; height:21px; width:355px; margin-left:8px;"><div dir="auto" class="native-text rslh" style="color:#65686c;"><span class="f1">Category</span></div></div>
```
Control (shows "Select" until chosen; tapping **navigates to a new page**, not an in-place menu):
```html
<div data-type="container" data-mcomponent="MContainer" class="m nb" style="margin-top:4px; height:30px; ..."><div tabindex="0" data-focusable="true" data-action-id="32754" data-mcomponent="MContainer" data-type="container" class="m bg-s8" style="..."><div data-mcomponent="ServerTextArea" data-type="text" class="m" style="..."><div dir="auto" class="native-text rslh" style="color:#080809;"><span class="f1">Select</span></div></div><div aria-hidden="true" data-mcomponent="ServerTextArea" data-type="text" class="m" style="..."><div class="fl ac"><div dir="auto" class="native-text rslh"><span class="f1" data-nosnippet="true">󳌒</span></div></div></div></div></div>
```
Selector strategy: label text "Category" → next `[data-focusable="true"]` → click → wait for
the category page → pick option by visible text. 
### Category list page (captured 2026-09-26)
One flat container of 45px-tall rows (`div[data-focusable="true"]`), separated by 1px
divider divs. **Two kinds of rows, same tag/attributes — distinguish by structure:**

| Row kind | Distinguishing structure | Behavior |
|---|---|---|
| **Section header** | contains an `[aria-hidden="true"]` icon child (glyph in `span.f1[data-nosnippet]`); label is `span.f2` | tapping does **nothing** — skip |
| **Selectable category** | NO icon child; label is `span.f1`; text indented (`margin-left:40px`) | tapping anywhere in the row selects it |

Header row example (Vehicles — not selectable):
```html
<div tabindex="0" data-focusable="true" data-action-id="32763" data-mcomponent="MContainer" ...><div aria-hidden="true" ...><div class="fl ac"><div dir="auto" class="native-text rslh" style="width:24px; color:#8c72cb;"><span class="f1" data-nosnippet="true">(icon glyph)</span></div></div></div><div data-mcomponent="ServerTextArea" ...><div dir="auto" class="native-text rslh"><span class="f2">Vehicles</span></div></div></div>
```
Selectable row example (Vehicles — the real button):
```html
<div tabindex="0" data-focusable="true" data-action-id="32759" data-mcomponent="MContainer" ...><div data-mcomponent="ServerTextArea" ...><div dir="auto" class="native-text rslh"><span class="f1">Vehicles</span></div></div></div>
```
**Same text appears twice** (header "Vehicles" + selectable "Vehicles"; header "Electronics" vs
selectable "Electronics & computers") — always match on text AND "no `[aria-hidden]` child".

Selector strategy: rows = `[data-focusable="true"]` whose text (trimmed) === target and which
has no `[aria-hidden="true"]` descendant → click. `data-action-id` is per-render; never use it.

Headers → selectable categories (as of capture; Facebook may change these):
- Vehicles → Vehicles
- Housing → Home sales, Rentals
- Home & Garden → Furniture, Household, Appliances, Tools, Garden
- Electronics → Electronics & computers, Mobile phones
- Classifieds → Garage Sale, Miscellaneous
- Hobbies → Sports & Outdoors, Antiques & Collectibles, Musical Instruments, Arts & Crafts, Auto parts, Bicycles
- Clothing & Accessories → Women's clothing & shoes, Men's clothing & shoes, Jewelry & Accessories, Bags & Luggage
- Family → Baby & kids, Health & beauty, Toys & Games, Pet Supplies
- Entertainment → Video Games, Books, Movies & Music

(Full raw HTML was ~30KB of repeated row markup; the two row kinds above are the whole pattern.)
Still unknown: how the page returns to the form after a selection (auto-back? URL change?).

## Base form (captured 2026-09-27, browser console script)

**IMPORTANT correction:** `document.title` was "New listing" and `location.href` was
`https://www.facebook.com/marketplace/selling/item/?listing_id` — the compose form lives
at **`/marketplace/selling/item/`**, not `/marketplace/create/item` (that's only the URL
we navigate WKWebView to; Facebook client-side routes here once the form loads). Any
success/create-page detection keyed on `/marketplace/create` in the path is wrong.

### Title / Price / Description — real `<input>`/`<textarea>`, selectable by `data-name`
The one genuinely stable selector found so far. Each field's wrapper div carries
`data-name`, and for these three the wrapper IS the `[data-focusable="true"]` element:
```html
<div ... data-focusable="true" data-action-id="32747" data-name="title" data-mcomponent="MInputBox" ...>
  <input type="text" tabindex="-1" maxlength="100" class="internal-input input-box native-text rslh non-native-input" style="color:#000;">
</div>
<div ... data-focusable="true" data-action-id="32741" data-name="price" data-mcomponent="MInputBox" data-init-markup-text="0" ...>
  <input type="text" tabindex="-1" maxlength="14" class="internal-input input-box native-text rslh non-native-input" style="color:#000;">
</div>
<div ... data-focusable="true" data-action-id="32734" data-name="description" data-mcomponent="MInputBox" ...>
  <textarea type="text" tabindex="-1" maxlength="2000" class="internal-input input-box native-text rslh non-native-input" style="color:#000;"></textarea>
</div>
```
Selector: `document.querySelector('[data-name="title"] input')` etc. `tabindex="-1"` on the
inner control — Facebook drives focus via the wrapper, not native tab order; `.focus()`
still works programmatically. Price's initial value is the string `"0"`, not empty.

### Location — pre-filled, NEVER autofilled
```html
<div ... data-name="location" data-mcomponent="MInputBox" data-init-markup-text="Richmond, VA" ...>
  <input type="text" tabindex="-1" maxlength="200" ...>
</div>
```
This is the seller's saved address, filled in by Facebook itself. Autofill must skip it.

### Add photos — no file input until the row is tapped
```html
<div tabindex="0" data-focusable="true" data-action-id="32723" data-mcomponent="MContainer" ...>...<span class="f1">Add photos</span>...
```
No `input[type=file]` existed anywhere in the DOM in this capture (the untouched form).
Click the row (matched by exact text "Add photos"), wait, then look for the file input.

### Publish — TWO elements, same `data-action-id`
```html
<!-- top nav-bar shortcut -->
<div role="button" tabindex="0" aria-label="Publish" data-focusable="true" data-action-id="32762" ...><span class="f1">Publish</span></div>
<!-- full-width bottom button -->
<div tabindex="0" data-focusable="true" data-action-id="32762" data-mcomponent="MContainer" class="m bg-s21" ...><span class="f2">Publish</span></div>
```
Both wired to the same action id. Never auto-clicked by the app — the user always taps
Publish themselves.

### Condition — NOT present on the base form
Confirms the category-dependent design: Condition only appears once a category is picked.
Still needs its own capture (after selecting a category).

### Location — "Change location" screen (captured 2026-09-27)
Tapping the Location field does NOT reveal an inline text field like Title/Price — it
pushes a full-screen search-and-pick UI. **Gotcha: this does not change `webView.url`**
(captured `location.href` was still `https://www.facebook.com/`, not a new path) — it's
an internal screen-stack push, not a real navigation. Anything watching `.url` (like
Swift's `handleFacebookURLChange`) can't see this transition; detection must poll the DOM.

Search input:
```html
<div data-focusable="true" data-name="location_query" data-mcomponent="MInputBox" data-init-markup-text="" ...>
  <input aria-label="Search on Facebook" placeholder="Location" type="text" maxlength="200" class="internal-input input-box native-input" ...>
</div>
```
Result rows (recent/suggested locations; same shape as category's selectable rows —
`role="button" data-focusable="true"`, text in `span.f1`, no icon child on any of them
here, so no header-row filtering needed on this screen):
```html
<div role="button" tabindex="0" data-focusable="true" data-action-id="32758" data-mcomponent="MContainer" data-type="container" ...><span class="f1">Richmond, Virginia</span></div>
```
Back button: `[aria-label="Back"]` (also used to leave the Category page).

Wired in `CrossPostJob.facebookLocation` (opt-in, nil by default → skipped, Facebook's own
saved location is left alone) + `fillLocationJS` in CrossPostWebView.swift: click the
field, poll for the search input, type + poll for a matching result row (prefix match,
case-insensitive), click it; times out and taps Back if nothing matches. No UI sets
`facebookLocation` yet — capability only, until there's a use case (e.g. §16-style bulk
location entry).

### "List as Single Item" — unexplored
A dropdown-style row next to the photo area (single-item vs. multi-quantity listing).
Not needed for MVP; noted for later.

## TODO captures
- [ ] Condition (only appears after a category is picked — control + option list page)
- [x] Location (see above — opt-in, wired, unverified on device)
- [x] Photo picker: no input exists until "Add photos" is tapped (see above) — still need: what the input looks like once it appears
- [x] Category list page and option rows (see above); still need: what happens after a row is tapped
- [x] Publish button (see above; no separate "Next" step seen on this form) — still need: any extra steps for specific categories
- [ ] Final URL/listing_id behavior after an ACTUAL publish (currently inferred, unverified — see success-detection note in CrossPostWebView.swift)
