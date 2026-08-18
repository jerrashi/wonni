//
//  DesktopDraftsView.swift
//  wonni
//

import SwiftUI
import FirebaseAuth

/// "Desktop Drafts" — the iOS half of cross-platform draft continuity. Lists
/// dropship (web-originated) `products/{id}` docs still in progress
/// (`isDraft != false`, `source != "ios"`) so the user can tap one to adopt it as a
/// local `Item` and keep editing on iOS. Mirrors wonni_dropship's own "Mobile
/// Drafts" folder on its Dashboard — same idea, opposite direction.
struct DesktopDraftsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var drafts: [(id: String, data: [String: Any])] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var adoptingId: String?
    @State private var adoptedItem: Item?

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let loadError {
                Text(loadError).font(.subheadline).foregroundStyle(.secondary)
            } else if drafts.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("No Desktop Drafts")
                        .font(.title3.weight(.semibold))
                    Text("Products started on the web dashboard and not yet posted will show up here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding().listRowBackground(Color.clear)
            } else {
                ForEach(drafts, id: \.id) { draft in
                    Button {
                        adopt(draft)
                    } label: {
                        DesktopDraftRowView(data: draft.data, isAdopting: adoptingId == draft.id)
                    }
                    .buttonStyle(.plain)
                    .disabled(adoptingId != nil)
                }
            }
        }
        .navigationTitle("Desktop Drafts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $adoptedItem) { item in
            DraftEditSheet(item: item)
        }
        .onChange(of: adoptedItem) { _, newValue in
            // Once the adopted draft's editor is dismissed, this list has served its
            // purpose — back out to wherever "Desktop Drafts" was opened from.
            if newValue == nil, adoptingId != nil { dismiss() }
        }
    }

    private func load() async {
        guard let userId = Auth.auth().currentUser?.uid else {
            loadError = "Not signed in."
            isLoading = false
            return
        }
        do {
            drafts = try await ProductRepository.shared.fetchDesktopDrafts(userId: userId)
        } catch {
            loadError = "Could not load desktop drafts."
        }
        isLoading = false
    }

    private func adopt(_ draft: (id: String, data: [String: Any])) {
        adoptingId = draft.id
        Task {
            let item = await UploadManager.shared.adoptProduct(productId: draft.id, modelContext: modelContext)
            adoptingId = nil
            adoptedItem = item
        }
    }
}

private struct DesktopDraftRowView: View {
    let data: [String: Any]
    let isAdopting: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let urlString = (data["images"] as? [String])?.first, let url = URL(string: urlString) {
                // products.images holds full public URLs already (dropship's own
                // convention) — no Storage-path resolution needed, unlike StorageImage.
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color(.systemGray5)
                    }
                }
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color(.systemGray5))
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
                .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text((data["title"] as? String)?.isEmpty == false ? (data["title"] as! String) : "Untitled")
                    .font(.subheadline.weight(.semibold))
                Text(sourceLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isAdopting {
                ProgressView()
            } else {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var sourceLabel: String {
        switch data["source"] as? String {
        case "aliexpress": return "From AliExpress"
        case "weverse": return "From Weverse"
        default: return "From web"
        }
    }
}
