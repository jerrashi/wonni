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
    /// Stamped by the Cloud Function (the only honest source): which model and
    /// prompt revision produced this output. Optional so an older deployed
    /// function that doesn't send them yet still decodes.
    var aiModel: String?
    var promptVersion: String?
}

/// The `enrichListing` mode:"draft" response — only the pieces GeminiService
/// maps back into `GeminiIdentificationResponse`. Mirrors contracts/enrichment.js.
private struct EnrichListingDraftResult: Codable {
    struct Suggested: Codable {
        var title: String?
        var shortTitle: String?
        var description: String?
        var brand: String?
        var category: String?
        var condition: String?      // canonical: new | likenew | good | fair | poor
        var suggestedPrice: Double?
        var weightOz: Double?
        var lengthIn: Double?
        var widthIn: Double?
        var heightIn: Double?
        var confidence: Double?
    }
    var suggested: Suggested
    var aiModel: String?
    var aiPromptVersion: String?
}

class GeminiService: ObservableObject {
    static let shared = GeminiService()

    private lazy var functions = Functions.functions()

    private init() {}

    /// Canonical 5-value condition → iOS `ItemCondition` rawValue.
    /// Only `likenew` differs; the rest (`new`/`good`/`fair`/`poor`) match.
    static func canonicalToItemCondition(_ c: String?) -> String? {
        c == "likenew" ? "likeNew" : c
    }

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
        
        // 2. Prepare parameters — `enrichListing` mode:"draft" (replaced the
        //    old `identifyItem`; one Gemini call, shared ListingFields shape).
        let parameters: [String: Any] = [
            "mode": "draft",
            "images": base64Images,
            "hints": [
                "title": userTitle ?? "",
                "price": userPrice ?? 0.0,
                "description": userDescription ?? ""
            ]
        ]

        // 3. Call the Firebase Cloud Function
        do {
            let result = try await functions.httpsCallable("enrichListing").call(parameters)

            // 4. Parse the result — enrichListing nests the fields under `suggested`
            //    and uses canonical names (title, weightOz, aiPromptVersion).
            guard let data = try? JSONSerialization.data(withJSONObject: result.data),
                  let env = try? JSONDecoder().decode(EnrichListingDraftResult.self, from: data) else {
                throw NSError(domain: "GeminiService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to parse AI response"])
            }
            let s = env.suggested
            return GeminiIdentificationResponse(
                name: s.title,
                shortTitle: s.shortTitle,
                brand: s.brand,
                category: s.category,
                suggestedPrice: s.suggestedPrice,
                description: s.description,
                condition: Self.canonicalToItemCondition(s.condition),
                weightLbs: s.weightOz.map { $0 / 16.0 },
                lengthIn: s.lengthIn,
                widthIn: s.widthIn,
                heightIn: s.heightIn,
                confidence: s.confidence,
                aiModel: env.aiModel,
                promptVersion: env.aiPromptVersion
            )
        } catch let error as NSError {
            // Extract the actual error message from the Cloud Function
            let message = error.userInfo["NSLocalizedDescription"] as? String ?? error.localizedDescription
            print("--- CLOUD FUNCTION ERROR: \(message)")
            throw NSError(domain: "GeminiService", code: error.code, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
