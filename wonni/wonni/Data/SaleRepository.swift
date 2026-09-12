//
//  SaleRepository.swift
//  wonni
//

import Foundation
import FirebaseFirestore
import FirebaseAuth
import FirebaseFunctions

class SaleRepository: ObservableObject {
    static let shared = SaleRepository()

    private let db = Firestore.firestore()
    private let col = "sales"

    func recordSale(_ sale: Sale) async throws -> String {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "SaleRepository", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }
        var s = sale
        s.userId = userId
        s.createdAt = Timestamp(date: Date())
        s.updatedAt = Timestamp(date: Date())
        let ref = db.collection(col).document()
        // The non-`await` Codable setData(from:) overload only synchronously encodes and
        // kicks off a fire-and-forget local-cache write — `try` here only ever caught encoding
        // errors, never a failed server write. Using the async overload actually confirms the
        // write landed before this function returns (github issue #24).
        try await ref.setData(from: s)
        return ref.documentID
    }

    func fetchSales() async throws -> [Sale] {
        guard let userId = Auth.auth().currentUser?.uid else { return [] }
        let snap = try await db.collection(col)
            .whereField("userId", isEqualTo: userId)
            .order(by: "soldAt", descending: true)
            .getDocuments()
        let sales = snap.documents
            .compactMap { try? $0.data(as: Sale.self) }
            .filter { !($0.isDeleted == true) }

        return sales
    }

    func fetchHiddenSales() async throws -> [Sale] {
        guard let userId = Auth.auth().currentUser?.uid else { return [] }
        let snap = try await db.collection(col)
            .whereField("userId", isEqualTo: userId)
            .getDocuments()
        return snap.documents
            .compactMap { try? $0.data(as: Sale.self) }
            .filter { $0.isDeleted == true }
            .sorted { ($0.soldAt.dateValue()) > ($1.soldAt.dateValue()) }
    }

    func updateSale(id: String, data: [String: Any]) async throws {
        var d = data
        d["updatedAt"] = Timestamp(date: Date())
        try await db.collection(col).document(id).updateData(d)
    }

    /// The ONE path for moving a sale between stage-board buckets (tap-to-move
    /// board, or the status picker in SaleDetailSheet) — mirrors web's
    /// Sales.jsx handleStatusChange. Routes through the validated
    /// `updateSaleStatus` Cloud Function instead of a raw `updateData` so the
    /// server checks the target key against this user's `saleStages` and, on
    /// a move into cancelled/returned, auto re-fetches the real take-home
    /// (docs/specs/2026-09-11-stage-board-and-revenue-accounting.md §4/§6).
    func updateSaleStatus(id: String, status: String) async throws {
        _ = try await Functions.functions()
            .httpsCallable("updateSaleStatus")
            .call(["saleId": id, "status": status])
    }

    /// One-shot read of this user's stage-board buckets, falling back to the
    /// built-ins — mirrors sale_stages.js's loadSaleStages. Not a live
    /// listener; callers that need live updates (a persistent board screen)
    /// should watch `users/{uid}` themselves instead.
    func fetchSaleStages() async -> [SaleStage] {
        guard let userId = Auth.auth().currentUser?.uid else { return SaleStages.builtIn }
        guard let snap = try? await db.collection("users").document(userId).getDocument() else {
            return SaleStages.builtIn
        }
        return SaleStages.parse(snap.data())
    }

    func hideSale(id: String) async throws {
        try await db.collection(col).document(id).updateData([
            "isDeleted": true,
            "updatedAt": Timestamp(date: Date()),
        ])
    }

    func restoreSale(id: String) async throws {
        try await db.collection(col).document(id).updateData([
            "isDeleted": FieldValue.delete(),
            "deletedAt": FieldValue.delete(),
            "updatedAt": Timestamp(date: Date()),
        ])
    }

    // Hard-deletes a sale doc. Used for permanently purging malformed/incorrect imports —
    // unlike hideSale, this removes the platformOrderId from knownMercariIds entirely,
    // so the item can be re-scanned and re-imported on the next sync.
    func permanentlyDeleteSale(id: String) async throws {
        try await db.collection(col).document(id).delete()
    }

    // Shared write path for every import flow (bulk/single Mercari import, auto-import,
    // fix-and-import). NOTE: `recordSale` above is a *separate* path used by call sites that
    // already call `decrementAndCascade` themselves (RecordSaleSheet, CrossPostWebView's
    // sold-status-drift flows) — the decrement hook only lives here to avoid double-decrementing
    // those sites (github issue #50).
    func addSale(_ sale: Sale) async throws {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "SaleRepository", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }
        var s = sale
        s.userId = userId
        s.createdAt = Timestamp(date: Date())
        s.updatedAt = Timestamp(date: Date())

        try await db.collection(col).document().setData(from: s)
        print("[SaleRepository.addSale] Sale saved successfully")

        if s.platform == "mercari", let productId = s.linkedProductId, !productId.isEmpty {
            do {
                _ = try await Functions.functions()
                    .httpsCallable("decrementAndCascade")
                    .call(["productId": productId, "platform": "mercari"])
            } catch {
                print("[SaleRepository.addSale] decrementAndCascade failed: \(error)")
                // Sale doc already persisted — don't fail the caller over a cascade error.
            }
        }
    }

    /// Used to avoid double-decrementing a listing's quantity: if a Sale already exists for
    /// this listing/platform, `addSale`'s decrement hook has already fired, so callers like
    /// `SoldOnMercariHandlerSheet` should skip their own "subtract 1?" prompt.
    func hasSale(listingId: String, platform: String) async -> Bool {
        guard let userId = Auth.auth().currentUser?.uid else { return false }
        // Canonical field is `productId`; the backfill copied it onto every old
        // `listingId`-only doc, and backend-created sales only ever have it.
        let snap = try? await db.collection(col)
            .whereField("userId", isEqualTo: userId)
            .whereField("productId", isEqualTo: listingId)
            .whereField("platform", isEqualTo: platform)
            .limit(to: 1)
            .getDocuments()
        return !(snap?.documents.isEmpty ?? true)
    }
}
