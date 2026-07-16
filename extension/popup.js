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

document.addEventListener("DOMContentLoaded", async () => {
  const statusEl = document.getElementById("status");
  const authBtn = document.getElementById("auth-btn");
  const dashboardUrlInput = document.getElementById("dashboard-url");
  const saveDashboardBtn = document.getElementById("save-dashboard-btn");
  const recentSection = document.getElementById("recent-section");
  const recentList = document.getElementById("recent-list");

  const { idToken, userEmail, recentImports, dashboardBaseUrl } = await chrome.storage.local.get([
    "idToken",
    "userEmail",
    "recentImports",
    "dashboardBaseUrl",
  ]);

  const currentDashboardUrl = normalizeDashboardUrl(dashboardBaseUrl);
  if (dashboardUrlInput) dashboardUrlInput.value = currentDashboardUrl;
  if (saveDashboardBtn) {
    saveDashboardBtn.onclick = async () => {
      const nextUrl = normalizeDashboardUrl(dashboardUrlInput?.value);
      await chrome.storage.local.set({ dashboardBaseUrl: nextUrl });
      if (dashboardUrlInput) dashboardUrlInput.value = nextUrl;
      statusEl.textContent = `Dashboard set to ${nextUrl}`;
    };
  }

  if (idToken && userEmail) {
    statusEl.textContent = "Signed in as ";
    const strong = document.createElement("strong");
    strong.textContent = userEmail;
    statusEl.appendChild(strong);
    authBtn.textContent = "Sign out";
    authBtn.onclick = () => {
      chrome.storage.local.remove(["idToken", "userEmail"]);
      window.close();
    };
  } else {
    statusEl.textContent = "Not signed in";
    authBtn.textContent = "Sign in";
    authBtn.onclick = () => openDashboard("/login");
  }

  if (recentImports?.length) {
    recentSection.style.display = "block";
    recentImports.slice(0, 3).forEach((r) => {
      const div = document.createElement("div");
      div.className = "recent-item";
      div.textContent = r.title; // textContent — title is scraped from AliExpress
      recentList.appendChild(div);
    });
  }
});

// The web app sets the idToken in chrome.storage after login via:
// chrome.runtime.sendMessage is not available cross-origin, so the web app
// writes the token using the extension's externally_connectable message passing.
// See: manifest.json "externally_connectable" (add the web app origin there).
