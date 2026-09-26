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

## TODO captures
- [ ] Title, Price, Description (are they real `<input>`/`<textarea>` or contenteditable?)
- [ ] Condition (control + option list page)
- [ ] Photo picker (`input[type=file]`, `accept`)
- [x] Category list page and option rows (see above); still need: what happens after a row is tapped
- [ ] Next / Publish buttons, any extra steps (location, delivery)
- [ ] Final URL after publishing a test item
