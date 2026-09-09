/**
 * One-time setup script — registers the eBay Commerce Notifications webhook.
 * Run as:
 *   EBAY_CLIENT_ID=... EBAY_CERT_ID=... EBAY_VERIFICATION_TOKEN=... node setup-ebay-notifications.js
 *
 * CLIENT_ID and CERT_ID are in your eBay Developer dashboard (developer.ebay.com/my/keys).
 * EBAY_VERIFICATION_TOKEN is the secret you stored in Firebase Secret Manager.
 */

const https = require("https");

const CLIENT_ID  = process.env.EBAY_CLIENT_ID;
const CERT_ID    = process.env.EBAY_CERT_ID;
const VERIFY_TOK = process.env.EBAY_VERIFICATION_TOKEN;
const WEBHOOK_URL = "https://ebaywebhook-dynv7fggca-uc.a.run.app";

if (!CLIENT_ID || !CERT_ID || !VERIFY_TOK) {
  console.error("Missing env vars. Run as:\n  EBAY_CLIENT_ID=... EBAY_CERT_ID=... EBAY_VERIFICATION_TOKEN=... node setup-ebay-notifications.js");
  process.exit(1);
}

function req(opts, body = null) {
  return new Promise((res, rej) => {
    const r = https.request(opts, resp => {
      let d = ""; resp.on("data", c => d += c); resp.on("end", () => res({ status: resp.statusCode, body: d }));
    });
    r.on("error", rej);
    if (body) r.write(body);
    r.end();
  });
}

async function main() {
  // 1. App-level token
  const creds = Buffer.from(`${CLIENT_ID}:${CERT_ID}`).toString("base64");
  const tokenBody = `grant_type=client_credentials&scope=${encodeURIComponent("https://api.ebay.com/oauth/api_scope")}`;
  const tokenRes = await req({ hostname: "api.ebay.com", path: "/identity/v1/oauth2/token", method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", "Authorization": `Basic ${creds}`, "Content-Length": Buffer.byteLength(tokenBody) }}, tokenBody);
  if (tokenRes.status !== 200) throw new Error(`Token failed: ${tokenRes.body}`);
  const token = JSON.parse(tokenRes.body).access_token;
  console.log("Got app token");

  // 2. Check existing destinations and subscriptions
  const existingDests = await req({ hostname: "api.ebay.com", path: "/commerce/notification/v1/destination", method: "GET",
    headers: { "Authorization": `Bearer ${token}` }});
  console.log("Existing destinations:", existingDests.status, existingDests.body);

  const existingSubs = await req({ hostname: "api.ebay.com", path: "/commerce/notification/v1/subscription", method: "GET",
    headers: { "Authorization": `Bearer ${token}` }});
  console.log("Existing subscriptions:", existingSubs.status, existingSubs.body);

  // 3. List all available topics
  const topicsRes = await req({ hostname: "api.ebay.com", path: "/commerce/notification/v1/topic", method: "GET",
    headers: { "Authorization": `Bearer ${token}` }});
  console.log("Available topics:", topicsRes.status, topicsRes.body);

  // Check if ORDER_COMPLETED subscription already exists
  let existingOrderSub = null;
  if (existingSubs.status === 200) {
    const subs = JSON.parse(existingSubs.body).subscriptions ?? [];
    existingOrderSub = subs.find(s => s.topicId === "MARKETPLACE_ORDER_COMPLETED");
  }
  if (existingOrderSub) {
    console.log("ORDER_COMPLETED subscription already exists:", JSON.stringify(existingOrderSub));
    return;
  }

  // 4. Use existing destination (already validated by eBay for ACCOUNT_DELETION delivery)
  let destId = null;
  if (existingDests.status === 200) {
    const dests = JSON.parse(existingDests.body).destinations ?? [];
    if (dests.length > 0) {
      destId = dests[0].destinationId;
      console.log("Reusing existing destination:", destId, dests[0].deliveryConfig?.endpoint ?? dests[0].deliveryConfig?.url);
    }
  }
  if (!destId) throw new Error("No existing destination found — create one manually in the eBay developer portal first.");

  // 5. Subscribe to MARKETPLACE_ORDER_COMPLETED
  const subBody = JSON.stringify({ destinationId: destId, status: "ENABLED", topicId: "MARKETPLACE_ORDER_COMPLETED", payload: { format: "JSON", schemaVersion: "1.0", deliveryProtocol: "HTTPS" } });
  const subRes = await req({ hostname: "api.ebay.com", path: "/commerce/notification/v1/subscription", method: "POST",
    headers: { "Authorization": `Bearer ${token}`, "Content-Type": "application/json", "Content-Length": Buffer.byteLength(subBody) }}, subBody);
  console.log("Subscription:", subRes.status, subRes.body);
}

main().catch(err => { console.error(err); process.exit(1); });
