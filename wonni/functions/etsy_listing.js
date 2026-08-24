/**
 * etsy_listing.js
 *
 * Firebase Cloud Functions: etsyCreateListing, etsyUpdateListing,
 * etsyDeleteListing, etsyCheckShopSetup
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const https = require("https");
const http = require("http");
const { refreshEtsyToken, getEtsyCredentials } = require("./etsy_auth");

if (admin.apps.length === 0) admin.initializeApp();

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

async function getActiveEtsyToken(uid, clientId, sharedSecret, db) {
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
    const refreshed = await refreshEtsyToken(clientId, sharedSecret, data.refreshToken);
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

async function etsyPut(path, body, accessToken, clientId) {
  const payload = JSON.stringify(body);
  const res = await makeHttpRequest({
    hostname: "openapi.etsy.com",
    path,
    method: "PUT",
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
// Category resolution — deterministic, no LLM
//
// The single listing-flow Gemini call already produced `listing.category` (a path like
// "Electronics > Audio > Headphones"). Rather than spend a second Gemini call here, we
// fuzzy-match that path against Etsy's live taxonomy leaf nodes. when_made / who_made are
// defaulted for resale (Wonni is a reselling app), so they never needed an LLM.
// ─────────────────────────────────────────────────────────────

const ETSY_FALLBACK_TAXONOMY_ID = 69150398; // Accessories

/** Lowercase a string into a deduped-friendly word array. */
function categoryWords(s) {
  return String(s || "")
    .toLowerCase()
    .replace(/[^a-z0-9 ]/g, " ")
    .split(/\s+/)
    .filter(Boolean);
}

/**
 * Picks the best Etsy taxonomy leaf id for a Wonni category path by weighted word overlap
 * against each node's full taxonomy path. The category leaf (most specific segment) is
 * weighted highest, then the rest of the path, then the title as a weak tiebreaker.
 */
function matchEtsyTaxonomyId(nodes, title, category) {
  if (!Array.isArray(nodes) || nodes.length === 0) return ETSY_FALLBACK_TAXONOMY_ID;

  const path = String(category || "").split(">").map((s) => s.trim()).filter(Boolean);
  const leaf = path.length ? path[path.length - 1] : "";

  const weights = new Map();
  const add = (text, w) => {
    for (const word of categoryWords(text)) weights.set(word, (weights.get(word) || 0) + w);
  };
  add(leaf, 3);
  add(path.join(" "), 1);
  add(title, 0.5);
  if (weights.size === 0) return ETSY_FALLBACK_TAXONOMY_ID;

  let bestId = ETSY_FALLBACK_TAXONOMY_ID;
  let bestScore = 0;
  for (const n of nodes) {
    const nameWords = new Set(categoryWords(n.name));
    let score = 0;
    for (const [word, w] of weights) { if (nameWords.has(word)) score += w; }
    if (score > bestScore) { bestScore = score; bestId = n.id; }
  }
  return bestScore > 0 ? bestId : ETSY_FALLBACK_TAXONOMY_ID;
}

async function resolveEtsyFields(clientId, title, category) {
  const nodes = await getTaxonomyLeafNodes(clientId);
  const taxonomy_id = matchEtsyTaxonomyId(nodes, title, category);
  console.log(`[etsy] taxonomy "${category || "(none)"}" -> ${taxonomy_id}`);
  return {
    taxonomy_id,
    when_made: "2020_2024",   // resale of modern merch; Etsy requires a value
    who_made: "someone_else", // Wonni resells existing products
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
      const url = (path.startsWith("http://") || path.startsWith("https://"))
        ? path
        : `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(path)}?alt=media`;
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
  { timeoutSeconds: 60 },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const uid = request.auth.uid;
    const db = admin.firestore();
    const { credentialSet = "ios" } = request.data || {};

    const credentials = await getEtsyCredentials(credentialSet);
    const { accessToken, shopId } = await getActiveEtsyToken(uid, credentials.clientId, credentials.sharedSecret, db);
    if (!shopId) throw new HttpsError("failed-precondition", "Shop ID not found. Reconnect your Etsy account.");

    const [shippingId, returnId] = await Promise.all([
      fetchFirstShippingProfileId(shopId, accessToken, credentials.clientId),
      fetchFirstReturnPolicyId(shopId, accessToken, credentials.clientId),
    ]);

    return {
      hasShippingProfile: shippingId !== null,
      hasReturnPolicy: returnId !== null,
    };
  }
);

