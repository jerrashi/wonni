//
//  ProfileView.swift
//  wonni
//

import SwiftUI
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

    @State private var profile: UserPublicProfile?

    private var user: FirebaseAuth.User? { authManager.currentUser }

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
                } else if listings.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                } else {
                    listingsList
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
            .navigationTitle(editMode == .active ? "\(selectedListings.count) Selected" : "Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
                
            }
            .safeAreaInset(edge: .bottom) {
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
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
            }
            .alert("Delete \(selectedListings.count) Listings?", isPresented: $isBulkDeleting) {
                Button("Delete", role: .destructive) {
                    Task { await performBulkDelete() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Cross-Post Failed", isPresented: $showCrossPostError, presenting: crossPostErrorMessage) { _ in
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
            .sheet(item: $listingToEdit) { listing in
                EditListingSheet(listing: listing) {
                    Task { await loadListings() }
                }
            }
            .sheet(isPresented: $showBulkPost) {
                let selectedListingsArray = listings.filter { selectedListings.contains($0.id ?? "") }
                BulkCrossPostSheet(listingsToPost: selectedListingsArray) { platforms in
                    bulkPostListings(platforms: platforms)
                }
                .presentationDetents([.fraction(0.75), .large])
            }
            .task { 
                await loadListings()
                await loadProfile()
            }
        }
    }
    
    private func loadProfile() async {
        guard let uid = user?.uid else { return }
        profile = try? await UserRepository.shared.fetchProfile(uid: uid)
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
        Text("\(filteredListings.count) Listing\(filteredListings.count == 1 ? "" : "s")")
            .font(.title2.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .listRowSeparator(.hidden)
            
        ForEach(filteredListings) { listing in
            NavigationLink(destination: ListingDetailView(listing: listing)) {
                ProfileListingRow(listing: listing) {
                    listingToEdit = listing
                }
            }
            .tag(listing.id ?? "")
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    Task { await deleteListing(listing) }
                } label: {
                    Label("Delete", systemImage: "trash")
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
    
    private func deleteListing(_ listing: UserListing) async {
        guard let id = listing.id else { return }
        do {
            try await ListingRepository.shared.deleteListing(id: id)
            if let index = listings.firstIndex(where: { $0.id == id }) {
                listings.remove(at: index)
            }
        } catch {
            print("[ProfileView] Failed to delete listing: \(error)")
        }
    }
    
    private func performBulkDelete() async {
        do {
            try await ListingRepository.shared.bulkDelete(listingIds: Array(selectedListings))
            editMode = .inactive
            selectedListings.removeAll()
            await loadListings()
        } catch {
            print("[ProfileView] Failed to bulk delete listings: \(error)")
        }
    }
    
    private func bulkPostListings(platforms: Set<String>) {
        let selectedListingsArray = listings.filter { selectedListings.contains($0.id ?? "") }
        
        for listing in selectedListingsArray {
            guard let id = listing.id else { continue }
            
            for platform in platforms {
                if platform == "ebay" {
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
                            print("Bulk cross-post triggered for: \(id)")
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
        
        // Clear selection
        selectedListings.removeAll()
        editMode = .inactive
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

// MARK: - Edit Listing Sheet

struct EditListingSheet: View {
    let listing: UserListing
    let onSave: () -> Void
    
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
    @State private var isSaving = false
    @State private var showAddressSetupSheet = false
    @State private var platformToEnableAfterAddressSetup = ""
    
    @StateObject private var integrationRepo = IntegrationRepository.shared
    @State private var selectedPlatforms: Set<String> = []
    @State private var initialPlatforms: Set<String> = []
    @State private var crossPostErrorMessage: String? = nil
    @State private var showCrossPostError = false
    
    init(listing: UserListing, onSave: @escaping () -> Void) {
        self.listing = listing
        self.onSave = onSave
        _title = State(initialValue: listing.customTitle ?? "")
        _price = State(initialValue: listing.price)
        _description = State(initialValue: listing.customDescription ?? "")
        _condition = State(initialValue: listing.condition)
        _category = State(initialValue: listing.category ?? "")
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
    }
    
    var body: some View {
        NavigationStack {
            Form {
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
                Section("Price") {
                    HStack {
                        Text("$")
                        TextField("0.00", value: $price, format: .number)
                            .keyboardType(.decimalPad)
                    }
                }
                Section("Shipping") {
                    Toggle("Free Shipping (Seller Pays)", isOn: $isFreeShipping)
                    HStack {
                        Text("Weight (lbs)")
                        Spacer()
                        TextField("0.0", value: $weightLbs, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
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
                Section("Marketplaces") {
                    if integrationRepo.integrations.isEmpty {
                        Text("No integrations available. Link them in settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(integrationRepo.integrations) { integration in
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
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(platformDisplayName(integration.platform))
                                    if isAPI {
                                        Text(integration.isConnected ? "Connected" : "Not connected (Link in settings)")
                                            .font(.caption)
                                            .foregroundStyle(integration.isConnected ? .green : .secondary)
                                    } else {
                                        Text("Autofill integration")
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
            .task {
                await integrationRepo.loadIntegrations()
                await SellingSettingsRepository.shared.loadSettings()
            }
            .navigationTitle("Edit Listing")
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
                            Task { await saveListing() }
                        }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
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
    
    private func saveListing() async {
        guard let id = listing.id else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            var dims: PackageDimensions?
            if let l = lengthIn, let w = widthIn, let h = heightIn {
                dims = PackageDimensions(lengthIn: l, widthIn: w, heightIn: h)
            }
            try await ListingRepository.shared.updateFields(
                id: id,
                title: title.trimmingCharacters(in: .whitespaces),
                price: price,
                description: description.trimmingCharacters(in: .whitespaces),
                condition: condition,
                brand: brand.isEmpty ? nil : brand.trimmingCharacters(in: .whitespaces),
                category: category.isEmpty ? nil : category.trimmingCharacters(in: .whitespaces),
                weightLbs: weightLbs,
                packageDimensions: dims,
                buyerPaysShipping: !isFreeShipping
            )
            
            let added = selectedPlatforms.subtracting(initialPlatforms)
            let removed = initialPlatforms.subtracting(selectedPlatforms)
            
            for platform in added {
                if platform == "ebay" {
                    Task {
                        do {
                            let functions = Functions.functions()
                            let _ = try await functions.httpsCallable("ebayCreateListing").call(["listingId": id])
                            print("Successfully triggered ebayCreateListing Cloud Function for listing: \(id)")
                        } catch {
                            print("Failed to call ebayCreateListing: \(error)")
                            let msg = extractCrossPostErrorMessage(error)
                            crossPostErrorMessage = msg
                            showCrossPostError = true
                        }
                    }
                }
            }
            
            for platform in removed {
                if platform == "ebay" {
                    Task {
                        do {
                            let functions = Functions.functions()
                            let _ = try await functions.httpsCallable("ebayDeleteListing").call(["listingId": id])
                            print("Successfully triggered ebayDeleteListing Cloud Function for listing: \(id)")
                        } catch {
                            print("Failed to call ebayDeleteListing: \(error)")
                        }
                    }
                }
            }
            
            onSave()
            dismiss()
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
                                    Button("Disconnect", role: .destructive) {
                                        Task {
                                            try? await integrationRepo.unlinkPlatform(platform: integration.platform)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                } else {
                                    Button("Connect") {
                                        if integration.platform == "ebay" {
                                            startEbayOAuth()
                                        } else {
                                            selectedPlatformToLink = integration.platform
                                            showLinkAlert = true
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
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
            }
            .onDisappear {
                saveSellingSettings(showAlertOnSuccess: false)
            }
        }
    }

    private func startEbayOAuth() {
        print("[SettingsSheet] startEbayOAuth initiated")
        guard let clientId = Bundle.main.object(forInfoDictionaryKey: "EbayClientId") as? String,
              !clientId.isEmpty,
              let ruName = Bundle.main.object(forInfoDictionaryKey: "EbayRuName") as? String,
              !ruName.isEmpty else {
            print("[SettingsSheet] Error: EbayClientId or EbayRuName is not set in Info.plist / Secrets.xcconfig")
            return
        }
        
        print("[SettingsSheet] Loaded EbayClientId: \(clientId), EbayRuName: \(ruName)")
        let isSandbox = ruName.lowercased().contains("sbx") || ruName.lowercased().contains("sandbox")
        let authHost = isSandbox ? "auth.sandbox.ebay.com" : "auth.ebay.com"
        
        var components = URLComponents(string: "https://\(authHost)/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: ruName),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://api.ebay.com/oauth/api_scope https://api.ebay.com/oauth/api_scope/sell.inventory https://api.ebay.com/oauth/api_scope/sell.account https://api.ebay.com/oauth/api_scope/commerce.identity.readonly")
        ]
        
        guard let authURL = components.url else {
            print("[SettingsSheet] Error: Could not construct eBay auth URL")
            return
        }
        
        print("[SettingsSheet] Full eBay auth URL: \(authURL.absoluteString)")
        print("[SettingsSheet] Presenting ASWebAuthenticationSession (ephemeral=false)")
        
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
                print("[SettingsSheet] Authentication session callbackURL received: \(callbackURL.absoluteString)")

                let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
                if let code = callbackComponents?.queryItems?.first(where: { $0.name == "code" })?.value {
                    print("[SettingsSheet] Authentication session extracted authorization code: \(code)")
                    do {
                        try await IntegrationRepository.shared.linkPlatformWithCode(platform: "ebay", code: code)
                        print("[SettingsSheet] Successfully linked platform with code")
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
        
        print("[SettingsSheet] Starting ASWebAuthenticationSession...")
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
                print("[SettingsSheet] Selling settings saved successfully")
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
                    Button("Post") {
                        onConfirm(selectedPlatforms)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .task {
                await integrationRepo.loadIntegrations()
                await SellingSettingsRepository.shared.loadSettings()
                // Default toggle connected API platforms
                selectedPlatforms = Set(integrationRepo.integrations.filter { $0.isConnected }.map { $0.platform })
            }
            .sheet(isPresented: $showAddressSetupSheet) {
                AddressSetupSheet {
                    if !platformToEnableAfterAddressSetup.isEmpty {
                        selectedPlatforms.insert(platformToEnableAfterAddressSetup)
                        platformToEnableAfterAddressSetup = ""
                    }
                }
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


