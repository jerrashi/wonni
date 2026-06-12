const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const https = require("https");

const ebayClientId = defineSecret("EBAY_CLIENT_ID");
const ebayCertId = defineSecret("EBAY_CERT_ID");

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
      req.write(typeof bodyData === "string" ? bodyData : JSON.stringify(bodyData));
    }
    req.end();
  });
}

async function getApplicationToken(clientId, certId, isSandbox = false) {
  const credentials = Buffer.from(`${clientId}:${certId}`).toString("base64");
  const body = "grant_type=client_credentials&scope=https://api.ebay.com/oauth/api_scope";
  
  const host = isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com";
  const options = {
    hostname: host,
    path: "/identity/v1/oauth2/token",
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "Authorization": `Basic ${credentials}`,
      "Content-Length": Buffer.byteLength(body),
    },
  };

  const response = await makeHttpRequest(options, body);
  if (response.statusCode !== 200) {
    throw new Error(`Failed to get app token: ${response.body}`);
  }
  return JSON.parse(response.body).access_token;
}

exports.ebayImportListing = onCall(
  { secrets: [ebayClientId, ebayCertId] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const { itemId, isSandbox = false } = request.data;
    if (!itemId) {
      throw new HttpsError("invalid-argument", "itemId is required.");
    }

    try {
      const appToken = await getApplicationToken(ebayClientId.value(), ebayCertId.value(), isSandbox);
      const host = isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com";
      
      const options = {
        hostname: host,
        path: `/buy/browse/v1/item/get_item_by_legacy_id?legacy_item_id=${encodeURIComponent(itemId)}`,
        method: "GET",
        headers: {
          "Authorization": `Bearer ${appToken}`,
          "Content-Type": "application/json",
        },
      };

      const res = await makeHttpRequest(options);
      if (res.statusCode !== 200) {
        throw new Error(`eBay API error: ${res.statusCode} ${res.body}`);
      }

      const itemData = JSON.parse(res.body);
      
      // Extract needed fields
      return {
        title: itemData.title || "",
        price: itemData.price ? parseFloat(itemData.price.value) : 0,
        description: itemData.description || itemData.shortDescription || "",
        imageUrls: itemData.image ? [itemData.image.imageUrl, ...(itemData.additionalImages || []).map(img => img.imageUrl)] : [],
        condition: itemData.condition || "",
      };
    } catch (err) {
      console.error("[ebayImportListing] Error:", err.message);
      throw new HttpsError("internal", err.message);
    }
  }
);
