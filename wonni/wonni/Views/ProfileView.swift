//
//  ProfileView.swift
//  wonni
//

import SwiftUI
import FirebaseStorage
import FirebaseAuth
import _PhotosUI_SwiftUI // required for PhotosPicker

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
    @State private var showSignOutAlert = false
    @State private var showEditProfile = false
    @State private var listingToEdit: UserListing?
    
    @State private var selectedListings = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var showBulkEdit = false
    @State private var isBulkDeleting = false
    @State private var searchText = ""
    @State private var selectedSort: ListingSortOption = .newest

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
                        Button { showSignOutAlert = true } label: {
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
            .alert("Sign Out", isPresented: $showSignOutAlert) {
                Button("Sign Out", role: .destructive) { try? authManager.signOut() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete \(selectedListings.count) Listings?", isPresented: $isBulkDeleting) {
                Button("Delete", role: .destructive) {
                    Task { await performBulkDelete() }
                }
                Button("Cancel", role: .cancel) {}
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
            onSave()
            dismiss()
        } catch {
            print("Failed to save listing: \(error)")
        }
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

