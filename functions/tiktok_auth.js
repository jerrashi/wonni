const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const { tokenUrl, parseTokenResponse, createTiktokClient } = require("./tiktok_client");

const TT_APP_KEY = defineSecret("TIKTOK_APP_KEY");
const TT_APP_SECRET = defineSecret("TIKTOK_APP_SECRET");

/** The signed-in user's TikTok Shop client (token refresh + shop cipher handled). */
function tiktokClientFor(uid, { db = admin.firestore(), fetchImpl } = {}) {
  return createTiktokClient({
    db, uid, appKey: TT_APP_KEY.value(), appSecret: TT_APP_SECRET.value(),
    ...(fetchImpl ? { fetchImpl } : {}),
  });
}

/**
 * Code → tokens → users/{uid}/integrations/tiktok, then the shop cipher.
 * The token endpoint does not return the shop; `/authorization/202309/shops`
 * does, and every shop-scoped call needs its cipher. A shop lookup failure
 * leaves the connection saved (the client retries the lookup on first use).
 */
async function exchangeTiktokCode(db, uid, code, { appKey, appSecret, fetchImpl = fetch, now = Date.now }) {
  const res = await fetchImpl(tokenUrl("get", { appKey, appSecret, code }), { method: "GET" });
  let parsed;
  try { parsed = JSON.parse(await res.text()); } catch { parsed = null; }
  const t = parseTokenResponse(parsed, now());

  const ref = db.doc(`users/${uid}/integrations/tiktok`);
  await ref.set({
    platform: "tiktok",
    isConnected: true,
    connectedUsername: t.sellerName ?? t.openId ?? "",
    connectedAt: admin.firestore.FieldValue.serverTimestamp(),
    accessToken: t.accessToken,
    refreshToken: t.refreshToken,
    tokenExpiresAt: t.tokenExpiresAt,
    refreshTokenExpiresAt: t.refreshTokenExpiresAt,
    openId: t.openId,
    // A reconnect may be a different shop: drop the old cipher so it is re-read.
    shopId: admin.firestore.FieldValue.delete(),
    shopCipher: admin.firestore.FieldValue.delete(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  let shopName = null;
  try {
    const client = createTiktokClient({ db, uid, appKey, appSecret, fetchImpl, now });
    await client.shopCipher();
    shopName = (await ref.get()).data()?.shopName ?? null;
  } catch (e) {
    console.error(`[tiktokExchangeToken] shop lookup failed uid=${uid}: ${e.message}`);
  }
  return { success: true, shopName };
}

exports.tiktokExchangeToken = onCall(
  { secrets: [TT_APP_KEY, TT_APP_SECRET] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { code, state } = request.data;
    if (!code) throw new HttpsError("invalid-argument", "Missing code.");

    const db = admin.firestore();
    const stateRef = db.doc(`users/${uid}/oauthStates/tiktok`);
    const stored = (await stateRef.get()).data();
    if (!stored?.nonce || stored.nonce !== state) {
      throw new HttpsError("invalid-argument", "Invalid OAuth state.");
    }
    await stateRef.delete();
    if (Date.now() - stored.createdAt.toMillis() > 10 * 60 * 1000) {
      throw new HttpsError("deadline-exceeded", "OAuth state expired.");
    }

    return exchangeTiktokCode(db, uid, code, { appKey: TT_APP_KEY.value(), appSecret: TT_APP_SECRET.value() });
  }
);

module.exports = {
  tiktokExchangeToken: exports.tiktokExchangeToken,
  tiktokClientFor,
  TT_APP_KEY,
  TT_APP_SECRET,
  _internal: { exchangeTiktokCode },
};
