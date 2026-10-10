//
//  CreateListingView.swift
//  wonni
//

import SwiftUI
import PhotosUI
import SwiftData
import Photos
import UniformTypeIdentifiers
import Vision
import UIKit
import FirebaseFirestore
import FirebaseAuth



struct DraftsStackIcon: View {
    var drafts: [Item]
    var cache: CachedImageManager
    var bouncing: Bool = false

    private static let cardW: CGFloat = 30
    private static let cardH: CGFloat = 38
    private static let rotations: [Double] = [-14, 0, 14]

    var body: some View {
        // Always show 3 slots. Most recent draft = top (index 2 in ZStack = rendered on top).
        let allAssets: [PhotoAsset] = drafts.compactMap {
            $0.sourceAssetIdentifiers.first.map(PhotoAsset.init(identifier:))
        }
        // suffix(3) keeps the 3 newest; pad the front with nils for empty ghost cards.
        let recent = Array(allAssets.suffix(3))
        let slots: [PhotoAsset?] = Array(repeating: nil, count: 3 - recent.count) + recent.map { .some($0) }

        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let rotation = Self.rotations[index]
                Group {
                    if let asset = slots[index] {
                        PhotoItemView(asset: asset, cache: cache,
                                      imageSize: CGSize(width: Self.cardW * 2, height: Self.cardH * 2))
                            .scaledToFill()
                            .frame(width: Self.cardW, height: Self.cardH)
                            .cornerRadius(4)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.systemGray2))
                            .frame(width: Self.cardW, height: Self.cardH)
                    }
                }
                .rotationEffect(.degrees(rotation), anchor: .bottom)
                .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
            }
        }
        .frame(width: 70, height: 62)
        .scaleEffect(bouncing ? 1.25 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.45), value: bouncing)
    }
}

struct SelectablePhotoGridItem: View, Equatable {
    let asset: PhotoAsset
    /// Position in the active draft (drives the numbered badge); nil = not selected.
    let selectionIndex: Int?
    /// Already saved into a committed draft.
    let isDrafted: Bool
    let cache: CachedImageManager
    let imageSize: CGSize
    let toggleAction: () -> Void

    var isSelected: Bool { selectionIndex != nil }

    // The picker's body re-runs on every UploadManager change (upload progress ticks
    // several times a second while the user is still picking) and on every tap. Each
    // pass hands every cell a fresh `toggleAction` closure, which SwiftUI always treats
    // as changed — so without this, every visible cell re-rendered every time. Compares
    // only what the cell draws; `toggleAction` is safe to leave stale because it only
    // captures the asset (UploadManager.togglePhotoInActiveDraft decides add vs remove).
    static func == (lhs: SelectablePhotoGridItem, rhs: SelectablePhotoGridItem) -> Bool {
        lhs.asset.id == rhs.asset.id &&
        lhs.selectionIndex == rhs.selectionIndex &&
        lhs.isDrafted == rhs.isDrafted &&
        lhs.imageSize == rhs.imageSize
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    PhotoItemView(asset: asset, cache: cache, imageSize: imageSize)
                        .scaledToFill()
                )
                .clipped()
                .opacity((isSelected || isDrafted) ? 0.5 : 1.0)
                .onTapGesture {
                    toggleAction()
                }
                .onAppear {
                    Task { await cache.startCaching(for: [asset], targetSize: imageSize) }
                }
                .accessibilityIdentifier("photoGridItem")

            if let index = selectionIndex {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 24, height: 24)
                    .overlay(Text("\(index + 1)").foregroundColor(.white).font(.caption))
                    .padding(4)
            } else if isDrafted {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 24, height: 24)
                    .overlay(Image(systemName: "checkmark").foregroundColor(.white).font(.caption))
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

struct CustomPhotoPickerView: View {
        /// The draft this picker edits — the camera's current draft for a new listing,
        /// or a committed draft reopened from the drawer's "+". Becomes the active draft
        /// whenever this screen is on top (see `onAppear`), so the carousel, the grid
        /// badges and the camera all agree on which draft a tap goes to.
        let draftID: UUID
        /// The Sell tab's one PhotoCollection (CameraView's DataModel owns it).
        @ObservedObject var photoCollection: PhotoCollection
        /// Green checkmark: the host commits the draft and pushes the overview.
        let onProceed: () -> Void
        /// Stack icon in the carousel: the host pushes the drafts drawer.
        let onOpenDrafts: () -> Void

        @State private var hidePreviouslySelected = false
        @State private var photoAccessLimited = false
        /// Divider + 88pt carousel row + 4pt padding. Fixed so the bar can never grow.
        private static let carouselBarHeight: CGFloat = 93
        @Environment(\.dismiss) private var dismiss

        @Environment(\.modelContext) private var modelContext
        @Query(filter: #Predicate<Item> { $0.isDraft == true })
        private var allItems: [Item]

        @EnvironmentObject private var uploadManager: UploadManager

        @Environment(\.displayScale) private var displayScale
        private static let itemSpacing = 2.0
        private var imageSize: CGSize {
            return CGSize(width: 100 * min(displayScale, 2), height: 100 * min(displayScale, 2))
        }

        let columns = [
            GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 2)
        ]

        /// The draft this screen edits.
        private var activeDraft: Item? {
            allItems.first { $0.id == draftID }
        }

        /// Every other draft with photos. Their asset IDs are the "used" set behind the
        /// grey checkmark badge and the "Hide previously selected" toggle — which
        /// deliberately excludes this draft's own selections, since those stay visible
        /// with their number badge.
        private var committedDrafts: [Item] {
            allItems.filter { $0.isDraft && !$0.sourceAssetIdentifiers.isEmpty && $0.id != draftID }
        }

        /// One grid cell. Takes the already-computed selection lookups — see the hoisting
        /// note at the top of `body`.
        private func gridItem(_ asset: PhotoAsset, selectionIndexByAsset: [String: Int], usedAssetIDs: Set<String>) -> some View {
            let selectionIndex = selectionIndexByAsset[asset.id]
            return SelectablePhotoGridItem(
                asset: asset,
                selectionIndex: selectionIndex,
                isDrafted: selectionIndex == nil && usedAssetIDs.contains(asset.id),
                cache: photoCollection.cache,
                imageSize: imageSize,
                toggleAction: { togglePhoto(asset) }
            )
            .equatable()
        }

