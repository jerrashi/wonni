/**
 * ebay_listing.js
 *
 * Firebase Cloud Functions: ebayCreateListing, ebayDeleteListing
 * Manages cross-posting individual listings to eBay via the Inventory API.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const https = require("https");

if (admin.apps.length === 0) {
  admin.initializeApp();
}

const ebayClientId = defineSecret("EBAY_CLIENT_ID");
const ebayCertId = defineSecret("EBAY_CERT_ID");

/**
 * Promise wrapper for https.request.
 */
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

/**
 * Refreshes the eBay OAuth token using the user's refresh token.
 */
async function refreshEbayToken(clientId, certId, refreshToken, isSandbox) {
  const credentials = Buffer.from(`${clientId}:${certId}`).toString("base64");
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(refreshToken)}&scope=${encodeURIComponent("https://api.ebay.com/oauth/api_scope https://api.ebay.com/oauth/api_scope/sell.inventory https://api.ebay.com/oauth/api_scope/sell.account https://api.ebay.com/oauth/api_scope/sell.fulfillment https://api.ebay.com/oauth/api_scope/sell.finances https://api.ebay.com/oauth/api_scope/commerce.identity.readonly")}`;

  const host = isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com";
  const options = {
    hostname: host,
    path:     "/identity/v1/oauth2/token",
    method:   "POST",
    headers: {
      "Content-Type":  "application/x-www-form-urlencoded",
      "Authorization": `Basic ${credentials}`,
      "Content-Length": Buffer.byteLength(body),
    },
  };

  const response = await makeHttpRequest(options, body);
  if (response.statusCode !== 200) {
    let errorBody = response.body;
  try {
    const parsed = JSON.parse(response.body);
    if (parsed.error === "invalid_scope") {
      throw new HttpsError(
        "failed-precondition",
        "Your eBay connection is missing required permissions. Please disconnect and reconnect your eBay account in Settings."
      );
    }
    errorBody = JSON.stringify(parsed);
  } catch (e) {
    if (e instanceof HttpsError) throw e;
  }
  throw new Error(`eBay token refresh failed (${response.statusCode}): ${errorBody}`);
  }

  return JSON.parse(response.body);
}

/**
 * Retrieves the user's current eBay access token, refreshing it if expired.
 */
async function getActiveAccessToken(uid, clientId, certId, db) {
  const integrationRef = db.collection("users").doc(uid).collection("integrations").doc("ebay");
  const doc = await integrationRef.get();
  if (!doc.exists) {
    throw new Error("eBay integration not configured for this user.");
  }
  const data = doc.data();
  if (!data.isConnected || !data.refreshToken) {
    throw new Error("eBay integration is disconnected.");
  }

  const now = Date.now();
  const tokenExpiresAt = data.tokenExpiresAt ? data.tokenExpiresAt.toDate().getTime() : 0;
  if (tokenExpiresAt > now + 300000) { // 5-minute buffer
    return { accessToken: data.accessToken, isSandbox: data.isSandbox || false };
  }

  console.log(`[ebay_listing] Refreshing token for uid=${uid}`);
  const refreshResult = await refreshEbayToken(clientId, certId, data.refreshToken, data.isSandbox);

  const expiresAt = admin.firestore.Timestamp.fromMillis(Date.now() + refreshResult.expires_in * 1000);
  await integrationRef.set({
    accessToken: refreshResult.access_token,
    tokenExpiresAt: expiresAt
  }, { merge: true });

  return { accessToken: refreshResult.access_token, isSandbox: data.isSandbox || false };
}

/**
 * Helper to extract duplicate policy ID from eBay API errors.
 */
function extractDuplicatePolicyId(responseBody) {
  try {
    const errorObj = JSON.parse(responseBody);
    if (errorObj && errorObj.errors) {
      for (const err of errorObj.errors) {
        if (err.parameters) {
          const dupParam = err.parameters.find(p => p.name === "duplicatePolicyId" || p.name === "duplicatePolicyName");
          if (dupParam && dupParam.value) {
            return dupParam.value;
          }
        }
      }
    }
  } catch (e) {
    console.warn("[extractDuplicatePolicyId] Failed to parse error body:", e.message);
  }
  return null;
}

/**
 * Resolves an eBay leaf category from eBay's own taxonomy suggestions, built from the listing
 * title plus the leaf of the Gemini category path. Returns null if no confident suggestion is
 * available (caller falls back to "Everything Else"). Production only — the sandbox taxonomy
 * service is unreliable.
 */
async function suggestEbayCategory(accessToken, title, geminiCategory) {
  let query = title || "";
  if (geminiCategory) {
    const leaf = String(geminiCategory).split(">").pop().trim();
    if (leaf && query.toLowerCase().indexOf(leaf.toLowerCase()) === -1) {
      query = `${leaf} ${query}`;
    }
  }
  query = query.trim().slice(0, 80);
  if (!query) return null;

  const options = {
    hostname: "api.ebay.com",
    path: `/commerce/taxonomy/v1/category_tree/0/get_category_suggestions?q=${encodeURIComponent(query)}`,
    method: "GET",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
  };
  try {
    const res = await makeHttpRequest(options);
    if (res.statusCode === 200) {
      const data = JSON.parse(res.body);
      const suggestions = data.categorySuggestions || [];
      if (suggestions.length > 0 && suggestions[0].category) {
        const cat = suggestions[0].category;
        console.log(`[suggestEbayCategory] "${query}" -> ${cat.categoryId} (${cat.categoryName})`);
        return cat.categoryId;
      }
    } else {
      console.warn(`[suggestEbayCategory] ${res.statusCode}: ${res.body}`);
    }
  } catch (err) {
    console.warn(`[suggestEbayCategory] request failed: ${err.message}`);
  }
  return null;
}

/**
 * Fetches the REQUIRED item aspects for a category so we can fill them before publishing.
 * Returns [{ name, mode, values }]. Production only; returns [] on any failure (the reactive
 * recovery in the publish loop is the safety net).
 */
async function getRequiredAspects(accessToken, categoryId) {
  const options = {
    hostname: "api.ebay.com",
    path: `/commerce/taxonomy/v1/category_tree/0/get_item_aspects_for_category?category_id=${encodeURIComponent(categoryId)}`,
    method: "GET",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
  };
  try {
    const res = await makeHttpRequest(options);
    if (res.statusCode !== 200) {
      console.warn(`[getRequiredAspects] ${res.statusCode}: ${res.body}`);
      return [];
    }
    const data = JSON.parse(res.body);
    return (data.aspects || [])
      .filter(a => a.aspectConstraint && a.aspectConstraint.aspectRequired)
      .map(a => ({
        name: a.localizedAspectName,
        mode: a.aspectConstraint.aspectMode, // FREE_TEXT | SELECTION_ONLY
        values: (a.aspectValues || []).map(v => v.localizedValue),
      }));
  } catch (err) {
    console.warn(`[getRequiredAspects] request failed: ${err.message}`);
    return [];
  }
}

/**
 * Builds the product.aspects object, satisfying every required aspect so the publish validates.
 * Brand is always set. SELECTION_ONLY aspects take a valid value from eBay's allowed list (a free
 * string would be rejected); FREE_TEXT aspects we have no data for get a neutral placeholder the
 * seller can refine on eBay. Best-effort by design — the goal is "the listing posts."
 */
function buildProductAspects(requiredAspects, brand) {
  const aspects = { Brand: [brand] };
  for (const aspect of requiredAspects) {
    if (aspects[aspect.name]) continue; // already supplied (e.g. Brand)
    if (aspect.mode === "SELECTION_ONLY" && aspect.values.length > 0) {
      aspects[aspect.name] = [aspect.values[0]];
    } else {
      aspects[aspect.name] = [brand && brand !== "Generic" ? brand : "Unbranded"];
    }
  }
  return aspects;
}

/**
 * Parses the aspect name(s) eBay reported as missing from a failed publish response, e.g.
 * "The item specific Release Title is missing." -> ["Release Title"]. Used to reactively fill
 * required aspects the proactive lookup didn't cover, then retry the publish.
 */
function extractMissingAspects(responseBody) {
  const names = new Set();
  try {
    const obj = JSON.parse(responseBody);
    for (const err of (obj.errors || [])) {
      const match = (err.message || "").match(/item specific (.+?) is missing/i);
      if (match && match[1]) names.add(match[1].trim());
      // eBay also echoes the aspect name as the parameter named "3".
      for (const p of (err.parameters || [])) {
        if (p.name === "3" && p.value) names.add(String(p.value).trim());
      }
    }
  } catch (e) {
    console.warn("[extractMissingAspects] parse failed:", e.message);
  }
  return [...names];
}

// eBay Inventory API condition enums <-> numeric condition IDs (what the category policy lists).
const CONDITION_ENUM_TO_ID = {
  NEW: "1000", LIKE_NEW: "2750", NEW_OTHER: "1500", NEW_WITH_DEFECTS: "1750",
  USED_EXCELLENT: "3000", USED_VERY_GOOD: "4000", USED_GOOD: "5000",
  USED_ACCEPTABLE: "6000", FOR_PARTS_OR_NOT_WORKING: "7000",
};
const CONDITION_ID_TO_ENUM = Object.fromEntries(
  Object.entries(CONDITION_ENUM_TO_ID).map(([k, v]) => [v, k])
);

/**
 * Preference order (by condition ID) for degrading to an allowed condition when the category
 * doesn't accept the one we intended. Stays as close as possible to the seller's stated grade,
 * falling back to the generic "Used" (3000) which nearly every used-supporting category accepts.
 */
function conditionPreferenceIds(conditionEnum) {
  switch (conditionEnum) {
    case "NEW":                     return ["1000", "1500", "3000"];
    case "LIKE_NEW":                return ["2750", "1500", "3000", "4000"];
    case "USED_EXCELLENT":          return ["3000", "4000", "5000", "6000"];
    case "USED_VERY_GOOD":          return ["4000", "3000", "5000", "6000"];
    case "USED_GOOD":               return ["5000", "4000", "3000", "6000"];
    case "USED_ACCEPTABLE":         return ["6000", "5000", "3000", "7000"];
    case "FOR_PARTS_OR_NOT_WORKING":return ["7000", "6000", "3000"];
    default:                        return ["3000", "4000", "5000", "1000"];
  }
}

/**
 * Fetches the condition IDs a category accepts via the eBay Metadata API. Returns null on any
 * failure (caller keeps its mapped condition and relies on the reactive 25021 recovery).
 */
async function getAllowedConditionIds(accessToken, categoryId, host) {
  const filter = encodeURIComponent(`categoryIds:{${categoryId}}`);
  const options = {
    hostname: host,
    path: `/sell/metadata/v1/marketplace/EBAY_US/get_item_condition_policies?filter=${filter}`,
    method: "GET",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
  };
  try {
    const res = await makeHttpRequest(options);
    if (res.statusCode !== 200) {
      console.warn(`[getAllowedConditionIds] ${res.statusCode}: ${res.body}`);
      return null;
    }
    const data = JSON.parse(res.body);
    const policy = (data.itemConditionPolicies || [])[0];
    if (!policy) return null;
    return (policy.itemConditions || []).map(c => String(c.conditionId));
  } catch (err) {
    console.warn(`[getAllowedConditionIds] request failed: ${err.message}`);
    return null;
  }
}

/**
 * Picks the best eBay condition enum a category will accept, given our intended one. Returns the
 * intended enum unchanged if it's allowed (or if allowed-list is unknown); otherwise degrades via
 * conditionPreferenceIds, finally falling back to the category's first allowed condition.
 */
function resolveCondition(intendedEnum, allowedIds) {
  if (!allowedIds || allowedIds.length === 0) return intendedEnum;
  const intendedId = CONDITION_ENUM_TO_ID[intendedEnum];
  if (intendedId && allowedIds.includes(intendedId)) return intendedEnum;
  for (const id of conditionPreferenceIds(intendedEnum)) {
    if (allowedIds.includes(id) && CONDITION_ID_TO_ENUM[id]) return CONDITION_ID_TO_ENUM[id];
  }
  return CONDITION_ID_TO_ENUM[allowedIds[0]] || intendedEnum;
}

/** True if a publish error body is the "invalid condition for this category" failure (25021). */
function isConditionError(responseBody) {
  try {
    const obj = JSON.parse(responseBody);
    return (obj.errors || []).some(e =>
      e.errorId === 25021 ||
      (e.parameters || []).some(p => p.value === "CONDITION_ID")
    );
  } catch (e) {
    return false;
  }
}

/**
 * Helper to get or create eBay Payment Policy.
 */
async function getOrCreatePaymentPolicy(accessToken, host) {
  const listOptions = {
    hostname: host,
    path:     "/sell/account/v1/payment_policy?marketplace_id=EBAY_US",
    method:   "GET",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type":  "application/json",
    },
  };
  const listRes = await makeHttpRequest(listOptions);
  let allPolicies = [];
  if (listRes.statusCode === 200) {
    const data = JSON.parse(listRes.body);
    allPolicies = data.paymentPolicies || [];
    const existing = allPolicies.find(p => p.name === "Wonni Payment Policy");
    if (existing) return existing.paymentPolicyId;
  }
  
  // Create new
  const createOptions = {
    hostname: host,
    path:     "/sell/account/v1/payment_policy",
    method:   "POST",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type":  "application/json",
    },
  };
  const payload = {
    name: "Wonni Payment Policy",
    marketplaceId: "EBAY_US",
    categoryTypes: [{ name: "ALL_EXCLUDING_MOTORS_VEHICLES" }],
    description: "Default payment policy created by Wonni"
  };
  const createRes = await makeHttpRequest(createOptions, payload);
  if (createRes.statusCode === 201) {
    return JSON.parse(createRes.body).paymentPolicyId;
  }

  const duplicateId = extractDuplicatePolicyId(createRes.body);
  if (duplicateId) {
    console.log(`[getOrCreatePaymentPolicy] Found duplicate payment policy ID: ${duplicateId}`);
    return duplicateId;
  }

  // Fall back to any existing payment policy
  if (allPolicies.length > 0) {
    const fallback = allPolicies[0];
    console.log(`[getOrCreatePaymentPolicy] Creation failed, falling back to existing policy: ${fallback.name} (${fallback.paymentPolicyId})`);
    return fallback.paymentPolicyId;
  }

  throw new Error(`Failed to create eBay payment policy (${createRes.statusCode}): ${createRes.body}`);
}

/**
 * Helper to get or create eBay Return Policy.
 */
async function getOrCreateReturnPolicy(accessToken, host, returnsAccepted, returnWindowDays) {
  const listOptions = {
    hostname: host,
    path:     "/sell/account/v1/return_policy?marketplace_id=EBAY_US",
    method:   "GET",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type":  "application/json",
    },
  };
  const listRes = await makeHttpRequest(listOptions);
  const policyName = `Wonni Return Policy - ${returnsAccepted ? `${returnWindowDays} Days` : "No Returns"}`;
  let allPolicies = [];
  if (listRes.statusCode === 200) {
    const data = JSON.parse(listRes.body);
    allPolicies = data.returnPolicies || [];
    const existing = allPolicies.find(p => p.name === policyName);
    if (existing) return existing.returnPolicyId;
  }
  
  // Create new
  const createOptions = {
    hostname: host,
    path:     "/sell/account/v1/return_policy",
    method:   "POST",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type":  "application/json",
    },
  };
  const payload = {
    name: policyName,
    marketplaceId: "EBAY_US",
    categoryTypes: [{ name: "ALL_EXCLUDING_MOTORS_VEHICLES" }],
    returnsAccepted: returnsAccepted,
  };
  if (returnsAccepted) {
    payload.returnPeriod = {
      value: returnWindowDays || 30,
      unit: "DAY"
    };
    payload.returnShippingCostPayer = "BUYER";
    payload.refundMethod = "MONEY_BACK";
  }
  const createRes = await makeHttpRequest(createOptions, payload);
  if (createRes.statusCode === 201) {
    return JSON.parse(createRes.body).returnPolicyId;
  }

  const duplicateId = extractDuplicatePolicyId(createRes.body);
  if (duplicateId) {
    console.log(`[getOrCreateReturnPolicy] Found duplicate return policy ID: ${duplicateId}`);
    return duplicateId;
  }

  // Fall back to any existing return policy
  if (allPolicies.length > 0) {
    const fallback = allPolicies[0];
    console.log(`[getOrCreateReturnPolicy] Creation failed, falling back to existing policy: ${fallback.name} (${fallback.returnPolicyId})`);
    return fallback.returnPolicyId;
  }

  throw new Error(`Failed to create eBay return policy (${createRes.statusCode}): ${createRes.body}`);
}

/**
 * Helper to get or create eBay Fulfillment Policy.
 */
async function getOrCreateFulfillmentPolicy(accessToken, host, shippingType, buyerPaysShipping) {
  const listOptions = {
    hostname: host,
    path:     "/sell/account/v1/fulfillment_policy?marketplace_id=EBAY_US",
    method:   "GET",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type":  "application/json",
    },
  };
  const listRes = await makeHttpRequest(listOptions);
  const policyName = `Wonni Ship Policy - ${shippingType} - ${buyerPaysShipping ? "Buyer Pays" : "Free"}`;

  let allPolicies = [];
  if (listRes.statusCode === 200) {
    const data = JSON.parse(listRes.body);
    allPolicies = data.fulfillmentPolicies || [];
    // First try exact name match
    const existing = allPolicies.find(p => p.name === policyName);
    if (existing) return existing.fulfillmentPolicyId;
  }
  
  // Map shippingType to valid eBay ShippingServiceCode values
  // These must match codes from GeteBayDetails/ShippingServiceDetails with ValidForSellingFlow=true
  let serviceCode = "USPSParcel"; // USPS Ground Advantage (formerly USPSParcel)
  let carrierCode = "USPS";
  if (shippingType === "mediaMailUSPS") {
    serviceCode = "USPSMedia";
  } else if (shippingType === "firstClassEnvelope") {
    serviceCode = "USPSFirstClass";
  } else if (shippingType === "priorityUSPS") {
    serviceCode = "USPSPriority";
  }
  
  const shippingOption = {
    optionType: "DOMESTIC",
  };
  
  if (buyerPaysShipping) {
    shippingOption.costType = "CALCULATED";
    shippingOption.shippingServices = [{
      shippingCarrierCode: carrierCode,
      shippingServiceCode: serviceCode,
      sortOrder: 1,
      buyerResponsibleForShipping: true
    }];
  } else {
    shippingOption.costType = "FLAT_RATE";
    shippingOption.shippingServices = [{
      shippingCarrierCode: carrierCode,
      shippingServiceCode: serviceCode,
      sortOrder: 1,
      freeShipping: true,
      shippingCost: { value: "0.00", currency: "USD" }
    }];
  }
  
  const payload = {
    name: policyName,
    marketplaceId: "EBAY_US",
    categoryTypes: [{ name: "ALL_EXCLUDING_MOTORS_VEHICLES" }],
    handlingTime: {
      value: 1,
      unit: "DAY"
    },
    shippingOptions: [shippingOption],
    localPickup: false,
    freightShipping: false
  };
  
  // Create new
  const createOptions = {
    hostname: host,
    path:     "/sell/account/v1/fulfillment_policy",
    method:   "POST",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type":  "application/json",
    },
  };

  const createRes = await makeHttpRequest(createOptions, payload);
  if (createRes.statusCode === 201) {
    return JSON.parse(createRes.body).fulfillmentPolicyId;
  }

  // Handle duplicate
  const duplicateId = extractDuplicatePolicyId(createRes.body);
  if (duplicateId) {
    console.log(`[getOrCreateFulfillmentPolicy] Found duplicate fulfillment policy ID: ${duplicateId}`);
    return duplicateId;
  }

  // If creation failed for any reason, fall back to using any existing fulfillment policy
  // (the user may have manually created one on ebay.com)
  if (allPolicies.length > 0) {
    const fallbackPolicy = allPolicies[0];
    console.log(`[getOrCreateFulfillmentPolicy] Creation failed, falling back to existing policy: ${fallbackPolicy.name} (${fallbackPolicy.fulfillmentPolicyId})`);
    return fallbackPolicy.fulfillmentPolicyId;
  }

  throw new Error(`Failed to create eBay fulfillment policy (${createRes.statusCode}): ${createRes.body}`);
}

/**
 * Opt in to the eBay Business Policies program (idempotent).
 */
async function optInToBusinessPolicies(accessToken, host) {
  const options = {
    hostname: host,
    path:     "/sell/account/v1/program/opt_in",
    method:   "POST",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type":  "application/json",
    },
  };
  const res = await makeHttpRequest(options, { programType: "SELLING_POLICY_MANAGEMENT" });
  console.log(`[optInToBusinessPolicies] ${res.statusCode} - ${res.body}`);
  // 204 = opted in now, 409 = already opted in — both fine
  return res.statusCode === 204 || res.statusCode === 409 || res.statusCode === 200;
}

/**
 * Ensures Return, Payment, and Fulfillment Policies exist on the eBay account.
 */
async function ensureBusinessPolicies(accessToken, isSandbox, sellingSettings, uid, db) {
  const host = isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com";

  // Step 1: Attempt auto opt-in to Business Policies (idempotent)
  try {
    await optInToBusinessPolicies(accessToken, host);
  } catch (e) {
    console.warn(`[ensureBusinessPolicies] opt_in call failed (non-fatal): ${e.message}`);
  }

  // Step 2: Verify Business Policies are accessible
  const options = {
    hostname: host,
    path:     "/sell/account/v1/fulfillment_policy?marketplace_id=EBAY_US",
    method:   "GET",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type":  "application/json",
    },
  };

  const response = await makeHttpRequest(options);
  if (response.statusCode !== 200) {
    console.error(`[ensureBusinessPolicies] Error: ${response.statusCode} - ${response.body}`);
    const bodyLower = response.body.toLowerCase();
    if (
      bodyLower.includes("opt") ||
      bodyLower.includes("business polic") ||
      bodyLower.includes("not eligible") ||
      bodyLower.includes("program") ||
      response.statusCode === 403
    ) {
      const settingsRef = db.collection("users").doc(uid).collection("sellingSettings").doc("default");
      await settingsRef.set({ businessPoliciesDisabled: true }, { merge: true });
      throw new HttpsError(
        "failed-precondition",
        "eBay Business Policies are not enabled. Please visit ebay.com/bp/manage to enable them, then try again."
      );
    }
    throw new Error(`Failed to query eBay Business Policies (${response.statusCode}): ${response.body}`);
  }
  
  if (sellingSettings.businessPoliciesDisabled) {
    const settingsRef = db.collection("users").doc(uid).collection("sellingSettings").doc("default");
    await settingsRef.set({ businessPoliciesDisabled: false }, { merge: true });
  }
  
  let ebayPolicyIds = sellingSettings.ebayPolicyIds || {};
  let updated = false;
  
  if (!ebayPolicyIds.paymentPolicyId) {
    const paymentPolicyId = await getOrCreatePaymentPolicy(accessToken, host);
    ebayPolicyIds.paymentPolicyId = paymentPolicyId;
    updated = true;
  }
  
  if (!ebayPolicyIds.returnPolicyId) {
    const returnPolicyId = await getOrCreateReturnPolicy(accessToken, host, sellingSettings.returnsAccepted, sellingSettings.returnWindowDays);
    ebayPolicyIds.returnPolicyId = returnPolicyId;
    updated = true;
  }
  
  if (!ebayPolicyIds.fulfillmentPolicyId) {
    const fulfillmentPolicyId = await getOrCreateFulfillmentPolicy(accessToken, host, sellingSettings.shippingType, sellingSettings.buyerPaysShipping);
    ebayPolicyIds.fulfillmentPolicyId = fulfillmentPolicyId;
    updated = true;
  }
  
  if (updated) {
    const settingsRef = db.collection("users").doc(uid).collection("sellingSettings").doc("default");
    await settingsRef.set({ ebayPolicyIds }, { merge: true });
  }
  
  return ebayPolicyIds;
}

/**
 * Ensures an Inventory Warehouse Location exists for mapping inventory listings.
 */
async function ensureInventoryLocation(accessToken, host, defaultLocation, uid, db) {
  let merchantLocationKey = defaultLocation.merchantLocationKey;
  if (merchantLocationKey) return merchantLocationKey;

  const locationKey = `loc_${uid.replace(/[^a-zA-Z0-9]/g, "").slice(0, 40)}`;
  
  const options = {
    hostname: host,
    path:     `/sell/inventory/v1/location/${locationKey}`,
    method:   "POST",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type":  "application/json",
    },
  };
  
  const payload = {
    name: "Wonni Inventory Warehouse",
    locationTypes: ["WAREHOUSE"],
    location: {
      address: {
        addressLine1: defaultLocation.addressLine1 || "100 Main St",
        city: defaultLocation.city || "San Jose",
        stateOrProvince: defaultLocation.stateOrProvince || "CA",
        postalCode: defaultLocation.postalCode || "95125",
        country: defaultLocation.country || "US"
      }
    }
  };
  
  console.log(`[ensureInventoryLocation] Creating location for key=${locationKey}`);
  const response = await makeHttpRequest(options, payload);
  if (response.statusCode !== 204 && response.statusCode !== 201 && response.statusCode !== 200) {
    console.warn(`[ensureInventoryLocation] Location create response: ${response.statusCode} - ${response.body}`);
    if (response.statusCode !== 409) {
      throw new Error(`Failed to create eBay inventory location (${response.statusCode}): ${response.body}`);
    }
  }
  
  const settingsRef = db.collection("users").doc(uid).collection("sellingSettings").doc("default");
  await settingsRef.set({
    defaultLocation: {
      merchantLocationKey: locationKey
    }
  }, { merge: true });
  
  return locationKey;
}

/**
 * Callable Function: ebayCreateListing
 * Expects: { listingId: string }
 */
exports.ebayCreateListing = onCall(
  { secrets: [ebayClientId, ebayCertId] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;
    const { listingId } = request.data;
    if (!listingId) {
      throw new HttpsError("invalid-argument", "listingId is required.");
    }

    const db = admin.firestore();
    const listingRef = db.collection("listings").doc(listingId);
    const listingDoc = await listingRef.get();
    if (!listingDoc.exists) {
      throw new HttpsError("not-found", "Listing not found.");
    }
    const listing = listingDoc.data();
    if (listing.userId !== uid) {
      throw new HttpsError("permission-denied", "You do not own this listing.");
    }

    // Idempotency guard: if already posted, return the existing eBay listing ID rather
    // than re-submitting. Prevents duplicate listings from retry storms.
    if (listing.crossPostStatus?.ebay === "posted" && listing.crossPostListingIds?.ebay) {
      console.log(`[ebayCreateListing] Listing ${listingId} already posted to eBay (${listing.crossPostListingIds.ebay}). Skipping.`);
      return { success: true, listingId: listing.crossPostListingIds.ebay };
    }

    // Set status to pending in UserListing
    await listingRef.set({
      crossPostStatus: {
        ebay: "pending"
      }
    }, { merge: true });

    try {
      // 1. Load SellingSettings
      const settingsRef = db.collection("users").doc(uid).collection("sellingSettings").doc("default");
      const settingsDoc = await settingsRef.get();
      if (!settingsDoc.exists) {
        throw new HttpsError("failed-precondition", "Selling settings not configured. Please fill in your Address in settings first.");
      }
      const sellingSettings = settingsDoc.data();
      if (!sellingSettings.defaultLocation || !sellingSettings.defaultLocation.postalCode) {
        throw new HttpsError("failed-precondition", "Please save a valid address in Settings before listing.");
      }

      // 2. Refresh token & Get active credentials
      const { accessToken, isSandbox } = await getActiveAccessToken(uid, ebayClientId.value(), ebayCertId.value(), db);
      const host = isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com";

      // 3. Ensure business policies exist and retrieve policy IDs
      const policyIds = await ensureBusinessPolicies(accessToken, isSandbox, sellingSettings, uid, db);

      // 4. Ensure inventory location exists and retrieve location key
      const locationKey = await ensureInventoryLocation(accessToken, host, sellingSettings.defaultLocation, uid, db);

      // 5. Generate public URLs for Storage photos
      // (Listing photos are publicly readable in storage rules, avoiding signBlob IAM errors)
      const photoPaths = listing.photoPaths || [];
      const imageUrls = [];
      const bucket = admin.storage().bucket();
      for (const path of photoPaths) {
        try {
          const encodedPath = encodeURIComponent(path);
          const url = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodedPath}?alt=media`;
          imageUrls.push(url);
        } catch (err) {
          console.error(`[ebayCreateListing] Error constructing URL for path ${path}:`, err);
        }
      }

      if (imageUrls.length === 0) {
        throw new Error("eBay requires at least one product image.");
      }

      // 6. Category resolution. Prefer eBay's own taxonomy suggestion (built from the title +
      //    Gemini category); honor an explicit client-provided category only if present; fall back
      //    to "Everything Else" (99). The previous static client-side map produced wrong leaf
      //    categories (e.g. Music CDs) whose required item specifics then failed the publish.
      const title = listing.customTitle || "Wonni Listing";
      const description = listing.customDescription || "Listed via Wonni";
      let categoryId = listing.ebayCategory ? String(listing.ebayCategory) : null;
      if (!categoryId && !isSandbox) {
        categoryId = await suggestEbayCategory(accessToken, title, listing.category);
      }
      if (!categoryId) categoryId = "99"; // "Everything Else" — minimal required aspects
      console.log(`[ebayCreateListing] Using category ${categoryId}`);

      // Pre-fetch the category's required item aspects so we can fill them before publishing.
      // (Production only — getRequiredAspects returns [] in sandbox; the publish loop below also
      // recovers reactively from any missing-aspect error the pre-fetch didn't cover.)
      const requiredAspects = isSandbox ? [] : await getRequiredAspects(accessToken, categoryId);
      if (requiredAspects.length > 0) {
        console.log(`[ebayCreateListing] Required aspects for ${categoryId}: ${requiredAspects.map(a => a.name).join(", ")}`);
      }

      // Pre-fetch which conditions this category accepts. Many categories reject the generic
      // grade we'd otherwise send (the 25021 "invalid condition for category" failure).
      const allowedConditionIds = isSandbox ? null : await getAllowedConditionIds(accessToken, categoryId, host);

      // 7. Map Condition
      const conditionMap = {
        new:            "NEW",
        newWithoutTags: "USED_EXCELLENT",
        likeNew:        "USED_EXCELLENT",
        good:           "USED_GOOD",
        fair:           "USED_ACCEPTABLE",
        poor:           "USED_ACCEPTABLE",
        forParts:       "FOR_PARTS_OR_NOT_WORKING"
      };
      let conditionMapped = conditionMap[listing.condition] || "USED_EXCELLENT";
      // Degrade to a condition the category actually accepts (e.g. some categories only allow
      // New/Used, not the finer Good/Acceptable grades) so the publish isn't rejected with 25021.
      const intendedCondition = conditionMapped;
      conditionMapped = resolveCondition(conditionMapped, allowedConditionIds);
      if (conditionMapped !== intendedCondition) {
        console.log(`[ebayCreateListing] Condition ${intendedCondition} not allowed for ${categoryId}; using ${conditionMapped}`);
      }

      // 8. Create or update inventory item
      const sku = `wonni_${listingId}`;
      const itemOptions = {
        hostname: host,
        path: `/sell/inventory/v1/inventory_item/${sku}`,
        method: "PUT",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
          "Content-Language": "en-US"
        }
      };

      const weightLbs = listing.shippingInfo?.weightLbs || 1.0;
      const lengthIn = listing.shippingInfo?.packageDimensions?.lengthIn || 8.0;
      const widthIn = listing.shippingInfo?.packageDimensions?.widthIn || 6.0;
      const heightIn = listing.shippingInfo?.packageDimensions?.heightIn || 4.0;
      const brand = listing.brand || "Generic";
      const price = listing.price || 0.0;
      const quantity = listing.quantity ?? 1;

      const itemBody = {
        availability: {
          shipToLocationAvailability: {
            quantity: quantity
          }
        },
        condition: conditionMapped,
        product: {
          title: title.slice(0, 80),
          description: description.slice(0, 1000), // Safety limit for descriptions in catalog
          imageUrls: imageUrls.slice(0, 12),
          brand: brand,
          mpn: "Does Not Apply",
          aspects: buildProductAspects(requiredAspects, brand)
        },
        packageWeightAndSize: {
          weight: {
            value: weightLbs,
            unit: "POUND"
          },
          dimensions: {
            length: lengthIn,
            width: widthIn,
            height: heightIn,
            unit: "INCH"
          }
        }
      };

      if (sellingSettings.shippingType === "firstClassEnvelope") {
        itemBody.packageWeightAndSize.packageType = "LETTER";
      }

      if (listing.conditionNotes) {
        itemBody.conditionDescription = listing.conditionNotes;
      }

      console.log(`[ebayCreateListing] Creating inventory item for SKU=${sku}`);
      const itemRes = await makeHttpRequest(itemOptions, itemBody);
      if (itemRes.statusCode !== 200 && itemRes.statusCode !== 201 && itemRes.statusCode !== 204) {
        throw new Error(`Failed to create eBay inventory item (${itemRes.statusCode}): ${itemRes.body}`);
      }

      // 9. Create Offer
      const offerOptions = {
        hostname: host,
        path: "/sell/inventory/v1/offer",
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
          "Content-Language": "en-US"
        }
      };

      const offerBody = {
        sku: sku,
        marketplaceId: "EBAY_US",
        format: "FIXED_PRICE",
        availableQuantity: quantity,
        outOfStockControl: true,
        categoryId: categoryId,
        listingDescription: description,
        listingPolicies: {
          fulfillmentPolicyId: policyIds.fulfillmentPolicyId,
          paymentPolicyId: policyIds.paymentPolicyId,
          returnPolicyId: policyIds.returnPolicyId
        },
        merchantLocationKey: locationKey,
        pricingSummary: {
          price: {
            value: price.toFixed(2),
            currency: "USD"
          }
        }
      };

      let offerId;
      console.log(`[ebayCreateListing] Creating offer for SKU=${sku}`);
      const offerRes = await makeHttpRequest(offerOptions, offerBody);
      if (offerRes.statusCode === 200 || offerRes.statusCode === 201) {
        const offerData = JSON.parse(offerRes.body);
        offerId = offerData.offerId;
        console.log(`[ebayCreateListing] Offer created successfully. offerId=${offerId}`);
      } else if (offerRes.statusCode === 400 && offerRes.body.includes("Offer entity already exists")) {
        const errorData = JSON.parse(offerRes.body);
        const existsError = errorData.errors?.find(e => e.errorId === 25002);
        const offerIdParam = existsError?.parameters?.find(p => p.name === "offerId");
        if (offerIdParam && offerIdParam.value) {
          offerId = offerIdParam.value;
          console.log(`[ebayCreateListing] Offer already existed. Recovered offerId=${offerId}. Updating offer...`);
          const updateOfferOptions = {
            hostname: host,
            path: `/sell/inventory/v1/offer/${offerId}`,
            method: "PUT",
            headers: {
              "Authorization": `Bearer ${accessToken}`,
              "Content-Type": "application/json",
              "Content-Language": "en-US"
            }
          };
          const updateRes = await makeHttpRequest(updateOfferOptions, offerBody);
          if (updateRes.statusCode !== 200 && updateRes.statusCode !== 204) {
             throw new Error(`Failed to update existing eBay offer (${updateRes.statusCode}): ${updateRes.body}`);
          }
        } else {
          throw new Error(`Failed to create eBay offer (${offerRes.statusCode}): ${offerRes.body}`);
        }
      } else {
        throw new Error(`Failed to create eBay offer (${offerRes.statusCode}): ${offerRes.body}`);
      }

      // 10. Publish the offer, recovering from "required item specific" errors.
      //
      // eBay validates required item aspects at publish time. We fill them up front (step 8), but
      // some categories only surface additional required aspects at publish — so if the publish
      // fails citing a missing item specific, we parse the aspect name(s), fill them, re-PUT the
      // inventory item, and try again. This is what turns the observed "Release Title is missing" /
      // "Artist is missing" failures into successful listings.
      const publishOptions = {
        hostname: host,
        path: `/sell/inventory/v1/offer/${offerId}/publish`,
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        }
      };

      // Publish once, retrying transient 5xx (common on re-publishes of existing inventory).
      const publishOnce = async () => {
        let res;
        for (let attempt = 1; attempt <= 3; attempt++) {
          res = await makeHttpRequest(publishOptions, {});
          if (res.statusCode === 200) return res;
          if (attempt < 3 && res.statusCode >= 500) {
            console.log(`[ebayCreateListing] Publish attempt ${attempt} returned ${res.statusCode}, retrying...`);
            await new Promise(resolve => setTimeout(resolve, attempt * 1500));
          } else {
            return res;
          }
        }
        return res;
      };

      console.log(`[ebayCreateListing] Publishing offerId=${offerId}`);
      let publishRes = await publishOnce();

      // Recover from publish failures eBay reports against the inventory item: missing required
      // aspects (25002) and an invalid condition for the category (25021). Each round mutates the
      // inventory item, re-PUTs it, and republishes. Bounded to avoid loops.
      let conditionFallbackTried = false;
      for (let round = 0; round < 4 && publishRes.statusCode !== 200; round++) {
        let changed = false;

        // (a) Fill any required item aspects the error names.
        const missing = extractMissingAspects(publishRes.body);
        for (const name of missing) {
          if (!itemBody.product.aspects[name]) {
            itemBody.product.aspects[name] = [brand && brand !== "Generic" ? brand : "Unbranded"];
            changed = true;
          }
        }
        if (missing.length > 0 && changed) {
          console.log(`[ebayCreateListing] Filling missing aspects and retrying: ${missing.join(", ")}`);
        }

        // (b) Category rejected the condition — fall back to generic "Used" once. (The proactive
        //     remap usually prevents this; this only fires if the condition-policy fetch failed.)
        if (isConditionError(publishRes.body) && !conditionFallbackTried) {
          conditionFallbackTried = true;
          if (itemBody.condition !== "USED_EXCELLENT") {
            console.log(`[ebayCreateListing] Condition ${itemBody.condition} rejected by ${categoryId}; retrying as USED_EXCELLENT`);
            itemBody.condition = "USED_EXCELLENT";
            changed = true;
          }
        }

        if (!changed) break; // nothing left we know how to fix — surface the real error
        const reput = await makeHttpRequest(itemOptions, itemBody);
        if (![200, 201, 204].includes(reput.statusCode)) {
          console.warn(`[ebayCreateListing] Re-PUT inventory item failed (${reput.statusCode}): ${reput.body}`);
          break;
        }
        publishRes = await publishOnce();
      }

      if (publishRes.statusCode !== 200) {
        throw new Error(`Failed to publish eBay offer (${publishRes.statusCode}): ${publishRes.body}`);
      }

      const publishData = JSON.parse(publishRes.body);
      const ebayListingId = publishData.listingId;
      console.log(`[ebayCreateListing] Published successfully. eBay Listing ID=${ebayListingId}`);

      // 11. Write success to Firestore
      const crossPostRef = db.collection("users").doc(uid).collection("crossPosts").doc(`${listingId}_ebay`);
      await crossPostRef.set({
        listingId: listingId,
        platform: "ebay",
        status: "posted",
        platformListingId: ebayListingId,
        ebayCategoryId: categoryId,
        createdAt: admin.firestore.FieldValue.serverTimestamp()
      });

      await listingRef.set({
        crossPostStatus: {
          ebay: "posted"
        },
        crossPostListingIds: {
          ebay: ebayListingId
        }
      }, { merge: true });

      return { success: true, listingId: ebayListingId };

    } catch (err) {
      console.error(`[ebayCreateListing] Error processing cross-post:`, err);

      // Write failure to Firestore
      const crossPostRef = db.collection("users").doc(uid).collection("crossPosts").doc(`${listingId}_ebay`);
      await crossPostRef.set({
        listingId: listingId,
        platform: "ebay",
        status: "failed",
        error: err.message,
        createdAt: admin.firestore.FieldValue.serverTimestamp()
      });

      await listingRef.set({
        crossPostStatus: {
          ebay: "failed"
        }
      }, { merge: true });

      let code = "internal";
      if (err instanceof HttpsError) {
        code = err.code;
      } else if (err.code && typeof err.code === "string") {
        const validCodes = [
          "ok", "cancelled", "unknown", "invalid-argument", "deadline-exceeded",
          "not-found", "already-exists", "permission-denied", "resource-exhausted",
          "failed-precondition", "aborted", "out-of-range", "unimplemented",
          "internal", "unavailable", "data-loss", "unauthenticated"
        ];
        if (validCodes.includes(err.code)) {
          code = err.code;
        }
      }
      throw new HttpsError(code, err.message);
    }
  }
);

