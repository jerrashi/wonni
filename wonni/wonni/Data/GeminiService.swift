//
//  GeminiService.swift
//  wonni
//
//  Created by Antigravity on 5/7/25.
//

import Foundation
import FirebaseAI
import UIKit

struct GeminiIdentificationResponse: Codable {
    var name: String?
    var brand: String?
    var category: String?
    var attributes: [String: String]?
    var suggestedPrice: Double?
    var description: String?
    var confidence: Double?
}

class GeminiService: ObservableObject {
    static let shared = GeminiService()

    private let model: GenerativeModel

    init() {
        let ai = FirebaseAI.firebaseAI(backend: .googleAI())
        self.model = ai.generativeModel(modelName: "gemini-1.5-flash")
    }
    
    /// Identifies an item from one or more images.
    func identifyItem(images: [UIImage]) async throws -> GeminiIdentificationResponse {
        // 1. Prepare the prompt
        let prompt = """
        Identify the item in these photos. Provide a detailed identification in JSON format.
        Include:
        - name: A concise, searchable product name.
        - brand: The brand or manufacturer.
        - category: A hierarchical category string (e.g., "Electronics > Audio > Headphones").
        - attributes: Key product details (e.g., {"Color": "Black", "Model": "WH-1000XM4"}).
        - suggestedPrice: An estimated current market price in USD (numeric).
        - description: A 2-3 sentence professional product description.
        - confidence: Your confidence score from 0.0 to 1.0.
        
        Return ONLY the JSON object.
        """
        
        // 2. Build parts: inline JPEG data for each image, then the text prompt
        var parts: [any Part] = []
        for image in images {
            let resized = ImageCompressor.resize(image: image, maxDimension: 1024)
            if let jpegData = resized.jpegData(compressionQuality: 0.8) {
                parts.append(InlineDataPart(data: jpegData, mimeType: "image/jpeg"))
            }
        }
        parts.append(TextPart(prompt))

        // 3. Generate content
        let content = ModelContent(role: "user", parts: parts)
        let response = try await model.generateContent([content])

        guard let text = response.text else {
            throw NSError(domain: "GeminiService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Empty response from Gemini"])
        }

        // 4. Parse JSON (strip markdown fences if present)
        let cleanedJson = text.replacingOccurrences(of: "```json", with: "")
                             .replacingOccurrences(of: "```", with: "")
                             .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard let jsonData = cleanedJson.data(using: String.Encoding.utf8) else {
            throw NSError(domain: "GeminiService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to encode response string"])
        }

        return try JSONDecoder().decode(GeminiIdentificationResponse.self, from: jsonData)
    }
}
