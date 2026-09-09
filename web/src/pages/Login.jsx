import {
  signInWithPopup,
  linkWithCredential,
  fetchSignInMethodsForEmail,
  OAuthProvider,
  GoogleAuthProvider,
} from "firebase/auth";
import { useNavigate } from "react-router-dom";
import { auth, googleProvider, appleProvider } from "../firebase";
import { useAuthState } from "../hooks/useAuthState";
import { useEffect, useState } from "react";

// Maps a Firebase sign-in-method id back to the provider + human label needed
// to re-prompt the user and finish linking.
const PROVIDERS_BY_METHOD = {
  "google.com": { provider: googleProvider, label: "Google" },
  "apple.com": { provider: appleProvider, label: "Apple" },
};

export default function Login() {
  const navigate = useNavigate();
  const { user } = useAuthState();
  // Set when a sign-in hits an existing account under a different provider:
  // holds the credential we still need to link once the user re-authenticates
  // with the provider that account was originally created with.
  const [pendingLink, setPendingLink] = useState(null);

  useEffect(() => {
    if (user) navigate("/sell", { replace: true });
  }, [user, navigate]);

  async function signIn(provider) {
    try {
      await signInWithPopup(auth, provider);
    } catch (e) {
      if (e.code !== "auth/account-exists-with-different-credential") {
        console.error(e);
        return;
      }
      const pendingCredential =
        OAuthProvider.credentialFromError(e) || GoogleAuthProvider.credentialFromError(e);
      const email = e.customData?.email;
      const methods = email ? await fetchSignInMethodsForEmail(auth, email) : [];
      const existing = PROVIDERS_BY_METHOD[methods[0]];
      if (!pendingCredential || !existing) {
        console.error(e);
        return;
      }
      setPendingLink({ credential: pendingCredential, existing });
    }
  }

  async function finishLink() {
    try {
      const { user: signedInUser } = await signInWithPopup(auth, pendingLink.existing.provider);
      await linkWithCredential(signedInUser, pendingLink.credential);
      setPendingLink(null);
    } catch (e) {
      console.error(e);
    }
  }

  if (pendingLink) {
    return (
      <div className="login-page">
        <div className="login-card">
          <h1>Link accounts</h1>
          <p>
            You already have an account signed in with {pendingLink.existing.label}. Sign in with
            {" "}{pendingLink.existing.label} to link it.
          </p>
          <button className="btn-google" onClick={finishLink}>
            Continue with {pendingLink.existing.label}
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="login-page">
      <div className="login-card">
        <h1>Wonni Drop</h1>
        <p>Weverse Shop + AliExpress → draft listings, automated.</p>
        <button className="btn-google" onClick={() => signIn(googleProvider)}>
          <svg width="18" height="18" viewBox="0 0 18 18">
            <path fill="#4285F4" d="M17.64 9.2c0-.637-.057-1.251-.164-1.84H9v3.481h4.844c-.209 1.125-.843 2.078-1.796 2.717v2.258h2.908c1.702-1.567 2.684-3.874 2.684-6.615z"/>
            <path fill="#34A853" d="M9 18c2.43 0 4.467-.806 5.956-2.184l-2.908-2.258c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 0 0 9 18z"/>
            <path fill="#FBBC05" d="M3.964 10.707A5.41 5.41 0 0 1 3.682 9c0-.593.102-1.17.282-1.707V4.961H.957A8.996 8.996 0 0 0 0 9c0 1.452.348 2.827.957 4.039l3.007-2.332z"/>
            <path fill="#EA4335" d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 0 0 .957 4.961L3.964 7.293C4.672 5.163 6.656 3.58 9 3.58z"/>
          </svg>
          Continue with Google
        </button>
        <button className="btn-apple" onClick={() => signIn(appleProvider)}>
          <svg width="16" height="18" viewBox="0 0 16 18" fill="white">
            <path d="M13.03 9.55c-.02-2.02 1.65-2.99 1.72-3.03-.94-1.37-2.4-1.56-2.92-1.58-1.24-.13-2.43.73-3.06.73-.63 0-1.6-.71-2.64-.7-1.35.02-2.6.79-3.3 2-1.4 2.44-.36 6.05 1 8.03.67.97 1.46 2.05 2.5 2.01 1-.04 1.38-.65 2.6-.65 1.21 0 1.56.65 2.62.63 1.08-.02 1.77-.98 2.43-1.95.77-1.13 1.08-2.22 1.1-2.28-.02-.01-2.1-.81-2.05-3.21zM11.01 3.62c.55-.68.93-1.62.83-2.56-.8.03-1.77.54-2.34 1.2-.51.6-.96 1.56-.84 2.48.9.07 1.81-.46 2.35-1.12z"/>
          </svg>
          Continue with Apple
        </button>
      </div>
    </div>
  );
}
