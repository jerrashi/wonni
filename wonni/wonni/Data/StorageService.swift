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

    /// Uploads a single listing image directly to its permanent path using a UUID instead of an integer index.
    func uploadListingImageWithUUID(image: UIImage, userId: String, listingId: String) async throws -> String {
        let resized = ImageCompressor.resize(image: image, maxDimension: 1200)
        guard let data = ImageCompressor.compress(image: resized, targetSizeInBytes: 180 * 1024) else {
            throw NSError(domain: "StorageService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to compress image"])
        }

        let path = "users/\(userId)/\(listingId)/\(UUID().uuidString).jpg"
        let ref = storage.child(path)

        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        metadata.customMetadata = ["userId": userId]

        _ = try await ref.putDataAsync(data, metadata: metadata)
        return path
    }

    func uploadTemplateImage(image: UIImage, index: Int, userId: String, templateId: String) async throws -> String {
        let resized = ImageCompressor.resize(image: image, maxDimension: 1200)
        guard let data = ImageCompressor.compress(image: resized, targetSizeInBytes: 180 * 1024) else {
            throw NSError(domain: "StorageService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to compress image"])
        }
        let path = "users/\(userId)/templates/\(templateId)/\(index).jpg"
        let ref = storage.child(path)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        metadata.customMetadata = ["userId": userId]
        _ = try await ref.putDataAsync(data, metadata: metadata)
        return path
    }

    func downloadImageData(path: String) async throws -> Data {
        return try await storage.child(path).data(maxSize: 10 * 1024 * 1024)
    }

    /// Deletes all images for a listing.
    func deleteListingImages(userId: String, listingId: String) async throws {
        let listRef = storage.child("users/\(userId)/\(listingId)")
        let result = try await listRef.listAll()
        
        for item in result.items {
            try await item.delete()
        }
    }
    
    /// Uploads a user's profile photo and returns the download URL string.
    func uploadProfilePhoto(image: UIImage, userId: String) async throws -> String {
        let resized = ImageCompressor.resize(image: image, maxDimension: 500)
        guard let data = ImageCompressor.compress(image: resized, targetSizeInBytes: 100 * 1024) else {
            throw NSError(domain: "StorageService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to compress profile image"])
        }

        let path = "users/\(userId)/profile.jpg"
        let ref = storage.child(path)

        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        metadata.customMetadata = ["userId": userId]

        _ = try await ref.putDataAsync(data, metadata: metadata)
        let downloadURL = try await ref.downloadURL()
        return downloadURL.absoluteString
    }
}