function buildEtsyInventoryPayload(variations = [], basePrice = 0.0) {
  const products = [];

  variations.forEach((v, idx) => {
    const sku = v.sku || `SKU_${idx + 1}`;
    const qty = (typeof v.quantity === "number" && v.quantity >= 0) ? v.quantity : 1;
    const rawPrice = (typeof v.price === "number" && v.price > 0) ? v.price : basePrice;
    const price = Math.max(0.20, Math.round(rawPrice * 100) / 100);

    const property_values = [];
    const attrs = v.attributes || [];
    if (attrs.length > 0) {
      attrs.forEach(({ name, value }) => {
        if (name && value) {
          property_values.push({
            property_name: name,
            values: [String(value)]
          });
        }
      });
    } else if (v.optionValues && Object.keys(v.optionValues).length > 0) {
      Object.entries(v.optionValues).forEach(([name, value]) => {
        if (name && value) {
          property_values.push({
            property_name: name,
            values: [String(value)]
          });
        }
      });
    } else if (v.name) {
      property_values.push({
        property_name: "Size",
        values: [String(v.name)]
      });
    }

    products.push({
      sku: sku,
      property_values: property_values.length > 0 ? property_values : [{ property_name: "Size", values: ["Regular"] }],
      offerings: [
        {
          price: price,
          quantity: qty,
          is_enabled: true
        }
      ]
    });
  });

  return {
    products,
    price_on_property: [],
    quantity_on_property: [],
    sku_on_property: []
  };
}

/**
 * etsyCreateListing — creates a new Etsy listing from a Wonni listing document.
 */
