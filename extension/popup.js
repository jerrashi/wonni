const DEFAULT_DASHBOARD_URL = "https://wonni-dropship.web.app";

function normalizeDashboardUrl(rawUrl) {
  try {
    return new URL(rawUrl).origin;
  } catch {
    return DEFAULT_DASHBOARD_URL;
  }
}

async function getDashboardUrl() {
  const { dashboardBaseUrl } = await chrome.storage.local.get(["dashboardBaseUrl"]);
  return normalizeDashboardUrl(dashboardBaseUrl);
}

async function openDashboard(path = "") {
  const dashboardUrl = await getDashboardUrl();
  chrome.tabs.create({ url: `${dashboardUrl}${path}` });
}

// This popup can run two ways: as the real toolbar-icon popup (window.top is
// itself), or injected as an iframe on the page by weverse_content.js's
// floating button. window.close() only works in the former — in the latter,
// ask the parent frame to remove the iframe wrapper instead.
function isInIframe() {
  return window.self !== window.top;
}

function closePopup() {
  if (isInIframe()) {
    window.parent.postMessage({ type: "WONNI_CLOSE_POPUP" }, "*");
  } else {
    window.close();
  }
}

const BATCH_CHUNK_SIZE = 20;

document.addEventListener("DOMContentLoaded", async () => {
  const statusEl = document.getElementById("status");
  const authBtn = document.getElementById("auth-btn");
  const openDashboardBtn = document.getElementById("open-dashboard-btn");
  const dashboardUrlInput = document.getElementById("dashboard-url");

  const singleCard = document.getElementById("single-card");
  const singlePhoto = document.getElementById("single-photo");
  const singleTitle = document.getElementById("single-title");
  const singleMeta = document.getElementById("single-meta");
  const singleImportBtn = document.getElementById("single-import-btn");

  const checklistSection = document.getElementById("checklist-section");
  const checklistHeader = document.getElementById("checklist-header");
  const checklistGate = document.getElementById("checklist-gate");
  const importAllBtn = document.getElementById("import-all-btn");
  const selectBtn = document.getElementById("select-btn");
  const checklistBody = document.getElementById("checklist-body");
  const bulkList = document.getElementById("bulk-list");
  const selectAllCb = document.getElementById("select-all-cb");
  const bulkCountLabel = document.getElementById("bulk-count-label");
  const importSelectedBtn = document.getElementById("import-selected-btn");
  const progressWrap = document.getElementById("progress-wrap");
  const progressFill = document.getElementById("progress-fill");
  const progressText = document.getElementById("progress-text");

  const { idToken, userEmail, dashboardBaseUrl } = await chrome.storage.local.get([
    "idToken",
    "userEmail",
    "dashboardBaseUrl",
  ]);

  const currentDashboardUrl = normalizeDashboardUrl(dashboardBaseUrl);
  if (dashboardUrlInput) dashboardUrlInput.value = currentDashboardUrl;
  dashboardUrlInput?.addEventListener("change", async () => {
    const nextUrl = normalizeDashboardUrl(dashboardUrlInput?.value);
    await chrome.storage.local.set({ dashboardBaseUrl: nextUrl });
    if (dashboardUrlInput) dashboardUrlInput.value = nextUrl;
  });

  if (openDashboardBtn) openDashboardBtn.onclick = () => openDashboard();

  if (idToken && userEmail) {
    authBtn.textContent = "Sign out";
    authBtn.title = `Signed in as ${userEmail}`;
    authBtn.onclick = () => {
      chrome.storage.local.remove(["idToken", "userEmail"]);
      closePopup();
    };
  } else {
    statusEl.textContent = "Not signed in";
    authBtn.textContent = "Sign in";
    authBtn.onclick = () => openDashboard("/login");
    return;
  }

  // Detect active tab and branch on page type
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id || !tab.url?.includes("shop.weverse.io")) {
    statusEl.textContent = "Navigate to shop.weverse.io to import listings.";
    return;
  }

  const saleMatch = tab.url.match(/\/artists\/(\d+)\/sales\/(\d+)/);
  const isOrderHistory = /\/order\/history/.test(tab.url);

  if (saleMatch) {
    await renderSingleMode(tab.id);
  } else if (isOrderHistory) {
    statusEl.textContent = "Loading order history…";
    chrome.tabs.sendMessage(tab.id, { type: "FETCH_ORDER_HISTORY" }, (response) => {
      if (chrome.runtime.lastError || response?.error) {
        statusEl.textContent = response?.error ?? "Could not load order history.";
        return;
      }
      renderListMode(response.items ?? [], "Orders");
    });
  } else {
    statusEl.textContent = "Scanning Weverse page items…";
    chrome.tabs.sendMessage(tab.id, { type: "SCRAPE_PAGE_ITEMS" }, (response) => {
      if (chrome.runtime.lastError || !response?.items) {
        statusEl.textContent = "Open an Artist Shop page, a product page, or your Order History to detect items.";
        return;
      }
      renderListMode(response.items, "Items");
    });
  }

  async function renderSingleMode(tabId) {
    const single = await new Promise((resolve) => {
      chrome.tabs.sendMessage(tabId, { type: "SCRAPE_SINGLE_ITEM" }, (response) => resolve(response?.item ?? null));
    });

    if (!single) {
      statusEl.textContent = "Could not read this product yet — try reopening in a moment.";
      return;
    }

    statusEl.textContent = "";
    singleCard.style.display = "block";
    singlePhoto.src = single.thumbnailUrl || "";
    singleTitle.textContent = single.title;
    singleMeta.textContent = [
      single.artist,
      typeof single.price === "number" ? `$${single.price}` : null,
      single.variantCount ? `${single.variantCount} variant${single.variantCount === 1 ? "" : "s"}` : null,
    ].filter(Boolean).join(" · ");

    singleImportBtn.onclick = () => importSingleItem(single, singleImportBtn);

    // Secondary block: other items found elsewhere on this page.
    chrome.tabs.sendMessage(tabId, { type: "SCRAPE_PAGE_ITEMS" }, (response) => {
      const items = (response?.items ?? []).filter((item) => item.saleId !== single.saleId);
      if (!items.length) return;
      renderChecklist({ items, gated: false, header: `Related items on this page (${items.length})` });
    });
  }

  function renderListMode(items, noun) {
    if (!items.length) {
      statusEl.textContent = `No ${noun.toLowerCase()} detected on this page.`;
      return;
    }
    statusEl.textContent = "";
    renderChecklist({ items, gated: true, header: `${items.length} ${noun} Found` });
  }

  function importSingleItem(single, btnEl) {
    btnEl.disabled = true;
    btnEl.textContent = "Importing…";
    chrome.runtime.sendMessage(
      { type: "IMPORT_PRODUCT", source: "weverse", data: { productUrl: single.productUrl, title: single.title } },
      (response) => {
        if (chrome.runtime.lastError || response?.error) {
          btnEl.disabled = false;
          btnEl.textContent = "Import";
          statusEl.textContent = response?.error ?? "Import failed — are you signed in?";
          statusEl.style.color = "#ef4444";
        } else {
          btnEl.textContent = "Imported!";
          setTimeout(closePopup, 1200);
        }
      }
    );
  }

  // ── Shared checklist component ────────────────────────────────────────
  // Used both for the "related items" secondary block on a product page
  // (ungated — small/scoped, no confirmation needed) and for the whole
  // popup on order-history/generic list pages (gated behind Import
  // All/Select — a blind bulk-import there deserves a confirmation step).
  function renderChecklist({ items, gated, header }) {
    checklistSection.style.display = "block";
    checklistHeader.textContent = header;

    if (gated) {
      checklistGate.style.display = "flex";
      checklistBody.style.display = "none";
      importAllBtn.onclick = () => {
        if (!window.confirm(`Import all ${items.length} items?`)) return;
        expandChecklist(items);
        runChunkedQueue(items);
      };
      selectBtn.onclick = () => expandChecklist(items);
    } else {
      expandChecklist(items);
    }
  }

  function expandChecklist(items) {
    checklistGate.style.display = "none";
    checklistBody.style.display = "block";
    renderItemList(items);
  }

  function renderItemList(items) {
    bulkList.innerHTML = "";

    items.forEach((item, index) => {
      const row = document.createElement("div");
      row.className = "bulk-item";

      const cb = document.createElement("input");
      cb.type = "checkbox";
      cb.checked = true;
      cb.dataset.index = String(index);
      cb.className = "item-cb";

      const img = document.createElement("img");
      img.src = item.thumbnailUrl || "";
      img.alt = item.title;

      const info = document.createElement("div");
      info.className = "bulk-item-info";

      const title = document.createElement("div");
      title.className = "bulk-item-title";
      title.textContent = item.title;

      const meta = document.createElement("div");
      meta.className = "bulk-item-meta";
      meta.textContent = `${item.artist ? item.artist + " · " : ""}$${item.price}`;

      info.appendChild(title);
      info.appendChild(meta);
      row.appendChild(cb);
      row.appendChild(img);
      row.appendChild(info);
      bulkList.appendChild(row);
    });

    updateSelectionCount(items);

    selectAllCb.onchange = () => {
      const checkboxes = bulkList.querySelectorAll(".item-cb");
      checkboxes.forEach((cb) => { cb.checked = selectAllCb.checked; });
      updateSelectionCount(items);
    };

    bulkList.onchange = () => updateSelectionCount(items);

    importSelectedBtn.onclick = () => runChunkedQueue(getSelectedItems(items));
  }

  function getSelectedItems(items) {
    const checkboxes = bulkList.querySelectorAll(".item-cb:checked");
    const selected = [];
    checkboxes.forEach((cb) => {
      const idx = parseInt(cb.dataset.index, 10);
      if (items[idx]) selected.push(items[idx]);
    });
    return selected;
  }

  function updateSelectionCount(items) {
    const selected = getSelectedItems(items);
    bulkCountLabel.textContent = `${selected.length} / ${items.length} selected`;
    importSelectedBtn.textContent = `Import ${selected.length} Selected Item${selected.length === 1 ? "" : "s"}`;
    importSelectedBtn.disabled = selected.length === 0;
  }

  // ── Chunked Queue Runner for Large Selections ─────────────────────────────
  async function runChunkedQueue(allCandidates) {
    const selected = allCandidates;
    if (!selected.length) return;

    importSelectedBtn.disabled = true;
    importAllBtn.disabled = true;
    progressWrap.style.display = "block";
    progressFill.style.width = "0%";

    const totalCount = selected.length;
    let importedTotal = 0;

    // Split selection into chunks of BATCH_CHUNK_SIZE (20)
    const chunks = [];
    for (let i = 0; i < selected.length; i += BATCH_CHUNK_SIZE) {
      chunks.push(selected.slice(i, i + BATCH_CHUNK_SIZE));
    }

    for (let cIndex = 0; cIndex < chunks.length; cIndex++) {
      const chunk = chunks[cIndex];
      const batchNum = cIndex + 1;

      progressText.textContent = `Batch ${batchNum} of ${chunks.length}: importing ${chunk.length} items…`;

      try {
        const response = await new Promise((resolve) => {
          chrome.runtime.sendMessage(
            {
              type: "BULK_IMPORT_PRODUCTS",
              source: "weverse",
              items: chunk,
            },
            (res) => resolve(res)
          );
        });

        if (chrome.runtime.lastError || response?.error) {
          progressText.textContent = `Batch ${batchNum} failed: ${response?.error ?? "Network error."}`;
        } else {
          importedTotal += response.importedCount ?? chunk.length;
        }
      } catch (err) {
        progressText.textContent = `Batch ${batchNum} error: ${err.message}`;
      }

      const pct = Math.round(((cIndex + 1) / chunks.length) * 100);
      progressFill.style.width = `${pct}%`;
    }

    progressText.textContent = `Complete! ${importedTotal} of ${totalCount} items imported. Opening dashboard…`;
    progressFill.style.width = "100%";

    setTimeout(() => {
      openDashboard();
      closePopup();
    }, 1500);
  }
});
