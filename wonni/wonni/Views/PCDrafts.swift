//
//  PCDrafts.swift
//  wonni
//
//  Phone vs PC drafts (2026-11-25, mock https://claude.ai/artifact/1L7JKHqXkmPP5MAkJLn6Eu).
//  Phone and web drafts are one folder (`products/{id}`, isDraft) tagged by where they
//  were made; the tag never changes. Drafts shows phone drafts; PC drafts appear under
//  the PC button, or mixed in when Settings › Drafts › "Show PC drafts" is on
//  (`users/{uid}/sellingSettings/default.showPcDraftsOnPhone`, account-wide — the web's
//  twin is `showPhoneDraftsOnWeb`). A PC draft not on this phone yet is a network row
//  with a cloud (`CloudDraftCard`); opening it downloads it first (`adoptProduct`) and
//  from then on it is an ordinary local draft whose edits sync back to the same doc.
//  Replaces the old "Desktop Drafts" sheet, which this file used to be.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

enum DraftOrigin {
    /// iOS gives every draft a UUID product id the moment it is created
    /// (`Item(firestoreListingId: UUID().uuidString)`); the web's ids are Firestore
    /// auto-ids. So the id alone says where a draft was made — including PC drafts
    /// downloaded before this tag existed, whose `source` the old sync overwrote.
    static func isMadeOnPC(productId: String?) -> Bool {
        guard let productId, !productId.isEmpty else { return false }
        return UUID(uuidString: productId) == nil
    }

    /// Which local drafts the Drafts screen lists.
    static func showsLocal(isMadeOnPC: Bool, pcOnly: Bool, showPcDrafts: Bool) -> Bool {
        pcOnly ? isMadeOnPC : (!isMadeOnPC || showPcDrafts)
    }

    /// PC drafts that exist only on the server: not downloaded to this phone yet.
    static func cloudOnly(remoteIds: [String], localProductIds: Set<String>) -> [String] {
        remoteIds.filter { !localProductIds.contains($0) }
    }
}

extension Item {
    var isMadeOnPC: Bool { DraftOrigin.isMadeOnPC(productId: firestoreListingId) }
}

/// Settings › Drafts › "Show PC drafts". Off by default.
enum DraftsSettings {
    static let field = "showPcDraftsOnPhone"

    private static func doc() -> DocumentReference? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return Firestore.firestore().collection("users").document(uid)
            .collection("sellingSettings").document("default")
    }

    static func loadShowPcDrafts() async -> Bool {
        guard let ref = doc(), let snap = try? await ref.getDocument() else { return false }
        return snap.data()?[field] as? Bool ?? false
    }

    static func saveShowPcDrafts(_ on: Bool) async throws {
        try await doc()?.setData([field: on], merge: true)
    }
}

/// Phone / PC tag, shown only while PC drafts are mixed in with phone drafts.
struct DraftOriginTag: View {
    let isMadeOnPC: Bool

    var body: some View {
        Label(isMadeOnPC ? "PC" : "Phone", systemImage: isMadeOnPC ? "desktopcomputer" : "iphone")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(isMadeOnPC ? Color.accentColor : Color.green)
            .background((isMadeOnPC ? Color.accentColor : Color.green).opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .fixedSize()
    }
}

/// A PC draft that isn't on this phone yet, laid out like `DraftCard` (title, price
/// under it, 80 pt photo strip, plain list row) with a cloud on the first photo. Tap → download → Edit.
/// "Deleted <title> · Undo" while a swiped cloud PC draft waits out its Undo window
/// (`UploadManager.pendingCloudDelete`). Swipe down or sideways to make it final now.
struct CloudDraftDeletedToast: View {
    @EnvironmentObject private var uploadManager: UploadManager
    @Environment(\.modelContext) private var modelContext
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        if let pending = uploadManager.pendingCloudDelete {
            HStack(spacing: 14) {
                Text(pending.title.isEmpty ? "Draft deleted" : "Deleted \"\(pending.title)\"")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Button("Undo") { uploadManager.undoCloudDelete() }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("undoCloudDraftDeleteButton")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .offset(dragOffset)
            .highPriorityGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        dragOffset = CGSize(width: value.translation.width, height: max(0, value.translation.height))
                    }
                    .onEnded { value in
                        if value.translation.height > 30 || abs(value.translation.width) > 60 {
                            uploadManager.commitPendingCloudDelete(modelContext: modelContext)
                        } else {
                            withAnimation(.spring(response: 0.3)) { dragOffset = .zero }
                        }
                    }
            )
            .onDisappear { dragOffset = .zero }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct CloudDraftCard: View {
    let data: [String: Any]
    let showTag: Bool
    let isDownloading: Bool
    var isSelectMode = false
    var isSelected = false
    /// Downloads the draft, or toggles it in select mode.
    let onOpen: () -> Void

    private var title: String {
        let t = (data["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty ? "Untitled" : t
    }
    private var priceText: String {
        if let p = data["listingPrice"] as? Double { return p.formatted(.currency(code: "USD")) }
        if let p = data["listingPrice"] as? Int { return Double(p).formatted(.currency(code: "USD")) }
        return "No price"
    }
    private var images: [URL] {
        ((data["images"] as? [String]) ?? []).prefix(8).compactMap(URL.init(string:))
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isSelectMode {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if showTag { DraftOriginTag(isMadeOnPC: true) }
                }
                Text(isDownloading ? "Downloading…" : priceText)
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, url in
                            AsyncImage(url: url) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() } else { Color(.systemGray5) }
                            }
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                if index == 0 {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.5))
                                        if isDownloading { ProgressView().tint(.white) }
                                        else { Image(systemName: "icloud.and.arrow.down").font(.title3).foregroundStyle(.white) }
                                    }
                                }
                            }
                        }
                        if images.isEmpty {
                            Image(systemName: "icloud.and.arrow.down")
                                .frame(width: 80, height: 80)
                                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(height: 80)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDownloading)
        .accessibilityLabel(isSelectMode ? "\(title), on your PC" : "\(title), on your PC. Tap to download.")
        .accessibilityAddTraits(isSelectMode && isSelected ? .isSelected : [])
        .accessibilityIdentifier("cloudDraftCard")
    }
}

/// Settings › Drafts row.
struct ShowPcDraftsToggle: View {
    @State private var isOn = false
    @State private var loaded = false

    var body: some View {
        Toggle("Show PC drafts", isOn: $isOn)
            .disabled(!loaded)
            .task {
                isOn = await DraftsSettings.loadShowPcDrafts()
                loaded = true
            }
            .onChange(of: isOn) { old, new in
                guard loaded, old != new else { return }
                Task {
                    do { try await DraftsSettings.saveShowPcDrafts(new) }
                    catch { isOn = old }
                }
            }
            .accessibilityIdentifier("showPcDraftsToggle")
    }
}