exports.etsyCreateListing = onCall(
  { timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const uid = request.auth.uid;
    const { listingId: rawListingId, productId, credentialSet = "ios", taxonomyId, shippingProfileId, returnPolicyId } = request.data || {};
    const listingId = rawListingId || productId;
    if (!listingId) throw new HttpsError("invalid-argument", "listingId is required.");

    const db = admin.firestore();
    const credentials = await getEtsyCredentials(credentialSet);
    const { clientId, sharedSecret } = credentials;

    // Load listing and product
    const [listingDoc, productDoc] = await Promise.all([
      db.collection("listings").doc(listingId).get(),
      db.collection("products").doc(listingId).get()
    ]);

    if (!listingDoc.exists && !productDoc.exists) throw new HttpsError("not-found", "Listing not found.");
    const listing = listingDoc.exists ? listingDoc.data() : {};
    const product = productDoc.exists ? productDoc.data() : {};

    if (listing.userId && listing.userId !== uid && product.userId && product.userId !== uid) {
      throw new HttpsError("permission-denied", "Not your listing.");
    }

    const listingRef = db.collection("listings").doc(listingId);
    const productRef = db.collection("products").doc(listingId);

    // Idempotency guard
    if ((listing.crossPostStatus?.etsy === "posted" && listing.crossPostListingIds?.etsy) ||
        (product.etsyStatus === "active" && product.etsyListingId)) {
      return { success: true, listingId: listing.crossPostListingIds?.etsy || product.etsyListingId };
    }

    await listingRef.set({ crossPostStatus: { etsy: "pending" } }, { merge: true });

    try {
      const { accessToken, shopId } = await getActiveEtsyToken(uid, clientId, sharedSecret, db);
      if (!shopId) throw new HttpsError("failed-precondition", "Shop ID missing. Reconnect your Etsy account.");

      // Use provided IDs or fetch defaults
      let finalShippingProfileId = shippingProfileId;
      let finalReturnPolicyId = returnPolicyId;

      if (!finalShippingProfileId) {
        finalShippingProfileId = await fetchFirstShippingProfileId(shopId, accessToken, clientId);
      }
      if (!finalReturnPolicyId) {
        finalReturnPolicyId = await fetchFirstReturnPolicyId(shopId, accessToken, clientId);
      }

      if (!finalShippingProfileId) {
        throw new HttpsError(
          "failed-precondition",
          "etsy_missing_shipping_profile: Add a shipping profile in your Etsy shop settings before listing."
        );
      }
      if (!finalReturnPolicyId) {
        throw new HttpsError(
          "failed-precondition",
          "etsy_missing_return_policy: Add a return policy in your Etsy shop settings before listing."
        );
      }

      const title = (listing.customTitle || product.title || "").slice(0, 140);
      const description = listing.customDescription || product.description || "";

      // Resolve taxonomy_id from category
      let taxonomy_id = taxonomyId;
      let when_made, who_made;
      if (!taxonomy_id) {
        const categoryToResolve = listing.category || product.category || product.artistName;
        const resolved = await resolveEtsyFields(clientId, title, categoryToResolve);
        taxonomy_id = resolved.taxonomy_id;
        when_made = resolved.when_made;
        who_made = resolved.who_made;
      } else {
        when_made = "2020_2024";
        who_made = "someone_else";
      }

      const rawPrice = typeof product.listingPrice === "number" ? product.listingPrice : (listing.price ?? 0);
      const priceAmount = Math.max(0.20, Math.round(rawPrice * 100) / 100);
      const quantity = typeof listing.quantity === "number" ? listing.quantity : (typeof product.quantity === "number" ? product.quantity : 1);

      const createBody = {
        quantity: quantity,
        title: title || "Product",
        description: description || title || "Product description",
        price: priceAmount,
        who_made,
        when_made,
        taxonomy_id,
        state: "active",
        shipping_profile_id: finalShippingProfileId,
        return_policy_id: finalReturnPolicyId,
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
      const photoPaths = (listing.photoPaths && listing.photoPaths.length > 0)
        ? listing.photoPaths
        : (product.images || []);
      if (photoPaths.length > 0) {
        await uploadListingImages(shopId, etsyListingId, photoPaths, accessToken, clientId);
      }

      // Check variations and update listing inventory
      const variations = (listing.variations && listing.variations.length > 0)
        ? listing.variations
        : (product.variants || []);
      if (variations.length > 1) {
        console.log(`[etsyCreateListing] Updating inventory for ${variations.length} variations on listing ${etsyListingId}`);
        try {
          const invPayload = buildEtsyInventoryPayload(variations, priceAmount);
          const invRes = await etsyPut(
            `/v3/application/listings/${etsyListingId}/inventory`,
            invPayload,
            accessToken,
            clientId
          );
          console.log(`[etsyCreateListing] Inventory update status: ${invRes.statusCode}`);
        } catch (invErr) {
          console.warn(`[etsyCreateListing] Failed to update inventory variations:`, invErr.message);
        }
      }

      await Promise.all([
        listingRef.set({
          crossPostStatus: { etsy: "posted" },
          crossPostListingIds: { etsy: etsyListingId },
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true }),
        productRef.set({
          etsyStatus: "active",
          "crossPostStatus.etsy": "active",
          "crossPostListingIds.etsy": etsyListingId,
          etsyListingId: etsyListingId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true })
      ]);

      return { success: true, listingId: etsyListingId };
    } catch (err) {
      console.error(
        `[etsyCreateListing] failed for listing ${listingId}:`,
        err instanceof HttpsError ? `${err.code}: ${err.message}` : (err && err.stack ? err.stack : err)
      );
      await listingRef.set({ crossPostStatus: { etsy: "failed" } }, { merge: true });
      if (err instanceof HttpsError) throw err;
      throw new HttpsError("internal", `Etsy listing failed: ${err.message}`);
    }
  }
);

/**
 * etsyUpdateListing — syncs title, description, price, and inventory to an existing Etsy listing.
 */
exports.etsyUpdateListing = onCall(
  { timeoutSeconds: 60 },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const uid = request.auth.uid;
    const { listingId: rawListingId, productId, credentialSet = "ios" } = request.data || {};
    const listingId = rawListingId || productId;
    if (!listingId) throw new HttpsError("invalid-argument", "listingId is required.");

    const db = admin.firestore();
    const credentials = await getEtsyCredentials(credentialSet);
    const { clientId, sharedSecret } = credentials;

    const [listingDoc, productDoc] = await Promise.all([
      db.collection("listings").doc(listingId).get(),
      db.collection("products").doc(listingId).get()
    ]);

    if (!listingDoc.exists && !productDoc.exists) throw new HttpsError("not-found", "Listing not found.");
    const listing = listingDoc.exists ? listingDoc.data() : {};
    const product = productDoc.exists ? productDoc.data() : {};

    if (listing.userId && listing.userId !== uid && product.userId && product.userId !== uid) {
      throw new HttpsError("permission-denied", "Not your listing.");
    }

    const etsyId = listing.crossPostListingIds?.etsy || product.etsyListingId || product.crossPostListingIds?.etsy;
    if (!etsyId) throw new HttpsError("failed-precondition", "No Etsy listing ID on record.");

    const { accessToken, shopId } = await getActiveEtsyToken(uid, clientId, sharedSecret, db);

    const title = (listing.customTitle || product.title || "").slice(0, 140);
    const description = listing.customDescription || product.description || "";
    const rawPrice = typeof product.listingPrice === "number" ? product.listingPrice : (listing.price ?? 0);
    const priceAmount = Math.max(0.20, Math.round(rawPrice * 100) / 100);
    const quantity = typeof listing.quantity === "number" ? listing.quantity : (typeof product.quantity === "number" ? product.quantity : 1);

    const { statusCode, data } = await etsyPatch(
      `/v3/application/shops/${shopId}/listings/${etsyId}`,
      {
        title,
        description,
        price: priceAmount,
        quantity,
      },
      accessToken, clientId
    );

    if (statusCode === 404) {
      await Promise.all([
        db.collection("listings").doc(listingId).set({ crossPostStatus: { etsy: "deleted" } }, { merge: true }),
        db.collection("products").doc(listingId).set({ etsyStatus: "deleted", "crossPostStatus.etsy": "deleted" }, { merge: true })
      ]);
      throw new HttpsError("not-found", "Etsy listing not found — it may have been deleted.");
    }
    if (statusCode !== 200) {
      throw new HttpsError("internal", `Etsy update failed (${statusCode}): ${JSON.stringify(data)}`);
    }

    // If variations exist, update inventory
    const variations = (listing.variations && listing.variations.length > 0)
      ? listing.variations
      : (product.variants || []);
    if (variations.length > 1) {
      try {
        const invPayload = buildEtsyInventoryPayload(variations, priceAmount);
        await etsyPut(
          `/v3/application/listings/${etsyId}/inventory`,
          invPayload,
          accessToken,
          clientId
        );
      } catch (invErr) {
        console.warn(`[etsyUpdateListing] Failed to update inventory variations:`, invErr.message);
      }
    }

    await Promise.all([
      db.collection("listings").doc(listingId).set({ updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true }),
      db.collection("products").doc(listingId).set({ updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true })
    ]);

    return { success: true };
  }
);

