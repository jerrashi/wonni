const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { toListingFields } = require("./listing_shape");

// Explicit "Post to Wonni" action — the only path that ever creates/updates a
// `listings/{productId}` doc. Unlike eBay/TikTok/Mercari (whose status lives
// only on the `products` doc), wonni-app's `listings` collection is treated
// by every query in the iOS app as "real, for-sale" — there's no in-collection
// draft state there (see firestore.rules there: "Drafts live only in
// SwiftData until publish"). So a dropship product must never be dual-written
// into `listings` automatically at import/edit time; it only happens here,
// on the user's explicit choice, exactly mirroring how the iOS app's own
// publish flow creates a listing already `status: "active"`.
exports.postToWonni = onCall(
  { timeoutSeconds: 30 },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId } = request.data ?? {};
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

    const db = admin.firestore();
    const productRef = db.collection("products").doc(productId);
    const productSnap = await productRef.get();
    if (!productSnap.exists) throw new HttpsError("not-found", "Product not found.");
    const product = productSnap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    const listingRef = db.collection("listings").doc(productId);
    const listingSnap = await listingRef.get();
    const alreadyPosted = listingSnap.exists;

    const crossPostStatus = {};
    const crossPostListingIds = {};
    if (product.ebayStatus) crossPostStatus.ebay = product.ebayStatus;
    if (product.ebayListingId) crossPostListingIds.ebay = product.ebayListingId;
    if (product.tiktokStatus) crossPostStatus.tiktok = product.tiktokStatus;
    if (product.tiktokProductId) crossPostListingIds.tiktok = product.tiktokProductId;
    if (product.listingStatus?.mercari) crossPostStatus.mercari = product.listingStatus.mercari;
    if (product.listingId?.mercari) crossPostListingIds.mercari = product.listingId.mercari;
    if (product.listingUrl?.mercari) crossPostListingIds.mercariUrl = product.listingUrl.mercari;

    const existingPublishedAt = alreadyPosted ? listingSnap.data().publishedAt : null;
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
      // If re-publishing a draft that was saved without publishedAt, set it now
      ...(alreadyPosted && !existingPublishedAt ? {
        publishedAt: admin.firestore.FieldValue.serverTimestamp(),
      } : {}),
    };

    await listingRef.set(listingFields, { merge: true });
    await productRef.update({
      "crossPostStatus.wonni": "active",
      "crossPostListingIds.wonni": productId,
      // Posting to Wonni is the "graduate a draft" signal both clients key
      // off of — see the isDraft field on `products` docs.
      isDraft: false,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { listingId: productId, alreadyPosted };
  }
);