        var body: some View {
            // Everything the grid cells need is derived ONCE per body pass here. These
            // used to be read through the computed properties above from inside the
            // ForEach, so every visible cell re-scanned all drafts and rebuilt a Set.
            let activeOrder = activeDraft?.sourceAssetIdentifiers ?? []
            let selectionIndexByAsset = Dictionary(
                activeOrder.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
            let committed = committedDrafts
            let currentUsedAssetIDs = Set(committed.flatMap { $0.sourceAssetIdentifiers })

            // hasContent gates the bottom carousel below — computed here (not inside the
            // old .safeAreaInset(edge: .bottom) closure) now that it's a plain VStack
            // sibling of the ScrollView instead of a safe-area reservation on it. See the
            // 2026-09-29 note on the carousel below for why that mattered.
            let hasContent = (!activeOrder.isEmpty || !committed.isEmpty)
                && !photoCollection.photoAssets.isEmpty

            VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.itemSpacing) {
                    if hidePreviouslySelected {
                        ForEach(photoCollection.photoAssets.filter { !currentUsedAssetIDs.contains($0.id) }) { asset in
                            gridItem(asset, selectionIndexByAsset: selectionIndexByAsset, usedAssetIDs: currentUsedAssetIDs)
                        }
                    } else {
                        ForEach(photoCollection.photoAssets) { asset in
                            gridItem(asset, selectionIndexByAsset: selectionIndexByAsset, usedAssetIDs: currentUsedAssetIDs)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    if photoAccessLimited {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                            Text("You've allowed access to only some photos.")
                                .font(.caption)
                            Spacer()
                            Button("Select More") { presentLimitedLibraryPicker() }
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                    }
                }
            }

            // 2026-09-29: was `.safeAreaInset(edge: .bottom)` on the ScrollView above —
            // that relies on the ScrollView correctly re-reserving space for the inset's
            // content, which it doesn't reliably do on the very first layout pass (see the
            // old comment this replaced). Reported symptom: the carousel rendering
            // mid-screen / overlapping the grid instead of pinned to the bottom, a real
            // constraint bug, not an animation timing one. A plain VStack sibling below the
            // ScrollView has no such reservation to get wrong — it's just laid out in flow.
            // 2026-10-10: the row is pinned to one fixed height (user saw it take half
            // the screen on an SE); the VStack sibling only hugs when every child does.
            if hasContent {
                VStack(spacing: 0) {
                    Divider()
                    ActiveDraftCarouselView(
                        cache: photoCollection.cache,
                        onOpenDraftHistory: onOpenDrafts
                    )
                    .padding(.bottom, 4)
                }
                .frame(height: Self.carouselBarHeight)
                .clipped()
                .background(Color(.systemBackground))
                .transition(.move(edge: .bottom))
            }
            }
            .overlay(alignment: .bottom) {
                PhotoRemovedToast().padding(.bottom, 8)
            }
            .animation(.easeOut(duration: 0.2), value: uploadManager.removedPhoto)
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // Pops this screen. Where that lands (camera or drafts drawer) is
                    // whatever is under it on the path, so the label is just "Back".
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                    }
                    .accessibilityIdentifier("pickerBackButton")
                }
                // "Hide previously selected" lives up here (2026-10-10); the row it used
                // to take above the grid is gone. The "paste a list" button left this
                // screen — the camera and the Drafts screen both have it.
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !photoCollection.photoAssets.isEmpty {
                        Button {
                            hidePreviouslySelected.toggle()
                        } label: {
                            Image(systemName: hidePreviouslySelected ? "eye.slash" : "eye")
                        }
                        .disabled(currentUsedAssetIDs.isEmpty)
                        .accessibilityLabel(hidePreviouslySelected ? "Show previously selected" : "Hide previously selected")
                        .accessibilityIdentifier("pickerHideUsedToggle")
                    }
                }
                // Primary action at the bottom (iOS 26 convention, agreed 2026-10-10).
                ToolbarItem(placement: .bottomBar) {
                    let hasActiveDraft = !(activeDraft?.sourceAssetIdentifiers.isEmpty ?? true)
                    let canProceed = hasActiveDraft || !committedDrafts.isEmpty
                    HStack {
                        Spacer()
                        Button {
                            if hasActiveDraft {
                                uploadManager.commitActiveDraft(modelContext: modelContext)
                            }
                            onProceed()
                        } label: {
                            HStack(spacing: 6) {
                                Text("Proceed").fontWeight(.semibold)
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(canProceed ? .green : .secondary)
                            }
                        }
                        .disabled(!canProceed)
                        .accessibilityIdentifier("pickerProceedButton")
                    }
                }
            }
            // Whenever this screen is on top — first push, or a pop back onto it from
            // the drafts drawer — its draft is the one the carousel and grid edit.
            .onAppear { uploadManager.activeDraftID = draftID }
            .task {
                guard await PhotoLibrary.checkAuthorization() else {
                    print("Photo library access not authorized for picker")
                    return
                }
                photoAccessLimited = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
                // The camera already loaded this collection; a reload here picks up
                // anything added since (and the first load if the camera's was denied).
                do {
                    try await photoCollection.load()
                } catch {
                    print("Failed to load photos: \(error)")
                }
            }
        }
        
        /// Present the system sheet that lets a limited-access user add more photos
        /// to the app's allowed selection. PhotoCollection observes library changes,
        /// so the grid refreshes automatically once the selection expands.
        private func presentLimitedLibraryPicker() {
            guard let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                  let root = scene.keyWindow?.rootViewController else { return }
            var top = root
            while let presented = top.presentedViewController { top = presented }
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
        }

        /// Toggle a photo in/out of the active draft.
        private func togglePhoto(_ asset: PhotoAsset) {
            withAnimation {
                uploadManager.togglePhotoInActiveDraft(assetId: asset.id, modelContext: modelContext)
            }
        }
    }

    struct DraftSelectionToolbar: Equatable {
        enum Leading: Equatable { case selectAll, deselectAll }

        let leading: Leading
        /// Bulk Edit acts on whole drafts and needs at least two of them.
        let canBulkEdit: Bool
        /// Delete also removes individual photos, so any selection enables it.
        let canDelete: Bool

        /// - Parameters:
        ///   - totalDrafts: drafts on screen.
        ///   - fullySelectedDrafts: drafts with EVERY photo selected. Selection here is
        ///     per photo, so a draft with only some photos ticked doesn't count.
        ///   - hasAnySelection: at least one photo selected anywhere.
        init(totalDrafts: Int, fullySelectedDrafts: Int, hasAnySelection: Bool) {
            let allSelected = totalDrafts > 0 && fullySelectedDrafts == totalDrafts
            leading = allSelected ? .deselectAll : .selectAll
            canBulkEdit = fullySelectedDrafts >= 2
            canDelete = hasAnySelection
        }
    }

struct TitleCharCountView: View {
    let count: Int
    /// The "Facebook & Etsy only" / "Only shows fully on Etsy" hint is a per-platform
    /// truncation *suggestion* — only meaningful once the user is choosing which
    /// platforms to cross-post to, on the Review & Publish screen (`ResultDraftRow`).
    /// Shown there; suppressed on the earlier draft-edit rows/sheets (2026-09-30 report:
    /// it was confusingly showing up before the user had even gotten to platform
    /// selection). The character counter itself still shows everywhere.
    var showPlatformMessage: Bool = true

    private var color: Color {
        if count > 140 { return Color(red: 0.75, green: 0.0, blue: 0.0) }
        if count > 99  { return .red }
        if count > 80  { return .orange }
        return .secondary
    }

    private var message: String? {
        guard showPlatformMessage else { return nil }
        if count > 140 { return "Truncated on all platforms" }
        if count > 99  { return "Only shows fully on Etsy" }
        if count > 80  { return "Facebook & Etsy only" }
        return nil
    }

    var body: some View {
        // Only surface the counter once the title is long enough to matter (>= 70 chars).
        // Below that it renders nothing and takes no vertical space.
        if count >= 70 {
            HStack(spacing: 4) {
                if let msg = message {
                    Text(msg).font(.caption2)
                }
                Spacer()
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(count > 80 ? .semibold : .regular))
            }
            .foregroundStyle(color)
            .animation(.easeInOut(duration: 0.2), value: count)
        }
    }
}

// MARK: - VisionTitleSuggestionChip
/// On-device Vision's title guess, offered as an explicit suggestion instead of
/// prefilled editable text. Prefilling polluted the "user title" hint sent to Gemini
/// (any edit dragged the vision text along as if the user wrote it) and even leaked
/// into `userEditedTitle` on scroll-away. Tapping the chip is a deliberate acceptance:
/// it fills the field and marks `visionTitleAccepted` for model-quality tracking.
/// Shown only pre-AI (`processedAt == nil`) while the title field is empty; an
/// unaccepted suggestion is simply dropped at process time.
struct VisionTitleSuggestionChip: View {
    let suggestion: String
    let onAccept: () -> Void

    var body: some View {
        Button(action: onAccept) {
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                    .font(.caption2)
                Text("Use: \u{201C}\(suggestion)\u{201D}")
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.1))
            .foregroundStyle(.blue)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct DraftEditSheet: View {
    let item: Item
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var settingsRepo = SellingSettingsRepository.shared

    @State private var cache = CachedImageManager()
    @State private var title: String = ""
    @State private var priceText: String = ""
    @State private var description: String = ""
    @State private var personalNote: String = ""
    @State private var buyerPaysShipping: Bool = true
    @State private var handlingFee: String = ""
    @State private var estimatedDays: String = ""
    @State private var selectedCondition: ItemCondition = .good
    @State private var tagsText: String = ""
    // Facebook overrides: nil = account default (see Item.facebookOfferShipping).
    @State private var facebookOfferShipping: Bool?
    @State private var facebookHideFromFriends: Bool?

    @State private var showPhotoEditModal = false
    @State private var selectedItems: [PhotosPickerItem] = []

    // Shipping & Dimensions state
    @State private var weightText: String = ""
    @State private var lengthText: String = ""
    @State private var widthText: String = ""
    @State private var heightText: String = ""
    /// nil = inherit the account's default handling time at publish time.
    @State private var handlingTimeDaysOverride: Int? = nil

    @State private var showTemplatePicker = false
    @State private var isApplyingTemplate = false
    @State private var showVariantsEditor = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Photos")
                                .font(.headline)
                            Spacer()
                            if !item.sourceAssetIdentifiers.isEmpty {
                                Button {
                                    showPhotoEditModal = true
                                } label: {
                                    Image(systemName: "pencil")
                                }
                            }
                        }
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(item.sourceAssetIdentifiers, id: \.self) { assetId in
                                    ZStack(alignment: .topTrailing) {
                                        DraftThumbnailView(item: item, assetId: assetId)
                                        .frame(width: 80, height: 80)
                                        .cornerRadius(8)
                                        .clipped()
                                    }
                                }
                                
