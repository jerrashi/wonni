/**
 * weverse_shipping_estimate.js — the per-user, per-platform "shipping cost by
 * item type" lookup table that backs the Weverse shop-section import's
 * shipping estimate (see extension/weverse_content.js's probeShippingCost for
 * the actual cart/checkout probe, and web/src/components/WeverseShopImportModal.jsx
 * for the import-flow orchestration).
 *
 * ── Why a lookup table instead of probing every item ───────────────────────
 * The probe adds a real item to the user's real Weverse cart and reads the
 * checkout preview — expensive and only as reliable as an unverified,
 * reverse-engineered API guess (see probeShippingCost's own caveat). Instead
 * of paying that cost per item, we probe once per *item type* per import
 * batch (the first importable item of that type) and store the result keyed
 * by (userId, platform, itemType) at `users/{uid}/shippingEstimates/{platform}_{itemType}`.
 * Every item of that type in the batch — probed or not — gets the same
 * resolved cost. A later probe for the same type only ever raises the stored
 * value (`max(existing, new)`), never lowers it, on the theory that a
 * heavier/bulkier variant of the same type is a more conservative estimate
 * than a lighter one (see PR discussion — user-specified behavior).
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { GoogleGenerativeAI } = require("@google/generative-ai");

const { geminiApiKey } = require("./gemini_identify");
const { downloadBuffer, isAllowedImageUrl } = require("./product_media");

const GEMINI_MODEL = "gemini-flash-lite-latest";

// Baseline candidate item types per platform. Reuses the same taxonomy
// gemini_identify.js already asks Gemini for at general import time, so
// "item type" here and "category" there stay the same vocabulary instead of
// drifting into two parallel taxonomies. Platform-specific because a future
// Costco/Amazon shipping-estimate pass (see PR discussion) will want its own
// baseline — these are starting candidates, not a closed set: a user's own
// previously-confirmed types (see getKnownItemTypes) are always merged in too,
// and Gemini/the user can always add a new one via "+ Add new".
const PLATFORM_BASELINE_ITEM_TYPES = {
  weverse: [
    "Photocard", "Keychain/Accessory", "Apparel", "Plushie", "Poster/Print",
    "Album/CD", "Light Stick", "Stationery", "Mirror/Beauty", "Collectible Figure", "Other",
  ],
};

function baselineItemTypes(platform) {
  return PLATFORM_BASELINE_ITEM_TYPES[platform] ?? PLATFORM_BASELINE_ITEM_TYPES.weverse;
}

function estimateDocId(platform, itemType) {
  // Firestore doc IDs can't contain "/"; item types like "Photocard" are
  // already safe, but be defensive since a user-typed "+ Add new" value ends
  // up here too.
  const safeType = String(itemType).replace(/\//g, "-").slice(0, 200);
  return `${platform}_${safeType}`;
}

function estimatesCollection(db, uid) {
  return db.collection("users").doc(uid).collection("shippingEstimates");
}

/** Every item type this user has ever confirmed/probed for this platform,
 *  merged with the platform baseline — the candidate list both Gemini
 *  classification and the client's manual-confirm dropdown draw from. */
async function getKnownItemTypes(db, uid, platform) {
  const snap = await estimatesCollection(db, uid).where("platform", "==", platform).get();
  const known = snap.docs.map((d) => d.data().itemType).filter(Boolean);
  return Array.from(new Set([...baselineItemTypes(platform), ...known]));
}

/** Reads the currently-stored estimate for (uid, platform, itemType), or
 *  null if this type has never been probed/confirmed for this user. */
async function getStoredEstimate(db, uid, platform, itemType) {
  const doc = await estimatesCollection(db, uid).doc(estimateDocId(platform, itemType)).get();
  return doc.exists ? (doc.data().shippingCost ?? null) : null;
}

/** Merges a freshly-probed cost into the stored per-type estimate —
 *  max(existing, new), per the user-specified "only ratchets up" behavior —
 *  and returns the resulting value. */
async function mergeShippingEstimate(db, uid, platform, itemType, newCost) {
  if (typeof newCost !== "number" || !Number.isFinite(newCost)) {
    throw new HttpsError("invalid-argument", "newCost must be a finite number.");
  }
  const ref = estimatesCollection(db, uid).doc(estimateDocId(platform, itemType));
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const existing = snap.exists ? snap.data().shippingCost : null;
    const merged = typeof existing === "number" ? Math.max(existing, newCost) : newCost;
    tx.set(ref, {
      userId: uid,
      platform,
      itemType,
      shippingCost: merged,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return merged;
  });
}

