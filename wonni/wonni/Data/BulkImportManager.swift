//
//  BulkImportManager.swift
//  wonni
//

import SwiftUI
import Combine
import FirebaseAuth
import FirebaseFirestore

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
    private var importTaskId = UUID()

    func startImporting(previews: [ListingPreview]) {
        self.jobs = previews.map { BulkImportJob(preview: $0) }
        self.totalCount = previews.count
        self.currentIndex = 0
        self.isPillVisible = true
        importTaskId = UUID()
        AppTaskQueue.shared.begin(
            id: importTaskId,
            label: "Importing items",
            detail: "0 of \(previews.count)",
            progress: 0,
            accentColor: Color(red: 0, green: 0.3, blue: 0.1),
            onTap: { [weak self] in self?.showProgressSheet = true }
        )

        Task {
            await processQueue()
        }
    }

    private func processQueue() async {
        for (index, job) in jobs.enumerated() {
            guard jobs[index].status == .pending else { continue }

            self.currentIndex = index + 1
            AppTaskQueue.shared.update(
                id: importTaskId,
                detail: "\(index + 1) of \(totalCount)",
                progress: Double(index + 1) / Double(max(totalCount, 1))
            )
            jobs[index].status = .extracting

            do {
                let extracted = try await urlExtractor.extract(from: job.preview.url)
                try await createListing(from: extracted, preview: job.preview)
                jobs[index].status = .done
            } catch {
                print("Failed to bulk import \(job.preview.title): \(error)")
                jobs[index].status = .failed
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if self.jobs.allSatisfy({ $0.status == .done || $0.status == .failed }) {
                withAnimation { self.isPillVisible = false }
                AppTaskQueue.shared.complete(id: self.importTaskId)
            }
        }
    }

    private func createListing(from extracted: ExtractedListing, preview: ListingPreview) async throws {
        guard let userId = Auth.auth().currentUser?.uid else { return }

        // Pre-generate a listing ID so we can use it for Storage paths
        let listingId = UUID().uuidString

        // Download and upload photos
        var photoPaths: [String] = []
        let imageUrls = extracted.imageUrls.isEmpty ? [preview.thumbnailUrl] : extracted.imageUrls
        for (i, urlStr) in imageUrls.prefix(12).enumerated() {
            guard let url = URL(string: urlStr),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  let path = try? await StorageService.shared.uploadListingImage(
                      image: image, index: i, userId: userId, listingId: listingId
                  ) else { continue }
            photoPaths.append(path)
        }

        // Extract Mercari item ID from URL
        var crossPostIds: [String: String]? = nil
        if let range = preview.url.range(of: #"m[a-zA-Z0-9]+"#, options: .regularExpression) {
            let mercariId = String(preview.url[range])
            crossPostIds = ["mercari": mercariId]
        }

        let condition = mapCondition(extracted.condition) ?? .good

        var listing = UserListing(
            id: listingId,
            userId: userId,
            catalogItemId: "",
            customTitle: extracted.title.isEmpty ? nil : extracted.title,
            customDescription: extracted.description.isEmpty ? nil : extracted.description,
            price: extracted.price,
            currency: "USD",
            quantity: 1,
            condition: condition,
            photoPaths: photoPaths,
            coverPhotoPath: photoPaths.first,
            status: .active,
            createdAt: Timestamp(date: Date()),
            updatedAt: Timestamp(date: Date()),
            publishedAt: Timestamp(date: Date()),
            crossPostListingIds: crossPostIds
        )
        _ = try await ListingRepository.shared.saveDraft(listing)
    }

    private func mapCondition(_ text: String) -> ItemCondition? {
        let lower = text.lowercased()
        if lower.contains("new") && !lower.contains("other") && !lower.contains("without tags") {
            return .new
        } else if lower.contains("like new") || lower.contains("excellent") {
            return .likeNew
        } else if lower.contains("good") {
            return .good
        } else if lower.contains("fair") {
            return .fair
        } else if lower.contains("poor") || lower.contains("parts") {
            return .poor
        }
        return nil
    }
}
