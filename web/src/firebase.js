import { initializeApp } from "firebase/app";
import { getAuth, GoogleAuthProvider } from "firebase/auth";
import { getFirestore } from "firebase/firestore";
import { getFunctions, httpsCallable } from "firebase/functions";

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

export const callFunction = (name) => httpsCallable(functions, name);
