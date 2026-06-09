/**
 * etsy_listing.js
 *
 * Firebase Cloud Functions: etsyCreateListing, etsyUpdateListing,
 * etsyDeleteListing, etsyCheckShopSetup
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const https = require("https");
const http = require("http");
const { GoogleGenerativeAI } = require("@google/generative-ai");
const { refreshEtsyToken } = require("./etsy_auth");

if (admin.apps.length === 0) admin.initializeApp();

const etsyClientId = defineSecret("ETSY_CLIENT_ID");
const geminiApiKey = defineSecret("GEMINI_API_KEY");

// Module-level taxonomy cache (lives for the function instance lifetime ~15 min)
let taxonomyCache = null;

// ─────────────────────────────────────────────────────────────
// HTTP helpers
// ─────────────────────────────────────────────────────────────

function makeHttpRequest(options, bodyData = null) {
  return new Promise((resolve, reject) => {
    const lib = options.port === 80 ? http : https;
    const req = lib.request(options, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({
        statusCode: res.statusCode,
        headers: res.headers,
        body: Buffer.concat(chunks).toString("utf8"),
      }));
    });
    req.on("error", reject);
    if (bodyData) {
      const payload = Buffer.isBuffer(bodyData) ? bodyData
        : typeof bodyData === "string" ? Buffer.from(bodyData)
        : Buffer.from(JSON.stringify(bodyData));
      req.write(payload);
    }
    req.end();
  });
}

/** Downloads a URL (http or https) and returns a Buffer. */
function downloadBuffer(url) {
  return new Promise((resolve, reject) => {
    const lib = url.startsWith("https") ? https : http;
    lib.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return resolve(downloadBuffer(res.headers.location));
      }
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve(Buffer.concat(chunks)));
      res.on("error", reject);
    }).on("error", reject);
  });
}

// ─────────────────────────────────────────────────────────────
// Token management
// ─────────────────────────────────────────────────────────────

async function getActiveEtsyToken(uid, clientId, db) {
  const ref = db.collection("users").doc(uid).collection("integrations").doc("etsy");
  const doc = await ref.get();
  if (!doc.exists || !doc.data().isConnected) {
    throw new HttpsError(
      "failed-precondition",
      "Etsy account not connected. Please reconnect in Settings."
    );
  }
  const data = doc.data();
  const expiresAt = data.tokenExpiresAt?.toMillis() ?? 0;

  if (Date.now() > expiresAt - 5 * 60 * 1000) {
    const refreshed = await refreshEtsyToken(clientId, null, data.refreshToken);
    const newExpiry = admin.firestore.Timestamp.fromMillis(
      Date.now() + refreshed.expires_in * 1000
    );
    await ref.update({
      accessToken: refreshed.access_token,
      refreshToken: refreshed.refresh_token ?? data.refreshToken,
      tokenExpiresAt: newExpiry,
    });
    return { accessToken: refreshed.access_token, shopId: data.shopId };
  }
  return { accessToken: data.accessToken, shopId: data.shopId };
}

// ─────────────────────────────────────────────────────────────
// Etsy API helpers
// ─────────────────────────────────────────────────────────────

function etsyHeaders(accessToken, clientId, extra = {}) {
  return {
    "x-api-key": clientId,
    "Authorization": `Bearer ${accessToken}`,
    "Content-Type": "application/json",
    ...extra,
  };
}

async function etsyGet(path, accessToken, clientId) {
  const res = await makeHttpRequest({
    hostname: "openapi.etsy.com",
    path,
    method: "GET",
    headers: etsyHeaders(accessToken, clientId),
  });
  return { statusCode: res.statusCode, data: JSON.parse(res.body) };
}

async function etsyPost(path, body, accessToken, clientId) {
  const payload = JSON.stringify(body);
  const res = await makeHttpRequest({
    hostname: "openapi.etsy.com",
    path,
    method: "POST",
    headers: etsyHeaders(accessToken, clientId, { "Content-Length": Buffer.byteLength(payload) }),
  }, payload);
  return { statusCode: res.statusCode, data: JSON.parse(res.body) };
}

async function etsyPatch(path, body, accessToken, clientId) {
  const payload = JSON.stringify(body);
  const res = await makeHttpRequest({
    hostname: "openapi.etsy.com",
    path,
    method: "PATCH",
    headers: etsyHeaders(accessToken, clientId, { "Content-Length": Buffer.byteLength(payload) }),
  }, payload);
  return { statusCode: res.statusCode, data: JSON.parse(res.body) };
}

// ─────────────────────────────────────────────────────────────
// Taxonomy
// ─────────────────────────────────────────────────────────────

