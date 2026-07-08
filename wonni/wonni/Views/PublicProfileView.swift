//
//  PublicProfileView.swift
//  wonni
//

import SwiftUI

struct PublicProfileView: View {
    let userId: String
    let initialProfile: UserPublicProfile?

    @EnvironmentObject private var authManager: AuthManager
    @State private var profile: UserPublicProfile?
    @State private var listings: [UserListing] = []
    @State private var directConversation: Conversation?
    @State private var showConversation = false

    private var currentUserId: String { authManager.currentUser?.uid ?? "" }
    private var isOwnProfile: Bool { userId == currentUserId }
    private var displayProfile: UserPublicProfile? { profile ?? initialProfile }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                profileHeader
                    .padding(.vertical, 24)
                if !listings.isEmpty {
                    Divider()
                    listingsGrid
                        .padding(.top, 16)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationDestination(isPresented: $showConversation) {
            if let conv = directConversation {
                ConversationView(conversation: conv)
            }
        }
        .task {
            async let profileFetch = UserRepository.shared.fetchProfile(uid: userId)
            async let listingsFetch = ListingRepository.shared.fetchActiveListings(forUserId: userId)
            profile = try? await profileFetch
            listings = (try? await listingsFetch) ?? []
        }
    }

    // MARK: Profile header

    private var profileHeader: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 80, height: 80)
                Text((displayProfile?.displayName ?? userId).prefix(1).uppercased())
                    .font(.largeTitle.bold())
                    .foregroundStyle(.blue)
            }

            VStack(spacing: 4) {
                Text(displayProfile?.displayName ?? "User")
                    .font(.title3.weight(.semibold))
                if let username = displayProfile?.username {
                    Text("@\(username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !isOwnProfile {
                Button {
                    Task { await openDirectMessage() }
                } label: {
                    Text("Message")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 140)
                        .padding(.vertical, 10)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Listings grid

    private var listingsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Listings")
                .font(.headline)
                .padding(.horizontal, 16)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(listings) { listing in
                    NavigationLink(destination: ListingDetailView(listing: listing)) {
                        ProfileListingCard(listing: listing)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 24)
    }

    // MARK: Action

    private func openDirectMessage() async {
        do {
            let convId = try await ConversationRepository.shared.getOrCreateDirectConversation(
                currentUserId: currentUserId,
                currentDisplayName: authManager.currentUser?.displayName,
                otherUserId: userId,
                otherDisplayName: displayProfile?.displayName
            )
            if let conv = try await ConversationRepository.shared.fetchConversation(id: convId) {
                directConversation = conv
                showConversation = true
            }
        } catch {
            print("[PublicProfileView] Direct message failed: \(error)")
        }
    }
}

// MARK: - Profile Listing Card

private struct ProfileListingCard: View {
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
            .frame(height: 140)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(listing.customTitle ?? "Untitled")
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)

            if let price = listing.price {
                Text(String(format: "$%.2f", price))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
