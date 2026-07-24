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

const BATCH_CHUNK_SIZE = 20;

document.addEventListener("DOMContentLoaded", async () => {
  const statusEl = document.getElementById("status");
  const authBtn = document.getElementById("auth-btn");
  const openDashboardBtn = document.getElementById("open-dashboard-btn");
  const dashboardUrlInput = document.getElementById("dashboard-url");
  const bulkSection = document.getElementById("bulk-section");
  const bulkList = document.getElementById("bulk-list");
  const selectAllCb = document.getElementById("select-all-cb");
  const bulkCountLabel = document.getElementById("bulk-count-label");
  const importBulkBtn = document.getElementById("import-bulk-btn");
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
      window.close();
    };
  } else {
    statusEl.textContent = "Not signed in";
    authBtn.textContent = "Sign in";
    authBtn.onclick = () => openDashboard("/login");
    return;
  }

  // Detect active tab and send SCRAPE_PAGE_ITEMS message
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id || !tab.url?.includes("shop.weverse.io")) {
    statusEl.textContent = "Navigate to shop.weverse.io to import listings.";
    return;
  }

  statusEl.textContent = "Scanning Weverse page items…";

  chrome.tabs.sendMessage(tab.id, { type: "SCRAPE_PAGE_ITEMS" }, (response) => {
    if (chrome.runtime.lastError || !response?.items) {
      statusEl.textContent = "Open an Artist Shop page or My Orders page to detect items.";
      return;
    }

    const items = response.items;
    if (items.length === 0) {
      statusEl.textContent = "No product items detected on this page.";
      return;
    }

    statusEl.textContent = `Found ${items.length} item${items.length === 1 ? "" : "s"} on this page.`;
    bulkSection.style.display = "block";
    renderItemList(items);
  });

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

    // Checkbox event listeners
    selectAllCb.onchange = () => {
      const checkboxes = bulkList.querySelectorAll(".item-cb");
      checkboxes.forEach((cb) => { cb.checked = selectAllCb.checked; });
      updateSelectionCount(items);
    };

    bulkList.addEventListener("change", () => updateSelectionCount(items));

    importBulkBtn.onclick = () => runChunkedQueue(items);
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
    importBulkBtn.textContent = `Import ${selected.length} Selected Item${selected.length === 1 ? "" : "s"}`;
    importBulkBtn.disabled = selected.length === 0;
  }

  // ── Chunked Queue Runner for Large Selections ─────────────────────────────
  async function runChunkedQueue(allCandidates) {
    const selected = getSelectedItems(allCandidates);
    if (!selected.length) return;

    importBulkBtn.disabled = true;
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
      window.close();
    }, 1500);
  }
});
