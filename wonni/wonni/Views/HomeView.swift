//
//  HomeView.swift
//  wonni
//

import SwiftUI
import FirebaseFirestore

// MARK: - Banner Destination

/// All surfaces a promoted banner can navigate to.
/// Add a new case here + one branch in HomeView.navigationDestination to wire up a new destination.
enum BannerDestination: Hashable {
    case listing(id: String)
    case category(name: String)
    case search(query: String)
    case externalURL(urlString: String)
}

// MARK: - Promoted Banner Model

struct PromotedBanner: Identifiable, Codable {
    @DocumentID var id: String?
    var title: String
    var subtitle: String?
    var imagePath: String?
    var colorHex: String?
    var isActive: Bool
    var sortOrder: Int
    var expiresAt: Timestamp?

    /// Firestore-stored destination. Set destinationType to one of:
    /// "listing", "category", "search", "externalURL"
    /// and destinationValue to the associated payload (id, name, query, url).
    var destinationType: String?
    var destinationValue: String?

    var destination: BannerDestination? {
        guard let type = destinationType, let value = destinationValue else { return nil }
        switch type {
        case "listing":     return .listing(id: value)
        case "category":    return .category(name: value)
        case "search":      return .search(query: value)
        case "externalURL": return .externalURL(urlString: value)
        default:            return nil
        }
    }
}

// MARK: - Feed View Model

@MainActor
class FeedViewModel: ObservableObject {
    @Published var listings: [UserListing] = []
    @Published var promotedBanners: [PromotedBanner] = []
    @Published var isLoading = false
    @Published var hasMore = true

    private var lastDoc: DocumentSnapshot?
    private let db = Firestore.firestore()

    func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        async let pageFetch = ListingRepository.shared.fetchFeedPage()
        async let bannerFetch = fetchBanners()

        if let page = try? await pageFetch {
            listings = page.listings
            lastDoc = page.lastDocument
            hasMore = page.hasMore
        }
        if let banners = try? await bannerFetch {
            promotedBanners = banners
        }
    }

    func loadNextPage() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        guard let page = try? await ListingRepository.shared.fetchFeedPage(after: lastDoc) else { return }
        listings.append(contentsOf: page.listings)
        lastDoc = page.lastDocument
        hasMore = page.hasMore
    }

    private func fetchBanners() async throws -> [PromotedBanner] {
        let now = Date()
        let snapshot = try await db.collection("promotions")
            .whereField("isActive", isEqualTo: true)
            .getDocuments()
        return snapshot.documents
            .compactMap { try? $0.data(as: PromotedBanner.self) }
            .filter { banner in
                guard let expiresAt = banner.expiresAt else { return true }
                return expiresAt.dateValue() > now
            }
            .sorted { $0.sortOrder < $1.sortOrder }
    }
}

// MARK: - Home View

struct HomeView: View {
    @StateObject private var vm = FeedViewModel()
    @State private var carouselIndex = 0

    private let autoScrollTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchBarView()
                    .padding(.vertical, 8)
                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !vm.promotedBanners.isEmpty {
                            promotedCarousel
                                .padding(.bottom, 20)
                        }

                        Text("For you")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)

                        if vm.listings.isEmpty && !vm.isLoading {
                            emptyState
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(vm.listings) { listing in
                                    NavigationLink(destination: ListingDetailView(listing: listing)) {
                                        FeedListingCard(listing: listing)
                                    }
                                    .buttonStyle(.plain)
                                    .onAppear {
                                        if listing.id == vm.listings.last?.id {
                                            Task { await vm.loadNextPage() }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        if vm.isLoading {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 24)
                        }

                        Spacer(minLength: 32)
                    }
                }
            }
            .navigationTitle("wonni")
            .navigationBarTitleDisplayMode(.inline)
            // ── Banner routing ────────────────────────────────────────────────
            // Add a new case here whenever you add a BannerDestination case.
            .navigationDestination(for: BannerDestination.self) { destination in
                switch destination {
                case .listing(let id):
                    ListingLoaderView(listingId: id)
                case .category(let name):
                    // TODO: CategoryFeedView(category: name)
                    placeholderDestination("Category: \(name)")
                case .search(let query):
                    // TODO: SearchResultsView(query: query)
                    placeholderDestination("Search: \(query)")
                case .externalURL(let urlString):
                    if let url = URL(string: urlString) {
                        SafariView(url: url)
                    } else {
                        placeholderDestination("Invalid URL")
                    }
                }
            }
        }
        .task { await vm.loadInitial() }
        .onReceive(autoScrollTimer) { _ in
            guard vm.promotedBanners.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                carouselIndex = (carouselIndex + 1) % vm.promotedBanners.count
            }
        }
    }

    // MARK: Promoted Carousel

    private var promotedCarousel: some View {
        TabView(selection: $carouselIndex) {
            ForEach(Array(vm.promotedBanners.enumerated()), id: \.offset) { index, banner in
                PromotedBannerCard(banner: banner)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .frame(height: 200)
    }

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tag")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No listings yet")
                .font(.headline)
            Text("Be the first to sell something!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func placeholderDestination(_ label: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Coming soon").font(.headline)
            Text(label).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Promoted Banner Card

private struct PromotedBannerCard: View {
    let banner: PromotedBanner

    private var accentColor: Color {
        guard let hex = banner.colorHex else { return .blue }
        return Color(hexString: hex) ?? .blue
    }

    var body: some View {
        let card = ZStack(alignment: .bottomLeading) {
            Group {
                if let path = banner.imagePath {
                    StorageImage(path: path).scaledToFill()
                } else {
                    LinearGradient(
                        colors: [accentColor.opacity(0.7), accentColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .bottom,
                endPoint: .center
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                if let subtitle = banner.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .clipped()

        if let destination = banner.destination {
            NavigationLink(value: destination) { card }
                .buttonStyle(.plain)
        } else {
            card
        }
    }
}

// MARK: - Feed Listing Card

private struct FeedListingCard: View {
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
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let price = listing.price {
                Text(String(format: "$%.0f", price))
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
            }

            Text(listing.customTitle ?? "Untitled")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(listing.condition.displayName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1), in: Capsule())
        }
    }
}

// MARK: - Listing Loader (banner → listing destination)

private struct ListingLoaderView: View {
    let listingId: String
    @State private var listing: UserListing?

    var body: some View {
        Group {
            if let listing {
                ListingDetailView(listing: listing)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            listing = try? await ListingRepository.shared.fetchListing(id: listingId)
        }
    }
}

// MARK: - Safari View (external URL destination)

import SafariServices

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - Hex Color Extension

extension Color {
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&int) else { return nil }
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: return nil
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