async function getTaxonomyLeafNodes(clientId) {
  if (taxonomyCache) return taxonomyCache;
  const res = await makeHttpRequest({
    hostname: "openapi.etsy.com",
    path: "/v3/application/seller-taxonomy/nodes",
    method: "GET",
    headers: { "x-api-key": clientId },
  });
  if (res.statusCode !== 200) {
    console.error(`[etsy] Taxonomy fetch failed (${res.statusCode})`);
    return [];
  }
  const all = JSON.parse(res.body).results || [];
  // Keep only leaf nodes (children_count === 0) and compress to id + path
  const leaves = all
    .filter((n) => n.children_count === 0)
    .map((n) => ({ id: n.id, name: n.full_path_taxonomy_string || n.name }));
  taxonomyCache = leaves;
  return leaves;
}

// ─────────────────────────────────────────────────────────────
// Gemini — fills when_made, taxonomy_id, who_made
// ─────────────────────────────────────────────────────────────

const WHEN_MADE_VALUES = [
  "made_to_order",
  "2020_2024", "2010_2019", "2000_2009",
  "1990s", "1980s", "1970s", "1960s", "1950s", "before_1950",
];

async function getEtsyFieldsFromGemini(geminiKey, clientId, title, description, category) {
  const nodes = await getTaxonomyLeafNodes(clientId);

  // Pass at most 400 nodes — enough coverage without blowing the context window
  const taxonomyList = nodes.slice(0, 400)
    .map((n) => `${n.id}: ${n.name}`)
    .join("\n");

  const genAI = new GoogleGenerativeAI(geminiKey);
  const model = genAI.getGenerativeModel({ model: "gemini-2.0-flash-lite" });

  const prompt = `
You are helping create an Etsy listing. Based on the listing details below, return a JSON object
with exactly three fields:

1. taxonomy_id (integer): The best matching Etsy taxonomy leaf node ID from the list below.
   Choose the most specific match. If nothing fits well, use 69150398 (Accessories).

2. when_made (string): When the item was made. Must be one of:
   ${WHEN_MADE_VALUES.join(", ")}
   For modern K-pop / entertainment merchandise, use "2020_2024" or "2010_2019" as appropriate.
   Use "made_to_order" only for custom/handmade items.

3. who_made (string): Must be one of: "i_did", "someone_else", "collective".
   For resale of existing products, use "someone_else".
   Use "i_did" only if the item is handmade by the seller.

Listing details:
- Title: ${title}
- Description: ${description || "(none)"}
- Category hint: ${category || "(none)"}

Available Etsy taxonomy leaf nodes (id: full path):
${taxonomyList}

Return ONLY a JSON object like: {"taxonomy_id": 1234, "when_made": "2020_2024", "who_made": "someone_else"}
`.trim();

  const result = await model.generateContent(prompt);
  const raw = result.response.text()
    .replace(/```json/g, "").replace(/```/g, "").trim();

  const parsed = JSON.parse(raw);
  return {
    taxonomy_id: Number(parsed.taxonomy_id) || 69150398,
    when_made: WHEN_MADE_VALUES.includes(parsed.when_made) ? parsed.when_made : "2020_2024",
    who_made: ["i_did", "someone_else", "collective"].includes(parsed.who_made)
      ? parsed.who_made : "someone_else",
  };
}

// ─────────────────────────────────────────────────────────────
// Shop setup helpers
// ─────────────────────────────────────────────────────────────

async function fetchFirstShippingProfileId(shopId, accessToken, clientId) {
  const { statusCode, data } = await etsyGet(
    `/v3/application/shops/${shopId}/shipping-profiles`,
    accessToken, clientId
  );
  if (statusCode !== 200) return null;
  const profiles = data.results || [];
  return profiles.length > 0 ? profiles[0].shipping_profile_id : null;
}

async function fetchFirstReturnPolicyId(shopId, accessToken, clientId) {
  const { statusCode, data } = await etsyGet(
    `/v3/application/shops/${shopId}/return-policies`,
    accessToken, clientId
  );
  if (statusCode !== 200) return null;
  const policies = data.results || [];
  return policies.length > 0 ? policies[0].return_policy_id : null;
}

// ─────────────────────────────────────────────────────────────
// Image upload (multipart/form-data)
// ─────────────────────────────────────────────────────────────

