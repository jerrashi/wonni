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
        return snap.documents
            .compactMap { try? $0.data(as: Sale.self) }
            .filter { !($0.isDeleted == true) }
    }

    func fetchDeletedSales() async throws -> [Sale] {
        guard let userId = Auth.auth().currentUser?.uid else { return [] }
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        // Single-field equality query avoids a composite index requirement.
        // isDeleted and deletedAt age are filtered client-side.
        let snap = try await db.collection(col)
            .whereField("userId", isEqualTo: userId)
            .getDocuments()
        let all: [Sale] = snap.documents.compactMap { try? $0.data(as: Sale.self) }
        var deleted: [Sale] = []
        for sale in all {
            guard sale.isDeleted == true else { continue }
            let deletedDate = sale.deletedAt?.dateValue() ?? .distantPast
            if deletedDate > thirtyDaysAgo { deleted.append(sale) }
        }
        return deleted.sorted { ($0.deletedAt?.dateValue() ?? .distantPast) > ($1.deletedAt?.dateValue() ?? .distantPast) }
    }

    func updateSale(id: String, data: [String: Any]) async throws {
        var d = data
        d["updatedAt"] = Timestamp(date: Date())
        try await db.collection(col).document(id).updateData(d)
    }

    func deleteSale(id: String) async throws {
        try await db.collection(col).document(id).updateData([
            "isDeleted": true,
            "deletedAt": Timestamp(date: Date()),
            "updatedAt": Timestamp(date: Date())
        ])
    }

    func restoreSale(id: String) async throws {
        try await db.collection(col).document(id).updateData([
            "isDeleted": FieldValue.delete(),
            "deletedAt": FieldValue.delete(),
            "updatedAt": Timestamp(date: Date())
        ])
    }
}
