import { initializeApp } from "firebase/app";
import { getAuth, GoogleAuthProvider, connectAuthEmulator } from "firebase/auth";
import { getFirestore, connectFirestoreEmulator } from "firebase/firestore";
import { getFunctions, httpsCallable, connectFunctionsEmulator } from "firebase/functions";

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
export const googleProvider = new GoogleAuthProvider();

// Local testing: VITE_USE_EMULATORS=1 npm run dev
if (import.meta.env.VITE_USE_EMULATORS === "1") {
  connectAuthEmulator(auth, "http://127.0.0.1:9099", { disableWarnings: true });
  connectFirestoreEmulator(db, "127.0.0.1", 8080);
  connectFunctionsEmulator(functions, "127.0.0.1", 5001);
}

export const callFunction = (name) => httpsCallable(functions, name);