/**
 * Callable Function: etsyPullSync
 * Fetches live Etsy listing data (price, quantity, title, status) and returns diff with Wonni data.
 * Expects: { listingId: string, credentialSet?: "ios" | "web" }
 */
exports.etsyPullSync = onCall(
  { memory: "512MiB", timeoutSeconds: 60 },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const uid = request.auth.uid;
    const { listingId: rawListingId, productId, credentialSet = "ios" } = request.data || {};
    const listingId = rawListingId || productId;
    if (!listingId) {
      throw new HttpsError("invalid-argument", "listingId is required.");
    }

    const db = admin.firestore();
    const credentials = await getEtsyCredentials(credentialSet);
    const { clientId, sharedSecret } = credentials;

    const [listingDoc, productDoc] = await Promise.all([
      db.collection("listings").doc(listingId).get(),
      db.collection("products").doc(listingId).get()
    ]);

    const listing = listingDoc.exists ? listingDoc.data() : {};
    const product = productDoc.exists ? productDoc.data() : {};

    if (listing.userId && listing.userId !== uid && product.userId && product.userId !== uid) {
      throw new HttpsError("permission-denied", "Not your listing.");
    }

    const etsyListingId = listing.crossPostListingIds?.etsy || product.etsyListingId || product.crossPostListingIds?.etsy;
    if (!etsyListingId) {
      throw new HttpsError("not-found", "No Etsy listing ID on record.");
    }

    const { accessToken } = await getActiveEtsyToken(uid, clientId, sharedSecret, db);

    const { statusCode, data: etsyItem } = await etsyGet(
      `/v3/application/listings/${etsyListingId}`,
      accessToken,
      clientId
    );

    if (statusCode !== 200) {
      throw new HttpsError("not-found", `Etsy listing ${etsyListingId} not found (${statusCode}).`);
    }

    const etsyTitle = etsyItem.title || null;
    const etsyPrice = etsyItem.price ? (etsyItem.price.amount / etsyItem.price.divisor) : null;
    const etsyQuantity = typeof etsyItem.quantity === "number" ? etsyItem.quantity : null;
    const etsyStatus = etsyItem.state === "active" ? "active" : (etsyItem.state ? etsyItem.state.toLowerCase() : "active");

    const wonniTitle = listing.customTitle || product.title || "";
    const wonniPrice = typeof product.listingPrice === "number" ? product.listingPrice : (typeof listing.price === "number" ? listing.price : 0.0);
    const wonniQty = typeof listing.quantity === "number" ? listing.quantity : (typeof product.quantity === "number" ? product.quantity : 1);

    const diff = [];
    if (etsyTitle && etsyTitle.trim() && etsyTitle.trim() !== wonniTitle.trim()) {
      diff.push({ field: "Title", wonni: wonniTitle, external: etsyTitle, key: "title", value: etsyTitle });
    }
    if (etsyPrice != null && Math.abs(etsyPrice - wonniPrice) >= 0.01) {
      diff.push({ field: "Price", wonni: `$${wonniPrice.toFixed(2)}`, external: `$${etsyPrice.toFixed(2)}`, key: "price", value: etsyPrice });
    }
    if (etsyQuantity != null && etsyQuantity !== wonniQty) {
      diff.push({ field: "Quantity", wonni: String(wonniQty), external: String(etsyQuantity), key: "quantity", value: etsyQuantity });
    }

    return {
      hasDrift: diff.length > 0,
      diff,
      etsyData: {
        title: etsyTitle,
        price: etsyPrice,
        quantity: etsyQuantity,
        status: etsyStatus,
        listingId: String(etsyListingId)
      },
      wonniData: {
        title: wonniTitle,
        price: wonniPrice,
        quantity: wonniQty,
        status: listing.crossPostStatus?.etsy || product.etsyStatus || "active"
      }
    };
  }
);

