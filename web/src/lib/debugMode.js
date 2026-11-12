// Developer / debugging features (e.g. the Etsy drafts-only dry run) are hidden
// from normal users. Turn them on by opening any dashboard page with ?debug=1
// (remembered in this browser); ?debug=0 turns them off again.
const KEY = "wonniDebug";

export function isDebugMode() {
  try {
    const q = new URLSearchParams(window.location.search).get("debug");
    if (q === "1") localStorage.setItem(KEY, "1");
    if (q === "0") localStorage.removeItem(KEY);
    return localStorage.getItem(KEY) === "1";
  } catch {
    return false;
  }
}
