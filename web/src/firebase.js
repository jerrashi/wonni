import { initializeApp } from "firebase/app";
import { getAuth, GoogleAuthProvider, connectAuthEmulator } from "firebase/auth";
import { getFirestore, connectFirestoreEmulator } from "firebase/firestore";
import { getFunctions, httpsCallable, connectFunctionsEmulator } from "firebase/functions";
import { getStorage, ref, uploadBytes, getDownloadURL, connectStorageEmulator } from "firebase/storage";

const firebaseConfig = {
  apiKey: "AIzaSyB7QQahI-DxHsDE7OKaxtXfdQucr1sSxfU",
  authDomain: "wonni-dropship.firebaseapp.com",
  projectId: "wonni-dropship",
  storageBucket: "wonni-dropship.firebasestorage.app",
  messagingSenderId: "431608790074",
  appId: "1:431608790074:web:3672d25c487400ba034903",
  measurementId: "G-1X5GTPE27C"
};

const app = initializeApp(firebaseConfig);

export const auth = getAuth(app);
export const db = getFirestore(app);
export const functions = getFunctions(app);
export const storage = getStorage(app);
export const googleProvider = new GoogleAuthProvider();


// Local testing: VITE_USE_EMULATORS=1 npm run dev
if (import.meta.env.VITE_USE_EMULATORS === "1") {
  connectAuthEmulator(auth, "http://127.0.0.1:9099", { disableWarnings: true });
  connectFirestoreEmulator(db, "127.0.0.1", 8080);
  connectFunctionsEmulator(functions, "127.0.0.1", 5001);
  connectStorageEmulator(storage, "127.0.0.1", 9199);
}

export const callFunction = (name) => httpsCallable(functions, name);

// Upload a canvas Blob to Firebase Storage and return the public download URL.
export async function uploadImageBlob(uid, productId, blob, suffix = "") {
  const ext = blob.type === "image/png" ? "png" : "jpg";
  const ts = Date.now();
  const path = `dropship/${uid}/edits/${productId}/${ts}${suffix}.${ext}`;
  const fileRef = ref(storage, path);
  await uploadBytes(fileRef, blob, { contentType: blob.type });
  return getDownloadURL(fileRef);
}

// Upload a File or Blob directly for a new photo draft and return the public URL.
export async function uploadFileToStorage(uid, draftId, fileOrBlob, filename = "photo") {
  const type = fileOrBlob.type || "image/jpeg";
  const ext = type.includes("png") ? "png" : "jpg";
  const ts = Date.now();
  const path = `dropship/${uid}/drafts/${draftId}/${ts}-${filename}.${ext}`;
  const fileRef = ref(storage, path);
  await uploadBytes(fileRef, fileOrBlob, { contentType: type });
  return getDownloadURL(fileRef);
}
