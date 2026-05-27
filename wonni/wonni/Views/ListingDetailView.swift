//
//  ListingDetailView.swift
//  wonni
//

import SwiftUI
import FirebaseFirestore
import FirebaseAuth

// MARK: - Models

/// A listing saved by the current user.
/// catalogItemId is nil now — populated when we migrate to the catalog model.
struct SavedItem: Identifiable, Codable {
    @DocumentID var id: String?
    var listingId: String
    var catalogItemId: String?
    var sellerId: String
    var snapshotTitle: String?
    var snapshotCoverPath: String?
    var snapshotPrice: Double?
    var savedAt: Timestamp
    var listIds: [String]

    init(listingId: String, sellerId: String, snapshotTitle: String?,
         snapshotCoverPath: String?, snapshotPrice: Double?,
         savedAt: Timestamp, listIds: [String]) {
        self.listingId = listingId
        self.sellerId = sellerId
        self.snapshotTitle = snapshotTitle
        self.snapshotCoverPath = snapshotCoverPath
        self.snapshotPrice = snapshotPrice
        self.savedAt = savedAt
        self.listIds = listIds
    }
}

/// A user-created collection for organizing saved listings.
struct UserList: Identifiable, Codable {
    @DocumentID var id: String?
    var title: String
    var emoji: String
    var createdAt: Timestamp

    init(title: String, emoji: String, createdAt: Timestamp) {
        self.title = title
        self.emoji = emoji
        self.createdAt = createdAt
    }
}

// MARK: - FavoritesRepository

class FavoritesRepository {
    static let shared = FavoritesRepository()
    private let db = Firestore.firestore()

    private func savedCollection() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "FavoritesRepository", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }
        return db.collection("users").document(uid).collection("saved")
    }

    private func listsCollection() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "FavoritesRepository", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }
        return db.collection("users").document(uid).collection("lists")
    }

    func isSaved(listingId: String) async throws -> Bool {
        let col = try savedCollection()
        let doc = try await col.document(listingId).getDocument()
        return doc.exists
    }

    func save(listing: UserListing) async throws {
        guard let listingId = listing.id else { return }
        let col = try savedCollection()
        let item = SavedItem(
            listingId: listingId,
            sellerId: listing.userId,
            snapshotTitle: listing.customTitle,
            snapshotCoverPath: listing.coverPhotoPath,
            snapshotPrice: listing.price,
            savedAt: Timestamp(date: Date()),
            listIds: []
        )
        try col.document(listingId).setData(from: item)
    }

    func unsave(listingId: String) async throws {
        let col = try savedCollection()
        try await col.document(listingId).delete()
    }

    func fetchLists() async throws -> [UserList] {
        let col = try listsCollection()
        let snapshot = try await col.order(by: "createdAt").getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: UserList.self) }
    }

    func createList(title: String, emoji: String) async throws -> UserList {
        let col = try listsCollection()
        var list = UserList(title: title, emoji: emoji, createdAt: Timestamp(date: Date()))
        let ref = try col.addDocument(from: list)
        list.id = ref.documentID
        return list
    }

    func addToList(listing: UserListing, listId: String) async throws {
        guard let listingId = listing.id else { return }
        let col = try savedCollection()
        let ref = col.document(listingId)
        if !(try await isSaved(listingId: listingId)) {
            try await save(listing: listing)
        }
        try await ref.updateData(["listIds": FieldValue.arrayUnion([listId])])
    }
}

// MARK: - Listing Detail View

struct ListingDetailView: View {
    let listing: UserListing
    @EnvironmentObject private var authManager: AuthManager
    @State private var suggestedListings: [UserListing] = []
    @State private var showOfferSheet = false
    @State private var offerSent = false
    @State private var sellerProfile: UserPublicProfile?

    private var currentUserId: String { authManager.currentUser?.uid ?? "" }
    private var isSeller: Bool { listing.userId == currentUserId }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                photoCarousel
                contentSection.padding(16)
                if !suggestedListings.isEmpty {
                    Divider().padding(.horizontal, 16)
                    suggestedSection
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $showOfferSheet) {
            MakeOfferSheet(currentPrice: listing.price) { amount in
                Task { await submitOffer(amount: amount) }
            }
        }
        .overlay(alignment: .top) {
            if offerSent {
                Text("Offer sent!")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.green, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            suggestedListings = (try? await ListingRepository.shared
                .fetchSuggestedListings(excluding: listing.id ?? "", limit: 8)) ?? []
            sellerProfile = try? await UserRepository.shared.fetchProfile(uid: listing.userId)
        }
    }

    private func submitOffer(amount: Double) async {
        do {
            let convId = try await ConversationRepository.shared
                .getOrCreateConversation(listing: listing, buyerId: currentUserId)
            try await ConversationRepository.shared
                .sendOffer(conversationId: convId, amount: amount, senderId: currentUserId)
            withAnimation { offerSent = true }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { offerSent = false }
        } catch {
            print("[ListingDetailView] Offer failed: \(error)")
        }
    }

    // MARK: Photo Carousel

