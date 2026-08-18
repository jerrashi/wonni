import { initializeApp } from "firebase/app";
import { getAuth, GoogleAuthProvider, OAuthProvider, connectAuthEmulator } from "firebase/auth";
import { getFirestore, connectFirestoreEmulator } from "firebase/firestore";
import { getFunctions, httpsCallable, connectFunctionsEmulator } from "firebase/functions";
import { getStorage, ref, uploadBytes, connectStorageEmulator } from "firebase/storage";

// Points at the shared wonni-app project (Phase B backend merge) — NOT
// wonni-dropship. Do not deploy/build against this until the rest of the
// cutover (data migration + merged functions/rules deploy) is done; see the
// integration plan's step 9. The old wonni-dropship config is kept below,
// commented out, for reference during the migration window.
const firebaseConfig = {
  apiKey: "AIzaSyCrroW6RXSl15a4j9FPeAUOqkiNCx3g2Lk",
  authDomain: "wonni-app.firebaseapp.com",
  projectId: "wonni-app",
  storageBucket: "wonni-app.firebasestorage.app",
  messagingSenderId: "840012373819",
  appId: "1:840012373819:web:c5081552e35940d578a11e",
};
// const firebaseConfig = {
//   apiKey: "AIzaSyB7QQahI-DxHsDE7OKaxtXfdQucr1sSxfU",
//   authDomain: "wonni-dropship.firebaseapp.com",
//   projectId: "wonni-dropship",
//   storageBucket: "wonni-dropship.firebasestorage.app",
//   messagingSenderId: "431608790074",
//   appId: "1:431608790074:web:3672d25c487400ba034903",
//   measurementId: "G-1X5GTPE27C"
// };

const app = initializeApp(firebaseConfig);

export const auth = getAuth(app);
export const db = getFirestore(app);
export const functions = getFunctions(app);
export const storage = getStorage(app);
export const googleProvider = new GoogleAuthProvider();
export const appleProvider = new OAuthProvider("apple.com");


// Local testing: VITE_USE_EMULATORS=1 npm run dev
if (import.meta.env.VITE_USE_EMULATORS === "1") {
  connectAuthEmulator(auth, "http://127.0.0.1:9099", { disableWarnings: true });
  connectFirestoreEmulator(db, "127.0.0.1", 8080);
  connectFunctionsEmulator(functions, "127.0.0.1", 5001);
  connectStorageEmulator(storage, "127.0.0.1", 9199);
}

export const callFunction = (name) => httpsCallable(functions, name);

// Upload a canvas Blob to Firebase Storage and return its public
// storage.googleapis.com URL — the same host every server-side (AliExpress/
// Weverse/split) upload uses, so the Mercari extension can fetch it too (its
// host_permissions CORS-bypass only covers storage.googleapis.com, not the
// signed-token firebasestorage.googleapis.com URL getDownloadURL() returns).
export async function uploadImageBlob(uid, productId, blob, suffix = "") {
  const ext = blob.type === "image/png" ? "png" : "jpg";
  const ts = Date.now();
  const path = `dropship/${uid}/edits/${productId}/${ts}${suffix}.${ext}`;
  const fileRef = ref(storage, path);
  await uploadBytes(fileRef, blob, { contentType: blob.type });
  const { data } = await callFunction("publishStorageObject")({ path });
  return data.url;
}

// Upload a File or Blob directly for a new photo draft and return its public
// storage.googleapis.com URL (see uploadImageBlob for why).
export async function uploadFileToStorage(uid, draftId, fileOrBlob, filename = "photo") {
  const type = fileOrBlob.type || "image/jpeg";
  const ext = type.includes("png") ? "png" : "jpg";
  const ts = Date.now();
  const path = `dropship/${uid}/drafts/${draftId}/${ts}-${filename}.${ext}`;
  const fileRef = ref(storage, path);
  await uploadBytes(fileRef, fileOrBlob, { contentType: type });
  const { data } = await callFunction("publishStorageObject")({ path });
  return data.url;
}
