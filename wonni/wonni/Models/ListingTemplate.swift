//
//  ListingTemplate.swift
//  wonni
//

import SwiftUI
import FirebaseFirestore
import FirebaseStorage
import FirebaseAuth

// MARK: - Model

struct ListingTemplate: Identifiable, Codable {
    @DocumentID var id: String?
    var name: String
    var title: String?
    var customDescription: String?
    var condition: String?           // ItemCondition.rawValue
    var brand: String?
    var category: String?
    var isFreeShipping: Bool?
    var weightLbs: Double?
    var packageDimensions: PackageDimensions?
    var platforms: [String]?
    var photoPaths: [String]
    var createdAt: Timestamp

    init(
        id: String? = nil,
        name: String,
        title: String? = nil,
        customDescription: String? = nil,
        condition: String? = nil,
        brand: String? = nil,
        category: String? = nil,
        isFreeShipping: Bool? = nil,
        weightLbs: Double? = nil,
        packageDimensions: PackageDimensions? = nil,
        platforms: [String]? = nil,
        photoPaths: [String] = [],
        createdAt: Timestamp = Timestamp(date: Date())
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.customDescription = customDescription
        self.condition = condition
        self.brand = brand
        self.category = category
        self.isFreeShipping = isFreeShipping
        self.weightLbs = weightLbs
        self.packageDimensions = packageDimensions
        self.platforms = platforms
        self.photoPaths = photoPaths
        self.createdAt = createdAt
    }
}

// MARK: - Repository

@MainActor
class ListingTemplateRepository: ObservableObject {
    static let shared = ListingTemplateRepository()
    private let db = Firestore.firestore()

    @Published var templates: [ListingTemplate] = []
    @Published var isLoading = false

    private init() {}

    private var userId: String? { Auth.auth().currentUser?.uid }

    private func coll(uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("listingTemplates")
    }

    func loadTemplates() async {
        guard let uid = userId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snap = try await coll(uid: uid)
                .order(by: "createdAt", descending: false)
                .getDocuments()
            templates = snap.documents.compactMap { try? $0.data(as: ListingTemplate.self) }
        } catch {
            print("[ListingTemplateRepository] load error: \(error)")
        }
    }

    func save(_ template: ListingTemplate) async throws {
        guard let uid = userId else { return }
        if let id = template.id {
            try coll(uid: uid).document(id).setData(from: template)
        } else {
            _ = try coll(uid: uid).addDocument(from: template)
        }
        await loadTemplates()
    }

    func delete(_ template: ListingTemplate) async {
        guard let uid = userId, let id = template.id else { return }
        do {
            try await coll(uid: uid).document(id).delete()
            templates.removeAll { $0.id == id }
            Task.detached {
                let ref = Storage.storage().reference().child("users/\(uid)/templates/\(id)")
                if let result = try? await ref.listAll() {
                    for item in result.items { try? await item.delete() }
                }
            }
        } catch {
            print("[ListingTemplateRepository] delete error: \(error)")
        }
    }
}
