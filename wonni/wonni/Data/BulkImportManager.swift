//
//  BulkImportManager.swift
//  wonni
//

import SwiftUI
import Combine
import SwiftData

enum BulkImportStatus {
    case pending
    case extracting
    case failed
    case done
}

struct BulkImportJob: Identifiable {
    var id: String { preview.url }
    let preview: ListingPreview
    var status: BulkImportStatus = .pending
}

@MainActor
class BulkImportManager: ObservableObject {
    @Published var jobs: [BulkImportJob] = []
    @Published var isPillVisible = false
    @Published var showProgressSheet = false
    
    @Published var currentIndex = 0
    @Published var totalCount = 0
    
    @Published var urlExtractor = URLExtractor()
    private var modelContext: SwiftData.ModelContext?
    
    func startImporting(previews: [ListingPreview], context: SwiftData.ModelContext) {
        self.jobs = previews.map { BulkImportJob(preview: $0) }
        self.modelContext = context
        self.totalCount = previews.count
        self.currentIndex = 0
        self.isPillVisible = true
        
        Task {
            await processQueue()
        }
    }
    
    private func processQueue() async {
        for (index, job) in jobs.enumerated() {
            guard jobs[index].status == .pending else { continue }
            
            self.currentIndex = index + 1
            jobs[index].status = .extracting
            
            do {
                guard let ctx = modelContext else { break }
                let extracted = try await urlExtractor.extract(from: job.preview.url)
                
                // Download images and create draft
                try await createDraft(from: extracted, context: ctx)
                
                jobs[index].status = .done
            } catch {
                print("Failed to bulk import \(job.preview.title): \(error)")
                jobs[index].status = .failed
            }
        }
        
        // Hide pill after a few seconds when done
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if self.jobs.allSatisfy({ $0.status == .done || $0.status == .failed }) {
                withAnimation {
                    self.isPillVisible = false
                }
            }
        }
    }
    
    private func createDraft(from extracted: ExtractedListing, context: SwiftData.ModelContext) async throws {
        var dataArray: [Data] = []
        for urlStr in extracted.imageUrls.prefix(12) {
            if let url = URL(string: urlStr) {
                let (data, _) = try await URLSession.shared.data(from: url)
                dataArray.append(data)
            }
        }
        
        let draft = Item(
            photosData: dataArray,
            buyerPaysShipping: true,
            handlingFee: 0.0,
            estimatedShippingDays: 3,
            isDraft: true,
            sourceAssetIdentifiers: [],
            isLocalPhotoOnly: true,
            originalUserTitleBeforeAI: extracted.title,
            originalUserDescriptionBeforeAI: extracted.description
        )
        
        draft.userEditedTitle = extracted.title
        draft.userEditedPrice = extracted.price
        draft.userEditedDescription = extracted.description
        if !extracted.condition.isEmpty {
            draft.condition = mapCondition(extracted.condition)
        }
        
        context.insert(draft)
        try context.save()
    }
    
    private func mapCondition(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("new") && !lower.contains("other") && !lower.contains("without tags") {
            return "new"
        } else if lower.contains("like new") || lower.contains("excellent") {
            return "likeNew"
        } else if lower.contains("good") {
            return "good"
        } else if lower.contains("fair") {
            return "fair"
        } else if lower.contains("poor") || lower.contains("parts") {
            return "poor"
        }
        return nil
    }
}
