/**
 * saved_search_notify.js
 *
 * notifySavedSearchMatches — triggered whenever a listing is written. When a listing
 * transitions into `active` (newly published, not just re-saved while already active),
 * checks it against every user's saved searches and writes an in-app notification doc
 * for each match, surfaced by InboxView's "Search" filter.
 *
 * Matching mirrors the tokenized fuzzy logic in SearchRepository.swift (order-independent,
 * typo-tolerant) so a saved search notifies on the same listings manually searching it
 * would find.
 */

const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

if (admin.apps.length === 0) admin.initializeApp();

function tokenize(text) {
  return (text || "")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean);
}

function levenshteinDistance(a, b) {
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;

  let previousRow = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const currentRow = [i];
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      currentRow[j] = Math.min(
        previousRow[j] + 1,
        currentRow[j - 1] + 1,
        previousRow[j - 1] + cost
      );
    }
    previousRow = currentRow;
  }
  return previousRow[b.length];
}

function tokenMatches(queryToken, titleTokens) {
  for (const token of titleTokens) {
    if (token === queryToken) return true;
    if (token.startsWith(queryToken) || queryToken.startsWith(token)) return true;
    const maxLen = Math.max(queryToken.length, token.length);
    const allowedDistance = Math.max(1, Math.floor(maxLen / 3));
    if (levenshteinDistance(queryToken, token) <= allowedDistance) return true;
  }
  return false;
}

function matchesQuery(query, titleTokens) {
  const queryTokens = tokenize(query);
  if (queryTokens.length === 0) return false;
  return queryTokens.every((qt) => tokenMatches(qt, titleTokens));
}

exports.notifySavedSearchMatches = onDocumentWritten("listings/{listingId}", async (event) => {
  const after = event.data.after.exists ? event.data.after.data() : null;
  if (!after || after.status !== "active") return;

  const before = event.data.before.exists ? event.data.before.data() : null;
  if (before && before.status === "active") return; // already notified on the original publish

  const titleTokens = tokenize(after.customTitle);
  if (titleTokens.length === 0) return;

  const db = admin.firestore();
  const savedSearches = await db.collectionGroup("savedSearches").get();

  const batch = db.batch();
  let matchCount = 0;

  for (const doc of savedSearches.docs) {
    const userRef = doc.ref.parent.parent;
    if (!userRef || userRef.id === after.userId) continue; // don't notify the seller about their own listing

    const { query } = doc.data();
    if (!matchesQuery(query, titleTokens)) continue;

    const notifRef = userRef.collection("searchNotifications").doc();
    batch.set(notifRef, {
      savedQuery: query,
      listingId: event.params.listingId,
      listingTitle: after.customTitle || null,
      listingPrice: after.price ?? null,
      listingPhotoPath: after.coverPhotoPath || null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      isRead: false,
    });
    matchCount++;
  }

  if (matchCount > 0) await batch.commit();
});