                                PhotosPicker(selection: $selectedItems, matching: .images) {
                                        VStack {
                                            Image(systemName: "plus.circle")
                                                .font(.title2)
                                            Text("Add Photo")
                                                .font(.caption2)
                                        }
                                        .foregroundColor(.accentColor)
                                        .frame(width: 80, height: 80)
                                        .background(Color(.systemGray6))
                                        .cornerRadius(8)
                                    }
                                    .onChange(of: selectedItems) { _, newItems in
                                        Task {
                                            for phItem in newItems {
                                                if let data = try? await phItem.loadTransferable(type: Data.self) {
                                                    let assetId = UUID().uuidString
                                                    item.insertPhoto(assetId: assetId, data: data, at: item.sourceAssetIdentifiers.count)
                                                }
                                            }
                                            selectedItems = []
                                            try? modelContext.save()
                                        }
                                    }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Title & Price") {
                    TextField("Title", text: $title)
                        .font(.body.weight(.medium))
                        .onChange(of: title) { _, v in
                            if v.count > 140 { title = String(v.prefix(140)) }
                        }
                    TitleCharCountView(count: title.count, showPlatformMessage: false)
                    HStack {
                        Text("$")
                        TextField("0.00", text: $priceText)
                            .keyboardType(.decimalPad)
                    }
                }

                Section("Description") {
                    TextEditor(text: $description)
                        .frame(minHeight: 80)
                }

                // Variant editing (Style/Size dimensions, per-variant price/SKU/
                // quantity) writes through ProductRepository against the shared
                // `products/{id}` doc — it needs a real backend id, which a draft
                // only has once `firestoreListingId` is set (see UploadManager's
                // `syncProductDataAwaiting`/`adoptProduct`). A brand-new, not-yet-
                // synced draft has nowhere to persist variants yet, so the entry
                // point is hidden rather than opening onto an id that doesn't
                // exist server-side.
                if let productId = item.firestoreListingId {
                    Section {
                        Button {
                            showVariantsEditor = true
                        } label: {
                            Label("Manage Variations", systemImage: "square.stack.3d.up")
                        }
                    }
                    .sheet(isPresented: $showVariantsEditor) {
                        VariantsEditorView(productId: productId, listingPrice: item.userEditedPrice ?? item.aiSuggestedPrice)
                    }
                }

                Section("Condition") {
                    Picker("Condition", selection: $selectedCondition) {
                        ForEach(ItemCondition.allCases, id: \.self) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                }

                Section("Tags") {
                    TextField("e.g. photocard, kpop, sealed", text: $tagsText)
                }

                Section("Note (hidden from buyer)") {
                    TextField("e.g. stored in basement", text: $personalNote)
                }

                Section {
                    Picker("Offer shipping", selection: $facebookOfferShipping) {
                        Text("Default").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    Picker("Hide from friends", selection: $facebookHideFromFriends) {
                        Text("Default").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                } header: {
                    Text("Facebook Marketplace")
                } footer: {
                    Text("\"Default\" uses your account setting (Settings → Facebook Marketplace).")
                }

                Section("Shipping & Dimensions") {
                    Toggle("Buyer pays shipping", isOn: $buyerPaysShipping)
                    if !buyerPaysShipping {
                        HStack {
                            Text("Handling fee")
                            Spacer()
                            Text("$")
                            TextField("0.00", text: $handlingFee)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }
                    }
                    HStack {
                        Text("Est. shipping days")
                        Spacer()
                        TextField("3", text: $estimatedDays)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Handling Time", selection: $handlingTimeDaysOverride) {
                            Text("Default (\(HandlingTimeOptions.label(for: settingsRepo.settings?.handlingTimeDays ?? 1)))").tag(Int?.none)
                            ForEach(HandlingTimeOptions.days, id: \.self) { days in
                                Text(HandlingTimeOptions.label(for: days)).tag(Int?.some(days))
                            }
                        }
                        .pickerStyle(.menu)
                        if handlingTimeDaysOverride == nil {
                            Text("Uses your default shipping time — change it in Settings.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Weight (lbs)")
                        Spacer()
                        TextField("lbs", text: $weightText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dimensions (inches)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        HStack(spacing: 12) {
                            HStack {
                                Text("L:")
                                TextField("Length", text: $lengthText)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.center)
                            }
                            HStack {
                                Text("W:")
                                TextField("Width", text: $widthText)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.center)
                            }
                            HStack {
                                Text("H:")
                                TextField("Height", text: $heightText)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Edit Draft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveToDraft()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showTemplatePicker) {
                TemplatePickerSheet { template in
                    applyTemplateToDraft(template)
                }
            }
            .fullScreenCover(isPresented: $showPhotoEditModal) {
                DraftPhotoEditModal(item: item)
            }
            .onAppear { loadFromDraft() }
            .task {
                // Pull first (in case this draft was edited on web since last opened
                // here), then reload the form fields so they reflect whatever's newest.
                await UploadManager.shared.pullProductIfNewer(item, modelContext: modelContext)
                loadFromDraft()
                await SellingSettingsRepository.shared.loadSettings()
            }
        }
    }


    private func applyTemplateToDraft(_ template: ListingTemplate) {
        if let t = template.title, !t.isEmpty { title = t }
        if let d = template.customDescription, !d.isEmpty { description = d }
        if let c = template.condition, let cond = ItemCondition(rawValue: c) { selectedCondition = cond }
        if let free = template.isFreeShipping { buyerPaysShipping = !free }
        if let w = template.weightLbs { weightText = String(format: "%.2f", w) }
        if let dims = template.packageDimensions {
            lengthText = String(format: "%.2f", dims.lengthIn)
            widthText = String(format: "%.2f", dims.widthIn)
            heightText = String(format: "%.2f", dims.heightIn)
        }
        guard !template.photoPaths.isEmpty else { return }
        isApplyingTemplate = true
        Task {
            for path in template.photoPaths {
                if let data = try? await StorageService.shared.downloadImageData(path: path),
                   let img = UIImage(data: data) {
                    let fakeId = "tpl_\(UUID().uuidString)"
                    item.insertPhoto(assetId: fakeId, data: img.jpegData(compressionQuality: 0.85), at: item.sourceAssetIdentifiers.count)
                    try? modelContext.save()
                }
            }
            isApplyingTemplate = false
        }
    }

    private func loadFromDraft() {
        title = item.userEditedTitle ?? item.aiSuggestedTitle ?? ""
        if let p = item.userEditedPrice {
            priceText = String(format: "%.2f", p)
        }
        description = item.userEditedDescription ?? item.aiSuggestedDescription ?? ""
        personalNote = item.personalNote ?? ""
        if let c = item.condition, let parsed = ItemCondition(rawValue: c) {
            selectedCondition = parsed
        } else {
            selectedCondition = .good
        }
        buyerPaysShipping = item.buyerPaysShipping
        handlingFee = item.handlingFee > 0 ? String(format: "%.2f", item.handlingFee) : ""
        estimatedDays = "\(item.estimatedShippingDays)"
        handlingTimeDaysOverride = item.handlingTimeDays
        tagsText = item.tags.joined(separator: ", ")
        facebookOfferShipping = item.facebookOfferShipping
        facebookHideFromFriends = item.facebookHideFromFriends
        
        // Dimensions & Weight
        if let w = item.weightLbs { weightText = String(format: "%.2f", w) } else { weightText = "" }
        if let l = item.lengthIn { lengthText = String(format: "%.2f", l) } else { lengthText = "" }
        if let w = item.widthIn { widthText = String(format: "%.2f", w) } else { widthText = "" }
        if let h = item.heightIn { heightText = String(format: "%.2f", h) } else { heightText = "" }
    }

    private func saveToDraft() {
        // Editing an AI-changed title/description here counts as taking ownership,
        // same as inline edits in ResultDraftRow: a real change retires the AI diff
        // (Review & Publish then shows a normal field, not the word-diff).
        if item.originalUserTitleBeforeAI != nil,
           title != (item.userEditedTitle ?? item.aiSuggestedTitle ?? "") {
            item.originalUserTitleBeforeAI = nil
        }
        if item.originalUserDescriptionBeforeAI != nil,
           description != (item.userEditedDescription ?? item.aiSuggestedDescription ?? "") {
            item.originalUserDescriptionBeforeAI = nil
        }
        item.userEditedTitle = title.isEmpty ? nil : title
        item.userEditedPrice = Double(priceText.filter { $0.isNumber || $0 == "." })
        item.userEditedDescription = description.isEmpty ? nil : description
        item.personalNote = personalNote.isEmpty ? nil : personalNote
        item.condition = selectedCondition.rawValue
        item.buyerPaysShipping = buyerPaysShipping
        item.handlingFee = Double(handlingFee.filter { $0.isNumber || $0 == "." }) ?? 0
        item.estimatedShippingDays = Int(estimatedDays) ?? 3
        item.handlingTimeDays = handlingTimeDaysOverride
        item.facebookOfferShipping = facebookOfferShipping
        item.facebookHideFromFriends = facebookHideFromFriends
        item.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        
        // Dimensions & Weight
        item.weightLbs = Double(weightText.filter { $0.isNumber || $0 == "." })
        item.lengthIn = Double(lengthText.filter { $0.isNumber || $0 == "." })
        item.widthIn = Double(widthText.filter { $0.isNumber || $0 == "." })
        item.heightIn = Double(heightText.filter { $0.isNumber || $0 == "." })

        try? modelContext.save()
        UploadManager.shared.syncProductData(item)
    }
    }


// MARK: - DescriptionEditorSheet
private struct DescriptionEditorSheet: View {
    var initialText: String
    var onSave: (String) -> Void
    var hasAIPurple: Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    
    @State private var localText: String = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $localText)
                .focused($focused)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .background(hasAIPurple ? Color.purple.opacity(0.05) : Color(.systemBackground))
                .navigationTitle("Description")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onSave(localText)
                            dismiss()
                        }
                    }
                }
        }
        .onAppear {
            localText = initialText
            focused = true
        }
    }
}

