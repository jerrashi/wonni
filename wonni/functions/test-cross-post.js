/**
 * test-cross-post.js
 *
 * Standalone testing script to verify Etsy v3 API integration.
 * Performs OAuth 2.0 PKCE token exchange, token refresh, and listing draft creation.
 * Does NOT modify any existing codebase files.
 *
 * Usage:
 *   1. Run OAuth setup first:
 *      node test-cross-post.js --auth
 *   2. Run listing test:
 *      node test-cross-post.js <listingId> [--taxonomy <id>]
 */

const admin = require("firebase-admin");
const https = require("https");
const fs = require("fs");
const path = require("path");
const readline = require("readline");
const crypto = require("crypto");

// 1. Initialize Firebase Admin
if (admin.apps.length === 0) {
  admin.initializeApp({
    projectId: "wonni-app"
  });
}
const db = admin.firestore();

const AUTH_FILE = path.join(__dirname, "etsy-auth.json");

// Helper to prompt user via console
function askQuestion(query) {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
  });
  return new Promise((resolve) => rl.question(query, (ans) => {
    rl.close();
    resolve(ans);
  }));
}

// Promise wrapper for https requests
function makeHttpRequest(options, bodyData = null) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        resolve({
          statusCode: res.statusCode,
          headers: res.headers,
          body: data,
        });
      });
    });

    req.on("error", reject);

    if (bodyData) {
      const payload = typeof bodyData === "string" ? bodyData : JSON.stringify(bodyData);
      req.write(payload);
    }
    req.end();
  });
}

// Generate cryptographically secure verifier and challenge for PKCE
function generateCodeVerifier() {
  return crypto.randomBytes(32).toString("base64url");
}

function generateCodeChallenge(verifier) {
  return crypto.createHash("sha256").update(verifier).digest("base64url");
}

// Load current configuration/auth from local file
function loadConfig() {
  if (fs.existsSync(AUTH_FILE)) {
    try {
      return JSON.parse(fs.readFileSync(AUTH_FILE, "utf8"));
    } catch (e) {
      console.warn("Failed to parse etsy-auth.json. Starting fresh.");
    }
  }
  return {};
}

// Save configuration/auth to local file
function saveConfig(config) {
  fs.writeFileSync(AUTH_FILE, JSON.stringify(config, null, 2), "utf8");
  console.log(`Saved configuration to ${AUTH_FILE}`);
}

// Fetch shop details using the access token
async function fetchShopDetails(accessToken, clientId) {
  const userId = accessToken.split(".")[0];
  const options = {
    hostname: "openapi.etsy.com",
    path: `/v3/application/users/${userId}/shops`,
    method: "GET",
    headers: {
      "x-api-key": clientId,
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json"
    }
  };

  const res = await makeHttpRequest(options);
  if (res.statusCode === 200) {
    const data = JSON.parse(res.body);
    if (data.results && data.results.length > 0) {
      return data.results[0];
    }
  }
  throw new Error(`Failed to fetch shop details (${res.statusCode}): ${res.body}`);
}

