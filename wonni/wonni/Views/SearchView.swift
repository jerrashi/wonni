//
//  SearchView.swift
//  wonni
//

import SwiftUI

// MARK: - Search View Model

@MainActor
class SearchViewModel: ObservableObject {
    @Published var results: [UserListing] = []
    @Published var trending: [TrendingSearch] = []
    @Published var history: [SearchHistoryEntry] = []
    @Published var isSearching = false
    @Published var hasSearched = false

    func loadInitial() async {
        async let trendFetch = SearchRepository.shared.fetchTrending()
        async let histFetch = SearchRepository.shared.fetchHistory()
        trending = (try? await trendFetch) ?? []
        history = (try? await histFetch) ?? []
    }

    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        hasSearched = true
        results = (try? await SearchRepository.shared.search(query: trimmed)) ?? []
        try? await SearchRepository.shared.addToHistory(query: trimmed)
        history = (try? await SearchRepository.shared.fetchHistory()) ?? []
    }

    func remove(entry: SearchHistoryEntry) async {
        try? await SearchRepository.shared.removeFromHistory(entry: entry)
        history = (try? await SearchRepository.shared.fetchHistory()) ?? []
    }

    func clearHistory() async {
        try? await SearchRepository.shared.clearHistory()
        history = []
    }
}

// MARK: - Search View

struct SearchView: View {
    @StateObject private var vm = SearchViewModel()
    @State private var searchText = ""
    @FocusState private var isFocused: Bool

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Divider()

                Group {
                    if vm.isSearching {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if vm.hasSearched {
                        resultsView
                    } else {
                        idleView
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await vm.loadInitial() }
    }

    // MARK: Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search listings...", text: $searchText)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .onSubmit { Task { await submitSearch() } }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if isFocused || !searchText.isEmpty {
                Button("Cancel") {
                    searchText = ""
                    isFocused = false
                    vm.hasSearched = false
                    vm.results = []
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }

    // MARK: Idle View (trending + history)

    private var idleView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !vm.history.isEmpty {
                    historySection
                }
                if !vm.trending.isEmpty {
                    trendingSection
                }
            }
            .padding(.top, 8)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { Task { await vm.clearHistory() } }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ForEach(vm.history) { entry in
                Button {
                    searchText = entry.query
                    Task { await submitSearch() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(entry.query)
                            .foregroundStyle(.primary)
                        Spacer()
                        Button {
                            Task { await vm.remove(entry: entry) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                Divider().padding(.leading, 48)
            }
        }
    }

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trending")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            ForEach(vm.trending) { trend in
                Button {
                    searchText = trend.query
                    Task { await submitSearch() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "flame")
                            .foregroundStyle(.orange)
                            .frame(width: 20)
                        Text(trend.query)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                Divider().padding(.leading, 48)
            }
        }
    }

    // MARK: Results View

    @ViewBuilder
    private var resultsView: some View {
        if vm.results.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48)).foregroundStyle(.secondary)
                Text("No results for "\(searchText)"")
                    .font(.headline)
                Text("Try a different search term.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 60)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(vm.results) { listing in
                        NavigationLink(destination: ListingDetailView(listing: listing)) {
                            FeedListingCard(listing: listing)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: Helpers

    private func submitSearch() async {
        isFocused = false
        await vm.search(query: searchText)
    }
}

// MARK: - Feed Listing Card (search results)

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
