//
//  InventoryUnit.swift
//  wonni
//
//  Represents a seller's physical stock of one specific variant of a CatalogItem.
//  The bridge between the global catalog and a user's listings.
//
//  Quantity invariant:
//      quantityAvailable = quantityTotal - quantityReserved - quantitySold
//

import Foundation
import FirebaseFirestore

struct InventoryUnit: Identifiable, Codable {

    // ── Identity ─────────────────────────────────────────────────────────────
    @DocumentID var id: String?
    var userId: String              // FK → /users/{userId}
    var catalogItemId: String       // FK → /catalog/{catalogItemId}

    // ── Variant ───────────────────────────────────────────────────────────────
    // Keys match the variantDimension names on the CatalogItem.
    // e.g. {"Size": "M", "Color": "Red"}
    // Empty dict means "no variant" (item has no dimensions).
    var variantValues: [String: String]

    // ── Quantity tracking ─────────────────────────────────────────────────────
    var quantityTotal: Int          // Total owned by this seller
    var quantityReserved: Int       // In an active cart or pending order
    var quantitySold: Int           // Historical sold count

    /// Computed locally — not stored in Firestore.
    var quantityAvailable: Int { quantityTotal - quantityReserved - quantitySold }

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    var createdAt: Timestamp?
    var updatedAt: Timestamp?

    // ── CodingKeys (exclude computed property) ────────────────────────────────
    enum CodingKeys: String, CodingKey {
        case id, userId, catalogItemId, variantValues
        case quantityTotal, quantityReserved, quantitySold
        case createdAt, updatedAt
    }
}
