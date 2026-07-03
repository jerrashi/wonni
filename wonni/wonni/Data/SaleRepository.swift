//
//  SaleRepository.swift
//  wonni
//

import Foundation
import FirebaseFirestore
import FirebaseAuth

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
        try ref.setData(from: s)
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

        // DEBUG: Log thumbnailUrl retrieval
        for sale in sales {
            if sale.platform == "mercari" {
                print("[SaleRepository.fetchSales] Mercari sale ID: \(sale.id ?? "nil")")
                print("[SaleRepository.fetchSales]   Title: \(sale.listingTitle ?? "nil")")
                print("[SaleRepository.fetchSales]   coverPhotoPath: \(sale.coverPhotoPath ?? "nil")")
                print("[SaleRepository.fetchSales]   thumbnailUrl: \(sale.thumbnailUrl ?? "nil")")
            }
        }

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

    func addSale(_ sale: Sale) async throws {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "SaleRepository", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }
        var s = sale
        s.userId = userId
        s.createdAt = Timestamp(date: Date())
        s.updatedAt = Timestamp(date: Date())

        // DEBUG: Log what we're about to save to Firestore
        print("[SaleRepository.addSale] Saving sale with:")
        print("[SaleRepository.addSale]   platform: \(s.platform)")
        print("[SaleRepository.addSale]   listingTitle: \(s.listingTitle ?? "nil")")
        print("[SaleRepository.addSale]   coverPhotoPath: \(s.coverPhotoPath ?? "nil")")
        print("[SaleRepository.addSale]   thumbnailUrl: \(s.thumbnailUrl ?? "nil")")

        try db.collection(col).document().setData(from: s)
        print("[SaleRepository.addSale] Sale saved successfully")
    }
}
