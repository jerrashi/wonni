//
//  StorageService.swift
//  wonni
//
//  Created by Antigravity on 5/7/25.
//

import Foundation
import FirebaseStorage
import FirebaseAuth
import FirebaseFirestore
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

    /// True if a Sale record still snapshots this exact Storage path as its cover photo —
    /// e.g. a sold listing that never got a working platform (eBay/Mercari) CDN thumbnail
    /// and is still falling back to the Wonni-hosted copy. Deleting the path out from under
    /// it would break the Sales dashboard's photo.
    private func isPhotoReferencedBySale(path: String, userId: String) async throws -> Bool {
        let snap = try await Firestore.firestore().collection("sales")
            .whereField("userId", isEqualTo: userId)
            .whereField("coverPhotoPath", isEqualTo: path)
            .limit(to: 1)
            .getDocuments()
        return !snap.documents.isEmpty
    }

    /// True if a Conversation record still snapshots this exact Storage path as its cover
    /// photo (same shared-reference risk as Sales, above).
    private func isPhotoReferencedByConversation(path: String, userId: String) async throws -> Bool {
        let snap = try await Firestore.firestore().collection("conversations")
            .whereField("participants", arrayContains: userId)
            .whereField("snapshotCoverPath", isEqualTo: path)
            .limit(to: 1)
            .getDocuments()
        return !snap.documents.isEmpty
    }

    private func isPhotoReferenced(path: String, userId: String) async throws -> Bool {
        if try await isPhotoReferencedBySale(path: path, userId: userId) { return true }
        if try await isPhotoReferencedByConversation(path: path, userId: userId) { return true }
        return false
    }

    /// Deletes a single photo, unless a Sale or Conversation still references it — in which
    /// case it's left in place (no-op) so that record doesn't end up with a broken image.
    func deletePhoto(path: String, userId: String) async throws {
        guard try await !isPhotoReferenced(path: path, userId: userId) else {
            print("[StorageService] Skipping delete of \(path) — still referenced by a Sale/Conversation")
            return
        }
        try await storage.child(path).delete()
    }

    /// Deletes all images for a listing, except any still referenced by a Sale or
    /// Conversation snapshot (see `isPhotoReferenced`). Throws on the first real failure —
    /// callers should treat a thrown error as "cleanup did not fully complete" rather than
    /// swallowing it, so orphaned files don't go undetected.
    func deleteListingImages(userId: String, listingId: String) async throws {
        let listRef = storage.child("users/\(userId)/\(listingId)")
        let result = try await listRef.listAll()

        for item in result.items {
            if try await isPhotoReferenced(path: item.fullPath, userId: userId) {
                print("[StorageService] Skipping delete of \(item.fullPath) — still referenced by a Sale/Conversation")
                continue
            }
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
