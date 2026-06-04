//
//  MercariObservedDataRepository.swift
//  wonni
//

import Foundation
import FirebaseFirestore

@MainActor
class MercariObservedDataRepository: ObservableObject {
    static let shared = MercariObservedDataRepository()

    private(set) var observedBrands: Set<String> = []
    private var isFetched = false

    private init() {}

    /// Call at app launch — loads the known brand set from Firestore into memory once.
    func fetchBrandsIfNeeded() async {
        guard !isFetched else { return }
        isFetched = true
        do {
            let doc = try await Firestore.firestore()
                .collection("system").document("mercariObservedBrands").getDocument()
            if let brands = doc.data()?["brands"] as? [String] {
                observedBrands = Set(brands)
            }
        } catch {
            print("[MercariObservedDataRepository] Failed to fetch brands: \(error)")
        }
    }

    /// Call after a Mercari brand is selected. Diffs against the known set and writes only new entries.
    func observeAndStore(brands newBrands: [String]) {
        let fresh = Set(newBrands.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let toAdd = fresh.subtracting(observedBrands)
        guard !toAdd.isEmpty else { return }

        observedBrands.formUnion(toAdd)
        let allBrands = Array(observedBrands)

        Task {
            do {
                try await Firestore.firestore()
                    .collection("system").document("mercariObservedBrands")
                    .setData(["brands": allBrands, "updatedAt": Timestamp(date: Date())], merge: true)
                print("[MercariObservedDataRepository] Stored \(toAdd.count) new brand(s)")
            } catch {
                print("[MercariObservedDataRepository] Failed to store brands: \(error)")
            }
        }
    }
}