// MARK: - TitleEditorSheet
private struct TitleEditorSheet: View {
    var initialText: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    @State private var localText: String = ""

    var body: some View {
        NavigationStack {
            TextField("Add title…", text: $localText, axis: .vertical)
                .focused($focused)
                .font(.body)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .navigationTitle("Title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onSave(localText)
                            dismiss()
                        }
                    }
                }
        }
        .onAppear {
            localText = initialText
            focused = true
        }
    }
}

// MARK: - Draft Focus Types (shared between DraftsView & ProcessResultsOverviewView)

struct DraftFocusField: Hashable {
    let itemID: UUID
    let field: DraftFocusSubfield
}
enum DraftFocusSubfield: Hashable { case title, price, description }

// MARK: - ProcessResultsOverviewView


struct ProcessResultsOverviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Item> { $0.isDraft == true })
    private var allItems: [Item]
    @EnvironmentObject private var uploadManager: UploadManager

    @State private var cache = CachedImageManager()
    @State private var selectedIDs: Set<UUID> = []
    @State private var showingEditSheet: Item? = nil
    @FocusState private var focusedField: DraftFocusField?
    /// Measured height of the List container, used to compute per-item description size.
    @State private var listHeight: CGFloat = 0
    /// Direction of the last arrow-key move, so continuing past a description slot (see
    /// ResultDraftRow.onDescriptionAutoAdvance) keeps going the same way the user was already moving.
    @State private var lastFocusMoveDelta = 1

    @State private var showPublishConfirmation = false
    // The post-publish continuation (deferred API triggers, web autofill job building,
    // its gating flags) lives on UploadManager — see its "Publish continuation" section.
    // It was @State here once, and dismissing this sheet mid-publish discarded it.

    // Only show the items that went through AI processing
    private var results: [Item] {
        let processedSet = Set(uploadManager.processedItemIDs)
        // See UploadManager.deletedDraftIDs — deletion is deferred a tick, so this filter is
        // what actually drops the row from the List immediately.
        // publishedAt != nil means this item already published successfully and is only
        // still in SwiftData because a queued web cross-post job needs its photos — drop it
        // from the reviewable/swipeable list the moment that happens, instead of leaving a
        // live listing looking like an ordinary draft (see deleteDraftLocallyAndCloud).
        // pendingPublish=true items ARE kept here intentionally — they are failed-to-publish
        // drafts that the user is retrying. They appear with an orange highlight below.
        // Items where Gemini itself failed (processingFailedIDs) must ALSO show here, not
        // just successes — ResultDraftRow already renders a dedicated "Couldn't identify —
        // enter details manually" state for isGeminiFailed, but excluding them from `results`
        // made that state unreachable: if every draft failed AI (e.g. Gemini outage), this
        // screen rendered a totally empty list instead of the failed drafts to fix up by hand
        // (found 2026-09-15).
        let failedSet = Set(uploadManager.processingFailedIDs)
        return allItems.filter { (processedSet.contains($0.id) || failedSet.contains($0.id)) && !uploadManager.deletedDraftIDs.contains($0.id) && $0.publishedAt == nil }
    }

    private var toPublish: [Item] {
        selectedIDs.isEmpty ? results : results.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(results) { item in
                    ResultDraftRow(
                        item: item,
                        cache: cache,
                        isSelected: selectedIDs.contains(item.id),
                        onToggle: { toggleSelection(item) },
                        focusedField: $focusedField,
                        isGeminiFailed: uploadManager.processingFailedIDs.contains(item.id),
                        descriptionLineLimit: descriptionLineLimit,
                        onDescriptionAutoAdvance: { moveFocus(by: lastFocusMoveDelta) }
                    )
                    .equatable()
                    // Orange tint for items that previously failed to publish
                    // (pendingPublish=true but not yet successfully written to Firestore).
                    .listRowBackground(item.pendingPublish ? Color.orange.opacity(0.10) : nil)
                }
                .onDelete { offsets in
                    for i in offsets {
                        uploadManager.deleteDraftLocallyAndCloud(draft: results[i], modelContext: modelContext)
                    }
                }
            }
            .listStyle(.plain)
            .background(GeometryReader { geo in
                Color.clear.onAppear { listHeight = geo.size.height }
            })
            .onAppear { selectedIDs = Set(results.map { $0.id }) }

            // ── Bottom action bar ────────────────────────────────────────
            // The Mercari autofill pill lives in MainView, underneath this sheet — surface
            // its activity here so the user isn't staring at a seemingly frozen screen.
            if uploadManager.globalMercariJob != nil {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Posting to Mercari in the background…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.purple.opacity(0.08))
            }
            Divider()
            HStack(spacing: 16) {
                Button(selectedIDs.count == results.count ? "Deselect All" : "Select All") {
                    if selectedIDs.count == results.count {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(results.map { $0.id })
                    }
                }
                .font(.subheadline)

                Spacer()

                Button {
                    focusedField = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        uploadManager.publishConfirmationSheetVisible = true
                        showPublishConfirmation = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        let busy = uploadManager.isUploadingPhotos || uploadManager.isPublishing
                        let countLabel: String = selectedIDs.isEmpty ? "All" : "\(selectedIDs.count)"
                        let buttonLabel: String = uploadManager.isPublishing ? "Publishing…" : uploadManager.isUploadingPhotos ? "Uploading Photos…" : "Publish \(countLabel)"
                        if busy {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        }
                        Text(buttonLabel)
                        .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(
                        (uploadManager.isUploadingPhotos || uploadManager.isPublishing) ? Color.secondary : Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                .disabled(results.isEmpty || uploadManager.isUploadingPhotos || uploadManager.isPublishing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .navigationTitle("Review & Publish")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Spec N4: full-screen view with an explicit way back — returns to the
            // camera with drafts saved. Safe even mid-publish: the continuation lives
            // on UploadManager (Phase 3) and the queue pill re-opens this view.
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    uploadManager.showResultsOverview = false
                    uploadManager.returnToCameraRoot = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                let atFirst: Bool = focusedIndex == nil || focusedIndex == 0
                let atLast: Bool = focusedIndex == nil || focusedIndex == results.count * 3 - 1
                Button(action: { moveFocus(by: -1) }) { Image(systemName: "chevron.up") }
                    .disabled(atFirst)
                Button(action: { moveFocus(by: 1) }) { Image(systemName: "chevron.down") }
                    .disabled(atLast)
                Spacer()
                Button("Done") {
                    focusedField = nil
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .alert("Publish Failed", isPresented: Binding(
            get: { uploadManager.publishError != nil },
            set: { if !$0 { uploadManager.publishError = nil } }
        )) {
            Button("OK", role: .cancel) { uploadManager.publishError = nil }
        } message: {
            Text(uploadManager.publishError ?? "")
        }
        // The eBay/Etsy cross-post error (crossPostError) is NOT surfaced here — see
        // UploadManager.crossPostError. The API-trigger Task that sets it typically completes
        // after this view has already been dismissed (showResultsOverview = false runs
        // immediately once publish succeeds and there's no web-autofill queue to wait on), so
        // a local alert here would silently discard it. It's shown from CrossPostStatusView
        // instead, which is reliably the next screen the user lands on either way.
        .sheet(isPresented: $showPublishConfirmation, onDismiss: {
            // Fires once the sheet is FULLY gone — only now is it safe to run the
            // post-publish continuation that mutates other sheet state.
            uploadManager.publishConfirmationSheetVisible = false
            uploadManager.runPublishContinuationIfReady(modelContext: modelContext)
            // If beginPublish was called (i.e. user didn't cancel), swap to CrossPostStatusView —
            // the single post-publish status screen (Wonni + eBay + Mercari, live per row).
            // Delay matches the existing AI→results transition to avoid overlapping covers.
            if uploadManager.isPublishing || !uploadManager.publishStatuses.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    uploadManager.showResultsOverview = false
                    uploadManager.showCrossPostStatus = true
                }
            }
        }) {
            publishConfirmationSheetContent
        }
    }
    
    @ViewBuilder private var publishConfirmationSheetContent: some View {
        PublishConfirmationSheet(itemsToPublish: toPublish) { selectedPlatforms in
            // Web autofill jobs are BUILT in UploadManager.runPublishContinuationIfReady,
            // after publish completes — at this point firestoreListingId can be nil and the
            // Storage photo uploads unfinished, so a job snapshotted now would carry empty
            // paths / no listing ID (the old fragility: jobs held the live draft instead and
            // broke whenever the draft was deleted or its photos still uploading). Here we
            // only record what to build; beginPublish stores it all on the manager.
            let webPlatforms = selectedPlatforms.filter { $0 == "mercari" || $0 == "facebook" }.sorted()
            // Capture per-listing cross-post info now (before the drafts are deleted) so the
            // post-publish status overview can show per-platform status and offer retries.
            let attemptedPlatforms = Array(selectedPlatforms).sorted()
            // Always populate so CrossPostStatusView (global sheet) can show at minimum
            // "Wonni - posted" even when no cross-posting was selected.
            uploadManager.sessionCrossPostItems = toPublish.compactMap { item in
                guard let listingId = item.firestoreListingId else { return nil }
                return CrossPostSessionItem(
                    id: listingId,
                    draftId: item.id,
                    title: item.userEditedTitle ?? item.aiSuggestedTitle ?? "Untitled",
                    description: item.userEditedDescription ?? item.aiSuggestedDescription ?? "",
                    price: item.userEditedPrice ?? item.aiSuggestedPrice ?? 0.0,
                    coverPhotoPath: item.orderedFirebasePhotoPaths.first,
                    photoPaths: item.orderedFirebasePhotoPaths,
                    platforms: attemptedPlatforms,
                    buyerPaysShipping: item.buyerPaysShipping,
                    condition: item.condition ?? ItemCondition.good.rawValue
                )
            }
            if !attemptedPlatforms.isEmpty {
                uploadManager.crossPostStatusPending = true
            }
            // API cross-posts are deferred to the publish completion (the continuation)
            // so the Firestore write completes before the Cloud Function reads the listing.
            let apiPlatforms = selectedPlatforms.filter { $0 == "ebay" || $0 == "etsy" }
            let apiTriggers: [UploadManager.PendingAPITrigger] = apiPlatforms.isEmpty ? [] : toPublish.compactMap { item in
                guard let listingId = item.firestoreListingId else { return nil }
                let title = item.userEditedTitle ?? item.aiSuggestedTitle ?? "Untitled"
                return UploadManager.PendingAPITrigger(listingId: listingId, title: title, platforms: Array(apiPlatforms))
            }
            uploadManager.beginPublish(
                drafts: toPublish,
                webPlatforms: webPlatforms,
                apiTriggers: apiTriggers,
                modelContext: modelContext
            )
        }
        .presentationDetents([.large])
    }

    private func toggleSelection(_ item: Item) {
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
        else { selectedIDs.insert(item.id) }
    }

    private var descriptionLineLimit: Int {
        guard !results.isEmpty, listHeight > 0 else { return 4 }
        let count = CGFloat(results.count)
        let bottomBarH: CGFloat = 72
        let processingBannerH: CGFloat = uploadManager.isProcessing ? 50 : 0
        let perRowFixedH: CGFloat = 120
        let lineH: CGFloat = 17
        let descPaddingH: CGFloat = 16
        let totalFixed = perRowFixedH * count + bottomBarH + processingBannerH
        let perItemDescH = (listHeight - totalFixed) / count
        return max(3, Int((perItemDescH - descPaddingH) / lineH))
    }

    private var focusedIndex: Int? {
        guard let fv = focusedField else { return nil }
        guard let row = results.firstIndex(where: { $0.id == fv.itemID }) else { return nil }
        let fieldOffset: Int
        switch fv.field {
        case .title: fieldOffset = 0
        case .price: fieldOffset = 1
        case .description: fieldOffset = 2
        }
        return row * 3 + fieldOffset
    }

    private func moveFocus(by delta: Int) {
        lastFocusMoveDelta = delta
        guard let current = focusedIndex else { return }
        let next = current + delta
        let maxIndex = results.count * 3 - 1
        guard next >= 0 && next <= maxIndex else { return }
        let row = next / 3
        let field: DraftFocusSubfield
        switch next % 3 {
        case 0: field = .title
        case 1: field = .price
        default: field = .description
        }
        focusedField = DraftFocusField(itemID: results[row].id, field: field)
    }
}

// MARK: - Cross-Post Status Overview

/// One published listing's cross-post info, captured at publish time so the status overview
/// survives the SwiftData draft being deleted.
struct CrossPostSessionItem: Identifiable, Equatable {
    let id: String              // Firestore listing document ID
    let draftId: UUID           // SwiftData Item.id — keys uploadManager.publishStatuses
    let title: String
    let description: String
    let price: Double
    let coverPhotoPath: String?
    let photoPaths: [String]
    let platforms: [String]     // attempted cross-post platforms, e.g. ["ebay","mercari"]
    let buyerPaysShipping: Bool
    let condition: String       // ItemCondition rawValue, so retries don't post as "good"
}

/// Post-publish overview: per listing, shows Wonni plus each attempted platform's live status
/// (read from Firestore `crossPostStatus`) with one-tap retry for any failures. This is the
/// "see status + retry" screen, shown in place of silently bouncing home after a cross-post.
struct CrossPostStatusView: View {
    let items: [CrossPostSessionItem]
    /// Called with `true` when every row has resolved (posted or failed) — the caller can
    /// safely discard session state. Called with `false` on "Minimize", where the queue
    /// keeps running in the background and the caller should keep the session around so
    /// re-opening (e.g. via the AppTaskQueue pill) shows the same, still-updating list.
    var onDone: (Bool) -> Void

    @State private var statuses: [String: [String: String]] = [:]   // listingId -> platform -> status
    @State private var listeners: [ListenerRegistration] = []
    @State private var retryJob: CrossPostJob? = nil
    @State private var retryingEbay: Set<String> = []
    @AppStorage("hasSeenEbayEditingNotice") private var hasSeenEbayEditingNotice = false
    @State private var showEbayNoticeAlert = false
    @EnvironmentObject private var uploadManager: UploadManager
    @Environment(\.modelContext) private var modelContext
    @Query private var allDraftItems: [Item]

    /// Wonni's own publish (photo upload + Firestore write) is tracked separately from
    /// cross-post platforms, in uploadManager.publishStatuses (keyed by the SwiftData
    /// draft id, not the Firestore listing id) — this view auto-opens the instant publish
    /// begins, before the "wonni" row even has a status. Maps DraftUploadStatus onto the
    /// same pending/posted/failed vocabulary the rest of this view already speaks.
    private func wonniStatus(for item: CrossPostSessionItem) -> String {
        switch uploadManager.publishStatuses[item.draftId] ?? .pending {
        case .pending, .uploading: return "pending"
        case .done:                return "posted"
        case .failed:              return "failed"
        }
    }

    private var allResolved: Bool {
        for item in items {
            if wonniStatus(for: item) == "pending" { return false }
            for platform in item.platforms where platform != "wonni" {
                let status = statuses[item.id]?[platform] ?? "pending"
                if status == "pending" || status == "removing" { return false }
            }
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(items) { item in
                    Section {
                        platformRow(item: item, platform: "wonni")
                        ForEach(item.platforms.filter { $0 != "wonni" }, id: \.self) { platform in
                            platformRow(item: item, platform: platform)
                        }
                    } header: {
                        HStack(spacing: 10) {
                            if let cover = item.coverPhotoPath {
                                StorageImage(path: cover)
                                    .frame(width: 30, height: 30)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)

            Divider()
            // N6: still-in-flight jobs can be minimized (mirrors ProcessProgressView) —
            // the queue keeps running via UploadManager, this view just steps aside.
            // Once everything has resolved (posted or failed), it reads "Done".
            Button(action: { stopListeners(); onDone(allResolved) }) {
                Text(allResolved ? "Done" : "Minimize")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .navigationTitle("Cross-Post Status")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .onAppear(perform: startListeners)
        .onDisappear(perform: stopListeners)
        .sheet(item: $retryJob) { job in
            FacebookAutoPosterView(job: job)
        }
        // See UploadManager.crossPostError — surfaced here (not on ProcessResultsOverviewView)
        // because this is reliably the screen the user is on by the time an eBay/Etsy
        // cross-post Task resolves, regardless of how quickly the previous screen dismissed.
        // The live status badge below (via startListeners' Firestore listener) already shows
        // "Failed" + Retry per-row from the Cloud Function's own crossPostStatus write, so this
        // alert exists mainly to explain WHY it failed the moment it happens, once, per attempt.
        .alert("Cross-Post Failed", isPresented: Binding(
            get: { uploadManager.crossPostError != nil },
            set: { if !$0 { uploadManager.crossPostError = nil } }
        )) {
            Button("OK", role: .cancel) { uploadManager.crossPostError = nil }
        } message: {
            Text(uploadManager.crossPostError ?? "")
        }
        // See UploadManager.photoUploadWarning — a listing can publish (and cross-post) with
        // fewer photos than selected if one silently failed every upload retry; this is the
        // first point the user finds out, rather than noticing a thin listing later.
        .alert("Some Photos Didn't Upload", isPresented: Binding(
            get: { uploadManager.photoUploadWarning != nil },
            set: { if !$0 { uploadManager.photoUploadWarning = nil } }
        )) {
            Button("OK", role: .cancel) { uploadManager.photoUploadWarning = nil }
        } message: {
            Text(uploadManager.photoUploadWarning ?? "")
        }
        .alert("Managing Your eBay Listing", isPresented: $showEbayNoticeAlert) {
            Button("Got It", role: .cancel) {
                hasSeenEbayEditingNotice = true
            }
        } message: {
            Text("Your item is now live on eBay!\n\n• To edit details: Update your listing right here in Wonni, and changes will push to eBay automatically.\n• Direct eBay edits: eBay locks the standard consumer edit page for API listings. To edit on eBay, use eBay Seller Hub (ebay.com/sh/lst/active).")
        }
    }

    @ViewBuilder
    private func platformRow(item: CrossPostSessionItem, platform: String) -> some View {
        let status = platform == "wonni" ? wonniStatus(for: item) : (statuses[item.id]?[platform] ?? "pending")
        HStack(spacing: 12) {
            Image(systemName: platformIcon(platform))
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(platformName(platform))
                .font(.subheadline)
            Spacer()
            statusBadge(status)
            if status == "failed" {
                Button("Retry") { retry(item: item, platform: platform) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .disabled(platform == "ebay" && retryingEbay.contains(item.id))
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        switch status {
        case "posted":
            Label("Posted", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.green).labelStyle(.titleAndIcon)
        case "failed":
            Label("Failed", systemImage: "exclamationmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.red).labelStyle(.titleAndIcon)
        case "pending", "removing":
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.6)
                Text(status == "removing" ? "Removing…" : "In progress…")
                    .font(.caption).foregroundStyle(.orange)
            }
        default:
            Text(status.capitalized).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func startListeners() {
        stopListeners()
        let db = Firestore.firestore()
        for item in items {
            let reg = db.collection("listings").document(item.id).addSnapshotListener { snap, _ in
                guard let data = snap?.data() else { return }
                let cpStatus = data["crossPostStatus"] as? [String: String] ?? [:]
                statuses[item.id] = cpStatus
                if !hasSeenEbayEditingNotice && cpStatus["ebay"] == "posted" {
                    showEbayNoticeAlert = true
                }
            }
            listeners.append(reg)
        }
    }

    private func stopListeners() {
        listeners.forEach { $0.remove() }
        listeners.removeAll()
    }

    private func retry(item: CrossPostSessionItem, platform: String) {
        switch platform {
        case "wonni":
            guard let draft = allDraftItems.first(where: { $0.id == item.draftId }) else { return }
            uploadManager.retryFailedPublish(drafts: [draft], modelContext: modelContext)
        case "ebay", "etsy":
            retryingEbay.insert(item.id)
            Task {
                try? await IntegrationRepository.shared.triggerCrossPost(listingId: item.id, platforms: [platform])
                retryingEbay.remove(item.id)
            }
        case "mercari":
            let job = CrossPostJob(
                platform: platform,
                title: item.title,
                description: item.description,
                price: item.price,
                listingId: item.id,
                photoFirebasePaths: item.photoPaths,
                buyerPaysShipping: item.buyerPaysShipping,
                condition: item.condition
            )
            uploadManager.globalMercariJob = job
            uploadManager.onMercariJobComplete = nil
        case "facebook":
            // Facebook requires a visible full-screen sheet.
            retryJob = CrossPostJob(
                platform: platform,
                title: item.title,
                description: item.description,
                price: item.price,
                listingId: item.id,
                photoFirebasePaths: item.photoPaths,
                buyerPaysShipping: item.buyerPaysShipping,
                condition: item.condition,
                facebookLocation: CrossPostJob.facebookLocationFromSettings()
            )
        default:
            break
        }
    }

    private func platformName(_ platform: String) -> String {
        switch platform {
        case "wonni":    return "Wonni"
        case "ebay":     return "eBay"
        case "mercari":  return "Mercari"
        case "facebook": return "Facebook Marketplace"
        case "etsy":     return "Etsy"
        default:         return platform.capitalized
        }
    }

    private func platformIcon(_ platform: String) -> String {
        switch platform {
        case "wonni":    return "bag.fill"
        case "facebook": return "person.2.fill"
        default:         return "globe"
        }
    }
}

// MARK: - WordDiffView

private struct WordDiffView: View {
    let before: String
    let after: String

    enum TokenKind { case same, deleted, added }
    struct Token { let word: String; let kind: TokenKind }

    var body: some View {
        tokens.reduce(Text("")) { acc, tok in
            switch tok.kind {
            case .same:    return acc + Text(tok.word + " ").font(.caption).foregroundColor(.primary)
            case .deleted: return acc + Text(tok.word + " ").font(.caption).foregroundColor(.red).strikethrough()
            case .added:   return acc + Text(tok.word + " ").font(.caption).foregroundColor(.green).fontWeight(.semibold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tokens: [Token] {
        let old = before.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let new = after.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let lcs = longestCommonSubsequence(old, new)
        return buildDiff(old: old, new: new, lcs: lcs)
    }

    private func buildDiff(old: [String], new: [String], lcs: [String]) -> [Token] {
        var result: [Token] = []
        var oi = 0, ni = 0, li = 0
        while oi < old.count || ni < new.count {
            if li < lcs.count {
                while oi < old.count && old[oi] != lcs[li] {
                    result.append(Token(word: old[oi], kind: .deleted)); oi += 1
                }
                while ni < new.count && new[ni] != lcs[li] {
                    result.append(Token(word: new[ni], kind: .added)); ni += 1
                }
                if oi < old.count && ni < new.count {
                    result.append(Token(word: lcs[li], kind: .same))
                    oi += 1; ni += 1; li += 1
                }
            } else {
                while oi < old.count { result.append(Token(word: old[oi], kind: .deleted)); oi += 1 }
                while ni < new.count { result.append(Token(word: new[ni], kind: .added)); ni += 1 }
            }
        }
        return result
    }

    private func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        guard !a.isEmpty && !b.isEmpty else { return [] }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                dp[i][j] = a[i-1] == b[j-1] ? dp[i-1][j-1] + 1 : Swift.max(dp[i-1][j], dp[i][j-1])
            }
        }
        var res: [String] = []
        var i = a.count, j = b.count
        while i > 0 && j > 0 {
            if a[i-1] == b[j-1] { res.insert(a[i-1], at: 0); i -= 1; j -= 1 }
            else if dp[i-1][j] > dp[i][j-1] { i -= 1 }
            else { j -= 1 }
        }
        return res
    }
}

// MARK: - AIUndoToastView

private struct AIUndoToastView: View {
    let message: String
    let onRestore: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if let restore = onRestore {
                Button("Restore", action: restore)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.label).opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

// MARK: - ResultDraftRow

struct ResultDraftRow: View, Equatable {
    let item: Item
    let cache: CachedImageManager
    let isSelected: Bool
    let onToggle: () -> Void
    var focusedField: FocusState<DraftFocusField?>.Binding
    var isGeminiFailed: Bool = false
    /// Minimum lines for the description field; computed from available screen height.
    var descriptionLineLimit: Int = 4
    /// Called when the description sheet — opened via arrow-key navigation landing on this
    /// row's description slot, not a direct tap — is dismissed. Lets the keyboard toolbar's
    /// up/down arrows continue on to the next field instead of stopping dead at description,
    /// which (unlike title/price) isn't a real focusable text field.
    var onDescriptionAutoAdvance: (() -> Void)? = nil

    // ProcessResultsOverviewView.body re-evaluates on every uploadManager @Published change
    // (isUploadingPhotos, isPublishing, processingFailedIDs are all read there directly) —
    // which fires repeatedly while background photo uploads are still finishing, i.e.
    // exactly while the user is typing on this screen. That reconstructs every row with a
    // fresh `onToggle` closure, and SwiftUI's default diffing treats closures as always
    // "changed," so every row's body re-evaluates on every tick regardless of whether it has
    // anything to do with that row. Equatable + `.equatable()` at the call site lets SwiftUI
    // skip re-evaluating a row whose actual rendered inputs haven't changed. Compares every
    // `item` field this row reads — add to this list if the body starts reading a new one.
    static func == (lhs: ResultDraftRow, rhs: ResultDraftRow) -> Bool {
        lhs.isSelected == rhs.isSelected &&
        lhs.isGeminiFailed == rhs.isGeminiFailed &&
        lhs.descriptionLineLimit == rhs.descriptionLineLimit &&
        lhs.focusedField.wrappedValue == rhs.focusedField.wrappedValue &&
        lhs.item.sourceAssetIdentifiers == rhs.item.sourceAssetIdentifiers &&
        lhs.item.userEditedTitle == rhs.item.userEditedTitle &&
        lhs.item.aiSuggestedTitle == rhs.item.aiSuggestedTitle &&
        lhs.item.visionTitle == rhs.item.visionTitle &&
        lhs.item.userEditedPrice == rhs.item.userEditedPrice &&
        lhs.item.aiSuggestedPrice == rhs.item.aiSuggestedPrice &&
        lhs.item.userEditedDescription == rhs.item.userEditedDescription &&
        lhs.item.aiSuggestedDescription == rhs.item.aiSuggestedDescription &&
        lhs.item.originalUserTitleBeforeAI == rhs.item.originalUserTitleBeforeAI &&
        lhs.item.originalUserDescriptionBeforeAI == rhs.item.originalUserDescriptionBeforeAI
    }

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var uploadManager: UploadManager
    @State private var titleText: String = ""
    @State private var priceText: String = ""
    @State private var descriptionText: String = ""
    @State private var showEditSheet = false
    @State private var showDescriptionEditor = false
    @State private var descriptionEditorOpenedViaFocus = false
    @State private var undoneAITitle: String? = nil
    @State private var undoneAIDescription: String? = nil
    @State private var toastMessage: String? = nil
    @State private var toastRestoreAction: (() -> Void)? = nil
    /// While an AI-edited title shows as a word-diff, tapping it (or arrow-keying into
    /// it) swaps in the editable field. Leaving the field decides the diff's fate:
    /// text changed → the user has taken ownership, drop `originalUserTitleBeforeAI`
    /// (row becomes a normal title permanently); unchanged → the diff comes back.
    @State private var isEditingAITitle = false
    @State private var aiTitleAtEditStart: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ── Top row: toggle + photo + title/price + edit ───────────────
            HStack(alignment: .top, spacing: 14) {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

                Group {
                    if let assetId = item.sourceAssetIdentifiers.first {
                        DraftThumbnailView(item: item, assetId: assetId)
                    } else {
                        Color(.systemGray5)
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    // AI-edited titles show ONLY the diff (accept = leave it, reject =
                    // undo link, edit = tap the diff). The old layout stacked the diff
                    // AND a duplicate editable title, which read as two titles.
                    if let origTitle = item.originalUserTitleBeforeAI, !isEditingAITitle {
                        HStack(alignment: .top, spacing: 6) {
                            WordDiffView(before: origTitle, after: titleText)
                            Spacer(minLength: 0)
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { beginEditingAITitle() }
                        Button("Undo AI title edits") { undoAITitle() }
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)
                            .buttonStyle(.plain)
                    } else {
                        TextField("Title", text: $titleText)
                            .font(.body.weight(.semibold))
                            .focused(focusedField, equals: DraftFocusField(itemID: item.id, field: .title))

                        TitleCharCountView(count: titleText.count)
                    }

                    HStack(spacing: 3) {
                        Text("$").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Price", text: $priceText)
                            .font(.subheadline)
                            .keyboardType(.decimalPad)
                            .focused(focusedField, equals: DraftFocusField(itemID: item.id, field: .price))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { showEditSheet = true } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            // ── Description (full width) ────────────────────────────────────
            // Same treatment as the title: an AI-edited description shows ONLY the
            // diff (tap opens the editor; saving a real change drops the diff), not
            // the diff plus a duplicate description box.
            if let origDesc = item.originalUserDescriptionBeforeAI {
                HStack(alignment: .top, spacing: 6) {
                    WordDiffView(before: origDesc, after: descriptionText)
                    Spacer(minLength: 0)
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture { showDescriptionEditor = true }
                Button("Undo AI description edits") { undoAIDescription() }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
            } else {
                Button { showDescriptionEditor = true } label: {
                    Text(descriptionText.isEmpty ? "Add description…" : descriptionText)
                        .lineLimit(3)
                        .font(.caption)
                        .foregroundStyle(descriptionText.isEmpty
                            ? Color(.placeholderText)
                            : (item.userEditedDescription != nil ? .primary : .secondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            // ── AI badge row ────────────────────────────────────────────────
            let hasAIEdits = item.originalUserTitleBeforeAI != nil || item.originalUserDescriptionBeforeAI != nil
            HStack(spacing: 0) {
                if isGeminiFailed {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                        Text("Couldn't identify — enter details manually").font(.caption2).foregroundStyle(.orange.opacity(0.9))
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles").font(.caption2).foregroundStyle(.purple)
                        Text(hasAIEdits ? "AI edited" : "AI identified").font(.caption2).foregroundStyle(.purple.opacity(0.8))
                    }
                }
                Spacer()
            }

            // ── Undo toast (in flow) ────────────────────────────────────────
            // A real list element, not an overlay: the old floating version sat on
            // top of neighboring rows and hid them. In flow, it occupies (part of)
            // the space the undone AI text just vacated.
            if let msg = toastMessage {
                AIUndoToastView(message: msg, onRestore: toastRestoreAction)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.vertical, 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toastMessage != nil)
        .sheet(isPresented: $showDescriptionEditor) {
            DescriptionEditorSheet(
                initialText: descriptionText,
                onSave: { newText in
                    let changed = newText != descriptionText
                    item.userEditedDescription = newText.isEmpty ? nil : newText
                    if changed && item.originalUserDescriptionBeforeAI != nil {
                        // The user reshaped the AI's description to their liking —
                        // the diff has served its purpose; show a normal field now.
                        item.originalUserDescriptionBeforeAI = nil
                    }
                },
                hasAIPurple: item.originalUserDescriptionBeforeAI != nil
            )
        }
        .onAppear {
            titleText = item.userEditedTitle ?? item.aiSuggestedTitle ?? ""
            descriptionText = item.userEditedDescription ?? item.aiSuggestedDescription ?? ""
            if let p = item.userEditedPrice ?? item.aiSuggestedPrice {
                priceText = String(format: "%.2f", p)
            }
        }
        .onChange(of: focusedField.wrappedValue) { oldFocus, newFocus in
            let myTitle = DraftFocusField(itemID: item.id, field: .title)
            // Leaving the title field while editing an AI-diffed title decides the
            // diff's fate (see endEditingAITitleIfNeeded) BEFORE the general save.
            if oldFocus == myTitle && newFocus != myTitle {
                endEditingAITitleIfNeeded()
            }
            if oldFocus?.itemID == item.id && newFocus?.itemID != item.id {
                saveLocalStateToModel()
            }
            // Arrow-keying into a title that's showing as a diff: swap in the editable
            // field, same as tapping the diff.
            if newFocus == myTitle && item.originalUserTitleBeforeAI != nil && !isEditingAITitle {
                beginEditingAITitle()
            }
            // Description isn't a real focusable field (it's a button that opens a sheet),
            // so the keyboard arrows can't land real focus there. Landing "on" it via arrow
            // navigation instead opens the sheet directly, so up/down keeps working through it.
            if newFocus == DraftFocusField(itemID: item.id, field: .description) {
                descriptionEditorOpenedViaFocus = true
                showDescriptionEditor = true
            }
        }
        // Sync local state when the model is updated externally (undo AI edits, undo-toast
        // restore, bulk edit, edit sheet). Without this, the next saveLocalStateToModel()
        // (focus change / onDisappear) writes the stale local text back over the external
        // change — which made "Undo AI edits" silently revert. Same fix DraftRow got in
        // 1ad19e7 for its title/price.
        .onChange(of: item.userEditedTitle) { _, newVal in
            titleText = newVal ?? item.aiSuggestedTitle ?? ""
        }
        .onChange(of: item.userEditedDescription) { _, newVal in
            descriptionText = newVal ?? item.aiSuggestedDescription ?? ""
        }
        .onChange(of: item.userEditedPrice) { _, newVal in
            if let p = newVal ?? item.aiSuggestedPrice {
                priceText = String(format: "%.2f", p)
            } else {
                priceText = ""
            }
        }
        .onChange(of: showDescriptionEditor) { _, isShowing in
            // Fires whether the sheet was saved or swiped away — either way, continue the
            // arrow-key flow onward once the user's done with the description.
            if !isShowing && descriptionEditorOpenedViaFocus {
                descriptionEditorOpenedViaFocus = false
                onDescriptionAutoAdvance?()
            }
        }
        .onDisappear {
            endEditingAITitleIfNeeded()
            saveLocalStateToModel()
        }
        .sheet(isPresented: $showEditSheet) {
            DraftEditSheet(item: item)
        }
    }

    /// Swap the AI-title diff for the editable field and focus it. The focus assignment
    /// is deferred a tick so the TextField exists in the hierarchy before it's targeted.
    private func beginEditingAITitle() {
        aiTitleAtEditStart = titleText
        isEditingAITitle = true
        DispatchQueue.main.async {
            focusedField.wrappedValue = DraftFocusField(itemID: item.id, field: .title)
        }
    }

    /// Ends an AI-title editing session. Changed text means the user reshaped the AI's
    /// title to their liking — drop `originalUserTitleBeforeAI` so the row becomes a
    /// normal title field (their requested accept/reject/edit semantics). Unchanged
    /// text (tapped in, tapped out) brings the diff back.
    private func endEditingAITitleIfNeeded() {
        guard isEditingAITitle else { return }
        isEditingAITitle = false
        if let start = aiTitleAtEditStart, titleText != start,
           !Item.deletedIDs.contains(item.id) {
            item.originalUserTitleBeforeAI = nil
        }
        aiTitleAtEditStart = nil
    }

    private func saveLocalStateToModel() {
        // Same detached-object guard as DraftRow — the sheet can be dismissed as part
        // of a flow that already deleted the draft.
        guard !Item.deletedIDs.contains(item.id) else { return }
        let v = String(titleText.prefix(140))
        if item.userEditedTitle != (v.isEmpty ? nil : v) {
            item.userEditedTitle = v.isEmpty ? nil : v
        }

        if item.userEditedDescription != (descriptionText.isEmpty ? nil : descriptionText) {
            item.userEditedDescription = descriptionText.isEmpty ? nil : descriptionText
        }

        let cleaned = priceText.filter { $0.isNumber || $0 == "." }
        let newPrice = cleaned.isEmpty ? nil : Double(cleaned)
        if item.userEditedPrice != newPrice {
            item.userEditedPrice = newPrice
        }

        try? modelContext.save()
        uploadManager.syncProductData(item)
    }

    private func undoAITitle() {
        guard let orig = item.originalUserTitleBeforeAI else { return }
        let aiTitle = item.userEditedTitle
        // Drive the visible field on the tap frame. Without this the field only updates
        // after the model write round-trips back through .onChange(of: item.userEditedTitle),
        // which (behind a synchronous save + Firestore sync) is the lag users reported.
        titleText = orig.isEmpty ? (item.aiSuggestedTitle ?? "") : orig
        item.userEditedTitle = orig.isEmpty ? nil : orig
        item.originalUserTitleBeforeAI = nil
        item.aiUndoCount += 1
        undoneAITitle = aiTitle
        showToast(message: "AI title edits discarded") { [self] in
            titleText = self.undoneAITitle ?? item.aiSuggestedTitle ?? ""
            item.originalUserTitleBeforeAI = item.userEditedTitle
            item.userEditedTitle = self.undoneAITitle
            item.aiUndoCount = max(0, item.aiUndoCount - 1)
            self.undoneAITitle = nil
            deferredPersist()
        }
        deferredPersist()
    }

    private func undoAIDescription() {
        guard let orig = item.originalUserDescriptionBeforeAI else { return }
        let aiDesc = item.userEditedDescription
        descriptionText = orig.isEmpty ? (item.aiSuggestedDescription ?? "") : orig
        item.userEditedDescription = orig.isEmpty ? nil : orig
        item.originalUserDescriptionBeforeAI = nil
        item.aiUndoCount += 1
        undoneAIDescription = aiDesc
        showToast(message: "AI description edits discarded") { [self] in
            descriptionText = self.undoneAIDescription ?? item.aiSuggestedDescription ?? ""
            item.originalUserDescriptionBeforeAI = item.userEditedDescription
            item.userEditedDescription = self.undoneAIDescription
            item.aiUndoCount = max(0, item.aiUndoCount - 1)
            self.undoneAIDescription = nil
            deferredPersist()
        }
        deferredPersist()
    }

    /// Save + Firestore sync a beat after the current frame — keeps undo/redo taps
    /// responsive (the synchronous save was part of the visible lag). Fires on the
    /// main actor; the deleted-item guard lives in syncProductData.
    private func deferredPersist() {
        Task { @MainActor in
            guard !Item.deletedIDs.contains(item.id) else { return }
            try? modelContext.save()
            uploadManager.syncProductData(item)
        }
    }

    private func showToast(message: String, onRestore: @escaping () -> Void) {
        toastMessage = message
        toastRestoreAction = {
            onRestore()
            withAnimation { toastMessage = nil; toastRestoreAction = nil }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation { toastMessage = nil; toastRestoreAction = nil }
        }
    }
}

// MARK: - PublishedListingsView

struct PublishedListingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Item> { $0.isDraft == false })
    private var allItems: [Item]
    @State private var cache = CachedImageManager()

    var body: some View {
        Group {
            if allItems.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                    Text("No published listings yet")
                        .foregroundStyle(.secondary)
                }
            } else {
                List(allItems) { item in
                    PublishedRow(item: item, cache: cache)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Published")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - PublishedRow

struct PublishedRow: View {
    let item: Item
    let cache: CachedImageManager

    @Environment(\.modelContext) private var modelContext
    @State private var titleText: String = ""
    @State private var priceText: String = ""
    @State private var descriptionText: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let assetId = item.sourceAssetIdentifiers.first {
                DraftThumbnailView(item: item, assetId: assetId)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: 60, height: 60)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Title…", text: $titleText)
                    .font(.headline)

                HStack(spacing: 2) {
                    Text("$")
                        .foregroundStyle(.secondary)
                    TextField("Price", text: $priceText)
                        .keyboardType(.decimalPad)
                }
                .font(.subheadline)

                TextField("Description…", text: $descriptionText, axis: .vertical)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2...4)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            titleText = item.userEditedTitle ?? item.aiSuggestedTitle ?? ""
            descriptionText = item.userEditedDescription ?? item.aiSuggestedDescription ?? ""
            if let p = item.userEditedPrice ?? item.aiSuggestedPrice {
                priceText = String(format: "%.2f", p)
            }
        }
        .onDisappear {
            saveLocalStateToModel()
        }
    }

    private func saveLocalStateToModel() {
        if item.userEditedTitle != titleText {
            item.userEditedTitle = titleText
        }

        if item.userEditedDescription != descriptionText {
            item.userEditedDescription = descriptionText
        }

        let cleaned = priceText.filter { $0.isNumber || $0 == "." }
        let newPrice = cleaned.isEmpty ? nil : Double(cleaned)
        if item.userEditedPrice != newPrice {
            item.userEditedPrice = newPrice
        }

        try? modelContext.save()
    }
}

// MARK: - Supporting Cross-Posting Types
struct PublishConfirmationSheet: View {
    let itemsToPublish: [Item]
    let onConfirm: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var integrationRepo = IntegrationRepository.shared
    @State private var selectedPlatforms: Set<String> = []
    /// Platforms whose toggle the user has explicitly touched. The async `.task`
    /// default-selection may still seed the others, but must never overwrite an
    /// explicit user choice made while integrations were loading.
    @State private var touchedPlatforms: Set<String> = []
    @State private var showAddressSetupSheet = false
    @State private var platformToEnableAfterAddressSetup = ""
    /// Gates the Publish button until integrations/settings finish loading, so a fast tap
    /// can't confirm with `selectedPlatforms` still empty from the async default-selection
    /// not having run yet (github issue #46).
    @State private var isLoadingIntegrations = true
    @State private var showEmptyPlatformsConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                // Platforms only. The per-listing title/price rows that used to sit here
                // pushed the actual decision off-screen on a bulk publish, and repeated
                // what Review & Publish (one screen back) already shows.
                Section(header: Text("Cross-Post Options"), footer: Text(publishSummary)) {
                    if integrationRepo.integrations.isEmpty {
                        Text("No integrations available. Set them up in Profile Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(integrationRepo.integrations) { integration in
                            let isAPI = integration.platform == "ebay" || integration.platform == "etsy"
                            let isOn = Binding<Bool>(
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
                            )
                            Toggle(isOn: isOn) {
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
                                        Text("Launches browser autofill post-publish")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                // A Form Toggle only responds on the switch itself; the label —
                                // most of the row — was dead space, which read as "tapping does
                                // nothing." Make the label area toggle too.
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { isOn.wrappedValue.toggle() }
                            }
                            .disabled(isAPI && !integration.isConnected)
                        }
                    }
                }
            }
            .navigationTitle("Publish Listings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoadingIntegrations {
                        ProgressView()
                    } else {
                        Button("Publish") {
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
                // explicitly toggled while the async load was in flight (issue #8) — a
                // blanket reassignment here used to wipe the user's in-flight choices.
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
            .confirmationDialog(
                "Publish to Wonni only? No cross-post platforms are selected.",
                isPresented: $showEmptyPlatformsConfirm,
                titleVisibility: .visible
            ) {
                Button("Publish to Wonni Only") {
                    onConfirm(selectedPlatforms)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
    
    /// One line standing in for the old per-listing rows: how many, and the total ask.
    private var publishSummary: String {
        let count = itemsToPublish.count
        let total = itemsToPublish.reduce(0.0) { $0 + ($1.userEditedPrice ?? $1.aiSuggestedPrice ?? 0) }
        let amount = total.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
        return "\(count) listing\(count == 1 ? "" : "s") · \(amount) total. Every listing is also published to Wonni."
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