/**
 * Callable Function: ebayUpdateListing
 * Updates the title, description, price, condition, and dimensions of an already-live eBay listing.
 * Uses the same Inventory API PUTs as create — no re-publish needed; changes go live immediately.
 * Expects: { listingId: string }
 */
exports.ebayUpdateListing = onCall(
  { secrets: [ebayClientId, ebayCertId] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;
    const { listingId } = request.data;
    if (!listingId) {
      throw new HttpsError("invalid-argument", "listingId is required.");
    }

    const db = admin.firestore();
    const listingRef = db.collection("listings").doc(listingId);
    const listingDoc = await listingRef.get();
    if (!listingDoc.exists) {
      throw new HttpsError("not-found", "Listing not found.");
    }
    const listing = listingDoc.data();
    if (listing.userId !== uid) {
      throw new HttpsError("permission-denied", "You do not own this listing.");
    }
    if (!listing.crossPostListingIds?.ebay) {
      throw new HttpsError("failed-precondition", "This listing is not posted on eBay.");
    }

    try {
      const { accessToken, isSandbox } = await getActiveAccessToken(uid, ebayClientId.value(), ebayCertId.value(), db);
      const host = isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com";
      const sku = `wonni_${listingId}`;

      const title = listing.customTitle || "Wonni Listing";
      const description = listing.customDescription || "Listed via Wonni";
      const price = listing.price || 0.0;
      const brand = listing.brand || "Generic";
      const quantity = listing.quantity ?? 1;
      console.log(`[ebayUpdateListing] listing.quantity raw=${listing.quantity}, resolved quantity=${quantity}`);
      const weightLbs = listing.shippingInfo?.weightLbs || 1.0;
      const lengthIn = listing.shippingInfo?.packageDimensions?.lengthIn || 8.0;
      const widthIn = listing.shippingInfo?.packageDimensions?.widthIn || 6.0;
      const heightIn = listing.shippingInfo?.packageDimensions?.heightIn || 4.0;

      const conditionMap = {
        new: "NEW", newWithoutTags: "USED_EXCELLENT", likeNew: "USED_EXCELLENT",
        good: "USED_GOOD", fair: "USED_ACCEPTABLE", poor: "USED_ACCEPTABLE",
        forParts: "FOR_PARTS_OR_NOT_WORKING"
      };
      const condition = conditionMap[listing.condition] || "USED_EXCELLENT";

      // 1. Update inventory item (title, description, condition, brand, dimensions).
      const photoPaths = listing.photoPaths || [];
      const bucket = admin.storage().bucket();
      const imageUrls = photoPaths.map(path =>
        `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(path)}?alt=media`
      );

      const itemBody = {
        availability: { shipToLocationAvailability: { quantity: quantity } },
        condition: condition,
        product: {
          title: title.slice(0, 80),
          description: description.slice(0, 1000),
          imageUrls: imageUrls.slice(0, 12),
          brand: brand,
          mpn: "Does Not Apply",
          aspects: { Brand: [brand] }
        },
        packageWeightAndSize: {
          weight: { value: weightLbs, unit: "POUND" },
          dimensions: { length: lengthIn, width: widthIn, height: heightIn, unit: "INCH" }
        }
      };
      if (listing.conditionNotes) {
        itemBody.conditionDescription = listing.conditionNotes;
      }

      console.log(`[ebayUpdateListing] Updating inventory item SKU=${sku}`);
      const itemRes = await makeHttpRequest({
        hostname: host,
        path: `/sell/inventory/v1/inventory_item/${sku}`,
        method: "PUT",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
          "Content-Language": "en-US"
        }
      }, itemBody);
      if (![200, 201, 204].includes(itemRes.statusCode)) {
        throw new Error(`Failed to update eBay inventory item (${itemRes.statusCode}): ${itemRes.body}`);
      }

      // 2. Look up the existing offer so we can update price and description.
      const offersRes = await makeHttpRequest({
        hostname: host,
        path: `/sell/inventory/v1/offer?sku=${encodeURIComponent(sku)}`,
        method: "GET",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json"
        }
      });
      if (offersRes.statusCode !== 200) {
        throw new Error(`Failed to retrieve eBay offers (${offersRes.statusCode}): ${offersRes.body}`);
      }
      const offersData = JSON.parse(offersRes.body);
      const offer = (offersData.offers || []).find(o => o.status === "PUBLISHED") || offersData.offers?.[0];
      if (!offer?.offerId) {
        throw new Error("No eBay offer found for this listing. It may have been manually ended.");
      }
      const offerId = offer.offerId;
      console.log(`[ebayUpdateListing] Updating offerId=${offerId} with availableQuantity=${quantity}`);

      // 3. Update the offer (price, description, policies preserved from the existing offer).
      const offerUpdateBody = {
        sku: sku,
        marketplaceId: "EBAY_US",
        format: "FIXED_PRICE",
        availableQuantity: quantity,
        categoryId: offer.categoryId,
        listingDescription: description,
        listingPolicies: offer.listingPolicies,
        merchantLocationKey: offer.merchantLocationKey,
        pricingSummary: {
          price: { value: price.toFixed(2), currency: "USD" }
        }
      };
      const offerUpdateRes = await makeHttpRequest({
        hostname: host,
        path: `/sell/inventory/v1/offer/${offerId}`,
        method: "PUT",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
          "Content-Language": "en-US"
        }
      }, offerUpdateBody);
      if (![200, 204].includes(offerUpdateRes.statusCode)) {
        throw new Error(`Failed to update eBay offer (${offerUpdateRes.statusCode}): ${offerUpdateRes.body}`);
      }

      console.log(`[ebayUpdateListing] Offer update response: ${offerUpdateRes.statusCode}, body=${offerUpdateRes.body || '(empty)'}`);

      // 4. Use bulkUpdatePriceQuantity for a more reliable quantity + price sync
      //    on published offers. eBay recommends this endpoint for live listings.
      const bulkBody = {
        requests: [
          {
            sku: sku,
            shipToLocationAvailability: { quantity: quantity },
            offers: [
              {
                offerId: offerId,
                availableQuantity: quantity,
                price: { value: price.toFixed(2), currency: "USD" }
              }
            ]
          }
        ]
      };
      const bulkRes = await makeHttpRequest({
        hostname: host,
        path: "/sell/inventory/v1/bulk_update_price_quantity",
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
          "Content-Language": "en-US"
        }
      }, bulkBody);
      console.log(`[ebayUpdateListing] bulkUpdatePriceQuantity response: ${bulkRes.statusCode}, body=${bulkRes.body || '(empty)'}`);

      console.log(`[ebayUpdateListing] Updated successfully for listing ${listingId}`);
      await listingRef.set({ updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
      return { success: true };

    } catch (err) {
      console.error(`[ebayUpdateListing] Error:`, err);
      let code = "internal";
      if (err instanceof HttpsError) { code = err.code; }
      throw new HttpsError(code, err.message);
    }
  }
);