async function uploadImageToEtsy(shopId, listingId, rank, imageBuffer, accessToken, clientId) {
  const boundary = `--------WonniBoundary${Date.now()}`;
  const filename = `photo_${rank}.jpg`;

  const head = Buffer.from(
    `--${boundary}\r\n` +
    `Content-Disposition: form-data; name="image"; filename="${filename}"\r\n` +
    `Content-Type: image/jpeg\r\n\r\n`
  );
  const rankPart = Buffer.from(
    `\r\n--${boundary}\r\n` +
    `Content-Disposition: form-data; name="rank"\r\n\r\n` +
    `${rank}`
  );
  const overwritePart = Buffer.from(
    `\r\n--${boundary}\r\n` +
    `Content-Disposition: form-data; name="overwrite"\r\n\r\n` +
    `true`
  );
  const tail = Buffer.from(`\r\n--${boundary}--\r\n`);

  const body = Buffer.concat([head, imageBuffer, rankPart, overwritePart, tail]);

  const res = await makeHttpRequest({
    hostname: "openapi.etsy.com",
    path: `/v3/application/shops/${shopId}/listings/${listingId}/images`,
    method: "POST",
    headers: {
      "x-api-key": clientId,
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": `multipart/form-data; boundary=${boundary}`,
      "Content-Length": body.length,
    },
  }, body);

  if (res.statusCode !== 200 && res.statusCode !== 201) {
    console.error(`[etsy] Image upload rank ${rank} failed (${res.statusCode}): ${res.body}`);
  }
  return res.statusCode === 200 || res.statusCode === 201;
}

