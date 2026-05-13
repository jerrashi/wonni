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
    @Published var savedSearches: [SavedSearch] = []
    @Published var isSearching = false
    @Published var hasSearched = false

    func loadInitial() async {
        async let trendFetch  = SearchRepository.shared.fetchTrending()
        async let histFetch   = SearchRepository.shared.fetchHistory()
        async let savedFetch  = SearchRepository.shared.fetchSavedSearches()
        trending      = (try? await trendFetch)  ?? []
        history       = (try? await histFetch)   ?? []
        savedSearches = (try? await savedFetch)  ?? []
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

    func saveSearch(query: String) async {
        try? await SearchRepository.shared.saveSearch(query: query)
        savedSearches = (try? await SearchRepository.shared.fetchSavedSearches()) ?? []
    }

    func removeSaved(entry: SavedSearch) async {
        try? await SearchRepository.shared.removeSavedSearch(entry: entry)
        savedSearches = (try? await SearchRepository.shared.fetchSavedSearches()) ?? []
    }

    func removeHistory(entry: SearchHistoryEntry) async {
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
                    // Bookmark: save the current query before or after submitting
                    Button {
                        Task { await vm.saveSearch(query: searchText) }
                    } label: {
                        Image(systemName: savedIcon)
                            .foregroundStyle(.blue)
                    }
                    .transition(.opacity)

                    Button {
                        searchText = ""
                        vm.hasSearched = false
                        vm.results = []
                    } label: {
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
        .animation(.easeInOut(duration: 0.15), value: searchText.isEmpty)
    }

    private var savedIcon: String {
        let key = searchText.lowercased().trimmingCharacters(in: .whitespaces)
        let alreadySaved = vm.savedSearches.contains { $0.id == key }
        return alreadySaved ? "bookmark.fill" : "bookmark"
    }

    // MARK: Idle View (saved / recent / trending)

    private var idleView: some View {
        List {
            // ── Saved searches ────────────────────────────────────────────
            if !vm.savedSearches.isEmpty {
                Section("Saved") {
                    ForEach(vm.savedSearches) { entry in
                        savedRow(entry)
                    }
                }
            }

            // ── Recent searches ───────────────────────────────────────────
            if !vm.history.isEmpty {
                Section {
                    ForEach(vm.history) { entry in
                        historyRow(entry)
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button("Clear All") { Task { await vm.clearHistory() } }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }

            // ── Trending ──────────────────────────────────────────────────
            if !vm.trending.isEmpty {
                Section("Trending") {
                    ForEach(vm.trending) { trend in
                        trendingRow(trend)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: Row Builders

    @ViewBuilder
    private func savedRow(_ entry: SavedSearch) -> some View {
        Button {
            searchText = entry.query
            Task { await submitSearch() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.blue)
                    .frame(width: 20)
                Text(entry.query)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await vm.removeSaved(entry: entry) }
            } label: {
                Label("Remove", systemImage: "bookmark.slash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                Task { await vm.removeSaved(entry: entry) }
            } label: {
                Label("Remove from Saved", systemImage: "bookmark.slash")
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ entry: SearchHistoryEntry) -> some View {
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
                Image(systemName: "arrow.up.left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await vm.removeHistory(entry: entry) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                Task { await vm.saveSearch(query: entry.query) }
            } label: {
                Label("Save Search", systemImage: "bookmark")
            }
            Divider()
            Button(role: .destructive) {
                Task { await vm.removeHistory(entry: entry) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func trendingRow(_ trend: TrendingSearch) -> some View {
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
        }
        .contextMenu {
            Button {
                Task { await vm.saveSearch(query: trend.query) }
            } label: {
                Label("Save Search", systemImage: "bookmark")
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
                Text("No results for \"\(searchText)\"")
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
