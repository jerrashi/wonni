//
//  CreateListingView.swift
//  wonni
//

import SwiftUI
import SwiftData
import Photos
import UniformTypeIdentifiers

struct FramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct DraftsStackIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.blue)
                .frame(width: 35, height: 45)
                .rotationEffect(.degrees(-15), anchor: .bottom)
                .shadow(color: .black.opacity(0.2), radius: 2, x: -1, y: 1)
            
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.green)
                .frame(width: 35, height: 45)
                .rotationEffect(.degrees(0), anchor: .bottom)
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
            
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.orange)
                .frame(width: 35, height: 45)
                .rotationEffect(.degrees(15), anchor: .bottom)
                .shadow(color: .black.opacity(0.2), radius: 2, x: 1, y: 1)
        }
        .frame(width: 60, height: 60)
        .background(Color(.systemGray5))
        .cornerRadius(8)
    }
}

struct CustomPhotoPickerView: View {
    @StateObject var photoCollection = PhotoCollection(smartAlbum: .smartAlbumUserLibrary)
    @State private var selectedAssets: [PhotoAsset] = []
    @State private var navigateToOverview = false
    @State private var showingDraftHistory = false
    @State private var hidePreviouslySelected = false
    @State private var sessionDraftIDs: [UUID] = []
    @State private var showingExitAlert = false
    @Environment(\.dismiss) private var dismiss
    
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [Item]
    
    @State private var itemFrames = [String: CGRect]()
    @State private var isDragging = false
    @State private var draggedAsset: PhotoAsset?
    
    @Environment(\.displayScale) private var displayScale
    private static let itemSpacing = 2.0
    private var imageSize: CGSize {
        return CGSize(width: 100 * min(displayScale, 2), height: 100 * min(displayScale, 2))
    }
    
