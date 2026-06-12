//
//  ListingRepository.swift
//  wonni
//
//  Created by Antigravity on 5/7/25.
//

import Foundation
import FirebaseFirestore
import FirebaseAuth

class ListingRepository: ObservableObject {
    static let shared = ListingRepository()
    
    private let db = Firestore.firestore()
    private let listingsCollection = "listings"
    
    /// Saves a draft listing to Firestore.
    /// If the listing already has an ID, it updates the existing document.
    /// Otherwise, it creates a new document.
    func saveDraft(_ listing: UserListing) async throws -> String {
        print("[ListingRepository] saveDraft called for listing \(listing.id ?? "new")")
        guard let userId = Auth.auth().currentUser?.uid else {
            print("[ListingRepository] ERROR: User not authenticated")
            throw NSError(domain: "ListingRepository", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        
        var listingToSave = listing
        listingToSave.userId = userId
        listingToSave.updatedAt = Timestamp(date: Date())
        
        if listingToSave.createdAt == nil {
            listingToSave.createdAt = Timestamp(date: Date())
        }
        
        do {
            if let id = listing.id {
                print("[ListingRepository] Updating existing document: \(id)")
                try db.collection(listingsCollection).document(id).setData(from: listingToSave)
                print("[ListingRepository] Update successful for \(id)")
                return id
            } else {
                print("[ListingRepository] Creating new document in collection: \(listingsCollection)")
                let docRef = db.collection(listingsCollection).document()
                try docRef.setData(from: listingToSave)
                print("[ListingRepository] Creation successful: \(docRef.documentID)")
                return docRef.documentID
            }
        } catch {
            print("[ListingRepository] Firestore error: \(error)")
            throw error
        }
    }
    
    /// Partial update for photo paths.
    func updateListingPaths(listingId: String, paths: [String]) async throws {
        print("[ListingRepository] Updating photoPaths for \(listingId) with \(paths.count) paths")
        try await db.collection(listingsCollection).document(listingId).updateData([
            "photoPaths": paths,
            "coverPhotoPath": paths.first as Any,
            "updatedAt": Timestamp(date: Date())
        ])
    }
    
    /// Updates the status of a listing (e.g. to .active).
    func updateListingStatus(listingId: String, status: ListingStatus) async throws {
        print("[ListingRepository] Updating status for \(listingId) to \(status.rawValue)")
        try await updateListingData(listingId: listingId, data: [
            "status": status.rawValue,
            "publishedAt": status == .active ? Timestamp(date: Date()) : FieldValue.delete(),
            "updatedAt": Timestamp(date: Date())
        ])
    }
    
    /// Generic update for listing fields.
    func updateListingData(listingId: String, data: [String: Any]) async throws {
        try await db.collection(listingsCollection).document(listingId).updateData(data)
    }
    
    /// Fetches all active listings for the current user, sorted by most recently updated.
    func fetchActiveListings() async throws -> [UserListing] {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "ListingRepository", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }

        let snapshot = try await db.collection(listingsCollection)
            .whereField("userId", isEqualTo: userId)
            .getDocuments()

        return snapshot.documents
            .compactMap { try? $0.data(as: UserListing.self) }
            .filter { $0.status == .active }
            .sorted { ($0.updatedAt?.dateValue() ?? .distantPast) > ($1.updatedAt?.dateValue() ?? .distantPast) }
    }

    /// Fetches all sold-out listings (status == .sold) for the current user, sorted by soldAt desc.
    func fetchSoldListings() async throws -> [UserListing] {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "ListingRepository", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        let snapshot = try await db.collection(listingsCollection)
            .whereField("userId", isEqualTo: userId)
            .whereField("status", isEqualTo: ListingStatus.sold.rawValue)
            .getDocuments()
        return snapshot.documents
            .compactMap { try? $0.data(as: UserListing.self) }
            .sorted { ($0.soldAt?.dateValue() ?? .distantPast) > ($1.soldAt?.dateValue() ?? .distantPast) }
    }

    /// Restocks a sold-out listing: sets quantity and status back to active.
    /// Cross-platform quantity update is handled by the restockAndCascade cloud function.
    func restockListing(id: String, quantity: Int) async throws {
        var data: [String: Any] = [
            "quantity": quantity,
            "status": ListingStatus.active.rawValue,
            "updatedAt": Timestamp(date: Date())
        ]
        data["soldAt"] = FieldValue.delete()
        data["pendingMercariDeactivation"] = FieldValue.delete()
        data["pendingMercariRelist"] = FieldValue.delete()
        try await db.collection(listingsCollection).document(id).updateData(data)
    }

    /// Fetches all draft listings for the current user.
    func fetchDrafts() async throws -> [UserListing] {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "ListingRepository", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        
        let snapshot = try await db.collection(listingsCollection)
            .whereField("userId", isEqualTo: userId)
            .whereField("status", isEqualTo: ListingStatus.draft.rawValue)
            .order(by: "updatedAt", descending: true)
            .getDocuments()
        
        return snapshot.documents.compactMap { document in
            try? document.data(as: UserListing.self)
        }
    }
    
    /// Publishes a draft listing by setting its status to active.
    func publishListing(id: String) async throws {
        try await db.collection(listingsCollection).document(id).updateData([
            "status": ListingStatus.active.rawValue,
            "publishedAt": Timestamp(date: Date()),
            "updatedAt": Timestamp(date: Date())
        ])
    }
    
    func updateFields(
        id: String,
        title: String?,
        price: Double?,
        description: String? = nil,
        condition: ItemCondition? = nil,
        brand: String? = nil,
        category: String? = nil,
        quantity: Int? = nil,
        weightLbs: Double? = nil,
        packageDimensions: PackageDimensions? = nil,
        buyerPaysShipping: Bool? = nil,
        photoPaths: [String]? = nil,
        coverPhotoPath: String? = nil
    ) async throws {
        var data: [String: Any] = ["updatedAt": Timestamp(date: Date())]
        if let title { data["customTitle"] = title }
        if let price { data["price"] = price }
        if let description { data["customDescription"] = description }
        if let condition { data["condition"] = condition.rawValue }
        if let brand { data["brand"] = brand }
        if let category { data["category"] = category }
        if let quantity { data["quantity"] = quantity }
        if let photoPaths { data["photoPaths"] = photoPaths }
        if let coverPhotoPath { data["coverPhotoPath"] = coverPhotoPath }
        
        if buyerPaysShipping != nil || weightLbs != nil || packageDimensions != nil {
            let doc = try await db.collection(listingsCollection).document(id).getDocument()
            let listing = try? doc.data(as: UserListing.self)
            var shipping = listing?.shippingInfo ?? ShippingInfo(buyerPaysShipping: true, handlingFee: 0, estimatedShippingDays: 3, weightLbs: nil, packageDimensions: nil)
            
            if let bp = buyerPaysShipping { shipping.buyerPaysShipping = bp }
            if let w = weightLbs { shipping.weightLbs = w }
            if let pd = packageDimensions { shipping.packageDimensions = pd }
            
            if let encoded = try? Firestore.Encoder().encode(shipping) {
                data["shippingInfo"] = encoded
            }
        }
        
        try await db.collection(listingsCollection).document(id).updateData(data)
    }

    // MARK: - Feed Pagination

    /// A single page of feed results with a cursor for the next page.
    struct FeedPage {
        let listings: [UserListing]
        let lastDocument: DocumentSnapshot?
        let hasMore: Bool
    }

    /// Fetches one page of the public feed (all active listings, newest published first).
    /// Pass `after` the DocumentSnapshot from the previous page to paginate.
    /// Requires composite index: status ASC + publishedAt DESC (see firestore.indexes.json).
    func fetchFeedPage(after lastDoc: DocumentSnapshot? = nil, limit: Int = 20) async throws -> FeedPage {
        var query: Query = db.collection(listingsCollection)
            .whereField("status", isEqualTo: ListingStatus.active.rawValue)
            .order(by: "publishedAt", descending: true)
            .limit(to: limit + 1)

        if let lastDoc {
            query = query.start(afterDocument: lastDoc)
        }

        let snapshot = try await query.getDocuments()
        let docs = snapshot.documents
        let hasMore = docs.count > limit
        let page = Array(docs.prefix(limit))

        return FeedPage(
            listings: page.compactMap { try? $0.data(as: UserListing.self) },
            lastDocument: page.last,
            hasMore: hasMore
        )
    }

    /// Fetches active listings for discovery, excluding the given listing ID.
    /// Query is intentionally simple (single-field) to avoid composite index requirements.
    /// When catalog items exist, filter by catalogItemId instead.
    func fetchSuggestedListings(excluding listingId: String, limit: Int = 8) async throws -> [UserListing] {
        let snapshot = try await db.collection(listingsCollection)
            .whereField("status", isEqualTo: ListingStatus.active.rawValue)
            .limit(to: limit + 1)
            .getDocuments()

        return snapshot.documents
            .compactMap { try? $0.data(as: UserListing.self) }
            .filter { $0.id != listingId }
            .prefix(limit)
            .map { $0 }
    }

    /// Fetches a single listing by its Firestore document ID.
    func fetchListing(id: String) async throws -> UserListing? {
        let doc = try await db.collection(listingsCollection).document(id).getDocument()
        return try? doc.data(as: UserListing.self)
    }

    /// Deletes a listing from Firestore and its photos from Storage.
    func deleteListing(id: String) async throws {
        let userId = Auth.auth().currentUser?.uid
        try await db.collection(listingsCollection).document(id).delete()
        if let uid = userId {
            try? await StorageService.shared.deleteListingImages(userId: uid, listingId: id)
        }
    }
    
    /// Updates a listing with data received from Gemini identification.
    func updateListingWithGeminiData(id: String, data: GeminiIdentificationResponse) async throws {
        try await db.collection(listingsCollection).document(id).updateData([
            "customTitle": data.name as Any,
            "customDescription": data.description as Any,
            "price": data.suggestedPrice as Any,
            "geminiIdentificationConfirmed": true,
            "updatedAt": Timestamp(date: Date())
        ])
    }
    
    /// Listens for real-time updates to draft listings.
    func draftsPublisher(completion: @escaping (Result<[UserListing], Error>) -> Void) -> ListenerRegistration? {
        guard let userId = Auth.auth().currentUser?.uid else {
            completion(.failure(NSError(domain: "ListingRepository", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])))
            return nil
        }
        
        return db.collection(listingsCollection)
            .whereField("userId", isEqualTo: userId)
            .whereField("status", isEqualTo: ListingStatus.draft.rawValue)
            .order(by: "updatedAt", descending: true)
            .addSnapshotListener { querySnapshot, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                
                let drafts = querySnapshot?.documents.compactMap { document in
                    try? document.data(as: UserListing.self)
                } ?? []
                
                completion(.success(drafts))
            }
    }
    

