// Mercari Content Script — Wonni Drop Phase 3
// Replicates DOM target selectors and form injection pipeline from wonni (CrossPostWebView.swift)

(function () {
  if (window.__wonniMercariInjected) return;
  window.__wonniMercariInjected = true;

  console.log("[Wonni Drop] Mercari cross-post content script loaded.");

  // ── Status Logging ──────────────────────────────────────────────────────────
  // Mirrors iOS's silent, log-only status tracking (CrossPostWebView's `status`/
  // `injectionStep`) instead of an on-page overlay — progress is visible via the
  // console and, ultimately, via listingStatus.mercari in Firestore.
  function updateHUD(statusText, detailText, isError = false) {
    const log = isError ? console.warn : console.log;
    log(`[Wonni Drop] ${statusText}${detailText ? ` — ${detailText}` : ""}`);
  }

  // ── DOM Helpers & React Input Setters ───────────────────────────────────────

  function waitFor(fn, timeout = 10000, interval = 200) {
    return new Promise((resolve) => {
      const start = Date.now();
      (function loop() {
        let r = null;
        try { r = fn(); } catch (e) { /* ignore */ }
        if (r) { resolve(r); return; }
        if (Date.now() - start >= timeout) { resolve(null); return; }
        setTimeout(loop, interval);
      })();
    });
  }

  function realClick(el) {
    if (!el) return;
    ["pointerdown", "mousedown", "pointerup", "mouseup", "click"].forEach((type) => {
      el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
    });
  }

  function setReactInput(el, value) {
    if (!el) return false;
    const lastValue = el.value;
    const proto = el.tagName === "TEXTAREA"
      ? window.HTMLTextAreaElement.prototype
      : window.HTMLInputElement.prototype;
    const nativeSetter = Object.getOwnPropertyDescriptor(proto, "value");
    if (nativeSetter && nativeSetter.set) {
      nativeSetter.set.call(el, value);
    } else {
      el.value = value;
    }
    const tracker = el._valueTracker;
    if (tracker) { tracker.setValue(lastValue); }
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return true;
  }

  // ── Main Cross-Post Pipeline ────────────────────────────────────────────────

  async function runMercariCrossPost(payload) {
    updateHUD("Form Detection", "Waiting for Mercari sell form to mount…");

    // 1. Wait for Sell Form
    const sellFormMounted = await waitFor(() => {
      if (document.querySelector('input[data-testid="Title"]')) return "form";
      const u = (location && location.href) ? location.href.toLowerCase() : "";
      if (u.includes("login") || u.includes("signin")) return "login";
      return null;
    }, 45000);

    if (sellFormMounted === "login") {
      updateHUD("Sign In Required", "Please sign in to Mercari, then retry cross-posting.", true);
      return;
    }
    if (!sellFormMounted) {
      updateHUD("Form Load Timeout", "Mercari sell page didn't mount in time.", true);
      return;
    }

    // 2. Core Fields (Title, Description, Price, Condition)
    updateHUD("Filling Fields", "Setting title, description, price, and condition…");
    const titleEl = document.querySelector('input[data-testid="Title"]');
    setReactInput(titleEl, payload.title || "");
    if (titleEl) { titleEl.focus(); titleEl.blur(); }

    const descEl = document.querySelector('textarea[data-testid="Description"]');
    setReactInput(descEl, payload.description || "");
    if (descEl) { descEl.focus(); descEl.blur(); }

    const priceEl = document.querySelector('input[data-testid="Price"]');
    if (payload.price) {
      setReactInput(priceEl, String(Math.round(payload.price)));
      if (priceEl) { priceEl.focus(); priceEl.blur(); }
    }

    // Condition
    const conditionMap = {
      new: "ConditionNew",
      newwithouttags: "ConditionLikeNew",
      likenew: "ConditionLikeNew",
      good: "ConditionGood",
      fair: "ConditionFair",
      poor: "ConditionPoor",
      forparts: "ConditionPoor",
    };
    const condKey = (payload.condition || "good").toLowerCase().replace(/[\s_\-]/g, "");
    const conditionTestId = conditionMap[condKey] || "ConditionGood";
    const condLabel = document.querySelector(`[data-testid="${conditionTestId}"]`);
    if (condLabel) realClick(condLabel);

    // 3. Photos Upload
    if (Array.isArray(payload.images) && payload.images.length > 0) {
      updateHUD("Uploading Photos", `Attaching ${payload.images.length} photos…`);
      await attachPhotos(payload.images);
    }

    // 4. Category
    updateHUD("Category Selection", "Selecting product category…");
    await selectCategory(payload.suggestedCategory || payload.title);

    // 5. Smart Pricing (Turn off)
    updateHUD("Smart Pricing", "Disabling Smart Pricing auto-toggle…");
    await disableSmartPricing();

    // 6. Brand Selection
    updateHUD("Brand Selection", "Selecting brand…");
    await selectBrand(payload.brand);

    // 7. Shipping Setup
    updateHUD("Shipping Setup", "Configuring shipping options…");
    const shippingResult = await configureShipping(payload);
    console.log("[Wonni Drop] Shipping:", shippingResult);
    if (shippingResult === "oversized-no-dimension-step") {
      updateHUD("Shipping Warning", "Item looks oversized but this category has no dimensions step — a prepaid label may incur an overage fee.", true);
    }
    const payerResult = await selectShippingPayer(payload.buyerPaysShipping ?? false);
    console.log("[Wonni Drop] ShippingPayer:", payerResult);

    // 8. Submit Listing
    updateHUD("Submitting", "Waiting for Mercari List button to enable…");
    const submitResult = await submitListing();
    if (!submitResult.startsWith("submitted")) {
      updateHUD("Submit Pending", "Form completed! Please review and click List in Mercari.", false);
    }

    // 9. Poll for Post-Success & Scrape Item ID
    await pollForSuccessModal(payload);
  }

  // ── Photo Attachment Handler ────────────────────────────────────────────────

  // Content-script fetch() is bound by Mercari's page CORS policy (no
  // Access-Control-Allow-Origin on our Storage-hosted images), so the actual
  // download happens in the background service worker — the one context that's
  // truly exempt via manifest host_permissions — and comes back as base64.
  function fetchImageAsBase64(url) {
    return new Promise((resolve, reject) => {
      chrome.runtime.sendMessage({ type: "FETCH_MERCARI_IMAGE", url }, (res) => {
        if (chrome.runtime.lastError || res?.error) {
          reject(new Error(res?.error || chrome.runtime.lastError?.message || "Image fetch failed"));
        } else {
          resolve(res.base64);
        }
      });
    });
  }

  function base64ToBlob(base64, mimeType) {
    const byteChars = atob(base64);
    const byteArrays = [];
    for (let offset = 0; offset < byteChars.length; offset += 512) {
      const slice = byteChars.slice(offset, offset + 512);
      const byteNumbers = new Array(slice.length);
      for (let i = 0; i < slice.length; i++) byteNumbers[i] = slice.charCodeAt(i);
      byteArrays.push(new Uint8Array(byteNumbers));
    }
    return new Blob(byteArrays, { type: mimeType });
  }

  async function attachPhotos(imageUrls) {
    const fileInput = document.querySelector('input[data-testid="SellPhotoInput"]');
    if (!fileInput) return;

    try {
      const files = [];
      for (let i = 0; i < imageUrls.length; i++) {
        const url = imageUrls[i];
        try {
          const base64 = await fetchImageAsBase64(url);
          const mimeType = url.toLowerCase().endsWith(".png") ? "image/png" : "image/jpeg";
          const ext = mimeType === "image/png" ? "png" : "jpg";
          const blob = base64ToBlob(base64, mimeType);
          const file = new File([blob], `photo_${i}.${ext}`, { type: mimeType });
          files.push(file);
        } catch (e) {
          console.warn("[Wonni Drop] Failed to fetch photo blob:", url, e);
        }
      }

      if (files.length > 0) {
        const dt = new DataTransfer();
        files.forEach((f) => dt.items.add(f));
        fileInput.files = dt.files;
        fileInput.dispatchEvent(new Event("change", { bubbles: true }));
        fileInput.dispatchEvent(new Event("input", { bubbles: true }));
        await new Promise((r) => setTimeout(r, 3000));
        console.log(`[Wonni Drop] Photos attached: ${files.length}/${imageUrls.length}`);
      } else {
        console.warn(`[Wonni Drop] No photos attached (0/${imageUrls.length} fetched) — check manifest host_permissions covers the image host.`);
      }
    } catch (e) {
      console.error("[Wonni Drop] Photo attach error:", e);
    }
  }

  // ── Category Selection ──────────────────────────────────────────────────────

  async function selectCategory(targetCategory) {
    // Tier 1: Server-suggested accordion
    const accordion = await waitFor(() => document.querySelector('[data-testid="SuggestedCategoriesAccordion"]'), 8000);
    if (accordion) {
      if (accordion.getAttribute("aria-expanded") !== "true") realClick(accordion);
      const first = await waitFor(() => document.querySelector('[data-testid="SuggestedCategory1"]'), 3000);
      if (first) {
        realClick(first);
        return "tier1-suggested";
      }
    }

    // Tier 2 / 3: Walk dropdowns
    async function pickLevel(triggerTestId, listSelector, optionTestId) {
      const trigger = document.querySelector(`[data-testid="${triggerTestId}"]`);
      if (!trigger) return null;
      realClick(trigger);
      const list = await waitFor(() => document.querySelector(listSelector), 2000);
      if (!list) return null;
      const opts = list.querySelectorAll(`[data-testid="${optionTestId}"]`);
      if (opts.length === 0) return null;
      let other = null;
      for (let i = 0; i < opts.length; i++) {
        if (opts[i].textContent.trim().toLowerCase() === "other") other = opts[i];
      }
      const chosen = other || opts[0];
      realClick(chosen);
      return "picked";
    }

    await pickLevel("CategoryL0", "#categoryId", "CategoryL0-option");
    await pickLevel("CategoryL1", "#subCategoryId", "CategoryL1-option");
    if (document.querySelector('[data-testid="CategoryL2"]')) {
      await pickLevel("CategoryL2", "#subSubCategoryId", "CategoryL2-option");
    }
    return "category-walked";
  }

  // ── Smart Pricing ────────────────────────────────────────────────────────────

  async function disableSmartPricing() {
    function findToggle() {
      const t = document.querySelector('[data-testid*="SmartPricing"], [data-testid*="smartPricing"]');
      if (t) return t;
      const cands = document.querySelectorAll('input[type="checkbox"], button[role="switch"], [role="switch"]');
      for (let i = 0; i < cands.length; i++) {
        const anc = cands[i].closest("label") || cands[i].parentElement;
        if (anc && anc.textContent.toLowerCase().includes("smart pricing")) return cands[i];
      }
      return null;
    }

    function isOn(t) {
      return t.checked === true
        || t.getAttribute("aria-checked") === "true"
        || t.getAttribute("data-state") === "checked"
        || (t.className && String(t.className).includes("checked"));
    }

    const toggle = await waitFor(findToggle, 4000);
    if (!toggle || !isOn(toggle)) return;

    const target = toggle.tagName === "INPUT"
      ? (document.querySelector(`label[for="${toggle.id}"]`) || toggle.closest("label") || toggle)
      : toggle;

    realClick(target);
    toggle.dispatchEvent(new Event("change", { bubbles: true }));

    // Dismiss confirm dialog if shown
    const confirmBtn = await waitFor(() => {
      const bs = document.querySelectorAll('[role="dialog"] button, [role="alertdialog"] button');
      for (let i = 0; i < bs.length; i++) {
        const t = bs[i].textContent.trim().toLowerCase();
        if (["turn off", "confirm", "ok", "yes"].includes(t) && !bs[i].disabled) return bs[i];
      }
      return null;
    }, 1500);
    if (confirmBtn) realClick(confirmBtn);
  }

  // ── Brand Selection ──────────────────────────────────────────────────────────

  async function selectBrand(brandName) {
    // Tier 1: Suggested brand chips
    const suggested = await waitFor(() => document.querySelector('[data-testid="SuggestedBrandSection"]'), 5000);
    if (suggested) {
      const chips = suggested.querySelectorAll('[data-testid^="SuggestedBrand-"]:not([data-testid="NoBrandLink"])');
      if (chips.length > 0) {
        const label = chips[0].querySelector("label");
        if (label) realClick(label);
        else realClick(chips[0]);
        return "tier1-chip";
      }
    }

    // Tier 2: Search AI / specified brand name
    if (brandName) {
      const brandInput = await waitFor(() => document.querySelector('[data-testid="BrandSearchInput"], [data-testid="BrandInput"], input[placeholder*="brand" i]'), 2500);
      if (brandInput) {
        realClick(brandInput);
        setReactInput(brandInput, brandName);
        const option = await waitFor(() => {
          const opts = document.querySelectorAll('[data-testid*="BrandOption"], [data-testid*="BrandSuggestion"], li[role="option"]');
          return opts.length > 0 ? opts[0] : null;
        }, 2500);
        if (option) {
          realClick(option);
          return "tier2-search";
        }
      }
    }

    // Tier 3: No brand / Not sure
    const noBrand = document.querySelector('[data-testid="NoBrandLink"] label, [data-testid="NoBrandLink"] input');
    if (noBrand) realClick(noBrand);
    return "tier3-nobrand";
  }

  // ── Shipping Configuration ──────────────────────────────────────────────────
  // Ported from wonni iOS's CrossPostWebView.swift shipping stage. Mercari's List
  // button stays disabled until a carrier is chosen (for prepaid, non-SOYO listings),
  // so this has to actually walk the weight/carrier modal, not just the payer toggle.

  // Mercari's shoebox is 14x10x5in; "fits" keeps the cheap small-package flow.
  function isOversized(lengthIn, widthIn, heightIn) {
    if (lengthIn == null || widthIn == null || heightIn == null) return false;
    const dims = [lengthIn, widthIn, heightIn].slice().sort((a, b) => b - a);
    return dims[0] > 14 || dims[1] > 10 || dims[2] > 5;
  }

  // The weight modal's Next button is gated on a non-zero weight + an answered
  // shoebox question. Derive safe defaults when the listing has neither.
  function deriveWeightEntry(weightLbsTotal, lengthIn, widthIn, heightIn) {
    const knowDims = lengthIn != null && widthIn != null && heightIn != null;
    const fitsInShoebox = !(knowDims && isOversized(lengthIn, widthIn, heightIn));

    if (weightLbsTotal && weightLbsTotal > 0) {
      let lb = Math.floor(weightLbsTotal);
      let oz = Math.round((weightLbsTotal - lb) * 16);
      if (oz >= 16) { lb += Math.floor(oz / 16); oz %= 16; }
      if (lb === 0 && oz === 0) oz = 1; // never submit a zero weight
      return { lb, oz, fitsInShoebox };
    }
    return { lb: 0, oz: 6, fitsInShoebox }; // ~6oz light padded-mailer default
  }

  function btnByText(text) {
    const bs = document.querySelectorAll("button");
    for (const b of bs) { if (b.textContent.trim() === text) return b; }
    return null;
  }

  function shippingChosen() {
    const s = document.querySelector('#sellShippingClassesInput, [data-testid="SelectShipping"]');
    if (!s) return false;
    const v = (s.value || "").toLowerCase();
    return v.length > 0 && !v.includes("add title") && !v.includes("enable shipping") && !v.includes("select");
  }

  // Answers Mercari's "Will your item fit in a shoebox?" gate. Always fires a real
  // change event — a visually pre-selected default is often not yet committed to
  // React state, which otherwise leaves the Next button permanently disabled.
  function answerShoebox(scope, fits) {
    scope = scope || document;
    const direct = scope.querySelector(fits
      ? '[data-testid="ItemFitInShoeboxYes"], [data-testid="ShoeboxYes"]'
      : '[data-testid="ItemFitInShoeboxNo"], [data-testid="ShoeboxNo"]');
    if (direct) {
      const dl = document.querySelector(`label[for="${direct.id}"]`) || direct.closest("label") || direct;
      realClick(dl);
      direct.dispatchEvent(new Event("change", { bubbles: true }));
      return "testid";
    }
    const want = fits ? "yes" : "no";
    const radios = scope.querySelectorAll('input[type="radio"]');
    for (const r of radios) {
      const rl = document.querySelector(`label[for="${r.id}"]`) || r.closest("label") || r.parentElement;
      const txt = (rl ? rl.textContent : "").trim().toLowerCase();
      if (txt === want) {
        realClick(rl || r);
        r.dispatchEvent(new Event("change", { bubbles: true }));
        return "label";
      }
    }
    return "not-found";
  }

  // Stage 1: open the shipping field, dismiss the "weigh accurately" interstitial,
  // accept Mercari's recommended label if offered, else fill weight + shoebox (+
  // dimensions) and submit to fetch the live carrier list.
  async function openShippingAndSubmitWeight(entry, haveDims, lengthIn, widthIn, heightIn) {
    const field = await waitFor(() => {
      const el = document.querySelector('#sellShippingClassesInput, [data-testid="SelectShipping"]');
      return (el && !el.disabled) ? el : null;
    }, 15000);
    if (!field) return "no-shipping-field";
    realClick(field);

    const gotIt = await waitFor(() => btnByText("Got it"), 3000);
    if (gotIt) {
      const popup = gotIt.closest('div[role="dialog"]') || gotIt.parentElement;
      const labels = (popup || document).querySelectorAll("label");
      let dontShow = null;
      for (const l of labels) {
        if (l.textContent.toLowerCase().includes("don't show")) {
          dontShow = l.querySelector('input[type="checkbox"]');
          break;
        }
      }
      if (dontShow && !dontShow.checked) realClick(dontShow);
      realClick(gotIt);
    }

    // Prefer Mercari's recommended label when it's offered — verify it actually
    // closes the modal before trusting it.
    const useLabel = await waitFor(() => document.querySelector('[data-testid="UseThisButton"]'), 2500);
    if (useLabel) {
      realClick(useLabel);
      const accepted = await waitFor(() => (shippingChosen() ? "y" : null), 3500);
      if (accepted) return "used-recommended";
    }

    const lbEl = await waitFor(() => document.querySelector('[data-testid="ItemWeightInPounds"], #lb'), 6000);
    const ozEl = document.querySelector('[data-testid="ItemWeightInOunces"], #oz');
    if (!lbEl && !ozEl) return shippingChosen() ? "used-recommended" : "no-weight-modal";

    const modal = (lbEl || ozEl).closest('div[role="dialog"], [role="dialog"]');
    if (lbEl) { setReactInput(lbEl, String(entry.lb)); lbEl.focus(); lbEl.blur(); }
    if (ozEl) { setReactInput(ozEl, String(entry.oz)); ozEl.focus(); ozEl.blur(); }

    answerShoebox(modal, entry.fitsInShoebox);

    if (!entry.fitsInShoebox && haveDims) {
      const lenEl = await waitFor(() => document.querySelector('[data-testid="InputLength"], #Length'), 2500);
      if (lenEl) {
        const widEl = document.querySelector('[data-testid="InputWidth"], #Width');
        const heiEl = document.querySelector('[data-testid="InputHeight"], #Height');
        setReactInput(lenEl, String(Math.round(lengthIn)));
        if (widEl) setReactInput(widEl, String(Math.round(widthIn)));
        if (heiEl) setReactInput(heiEl, String(Math.round(heightIn)));
      } else {
        // Oversized but this category has no dimensions step — a prepaid label
        // risks an overage fee; surface via return value so the HUD can warn.
        return "oversized-no-dimension-step";
      }
    }

    // The Next button stays disabled until React validates weight + shoebox; poll
    // for enabled rather than clicking immediately (a disabled click silently no-ops).
    const next = await waitFor(() => {
      const b = document.querySelector('[data-testid="SelectCarrierButton"]');
      return (b && !b.disabled) ? b : null;
    }, 6000);
    if (next) { realClick(next); return "weight-submitted"; }

    return shippingChosen() ? "used-recommended" : "weight-next-not-found";
  }

  // Stage 2: wait for the live carrier list and parse each option's price.
  async function fetchShippingOptions() {
    const nodes = await waitFor(() => {
      const n = document.querySelectorAll('[data-testid="AvailableShippingOption"]');
      return n.length > 0 ? n : null;
    }, 10000);
    if (!nodes) return [];
    const out = [];
    for (const node of nodes) {
      const radio = node.querySelector('input[type="radio"]');
      if (!radio) continue;
      const priceEl = node.querySelector('[data-testid$="Price"]') || node;
      const match = (priceEl.textContent || "").match(/\$([0-9]+(?:\.[0-9]{1,2})?)/);
      const cents = match ? Math.round(parseFloat(match[1]) * 100) : 999999;
      out.push({ value: radio.value, carrier: node.getAttribute("data-carrier") || "", priceCents: cents });
    }
    return out;
  }

  // Stage 3: select the chosen label's radio, then Save to close the modal.
  async function chooseShippingOption(value) {
    const radio = await waitFor(() => document.querySelector(`input[type="radio"][value="${value}"]`), 4000);
    if (!radio) return "radio-not-found";
    const label = document.querySelector(`label[for="${radio.id}"]`) || radio.closest("label") || radio;
    for (let attempt = 0; attempt < 3 && !radio.checked; attempt++) {
      realClick(label);
      radio.dispatchEvent(new Event("change", { bubbles: true }));
      await waitFor(() => (radio.checked ? "y" : null), 1000);
    }
    const save = await waitFor(() => document.querySelector('[data-testid="SelectCarrierSaveButton"]'), 4000);
    if (!save) return "save-not-found";
    realClick(save);
    return "saved";
  }

  // "Offer buyers free shipping?" — Yes (seller pays, default) vs No (buyer pays).
  async function selectShippingPayer(buyerPays) {
    const trigger = document.querySelector('[data-testid="ShippingPayerOption"][aria-haspopup="listbox"]')
      || document.querySelector('#ShippingPayerOption[aria-haspopup="listbox"]');
    if (!trigger) return "payer-field-not-found";
    const currentlyNo = (trigger.textContent || "").trim().toLowerCase() === "no";
    if (buyerPays && currentlyNo) return "already-buyer-pays";
    if (!buyerPays && !currentlyNo) return "already-free";
    realClick(trigger);
    const wantTestId = buyerPays ? "FreeShippingNoButton" : "FreeShippingYesButton";
    const option = await waitFor(() => document.querySelector(`[data-testid="${wantTestId}"]`), 3000);
    if (!option) return "option-not-found";
    realClick(option);
    return buyerPays ? "set-buyer-pays" : "set-free";
  }

  // Walks the ship-on-own vs. prepaid-carrier flow, then always applies the
  // shipping-payer preference (mirrors iOS's injectFields ordering).
  async function configureShipping(payload) {
    if (payload.shipOnOwn) {
      const soyo = document.querySelector('input#SOYO[type="radio"], input[value="SOYO"][type="radio"]');
      if (soyo && !soyo.checked) {
        realClick(soyo);
        soyo.dispatchEvent(new Event("change", { bubbles: true }));
      }
      return "ship-on-own";
    }

    const entry = deriveWeightEntry(payload.weightLbs, payload.lengthIn, payload.widthIn, payload.heightIn);
    const haveDims = payload.lengthIn != null && payload.widthIn != null && payload.heightIn != null;

    const opened = await openShippingAndSubmitWeight(entry, haveDims, payload.lengthIn, payload.widthIn, payload.heightIn);
    if (opened === "used-recommended") return "recommended-accepted";
    if (opened !== "weight-submitted") return opened;

    // No carrier preference in this app (unlike iOS's carrier-selection UI) — always
    // take the cheapest option, per the "suggested label first, then cheapest" policy.
    const options = await fetchShippingOptions();
    if (!options.length) return "no-options";
    const cheapest = options.reduce((a, b) => (b.priceCents < a.priceCents ? b : a));
    const saved = await chooseShippingOption(cheapest.value);
    return `picked:${cheapest.value}|${saved}`;
  }

  // ── Submit Listing ──────────────────────────────────────────────────────────

  async function submitListing() {
    const listBtn = await waitFor(() => {
      const btn = document.querySelector('[data-testid="ListButton"]');
      return (btn && !btn.disabled) ? btn : null;
    }, 8000);

    if (listBtn) {
      realClick(listBtn);
      return "submitted";
    }
    return "button-disabled";
  }

  // ── Post-Success & Item ID Scraping ─────────────────────────────────────────

  async function pollForSuccessModal(payload) {
    const productId = payload.productId;
    function findItemId() {
      const re = /\/item\/(m[A-Za-z0-9]+)/;
      const links = document.querySelectorAll('a[href*="/item/"]');
      for (let i = 0; i < links.length; i++) {
        const m = (links[i].getAttribute("href") || "").match(re);
        if (m) return m[1];
      }
      const body = (document.body && document.body.innerText) || "";
      const m3 = body.match(re);
      if (m3) return m3[1];
      return null;
    }

    for (let i = 0; i < 120; i++) {
      await new Promise((r) => setTimeout(r, 1500));
      const body = (document.body && document.body.innerText) || "";
      const isSuccess = body.includes("Listed!")
        || body.includes("Your item has been listed")
        || body.includes("Your listing is live")
        || body.includes("Post another item")
        || body.includes("Share your listing");

      if (isSuccess) {
        const mercariItemId = findItemId();
        const mercariUrl = mercariItemId ? `https://www.mercari.com/us/item/${mercariItemId}/` : location.href;
        updateHUD("Listed Successfully!", mercariItemId ? `Mercari Item ID: ${mercariItemId}` : "Listing is live on Mercari!", false, true);

        // Notify background script. Include the just-pushed values as the new sync
        // baseline (mercariSynced*) — the next sync-to-Mercari push diffs against this.
        chrome.runtime.sendMessage({
          type: "MERCARI_CROSS_POST_RESULT",
          success: true,
          productId,
          variantId: payload.variantId,
          mercariItemId,
          mercariUrl,
          syncedTitle: payload.title,
          syncedDescription: payload.description,
          syncedPrice: payload.price,
          syncedImages: payload.images,
        });
        return;
      }
    }

    // No success signal within the poll window — report failure instead of leaving
    // Firestore's listingStatus stuck at "posting" forever. The form may still be
    // sitting there partially filled; the user can finish it by hand in this tab.
    updateHUD("Cross-post timed out", "Didn't detect a successful listing — review the form in this tab.", true);
    chrome.runtime.sendMessage({
      type: "MERCARI_CROSS_POST_RESULT",
      success: false,
      productId,
      variantId: payload.variantId,
      error: "Timed out waiting for Mercari to confirm the listing.",
    });
  }

  // ── Edit Flow (push Wonni Drop updates to an already-live listing) ──────────
  // `payload` here carries the FULL current desired state (title/description/
  // price/images) plus `diff` — the subset that actually changed since the last
  // successful sync (computed upstream in the web app). Only `diff` fields get
  // touched on the DOM; the full state is reported back as the new sync
  // baseline regardless, since untouched fields already matched it.

  async function runMercariEditFlow(payload) {
    updateHUD("Edit: Form Detection", "Waiting for Mercari edit form to mount…");

    const formMounted = await waitFor(() => {
      if (document.querySelector('input[data-testid="Title"]')) return "form";
      const u = (location && location.href) ? location.href.toLowerCase() : "";
      if (u.includes("login") || u.includes("signin")) return "login";
      return null;
    }, 45000);

    if (formMounted === "login") {
      updateHUD("Sign In Required", "Please sign in to Mercari, then retry syncing.", true);
      reportEditResult(payload, false, "Sign-in required.");
      return;
    }
    if (!formMounted) {
      updateHUD("Form Load Timeout", "Mercari edit page didn't mount in time.", true);
      reportEditResult(payload, false, "Edit form didn't load in time.");
      return;
    }

    const diff = payload.diff || {};

    if (typeof diff.title === "string") {
      updateHUD("Updating Title", diff.title);
      const titleEl = document.querySelector('input[data-testid="Title"]');
      setReactInput(titleEl, diff.title);
      if (titleEl) { titleEl.focus(); titleEl.blur(); }
    }

    if (typeof diff.description === "string") {
      updateHUD("Updating Description");
      const descEl = document.querySelector('textarea[data-testid="Description"]');
      setReactInput(descEl, diff.description);
      if (descEl) { descEl.focus(); descEl.blur(); }
    }

    if (typeof diff.price === "number") {
      updateHUD("Updating Price", String(diff.price));
      const priceEl = document.querySelector('input[data-testid="Price"]');
      setReactInput(priceEl, String(Math.round(diff.price)));
      if (priceEl) { priceEl.focus(); priceEl.blur(); }
    }

    if (Array.isArray(diff.images) && diff.images.length > 0) {
      updateHUD("Updating Photos", `Attaching ${diff.images.length} photos…`);
      // NOTE: this only ADDS the new photo set via the file input — it does not
      // remove Mercari's existing photos first. Mercari's "remove existing
      // photo" control is unverified without live access; if photos need to
      // fully replace rather than append, you may need to manually clear the
      // old ones once until that selector is confirmed and wired up.
      await attachPhotos(diff.images);
    }

    updateHUD("Saving", "Waiting for Mercari's Save button to enable…");
    const saveResult = await submitEdit();
    console.log("[Wonni Drop] Edit submit:", saveResult);

    await pollForEditSuccess(payload);
  }

  // Mercari's edit-page submit control testid is unverified without live access
  // — try the likely candidates, falling back to matching visible button text.
  async function submitEdit() {
    const btn = await waitFor(() => {
      const candidates = [
        document.querySelector('[data-testid="SaveButton"]'),
        document.querySelector('[data-testid="UpdateButton"]'),
        document.querySelector('[data-testid="ListButton"]'),
      ].filter(Boolean);
      const byText = Array.from(document.querySelectorAll("button")).find((b) => {
        const t = (b.textContent || "").trim().toLowerCase();
        return ["save", "save changes", "update", "done"].includes(t);
      });
      const found = candidates[0] || byText;
      return (found && !found.disabled) ? found : null;
    }, 8000);

    if (btn) {
      realClick(btn);
      return "submitted";
    }
    return "button-not-found";
  }

  // Unverified: best-guess success signal (a "saved" toast, or navigation away
  // from the edit page). Falls back to a timeout report so Firestore doesn't
  // stay stuck on "updating" forever.
  async function pollForEditSuccess(payload) {
    for (let i = 0; i < 40; i++) {
      await new Promise((r) => setTimeout(r, 1500));
      const body = (document.body && document.body.innerText) || "";
      const url = location.href.toLowerCase();
      const isSuccess = body.includes("Saved")
        || body.includes("Changes saved")
        || body.includes("Listing updated")
        || !url.includes("/sell/edit/");

      if (isSuccess) {
        updateHUD("Synced Successfully!", "Mercari listing updated.");
        reportEditResult(payload, true);
        return;
      }
    }

    updateHUD("Sync timed out", "Didn't detect a save confirmation — review the form in this tab.", true);
    reportEditResult(payload, false, "Timed out waiting for Mercari to confirm the update.");
  }

  function reportEditResult(payload, success, error) {
    chrome.runtime.sendMessage({
      type: "MERCARI_EDIT_RESULT",
      success,
      productId: payload.productId,
      variantId: payload.variantId,
      error: error ?? null,
      // Full current desired state — becomes the new sync baseline on success,
      // since fields NOT in `diff` already matched the previous baseline.
      syncedTitle: payload.title,
      syncedDescription: payload.description,
      syncedPrice: payload.price,
      syncedImages: payload.images,
    });
  }

  // ── Auto-Start Execution ────────────────────────────────────────────────────

  if (location.pathname.includes("/sell/edit/")) {
    chrome.runtime.sendMessage({ type: "GET_MERCARI_EDIT_PAYLOAD" }, (res) => {
      if (res && res.payload) {
        runMercariEditFlow(res.payload);
      }
    });
  } else {
    chrome.runtime.sendMessage({ type: "GET_MERCARI_PAYLOAD" }, (res) => {
      if (res && res.payload) {
        runMercariCrossPost(res.payload);
      }
    });
  }
})();