    private var photoCarousel: some View {
        Group {
            if listing.photoPaths.isEmpty {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 360)
            } else {
                TabView {
                    ForEach(listing.photoPaths, id: \.self) { path in
                        StorageImage(path: path)
                            .scaledToFill()
                            .clipped()
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .frame(height: 360)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            HeartButton(listing: listing)
                .padding(16)
                .background(Circle().fill(.thinMaterial))
                .padding()
        }
    }

    // MARK: Content

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if let price = listing.price {
                    Text(String(format: "$%.2f", price)).font(.title.bold())
                } else {
                    Text("Price TBD").font(.title.bold()).foregroundStyle(.secondary)
                }
                Spacer()
                Text(listing.condition.displayName)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            Text(listing.customTitle ?? "Untitled")
                .font(.title3.weight(.medium))

            if let desc = listing.customDescription, !desc.isEmpty {
                Text(desc).font(.body).foregroundStyle(.secondary)
            }

            Divider()
            sellerRow
            Divider()

            if !isSeller {
                Button { showOfferSheet = true } label: {
                    Text("Make an Offer")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sellerRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.12)).frame(width: 36, height: 36)
                Text(sellerProfile?.displayName?.prefix(1).uppercased() ?? String(listing.userId.prefix(1)).uppercased())
                    .font(.caption.bold()).foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Seller").font(.caption).foregroundStyle(.secondary)
                Text(sellerProfile?.displayName ?? (String(listing.userId.prefix(8)) + "..."))
                    .font(.subheadline.weight(.medium))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: Suggested Listings

    private var suggestedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More listings")
                .font(.headline)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(suggestedListings) { item in
                        NavigationLink(destination: ListingDetailView(listing: item)) {
                            SuggestedListingCard(listing: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 16)
    }
}

// MARK: - Heart Button

struct HeartButton: View {
    let listing: UserListing
    @State private var isSaved = false
    @State private var userLists: [UserList] = []
    @State private var showCreateList = false

    var body: some View {
        Button {
            Task { await toggleSave() }
        } label: {
            Image(systemName: isSaved ? "heart.fill" : "heart")
                .foregroundStyle(isSaved ? .red : .primary)
                .font(.title3)
        }
        .contextMenu {
            Section {
                Button {
                    Task { await toggleSave() }
                } label: {
                    Label(
                        isSaved ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: isSaved ? "heart.slash" : "heart"
                    )
                }
            }
            if !userLists.isEmpty {
                Section("Your Lists") {
                    ForEach(userLists) { list in
                        Button("\(list.emoji) \(list.title)") {
                            Task { await addToList(list) }
                        }
                    }
                }
            }
            Section {
                Button { showCreateList = true } label: {
                    Label("New List", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreateList) {
            CreateListSheet { title, emoji in
                Task { await createAndAddToList(title: title, emoji: emoji) }
            }
        }
        .task { await loadState() }
    }

    private func loadState() async {
        guard let id = listing.id else { return }
        isSaved = (try? await FavoritesRepository.shared.isSaved(listingId: id)) ?? false
        userLists = (try? await FavoritesRepository.shared.fetchLists()) ?? []
    }

    private func toggleSave() async {
        guard let id = listing.id else { return }
        do {
            if isSaved {
                try await FavoritesRepository.shared.unsave(listingId: id)
                isSaved = false
            } else {
                try await FavoritesRepository.shared.save(listing: listing)
                isSaved = true
            }
        } catch {
            print("[HeartButton] toggle failed: \(error)")
        }
    }

    private func addToList(_ list: UserList) async {
        guard let listId = list.id else { return }
        do {
            try await FavoritesRepository.shared.addToList(listing: listing, listId: listId)
            if !isSaved { isSaved = true }
        } catch {
            print("[HeartButton] addToList failed: \(error)")
        }
    }

    private func createAndAddToList(title: String, emoji: String) async {
        do {
            let newList = try await FavoritesRepository.shared.createList(title: title, emoji: emoji)
            userLists.append(newList)
            if let listId = newList.id {
                try await FavoritesRepository.shared.addToList(listing: listing, listId: listId)
                if !isSaved { isSaved = true }
            }
        } catch {
            print("[HeartButton] createAndAddToList failed: \(error)")
        }
    }
}

// MARK: - Create List Sheet

struct CreateListSheet: View {
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var emoji = "❤️"

    var body: some View {
        NavigationStack {
            Form {
                Section("List Name") {
                    TextField("e.g. Winter Wishlist", text: $title)
                }
                Section("Emoji") {
                    TextField("Emoji", text: $emoji)
                }
            }
            .navigationTitle("New List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onSave(title, emoji.isEmpty ? "❤️" : String(emoji.prefix(1)))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Suggested Listing Card

private struct SuggestedListingCard: View {
    let listing: UserListing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let path = listing.coverPhotoPath {
                    StorageImage(path: path).scaledToFill()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(width: 140, height: 140)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(listing.customTitle ?? "Untitled")
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)

            if let price = listing.price {
                Text(String(format: "$%.2f", price))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 140)
    }
}
