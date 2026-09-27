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

Wired in `CrossPostJob.facebookLocation` + `fillLocationJS` in CrossPostWebView.swift:
click the field, poll for the search input, type + poll for a matching result row (prefix
match, case-insensitive), click it; times out and taps Back if nothing matches. Every
Facebook `CrossPostJob` (2026-09-27) is constructed with
`facebookLocation: CrossPostJob.facebookLocationFromSettings()` — the city from the same
`SellingSettingsRepository` default-location settings eBay/Etsy shipping already reads —
so posting to Facebook always sets the listing's location to the seller's configured
city; nil (skipped, Facebook's saved default is left as-is) only if that setting is
unset. Search query is the city alone (not "city, state" — the settings model stores
`stateOrProvince` as an abbreviation like "VA", which won't prefix-match Facebook's
spelled-out "Virginia"; the city name alone is enough for the picker to suggest it).

### "List as Single Item" — unexplored
A dropdown-style row next to the photo area (single-item vs. multi-quantity listing).
Not needed for MVP; noted for later.

## Category → field-set schema (captured 2026-09-27, automated crawler)

A browser-console crawler (script kept at bottom of this section) walked all 28
non-Housing top-level categories from a fresh "New listing" form, opening each and
recording the resulting field list via the label/`nb`-sibling pattern from the Category
capture above. Housing (Home sales, Rentals) was excluded — tapping into it drops into a
structurally different flow (real-estate listing, not the generic compose form) that the
crawler's selectors can't navigate; matches the Phase 4 deferral in issue #129.

**Every category has:** Category, Price, Location, Description (the base `data-name`
inputs) — and every category except Vehicles has **Condition**. Beyond that:

| Category | Extra fields |
|---|---|
| Vehicles | `vehicle_make`, `vehicle_model` (real inputs) + Vehicle Type, Year, Make, Model, Interior Color, Exterior Color, Number of owners |
| Furniture | brand, Condition, Material |
| Household | brand, Condition, Color |
| Electronics & computers | brand, size, Condition |
| Mobile phones | Condition, Carrier, Device Name (no brand/size) |
| Women's / Men's clothing & shoes, Baby & kids | brand, size, Condition |
| Video Games | Condition, Platform |
| Books, Movies & Music | Condition only |
| Appliances, Tools, Garden, Garage Sale, Miscellaneous, Sports & Outdoors, Antiques & Collectibles, Musical Instruments, Arts & Crafts, Auto parts, Bicycles, Jewelry & Accessories, Bags & Luggage, Health & beauty, Toys & Games, Pet Supplies | brand, Condition |

So the whole 28-category schema reduces to **9 distinct extra-field types**: Material,
Color, size (Electronics/Clothing/Baby), Carrier, Device Name, Platform, and the
Vehicles-only set (Vehicle Type/Year/Make/Model/Interior Color/Exterior Color/Number of
owners) — brand and Condition are shared across nearly everything. Full raw crawl output:
`docs/dom-captures/facebook-category-fields-raw.json`.

### Common-row control types (from a screenshot, 2026-09-27)
The crawler's extractor caught several rows below Description that aren't category
schema fields at all — they're the always-present bottom of every compose form,
regardless of category. Their actual control types, confirmed visually:
- **Availability ("List as Single Item")** — a real **dropdown** (single vs. presumably
  multi-quantity), not noise; excluded from the per-category table above only because
  it's identical across every category, not because it isn't a real field.
- **Offer shipping**, **Hide from friends**, **Turn on commenting on listing** — **toggle
  switches**, not pickers. "Turn on commenting" defaults ON; the other two default OFF.
- **Add photos** — an **action button** (opens the native photo flow; see the Photos
  section above), not a form field.
- **"This listing is still public…"** and **"All listings go through a quick standard
  review…"** — plain **disclaimer text**, "Learn more" and "Commerce policies" are just
  links. None are interactive fields; correctly excluded from the schema.
- **Publish** — an **action button** (the submit), covered in its own section above.

This matters for autofill: none of these five interactive rows (Availability, the three
toggles, Add photos) can be filled the way Title/Price/Description are — each needs its
own interaction (dropdown pick / toggle click / native photo flow), the same way the
9 category-specific fields will each need their own handling once captured.

**`brand` is a real `<input>` (data-name), not a picker** — confirmed by the crawler
catching it both as `data-name="brand"` and (spuriously) as a `select`-style row, since
its bordered-box styling matches the picker pattern. The same false-positive happened for
the base form's Title/Price/Location/Description rows (each showed up twice: once via
`data-name`, once via a boilerplate label like "What are you selling?"/"Price ($)") —
**the label+`nb`-sibling pattern alone does not distinguish a real dropdown picker from a
plain text input in a bordered box.** Not yet known for any of the 9 extra fields above:
which are full-page pickers (like Category), in-place dropdowns (like Furniture's summary
suggested), or free-text/autocomplete. Needs one capture per field to confirm.

**Not yet captured:** option values for Condition (used almost everywhere — capture once)
or any of the 9 category-specific fields.

<details>
<summary>Crawler script (run on a fresh "New listing" form)</summary>