    let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 2)
    ]
    
    private var usedAssetIDs: Set<String> {
        Set(allItems.filter { $0.isDraft }.flatMap { $0.sourceAssetIdentifiers })
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Invisible navigation link to fix navigation stack pushing issues
            NavigationLink(destination: BulkListingOverviewView(selectedAssets: selectedAssets), isActive: $navigateToOverview) {
                EmptyView()
            }
            .hidden()
            
            if !usedAssetIDs.isEmpty && photoCollection.photoAssets.count <= 50000 {
                Toggle(isOn: $hidePreviouslySelected) {
                    HStack {
                        Image(systemName: hidePreviouslySelected ? "eye.slash" : "eye")
                        Text("Hide previously selected")
                    }
                    .font(.subheadline)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
            }
            
            // Photo Grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.itemSpacing) {
                    if hidePreviouslySelected && photoCollection.photoAssets.count <= 50000 {
                        ForEach(photoCollection.photoAssets.filter { !usedAssetIDs.contains($0.id) }) { asset in
                            photoGridItem(asset: asset)
                        }
                    } else {
                        ForEach(photoCollection.photoAssets) { asset in
                            photoGridItem(asset: asset)
                        }
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
            if !selectedAssets.isEmpty || !sessionDraftIDs.isEmpty {
                VStack {
                    Divider()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            if !sessionDraftIDs.isEmpty {
                                Button {
                                    showingDraftHistory = true
                                } label: {
                                    DraftsStackIcon()
                                }
                            }
                            
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
                                    .onDrag {
                                        self.draggedAsset = asset
                                        return NSItemProvider(object: asset.id as NSString)
                                    }
                                    .onDrop(of: [UTType.text], delegate: PhotoAssetDropDelegate(item: asset, items: $selectedAssets, draggedItem: $draggedAsset))
                            }
                            
                            if !selectedAssets.isEmpty {
                                Button {
                                    withAnimation { selectedAssets.removeAll() }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 24))
                                        .foregroundColor(.red)
                                        .frame(width: 60, height: 60)
                                        .background(Color(.systemGray5))
                                        .cornerRadius(8)
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
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    if sessionDraftIDs.isEmpty {
                        dismiss()
                    } else {
                        showingExitAlert = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 20) {
                    Button {
                        saveSelectionToDraft()
                        withAnimation { selectedAssets.removeAll() }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24))
                    }
                    .disabled(selectedAssets.isEmpty)
                    
                    Button {
                        saveSelectionToDraft()
                        navigateToOverview = true
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
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
        .sheet(isPresented: $showingDraftHistory) {
            DraftHistoryModal(photoCollection: photoCollection)
        }
        .alert("Save Drafts?", isPresented: $showingExitAlert) {
            Button("Discard", role: .destructive) {
                for draft in allItems where sessionDraftIDs.contains(draft.id) {
                    modelContext.delete(draft)
                }
                try? modelContext.save()
                dismiss()
            }
            Button("Save") {
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have created drafts in this session. Would you like to save or discard them?")
        }
    }
    
    @ViewBuilder
    private func photoGridItem(asset: PhotoAsset) -> some View {
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
        let newItem = Item(
            blurb: "Draft from \(selectedAssets.count) selected photos",
            sourceAssetIdentifiers: selectedAssets.map { $0.id }
        )
        modelContext.insert(newItem)
        try? modelContext.save()
        sessionDraftIDs.append(newItem.id)
    }
}

// MARK: - DropDelegate
struct PhotoAssetDropDelegate: DropDelegate {
    let item: PhotoAsset
    @Binding var items: [PhotoAsset]
    @Binding var draggedItem: PhotoAsset?

    func dropEntered(info: DropInfo) {
        guard let draggedItem = self.draggedItem else { return }
        if draggedItem != item {
            let from = items.firstIndex(of: draggedItem)!
            let to = items.firstIndex(of: item)!
            withAnimation {
                items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            }
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
    
    func performDrop(info: DropInfo) -> Bool {
        self.draggedItem = nil
        return true
    }
}

// MARK: - DraftHistoryModal
struct DraftHistoryModal: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var allItems: [Item]
    @ObservedObject var photoCollection: PhotoCollection
    @Environment(\.modelContext) private var modelContext
    
    var drafts: [Item] {
        allItems.filter { $0.isDraft && !$0.sourceAssetIdentifiers.isEmpty }
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if drafts.isEmpty {
                    VStack {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                            .padding()
                        Text("No active drafts found.")
                            .foregroundColor(.gray)
                    }
                } else {
                    List {
                        ForEach(drafts) { draft in
                            Section(header: Text(draft.userEditedTitle ?? draft.aiSuggestedTitle ?? "Draft (\(draft.sourceAssetIdentifiers.count) photos)")) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        if draft.sourceAssetIdentifiers.isEmpty {
                                            Text("No photos")
                                                .foregroundColor(.gray)
                                                .italic()
                                        } else {
                                            ForEach(draft.sourceAssetIdentifiers, id: \.self) { assetId in
                                                let asset = PhotoAsset(identifier: assetId)
                                                PhotoItemView(asset: asset, cache: photoCollection.cache, imageSize: CGSize(width: 80, height: 80))
                                                    .frame(width: 80, height: 80)
                                                    .cornerRadius(8)
                                                    .overlay(alignment: .topTrailing) {
                                                        Button {
                                                            var ids = draft.sourceAssetIdentifiers
                                                            ids.removeAll(where: { $0 == assetId })
                                                            draft.sourceAssetIdentifiers = ids
                                                            try? modelContext.save()
                                                        } label: {
                                                            Image(systemName: "xmark.circle.fill")
                                                                .foregroundColor(.red)
                                                                .background(Circle().fill(Color.white))
                                                        }
                                                        .offset(x: 5, y: -5)
                                                    }
                                                    .onDrag {
                                                        NSItemProvider(object: "\(draft.id.uuidString)|\(assetId)" as NSString)
                                                    }
                                            }
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        modelContext.delete(draft)
                                        try? modelContext.save()
                                    } label: {
                                        Label("Delete Draft", systemImage: "trash")
                                    }
                                }
                                .onDrop(of: [.text], isTargeted: nil) { providers in
                                    providers.first?.loadObject(ofClass: NSString.self) { string, error in
                                        if let str = string as? String {
                                            let parts = str.components(separatedBy: "|")
                                            if parts.count == 2 {
                                                let sourceDraftId = parts[0]
                                                let assetId = parts[1]
                                                if sourceDraftId != draft.id.uuidString {
                                                    DispatchQueue.main.async {
                                                        if let sourceDraft = drafts.first(where: { $0.id.uuidString == sourceDraftId }) {
                                                            var sourceIds = sourceDraft.sourceAssetIdentifiers
                                                            sourceIds.removeAll(where: { $0 == assetId })
                                                            sourceDraft.sourceAssetIdentifiers = sourceIds
                                                            
                                                            var destIds = draft.sourceAssetIdentifiers
                                                            if !destIds.contains(assetId) {
                                                                destIds.append(assetId)
                                                            }
                                                            draft.sourceAssetIdentifiers = destIds
                                                            try? modelContext.save()
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    return true
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                modelContext.delete(drafts[index])
                            }
                            try? modelContext.save()
                        }
                    }
                }
            }
            .navigationTitle("Drafts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
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
                        .overlay(Text("\(item.sourceAssetIdentifiers.count) img").font(.caption2))
                    
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
                let newItem = Item(blurb: "Draft from selected photos", sourceAssetIdentifiers: selectedAssets.map { $0.id })
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
