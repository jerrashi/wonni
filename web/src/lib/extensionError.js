// Chrome's raw message when the Wonni extension isn't answering ("Could not
// establish connection. Receiving end does not exist.") means nothing to a
// seller. Seen 2026-11-24: the web build carried an old extension ID after the
// extension was loaded from a new folder (unpacked IDs come from the path).
export function extensionError(lastError) {
  const msg = lastError?.message ?? String(lastError ?? "");
  if (/receiving end does not exist|could not establish connection/i.test(msg)) {
    return new Error("The Wonni extension didn't answer. Check it's installed and turned on in chrome://extensions, then reload this page.");
  }
  return new Error(msg);
}
