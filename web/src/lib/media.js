// Shared image-array helpers used by both ProductDetail's page-local media
// editing and the app-wide background media job queue (mediaJobQueue.jsx) —
// kept here (rather than in ProductDetail.jsx) so the queue module can import
// them without a circular import.

export function normalizeImageAssets(product) {
  if (!product) return [];
  if (Array.isArray(product.imageAssets) && product.imageAssets.length) {
    return product.imageAssets
      .filter(Boolean)
      .map((image, index) => {
        const url = typeof image === "string" ? image : image?.url ?? "";
        return {
          id: (typeof image === "object" && image?.id) ? image.id : `${url || "img"}-${index}`,
          url: url || "",
          sourceUrl: (typeof image === "object" && image?.sourceUrl) ? image.sourceUrl : url || "",
          width: typeof image === "object" ? image?.width ?? null : null,
          height: typeof image === "object" ? image?.height ?? null : null,
          kind: typeof image === "object" ? image?.kind ?? "catalog" : "catalog",
          variantTags: (typeof image === "object" && Array.isArray(image?.variantTags)) ? image.variantTags : [],
        };
      })
      .filter((img) => img.url);
  }
  return (product.images ?? [])
    .filter((url) => typeof url === "string" && url)
    .map((url, index) => ({
      id: `${url}-${index}`, url, sourceUrl: url, width: null, height: null, kind: "catalog",
      variantTags: [],
    }));
}

// Normalizes an in-memory images array into the shape persisted to Firestore
// (images/imageAssets/listingImages all derive from this).
export function buildImagePayload(images) {
  return images.map((image, index) => ({
    id: image.id ?? `${image.url}-${index}`,
    url: image.url,
    sourceUrl: image.sourceUrl ?? image.url,
    width: image.width ?? null,
    height: image.height ?? null,
    kind: image.kind ?? "catalog",
    variantTags: Array.isArray(image.variantTags) ? image.variantTags : [],
  }));
}
