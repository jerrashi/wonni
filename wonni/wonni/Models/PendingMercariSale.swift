//
//  PendingMercariSale.swift
//  wonni
//
//  Durable record of a Mercari sale discovered by a sync scan but not yet imported
//  (or actively rejected) — lives at users/{uid}/pendingMercariSales/{mercariItemId}
//  so the "+" import modal's list survives app restarts (github issue #50).
//

import Foundation
import FirebaseFirestore

struct PendingMercariSale: Identifiable, Codable {
    @DocumentID var id: String?   // == Mercari item id, so re-scans upsert idempotently
    var name: String?
    var price: Double?
    var thumbnailUrl: String?
    var takeHome: Double?
    var soldAt: Timestamp?
    var statusText: String?
    var enrichFailed: Bool?
    var discoveredAt: Timestamp?
}

extension MercariFoundSaleItem {
    init(pending: PendingMercariSale) {
        self.init(
            id: pending.id ?? "",
            name: pending.name,
            price: pending.price,
            thumbnailUrl: pending.thumbnailUrl,
            takeHome: pending.takeHome,
            soldAt: pending.soldAt?.dateValue(),
            statusText: pending.statusText,
            enrichFailed: pending.enrichFailed ?? false
        )
    }
}

extension PendingMercariSale {
    init(item: MercariFoundSaleItem) {
        self.init(
            id: item.id,
            name: item.name,
            price: item.price,
            thumbnailUrl: item.thumbnailUrl,
            takeHome: item.takeHome,
            soldAt: item.soldAt.map { Timestamp(date: $0) },
            statusText: item.statusText,
            enrichFailed: item.enrichFailed,
            discoveredAt: Timestamp(date: Date())
        )
    }
}
