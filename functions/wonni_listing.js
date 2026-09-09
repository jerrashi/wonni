/**
 * wonni_listing.js — postToWonni
 *
 * Ported verbatim from the (now-deleted) nested tree, plus the roadmap's
 * "skip when a live Wonni listing already exists" guard.
 *
 * The explicit "Post to Wonni" action — the ONLY path that creates/updates a
 * `listings/{productId}` doc. `listings/` is the Wonni **marketplace** feed
 * (iOS `UserListing` shape); every query there treats a doc as real & for-sale
 * (no in-collection draft state), so a product is written there only on the
 * user's explicit choice, `status: "active"` from the start — mirroring the
 * iOS publish flow. `products/{id}` stays the one and only draft store.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const { validated } = require("./contracts");
const { toListingFields } = require("./listing_shape");

/** Cross-post status/ids to mirror from the product onto the marketplace listing. */
function buildWonniCrossPost(product) {
  const crossPostStatus = {};
  const crossPostListingIds = {};
  if (product.ebayStatus) crossPostStatus.ebay = product.ebayStatus;
  if (product.ebayListingId) crossPostListingIds.ebay = product.ebayListingId;
  if (product.tiktokStatus) crossPostStatus.tiktok = product.tiktokStatus;
  if (product.tiktokProductId) crossPostListingIds.tiktok = product.tiktokProductId;
  if (product.listingStatus?.mercari) crossPostStatus.mercari = product.listingStatus.mercari;
  if (product.listingId?.mercari) crossPostListingIds.mercari = product.listingId.mercari;
  if (product.listingUrl?.mercari) crossPostListingIds.mercariUrl = product.listingUrl.mercari;
  return { crossPostStatus, crossPostListingIds };
}

/** The `products/{id}` patch that marks a product as published-to-Wonni. */
function wonniPublishedProductPatch(productId) {
  return {
    crossPostStatus: { wonni: "active" },
    crossPostListingIds: { wonni: productId },
    // "graduate a draft" signal both clients key off of.
    isDraft: false,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

exports.postToWonni = onCall(
  { timeoutSeconds: 30 },
  validated("postToWonni", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const db = admin.firestore();
    const productRef = db.collection("products").doc(data.productId);
    const productSnap = await productRef.get();
    if (!productSnap.exists) throw new HttpsError("not-found", "Product not found.");
    const product = productSnap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    if (!(Number(product.listingPrice) > 0)) {
      throw new HttpsError("failed-precondition", "Set a listing price before posting.");
    }

    const listingRef = db.collection("listings").doc(data.productId);
    const listingSnap = await listingRef.get();

    // Guard: a live marketplace listing already exists — don't re-map / clobber
    // it (it may carry marketplace-side edits). Just make sure the product's
    // published flags are set, and return.
    if (listingSnap.exists && listingSnap.data().status === "active") {
      await productRef.set(wonniPublishedProductPatch(data.productId), { merge: true });
      return { listingId: data.productId, alreadyPosted: true, skipped: true };
    }

    const alreadyPosted = listingSnap.exists;
    const existingPublishedAt = alreadyPosted ? listingSnap.data().publishedAt : null;
    const { crossPostStatus, crossPostListingIds } = buildWonniCrossPost(product);

    const listingFields = {
      userId: uid,
      ...toListingFields({
        title: product.title,
        description: product.description ?? "",
        price: product.listingPrice,
        images: product.images,
        options: product.options,
        variants: product.variants,
        condition: product.condition,
        category: product.category,
        brand: product.brand,
        aiSuggestedTitle: product.aiSuggestedTitle,
        aiSuggestedDescription: product.aiSuggestedDescription,
        aiSuggestedPrice: product.aiSuggestedPrice,
        aiModel: product.aiModel,
        aiPromptVersion: product.aiPromptVersion,
        buyerPaysShipping: product.buyerPaysShipping,
        handlingFee: product.handlingFee,
        estimatedShippingDays: product.estimatedShippingDays,
        handlingTimeDays: product.handlingTimeDays,
        weightLbs: product.weightLbs,
        lengthIn: product.lengthIn,
        widthIn: product.widthIn,
        heightIn: product.heightIn,
        tags: product.tags,
        personalNote: product.personalNote,
      }),
      status: "active",
      ...(Object.keys(crossPostStatus).length ? { crossPostStatus } : {}),
      ...(Object.keys(crossPostListingIds).length ? { crossPostListingIds } : {}),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...(alreadyPosted ? {} : {
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        publishedAt: admin.firestore.FieldValue.serverTimestamp(),
      }),
      ...(alreadyPosted && !existingPublishedAt
        ? { publishedAt: admin.firestore.FieldValue.serverTimestamp() }
        : {}),
    };

    await listingRef.set(listingFields, { merge: true });
    await productRef.set(wonniPublishedProductPatch(data.productId), { merge: true });

    return { listingId: data.productId, alreadyPosted };
  }),
);

exports._internal = { buildWonniCrossPost, wonniPublishedProductPatch };
