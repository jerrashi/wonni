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
    
    /// Uploads an image to the temporary scratch space.
    /// Returns the full storage path (e.g. "temp/USER_ID/UUID.jpg").
    func uploadTempImage(image: UIImage) async throws -> String {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "StorageService", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        
        // 1. Resize and Compress
        let resized = ImageCompressor.resize(image: image, maxDimension: 1200)
        guard let data = ImageCompressor.compress(image: resized, targetSizeInBytes: 180 * 1024) else {
            throw NSError(domain: "StorageService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to compress image"])
        }
        
        // 2. Generate path
        let fileName = UUID().uuidString + ".jpg"
        let path = "temp/\(userId)/\(fileName)"
        let ref = storage.child(path)
        
        // 3. Upload metadata
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        metadata.customMetadata = ["userId": userId]
        
        // 4. Perform upload
        _ = try await ref.putDataAsync(data, metadata: metadata)
        
        return path
    }
    
    /// Promotes images from temp storage to a permanent listing directory.
    /// This should be called after Gemini confirms the item and a UserListing is finalized.
    func promoteImages(tempPaths: [String], userId: String, listingId: String) async throws -> [String] {
        var permanentPaths: [String] = []
        
        for (index, tempPath) in tempPaths.enumerated() {
            let fileName = "\(index).jpg"
            let permanentPath = "listings/\(userId)/\(listingId)/\(fileName)"
            
            let tempRef = storage.child(tempPath)
            let permanentRef = storage.child(permanentPath)
            
            // Firebase Storage doesn't have a "move", so we copy then delete
            let downloadUrl = try await tempRef.downloadURL()
            let (data, _) = try await URLSession.shared.data(from: downloadUrl)
            
            _ = try await permanentRef.putDataAsync(data)
            try await tempRef.delete()
            
            permanentPaths.append(permanentPath)
        }
        
        return permanentPaths
    }
    
    /// Deletes a permanent listing directory and all its images.
    func deleteListingImages(userId: String, listingId: String) async throws {
        let listRef = storage.child("listings/\(userId)/\(listingId)")
        let result = try await listRef.listAll()
        
        for item in result.items {
            try await item.delete()
        }
    }
}
