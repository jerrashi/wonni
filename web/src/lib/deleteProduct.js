import { doc, deleteDoc } from "firebase/firestore";
import { db } from "../firebase";

// Wonni is the master listing (see CLAUDE.md's eBay listing lifecycle
// section): deleting it here means "stop selling this item everywhere," not
// "delete just the Wonni record" — leaving eBay/Etsy live would just get
// Wonni silently re-created the next time any platform is posted (postToWonni
// always posts to Wonni first). Shared by the single-product delete
// (ProductDetail) and the bulk delete (Dashboard select-mode toolbar).
const DELETE_FNS = { ebay: "ebayDeleteListing", etsy: "etsyDeleteListing", tiktok: "tiktokDeleteListing" };
const PLATFORM_NAMES = { ebay: "eBay", etsy: "Etsy", tiktok: "TikTok Shop" };

export function liveApiPlatforms(product) {
  return [
    (product?.ebayStatus === "active" || product?.crossPostStatus?.ebay === "active" || product?.crossPostStatus?.ebay === "posted") ? "ebay" : null,
    (product?.etsyStatus === "active" || product?.crossPostStatus?.etsy === "active" || product?.crossPostStatus?.etsy === "posted") ? "etsy" : null,
    product?.tiktokStatus === "active" ? "tiktok" : null,
  ].filter(Boolean);
}

export function isLiveOnMercari(product) {
  return product?.crossPostStatus?.mercari === "active" || !!product?.crossPostListingIds?.mercari || !!product?.mercariListingId
    || (product?.variants ?? []).some((v) => v?.crossPostListingIds?.mercari || v?.mercariListingId);
}

export function platformNoteFor(product) {
  const platforms = liveApiPlatforms(product);
  const onMercari = isLiveOnMercari(product);
  if (!platforms.length && !onMercari) return "";
  const names = [...platforms.map((p) => PLATFORM_NAMES[p]), onMercari ? "Mercari" : null].filter(Boolean);
  return ` This will also remove it from ${names.join(", ")}.`;
}

// Deletes eBay/Etsy/TikTok listings for one product (Mercari has no delete
// API — callers must warn + confirm separately before calling this), then
// the Firestore doc itself. Does not delete the doc if any platform delete
// fails, so a retry can pick up where it left off.
export async function deleteProductEverywhere(product, callFunction) {
  const productId = product.id;
  const platforms = liveApiPlatforms(product);
  const results = await Promise.allSettled(
    platforms.map((p) => callFunction(DELETE_FNS[p])({ productId }))
  );
  const failed = platforms.filter((_, i) => results[i].status === "rejected");
  if (failed.length) {
    return {
      ok: false,
      error: `Couldn't remove "${product?.title ?? productId}" from ${failed.map((p) => PLATFORM_NAMES[p]).join(", ")} — delete it there manually, then try again.`,
    };
  }
  await deleteDoc(doc(db, "products", productId));
  return { ok: true };
}