/**
 * Classifies one item's title (+ optional image) into the best-fitting type
 * from `candidateTypes`, via Gemini. Returns the matched type string, or
 * null if Gemini couldn't confidently match one (missing API key, network/
 * parse failure, or Gemini itself saying none fit) — the caller treats null
 * as "needs the user to manually confirm via dropdown."
 *
 * Logs every non-match case (comprehensive logging per PR discussion) so we
 * can see, over time, which titles keep falling through to manual confirm —
 * that's the signal for when the baseline/keyword list needs updating for
 * this platform, or when a new platform's taxonomy needs its own baseline.
 */
async function classifyItemType({ title, imageUrl, candidateTypes }) {
  const logCtx = { title, candidateCount: candidateTypes.length };
  try {
    const apiKey = process.env.GEMINI_API_KEY ?? process.env.GOOGLE_API_KEY;
    if (!apiKey) {
      console.warn("[weverse_shipping_estimate] classifyItemType: no Gemini API key configured", logCtx);
      return null;
    }

    const genAI = new GoogleGenerativeAI(apiKey);
    const model = genAI.getGenerativeModel({
      model: GEMINI_MODEL,
      systemInstruction: `You classify a resale item into exactly one type, for grouping items that ship at a similar cost.
Given a product title (and optionally a photo) and a list of candidate types, return ONLY the single best-matching
type string from the candidate list, verbatim (exact match, same casing). If none of the candidates reasonably fit
this item, return exactly "UNKNOWN" instead of guessing. Return ONLY the type string or "UNKNOWN" — no JSON, no
explanation, no punctuation.`,
    });

    const parts = [
      `Candidate types: ${candidateTypes.join(", ")}\nProduct title: ${title || "(not provided)"}`,
    ];

    if (imageUrl && isAllowedImageUrl(imageUrl)) {
      try {
        const buffer = await downloadBuffer(imageUrl);
        const mimeType = imageUrl.toLowerCase().endsWith(".png") ? "image/png" : "image/jpeg";
        parts.push({ inlineData: { mimeType, data: buffer.toString("base64") } });
      } catch (err) {
        console.warn("[weverse_shipping_estimate] classifyItemType: image download failed, continuing title-only", { ...logCtx, error: err.message });
      }
    }

    const result = await model.generateContent(parts);
    const raw = result.response.text().trim();

    if (raw === "UNKNOWN" || !candidateTypes.includes(raw)) {
      console.log("[weverse_shipping_estimate] classifyItemType: no confident match", { ...logCtx, geminiRaw: raw });
      return null;
    }
    return raw;
  } catch (err) {
    console.error("[weverse_shipping_estimate] classifyItemType failed", { ...logCtx, error: err.message });
    return null;
  }
}

/**
 * `classifyWeverseItemTypes` callable — the import modal calls this first,
 * for every item the user actually selected (never unselected preview
 * tiles — see PR discussion point 5), to get back a type per item plus the
 * known-types list for the manual-confirm dropdown ("+ Add new" included by
 * the client, not returned here).
 *
 * Request: { items: [{ saleId, title, thumbnailUrl? }] }
 * Response: {
 *   knownTypes: string[],
 *   classifications: { [saleId]: string | null }  // null => needs manual confirm
 * }
 */
exports.classifyWeverseItemTypes = onCall(
  { timeoutSeconds: 120, secrets: [geminiApiKey] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const items = request.data?.items;
    if (!Array.isArray(items) || items.length === 0) {
      throw new HttpsError("invalid-argument", "Missing items array.");
    }
    if (items.length > 25) {
      throw new HttpsError("invalid-argument", "Batch size exceeds limit of 25.");
    }

    const db = admin.firestore();
    const platform = "weverse";
    const knownTypes = await getKnownItemTypes(db, uid, platform);

    const classifications = {};
    // Sequential, not Promise.all: Gemini calls are rate-limited per-project,
    // and a whole-batch classification isn't latency-sensitive the way the
    // live cart probe is — the modal shows a spinner during this step anyway.
    for (const item of items) {
      if (!item?.saleId) continue;
      classifications[item.saleId] = await classifyItemType({
        title: item.title ?? "",
        imageUrl: item.thumbnailUrl,
        candidateTypes: knownTypes,
      });
    }

    return { knownTypes, classifications };
  }
);

module.exports.getKnownItemTypes = getKnownItemTypes;
module.exports.getStoredEstimate = getStoredEstimate;
module.exports.mergeShippingEstimate = mergeShippingEstimate;
module.exports.baselineItemTypes = baselineItemTypes;
