#!/usr/bin/env node
/**
 * Migration script: Transform all products from old schema to new unified schema
 *
 * Run with: node functions/migrate_product_schema.js --project wonni-app
 *
 * This script:
 * 1. Reads all products from Firestore
 * 2. Transforms them to the new schema
 * 3. Writes them back to Firestore
 * 4. Logs progress and errors
 */

const admin = require("firebase-admin");
const { buildNewProductDoc, extractSourceImages } = require("./product_schema");

const args = process.argv.slice(2);
const projectId = args[args.indexOf("--project") + 1] || "wonni-app";

console.log(`Migrating products in project: ${projectId}`);

// Initialize Firebase
admin.initializeApp({
  projectId,
});

const db = admin.firestore();

// Transformation function: convert old product to new product
function transformProduct(oldProduct, docId) {
  try {
    // Extract source images
    const sourceImages = extractSourceImages(oldProduct.imageAssets, oldProduct.images);

    // Build new product using schema helper
    const newProduct = buildNewProductDoc({
      userId: oldProduct.userId,
      source: oldProduct.source || "unknown",
      sourceId: oldProduct.weverseSaleId || oldProduct.aliexpressProductId || docId,
      sourceUrl: oldProduct.sourceUrl,
      title: oldProduct.title,
      description: oldProduct.description,
      category: oldProduct.category,
      brand: oldProduct.brand,
      condition: oldProduct.condition,
      saleStatus: oldProduct.saleStatus,
      isDraft: oldProduct.isDraft !== false,
      sourceCost: oldProduct.sourceCost ?? oldProduct.sourcePrice ?? oldProduct.aliexpressPrice,
      listingPrice: oldProduct.listingPrice,
      sourceImages,
      images: oldProduct.images || oldProduct.listingImages || [],
      imageAssets: oldProduct.imageAssets || [],
      options: oldProduct.options || [],
      variants: oldProduct.variants || [],
      // Source-specific fields
      weverseSaleId: oldProduct.weverseSaleId,
      weverseArtistId: oldProduct.weverseArtistId,
      weverseInfoTable: oldProduct.weverseInfoTable,
      artistName: oldProduct.artistName,
      aliexpressProductId: oldProduct.aliexpressProductId,
      aliexpressUrl: oldProduct.aliexpressProductUrl || oldProduct.aliexpressUrl,
      // Pricing
      ebayStatus: oldProduct.ebayStatus,
      ebayListingId: oldProduct.ebayListingId,
      ebaySellPrice: oldProduct.ebaySellPrice,
      ebayCategoryId: oldProduct.ebayCategoryId,
      ebayHasVariations: oldProduct.ebayHasVariations,
      etsyStatus: oldProduct.etsyStatus,
      etsyListingId: oldProduct.etsyListingId,
      mercariStatus: oldProduct.mercariStatus,
      mercariListingId: oldProduct.mercariListingId,
      tiktokStatus: oldProduct.tiktokStatus || "draft",
      // AI suggestions
      aiSuggestedTitle: oldProduct.aiSuggestedTitle,
      aiSuggestedPrice: oldProduct.aiSuggestedPrice,
      aiSuggestedDescription: oldProduct.aiSuggestedDescription,
      // Metadata
      importedAt: oldProduct.importedAt,
      updatedAt: oldProduct.updatedAt || new Date(),
    });

    return { success: true, data: newProduct };
  } catch (e) {
    return { success: false, error: e.message };
  }
}

// Main migration function
async function migrate() {
  let successCount = 0;
  let errorCount = 0;
  let processedCount = 0;
  const batchSize = 100;
  const batches = [];

  try {
    console.log("Fetching all products...");
    const snapshot = await db.collection("products").get();
    const totalDocs = snapshot.size;

    console.log(`Found ${totalDocs} products to migrate`);

    if (totalDocs === 0) {
      console.log("No products to migrate.");
      process.exit(0);
    }

    // Process in batches
    let batch = db.batch();
    let batchCount = 0;

    for (const doc of snapshot.docs) {
      const result = transformProduct(doc.data(), doc.id);

      if (!result.success) {
        console.error(`❌ Error transforming ${doc.id}: ${result.error}`);
        errorCount++;
      } else {
        batch.set(doc.ref, result.data);
        successCount++;
        batchCount++;

        // Commit batch when it reaches batchSize
        if (batchCount >= batchSize) {
          batches.push(batch.commit());
          batch = db.batch();
          batchCount = 0;
        }
      }

      processedCount++;
      if (processedCount % 10 === 0) {
        console.log(`  Progress: ${processedCount}/${totalDocs}`);
      }
    }

    // Commit remaining batch
    if (batchCount > 0) {
      batches.push(batch.commit());
    }

    // Wait for all batches to complete
    console.log(`Committing ${batches.length} batches to Firestore...`);
    await Promise.all(batches);

    console.log("\n✅ Migration complete!");
    console.log(`  Total processed: ${processedCount}`);
    console.log(`  Successfully transformed: ${successCount}`);
    console.log(`  Errors: ${errorCount}`);

    if (errorCount > 0) {
      console.log(`\n⚠️  Some products failed to transform. Review errors above.`);
      process.exit(1);
    }

    process.exit(0);
  } catch (e) {
    console.error("❌ Migration failed:", e);
    process.exit(1);
  }
}

// Run migration
migrate().catch((e) => {
  console.error("Fatal error:", e);
  process.exit(1);
});
