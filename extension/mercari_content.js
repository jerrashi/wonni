// Mercari Content Script — Wonni Drop Phase 3
// Replicates DOM target selectors and form injection pipeline from wonni (CrossPostWebView.swift)

(function () {
  if (window.__wonniMercariInjected) return;
  window.__wonniMercariInjected = true;

  console.log("[Wonni Drop] Mercari cross-post content script loaded.");

  // ── HUD Overlay ─────────────────────────────────────────────────────────────
  let hudEl = null;

  function createHUD() {
    if (document.getElementById("wonni-mercari-hud")) return;
    hudEl = document.createElement("div");
    hudEl.id = "wonni-mercari-hud";
    hudEl.style.cssText = `
      position: fixed; bottom: 24px; right: 24px; width: 320px;
      background: #18181b; border: 1px solid #27272a; border-radius: 12px;
      padding: 16px; z-index: 999999; font-family: -apple-system, BlinkMacSystemFont, sans-serif;
      color: #f4f4f5; box-shadow: 0 10px 30px rgba(0,0,0,0.5); font-size: 13px;
    `;
    hudEl.innerHTML = `
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
        <div style="display:flex;align-items:center;gap:6px">
          <div style="width:8px;height:8px;border-radius:50%;background:#ff6b35;animation:wonni-pulse 1.5s infinite"></div>
          <span style="font-weight:600;color:#ff6b35">Wonni Drop Cross-Post</span>
        </div>
        <button id="wonni-hud-close" style="background:none;border:none;color:#a1a1aa;cursor:pointer;font-size:16px">&times;</button>
      </div>
      <div id="wonni-hud-status" style="color:#e4e4e7;margin-bottom:6px;font-weight:500">Initializing…</div>
      <div id="wonni-hud-detail" style="color:#71717a;font-size:11px;line-height:1.4">Reading cross-post payload…</div>
      <style>
        @keyframes wonni-pulse { 0% { opacity: 0.4; } 50% { opacity: 1; } 100% { opacity: 0.4; } }
      </style>
    `;
    document.body.appendChild(hudEl);
    hudEl.querySelector("#wonni-hud-close").addEventListener("click", () => hudEl.remove());
  }

  function updateHUD(statusText, detailText, isError = false, isSuccess = false) {
    createHUD();
    const statusEl = document.getElementById("wonni-hud-status");
    const detailEl = document.getElementById("wonni-hud-detail");
    if (statusEl) {
      statusEl.textContent = statusText;
      statusEl.style.color = isError ? "#ef4444" : isSuccess ? "#22c55e" : "#e4e4e7";
    }
    if (detailEl && detailText) {
      detailEl.textContent = detailText;
    }
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
    await configureShipping(payload);

    // 8. Submit Listing
    updateHUD("Submitting", "Waiting for Mercari List button to enable…");
    const submitResult = await submitListing();
    if (!submitResult.startsWith("submitted")) {
      updateHUD("Submit Pending", "Form completed! Please review and click List in Mercari.", false);
    }

    // 9. Poll for Post-Success & Scrape Item ID
    pollForSuccessModal(payload.productId);
  }

  // ── Photo Attachment Handler ────────────────────────────────────────────────

  async function attachPhotos(imageUrls) {
    const fileInput = document.querySelector('input[data-testid="SellPhotoInput"]');
    if (!fileInput) return;

    try {
      const files = [];
      for (let i = 0; i < imageUrls.length; i++) {
        const url = imageUrls[i];
        try {
          const res = await fetch(url);
          const blob = await res.blob();
          const file = new File([blob], `photo_${i}.jpg`, { type: "image/jpeg" });
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

  async function configureShipping(payload) {
    const buyerPays = payload.buyerPaysShipping ?? false;
    const shipOnOwn = payload.shipOnOwn ?? false;

    // Ship on own
    if (shipOnOwn) {
      const soyo = document.querySelector('input#SOYO[type="radio"], input[value="SOYO"][type="radio"]');
      if (soyo && !soyo.checked) {
        soyo.click();
        soyo.dispatchEvent(new Event("change", { bubbles: true }));
      }
      return;
    }

    // Shipping Payer (Free shipping vs Buyer pays)
    const trigger = document.querySelector('[data-testid="ShippingPayerOption"][aria-haspopup="listbox"]')
      || document.querySelector('#ShippingPayerOption[aria-haspopup="listbox"]');
    if (trigger) {
      const currentlyNo = (trigger.textContent || "").trim().toLowerCase() === "no";
      if ((buyerPays && !currentlyNo) || (!buyerPays && currentlyNo)) {
        realClick(trigger);
        const wantTestId = buyerPays ? "FreeShippingNoButton" : "FreeShippingYesButton";
        const option = await waitFor(() => document.querySelector(`[data-testid="${wantTestId}"]`), 2000);
        if (option) realClick(option);
      }
    }
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

  async function pollForSuccessModal(productId) {
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

        // Notify background script
        chrome.runtime.sendMessage({
          type: "MERCARI_CROSS_POST_RESULT",
          success: true,
          productId,
          mercariItemId,
          mercariUrl,
        });
        return;
      }
    }
  }

  // ── Auto-Start Execution ────────────────────────────────────────────────────

  chrome.runtime.sendMessage({ type: "GET_MERCARI_PAYLOAD" }, (res) => {
    if (res && res.payload) {
      runMercariCrossPost(res.payload);
    }
  });
})();
