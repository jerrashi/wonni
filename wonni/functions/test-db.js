const admin = require("firebase-admin");

if (admin.apps.length === 0) {
  admin.initializeApp({
    projectId: "wonni-app"
  });
}

const db = admin.firestore();

async function run() {
  console.log("=== Inspecting Firestore Users and Integrations ===");
  try {
    const usersSnapshot = await db.collection("users").get();
    if (usersSnapshot.empty) {
      console.log("No users found in Firestore.");
    } else {
      for (const userDoc of usersSnapshot.docs) {
        const uid = userDoc.id;
        console.log(`\nUser: ${uid}`);
        
        // Load default selling settings
        const settingsDoc = await db.collection("users").doc(uid).collection("sellingSettings").doc("default").get();
        if (settingsDoc.exists) {
          const settings = settingsDoc.data();
          console.log("  Selling Settings (default):", JSON.stringify({
            hasLocation: !!settings.defaultLocation,
            postalCode: settings.defaultLocation?.postalCode,
            shippingType: settings.shippingType,
            buyerPaysShipping: settings.buyerPaysShipping,
            ebayPolicyIds: settings.ebayPolicyIds,
            businessPoliciesDisabled: settings.businessPoliciesDisabled
          }, null, 2));
        } else {
          console.log("  Selling Settings (default): Not set");
        }

        // Load integrations
        const integrationsSnapshot = await db.collection("users").doc(uid).collection("integrations").get();
        if (integrationsSnapshot.empty) {
          console.log("  Integrations: None");
        } else {
          console.log("  Integrations:");
          for (const intDoc of integrationsSnapshot.docs) {
            const data = intDoc.data();
            console.log(`    - ${intDoc.id}:`, JSON.stringify({
              platform: data.platform,
              isConnected: data.isConnected,
              connectedUsername: data.connectedUsername,
              isSandbox: data.isSandbox,
              hasAccessToken: !!data.accessToken,
              hasRefreshToken: !!data.refreshToken,
              tokenExpiresAt: data.tokenExpiresAt ? data.tokenExpiresAt.toDate().toISOString() : null
            }, null, 2));
          }
        }
      }
    }

    console.log("\n=== Inspecting Recent Listings ===");
    const listingsSnapshot = await db.collection("listings").limit(5).get();
    if (listingsSnapshot.empty) {
      console.log("No listings found in Firestore.");
    } else {
      for (const listingDoc of listingsSnapshot.docs) {
        const data = listingDoc.data();
        console.log(`Listing ID: ${listingDoc.id}`);
        console.log(`  Title: ${data.customTitle || data.title}`);
        console.log(`  Price: $${data.price}`);
        console.log(`  User: ${data.userId}`);
        console.log(`  Cross-post Status:`, JSON.stringify(data.crossPostStatus || {}));
        console.log(`  Cross-post IDs:`, JSON.stringify(data.crossPostListingIds || {}));
      }
    }
  } catch (error) {
    console.error("Error inspecting Firestore:", error);
  }
}

run();
