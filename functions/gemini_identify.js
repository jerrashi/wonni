// Secret name consumed by functions that run Gemini at various points
// (post-import "AI autofill", opt-in cross-post gap-fill, shipping estimate).
// Referenced in the `secrets` array of each onCall config that needs it.
const geminiApiKey = "GEMINI_API_KEY";

exports.geminiApiKey = geminiApiKey;

// `importTimeGeminiFields` (the automatic at-import Gemini call) was removed
// 2026-09-27 — dead code with zero remaining callers since AI enrichment
// became opt-in (see listing_fields.js resolveListingFields / the "AI
// autofill" button). This file now only exists to hold the shared
// `geminiApiKey` secret-name constant.
