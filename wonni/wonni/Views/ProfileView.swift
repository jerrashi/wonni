//
//  ProfileView.swift
//  wonni
//

import SwiftUI
import SwiftData
import FirebaseStorage
import FirebaseAuth
import _PhotosUI_SwiftUI // required for PhotosPicker
import AuthenticationServices
import FirebaseFunctions
import FirebaseFirestore
import CoreLocation

enum ListingSortOption: String, CaseIterable {
    case newest = "Newest First"
    case oldest = "Oldest First"
    case priceHighToLow = "Price: High to Low"
    case priceLowToHigh = "Price: Low to High"
    case lastUpdated = "Last Updated"
    case mostLiked = "Most Liked"
}

struct ProfileView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var listings: [UserListing] = []
    @State private var isLoading = true
    @State private var showSettings = false
    @State private var showEditProfile = false
    @State private var listingToEdit: UserListing?
    
    @State private var selectedListings = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var showBulkEdit = false
    @State private var isBulkDeleting = false
    @State private var showBulkPost = false
    @State private var searchText = ""
    @State private var selectedSort: ListingSortOption = .newest
    @State private var crossPostErrorMessage: String? = nil
    @State private var showCrossPostError = false
    @State private var deleteErrorMessage: String? = nil
    @State private var showDeleteError = false
    @State private var showImportSheet = false
    @State private var showBulkImportSheet = false
    
    // Web Autofill Queue for non-API cross-posting (Mercari, Facebook)
    @State private var webAutofillQueue: [CrossPostJob] = []
    @State private var activeAutofillJob: CrossPostJob? = nil
    @State private var activeMercariJob: CrossPostJob? = nil

    @State private var profile: UserPublicProfile?
    @State private var showMercariProfileSync = false
    @State private var showSalesDashboard = false
    @State private var listingToRecordSale: UserListing?
    @State private var saleSummary: (count: Int, takeHome: Double) = (0, 0)
    @State private var soldOutListings: [UserListing] = []
    @State private var listingToRestock: UserListing?
    @State private var isSoldOutExpanded = false
    @State private var listingToMarkSoldOut: UserListing?
    @State private var listingToDelete: UserListing?
    @State private var isSellingSimilar = false

    private var user: FirebaseAuth.User? { authManager.currentUser }

    private var hasMercariListings: Bool {
        listings.contains { $0.crossPostListingIds?["mercari"] != nil }
    }
    private var pendingMercariCount: Int {
        listings.filter {
            $0.pendingMercariDeactivation == true || $0.pendingMercariRelist == true
        }.count
    }

    private var initials: String {
        let nameToUse = (user?.displayName?.isEmpty == false) ? user!.displayName! : (user?.email ?? "?")
        return nameToUse.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }
    
    private var filteredListings: [UserListing] {
        var result = listings
        
        if !searchText.isEmpty {
            result = result.filter { listing in
                let searchMatchTitle = listing.customTitle?.localizedCaseInsensitiveContains(searchText) ?? false
                let searchMatchDesc = listing.customDescription?.localizedCaseInsensitiveContains(searchText) ?? false
                return searchMatchTitle || searchMatchDesc
            }
        }
        
        switch selectedSort {
        case .newest:
            result.sort { ($0.createdAt?.dateValue() ?? Date.distantPast) > ($1.createdAt?.dateValue() ?? Date.distantPast) }
        case .oldest:
            result.sort { ($0.createdAt?.dateValue() ?? Date.distantPast) < ($1.createdAt?.dateValue() ?? Date.distantPast) }
        case .priceHighToLow:
            result.sort { ($0.price ?? 0) > ($1.price ?? 0) }
        case .priceLowToHigh:
            result.sort { ($0.price ?? 0) < ($1.price ?? 0) }
        case .lastUpdated:
            result.sort { ($0.updatedAt?.dateValue() ?? Date.distantPast) > ($1.updatedAt?.dateValue() ?? Date.distantPast) }
        case .mostLiked:
            result.sort { ($0.likesCount ?? 0) > ($1.likesCount ?? 0) }
        }
        
        return result
    }

    var body: some View {
        profileNavStack
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let job = activeMercariJob {
                    MercariAutoPosterView(job: job) {
                        activeMercariJob = nil
                        checkAndStartNextWebJob()
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: activeMercariJob?.id)
    }

    // Extracted to break the compiler's type-check budget: body stays trivial,
    // the sheet/alert chain gets its own fresh inference pass here.
    @ViewBuilder
    private var profileNavStack: some View {
        profileNavCore
            .sheet(item: $listingToEdit) { listing in
                EditListingSheet(listing: listing) { jobs in
                    Task { await loadListings() }
                    if !jobs.isEmpty {
                        self.webAutofillQueue.append(contentsOf: jobs)
                        if self.activeAutofillJob == nil {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                self.checkAndStartNextWebJob()
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showImportSheet) {
                ImportListingSheet()
            }
            .sheet(isPresented: $showBulkImportSheet) {
                BulkImportSheet()
            }
            .sheet(isPresented: $showBulkPost) {
                let selectedListingsArray = listings.filter { selectedListings.contains($0.id ?? "") }
                BulkCrossPostSheet(listingsToPost: selectedListingsArray) { platforms in
                    bulkPostListings(platforms: platforms)
                }
                .presentationDetents([.fraction(0.75), .large])
            }
            .sheet(item: $activeAutofillJob, onDismiss: {
                checkAndStartNextWebJob()
            }) { job in
                CrossPostContainerView(
                    platformName: "Facebook Marketplace",
                    listingTitle: job.title,
                    listingDescription: job.description,
                    listingPrice: job.price
                )
            }
            .task {
                await loadListings()
                await loadProfile()
                await loadSaleSummary()
            }
            .sheet(item: $listingToRestock) { listing in
                RestockSheet(listing: listing) { restockedQty in
                    Task {
                        guard let id = listing.id else { return }
                        try? await ListingRepository.shared.restockListing(id: id, quantity: restockedQty)
                        _ = try? await callCloudFunction("restockAndCascade", ["listingId": id, "quantity": restockedQty])
                        soldOutListings.removeAll { $0.id == id }
                        await loadListings()
                    }
                }
            }
            .alert("Mark as Sold Out?", isPresented: Binding(
                get: { listingToMarkSoldOut != nil },
                set: { if !$0 { listingToMarkSoldOut = nil } }
            ), presenting: listingToMarkSoldOut) { listing in
                Button("Mark Sold Out", role: .destructive) {
                    Task {
                        guard let id = listing.id else { return }
                        _ = try? await callCloudFunction("markSoldOutAndCascade", ["listingId": id])
                        listings.removeAll { $0.id == id }
                        await loadListings()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { listing in
                let title = listing.customTitle ?? "this listing"
                let hasCrossPosts = listing.crossPostStatus?.values.contains("posted") == true
                let msg = hasCrossPosts
                    ? "\"\(title)\" will be marked sold out and deactivated on all connected platforms."
                    : "\"\(title)\" will be marked as sold out."
                Text(msg)
            }
            .confirmationDialog(
                "Delete Listing?",
                isPresented: Binding(
                    get: { listingToDelete != nil },
                    set: { if !$0 { listingToDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: listingToDelete
            ) { listing in
                Button("Delete", role: .destructive) {
                    let toDelete = listing
                    listingToDelete = nil
                    Task { await deleteListing(toDelete) }
                }
                Button("Cancel", role: .cancel) { listingToDelete = nil }
            } message: { listing in
                let linkedPlatforms = listing.crossPostStatus?
                    .filter { $0.value == "posted" }
                    .keys.sorted() ?? []
                if linkedPlatforms.isEmpty {
                    Text("This listing will be permanently deleted. This cannot be undone.")
                } else {
                    Text("This listing will be permanently deleted from Wonni. This cannot be undone.\n\nNote: listings on Mercari or Facebook must be removed manually.")
                }
            }
    }

    @ViewBuilder
    private var profileNavCore: some View {
        NavigationStack {
            List(selection: $selectedListings) {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 0))

                searchAndSortBar
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 10, trailing: 20))

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.top, 60)
                        .listRowBackground(Color.clear)
                } else if listings.isEmpty && soldOutListings.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                } else {
                    if !listings.isEmpty {
                        listingsList
                    }
                    if !soldOutListings.isEmpty {
                        soldOutSection
                    }
                }
            }
            .refreshable {
                await loadProfile()
                await loadListings()
                await loadSaleSummary()
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
            .navigationTitle(editMode == .active ? "\(selectedListings.count) Selected" : "Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { profileToolbar }
            .safeAreaInset(edge: .bottom) { bulkActionBar }
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
            }
            .sheet(isPresented: $showMercariProfileSync) {
                MercariProfileSyncSheet {
                    Task { await loadListings() }
                }
            }
            .navigationDestination(isPresented: $showSalesDashboard) {
                SalesDashboardView()
            }
            .sheet(item: $listingToRecordSale) { listing in
                RecordSaleSheet(listing: listing) {
                    Task {
                        await loadListings()
                        await loadSaleSummary()
                    }
                }
            }
            .alert("Delete \(selectedListings.count) Listings?", isPresented: $isBulkDeleting) {
                Button("Delete", role: .destructive) {
                    Task { await performBulkDelete() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete Failed", isPresented: $showDeleteError, presenting: deleteErrorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            // Hold the eBay/API error until no web-autofill sheet is up — an alert can't show
            // beneath an active sheet, so without this gate it would be swallowed the moment the
            // Mercari sheet opened. Same fix as the bulk publish flow.
            .alert("Cross-Post Failed", isPresented: Binding(
                get: { showCrossPostError && activeAutofillJob == nil },
                set: { showCrossPostError = $0 }
            ), presenting: crossPostErrorMessage) { _ in
                if crossPostErrorMessage?.contains("ebay.com/bp/manage") == true || crossPostErrorMessage?.contains("bizpolicy.ebay.com") == true || crossPostErrorMessage?.contains("Business Policies") == true {
                    Button("Enable on eBay") {
                        if let url = URL(string: "https://www.ebay.com/bp/manage") {
                            UIApplication.shared.open(url)
                        }
                    }
                    Button("Go to Settings") { showSettings = true }
                    Button("Dismiss", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { message in
                Text(message)
            }
            .sheet(isPresented: $showBulkEdit) {
                BulkEditSheet(selectedListingIds: selectedListings) {
                    editMode = .inactive
                    selectedListings.removeAll()
                    Task { await loadListings() }
                }
            }
            .sheet(isPresented: $showEditProfile) {
                EditProfileSheet(
                    currentName: user?.displayName ?? "",
                    currentUsername: profile?.username ?? "",
                    currentPhotoURL: profile?.photoURL
                ) {
                    Task { await loadProfile() }
                }
            }
        }
    }
    private func loadProfile() async {
        guard let uid = user?.uid else { return }
        profile = try? await UserRepository.shared.fetchProfile(uid: uid)
    }

    private func loadSaleSummary() async {
        let allSales = (try? await SaleRepository.shared.fetchSales()) ?? []
        let takeHome = allSales.reduce(0.0) { $0 + ($1.takeHome ?? 0) }
        saleSummary = (count: allSales.count, takeHome: takeHome)
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color(UIColor.systemGray4))
                    .frame(width: 80, height: 80)
                
                if let photoURLString = profile?.photoURL, let url = URL(string: photoURLString) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                } else {
                    Text(initials)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                if let name = user?.displayName, !name.isEmpty {
                    Text(name).font(.title3.weight(.semibold))
                } else {
                    Text("No Name Set").font(.title3.weight(.semibold))
                }
                
                if let username = profile?.username {
                    Text("@\(username)").font(.subheadline).foregroundStyle(.secondary)
                }
                
                Button {
                    showEditProfile = true
                } label: {
                    Text("View Public Profile >")
                        .font(.footnote)
                        .foregroundStyle(.blue)
                }
                .padding(.top, 4)
            }
            
            Spacer()
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 4)
    }
    
    private var searchAndSortBar: some View {
        HStack {
            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search listings...", text: $searchText)
                
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            
            // Sort Picker
            Menu {
                Picker("Sort By", selection: $selectedSort) {
                    ForEach(ListingSortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .padding(10)
                    .background(Color(.systemGray6))
                    .clipShape(Circle())
            }
            .foregroundStyle(.primary)
        }
    }
    
    @ViewBuilder
    private var listingsList: some View {
        // Sales summary row
        if saleSummary.count > 0 || !listings.isEmpty {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sales")
                        .font(.title2.weight(.medium))
                    if saleSummary.count > 0 {
                        Text("\(saleSummary.count) sold · \(String(format: "$%.2f", saleSummary.takeHome)) take-home")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    showSalesDashboard = true
                } label: {
                    Text(saleSummary.count > 0 ? "View All" : "Dashboard")
                        .font(.subheadline)
                }
            }
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }

        HStack {
            Text("\(filteredListings.count) Listing\(filteredListings.count == 1 ? "" : "s")")
                .font(.title2.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            Menu {
                Button {
                    showImportSheet = true
                } label: {
                    Label("Single Item URL", systemImage: "link")
                }
                
                Button {
                    showBulkImportSheet = true
                } label: {
                    Label("Bulk from Profile", systemImage: "square.grid.2x2.fill")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import")
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12))
                .foregroundStyle(Color.accentColor)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
        .listRowSeparator(.hidden)

        ForEach(filteredListings) { listing in
            NavigationLink(destination: ListingDetailView(listing: listing)) {
                ProfileListingRow(listing: listing) {
                    listingToEdit = listing
                }
            }
            .navigationLinkIndicatorVisibility(.hidden)
            .tag(listing.id ?? "")
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    listingToRecordSale = listing
                } label: {
                    Label("Record Sale", systemImage: "dollarsign.circle")
                }
                .tint(.green)
                Button {
                    Task { await sellSimilar(listing) }
                } label: {
                    Label("Sell Similar", systemImage: "doc.on.doc")
                }
                .tint(.blue)
                .disabled(isSellingSimilar)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    listingToDelete = listing
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }

    }

    @ToolbarContentBuilder
    private var profileToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if !listings.isEmpty {
                Button {
                    if editMode == .active {
                        editMode = .inactive
                        selectedListings.removeAll()
                    } else {
                        editMode = .active
                    }
                } label: {
                    Text(editMode == .active ? "Done" : "Select")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if editMode == .inactive {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            if hasMercariListings && editMode == .inactive {
                Button { showMercariProfileSync = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        if pendingMercariCount > 0 {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                                .offset(x: 4, y: -4)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var bulkActionBar: some View {
        if editMode == .active {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button(role: .destructive) {
                        isBulkDeleting = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selectedListings.isEmpty)

                    Spacer()

                    Button {
                        showBulkPost = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Post to...")
                        }
                    }
                    .disabled(selectedListings.isEmpty)

                    Spacer()

                    Button("Edit") {
                        showBulkEdit = true
                    }
                    .disabled(selectedListings.isEmpty)
                }
                .padding()
                .background(.bar)
            }
        }
    }

    @ViewBuilder private var soldOutSection: some View {
        Button {
            withAnimation { isSoldOutExpanded.toggle() }
        } label: {
            HStack {
                Label("\(soldOutListings.count) Sold Out", systemImage: "archivebox")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: isSoldOutExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .padding(.top, 8)

        if isSoldOutExpanded {
            ForEach(soldOutListings) { listing in
                HStack(spacing: 12) {
                    if let path = listing.coverPhotoPath {
                        StorageImage(path: path)
                            .frame(width: 44, height: 44)
                            .cornerRadius(6)
                            .clipped()
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.systemGray5))
                            .frame(width: 44, height: 44)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(listing.customTitle ?? "Untitled")
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(listing.price.map { "$\(String(format: "%.2f", $0))" } ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        listingToRestock = listing
                    } label: {
                        Text("Restock")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .listRowSeparator(.hidden)
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
            async let active = ListingRepository.shared.fetchActiveListings()
            async let sold = ListingRepository.shared.fetchSoldListings()
            listings = try await active
            soldOutListings = (try? await sold) ?? []
        } catch {
            print("[ProfileView] Failed to load listings: \(error)")
        }
    }
    
    private func deleteListing(_ listing: UserListing) async {
        guard let id = listing.id else { return }
        // Delete from API-based platforms first (eBay, Etsy). Best-effort — never blocks Wonni delete.
        // Mercari/Facebook are web-only and cannot be deleted programmatically.
        let postedPlatforms = listing.crossPostStatus?
            .filter { $0.value == "posted" }
            .map { $0.key } ?? []
        if !postedPlatforms.isEmpty {
            await IntegrationRepository.shared.triggerCrossDelete(listingId: id, platforms: postedPlatforms)
        }
        do {
            try await ListingRepository.shared.deleteListing(id: id)
            listings.removeAll { $0.id == id }
        } catch {
            print("[ProfileView] Failed to delete listing: \(error)")
            deleteErrorMessage = "Couldn't fully delete this listing's photos, so it was kept — please try again."
            showDeleteError = true
        }
    }

    private func sellSimilar(_ original: UserListing) async {
        guard !isSellingSimilar, let userId = user?.uid else { return }
        isSellingSimilar = true

        let taskId = UUID()
        AppTaskQueue.shared.begin(id: taskId, label: "Copying listing…", detail: original.customTitle, accentColor: .blue)

        let newId = UUID().uuidString

        // Copy all user-customizable fields; reset platform-specific state
        var copy = UserListing(
            id: newId,
            userId: userId,
            catalogItemId: original.catalogItemId,
            inventoryUnitIds: [],
            isBundleListing: original.isBundleListing,
            bundleLabel: original.bundleLabel,
            customTitle: original.customTitle,
            customDescription: original.customDescription,
            price: original.price,
            currency: original.currency,
            quantity: original.quantity,
            condition: original.condition,
            conditionNotes: original.conditionNotes,
            photoPaths: [],
            coverPhotoPath: nil,
            shippingInfo: original.shippingInfo,
            status: .draft,
            createdAt: Timestamp(date: Date()),
            updatedAt: Timestamp(date: Date()),
            sourceAssetIdentifiers: [],
            geminiIdentificationConfirmed: false,
            sellingProfileId: original.sellingProfileId,
            ebayCategory: original.ebayCategory,
            variations: original.variations,
            variationStrategy: original.variationStrategy
        )

        // Copy brand / category / tags / personalNote
        copy.brand = original.brand
        copy.category = original.category
        copy.tags = original.tags
        copy.personalNote = original.personalNote

        // Download and re-upload photos under the new listing ID
        var newPhotoPaths: [String] = []
        let storage = StorageService.shared
        for (index, path) in original.photoPaths.enumerated() {
            AppTaskQueue.shared.update(
                id: taskId,
                detail: "Photo \(index + 1) of \(original.photoPaths.count)"
            )
            do {
                let data = try await storage.downloadImageData(path: path)
                if let image = UIImage(data: data) {
                    let newPath = try await storage.uploadListingImageWithUUID(image: image, userId: userId, listingId: newId)
                    newPhotoPaths.append(newPath)
                }
            } catch {
                print("[ProfileView] sellSimilar: failed to copy photo at \(path): \(error)")
            }
        }
        copy.photoPaths = newPhotoPaths
        copy.coverPhotoPath = newPhotoPaths.first

        do {
            _ = try await ListingRepository.shared.saveDraft(copy)
            AppTaskQueue.shared.complete(id: taskId)
            await loadListings()
            // Open EditListingSheet for the new listing
            if let newListing = listings.first(where: { $0.id == newId }) {
                listingToEdit = newListing
            } else {
                // Fallback: open with the copy struct directly
                listingToEdit = copy
            }
        } catch {
            AppTaskQueue.shared.complete(id: taskId)
            print("[ProfileView] sellSimilar: failed to save copy: \(error)")
        }

        isSellingSimilar = false
    }

    private func performBulkDelete() async {
        do {
            try await ListingRepository.shared.bulkDelete(listingIds: Array(selectedListings))
        } catch {
            // bulkDelete may throw after partially succeeding (some listings' Storage
            // cleanup failed and were left in place) — always reload below to reflect
            // whichever documents actually got deleted.
            print("[ProfileView] Failed to bulk delete listings: \(error)")
            deleteErrorMessage = error.localizedDescription
            showDeleteError = true
        }
        editMode = .inactive
        selectedListings.removeAll()
        await loadListings()
    }
    
    private func bulkPostListings(platforms: Set<String>) {
        let selectedListingsArray = listings.filter { selectedListings.contains($0.id ?? "") }
        
        var webJobs: [CrossPostJob] = []
        
        for listing in selectedListingsArray {
            guard let id = listing.id else { continue }
            
            for platform in platforms {
                if platform == "mercari" || platform == "facebook" {
                    webJobs.append(CrossPostJob(
                        platform: platform,
                        title: listing.customTitle ?? "Untitled",
                        description: listing.customDescription ?? "",
                        price: listing.price ?? 0.0,
                        listingId: id,
                        photoFirebasePaths: listing.photoPaths,
                        buyerPaysShipping: listing.shippingInfo?.buyerPaysShipping ?? false,
                        condition: listing.condition.rawValue
                    ))
                } else if platform == "ebay" {
                    // Set pending state locally first so UI updates immediately
                    if let index = listings.firstIndex(where: { $0.id == id }) {
                        var updated = listings[index]
                        var status = updated.crossPostStatus ?? [:]
                        status["ebay"] = "pending"
                        updated.crossPostStatus = status
                        listings[index] = updated
                    }
                    
                    Task {
                        do {
                            let functions = Functions.functions()
                            let _ = try await functions.httpsCallable("ebayCreateListing").call(["listingId": id])
                            await loadListings()
                        } catch {
                            print("Failed to bulk cross-post listing \(id): \(error)")
                            await loadListings()
                            let msg = extractCrossPostErrorMessage(error)
                            crossPostErrorMessage = msg
                            showCrossPostError = true
                        }
                    }
                }
            }
        }
        
        if !webJobs.isEmpty {
            self.webAutofillQueue = webJobs
            // Delay to allow BulkCrossPostSheet to fully dismiss before presenting the autofill sheet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.checkAndStartNextWebJob()
            }
        }
        
        // Clear selection
        selectedListings.removeAll()
        editMode = .inactive
    }
    
    private func checkAndStartNextWebJob() {
        guard activeAutofillJob == nil, activeMercariJob == nil else { return }
        if !webAutofillQueue.isEmpty {
            let nextJob = webAutofillQueue.removeFirst()
            if nextJob.platform == "mercari" {
                activeMercariJob = nextJob
            } else {
                activeAutofillJob = nextJob
            }
        } else {
            Task { await loadListings() }
        }
    }

    /// Extracts a user-readable error message from a Firebase FunctionsError.
    private func extractCrossPostErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        // Firebase Functions errors carry the server message in NSLocalizedDescriptionKey
        // but for failed-precondition, the actual human message is in the error itself
        if let serverMessage = nsError.userInfo["NSLocalizedDescription"] as? String,
           !serverMessage.isEmpty,
           serverMessage != "INTERNAL" {
            return serverMessage
        }
        // Fallback: use localizedDescription
        let desc = error.localizedDescription
        if desc.contains("INTERNAL") {
            return "Something went wrong while posting to eBay. Please check your eBay connection in Settings and try again."
        }
        return desc
    }
}

// MARK: - Edit Profile Sheet

struct EditProfileSheet: View {
    @State var currentName: String
    @State var currentUsername: String
    @State var currentPhotoURL: String?
    let onSave: () -> Void
    
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack {
                            ZStack {
                                Circle()
                                    .fill(Color(red: 0.3, green: 0.8, blue: 1.0))
                                    .frame(width: 80, height: 80)
                                
                                if let photoURLString = currentPhotoURL, let url = URL(string: photoURLString) {
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        ProgressView()
                                    }
                                    .frame(width: 80, height: 80)
                                    .clipShape(Circle())
                                }
                            }
                            
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                Text("Change Photo")
                                    .font(.footnote.weight(.medium))
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                
                Section("Display Name") {
                    TextField("Name", text: $currentName)
                }
                
                Section(header: Text("Username"), footer: Text("Unique username for mentioning.")) {
                    HStack {
                        Text("@").foregroundStyle(.secondary)
                        TextField("username", text: $currentUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await saveProfile() }
                        }
                        .disabled(currentName.trimmingCharacters(in: .whitespaces).isEmpty || currentUsername.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                if let newItem {
                    Task {
                        if let data = try? await newItem.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            await uploadProfilePhoto(image)
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
    
    private func uploadProfilePhoto(_ image: UIImage) async {
        guard let uid = authManager.currentUser?.uid else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let url = try await StorageService.shared.uploadProfilePhoto(image: image, userId: uid)
            currentPhotoURL = url
        } catch {
            print("Failed to upload profile photo: \(error)")
        }
    }
    
    private func saveProfile() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await authManager.updateDisplayName(currentName.trimmingCharacters(in: .whitespaces))
            
            let formattedUsername = currentUsername.trimmingCharacters(in: .whitespaces).lowercased()
            try await UserRepository.shared.updateCustomProfile(
                username: formattedUsername.isEmpty ? nil : formattedUsername,
                photoURL: currentPhotoURL
            )
            onSave()
            dismiss()
        } catch {
            print("Failed to update profile: \(error)")
        }
    }
}

// MARK: - Edit Photo Item
enum EditPhotoItem: Identifiable, Hashable {
    case existing(path: String)
    case new(id: String, image: UIImage)
    
    var id: String {
        switch self {
        case .existing(let path): return path
        case .new(let id, _): return id
        }
    }
    
    static func == (lhs: EditPhotoItem, rhs: EditPhotoItem) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}



// MARK: - Edit Listing Sheet

struct EditListingSheet: View {
    let listing: UserListing
    let onSave: ([CrossPostJob]) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var price: Double?
    @State private var description: String
    @State private var condition: ItemCondition?
    @State private var category: String
    @State private var brand: String
    @State private var isFreeShipping: Bool
    @State private var weightLbs: Double?
    @State private var lengthIn: Double?
    @State private var widthIn: Double?
    @State private var heightIn: Double?
    @State private var quantity: Int
    @State private var isSaving = false
    @State private var showAddressSetupSheet = false
    @State private var platformToEnableAfterAddressSetup = ""
    
    @StateObject private var integrationRepo = IntegrationRepository.shared
    @State private var selectedPlatforms: Set<String> = []
    @State private var initialPlatforms: Set<String> = []
    @State private var crossPostErrorMessage: String? = nil
    @State private var showCrossPostError = false

    // Manual Mercari-link entry: lets the seller attach a Mercari item ID to a listing whose ID
    // wasn't captured automatically (older posts, or a run where capture missed).
    @State private var mercariLinkInput = ""
    @State private var linkedMercariId: String?
    @State private var isLinkingMercari = false
    @State private var mercariLinkError: String?
    @State private var showMercariSync = false
    @State private var showTemplatePicker = false
    @State private var showMercariEdit = false
    @State private var applyEditsToMercari = true
    @State private var showMercariAutoEdit = false
    @State private var pendingOnSaveJobs: [CrossPostJob] = []
    @State private var pendingPhotosUpdated = false
    @State private var showShippingProfileAlert = false
    @State private var reconnectSession: ASWebAuthenticationSession?
    @State private var reconnectAnchor = WebAuthPresentationAnchor()
    @State private var showMercariReconnect = false
    /// Set when the user unlinks Mercari in this edit session. The change is kept local until
    /// "Save" so cancelling discards it; on save the Mercari fields are deleted from Firestore.
    @State private var mercariCleared = false
    @State private var showUnlinkMercariConfirm = false

    // Mercari ID inline editing (Feature 4)
    @State private var isEditingMercariId = false
    @State private var mercariIdDraft: String = ""
    @State private var showDeleteMercariConfirm = false
    @State private var isSavingMercariId = false

    // Mark as Sold Out
    @State private var showMarkSoldOutConfirm = false
    @State private var isMarkingAsSoldOut = false

    // Photo Editing
    @State private var editPhotos: [EditPhotoItem]
    @State private var newPhotosItems: [PhotosPickerItem] = []
    @State private var showPhotoEditModal = false

    init(listing: UserListing, onSave: @escaping ([CrossPostJob]) -> Void) {
        self.listing = listing
        self.onSave = onSave
        _title = State(initialValue: listing.customTitle ?? "")
        _price = State(initialValue: listing.price)
        _description = State(initialValue: listing.customDescription ?? "")
        _condition = State(initialValue: listing.condition)
        _category = State(initialValue: listing.category ?? "")
        _quantity = State(initialValue: listing.quantity ?? 1)
        _brand = State(initialValue: listing.brand ?? "")
        let ship = listing.shippingInfo
        _isFreeShipping = State(initialValue: !(ship?.buyerPaysShipping ?? true))
        _weightLbs = State(initialValue: ship?.weightLbs)
        _lengthIn = State(initialValue: ship?.packageDimensions?.lengthIn)
        _widthIn = State(initialValue: ship?.packageDimensions?.widthIn)
        _heightIn = State(initialValue: ship?.packageDimensions?.heightIn)
        
        let posted = listing.crossPostStatus?
            .filter { $1 == "posted" || $1 == "pending" }
            .map { $0.key } ?? []
        _selectedPlatforms = State(initialValue: Set(posted))
        _initialPlatforms = State(initialValue: Set(posted))
        _linkedMercariId = State(initialValue: listing.crossPostListingIds?["mercari"])
        _editPhotos = State(initialValue: listing.photoPaths.map { .existing(path: $0) })
    }
    
    var body: some View {
        NavigationStack {
            Form {
                if linkedMercariId != nil {
                    Section {
                        Toggle("Apply edits to Mercari", isOn: $applyEditsToMercari)
                            .tint(.accentColor)
                    }
                }
                photosSection
                detailsSection
                shippingSection
                marketplacesSection
                crossPostStatusSection
                markSoldOutSection
            }
            .task {
                await integrationRepo.loadIntegrations()
                await SellingSettingsRepository.shared.loadSettings()
                await clearStaleMercariPending()
            }
            .navigationTitle("Edit Listing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showTemplatePicker = true
                    } label: {
                        Label("Templates", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else if hasChanges {
                        Button("Save") {
                            // Clearing the Mercari ID requires a confirmation before saving.
                            if isEditingMercariId
                                && mercariIdDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                && linkedMercariId != nil {
                                showDeleteMercariConfirm = true
                            } else {
                                Task { await saveListing() }
                            }
                        }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showTemplatePicker) {
                TemplatePickerSheet { template in
                    applyTemplate(template)
                }
            }
            .sheet(isPresented: $showAddressSetupSheet) {
                AddressSetupSheet {
                    if !platformToEnableAfterAddressSetup.isEmpty {
                        selectedPlatforms.insert(platformToEnableAfterAddressSetup)
                        platformToEnableAfterAddressSetup = ""
                    }
                }
            }
            .sheet(isPresented: $showMercariSync) {
                if let id = linkedMercariId {
                    MercariSyncSheet(listing: listing, mercariId: id) {
                        onSave([])
                    }
                }
            }
            .sheet(isPresented: $showMercariEdit) {
                if let id = linkedMercariId,
                   let url = URL(string: "https://www.mercari.com/us/item/\(id)/") {
                    MercariListingEditSheet(
                        url: url,
                        title: title.trimmingCharacters(in: .whitespaces),
                        description: description.trimmingCharacters(in: .whitespaces),
                        price: price ?? 0
                    )
                }
            }
            .sheet(isPresented: $showMercariAutoEdit, onDismiss: {
                onSave(pendingOnSaveJobs)
                dismiss()
            }) {
                if let id = linkedMercariId {
                    MercariAutoEditSheet(listing: listing, mercariId: id, photosWereUpdated: pendingPhotosUpdated) {
                        pendingPhotosUpdated = false
                    }
                }
            }
            .confirmationDialog("Unlink Mercari listing?", isPresented: $showUnlinkMercariConfirm, titleVisibility: .visible) {
                Button("Unlink", role: .destructive) { clearMercariLocally() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the Mercari link from this listing when you Save. You can paste a new link to replace it.")
            }
            .confirmationDialog("Remove Mercari listing?", isPresented: $showDeleteMercariConfirm, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    mercariCleared = true
                    isEditingMercariId = false
                    Task { await saveListing() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the Mercari link. The listing stays live on Mercari but won't be tracked here.")
            }
            .confirmationDialog(
                "Mark as Sold Out?",
                isPresented: $showMarkSoldOutConfirm,
                titleVisibility: .visible
            ) {
                Button("Mark Sold Out", role: .destructive) {
                    Task { await markAsSoldOut() }
                }
            } message: {
                let hasCrossPosts = listing.crossPostStatus?.values.contains("posted") == true
                Text(hasCrossPosts
                    ? "This listing will be marked sold out and deactivated on all connected platforms."
                    : "This listing will be marked as sold out.")
            }
            .alert("Shipping Profile", isPresented: $showShippingProfileAlert) {
                Button("Got it", role: .cancel) {}
            } message: {
                Text("You changed who pays shipping. Remember to update your shipping profile on eBay or Etsy to match.")
            }
            .alert("Cross-Post Failed", isPresented: $showCrossPostError, presenting: crossPostErrorMessage) { _ in
                if crossPostErrorMessage?.contains("ebay.com/bp/manage") == true || crossPostErrorMessage?.contains("bizpolicy.ebay.com") == true || crossPostErrorMessage?.contains("Business Policies") == true {
                    Button("Enable on eBay") {
                        if let url = URL(string: "https://www.ebay.com/bp/manage") {
                            UIApplication.shared.open(url)
                        }
                    }
                    Button("Dismiss", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { message in
                Text(message)
            }
        }
    }
    
    // MARK: - Mark as Sold Out

    @ViewBuilder private var markSoldOutSection: some View {
        Section {
            Button {
                showMarkSoldOutConfirm = true
            } label: {
                HStack {
                    if isMarkingAsSoldOut {
                        ProgressView().scaleEffect(0.85)
                    } else {
                        Image(systemName: "xmark.circle")
                    }
                    Text(isMarkingAsSoldOut ? "Marking as sold out…" : "Mark as Sold Out")
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .disabled(isMarkingAsSoldOut)
        } footer: {
            Text("Deactivates this listing on all connected platforms and moves it to the Sold Out section.")
                .font(.caption)
        }
    }

    private func markAsSoldOut() async {
        guard let id = listing.id else { return }
        isMarkingAsSoldOut = true
        _ = try? await callCloudFunction("markSoldOutAndCascade", ["listingId": id])
        isMarkingAsSoldOut = false
        dismiss()
    }

    // MARK: Cross-post status + manual Mercari linking

    @ViewBuilder private var crossPostStatusSection: some View {
        Section {
            let statusMap = listing.crossPostStatus ?? [:]
            let platforms = Set(statusMap.keys)
                .union(linkedMercariId != nil ? ["mercari"] : [])
                // Hide Mercari immediately when unlinked this session (persisted on Save).
                .subtracting(mercariCleared ? ["mercari"] : [])
                .sorted()

            if platforms.isEmpty {
                Text("Not cross-posted yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(platforms, id: \.self) { platform in
                    crossPostPlatformRow(platform: platform, statusMap: statusMap)
                }
            }

            // Manual Mercari link input when no Mercari ID is saved.
            if linkedMercariId == nil {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Paste Mercari listing link", text: $mercariLinkInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if let err = mercariLinkError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Spacer()
                        Button {
                            linkMercari()
                        } label: {
                            if isLinkingMercari { ProgressView() } else { Text("Link Mercari listing") }
                        }
                        .disabled(mercariLinkInput.trimmingCharacters(in: .whitespaces).isEmpty || isLinkingMercari)
                    }
                }
            }
        } header: {
            Text("Cross-post status")
                .textCase(nil)
        }
    }

    @ViewBuilder private var photosSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Photos").font(.headline)
                    Spacer()
                    if !editPhotos.isEmpty {
                        Button {
                            showPhotoEditModal = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.blue)
                                .padding(6)
                                .background(Color.blue.opacity(0.1))
                                .clipShape(Circle())
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(editPhotos) { item in
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    switch item {
                                    case .existing(let path):
                                        StorageImage(path: path)
                                    case .new(_, let image):
                                        Image(uiImage: image).resizable().scaledToFill()
                                    }
                                }
                                .frame(width: 80, height: 80)
                                .cornerRadius(8)
                                .clipped()
                            }
                        }
                        
                        PhotosPicker(selection: $newPhotosItems, matching: .images) {
                            VStack {
                                Image(systemName: "plus.circle").font(.title2)
                                Text("Add Photo").font(.caption2)
                            }
                            .foregroundColor(.accentColor)
                            .frame(width: 80, height: 80)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                        }
                        .onChange(of: newPhotosItems) { _, newItems in
                            Task {
                                for phItem in newItems {
                                    if let data = try? await phItem.loadTransferable(type: Data.self),
                                       let uiImage = UIImage(data: data) {
                                        editPhotos.append(.new(id: UUID().uuidString, image: uiImage))
                                    }
                                }
                                newPhotosItems = []
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .fullScreenCover(isPresented: $showPhotoEditModal) {
            PublishedPhotoModal(photos: $editPhotos)
        }
    }

    @ViewBuilder private var detailsSection: some View {
        Section("Details") {
            TextField("Title", text: $title)
            TextField("Description", text: $description, axis: .vertical)
                .lineLimit(3...6)
            Picker("Condition", selection: $condition) {
                Text("Select Condition").tag(ItemCondition?.none)
                ForEach(ItemCondition.allCases, id: \.self) { c in
                    Text(c.displayName).tag(ItemCondition?.some(c))
                }
            }
            TextField("Brand", text: $brand)
            TextField("Category", text: $category)
        }
        Section("Price & Quantity") {
            HStack {
                Text("$")
                TextField("0.00", value: $price, format: .number)
                    .keyboardType(.decimalPad)
            }
            Stepper("Quantity: \(quantity)", value: $quantity, in: 1...999)
        }
    }

    @ViewBuilder private var shippingSection: some View {
        Section("Shipping") {
            Toggle("Free Shipping (Seller Pays)", isOn: $isFreeShipping)
            HStack {
                Text("Weight (lbs)")
                Spacer()
                TextField("0.0", value: $weightLbs, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            dimensionsRow
        }
    }

    @ViewBuilder private var marketplacesSection: some View {
        Section("Marketplaces") {
            if integrationRepo.integrations.isEmpty {
                Text("No integrations available. Link them in settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let available = integrationRepo.integrations.filter { i in
                    let isAPI = i.platform == "ebay" || i.platform == "etsy"
                    return !isAPI || i.isConnected
                }
                let disconnected = integrationRepo.integrations.filter { i in
                    let isAPI = i.platform == "ebay" || i.platform == "etsy"
                    return isAPI && !i.isConnected
                }
                ForEach(available) { integration in
                    let isAPI = integration.platform == "ebay" || integration.platform == "etsy"
                    Toggle(isOn: Binding(
                        get: { selectedPlatforms.contains(integration.platform) },
                        set: { isSelected in
                            if isSelected {
                                if isAPI && SellingSettingsRepository.shared.settings?.defaultLocation.postalCode.isEmpty != false {
                                    platformToEnableAfterAddressSetup = integration.platform
                                    showAddressSetupSheet = true
                                } else {
                                    selectedPlatforms.insert(integration.platform)
                                }
                            } else {
                                selectedPlatforms.remove(integration.platform)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(platformDisplayName(integration.platform))
                            if !isAPI {
                                Text("Autofill integration")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !disconnected.isEmpty {
                    HStack(spacing: 6) {
                        Text("Connect in Settings:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(disconnected) { i in
                            Text(platformDisplayName(i.platform))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func crossPostPlatformRow(platform: String, statusMap: [String: String]) -> some View {
        let status = statusMap[platform] ?? (platform == "mercari" && linkedMercariId != nil ? "posted" : "")
        let isAPIplatform = platform == "ebay" || platform == "etsy"
        let integration = integrationRepo.integrations.first(where: { $0.platform == platform })
        let isDisconnected = isAPIplatform && status == "posted" && integration?.isConnected == false

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(platformDisplayName(platform))
                    .font(.subheadline)
                Spacer()
                if isDisconnected {
                    Label("Disconnected", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                } else {
                    crossPostStatusBadge(status)
                }
                // View link — skip if disconnected or deleted
                if !isDisconnected && status != "deleted" {
                    if platform == "mercari", let id = linkedMercariId,
                       let url = URL(string: "https://www.mercari.com/us/item/\(id)/") {
                        Link("View", destination: url)
                            .font(.caption.weight(.semibold))
                    } else if platform == "ebay",
                              let id = listing.crossPostListingIds?["ebay"],
                              let url = URL(string: "https://www.ebay.com/itm/\(id)") {
                        Link("View", destination: url)
                            .font(.caption.weight(.semibold))
                    }
                }
            }
            // Second row: action buttons
            if isDisconnected {
                Button { reconnectPlatform(platform) } label: {
                    Label("Reconnect account", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            } else if status == "deleted" {
                Button { repostToPlatform(platform) } label: {
                    Label("Listing deleted — Repost", systemImage: "arrow.up.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else if platform == "mercari", linkedMercariId != nil {
                if isEditingMercariId {
                    // Inline ID editor with clear (X) button
                    HStack(spacing: 8) {
                        TextField("Mercari listing ID or URL", text: $mercariIdDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption)
                        if !mercariIdDraft.isEmpty {
                            Button {
                                mercariIdDraft = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Button("Cancel") {
                            isEditingMercariId = false
                            mercariIdDraft = linkedMercariId ?? ""
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                        Spacer()
                        if mercariIdDraft.isEmpty {
                            Text("Saves without a Mercari link")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            Task { await saveMercariIdOnly() }
                        } label: {
                            if isSavingMercariId {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Text("Save")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isSavingMercariId)
                    }
                } else {
                    Button {
                        mercariIdDraft = linkedMercariId ?? ""
                        isEditingMercariId = true
                    } label: {
                        Label("Edit ID", systemImage: "pencil")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .contextMenu {
            if platform == "mercari", linkedMercariId != nil {
                Button {
                    showMercariEdit = true
                } label: {
                    Label("Edit listing on Mercari", systemImage: "square.and.pencil")
                }
                Button {
                    showMercariSync = true
                } label: {
                    Label("Sync from Mercari", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
                Button(role: .destructive) {
                    showUnlinkMercariConfirm = true
                } label: {
                    Label("Unlink Mercari listing", systemImage: "xmark.circle")
                }
            }
        }
        .sheet(isPresented: $showMercariReconnect) {
            MercariConnectSheet()
        }
    }

    @ViewBuilder private func crossPostStatusBadge(_ status: String) -> some View {
        switch status {
        case "posted":
            Label("Posted", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.green)
        case "failed":
            Label("Failed", systemImage: "exclamationmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.red)
        case "pending":
            Label("In progress", systemImage: "clock")
                .font(.caption).foregroundStyle(.orange)
        case "deleted":
            Label("Deleted", systemImage: "trash.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.red)
        case "":
            EmptyView()
        default:
            Text(status.capitalized).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func reconnectPlatform(_ platform: String) {
        switch platform {
        case "ebay":
            guard let clientId = Bundle.main.object(forInfoDictionaryKey: "EbayClientId") as? String, !clientId.isEmpty,
                  let ruName = Bundle.main.object(forInfoDictionaryKey: "EbayRuName") as? String, !ruName.isEmpty
            else { return }
            let isSandbox = ruName.lowercased().contains("sbx")
            var components = URLComponents(string: "https://\(isSandbox ? "auth.sandbox.ebay.com" : "auth.ebay.com")/oauth2/authorize")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientId),
                URLQueryItem(name: "redirect_uri", value: ruName),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "https://api.ebay.com/oauth/api_scope https://api.ebay.com/oauth/api_scope/sell.inventory https://api.ebay.com/oauth/api_scope/sell.account https://api.ebay.com/oauth/api_scope/sell.fulfillment https://api.ebay.com/oauth/api_scope/sell.finances https://api.ebay.com/oauth/api_scope/commerce.identity.readonly")
            ]
            guard let authURL = components.url else { return }
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "wonni") { callbackURL, _ in
                Task { @MainActor in
                    self.reconnectSession = nil
                    guard let code = URLComponents(url: callbackURL ?? URL(string: "x://")!, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "code" })?.value else { return }
                    try? await IntegrationRepository.shared.linkPlatformWithCode(platform: "ebay", code: code)
                }
            }
            session.presentationContextProvider = reconnectAnchor
            session.prefersEphemeralWebBrowserSession = false
            reconnectSession = session
            session.start()
        case "mercari":
            showMercariReconnect = true
        default:
            break
        }
    }

    private func repostToPlatform(_ platform: String) {
        guard let id = listing.id else { return }
        Task {
            do {
                let functions = Functions.functions()
                if platform == "ebay" {
                    let _ = try await functions.httpsCallable("ebayCreateListing").call(["listingId": id])
                }
            } catch {
                let msg = extractCrossPostErrorMessage(error)
                await MainActor.run { crossPostErrorMessage = msg; showCrossPostError = true }
            }
        }
    }

    /// Extracts a Mercari item ID ("m" + digits) from a pasted listing URL or raw ID.
    private func parseMercariItemId(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"/item/(m[A-Za-z0-9]+)"#, options: .regularExpression) {
            return String(trimmed[range]).replacingOccurrences(of: "/item/", with: "")
        }
        if let range = trimmed.range(of: #"\bm\d{6,}\b"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        return nil
    }

    private func linkMercari() {
        mercariLinkError = nil
        guard let itemId = parseMercariItemId(mercariLinkInput) else {
            mercariLinkError = "Couldn't find a Mercari item ID in that link."
            return
        }
        guard let listingId = listing.id else { return }
        isLinkingMercari = true
        Task {
            do {
                try await Firestore.firestore().collection("listings").document(listingId).updateData([
                    "crossPostListingIds.mercari": itemId,
                    // Providing the link asserts it's live — mark posted so the badge stops showing
                    // "pending" and no further auto-post is attempted.
                    "crossPostStatus.mercari": "posted",
                    "updatedAt": Timestamp(date: Date())
                ])
                linkedMercariId = itemId
                mercariLinkInput = ""
            } catch {
                mercariLinkError = "Couldn't save the link. Check your connection and try again."
            }
            isLinkingMercari = false
        }
    }

    @ViewBuilder private var dimensionsRow: some View {
        HStack {
            Text("L (in)")
            TextField("0", value: $lengthIn, format: .number).keyboardType(.decimalPad).frame(maxWidth: 50)
            Spacer()
            Text("W")
            TextField("0", value: $widthIn, format: .number).keyboardType(.decimalPad).frame(maxWidth: 50)
            Spacer()
            Text("H")
            TextField("0", value: $heightIn, format: .number).keyboardType(.decimalPad).frame(maxWidth: 50)
        }
    }

    private var photosChanged: Bool {
        let currentPaths: [String] = editPhotos.compactMap {
            if case .existing(let p) = $0 { return p } else { return nil }
        }
        let hasNew = editPhotos.contains { if case .new = $0 { return true } else { return false } }
        return hasNew || currentPaths != listing.photoPaths
    }

    private var coreFieldsChanged: Bool {
        title != (listing.customTitle ?? "") ||
        price != listing.price ||
        description != (listing.customDescription ?? "") ||
        condition != listing.condition ||
        category != (listing.category ?? "") ||
        brand != (listing.brand ?? "") ||
        quantity != (listing.quantity ?? 1)
    }

    private var shippingChanged: Bool {
        let s = listing.shippingInfo
        return isFreeShipping != !(s?.buyerPaysShipping ?? true) ||
            weightLbs != s?.weightLbs ||
            lengthIn != s?.packageDimensions?.lengthIn ||
            widthIn != s?.packageDimensions?.widthIn ||
            heightIn != s?.packageDimensions?.heightIn
    }

    private var hasChanges: Bool {
        coreFieldsChanged || shippingChanged ||
        selectedPlatforms != initialPlatforms ||
        mercariCleared || photosChanged ||
        (isEditingMercariId && mercariIdDraft != (linkedMercariId ?? "")) ||
        !mercariLinkInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Saves just the Mercari listing ID without requiring a full listing save.
    private func saveMercariIdOnly() async {
        guard let listingId = listing.id else { return }
        isSavingMercariId = true
        defer { isSavingMercariId = false }
        let trimmed = mercariIdDraft.trimmingCharacters(in: .whitespaces)
        do {
            if trimmed.isEmpty {
                try await Firestore.firestore().collection("listings").document(listingId).updateData([
                    "crossPostListingIds.mercari": FieldValue.delete(),
                    "crossPostStatus.mercari": FieldValue.delete(),
                    "updatedAt": Timestamp(date: Date())
                ])
                linkedMercariId = nil
            } else if let parsedId = parseMercariItemId(trimmed) {
                try await Firestore.firestore().collection("listings").document(listingId).updateData([
                    "crossPostListingIds.mercari": parsedId,
                    "crossPostStatus.mercari": "posted",
                    "updatedAt": Timestamp(date: Date())
                ])
                linkedMercariId = parsedId
            } else {
                return
            }
        } catch {
            print("[EditListingSheet] saveMercariIdOnly failed: \(error)")
        }
        isEditingMercariId = false
    }

    /// Marks the Mercari association for removal *locally* — the row hides, the toggle clears,
    /// and the manual-link field reappears so the user can paste a replacement. Nothing is
    /// written to Firestore until "Save" (see saveListing); cancelling discards it.
    private func clearMercariLocally() {
        linkedMercariId = nil
        selectedPlatforms.remove("mercari")
        mercariLinkError = nil
        mercariCleared = true
    }

    /// If the listing has been stuck in "pending" for > 90 seconds the auto-poster likely exited
    /// mid-flow. Clear it so the user can delete or re-link the Mercari ID. Zero extra Firebase
    /// reads — we already have the listing and the start time lives in UserDefaults.
    private func clearStaleMercariPending() async {
        guard let listingId = listing.id,
              listing.crossPostStatus?["mercari"] == "pending",
              let startTime = UserDefaults.standard.object(
                  forKey: "mercariPendingStart_\(listingId)") as? Double
        else { return }
        let age = Date().timeIntervalSince1970 - startTime
        guard age > 90 else { return }
        UserDefaults.standard.removeObject(forKey: "mercariPendingStart_\(listingId)")
        try? await Firestore.firestore().collection("listings").document(listingId).updateData([
            "crossPostStatus.mercari": FieldValue.delete(),
            "updatedAt": Timestamp(date: Date())
        ])
        print("[EditListingSheet] Cleared stale mercari=pending for listing \(listingId) (age: \(Int(age))s)")
    }

    private func applyTemplate(_ template: ListingTemplate) {
        if let t = template.title, !t.isEmpty { title = t }
        if let d = template.customDescription, !d.isEmpty { description = d }
        if let c = template.condition, let cond = ItemCondition(rawValue: c) { condition = cond }
        if let b = template.brand, !b.isEmpty { brand = b }
        if let cat = template.category, !cat.isEmpty { category = cat }
        if let free = template.isFreeShipping { isFreeShipping = free }
        if let w = template.weightLbs { weightLbs = w }
        if let dims = template.packageDimensions {
            lengthIn = dims.lengthIn; widthIn = dims.widthIn; heightIn = dims.heightIn
        }
        if let platforms = template.platforms, !platforms.isEmpty {
            selectedPlatforms = selectedPlatforms.union(Set(platforms))
        }
        // Append template photos that aren't already present
        for path in template.photoPaths where !editPhotos.contains(where: { $0.id == path }) {
            editPhotos.append(.existing(path: path))
        }
    }

    private func saveListing() async {
        guard let id = listing.id else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            var dims: PackageDimensions?
            if let l = lengthIn, let w = widthIn, let h = heightIn {
                dims = PackageDimensions(lengthIn: l, widthIn: w, heightIn: h)
            }
            
            var finalPhotoPaths: [String] = []
            for item in editPhotos {
                switch item {
                case .existing(let path):
                    finalPhotoPaths.append(path)
                case .new(_, let image):
                    if let newPath = try? await StorageService.shared.uploadListingImageWithUUID(image: image, userId: listing.userId, listingId: id) {
                        finalPhotoPaths.append(newPath)
                    }
                }
            }
            
            let pathsToDelete = listing.photoPaths.filter { !finalPhotoPaths.contains($0) }
            if !pathsToDelete.isEmpty {
                let userId = listing.userId
                Task {
                    for path in pathsToDelete {
                        do {
                            try await StorageService.shared.deletePhoto(path: path, userId: userId)
                        } catch {
                            print("[EditListingSheet] Failed to delete photo at \(path): \(error)")
                            await MainActor.run {
                                UploadManager.shared.cleanupError = "Couldn't fully delete a removed photo. It may still be using storage."
                            }
                        }
                    }
                }
            }
            
            try await ListingRepository.shared.updateFields(
                id: id,
                title: title.trimmingCharacters(in: .whitespaces),
                price: price,
                description: description.trimmingCharacters(in: .whitespaces),
                condition: condition,
                brand: brand.isEmpty ? nil : brand.trimmingCharacters(in: .whitespaces),
                category: category.isEmpty ? nil : category.trimmingCharacters(in: .whitespaces),
                quantity: quantity,
                weightLbs: weightLbs,
                packageDimensions: dims,
                buyerPaysShipping: !isFreeShipping,
                photoPaths: finalPhotoPaths,
                coverPhotoPath: finalPhotoPaths.first
            )
            
            let added = selectedPlatforms.subtracting(initialPlatforms)
            let removed = initialPlatforms.subtracting(selectedPlatforms)
            let alreadyPosted = initialPlatforms.intersection(selectedPlatforms)

            var newWebJobs: [CrossPostJob] = []

            // Push edits to already-live eBay listings.
            // Push edits to already-live API listings
            for platform in alreadyPosted where platform == "ebay" || platform == "etsy" {
                let fn = platform == "ebay" ? "ebayUpdateListing" : "etsyUpdateListing"
                Task {
                    do {
                        let _ = try await Functions.functions().httpsCallable(fn).call(["listingId": id])
                    } catch {
                        let msg = extractCrossPostErrorMessage(error)
                        if msg.localizedLowercase.contains("not found") {
                            try? await Firestore.firestore().collection("listings").document(id).updateData([
                                "crossPostStatus.\(platform)": "deleted"
                            ])
                        } else {
                            await MainActor.run { crossPostErrorMessage = msg; showCrossPostError = true }
                        }
                    }
                }
            }

            for platform in added {
                if platform == "ebay" || platform == "etsy" {
                    let fn = platform == "ebay" ? "ebayCreateListing" : "etsyCreateListing"
                    Task {
                        do {
                            let _ = try await Functions.functions().httpsCallable(fn).call(["listingId": id])
                        } catch {
                            let msg = extractCrossPostErrorMessage(error)
                            await MainActor.run { crossPostErrorMessage = msg; showCrossPostError = true }
                        }
                    }
                } else if platform == "mercari" || platform == "facebook" {
                    newWebJobs.append(CrossPostJob(
                        platform: platform,
                        title: title.trimmingCharacters(in: .whitespaces),
                        description: description.trimmingCharacters(in: .whitespaces),
                        price: price ?? 0.0,
                        listingId: id,
                        photoFirebasePaths: listing.photoPaths,
                        buyerPaysShipping: !isFreeShipping,
                        condition: (condition ?? listing.condition).rawValue
                    ))
                }
            }

            for platform in removed {
                if platform == "ebay" || platform == "etsy" {
                    let fn = platform == "ebay" ? "ebayDeleteListing" : "etsyDeleteListing"
                    Task {
                        _ = try? await callCloudFunction(fn, ["listingId": id])
                    }
                }
            }

            // Persist a Mercari unlink chosen this session. Mercari has no API delete (the listing
            // stays live on Mercari); we just drop the local association so it's no longer marked
            // posted here and can be re-linked or re-posted.
            if mercariCleared {
                try? await Firestore.firestore().collection("listings").document(id).updateData([
                    "crossPostListingIds.mercari": FieldValue.delete(),
                    "crossPostStatus.mercari": FieldValue.delete()
                ])
            }

            // Persist a new Mercari link pasted in the "no ID" input field.
            let trimmedLink = mercariLinkInput.trimmingCharacters(in: .whitespaces)
            if !trimmedLink.isEmpty, let parsedId = parseMercariItemId(trimmedLink) {
                try? await Firestore.firestore().collection("listings").document(id).updateData([
                    "crossPostListingIds.mercari": parsedId,
                    "crossPostStatus.mercari": "posted",
                    "updatedAt": Timestamp(date: Date())
                ])
                linkedMercariId = parsedId
                mercariLinkInput = ""
            }

            // Persist a manually-edited Mercari listing ID (new link entered via Edit ID flow).
            if isEditingMercariId && !mercariCleared {
                let trimmed = mercariIdDraft.trimmingCharacters(in: .whitespaces)
                if let parsedId = parseMercariItemId(trimmed), parsedId != linkedMercariId {
                    try? await Firestore.firestore().collection("listings").document(id).updateData([
                        "crossPostListingIds.mercari": parsedId,
                        "crossPostStatus.mercari": "posted",
                        "updatedAt": Timestamp(date: Date())
                    ])
                    linkedMercariId = parsedId
                }
                isEditingMercariId = false
            }

            // Shipping profile alert: if buyer-pays-shipping changed on a live API listing
            let shippingChanged = isFreeShipping != !(listing.shippingInfo?.buyerPaysShipping ?? true)
            let hasLiveAPIListing = alreadyPosted.contains("ebay") || alreadyPosted.contains("etsy")
            if shippingChanged && hasLiveAPIListing {
                showShippingProfileAlert = true
            }

            // Mercari update logic: if Mercari is linked, the user left the toggle on,
            // and a Mercari-visible field (title, description, price, condition) changed.
            // Quantity, weight, dimensions are not editable on Mercari.
            let mercariIsLive = linkedMercariId != nil
            let mercariFieldsChanged =
                title.trimmingCharacters(in: .whitespaces) != (listing.customTitle ?? "") ||
                description.trimmingCharacters(in: .whitespaces) != (listing.customDescription ?? "") ||
                price != listing.price ||
                condition != listing.condition ||
                photosChanged
            if mercariIsLive && mercariFieldsChanged && applyEditsToMercari {
                pendingOnSaveJobs = newWebJobs
                pendingPhotosUpdated = photosChanged
                showMercariAutoEdit = true
            } else {
                onSave(newWebJobs)
                dismiss()
            }
        } catch {
            print("Failed to save listing: \(error)")
        }
    }
    
    private func platformDisplayName(_ platform: String) -> String {
        switch platform {
        case "ebay": return "eBay"
        case "etsy": return "Etsy"
        case "mercari": return "Mercari"
        case "facebook": return "Facebook Marketplace"
        default: return platform.capitalized
        }
    }

    private func extractCrossPostErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if let serverMessage = nsError.userInfo["NSLocalizedDescription"] as? String,
           !serverMessage.isEmpty,
           serverMessage != "INTERNAL" {
            return serverMessage
        }
        let desc = error.localizedDescription
        if desc.contains("INTERNAL") {
            return "Something went wrong while posting to eBay. Please check your eBay connection in Settings and try again."
        }
        return desc
    }
}

// MARK: - Profile Listing Row

private struct ProfileListingRow: View {
    let listing: UserListing
    let onEdit: () -> Void

    var priceText: String {
        guard let price = listing.price else { return "Price TBD" }
        return String(format: "$%.2f", price)
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let path = listing.coverPhotoPath {
                    StorageImage(path: path)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(listing.customTitle ?? "Untitled")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(priceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if let statuses = listing.crossPostStatus, !statuses.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(statuses.sorted(by: { $0.key < $1.key }), id: \.key) { platform, status in
                            PlatformStatusBadge(platform: platform, status: status)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            
            Spacer()
            
            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color(.systemGray3))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
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
                
                if let statuses = listing.crossPostStatus, !statuses.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(statuses.sorted(by: { $0.key < $1.key }), id: \.key) { platform, status in
                            PlatformStatusBadge(platform: platform, status: status)
                        }
                    }
                    .padding(.top, 2)
                }
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

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var authManager: AuthManager

    @AppStorage("saveToCameraRoll") private var saveToCameraRoll: Bool = true
    @AppStorage("showCameraGrid") private var showCameraGrid: Bool = false
    @State private var showSignOutConfirm = false
    @StateObject private var integrationRepo = IntegrationRepository.shared
    @State private var showLinkAlert = false
    @State private var selectedPlatformToLink = ""
    @State private var linkUsername = ""
    @State private var activeSession: ASWebAuthenticationSession?
    @State private var anchorProvider = WebAuthPresentationAnchor()
    @State private var showMercariLogin = false
    @State private var showEtsySetupAlert = false
    @State private var etsySetupMissingShipping = false
    @State private var showEtsyConnectError = false
    @State private var etsyConnectErrorMessage = ""
    @State private var etsySetupMissingReturn = false
    
    // Sales dashboard settings (Firestore-backed for cross-device sync)
    @State private var mercariAutoImport: Bool = true

    // Selling Settings State
    @StateObject private var settingsRepo = SellingSettingsRepository.shared
    @State private var addressLine1 = ""
    @State private var city = ""
    @State private var stateOrProvince = ""
    @State private var postalCode = ""
    @State private var country = "US"
    @State private var shippingType = "calculated"
    @State private var buyerPaysShipping = true
    @State private var returnsAccepted = false
    @State private var returnWindowDays = 30
    @State private var isSavingSettings = false
    
    @State private var settingsAlertTitle = ""
    @State private var settingsAlertMessage = ""
    @State private var showSettingsAlert = false
    
    @StateObject private var locationHelper = LocationHelper.shared
    
    enum Field: Hashable {
        case addressLine1, city, stateOrProvince, postalCode, country
    }
    @FocusState private var focusedField: Field?
    
    private func platformDisplayName(_ platform: String) -> String {
        switch platform {
        case "ebay": return "eBay"
        case "etsy": return "Etsy"
        case "mercari": return "Mercari (Autofill)"
        case "facebook": return "Facebook Marketplace (Autofill)"
        default: return platform.capitalized
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Camera Preferences")) {
                    Toggle(isOn: $saveToCameraRoll) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Save to Camera Roll")
                                .font(.body)
                            Text("Automatically save captured photos to your device library.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Toggle(isOn: $showCameraGrid) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Show Camera Grid")
                                .font(.body)
                            Text("Display a 3x3 grid overlay to align photos.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section(header: Text("Marketplace Integrations")) {
                    if integrationRepo.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else {
                        ForEach(integrationRepo.integrations) { integration in
                            PlatformRowView(
                                integration: integration,
                                onConnect: { connectPlatform(integration: integration) },
                                onDisconnect: { disconnectPlatform(platform: integration.platform) }
                            )
                        }
                    }
                }

                Section(header: Text("Listing Templates")) {
                    NavigationLink {
                        ListingTemplatesView()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Manage templates")
                            Text("Reusable fields (title, description, shipping, platforms, photos) applied when creating or editing a listing.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("Sales")) {
                    Toggle(isOn: $mercariAutoImport) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto-import Mercari Sales")
                                .font(.body)
                            Text("When syncing, automatically record all new Mercari sales. Turn off to review and select which sales to import.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: mercariAutoImport) { _, newValue in
                        Task { await IntegrationRepository.shared.saveSalesDashboardSettings(mercariAutoImport: newValue) }
                    }
                }

                Section(header: Text("Mercari Shipping")) {
                    NavigationLink {
                        MercariShippingPreferencesView()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Shipping preferences")
                            Text("How autofill picks weight, label, and carrier when posting to Mercari.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("Selling Settings")) {
                    if settingsRepo.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else {
                        // Business Policies Disabled Warning
                        if settingsRepo.settings?.businessPoliciesDisabled == true {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("eBay Business Policies Required")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                }
                                Text("To cross-post to eBay, please enable Business Policies in your eBay account. This allows Wonni to automatically configure payment, returns, and shipping on eBay.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                if let url = URL(string: "https://www.ebay.com/bp/manage") {
                                    Link("Enable Business Policies on eBay →", destination: url)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.vertical, 8)
                        }

                        // Ship From Address
                        Button(action: autofillLocation) {
                            HStack {
                                if locationHelper.isLocating {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .padding(.trailing, 4)
                                    Text("Locating...")
                                } else {
                                    Image(systemName: "location.fill")
                                    Text("Use Current Location")
                                }
                            }
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                        }
                        .disabled(locationHelper.isLocating)

                        Group {
                            TextField("Address Line 1", text: $addressLine1)
                                .focused($focusedField, equals: .addressLine1)
                                .submitLabel(.next)
                            TextField("City", text: $city)
                                .focused($focusedField, equals: .city)
                                .submitLabel(.next)
                            TextField("State / Province", text: $stateOrProvince)
                                .focused($focusedField, equals: .stateOrProvince)
                                .submitLabel(.next)
                            TextField("Postal Code", text: $postalCode)
                                .focused($focusedField, equals: .postalCode)
                                .submitLabel(.next)
                                .keyboardType(.numberPad)
                            TextField("Country", text: $country)
                                .focused($focusedField, equals: .country)
                                .submitLabel(.done)
                        }
                        .onSubmit {
                            switch focusedField {
                            case .addressLine1: focusedField = .city
                            case .city: focusedField = .stateOrProvince
                            case .stateOrProvince: focusedField = .postalCode
                            case .postalCode: focusedField = .country
                            default: focusedField = nil
                            }
                        }

                        // Shipping Preference
                        Picker("Shipping Type", selection: $shippingType) {
                            Text("Calculated").tag("calculated")
                            Text("Media Mail (USPS)").tag("mediaMailUSPS")
                            Text("First Class Envelope").tag("firstClassEnvelope")
                        }
                        .pickerStyle(.menu)

                        Toggle("Buyer Pays Shipping", isOn: $buyerPaysShipping)

                        // Returns
                        Toggle("Accept Returns", isOn: $returnsAccepted)
                        if returnsAccepted {
                            Picker("Return Window", selection: $returnWindowDays) {
                                Text("14 Days").tag(14)
                                Text("30 Days").tag(30)
                                Text("60 Days").tag(60)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }
                
                Section(header: Text("Account")) {
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        HStack {
                            Text("Sign Out")
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        saveSellingSettings(showAlertOnSuccess: false)
                        dismiss()
                    }
                }
            }
            .alert("Link \(platformDisplayName(selectedPlatformToLink))", isPresented: $showLinkAlert) {
                TextField("Username / Shop Name", text: $linkUsername)
                    .textInputAutocapitalization(.never)
                Button("Link") {
                    let user = linkUsername.trimmingCharacters(in: .whitespaces)
                    if !user.isEmpty {
                        Task {
                            try? await integrationRepo.linkPlatformWithMock(platform: selectedPlatformToLink, username: user)
                            linkUsername = ""
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    linkUsername = ""
                }
            } message: {
                Text("Enter your account username or shop name to link in sandbox mode.")
            }
            .alert("Sign Out", isPresented: $showSignOutConfirm) {
                Button("Sign Out", role: .destructive) {
                    try? authManager.signOut()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(settingsAlertTitle, isPresented: $showSettingsAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(settingsAlertMessage)
            }
            .task {
                await integrationRepo.loadIntegrations()
                await settingsRepo.loadSettings()
                loadLocalSettingsState()
                mercariAutoImport = await IntegrationRepository.shared.loadSalesDashboardSettings()
            }
            .onDisappear {
                saveSellingSettings(showAlertOnSuccess: false)
            }
            .sheet(isPresented: $showMercariLogin) {
                MercariConnectSheet()
            }
            .alert("Etsy Connection Failed", isPresented: $showEtsyConnectError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(etsyConnectErrorMessage)
            }
            .alert("Finish Etsy Setup", isPresented: $showEtsySetupAlert) {
                if etsySetupMissingShipping {
                    Button("Add Shipping Profile") {
                        if let url = URL(string: "https://www.etsy.com/your-shop/shipping-settings") {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                if etsySetupMissingReturn {
                    Button("Add Return Policy") {
                        if let url = URL(string: "https://www.etsy.com/your-shop/policies/edit") {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Button("Later", role: .cancel) {}
            } message: {
                let items = [
                    etsySetupMissingShipping ? "a shipping profile" : nil,
                    etsySetupMissingReturn   ? "a return policy"    : nil,
                ].compactMap { $0 }.joined(separator: " and ")
                Text("Before you can post to Etsy, your shop needs \(items). Tap below to set them up on Etsy.")
            }
        }
    }

    // MARK: - Handlers
    
    private func connectPlatform(integration: PlatformIntegration) {
        if integration.platform == "ebay" {
            startEbayOAuth()
        } else if integration.platform == "mercari" {
            showMercariLogin = true
        } else if integration.platform == "etsy" {
            startEtsyOAuth()
        } else {
            selectedPlatformToLink = integration.platform
            showLinkAlert = true
        }
    }
    
    private func disconnectPlatform(platform: String) {
        Task {
            try? await integrationRepo.unlinkPlatform(platform: platform)
        }
    }
    
    private func startEbayOAuth() {
        guard let clientId = Bundle.main.object(forInfoDictionaryKey: "EbayClientId") as? String,
              !clientId.isEmpty,
              let ruName = Bundle.main.object(forInfoDictionaryKey: "EbayRuName") as? String,
              !ruName.isEmpty else {
            print("[SettingsSheet] Error: EbayClientId or EbayRuName is not set in Info.plist / Secrets.xcconfig")
            return
        }
        
        let isSandbox = ruName.lowercased().contains("sbx") || ruName.lowercased().contains("sandbox")
        let authHost = isSandbox ? "auth.sandbox.ebay.com" : "auth.ebay.com"
        
        var components = URLComponents(string: "https://\(authHost)/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: ruName),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://api.ebay.com/oauth/api_scope https://api.ebay.com/oauth/api_scope/sell.inventory https://api.ebay.com/oauth/api_scope/sell.account https://api.ebay.com/oauth/api_scope/sell.fulfillment https://api.ebay.com/oauth/api_scope/sell.finances https://api.ebay.com/oauth/api_scope/commerce.identity.readonly")
        ]

        guard let authURL = components.url else {
            print("[SettingsSheet] Error: Could not construct eBay auth URL")
            return
        }
        
        
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: "wonni"
        ) { callbackURL, error in
            // The callback fires on an arbitrary thread; dispatch to MainActor
            // and use the shared singleton directly — the @StateObject wrapper
            // may be deallocated if the sheet dismisses during the OAuth redirect.
            Task { @MainActor in
                self.activeSession = nil
                if let error = error {
                    print("[SettingsSheet] Authentication session error callback: \(error.localizedDescription)")
                    return
                }

                guard let callbackURL = callbackURL else {
                    print("[SettingsSheet] Authentication session callbackURL is nil")
                    return
                }

                let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
                if let code = callbackComponents?.queryItems?.first(where: { $0.name == "code" })?.value {
                    do {
                        try await IntegrationRepository.shared.linkPlatformWithCode(platform: "ebay", code: code)
                    } catch {
                        print("[SettingsSheet] Error linking platform with code: \(error)")
                    }
                } else {
                    print("[SettingsSheet] No authorization code found in callback URL query parameters")
                }
            }
        }
        
        session.presentationContextProvider = anchorProvider
        // Set to false: eBay's OAuth uses server-side session cookies.
        // In ephemeral (private) mode those cookies are absent, causing the
        // post-login redirect to fail and the session to report canceledLogin.
        session.prefersEphemeralWebBrowserSession = false
        
        self.activeSession = session
        session.start()
    }

    private func startEtsyOAuth() {
        let clientId = (Bundle.main.object(forInfoDictionaryKey: "EtsyClientId") as? String) ?? ""
        guard !clientId.isEmpty, clientId != "YOUR_ETSY_CLIENT_ID_HERE" else { return }

        let codeVerifier = EtsyPKCEHelper.generateCodeVerifier()
        let codeChallenge = EtsyPKCEHelper.generateCodeChallenge(from: codeVerifier)
        let redirectUri = "https://wonni-app.web.app/oauth/etsy"
        let state = String(UUID().uuidString.prefix(8))

        var components = URLComponents(string: "https://www.etsy.com/oauth/connect")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: "listings_w listings_r shops_r transactions_r"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authURL = components.url else { return }

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "wonni") { callbackURL, error in
            Task { @MainActor in
                self.activeSession = nil
                guard let callbackURL,
                      let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                          .queryItems?.first(where: { $0.name == "code" })?.value
                else { return }

                do {
                    let functions = Functions.functions()
                    let result = try await functions.httpsCallable("etsyExchangeToken").call([
                        "code": code, "codeVerifier": codeVerifier, "redirectUri": redirectUri
                    ])
                    if (result.data as? [String: Any])?["success"] as? Bool == true {
                        await integrationRepo.loadIntegrations()
                        // Check if the shop has the required shipping profile and return policy.
                        if let setup = try? await functions.httpsCallable("etsyCheckShopSetup").call([:]),
                           let setupData = setup.data as? [String: Any] {
                            let missingShipping = (setupData["hasShippingProfile"] as? Bool) == false
                            let missingReturn   = (setupData["hasReturnPolicy"]   as? Bool) == false
                            if missingShipping || missingReturn {
                                etsySetupMissingShipping = missingShipping
                                etsySetupMissingReturn   = missingReturn
                                showEtsySetupAlert = true
                            }
                        }
                    }
                } catch {
                    let msg = (error as NSError).userInfo["NSLocalizedDescription"] as? String
                        ?? error.localizedDescription
                    etsyConnectErrorMessage = msg
                    showEtsyConnectError = true
                }
            }
        }
        session.presentationContextProvider = anchorProvider
        session.prefersEphemeralWebBrowserSession = false
        self.activeSession = session
        session.start()
    }

    private func loadLocalSettingsState() {
        if let currentSettings = settingsRepo.settings {
            self.addressLine1 = currentSettings.defaultLocation.addressLine1
            self.city = currentSettings.defaultLocation.city
            self.stateOrProvince = currentSettings.defaultLocation.stateOrProvince
            self.postalCode = currentSettings.defaultLocation.postalCode
            self.country = currentSettings.defaultLocation.country.isEmpty ? "US" : currentSettings.defaultLocation.country
            self.shippingType = currentSettings.shippingType
            self.buyerPaysShipping = currentSettings.buyerPaysShipping
            self.returnsAccepted = currentSettings.returnsAccepted
            self.returnWindowDays = currentSettings.returnWindowDays
        }
    }
    
    private func autofillLocation() {
        locationHelper.requestLocation { components in
            if let components = components {
                self.addressLine1 = components.addressLine1
                self.city = components.city
                self.stateOrProvince = components.state
                self.postalCode = components.postalCode
                self.country = components.country
            }
        }
    }

    private func saveSellingSettings(showAlertOnSuccess: Bool = false) {
        isSavingSettings = true
        Task {
            var updated = settingsRepo.settings ?? SellingSettings()
            updated.defaultLocation.addressLine1 = addressLine1
            updated.defaultLocation.city = city
            updated.defaultLocation.stateOrProvince = stateOrProvince
            updated.defaultLocation.postalCode = postalCode
            updated.defaultLocation.country = country
            updated.shippingType = shippingType
            updated.buyerPaysShipping = buyerPaysShipping
            updated.returnsAccepted = returnsAccepted
            updated.returnWindowDays = returnWindowDays
            
            do {
                try await settingsRepo.saveSettings(updated)
                if showAlertOnSuccess {
                    await MainActor.run {
                        settingsAlertTitle = "Success"
                        settingsAlertMessage = "Selling settings saved successfully."
                        showSettingsAlert = true
                    }
                }
            } catch {
                print("[SettingsSheet] Error saving selling settings: \(error)")
                await MainActor.run {
                    settingsAlertTitle = "Error"
                    settingsAlertMessage = "Failed to save settings: \(error.localizedDescription)"
                    showSettingsAlert = true
                }
            }
            await MainActor.run {
                isSavingSettings = false
            }
        }
    }

    private func mapItemCondition(_ raw: String?) -> ItemCondition {
        switch raw {
        case "new":      return .new
        case "likeNew":  return .likeNew
        case "good":     return .good
        case "fair":     return .fair
        case "poor":     return .poor
        default:         return .good
        }
    }
}

class WebAuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .first?.windows
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

struct PlatformStatusBadge: View {
    let platform: String
    let status: String
    
    private var name: String {
        switch platform {
        case "ebay": return "eBay"
        case "etsy": return "Etsy"
        case "mercari": return "Mercari"
        case "facebook": return "FB"
        default: return platform.capitalized
        }
    }
    
    private var baseColor: Color {
        switch platform {
        case "ebay": return .blue
        case "etsy": return .orange
        case "mercari": return .purple
        case "facebook": return .blue
        default: return .secondary
        }
    }
    
    var body: some View {
        HStack(spacing: 3) {
            if status == "posted" {
                Text(name)
                    .font(.system(size: 9, weight: .bold))
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 8))
            } else if status == "pending" || status == "removing" {
                Text(name)
                    .font(.system(size: 9, weight: .bold))
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 8, height: 8)
            } else if status == "failed" {
                Text(name)
                    .font(.system(size: 9, weight: .bold))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            status == "failed" ? Color.red.opacity(0.1) :
            status == "pending" || status == "removing" ? Color.secondary.opacity(0.1) :
            baseColor.opacity(0.12)
        )
        .foregroundStyle(
            status == "failed" ? Color.red :
            status == "pending" || status == "removing" ? Color.secondary :
            baseColor
        )
        .clipShape(Capsule())
    }
}

struct BulkCrossPostSheet: View {
    let listingsToPost: [UserListing]
    let onConfirm: (Set<String>) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var integrationRepo = IntegrationRepository.shared
    @State private var selectedPlatforms: Set<String> = []
    @State private var showAddressSetupSheet = false
    @State private var platformToEnableAfterAddressSetup = ""
    /// Platforms whose toggle the user has explicitly touched. The async `.task`
    /// default-selection must never overwrite an explicit user choice made while
    /// integrations were still loading (github issue #46 — same race as
    /// PublishConfirmationSheet, this sheet never got the fix from #8).
    @State private var touchedPlatforms: Set<String> = []
    @State private var isLoadingIntegrations = true
    @State private var showEmptyPlatformsConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Cross-Posting \(listingsToPost.count) Listing(s)")) {
                    ForEach(listingsToPost) { listing in
                        HStack {
                            Text(listing.customTitle ?? "Untitled")
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            if let price = listing.price {
                                Text(String(format: "$%.2f", price))
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                }
                
                Section(header: Text("Cross-Post Platforms")) {
                    if integrationRepo.integrations.isEmpty {
                        Text("No integrations available. Set them up in Profile Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(integrationRepo.integrations) { integration in
                            let isAPI = integration.platform == "ebay" || integration.platform == "etsy"
                            Toggle(isOn: Binding(
                                get: { selectedPlatforms.contains(integration.platform) },
                                set: { isSelected in
                                    touchedPlatforms.insert(integration.platform)
                                    if isSelected {
                                        if isAPI && SellingSettingsRepository.shared.settings?.defaultLocation.postalCode.isEmpty != false {
                                            platformToEnableAfterAddressSetup = integration.platform
                                            showAddressSetupSheet = true
                                        } else {
                                            selectedPlatforms.insert(integration.platform)
                                        }
                                    } else {
                                        selectedPlatforms.remove(integration.platform)
                                    }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(platformDisplayName(integration.platform))
                                        if !isAPI {
                                            Text("Autofill")
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.purple.opacity(0.12))
                                                .foregroundStyle(.purple)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    if isAPI {
                                        Text(integration.isConnected ? "Connected as: \(integration.connectedUsername ?? "Unknown")" : "Not connected (Link in settings)")
                                            .font(.caption)
                                            .foregroundStyle(integration.isConnected ? .green : .secondary)
                                    } else {
                                        Text("Launches browser autofill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(isAPI && !integration.isConnected)
                        }
                    }
                }
            }
            .navigationTitle("Cross-Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoadingIntegrations {
                        ProgressView()
                    } else {
                        Button("Post") {
                            if selectedPlatforms.isEmpty {
                                showEmptyPlatformsConfirm = true
                            } else {
                                onConfirm(selectedPlatforms)
                                dismiss()
                            }
                        }
                        .fontWeight(.bold)
                    }
                }
            }
            .task {
                await integrationRepo.loadIntegrations()
                await SellingSettingsRepository.shared.loadSettings()
                // Default-select connected API platforms, but only those the user hasn't
                // explicitly toggled while the async load was in flight — a blanket
                // reassignment here used to wipe the user's in-flight choices.
                for platform in integrationRepo.integrations.filter({ $0.isConnected }).map({ $0.platform })
                where !touchedPlatforms.contains(platform) {
                    selectedPlatforms.insert(platform)
                }
                isLoadingIntegrations = false
            }
            .sheet(isPresented: $showAddressSetupSheet) {
                AddressSetupSheet {
                    if !platformToEnableAfterAddressSetup.isEmpty {
                        selectedPlatforms.insert(platformToEnableAfterAddressSetup)
                        platformToEnableAfterAddressSetup = ""
                    }
                }
            }
            // These listings are already live on Wonni, so an empty selection here isn't a
            // meaningful "Wonni only" action like in PublishConfirmationSheet — it's just a
            // no-op. Tell the user instead of silently dismissing.
            .alert("Select at least one platform to cross-post to.", isPresented: $showEmptyPlatformsConfirm) {
                Button("OK", role: .cancel) {}
            }
        }
    }
    
    private func platformDisplayName(_ platform: String) -> String {
        switch platform {
        case "ebay": return "eBay"
        case "etsy": return "Etsy"
        case "mercari": return "Mercari"
        case "facebook": return "Facebook Marketplace"
        default: return platform.capitalized
        }
    }
}

struct SellingSettings: Codable {
    struct DefaultLocation: Codable {
        var addressLine1: String
        var city: String
        var stateOrProvince: String
        var postalCode: String
        var country: String // "US"
        var merchantLocationKey: String?

        init(
            addressLine1: String = "",
            city: String = "",
            stateOrProvince: String = "",
            postalCode: String = "",
            country: String = "US",
            merchantLocationKey: String? = nil
        ) {
            self.addressLine1 = addressLine1
            self.city = city
            self.stateOrProvince = stateOrProvince
            self.postalCode = postalCode
            self.country = country
            self.merchantLocationKey = merchantLocationKey
        }
    }

    struct EbayPolicyIds: Codable {
        var paymentPolicyId: String?
        var returnPolicyId: String?
        var fulfillmentPolicyId: String?

        init(
            paymentPolicyId: String? = nil,
            returnPolicyId: String? = nil,
            fulfillmentPolicyId: String? = nil
        ) {
            self.paymentPolicyId = paymentPolicyId
            self.returnPolicyId = returnPolicyId
            self.fulfillmentPolicyId = fulfillmentPolicyId
        }
    }

    var shippingType: String // "calculated" | "mediaMailUSPS" | "firstClassEnvelope"
    var buyerPaysShipping: Bool

    var returnsAccepted: Bool
    var returnWindowDays: Int // 14 | 30 | 60

    var defaultLocation: DefaultLocation
    var ebayPolicyIds: EbayPolicyIds?
    var businessPoliciesDisabled: Bool?

    init(
        shippingType: String = "calculated",
        buyerPaysShipping: Bool = true,
        returnsAccepted: Bool = false,
        returnWindowDays: Int = 30,
        defaultLocation: DefaultLocation = DefaultLocation(),
        ebayPolicyIds: EbayPolicyIds? = nil,
        businessPoliciesDisabled: Bool? = nil
    ) {
        self.shippingType = shippingType
        self.buyerPaysShipping = buyerPaysShipping
        self.returnsAccepted = returnsAccepted
        self.returnWindowDays = returnWindowDays
        self.defaultLocation = defaultLocation
        self.ebayPolicyIds = ebayPolicyIds
        self.businessPoliciesDisabled = businessPoliciesDisabled
    }
}

@MainActor
class SellingSettingsRepository: ObservableObject {
    static let shared = SellingSettingsRepository()
    private let db = Firestore.firestore()

    @Published var settings: SellingSettings? = nil
    @Published var isLoading = false

    private init() {}

    private var userId: String? {
        Auth.auth().currentUser?.uid
    }

    func loadSettings() async {
        guard let uid = userId else {
            self.settings = SellingSettings()
            return
        }

        self.isLoading = true
        defer { self.isLoading = false }

        do {
            let docRef = db.collection("users")
                .document(uid)
                .collection("sellingSettings")
                .document("default")

            let document = try await docRef.getDocument()
            if document.exists {
                self.settings = try document.data(as: SellingSettings.self)
            } else {
                self.settings = SellingSettings()
            }
        } catch {
            print("[SellingSettingsRepository] Error loading settings: \(error)")
            self.settings = SellingSettings()
        }
    }
    func saveSettings(_ newSettings: SellingSettings) async throws {
        guard let uid = userId else { return }
        let docRef = db.collection("users")
            .document(uid)
            .collection("sellingSettings")
            .document("default")
        try docRef.setData(from: newSettings)
        self.settings = newSettings
    }
}

struct AddressComponents {
    var addressLine1: String = ""
    var city: String = ""
    var state: String = ""
    var postalCode: String = ""
    var country: String = "US"
}

class LocationHelper: NSObject, CLLocationManagerDelegate, ObservableObject {
    static let shared = LocationHelper()
    
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    
    @Published var isLocating = false
    @Published var error: Error? = nil
    
    private var completion: ((AddressComponents?) -> Void)?
    
    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    func requestLocation(completion: @escaping (AddressComponents?) -> Void) {
        self.completion = completion
        
        DispatchQueue.main.async {
            self.isLocating = true
            self.error = nil
        }
        
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if status == .restricted || status == .denied {
            DispatchQueue.main.async {
                self.isLocating = false
            }
            completion(nil)
        } else {
            manager.requestLocation()
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        } else if status != .notDetermined {
            DispatchQueue.main.async {
                self.isLocating = false
            }
            completion?(nil)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else {
            DispatchQueue.main.async {
                self.isLocating = false
            }
            completion?(nil)
            return
        }
        
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.isLocating = false
                if let error = error {
                    self.error = error
                    self.completion?(nil)
                    return
                }
                
                if let placemark = placemarks?.first {
                    var addr = AddressComponents()
                    if let number = placemark.subThoroughfare, let street = placemark.thoroughfare {
                        addr.addressLine1 = "\(number) \(street)"
                    } else if let street = placemark.thoroughfare {
                        addr.addressLine1 = street
                    }
                    
                    addr.city = placemark.locality ?? placemark.subAdministrativeArea ?? ""
                    addr.state = placemark.administrativeArea ?? ""
                    addr.postalCode = placemark.postalCode ?? ""
                    addr.country = placemark.isoCountryCode ?? "US"
                    
                    self.completion?(addr)
                } else {
                    self.completion?(nil)
                }
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.isLocating = false
            self.error = error
        }
        completion?(nil)
    }
}

struct AddressSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settingsRepo = SellingSettingsRepository.shared
    @StateObject private var locationHelper = LocationHelper.shared
    
    @State private var addressLine1 = ""
    @State private var city = ""
    @State private var stateOrProvince = ""
    @State private var postalCode = ""
    @State private var country = "US"
    @State private var isSaving = false
    @State private var errorMessage = ""
    
    var onSaveComplete: () -> Void
    
    // Focus State for Keyboard Navigation
    enum Field: Hashable {
        case addressLine1, city, stateOrProvince, postalCode, country
    }
    @FocusState private var focusedField: Field?
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Default Address Details")) {
                    Text("To cross-post listings to eBay/Etsy, a default shipping address is required for inventory and shipping policies.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(action: autofillLocation) {
                        HStack {
                            if locationHelper.isLocating {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .padding(.trailing, 4)
                                Text("Locating...")
                            } else {
                                Image(systemName: "location.fill")
                                Text("Use Current Location")
                            }
                        }
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                    }
                    .disabled(locationHelper.isLocating)
                    
                    TextField("Address Line 1", text: $addressLine1)
                        .focused($focusedField, equals: .addressLine1)
                        .submitLabel(.next)
                    
                    TextField("City", text: $city)
                        .focused($focusedField, equals: .city)
                        .submitLabel(.next)
                    
                    TextField("State / Province", text: $stateOrProvince)
                        .focused($focusedField, equals: .stateOrProvince)
                        .submitLabel(.next)
                    
                    TextField("Postal Code", text: $postalCode)
                        .focused($focusedField, equals: .postalCode)
                        .submitLabel(.next)
                        .keyboardType(.numberPad)
                    
                    TextField("Country", text: $country)
                        .focused($focusedField, equals: .country)
                        .submitLabel(.done)
                }
                .onSubmit {
                    switch focusedField {
                    case .addressLine1: focusedField = .city
                    case .city: focusedField = .stateOrProvince
                    case .stateOrProvince: focusedField = .postalCode
                    case .postalCode: focusedField = .country
                    default: focusedField = nil
                    }
                }
                
                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Setup Shipping Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAddress()
                    }
                    .fontWeight(.bold)
                    .disabled(addressLine1.isEmpty || city.isEmpty || stateOrProvince.isEmpty || postalCode.isEmpty || isSaving)
                }
            }
            .task {
                await settingsRepo.loadSettings()
                if let current = settingsRepo.settings {
                    addressLine1 = current.defaultLocation.addressLine1
                    city = current.defaultLocation.city
                    stateOrProvince = current.defaultLocation.stateOrProvince
                    postalCode = current.defaultLocation.postalCode
                    country = current.defaultLocation.country.isEmpty ? "US" : current.defaultLocation.country
                }
            }
        }
    }
    
    private func autofillLocation() {
        locationHelper.requestLocation { components in
            if let components = components {
                self.addressLine1 = components.addressLine1
                self.city = components.city
                self.stateOrProvince = components.state
                self.postalCode = components.postalCode
                self.country = components.country
            }
        }
    }
    
    private func saveAddress() {
        isSaving = true
        Task {
            var updated = settingsRepo.settings ?? SellingSettings()
            updated.defaultLocation.addressLine1 = addressLine1
            updated.defaultLocation.city = city
            updated.defaultLocation.stateOrProvince = stateOrProvince
            updated.defaultLocation.postalCode = postalCode
            updated.defaultLocation.country = country
            
            do {
                try await settingsRepo.saveSettings(updated)
                onSaveComplete()
                dismiss()
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}

// MARK: - PlatformRowView
struct PlatformRowView: View {
    let integration: PlatformIntegration
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(platformDisplayName(integration.platform))
                    .font(.body)
                if integration.isConnected {
                    Text("Linked as: \(integration.connectedUsername ?? "Unknown")")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text("Not Connected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if integration.isConnected {
                Button("Disconnect", role: .destructive, action: onDisconnect)
                    .buttonStyle(.borderless)
            } else {
                Button("Connect", action: onConnect)
                    .buttonStyle(.borderless)
            }
        }
    }
    
    private func platformDisplayName(_ key: String) -> String {
        switch key {
        case "ebay": return "eBay"
        case "poshmark": return "Poshmark"
        case "mercari": return "Mercari"
        case "depop": return "Depop"
        case "facebook": return "Facebook Marketplace"
        case "etsy": return "Etsy"
        default: return key.capitalized
        }
    }
}

// MARK: - RestockSheet

struct RestockSheet: View {
    let listing: UserListing
    let onRestock: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var quantity = 1
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        if let path = listing.coverPhotoPath {
                            StorageImage(path: path)
                                .frame(width: 52, height: 52)
                                .cornerRadius(8)
                                .clipped()
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(listing.customTitle ?? "Untitled")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text(listing.price.map { "$\(String(format: "%.2f", $0))" } ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Restock Quantity") {
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...999)
                }
                Section {
                    Text("This will set the listing back to active and update quantity on any connected marketplaces.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Restock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Restock") {
                            isSaving = true
                            onRestock(quantity)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}