/**
 * Callable Function: ebayDeleteListing
 * Expects: { listingId: string }
 */
exports.ebayDeleteListing = onCall(
  { secrets: [ebayClientId, ebayCertId] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;
    const { listingId } = request.data;
    if (!listingId) {
      throw new HttpsError("invalid-argument", "listingId is required.");
    }

    const db = admin.firestore();
    const listingRef = db.collection("listings").doc(listingId);
    const listingDoc = await listingRef.get();
    if (!listingDoc.exists) {
      throw new HttpsError("not-found", "Listing not found.");
    }
    const listing = listingDoc.data();
    if (listing.userId !== uid) {
      throw new HttpsError("permission-denied", "You do not own this listing.");
    }

    const ebayListingId = listing.crossPostListingIds?.ebay;
    if (!ebayListingId) {
      return { success: true, message: "Listing not posted to eBay." };
    }

    // Set to pending/removing state
    await listingRef.set({
      crossPostStatus: {
        ebay: "removing" // Temporary state
      }
    }, { merge: true });

    try {
      const { accessToken, isSandbox } = await getActiveAccessToken(uid, ebayClientId.value(), ebayCertId.value(), db);
      const host = isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com";
      const sku = `wonni_${listingId}`;

      // 1. Get offers by SKU
      const getOffersOptions = {
        hostname: host,
        path:     `/sell/inventory/v1/offer?sku=${sku}`,
        method:   "GET",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type":  "application/json",
        },
      };

      const getOffersRes = await makeHttpRequest(getOffersOptions);
      if (getOffersRes.statusCode === 200) {
        const data = JSON.parse(getOffersRes.body);
        const offers = data.offers || [];
        for (const offer of offers) {
          if (offer.status === "ACTIVE") {
            console.log(`[ebayDeleteListing] Withdrawing active offer: ${offer.offerId}`);
            const withdrawOptions = {
              hostname: host,
              path:     `/sell/inventory/v1/offer/${offer.offerId}/withdraw`,
              method:   "POST",
              headers: {
                "Authorization": `Bearer ${accessToken}`,
                "Content-Type":  "application/json",
              },
            };
            await makeHttpRequest(withdrawOptions, {});
          }
          
          console.log(`[ebayDeleteListing] Deleting offer: ${offer.offerId}`);
          const deleteOptions = {
            hostname: host,
            path:     `/sell/inventory/v1/offer/${offer.offerId}`,
            method:   "DELETE",
            headers: {
              "Authorization": `Bearer ${accessToken}`,
              "Content-Type":  "application/json",
            },
          };
          await makeHttpRequest(deleteOptions);
        }
      }

      // 2. Delete inventory item
      console.log(`[ebayDeleteListing] Deleting inventory item: ${sku}`);
      const deleteItemOptions = {
        hostname: host,
        path:     `/sell/inventory/v1/inventory_item/${sku}`,
        method:   "DELETE",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type":  "application/json",
        },
      };
      await makeHttpRequest(deleteItemOptions);

      // 3. Update Firestore
      const crossPostRef = db.collection("users").doc(uid).collection("crossPosts").doc(`${listingId}_ebay`);
      await crossPostRef.set({
        listingId: listingId,
        platform: "ebay",
        status: "removed",
        createdAt: admin.firestore.FieldValue.serverTimestamp()
      });

      // Remove from UserListing maps
      const updatedStatus = { ...listing.crossPostStatus };
      delete updatedStatus.ebay;
      
      const updatedListingIds = { ...listing.crossPostListingIds };
      delete updatedListingIds.ebay;

      await listingRef.update({
        crossPostStatus: updatedStatus,
        crossPostListingIds: updatedListingIds
      });

      return { success: true };
    } catch (err) {
      console.error(`[ebayDeleteListing] Error deleting eBay listing:`, err);
      // Reset back to posted since delete failed
      await listingRef.set({
        crossPostStatus: {
          ebay: "posted"
        }
      }, { merge: true });
      
      let code = "internal";
      if (err instanceof HttpsError) {
        code = err.code;
      } else if (err.code && typeof err.code === "string") {
        const validCodes = [
          "ok", "cancelled", "unknown", "invalid-argument", "deadline-exceeded",
          "not-found", "already-exists", "permission-denied", "resource-exhausted",
          "failed-precondition", "aborted", "out-of-range", "unimplemented",
          "internal", "unavailable", "data-loss", "unauthenticated"
        ];
        if (validCodes.includes(err.code)) {
          code = err.code;
        }
      }
      throw new HttpsError(code, err.message);
    }
  }
);
