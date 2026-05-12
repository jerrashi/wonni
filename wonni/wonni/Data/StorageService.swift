//
//  StorageService.swift
//  wonni
//
//  Created by Antigravity on 5/7/25.
//

import Foundation
import FirebaseStorage
import FirebaseAuth
import UIKit

class StorageService: ObservableObject {
    static let shared = StorageService()
    private let storage = Storage.storage().reference()
    
    /// Uploads a single listing image directly to its permanent path.
    /// Returns the full storage path (e.g. "users/USER_ID/LISTING_ID/0.jpg").
    func uploadListingImage(image: UIImage, index: Int, userId: String, listingId: String) async throws -> String {
        let resized = ImageCompressor.resize(image: image, maxDimension: 1200)
        guard let data = ImageCompressor.compress(image: resized, targetSizeInBytes: 180 * 1024) else {
            throw NSError(domain: "StorageService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to compress image"])
        }

        let path = "users/\(userId)/\(listingId)/\(index).jpg"
        let ref = storage.child(path)

        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        metadata.customMetadata = ["userId": userId]

        _ = try await ref.putDataAsync(data, metadata: metadata)
        return path
    }

    /// Deletes all images for a listing.
    func deleteListingImages(userId: String, listingId: String) async throws {
        let listRef = storage.child("users/\(userId)/\(listingId)")
        let result = try await listRef.listAll()
        
        for item in result.items {
            try await item.delete()
        }
    }
}
