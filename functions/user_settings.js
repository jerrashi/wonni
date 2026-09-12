const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const crypto = require("crypto");
const { validated } = require("./contracts");
const { validateSaleStages } = require("./sale_stages");

const OAUTH_STATE_TTL_MS = 10 * 60 * 1000; // 10 minutes

exports.generateOAuthState = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

  const { platform } = request.data;
  if (!["aliexpress", "tiktok", "ebay"].includes(platform)) {
    throw new HttpsError("invalid-argument", "Invalid platform.");
  }

  const nonce = crypto.randomBytes(32).toString("hex");
  await admin.firestore()
    .doc(`users/${uid}/oauthStates/${platform}`)
    .set({ nonce, createdAt: admin.firestore.FieldValue.serverTimestamp() });

  return { state: nonce };
});

exports.disconnectPlatform = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

  const { platform } = request.data;
  if (!["aliexpress", "tiktok", "ebay"].includes(platform)) {
    throw new HttpsError("invalid-argument", "Invalid platform.");
  }

  await admin.firestore().doc(`users/${uid}/integrations/${platform}`).set({
    isConnected: false,
    accessToken: admin.firestore.FieldValue.delete(),
    refreshToken: admin.firestore.FieldValue.delete(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  return { success: true };
});

exports.updateSettings = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

  const { tiktokFeeRate } = request.data;
  if (tiktokFeeRate === undefined) {
    throw new HttpsError("invalid-argument", "No settings provided.");
  }
  if (typeof tiktokFeeRate !== "number" || tiktokFeeRate < 0 || tiktokFeeRate > 1) {
    throw new HttpsError("invalid-argument", "tiktokFeeRate must be a number between 0 and 1.");
  }

  await admin.firestore().doc(`users/${uid}`).set({ tiktokFeeRate }, { merge: true });
  return { success: true };
});

/**
 * Replace the user's sale-stage board/dropdown bucket list wholesale — the
 * settings-page control for the kanban feature (add/rename/reorder/delete
 * custom buckets, rename built-in labels). See sale_stages.js for the
 * built-in-keys-are-permanent rule this enforces.
 */
exports.updateSaleStages = onCall(validated("updateSaleStages", async (data, request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

  try {
    validateSaleStages(data.stages);
  } catch (e) {
    throw new HttpsError("invalid-argument", e.message);
  }

  await admin.firestore().doc(`users/${uid}`).set({
    saleStages: data.stages,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  return { ok: true };
}));
