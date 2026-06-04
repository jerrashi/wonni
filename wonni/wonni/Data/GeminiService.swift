//
//  GeminiService.swift
//  wonni
//
//  Production-ready Gemini service using Firebase Cloud Functions to proxy
//  requests and keep the API key secure on the server.
//

import Foundation
import FirebaseFunctions
import UIKit

struct GeminiIdentificationResponse: Codable {
    var name: String?
    var shortTitle: String?   // ≤80 chars, cross-platform optimized
    var brand: String?
    var category: String?
    var suggestedPrice: Double?
    var description: String?
    var condition: String?    // ItemCondition rawValue predicted from photos
    var weightLbs: Double?
    var lengthIn: Double?
    var widthIn: Double?
    var heightIn: Double?
    var confidence: Double?
}

class GeminiService: ObservableObject {
    static let shared = GeminiService()
    
    private lazy var functions = Functions.functions()

    private init() {}

    /// Identifies an item from one or more images using a secure Firebase Cloud Function.
    func identifyItem(images: [UIImage], userTitle: String? = nil, userPrice: Double? = nil, userDescription: String? = nil) async throws -> GeminiIdentificationResponse {
        
        // 1. Prepare images as base64 strings
        var base64Images: [String] = []
        for image in images {
            // SAFETY: Skip images that are zero-sized to prevent "Invalid frame dimension" crashes
            guard image.size.width > 0 && image.size.height > 0 else { continue }
            
            // Resize to keep payload size reasonable
            let resized = ImageCompressor.resize(image: image, maxDimension: 1024)
            if let data = resized.jpegData(compressionQuality: 0.7) {
                base64Images.append(data.base64EncodedString())
            }
        }
        
        if base64Images.isEmpty {
            throw NSError(domain: "GeminiService", code: 400, userInfo: [NSLocalizedDescriptionKey: "No valid images to process."])
        }
        
        // 2. Prepare parameters
        let parameters: [String: Any] = [
            "images": base64Images,
            "userTitle": userTitle ?? "",
            "userPrice": userPrice ?? 0.0,
            "userDescription": userDescription ?? ""
        ]
        
        // 3. Call the Firebase Cloud Function
        do {
            let result = try await functions.httpsCallable("identifyItem").call(parameters)
            
            // 4. Parse the result
            guard let data = try? JSONSerialization.data(withJSONObject: result.data),
                  let response = try? JSONDecoder().decode(GeminiIdentificationResponse.self, from: data) else {
                throw NSError(domain: "GeminiService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to parse AI response"])
            }
            return response
        } catch let error as NSError {
            // Extract the actual error message from the Cloud Function
            let message = error.userInfo["NSLocalizedDescription"] as? String ?? error.localizedDescription
            print("--- CLOUD FUNCTION ERROR: \(message)")
            throw NSError(domain: "GeminiService", code: error.code, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
