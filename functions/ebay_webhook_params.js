// Params shared by ebay_webhook.js and ebay_auth.js (kept apart so neither has to
// require the other at load time).
const { defineSecret, defineString } = require("firebase-functions/params");

// The same random string entered in developer.ebay.com > Alerts & Notifications.
// Never change it after the endpoint is registered.
const EBAY_VERIFICATION_TOKEN = defineSecret("EBAY_VERIFICATION_TOKEN");

// Must equal, byte for byte, the URL registered with eBay (the challenge hash
// includes it, and the proxy rewrites Host, so it cannot be read off the request).
const EBAY_WEBHOOK_URL = defineString("EBAY_WEBHOOK_URL", {
  default: "https://us-central1-wonni-app.cloudfunctions.net/ebayWebhook",
});

module.exports = { EBAY_VERIFICATION_TOKEN, EBAY_WEBHOOK_URL };
