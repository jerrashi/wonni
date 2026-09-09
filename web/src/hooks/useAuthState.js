import { useState, useEffect } from "react";
import { onIdTokenChanged } from "firebase/auth";
import { auth } from "../firebase";

const EXT_ID = import.meta.env.VITE_EXTENSION_ID;

function sendToExtension(msg) {
  if (!EXT_ID || typeof chrome === "undefined" || !chrome.runtime?.sendMessage) return;
  chrome.runtime.sendMessage(EXT_ID, msg).catch(() => {});
}

export function useAuthState() {
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (typeof window !== "undefined") {
      sendToExtension({ type: "SET_DASHBOARD_URL", dashboardBaseUrl: window.location.origin });
    }
    const unsub = onIdTokenChanged(auth, async (u) => {
      setUser(u);
      setLoading(false);
      if (u) {
        sendToExtension({ type: "SET_DASHBOARD_URL", dashboardBaseUrl: window.location.origin });
        const idToken = await u.getIdToken();
        sendToExtension({ type: "SET_TOKEN", idToken, email: u.email });
      }
    });
    return unsub;
  }, []);

  return { user, loading };
}
