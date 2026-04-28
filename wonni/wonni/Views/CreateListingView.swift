//
//  CreateListingView.swift
//  wonni
//

import SwiftUI
import SwiftData
import Photos

struct CustomPhotoPickerView: View {
    @StateObject var photoCollection = PhotoCollection(smartAlbum: .smartAlbumUserLibrary)
    @State private var selectedAssets: [PhotoAsset] = []
    @State private var navigateToOverview = false
    
    @Environment(\.displayScale) private var displayScale
    private static let itemSpacing = 2.0
    private var imageSize: CGSize {
        return CGSize(width: 100 * min(displayScale, 2), height: 100 * min(displayScale, 2))
    }
    
    let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 2)
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Photo Grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.itemSpacing) {
                    ForEach(photoCollection.photoAssets) { asset in
                        ZStack(alignment: .topTrailing) {
                            PhotoItemView(asset: asset, cache: photoCollection.cache, imageSize: imageSize)
                                .aspectRatio(1, contentMode: .fill)
                                .clipped()
                                .onTapGesture {
                                    toggleSelection(asset)
                                }
                                .onAppear {
                                    Task { await photoCollection.cache.startCaching(for: [asset], targetSize: imageSize) }
                                }
                            
                            if let index = selectedAssets.firstIndex(of: asset) {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 24, height: 24)
                                    .overlay(Text("\(index + 1)").foregroundColor(.white).font(.caption))
                                    .padding(4)
                            } else {
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: 2)
                                    .frame(width: 24, height: 24)
                                    .padding(4)
                            }
                        }
                    }
                }
            }
            
            // Bottom Carousel
            if !selectedAssets.isEmpty {
                VStack {
                    Divider()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(selectedAssets) { asset in
                                PhotoItemView(asset: asset, cache: photoCollection.cache, imageSize: imageSize)
                                    .frame(width: 60, height: 60)
                                    .cornerRadius(8)
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            toggleSelection(asset)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.red)
                                                .background(Circle().fill(Color.white))
                                        }
                                        .offset(x: 5, y: -5)
                                    }
                            }
                        }
                        .padding()
                    }
                    .frame(height: 100)
                    .background(Color(.systemBackground))
                }
                .transition(.move(edge: .bottom))
            }
        }
        .navigationTitle("Select Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Next") {
                    navigateToOverview = true
                }
                .disabled(selectedAssets.isEmpty)
            }
        }
        .task {
            do {
                try await photoCollection.load()
            } catch {
                print("Failed to load photos: \(error)")
            }
        }
        .navigationDestination(isPresented: $navigateToOverview) {
            BulkListingOverviewView(selectedAssets: selectedAssets)
        }
    }
    
    private func toggleSelection(_ asset: PhotoAsset) {
        withAnimation {
            if let index = selectedAssets.firstIndex(of: asset) {
                selectedAssets.remove(at: index)
            } else {
                selectedAssets.append(asset)
            }
        }
    }
}

// MARK: - BulkListingOverviewView
struct BulkListingOverviewView: View {
    var selectedAssets: [PhotoAsset]
    @State private var selection = Set<UUID>()
    @State private var showingBulkEdit = false
    
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [Item]
    
    var body: some View {
        List(selection: $selection) {
            ForEach(allItems.filter { $0.isDraft }) { item in
                HStack {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 50, height: 50)
                        .cornerRadius(8)
                        .overlay(Text("\(item.photosData.count) img").font(.caption2))
                    
                    VStack(alignment: .leading) {
                        Text(item.userEditedTitle ?? item.aiSuggestedTitle ?? "New Draft Item")
                            .font(.headline)
                        Text(item.blurb.isEmpty ? "No blurb" : item.blurb)
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                }
            }
        }
        .navigationTitle("Bulk Overview")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Button("Delete") {
                        deleteSelected()
                    }
                    .disabled(selection.isEmpty)
                    .foregroundColor(.red)
                    
                    Spacer()
                    
                    Button("Bulk Edit") {
                        showingBulkEdit = true
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showingBulkEdit) {
            BulkEditModal(selection: $selection)
        }
        .onAppear {
            // If we navigated here with selected photos, create a draft item for them
            // In a full implementation, we'd asynchronously convert PhotoAsset to Data.
            // For now, we just create a placeholder draft to show it works.
            if allItems.filter({ $0.isDraft }).isEmpty && !selectedAssets.isEmpty {
                let newItem = Item(blurb: "Draft from selected photos")
                modelContext.insert(newItem)
                try? modelContext.save()
            }
        }
    }
    
    private func deleteSelected() {
        for item in allItems where selection.contains(item.id) {
            modelContext.delete(item)
        }
        selection.removeAll()
    }
}

// MARK: - BulkEditModal
struct BulkEditModal: View {
    @Binding var selection: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [Item]
    
    @State private var appendBlurb = ""
    @State private var buyerPaysShipping = true
    @State private var handlingFee: Double = 0.0
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Description")) {
                    TextField("Append to description...", text: $appendBlurb, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section(header: Text("Shipping Rules")) {
                    Toggle("Buyer Pays Shipping", isOn: $buyerPaysShipping)
                    HStack {
                        Text("Handling Fee")
                        Spacer()
                        TextField("$0.00", value: $handlingFee, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                
                Section {
                    Button("Apply Changes") {
                        applyChanges()
                        dismiss()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Bulk Edit (\(selection.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
    
    private func applyChanges() {
        for item in allItems where selection.contains(item.id) {
            if !appendBlurb.isEmpty {
                if item.blurb.isEmpty {
                    item.blurb = appendBlurb
                } else {
                    item.blurb += "\n" + appendBlurb
                }
            }
            item.buyerPaysShipping = buyerPaysShipping
            item.handlingFee = handlingFee
        }
        try? modelContext.save()
        selection.removeAll()
    }
}