// Interactive OAuth 2.0 PKCE Flow
async function runInteractiveAuth() {
  console.log("\n=== Etsy OAuth 2.0 PKCE Setup ===");
  const config = loadConfig();

  // Retrieve keys from environment or prompt
  const client_id = process.env.ETSY_CLIENT_ID || config.client_id || await askQuestion("Enter your Etsy Client ID (keystring): ");
  const client_secret = process.env.ETSY_SHARED_SECRET || config.client_secret || await askQuestion("Enter your Etsy Shared Secret (shared secret): ");

  if (!client_id || !client_secret) {
    console.error("Client ID and Shared Secret are required.");
    process.exit(1);
  }

  // Generate PKCE values
  const codeVerifier = generateCodeVerifier();
  const codeChallenge = generateCodeChallenge(codeVerifier);
  const redirectUri = "wonni://oauth/etsy";
  const state = crypto.randomBytes(8).toString("hex");

  const authorizeUrl = `https://www.etsy.com/oauth/connect?response_type=code&client_id=${client_id}&redirect_uri=${encodeURIComponent(redirectUri)}&scope=listings_w%20listings_r%20shops_r&state=${state}&code_challenge=${codeChallenge}&code_challenge_method=S256`;

  console.log("\n1. Copy and open the following URL in your web browser:");
  console.log("\x1b[36m%s\x1b[0m", authorizeUrl);
  console.log("\n2. Log in to Etsy, authorize the app, and copy the redirected URL from your browser's address bar.");
  console.log("(It will look like wonni://oauth/etsy?code=...&state=...)");

  const redirectUrl = await askQuestion("\nPaste the redirect URL here: ");
  let code = "";
  try {
    const parsedUrl = new URL(redirectUrl.trim());
    code = parsedUrl.searchParams.get("code");
  } catch (e) {
    // If they pasted just the query params or the code
    const match = redirectUrl.match(/[?&]code=([^&]+)/);
    code = match ? match[1] : redirectUrl.trim();
  }

  if (!code) {
    console.error("Could not extract authorization code from input.");
    process.exit(1);
  }

  console.log("\nExchanging code for tokens...");
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: client_id,
    client_secret: client_secret,
    code: code,
    redirect_uri: redirectUri,
    code_verifier: codeVerifier
  }).toString();

  const options = {
    hostname: "api.etsy.com",
    path: "/v3/public/oauth/token",
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "Content-Length": Buffer.byteLength(body),
    },
  };

  const tokenRes = await makeHttpRequest(options, body);
  if (tokenRes.statusCode !== 200) {
    console.error(`Token exchange failed (${tokenRes.statusCode}):`, tokenRes.body);
    process.exit(1);
  }

  const tokenData = JSON.parse(tokenRes.body);
  console.log("Token exchange succeeded!");

  console.log("Fetching shop details...");
  try {
    const shop = await fetchShopDetails(tokenData.access_token, client_id);
    console.log(`Connected to Shop: "${shop.shop_name}" (ID: ${shop.shop_id})`);

    saveConfig({
      client_id,
      client_secret,
      shop_id: String(shop.shop_id),
      shop_name: shop.shop_name,
      access_token: tokenData.access_token,
      refresh_token: tokenData.refresh_token,
      token_expires_at: Date.now() + tokenData.expires_in * 1000
    });
    console.log("\nOAuth Authentication completed successfully.");
  } catch (err) {
    console.error("Failed to fetch shop details:", err.message);
  }
}

// Refresh access token if expired
async function getOrRefreshAccessToken(config) {
  const now = Date.now();
  if (config.access_token && config.token_expires_at && config.token_expires_at > now + 300000) {
    return config.access_token;
  }

  console.log("Access token expired or close to expiring. Refreshing...");
  if (!config.refresh_token) {
    throw new Error("No refresh token available. Run interactive auth again.");
  }

  const bodyParams = {
    grant_type: "refresh_token",
    client_id: config.client_id,
    refresh_token: config.refresh_token
  };
  if (config.client_secret) {
    bodyParams.client_secret = config.client_secret;
  }
  const body = new URLSearchParams(bodyParams).toString();

  const options = {
    hostname: "api.etsy.com",
    path: "/v3/public/oauth/token",
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "Content-Length": Buffer.byteLength(body)
    }
  };

  const res = await makeHttpRequest(options, body);
  if (res.statusCode !== 200) {
    throw new Error(`Token refresh failed (${res.statusCode}): ${res.body}`);
  }

  const tokenData = JSON.parse(res.body);
  config.access_token = tokenData.access_token;
  config.refresh_token = tokenData.refresh_token;
  config.token_expires_at = Date.now() + tokenData.expires_in * 1000;
  
  saveConfig(config);
  return config.access_token;
}

// Map listing categories to common taxonomy IDs
function getTaxonomyId(listingCategory, defaultOverride) {
  if (defaultOverride) return parseInt(defaultOverride);

  const category = (listingCategory || "").toLowerCase();
  if (category.includes("board games") || category.includes("games")) {
    return 1296; // Games > Board Games
  }
  if (category.includes("music") || category.includes("cd") || category.includes("vinyl")) {
    return 2042; // Books, Movies & Music > Music > Music CDs & Vinyl
  }
  if (category.includes("clothing") || category.includes("apparel")) {
    return 100; // Clothing
  }
  if (category.includes("toy") || category.includes("action figure")) {
    return 1290; // Toys
  }

  console.log(`Could not auto-map category "${listingCategory}". Defaulting to root taxonomy 1.`);
  return 1; // General / Root Category
}

