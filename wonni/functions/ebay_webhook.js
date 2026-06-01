/**
 * ebay_webhook.js
 * 
 * Firebase Cloud Function for handling eBay's Marketplace Account Deletion/Closure notifications.
 * Satisfies eBay's verification challenge (GET) and parses account deletion notifications (POST).
 */

const functions = require('firebase-functions');
const admin = require('firebase-admin');
const crypto = require('crypto');

// Initialize admin if not already initialized
if (admin.apps.length === 0) {
  admin.initializeApp();
}

/**
 * HTTP Cloud Function to handle eBay notifications
 * Endpoint URL: https://<region>-<project-id>.cloudfunctions.net/ebayWebhook
 */
exports.ebayWebhook = functions.https.onRequest(async (req, res) => {
  // ── 1. HANDLE VERIFICATION CHALLENGE (GET) ──────────────────────────
  if (req.method === 'GET') {
    const challengeCode = req.query.challenge_code;
    
    // Retrieve values securely via process.env
    const verificationToken = process.env.EBAY_VERIFICATION_TOKEN || 'YOUR_EBAY_VERIFICATION_TOKEN';
    const endpointUrl = process.env.EBAY_ENDPOINT_URL || 'https://YOUR_FUNCTION_ENDPOINT_URL';
    
    if (!challengeCode) {
      console.error('[eBay Webhook] Missing challenge_code query parameter');
      return res.status(400).send('Missing challenge_code');
    }
    
    console.log(`[eBay Webhook] Processing challenge verification for code: ${challengeCode}`);
    
    try {
      // eBay Signature Calculation:
      // SHA-256 hash of challengeCode + verificationToken + endpointUrl
      const hash = crypto.createHash('sha256');
      hash.update(challengeCode);
      hash.update(verificationToken);
      hash.update(endpointUrl);
      const responseHash = hash.digest('hex');
      
      res.setHeader('Content-Type', 'application/json');
      return res.status(200).json({
        challengeResponse: responseHash
      });
    } catch (err) {
      console.error('[eBay Webhook] Failed to compute hash:', err);
      return res.status(500).send('Internal Server Error');
    }
  }

  // ── 2. HANDLE ACCOUNT DELETION NOTIFICATION (POST) ──────────────────
  if (req.method === 'POST') {
    // Note: eBay sends a signature in the header 'X-EBAY-SIGNATURE' to verify the sender is eBay.
    // For basic compliance, you must receive the body and flag/remove the matching user data.
    const notification = req.body;
    
    console.log('[eBay Webhook] Received notification payload:', JSON.stringify(notification));
    
    // Check if the event type matches account deletion
    if (notification.metadata && notification.metadata.topic === 'MARKETPLACE_ACCOUNT_DELETION') {
      const ebayUserId = notification.notification.data.userId;
      console.log(`[eBay Webhook] Processing deletion request for eBay User ID: ${ebayUserId}`);
      
      try {
        // Query Firestore to find the Wonni user connected to this eBay account
        const db = admin.firestore();
        const querySnapshot = await db.collectionGroup('integrations')
          .where('platform', '==', 'ebay')
          .where('connectedUsername', '==', ebayUserId) // or other matching identifier
          .get();
          
        if (querySnapshot.empty) {
          console.log(`[eBay Webhook] No connected Wonni user found for eBay User ID: ${ebayUserId}`);
        } else {
          const batch = db.batch();
          for (const doc of querySnapshot.docs) {
            console.log(`[eBay Webhook] Unlinking integration for Wonni user: ${doc.ref.parent.parent.id}`);
            batch.delete(doc.ref);
          }
          await batch.commit();
        }
      } catch (err) {
        console.error('[eBay Webhook] Database transaction failed:', err);
        return res.status(500).send('Failed to update records');
      }
    }
    
    // Always return 200 OK to acknowledge receipt to eBay
    return res.status(200).send('Notification processed');
  }

  // ── 3. METHOD NOT ALLOWED ───────────────────────────────────────────
  res.setHeader('Allow', 'GET, POST');
  return res.status(405).send('Method Not Allowed');
});