/**
 * Callable Function: etsyImportPullSync
 * Applies selected external Etsy fields to Wonni Firestore documents.
 */
exports.etsyImportPullSync = onCall(
  { memory: "512MiB", timeoutSeconds: 30 },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const uid = request.auth.uid;
    const { listingId: rawListingId, productId, fields = {} } = request.data || {};
    const listingId = rawListingId || productId;
    if (!listingId) {
      throw new HttpsError("invalid-argument", "listingId is required.");
    }

    const db = admin.firestore();
    const productRef = db.collection("products").doc(listingId);
    const listingRef = db.collection("listings").doc(listingId);

    const updates = { updatedAt: admin.firestore.FieldValue.serverTimestamp() };
    const listingUpdates = { updatedAt: admin.firestore.FieldValue.serverTimestamp() };

    if (fields.title != null) {
      updates.title = fields.title;
      listingUpdates.customTitle = fields.title;
    }
    if (fields.price != null && typeof fields.price === "number") {
      updates.listingPrice = fields.price;
      listingUpdates.price = fields.price;
    }
    if (fields.quantity != null && typeof fields.quantity === "number") {
      updates.quantity = fields.quantity;
      listingUpdates.quantity = fields.quantity;
    }

    await Promise.all([
      productRef.set(updates, { merge: true }),
      listingRef.set(listingUpdates, { merge: true })
    ]);

    return { success: true };
  }
);

/**
 * etsyDeleteListing — deactivates (drafts) the Etsy listing.
 */
exports.etsyDeleteListing = onCall(
  { timeoutSeconds: 30 },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const uid = request.auth.uid;
    const { listingId, credentialSet = "ios" } = request.data;
    if (!listingId) throw new HttpsError("invalid-argument", "listingId is required.");

    const db = admin.firestore();
    const credentials = await getEtsyCredentials(credentialSet);
    const { clientId, sharedSecret } = credentials;

    const listingDoc = await db.collection("listings").doc(listingId).get();
    if (!listingDoc.exists) throw new HttpsError("not-found", "Listing not found.");
    const listing = listingDoc.data();
    if (listing.userId !== uid) throw new HttpsError("permission-denied", "Not your listing.");

    const etsyId = listing.crossPostListingIds?.etsy;
    if (!etsyId) return { success: true };

    const { accessToken, shopId } = await getActiveEtsyToken(uid, clientId, sharedSecret, db);

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

// Export helpers for UI preview callables
exports.matchEtsyTaxonomyId = matchEtsyTaxonomyId;
exports.getTaxonomyLeafNodes = getTaxonomyLeafNodes;

// ─────────────────────────────────────────────────────────────
// Shop setup helper callables (for UI)
// ─────────────────────────────────────────────────────────────

/**
 * getEtsyCategories — returns all Etsy taxonomy leaf categories for a searchable dropdown.
 */
exports.getEtsyCategories = onCall(
  { timeoutSeconds: 60 },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const { credentialSet = "ios" } = request.data || {};

    try {
      const credentials = await getEtsyCredentials(credentialSet);
      const categories = await getTaxonomyLeafNodes(credentials.clientId);
      return { categories };
    } catch (err) {
      console.error("[getEtsyCategories] Error:", err.message);
      if (err instanceof HttpsError) throw err;
      throw new HttpsError("internal", `Failed to fetch Etsy categories: ${err.message}`);
    }
  }
);