    // MARK: - Bulk Operations
    
    /// Bulk deletes multiple listings in a batch and deletes their photos from Storage.
    func bulkDelete(listingIds: [String]) async throws {
        let userId = Auth.auth().currentUser?.uid
        let batch = db.batch()
        for id in listingIds {
            let ref = db.collection(listingsCollection).document(id)
            batch.deleteDocument(ref)
        }
        try await batch.commit()
        
        if let uid = userId {
            for id in listingIds {
                try? await StorageService.shared.deleteListingImages(userId: uid, listingId: id)
            }
        }
    }
    
    /// Bulk updates listings with relative/appended values.
    func bulkUpdate(
        listingIds: [String],
        priceAdjustment: Double? = nil,
        isPercentage: Bool = false,
        isPriceSet: Bool = false,
        minimumPrice: Double = 0.01,
        maximumPrice: Double? = nil,
        titlePrepend: String? = nil,
        titleAppend: String? = nil,
        descriptionPrepend: String? = nil,
        descriptionAppend: String? = nil,
        condition: ItemCondition? = nil,
        buyerPaysShipping: Bool? = nil,
        setWeightLbs: Double? = nil,
        setPackageDimensions: (Double, Double, Double)? = nil
    ) async throws -> [String] {
        var updates: [String: [String: Any]] = [:]
        var ebayPostedIds: [String] = []

        // Fetch current states to compute new values
        for id in listingIds {
            let doc = try await db.collection(listingsCollection).document(id).getDocument()
            guard let listing = try? doc.data(as: UserListing.self) else { continue }
            if listing.crossPostStatus?["ebay"] == "posted" { ebayPostedIds.append(id) }

            var data: [String: Any] = [:]
            
            if let adj = priceAdjustment {
                var newPrice = listing.price ?? minimumPrice
                
                if isPriceSet {
                    newPrice = adj
                } else if isPercentage {
                    newPrice = newPrice * (1.0 + (adj / 100.0))
                } else {
                    newPrice = newPrice + adj
                }
                
                newPrice = max(newPrice, minimumPrice)
                if let maxP = maximumPrice {
                    newPrice = min(newPrice, maxP)
                }
                data["price"] = newPrice
            }
            
            let currentTitle = listing.customTitle ?? ""
            var newTitle = currentTitle
            if let pre = titlePrepend, !pre.isEmpty { newTitle = "\(pre) \(newTitle)".trimmingCharacters(in: .whitespaces) }
            if let app = titleAppend, !app.isEmpty { newTitle = "\(newTitle) \(app)".trimmingCharacters(in: .whitespaces) }
            if newTitle != currentTitle { data["customTitle"] = newTitle }
            
            let currentDesc = listing.customDescription ?? ""
            var newDesc = currentDesc
            if let pre = descriptionPrepend, !pre.isEmpty { newDesc = "\(pre)\n\n\(newDesc)".trimmingCharacters(in: .whitespaces) }
            if let app = descriptionAppend, !app.isEmpty { newDesc = "\(newDesc)\n\n\(app)".trimmingCharacters(in: .whitespaces) }
            if newDesc != currentDesc { data["customDescription"] = newDesc }
            
            if let newCondition = condition {
                data["condition"] = newCondition.rawValue
            }
            
            if buyerPaysShipping != nil || setWeightLbs != nil || setPackageDimensions != nil {
                var info = listing.shippingInfo ?? ShippingInfo(buyerPaysShipping: true, handlingFee: 0, estimatedShippingDays: 3)
                if let buyerPays = buyerPaysShipping { info.buyerPaysShipping = buyerPays }
                if let w = setWeightLbs { info.weightLbs = w }
                if let (l, w, h) = setPackageDimensions {
                    info.packageDimensions = PackageDimensions(lengthIn: l, widthIn: w, heightIn: h)
                }
                data["shippingInfo"] = try? Firestore.Encoder().encode(info)
            }
            
            if !data.isEmpty {
                data["updatedAt"] = FieldValue.serverTimestamp()
                updates[id] = data
            }
        }
        
        guard !updates.isEmpty else { return ebayPostedIds }
        
        // Apply computed updates in a batch
        let batch = db.batch()
        for (id, data) in updates {
            let ref = db.collection(listingsCollection).document(id)
            batch.updateData(data, forDocument: ref)
        }
        try await batch.commit()
        return ebayPostedIds
    }

    func findListingByMercariId(_ mercariId: String) async -> (listingId: String, coverPhotoPath: String?)? {
        let snap = try? await db.collection(listingsCollection)
            .whereField("crossPostListingIds.mercari", isEqualTo: mercariId)
            .limit(to: 1)
            .getDocuments()
        guard let doc = snap?.documents.first,
              let listing = try? doc.data(as: UserListing.self),
              let id = listing.id else { return nil }
        return (listingId: id, coverPhotoPath: listing.coverPhotoPath)
    }
}
