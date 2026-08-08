const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { publicStorageUrl } = require("./product_media");

// Client-side Firebase Storage uploads (uploadBytes via the web SDK) land as
// private objects, only reachable via a signed firebasestorage.googleapis.com
// download-token URL — a different host than every server-side upload (AliExpress/
// Weverse import, image split) already uses. The Mercari cross-post extension's
// background service worker can only bypass CORS for storage.googleapis.com (per
// manifest host_permissions), so a firebasestorage.googleapis.com image silently
// fails to fetch and gets dropped from the listing. This flips a just-uploaded
// object to public and returns its canonical storage.googleapis.com URL, so every
// image URL in the app — client or server uploaded — uses the same format.
exports.publishStorageObject = onCall(
  { timeoutSeconds: 30 },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { path } = request.data ?? {};
    if (!path || typeof path !== "string") throw new HttpsError("invalid-argument", "Missing path.");
    // Only allow publishing objects under this user's own upload namespace.
    if (!path.startsWith(`dropship/${uid}/`)) {
      throw new HttpsError("permission-denied", "Not your upload path.");
    }

    const bucket = admin.storage().bucket();
    const file = bucket.file(path);
    const [exists] = await file.exists();
    if (!exists) throw new HttpsError("not-found", "Uploaded file not found.");

    await file.makePublic();
    return { url: publicStorageUrl(bucket.name, path) };
  }
);
