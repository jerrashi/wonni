//
//  PendingMercariSaleRepository.swift
//  wonni
//
//  Durable store for Mercari sales discovered by a sync scan but not yet imported —
//  backs the "+" import modal's list so it survives app restarts instead of living only
//  in an 8-second toast's in-memory state (github issue #50).
//

import Foundation
import FirebaseFirestore
import FirebaseAuth

@MainActor
class PendingMercariSaleRepository: ObservableObject {
    static let shared = PendingMercariSaleRepository()

    private let db = Firestore.firestore()

    private func col() -> CollectionReference? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return db.collection("users").document(uid).collection("pendingMercariSales")
    }

    func fetchAll() async -> [MercariFoundSaleItem] {
        guard let col = col() else { return [] }
        guard let snap = try? await col.getDocuments() else { return [] }
        return snap.documents
            .compactMap { try? $0.data(as: PendingMercariSale.self) }
            .map { MercariFoundSaleItem(pending: $0) }
    }

    func upsert(_ items: [MercariFoundSaleItem]) async {
        guard let col = col(), !items.isEmpty else { return }
        let batch = db.batch()
        for item in items {
            let doc = col.document(item.id)
            guard let data = try? Firestore.Encoder().encode(PendingMercariSale(item: item)) else { continue }
            batch.setData(data, forDocument: doc, merge: true)
        }
        try? await batch.commit()
    }

    func delete(_ itemId: String) async {
        guard let col = col() else { return }
        try? await col.document(itemId).delete()
    }

    /// Single shared discovery entry point — called from both the dashboard's sync (when
    /// auto-import is off) and the "+" modal's own "Sync" button, so scan+persist logic
    /// isn't duplicated per call site.
    func discoverAndPersist(
        using manager: MercariSaleSyncManager,
        knownOrderIds: Set<String>,
        stopBeforeDate: Date?
    ) async -> [MercariFoundSaleItem] {
        let found = await manager.scanForNewSales(knownOrderIds: knownOrderIds, stopBeforeDate: stopBeforeDate)
        if !found.isEmpty { await upsert(found) }
        return found
    }
}
