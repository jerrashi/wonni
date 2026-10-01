//
//  StorageService.swift
//  wonni
//
//  Created by Antigravity on 5/7/25.
//

import Foundation
import FirebaseStorage
import FirebaseAuth
import FirebaseFunctions
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
        try await publishObject(path: path)
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
        try await publishObject(path: path)
        return path
    }

    /// Flips a just-uploaded object to public and returns. Client SDK uploads land
    /// PRIVATE at the GCS layer: `storage.rules` `allow read: if true` only covers the
    /// firebasestorage.googleapis.com endpoint, while every `products.images` /
    /// `listings.photoPaths` URL we write is the canonical `storage.googleapis.com`
    /// form (`publicURL(forPath:)`), which ignores rules and needs an allUsers ACL.
    /// Web has always called this after `uploadBytes` (`web/src/firebase.js`); iOS
    /// never did, so until 2026-10-01 every iOS photo 403'd for eBay's image fetch
    /// (listings posted with no pictures), the web dashboard, and the Mercari
    /// extension. Throws on failure so the caller's upload retry loop re-runs it —
    /// a silently private photo is exactly the bug this exists to prevent.
    private func publishObject(path: String) async throws {
        _ = try await Functions.functions().httpsCallable("publishStorageObject").call(["path": path])
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
        try await publishObject(path: path)
        return path
    }

    /// Converts a bare Storage path (e.g. "users/UID/LISTING_ID/0.jpg") into a full,
    /// directly-fetchable public URL. Listing-photo paths are `allow read: if true` in
    /// storage.rules, so this needs no auth/token — unlike `StorageImage`'s per-render
    /// `getDownloadURL()` call, this is safe to compute once and store. Used for the
    /// shared `products/{id}.images` field, whose canonical format (matching
    /// wonni_dropship's own convention) is a full public URL rather than a bare path.
    func publicURL(forPath path: String) -> String {
        "https://storage.googleapis.com/\(storage.bucket)/\(path)"
    }

    /// Inverse of `publicURL(forPath:)` — only resolves URLs pointing at *this app's own*
    /// bucket. Returns nil for anything else (e.g. wonni_dropship's pre-merge photos,
    /// still hosted on the old `wonni-dropship` bucket) — those aren't downloadable via
    /// the Storage SDK's bucket-scoped reference and are just skipped by callers rather
    /// than mishandled.
    func path(fromPublicURL url: String) -> String? {
        let prefix = "https://storage.googleapis.com/\(storage.bucket)/"
        guard url.hasPrefix(prefix) else { return nil }
        return String(url.dropFirst(prefix.count)).removingPercentEncoding
    }

    /// Where a stored photo string actually points. `listings.photoPaths` holds TWO
    /// formats: bare Storage paths (listings iOS wrote directly, pre-2026-09) and full
    /// public URLs (listings `postToWonni` writes by copying `products.images`, which is
    /// URL-shaped by convention). Feeding a URL to `reference().child(_:)` built a
    /// nonsense object path that matched no Storage rule — every photo on a
    /// freshly-published listing showed `FIRStorageErrorDomain -13021` (2026-10-01).
    enum PhotoLocation: Equatable {
        /// An object in this app's bucket — read through the SDK (rules + token).
        case storagePath(String)
        /// Someone else's bucket (e.g. wonni_dropship's old photos) — only fetchable as-is.
        case externalURL(URL)
    }

    /// Normalizes either format. Pure, so it's unit-testable.
    nonisolated static func photoLocation(for pathOrURL: String, bucket: String) -> PhotoLocation? {
        let trimmed = pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.lowercased().hasPrefix("http") else { return .storagePath(trimmed) }

        let gcsPrefix = "https://storage.googleapis.com/\(bucket)/"
        if trimmed.hasPrefix(gcsPrefix),
           let path = String(trimmed.dropFirst(gcsPrefix.count)).removingPercentEncoding,
           !path.isEmpty {
            return .storagePath(path)
        }
        // https://firebasestorage.googleapis.com/v0/b/<bucket>/o/<url-encoded path>?alt=media
        let fbPrefix = "https://firebasestorage.googleapis.com/v0/b/\(bucket)/o/"
        if trimmed.hasPrefix(fbPrefix) {
            let rest = String(trimmed.dropFirst(fbPrefix.count))
            let encoded = rest.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rest
            if let path = encoded.removingPercentEncoding, !path.isEmpty {
                return .storagePath(path)
            }
        }
        return URL(string: trimmed).map { .externalURL($0) }
    }

    func photoLocation(for pathOrURL: String) -> PhotoLocation? {
        Self.photoLocation(for: pathOrURL, bucket: storage.bucket)
    }

    /// A URL `AsyncImage`/`URLSession` can load, for either stored format.
    func imageURL(forPathOrURL pathOrURL: String) async throws -> URL {
        switch photoLocation(for: pathOrURL) {
        case .storagePath(let path): return try await storage.child(path).downloadURL()
        case .externalURL(let url):  return url
        case nil:
            throw NSError(domain: "StorageService", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "Empty photo path"])
        }
    }

    /// Bytes for either stored format (external URLs are fetched directly).
    func downloadImageData(path pathOrURL: String, maxSize: Int64 = 10 * 1024 * 1024) async throws -> Data {
        switch photoLocation(for: pathOrURL) {
        case .storagePath(let path):
            return try await storage.child(path).data(maxSize: maxSize)
        case .externalURL(let url):
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "StorageService", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) fetching \(url)"])
            }
            return data
        case nil:
            throw NSError(domain: "StorageService", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "Empty photo path"])
        }
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
    func deletePhoto(path pathOrURL: String, userId: String) async throws {
        // Only our own objects can be deleted; an external URL is just dropped from the doc.
        guard case .storagePath(let path) = photoLocation(for: pathOrURL) else { return }
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
        let result: StorageListResult
        do {
            result = try await listRef.listAll()
        } catch {
            logStorageError("listAll(\(listRef.fullPath))", error)
            throw error
        }
        print("[StorageService] deleteListingImages(\(listingId)): listAll found \(result.items.count) item(s)")

        for item in result.items {
            do {
                if try await isPhotoReferenced(path: item.fullPath, userId: userId) {
                    print("[StorageService] Skipping delete of \(item.fullPath) — still referenced by a Sale/Conversation")
                    continue
                }
            } catch {
                logStorageError("isPhotoReferenced(\(item.fullPath))", error)
                throw error
            }
            do {
                try await item.delete()
            } catch {
                logStorageError("delete(\(item.fullPath))", error)
                throw error
            }
        }
    }

    /// Verbose diagnostic for a Storage/Firestore failure — added 2026-09-29 to catch a
    /// "Delete Failed" report in TestFlight where the generic `\(error)` interpolation at
    /// the UploadManager call site wasn't enough to tell listAll/isPhotoReferenced/item
    /// delete apart, or surface the underlying NSError code. Temporary until root-caused;
    /// safe to keep (print-only, no behavior change).
    private func logStorageError(_ step: String, _ error: Error) {
        let nsError = error as NSError
        print("""
        [StorageService] ⚠️ \(step) failed:
          domain: \(nsError.domain)
          code: \(nsError.code)
          localizedDescription: \(nsError.localizedDescription)
          userInfo: \(nsError.userInfo)
        """)
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