```js
(async function () {
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  async function waitFor(fn, timeoutMs, intervalMs) {
    var deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      var v = fn();
      if (v) return v;
      await sleep(intervalMs || 200);
    }
    return fn();
  }
  function rows() { return Array.from(document.querySelectorAll('[data-focusable="true"]')); }
  function text(el) { return (el.innerText || '').trim(); }

  function controlForLabel(labelText) {
    var spans = Array.from(document.querySelectorAll('span.f1, span.f2'));
    var labelSpan = spans.find(function (s) { return s.innerText.trim() === labelText; });
    if (!labelSpan) return null;
    var labelDiv = labelSpan.closest('[data-mcomponent="ServerTextArea"]');
    if (!labelDiv || !labelDiv.parentElement) return null;
    var group = labelDiv.parentElement;
    var controlWrap = Array.from(group.children).find(function (c) {
      return c !== labelDiv && (c.className || '').indexOf('nb') !== -1;
    });
    if (!controlWrap) return null;
    return controlWrap.querySelector('[data-focusable="true"]') || controlWrap;
  }

  function extractFields() {
    var scroller = document.querySelector('[data-type="vscroller"]') || document.body;
    var out = [];
    scroller.querySelectorAll('[data-name]').forEach(function (w) {
      var ctl = w.querySelector('input,textarea');
      out.push({ kind: 'input', name: w.getAttribute('data-name'), placeholder: ctl ? ctl.getAttribute('placeholder') : null });
    });
    var seen = {};
    Array.from(scroller.querySelectorAll('span.f1')).forEach(function (s) {
      var label = s.innerText.trim();
      if (!label || seen[label]) return;
      var labelDiv = s.closest('[data-mcomponent="ServerTextArea"]');
      if (!labelDiv || !labelDiv.parentElement) return;
      var group = labelDiv.parentElement;
      var controlWrap = Array.from(group.children).find(function (c) {
        return c !== labelDiv && (c.className || '').indexOf('nb') !== -1;
      });
      if (!controlWrap) return;
      seen[label] = true;
      var valueSpan = controlWrap.querySelector('span.f1');
      out.push({ kind: 'select', label: label, currentValue: valueSpan ? valueSpan.innerText.trim() : null });
    });
    return out;
  }

  var results = { baseFields: extractFields(), categories: [] };
  var catControl = controlForLabel('Category');
  if (!catControl) { console.log('Category control not found — start from a fresh form.'); return; }
  catControl.click();
  await sleep(700);

  var catNames = rows()
    .filter(function (el) { return !el.querySelector('[aria-hidden="true"]') && el.tagName !== 'H1'; })
    .map(text).filter(Boolean);
  var SKIP = ['Home sales', 'Rentals']; // Housing — different flow, breaks the crawler
  catNames = catNames.filter(function (n) { return SKIP.indexOf(n) === -1; });
  console.log('Found ' + catNames.length + ' categories. Starting crawl...');

  for (var i = 0; i < catNames.length; i++) {
    var name = catNames[i];
    try {
      if (i > 0) {
        var control = await waitFor(function () { return controlForLabel('Category'); }, 5000, 250);
        if (!control) { results.categories.push({ name: name, error: 'category control not found' }); continue; }
        control.click();
        await sleep(600);
      }
      var target = await waitFor(function () {
        return rows()
          .filter(function (el) { return !el.querySelector('[aria-hidden="true"]') && el.tagName !== 'H1'; })
          .find(function (el) { return text(el) === name; });
      }, 3000, 200);
      if (!target) { results.categories.push({ name: name, error: 'row not found on reopen' }); continue; }
      target.click();
      var fields = await waitFor(function () {
        var f = extractFields();
        return f.length > 0 ? f : null;
      }, 4000, 300);
      if (!fields) fields = extractFields();
      results.categories.push({ name: name, fields: fields });
      console.log((i + 1) + '/' + catNames.length + ': ' + name + ' — ' + fields.length + ' fields');
    } catch (e) {
      results.categories.push({ name: name, error: e.message });
    }
  }

  var json = JSON.stringify(results, null, 1);
  window.__fbCrawlResults = json;
  var copied = false;
  try { await navigator.clipboard.writeText(json); copied = true; } catch (e) {}
  if (!copied) {
    try {
      var ta = document.createElement('textarea');
      ta.value = json; ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.focus(); ta.select();
      copied = document.execCommand('copy');
      document.body.removeChild(ta);
    } catch (e) {}
  }
  console.log(copied ? ('DONE. Copied ' + json.length + ' chars.') : 'DONE, but copy failed — run copy(window.__fbCrawlResults)');
})();
```
</details>

## TODO captures
- [ ] Condition (only appears after a category is picked — control + option list page)
- [x] Location (see above — opt-in, wired, unverified on device)
- [x] Photo picker: no input exists until "Add photos" is tapped (see above) — still need: what the input looks like once it appears
- [x] Category list page and option rows (see above); still need: what happens after a row is tapped
- [x] Publish button (see above; no separate "Next" step seen on this form) — still need: any extra steps for specific categories
- [ ] Final URL/listing_id behavior after an ACTUAL publish (currently inferred, unverified — see success-detection note in CrossPostWebView.swift)
