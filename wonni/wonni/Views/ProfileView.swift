//
//  ProfileView.swift
//  wonni
//

import SwiftUI
import FirebaseStorage
import FirebaseAuth

struct ProfileView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var listings: [UserListing] = []
    @State private var isLoading = true
    @State private var showSignOutAlert = false

    private var user: FirebaseAuth.User? { authManager.currentUser }

    private var initials: String {
        guard let name = user?.displayName, !name.isEmpty else {
            return user?.email?.prefix(1).uppercased().description ?? "?"
        }
        return name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    if isLoading {
                        ProgressView().padding(.top, 60)
                    } else if listings.isEmpty {
                        emptyState
                    } else {
                        listingsGrid
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSignOutAlert = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .alert("Sign Out", isPresented: $showSignOutAlert) {
                Button("Sign Out", role: .destructive) { try? authManager.signOut() }
                Button("Cancel", role: .cancel) {}
            }
            .task { await loadListings() }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 80, height: 80)
                Text(initials)
                    .font(.title.bold())
                    .foregroundStyle(.blue)
            }
            VStack(spacing: 4) {
                if let name = user?.displayName, !name.isEmpty {
                    Text(name).font(.title3.bold())
                }
                if let email = user?.email {
                    Text(email).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 28)
    }

    private var listingsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(listings.count) listing\(listings.count == 1 ? "" : "s")")
                .font(.headline)
                .padding(.horizontal, 16)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)],
                spacing: 2
            ) {
                ForEach(listings) { listing in
                    NavigationLink(destination: ListingDetailView(listing: listing)) {
                        ListingCard(listing: listing)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tag").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No listings yet").font(.headline)
            Text("Upload items from the Sell tab to see them here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.top, 60)
    }

    private func loadListings() async {
        isLoading = true
        defer { isLoading = false }
        do {
            listings = try await ListingRepository.shared.fetchActiveListings()
        } catch {
            print("[ProfileView] Failed to load listings: \(error)")
        }
    }
}

// MARK: - Listing Card

private struct ListingCard: View {
    let listing: UserListing

    var priceText: String {
        guard let price = listing.price else { return "Price TBD" }
        return String(format: "$%.2f", price)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let path = listing.coverPhotoPath {
                    StorageImage(path: path)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }
            }
            .aspectRatio(1, contentMode: .fill)
            .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(listing.customTitle ?? "Untitled")
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                Text(priceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Storage Image

struct StorageImage: View {
    let path: String
    @State private var url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Rectangle().fill(Color.secondary.opacity(0.12))
                    default:
                        Rectangle().fill(Color.secondary.opacity(0.08))
                            .overlay(ProgressView().scaleEffect(0.6))
                    }
                }
            } else {
                Rectangle().fill(Color.secondary.opacity(0.08))
            }
        }
        .task(id: path) {
            url = try? await Storage.storage().reference().child(path).downloadURL()
        }
    }
}
