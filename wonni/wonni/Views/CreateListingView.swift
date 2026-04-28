//
//  CreateListingView.swift
//  wonni
//

import SwiftUI
import SwiftData
import Photos

struct FramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct CustomPhotoPickerView: View {
    @StateObject var photoCollection = PhotoCollection(smartAlbum: .smartAlbumUserLibrary)
    @State private var selectedAssets: [PhotoAsset] = []
    @State private var navigateToOverview = false
    @Environment(\.modelContext) private var modelContext
    
    @State private var itemFrames = [String: CGRect]()
    @State private var isDragging = false
    
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
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(
                                    PhotoItemView(asset: asset, cache: photoCollection.cache, imageSize: imageSize)
                                        .scaledToFill()
                                )
                                .clipped()
                                .opacity(selectedAssets.contains(asset) ? 0.5 : 1.0)
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
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .preference(key: FramePreferenceKey.self, value: [asset.id: geo.frame(in: .named("GridSpace"))])
                            }
                        )
                    }
                }
                .coordinateSpace(name: "GridSpace")
                .onPreferenceChange(FramePreferenceKey.self) { frames in
                    self.itemFrames = frames
                }
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            isDragging = true
                            for (id, frame) in itemFrames {
                                if frame.contains(value.location) {
                                    if let asset = photoCollection.photoAssets.first(where: { $0.id == id }) {
                                        if !selectedAssets.contains(asset) {
                                            withAnimation {
                                                selectedAssets.append(asset)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
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
                        // Use scrollReader to scroll to end if needed, skipping for now
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
                Button("Clear") {
                    withAnimation { selectedAssets.removeAll() }
                }
                .disabled(selectedAssets.isEmpty)
            }
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Button {
                        saveSelectionToDraft()
                        withAnimation { selectedAssets.removeAll() }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 32))
                    }
                    .disabled(selectedAssets.isEmpty)
                    
                    Spacer()
                    
                    Button {
                        saveSelectionToDraft()
                        navigateToOverview = true
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.green)
                    }
                    .disabled(selectedAssets.isEmpty)
                }
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
    
    private func saveSelectionToDraft() {
        guard !selectedAssets.isEmpty else { return }
        // In a real app, convert PhotoAsset to Data. Here we mock it by adding an item with a blurb indicating count.
        let newItem = Item(blurb: "Draft from \(selectedAssets.count) selected photos")
        modelContext.insert(newItem)
        try? modelContext.save()
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