async function uploadListingImages(shopId, listingId, photoPaths, accessToken, clientId) {
  const bucket = admin.storage().bucket();
  let rank = 1;
  for (const path of photoPaths.slice(0, 10)) {
    try {
      const url = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(path)}?alt=media`;
      const buf = await downloadBuffer(url);
      await uploadImageToEtsy(shopId, listingId, rank, buf, accessToken, clientId);
      rank++;
    } catch (err) {
      console.error(`[etsy] Failed to upload image ${path}:`, err.message);
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Exported Cloud Functions
// ─────────────────────────────────────────────────────────────

/**
 * etsyCheckShopSetup — called right after OAuth connects.
 * Returns whether the shop has at least one shipping profile and return policy.
 */
exports.etsyCheckShopSetup = onCall(
  { secrets: [etsyClientId] },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const uid = request.auth.uid;
    const db = admin.firestore();
    const clientId = etsyClientId.value();

    const { accessToken, shopId } = await getActiveEtsyToken(uid, clientId, db);
    if (!shopId) throw new HttpsError("failed-precondition", "Shop ID not found. Reconnect your Etsy account.");

    const [shippingId, returnId] = await Promise.all([
      fetchFirstShippingProfileId(shopId, accessToken, clientId),
      fetchFirstReturnPolicyId(shopId, accessToken, clientId),
    ]);

    return {
      hasShippingProfile: shippingId !== null,
      hasReturnPolicy: returnId !== null,
    };
  }
);

/**
 * etsyCreateListing — creates a new Etsy listing from a Wonni listing document.
 */
exports.etsyCreateListing = onCall(
  { secrets: [etsyClientId, geminiApiKey], timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const uid = request.auth.uid;
    const { listingId } = request.data;
    if (!listingId) throw new HttpsError("invalid-argument", "listingId is required.");

    const db = admin.firestore();
    const clientId = etsyClientId.value();

    // Load listing
    const listingRef = db.collection("listings").doc(listingId);
    const listingDoc = await listingRef.get();
    if (!listingDoc.exists) throw new HttpsError("not-found", "Listing not found.");
    const listing = listingDoc.data();
    if (listing.userId !== uid) throw new HttpsError("permission-denied", "Not your listing.");

    // Idempotency guard
    if (listing.crossPostStatus?.etsy === "posted" && listing.crossPostListingIds?.etsy) {
      return { success: true, listingId: listing.crossPostListingIds.etsy };
    }

    await listingRef.set({ crossPostStatus: { etsy: "pending" } }, { merge: true });

    try {
      const { accessToken, shopId } = await getActiveEtsyToken(uid, clientId, db);
      if (!shopId) throw new HttpsError("failed-precondition", "Shop ID missing. Reconnect your Etsy account.");

      // Require shipping profile and return policy
      const [shippingProfileId, returnPolicyId] = await Promise.all([
        fetchFirstShippingProfileId(shopId, accessToken, clientId),
        fetchFirstReturnPolicyId(shopId, accessToken, clientId),
      ]);
      if (!shippingProfileId) {
        throw new HttpsError(
          "failed-precondition",
          "etsy_missing_shipping_profile: Add a shipping profile in your Etsy shop settings before listing."
        );
      }
      if (!returnPolicyId) {
        throw new HttpsError(
          "failed-precondition",
          "etsy_missing_return_policy: Add a return policy in your Etsy shop settings before listing."
        );
      }

      const title = (listing.customTitle || "").slice(0, 140);
      const description = listing.customDescription || "";

      // Gemini fills taxonomy_id, when_made, who_made
      const { taxonomy_id, when_made, who_made } = await getEtsyFieldsFromGemini(
        geminiApiKey.value(), clientId, title, description, listing.category
      );

      const priceAmount = Math.max(0.20, Math.round((listing.price ?? 0) * 100) / 100);

      const createBody = {
        quantity: listing.quantity ?? 1,
        title,
        description: description || title,
        price: priceAmount,
        who_made,
        when_made,
        taxonomy_id,
        state: "active",
        shipping_profile_id: shippingProfileId,
        return_policy_id: returnPolicyId,
      };

      const { statusCode, data: created } = await etsyPost(
        `/v3/application/shops/${shopId}/listings`,
        createBody, accessToken, clientId
      );

      if (statusCode !== 200 && statusCode !== 201) {
        throw new Error(`Etsy create listing failed (${statusCode}): ${JSON.stringify(created)}`);
      }

      const etsyListingId = String(created.listing_id);

      // Upload photos
      const photoPaths = listing.photoPaths || [];
      if (photoPaths.length > 0) {
        await uploadListingImages(shopId, etsyListingId, photoPaths, accessToken, clientId);
      }

      await listingRef.set({
        crossPostStatus: { etsy: "posted" },
        crossPostListingIds: { etsy: etsyListingId },
      }, { merge: true });

      return { success: true, listingId: etsyListingId };
    } catch (err) {
      await listingRef.set({ crossPostStatus: { etsy: "failed" } }, { merge: true });
      if (err instanceof HttpsError) throw err;
      throw new HttpsError("internal", `Etsy listing failed: ${err.message}`);
    }
  }
);

/**
 * etsyUpdateListing — syncs title, description, and price to an existing Etsy listing.
 */
exports.etsyUpdateListing = onCall(
  { secrets: [etsyClientId], timeoutSeconds: 60 },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const uid = request.auth.uid;
    const { listingId } = request.data;
    if (!listingId) throw new HttpsError("invalid-argument", "listingId is required.");

    const db = admin.firestore();
    const clientId = etsyClientId.value();

    const listingDoc = await db.collection("listings").doc(listingId).get();
    if (!listingDoc.exists) throw new HttpsError("not-found", "Listing not found.");
    const listing = listingDoc.data();
    if (listing.userId !== uid) throw new HttpsError("permission-denied", "Not your listing.");

    const etsyId = listing.crossPostListingIds?.etsy;
    if (!etsyId) throw new HttpsError("failed-precondition", "No Etsy listing ID on record.");

    const { accessToken, shopId } = await getActiveEtsyToken(uid, clientId, db);

    const { statusCode, data } = await etsyPatch(
      `/v3/application/shops/${shopId}/listings/${etsyId}`,
      {
        title: (listing.customTitle || "").slice(0, 140),
        description: listing.customDescription || "",
        price: Math.max(0.20, Math.round((listing.price ?? 0) * 100) / 100),
        quantity: listing.quantity ?? 1,
      },
      accessToken, clientId
    );

    if (statusCode === 404) {
      await db.collection("listings").doc(listingId).set(
        { crossPostStatus: { etsy: "deleted" } }, { merge: true }
      );
      throw new HttpsError("not-found", "Etsy listing not found — it may have been deleted.");
    }
    if (statusCode !== 200) {
      throw new HttpsError("internal", `Etsy update failed (${statusCode}): ${JSON.stringify(data)}`);
    }

    return { success: true };
  }
);

/**
 * etsyDeleteListing — deactivates (drafts) the Etsy listing.
 */
exports.etsyDeleteListing = onCall(
  { secrets: [etsyClientId], timeoutSeconds: 30 },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const uid = request.auth.uid;
    const { listingId } = request.data;
    if (!listingId) throw new HttpsError("invalid-argument", "listingId is required.");

    const db = admin.firestore();
    const clientId = etsyClientId.value();

    const listingDoc = await db.collection("listings").doc(listingId).get();
    if (!listingDoc.exists) throw new HttpsError("not-found", "Listing not found.");
    const listing = listingDoc.data();
    if (listing.userId !== uid) throw new HttpsError("permission-denied", "Not your listing.");

    const etsyId = listing.crossPostListingIds?.etsy;
    if (!etsyId) return { success: true };

    const { accessToken, shopId } = await getActiveEtsyToken(uid, clientId, db);

    // Etsy doesn't have a delete endpoint for active listings — set to inactive (draft)
    await etsyPatch(
      `/v3/application/shops/${shopId}/listings/${etsyId}`,
      { state: "inactive" },
      accessToken, clientId
    );

    await db.collection("listings").doc(listingId).set(
      { crossPostStatus: { etsy: "" }, crossPostListingIds: { etsy: admin.firestore.FieldValue.delete() } },
      { merge: true }
    );

    return { success: true };
  }
);