/**
 * suggestEtsyCategory — matches a product title + category against Etsy taxonomy
 * and returns the best matching taxonomy node (preview only, no writes).
 */
exports.suggestEtsyCategory = onCall(
  { timeoutSeconds: 60 },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const { title, category, credentialSet = "ios" } = request.data || {};

    try {
      const credentials = await getEtsyCredentials(credentialSet);
      const nodes = await getTaxonomyLeafNodes(credentials.clientId);
      const taxonomyId = matchEtsyTaxonomyId(nodes, title, category);
      const taxonomyNode = nodes.find((n) => n.id === taxonomyId);
      return {
        taxonomyId,
        taxonomyName: taxonomyNode?.name || "Other",
      };
    } catch (err) {
      console.error("[suggestEtsyCategory] Error:", err.message);
      if (err instanceof HttpsError) throw err;
      throw new HttpsError("internal", `Failed to suggest Etsy category: ${err.message}`);
    }
  }
);

/**
 * getEtsyShippingProfiles — lists the user's existing Etsy shipping profiles.
 */
exports.getEtsyShippingProfiles = onCall(
  { timeoutSeconds: 60 },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const uid = request.auth.uid;
    const { credentialSet = "ios" } = request.data || {};

    try {
      const credentials = await getEtsyCredentials(credentialSet);
      const db = admin.firestore();
      const { accessToken, shopId } = await getActiveEtsyToken(uid, credentials.clientId, credentials.sharedSecret, db);

      if (!shopId) throw new HttpsError("failed-precondition", "Shop ID not found.");

      const { statusCode, data } = await etsyGet(
        `/v3/application/shops/${shopId}/shipping-profiles`,
        accessToken,
        credentials.clientId
      );

      if (statusCode !== 200) {
        throw new Error(`Failed to fetch shipping profiles (${statusCode})`);
      }

      const profiles = (data.results || []).map((p) => ({
        id: p.shipping_profile_id,
        title: p.title,
      }));

      return { profiles };
    } catch (err) {
      console.error("[getEtsyShippingProfiles] Error:", err.message);
      if (err instanceof HttpsError) throw err;
      throw new HttpsError("internal", `Failed to fetch shipping profiles: ${err.message}`);
    }
  }
);

/**
 * getEtsyReturnPolicies — lists the user's existing Etsy return policies.
 */
exports.getEtsyReturnPolicies = onCall(
  { timeoutSeconds: 60 },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const uid = request.auth.uid;
    const { credentialSet = "ios" } = request.data || {};

    try {
      const credentials = await getEtsyCredentials(credentialSet);
      const db = admin.firestore();
      const { accessToken, shopId } = await getActiveEtsyToken(uid, credentials.clientId, credentials.sharedSecret, db);

      if (!shopId) throw new HttpsError("failed-precondition", "Shop ID not found.");

      const { statusCode, data } = await etsyGet(
        `/v3/application/shops/${shopId}/return-policies`,
        accessToken,
        credentials.clientId
      );

      if (statusCode !== 200) {
        throw new Error(`Failed to fetch return policies (${statusCode})`);
      }

      const policies = (data.results || []).map((p) => ({
        id: p.return_policy_id,
        name: `${p.accepts_returns ? "Accepts" : "No"} returns / ${p.accepts_exchanges ? "Accepts" : "No"} exchanges`,
      }));

      return { policies };
    } catch (err) {
      console.error("[getEtsyReturnPolicies] Error:", err.message);
      if (err instanceof HttpsError) throw err;
      throw new HttpsError("internal", `Failed to fetch return policies: ${err.message}`);
    }
  }
);
