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
the category page → pick option by visible text. **TODO capture:** category list page + option rows.

## TODO captures
- [ ] Title, Price, Description (are they real `<input>`/`<textarea>` or contenteditable?)
- [ ] Condition (control + option list page)
- [ ] Photo picker (`input[type=file]`, `accept`)
- [ ] Category list page and one option row
- [ ] Next / Publish buttons, any extra steps (location, delivery)
- [ ] Final URL after publishing a test item