// Create a draft listing on Etsy
async function createEtsyDraft(listingId, overrideTaxonomy) {
  console.log(`\n=== Creating Etsy Draft for Listing: ${listingId} ===`);
  const config = loadConfig();

  if (!config.client_id || !config.access_token || !config.shop_id) {
    console.error("Missing credentials. Please run interactive OAuth first: node test-cross-post.js --auth");
    process.exit(1);
  }

  // 1. Fetch listing details from Firestore
  console.log("Loading listing from Firestore...");
  const listingDoc = await db.collection("listings").doc(listingId).get();
  if (!listingDoc.exists) {
    console.error(`Listing not found in Firestore: ${listingId}`);
    process.exit(1);
  }
  const listing = listingDoc.data();
  console.log(`Loaded listing: "${listing.customTitle || listing.title}"`);

  // 2. Ensure access token is active
  const accessToken = await getOrRefreshAccessToken(config);

  // 3. Resolve Taxonomy ID
  const taxonomyId = getTaxonomyId(listing.category, overrideTaxonomy);
  console.log(`Using Etsy Taxonomy ID: ${taxonomyId}`);

  // 4. Construct Payload
  // Title limit on Etsy: 140 characters
  const title = (listing.customTitle || listing.title || "Wonni Listing").slice(0, 140);
  const description = listing.customDescription || listing.description || "Listed via Wonni";
  const price = listing.price || 9.99;
  const quantity = 1;

  const payload = {
    quantity: quantity,
    title: title,
    description: description,
    price: parseFloat(price.toFixed(2)),
    who_made: "someone_else", // one of: i_did, someone_else, collective
    when_made: "2020_2024",   // one of: made_to_order, before_2020, 2020_2024, etc.
    is_supply: false,
    taxonomy_id: taxonomyId
  };

  console.log("Request Payload:", JSON.stringify(payload, null, 2));

  // 5. Send POST request to Etsy
  const options = {
    hostname: "openapi.etsy.com",
    path: `/v3/application/shops/${config.shop_id}/listings`,
    method: "POST",
    headers: {
      "x-api-key": config.client_id,
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json"
    }
  };

  console.log("Sending request to Etsy API...");
  const res = await makeHttpRequest(options, payload);
  console.log(`HTTP Response Code: ${res.statusCode}`);
  
  try {
    const responseBody = JSON.parse(res.body);
    console.log("Response Body:", JSON.stringify(responseBody, null, 2));
    if (res.statusCode === 201 || res.statusCode === 200) {
      console.log("\x1b[32m%s\x1b[0m", "\n🎉 Draft Listing created successfully on Etsy!");
      console.log(`Etsy Listing ID: ${responseBody.listing_id}`);
      console.log(`Edit Draft Link: https://www.etsy.com/your/shops/${config.shop_name}/tools/listings/state:draft,view:table/details/${responseBody.listing_id}`);
    } else {
      console.error("\x1b[31m%s\x1b[0m", "\n❌ Failed to create draft listing on Etsy.");
    }
  } catch (e) {
    console.log("Raw Response Body:", res.body);
  }
}

// Main Runner
async function run() {
  const args = process.argv.slice(2);
  
  if (args.includes("--auth")) {
    await runInteractiveAuth();
    process.exit(0);
  }

  // Parse custom parameters
  const taxonomyIdx = args.indexOf("--taxonomy");
  let overrideTaxonomy = null;
  if (taxonomyIdx !== -1 && args[taxonomyIdx + 1]) {
    overrideTaxonomy = args[taxonomyIdx + 1];
    args.splice(taxonomyIdx, 2);
  }

  const listingId = args[0] || "14311C9C-A895-4CA1-8305-7BF7C74653D9"; // Default test listing
  await createEtsyDraft(listingId, overrideTaxonomy);
  process.exit(0);
}

run().catch((err) => {
  console.error("Fatal Error running script:", err);
  process.exit(1);
});
